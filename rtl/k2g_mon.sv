// The host monitor: the machine's operator, over the serial link.
//
// Until this existed, putting a program on the board meant regenerating the
// boot ROM and rebuilding the bitstream -- one program per synthesis, several
// minutes each -- and a program that misbehaved could only be diagnosed from
// six LEDs, because a halted core cannot execute the CSP read that would report
// its own fault cause (docs/bring-up.md calls the LEDs "the debugger").
//
// This module loads programs, starts and stops the core, and reads and writes
// memory, all from the host. The wire protocol is docs/host-control.md; the
// type codes come from `k2g_host_pkg`, generated from emu/src/hostproto.rs so
// that this file and the `kctl` host tool cannot disagree about what a frame
// means.
//
// ---- it owns the UART, in both directions ----
//
// The program's console output and the host's commands share one 8N1 link, so
// EVERY BYTE ON THE WIRE IS FRAMED and console output is a frame type of its
// own. The alternative -- raw console bytes with framed commands interleaved --
// makes a program that happens to print the magic sequence indistinguishable
// from a command, and the symptom of that is a wedged machine diagnosed over a
// serial cable.
//
// ---- THE DEADLOCK, AND WHY THERE ISN'T ONE ----
//
// This is the non-obvious part of the design and it is worth reading before
// changing the arbitration.
//
// A `PAUSE` holds fetch and then waits for the core to go quiet. The core is
// roughly fifty times faster than the line, so a printing program spends most
// of its time stalled on a full console buffer (k2g_csp.sv's `uart_tx_ready`
// is this module's "buffer not full"). If the monitor stopped emitting console
// frames while it waited, that program would never drain, never go idle, and
// the `PAUSE` would never complete -- each side waiting for the other.
//
// So: **console frames keep flowing for as long as the command engine is
// waiting.** A reply takes the transmitter only once the command is ready to
// answer, which for `PAUSE` is after the machine is already quiet -- at which
// point the core cannot produce another console byte. The two never contend.
//
// ---- what it does not do ----
//
// No single-step, no register dump, no breakpoints.
//
// AREA IS WHY, and it is not a hypothetical. The SoC was at 89% of its 8640
// logic cells before any of this; this module costs 906 of them and the design
// now places at 99%. The first version did not build at all -- 8645 cells,
// over by five -- and the second failed placement with 75 LUTs unplaced. What
// bought the difference is recorded at `crc_byte` and at `rpay` below, and the
// levers left are in docs/v2-plan.md. The next thing added here will not fit.
//
// A `WRITE` streams into memory as its bytes arrive rather than being buffered
// and committed at the end. At 87 microseconds per byte on the wire the bus is
// never the bottleneck, and a whole-payload buffer is area this part does not
// have. The price is that a frame failing CRC has already written part of its
// range; `kctl load` reads back and compares, which closes it on the host side
// for one extra pass over a link that is already the slow part. A corrupt
// header is bounded rather than unbounded -- a length above MAX_PAYLOAD is
// refused before any payload byte is taken, and an address outside memory is
// refused before any bus request -- so the worst case is up to MAX_PAYLOAD
// bytes at a legal but wrong address, which the read-back finds.

`include "k2g_types.svh"

module k2g_mon
  import k2g_types::*;
  import k2g_host_pkg::*;
#(
    // Where ADDR_OUT_OF_RANGE begins, and therefore what this module refuses to
    // address. The same number as the core's.
    parameter int MEM_BYTES = 8 * 1024 * 1024,

    // A build with no CPU behind it -- the `mon` bring-up stage -- answers
    // everything except RESET, and says so in IDENT's capability word rather
    // than making the host find out by timing out. It has no caches either, so
    // its pause needs no maintenance sequence.
    parameter bit HAS_RUN_CONTROL = 1'b1,
    parameter bit HAS_CONSOLE     = 1'b1,

    // The host -> program direction, separately, because it is separately
    // affordable. `k2g_soc` builds with this clear: the receive buffer and its
    // accept logic are 33 logic cells -- measured on the `mon` stage, 1210 to
    // 1177 -- and that build places at 99% of the part with twenty cells to
    // find. The `mon` probe keeps it, has room, and is where `tb_mon` proves it
    // still works.
    //
    // A parameter rather than a deletion, so this reverts the day the boot ROM
    // stops costing 128 cells of logic (see mkrom.rs). IDENT reports it, so a
    // host discovers it from `kctl ping` rather than from a command timing out.
    parameter bit HAS_CONSOLE_IN  = 1'b1,

    // Console coalescing. Seven bytes of framing per frame, so sending one
    // console byte at a time would cost eight times the link. A frame goes out
    // when the buffer fills or when nothing has been added for CONSOLE_IDLE
    // cycles -- at 13.5 MHz the default is about 150 microseconds, under two
    // byte times, so a program that prints once and stops is not left waiting.
    parameter int CONSOLE_TX_DEPTH = 16,
    parameter int CONSOLE_RX_DEPTH = 4,
    parameter int CONSOLE_IDLE     = 2048,

    // How long the core is held in reset by a RESET command. Its reset is
    // synchronous and one cycle would do; this is margin, and it happens once
    // per program load.
    parameter int RESET_CYCLES = 16
) (
    input  logic clk,
    input  logic rst_n,

    // ---- the serial link, as byte streams ---------------------------------
    // `rx_valid` is a one-cycle pulse from k2g_uart_rx; there is no way to
    // refuse a byte, which is why the receive path never back-pressures and
    // instead reports what it could not take.
    input  logic       rx_valid,
    input  logic [7:0] rx_data,
    output logic       tx_valid,
    output logic [7:0] tx_data,
    input  logic       tx_ready,

    // ---- memory -----------------------------------------------------------
    // One request in flight at a time: this master's credit is 1, which is all
    // a link delivering a byte every 87 microseconds can use.
    k2g_membus.master bus,

    // ---- run control ------------------------------------------------------
    output logic        fetch_hold,      // stop the core issuing fetches
    input  logic        core_idle,       // ... and nothing is left in flight
    input  logic        core_halted,
    input  logic        core_faulted,
    input  logic [4:0]  core_fault_cause,
    input  logic [31:0] core_fault_addr,
    input  logic [31:0] core_fault_info,
    input  logic [63:0] core_cycles,
    output logic        core_rst,        // held high to reset the core
    output logic        bus_own,         // this module owns the memory bus

    // Cache maintenance, shared with the core's own ICINVR request. A pause
    // cleans the write-back data cache and drops the instruction cache, which
    // is what makes memory tell the truth about what the program stored.
    output logic        cmaint_req,
    input  logic        cmaint_done,

    // ---- the program's console --------------------------------------------
    input  logic        con_tx_valid,
    input  logic [7:0]  con_tx_data,
    output logic        con_tx_ready,
    output logic        con_rx_valid,
    output logic [7:0]  con_rx_data,
    input  logic        con_rx_take
);

  localparam int RSTW    = $clog2(RESET_CYCLES + 1);
  localparam int CTX_W   = $clog2(CONSOLE_TX_DEPTH) + 1;
  localparam int CRX_W   = $clog2(CONSOLE_RX_DEPTH) + 1;
  localparam int CIDLE_W = $clog2(CONSOLE_IDLE + 1);

  // ---- CRC ----------------------------------------------------------------
  // CRC-16/CCITT-FALSE, ONE BIT PER CYCLE.
  //
  // The unrolled byte-at-a-time form is the obvious way to write this and it
  // does not fit. Measured on the whole SoC: with two unrolled networks the
  // design came to 8645 logic cells against the part's 8640 -- over by five.
  // Serialized, each is a 16-bit shift with a conditional XOR and a four-bit
  // counter.
  //
  // The link pays nothing for it. A byte at 115200 baud is about 1170 cycles of
  // `clk_sys`; eight of them is 0.7% of one byte time, and the receive CRC is
  // not read until two further bytes have arrived.
  //
  // WHAT IT COSTS INSTEAD is that the CRC is not ready the instant a byte is
  // consumed, so both directions have to wait for it: `tx_valid` is held low
  // while the shifts run, and a received byte arriving before they finish is an
  // error rather than a wrong answer. Both are below.
  logic [3:0] rx_crc_bits, tx_crc_bits;

  // ---- receive ------------------------------------------------------------
  typedef enum logic [2:0] {
    R_M0,    // hunting for the first magic byte
    R_M1,
    R_TY,
    R_L0,
    R_L1,
    R_PAY,
    R_C0,
    R_C1
  } rx_state_e;

  rx_state_e        rx_st;
  logic [7:0]       rx_ty;
  logic [7:0]       rx_len_lo;    // held between the two length bytes
  logic [LEN_W-1:0] rx_len, rx_ix;
  logic [15:0]      rx_crc;
  logic [7:0]       rx_crc_lo;

  // Which received bytes the CRC covers: everything but the magic and the CRC
  // itself. The byte is always `rx_data`.
  wire logic rx_crc_en = rx_valid && ((rx_st == R_TY) || (rx_st == R_L0) ||
                                      (rx_st == R_L1) || (rx_st == R_PAY));

  // Set as soon as a reason is known, reported once the frame ends. A damaged
  // frame must still be consumed to its end, or the frames behind it are read
  // as its payload.
  logic [7:0] rx_err;

  // ---- transmit -----------------------------------------------------------
  typedef enum logic [2:0] {
    T_IDLE, T_M0, T_M1, T_TY, T_L0, T_L1, T_PAY, T_CRC
  } tx_state_e;

  typedef enum logic [1:0] { SRC_RPAY, SRC_READ, SRC_CON } tx_src_e;

  tx_state_e        tx_st;
  tx_src_e          tx_src;
  logic [7:0]       tx_ty;
  logic [LEN_W-1:0] tx_len, tx_ix;
  logic [15:0]      tx_crc;
  logic             tx_crc_hi;   // which half of the CRC is going out

  wire logic tx_idle = (tx_st == T_IDLE);

  // STATE is the only reply that has to be CAPTURED -- its fields are moving,
  // and they are set by the command that is about to answer. It is registered
  // and indexed out a byte at a time.
  //
  // THE OTHER THREE ARE NOT REGISTERED, and that is an area decision rather
  // than a style one. Loading this vector from four sources is a 160-bit 4:1
  // multiplexer, which came to a few hundred logic cells on a part that had
  // seventy-five to spare -- the design failed to place. IDENT is entirely
  // constant, and ACK and NAK are two bytes and one between them, so all three
  // are built where the byte goes out and only their contents are held.
  logic [STATE_LEN*8-1:0] rpay;
  logic [LEN_W-1:0]       rep_ack;
  logic [7:0]             rep_nak;

  // ---- console buffers ----------------------------------------------------
  logic [7:0]       ctx_mem [0:CONSOLE_TX_DEPTH-1];
  logic [CTX_W-1:0] ctx_wp, ctx_rp;
  logic [7:0]       crx_mem [0:CONSOLE_RX_DEPTH-1];
  logic [CRX_W-1:0] crx_wp, crx_rp;

  wire logic [CTX_W-1:0] ctx_count = ctx_wp - ctx_rp;
  wire logic [CRX_W-1:0] crx_count = crx_wp - crx_rp;
  wire logic ctx_full = (ctx_count == CTX_W'(CONSOLE_TX_DEPTH));
  wire logic crx_full = (crx_count == CRX_W'(CONSOLE_RX_DEPTH));

  logic [CIDLE_W-1:0] ctx_quiet;

  // Full, or nothing added for a while. Sending one byte per frame would cost
  // eight times the link; waiting for a full buffer would strand the tail of a
  // program's output until the next one.
  wire logic ctx_due = HAS_CONSOLE && (ctx_count != '0) &&
                       (ctx_full || (ctx_quiet == CIDLE_W'(CONSOLE_IDLE)));

  assign con_tx_ready = HAS_CONSOLE && !ctx_full;
  assign con_rx_valid = HAS_CONSOLE && HAS_CONSOLE_IN && (crx_count != '0);
  assign con_rx_data  = HAS_CONSOLE_IN ? crx_mem[crx_rp[CRX_W-2:0]] : 8'd0;

  // ---- command engine -----------------------------------------------------
  typedef enum logic [2:0] {
    C_IDLE,
    C_PAUSE_WAIT,   // fetch held, waiting for the core to go quiet
    C_PAUSE_CM,     // caches being made coherent
    C_RESET,        // core held in reset
    C_START,        // reply ready, waiting for the transmitter
    C_SEND          // reply going out
  } cmd_state_e;

  cmd_state_e       cmd_st;
  logic [7:0]       rep_ty;
  logic [LEN_W-1:0] rep_len;
  tx_src_e          rep_src;

  logic            paused_r;
  logic [RSTW-1:0] rst_cnt;

  wire logic cmd_busy = (cmd_st != C_IDLE);

  // ---- memory access ------------------------------------------------------
  // A write byte waiting for the bus, and a read word being turned into bytes.
  // Never both: a WRITE streams during its own frame and a READ streams during
  // its reply, and a command arriving while another is in progress is refused
  // with BUSY before either starts.
  logic        wr_pend;
  logic [31:0] wr_addr;
  logic [7:0]  wr_byte;
  logic [31:0]      wr_ptr;    // where the next payload byte goes
  logic [LEN_W-1:0] wr_count;  // how many have been accepted

  logic [31:0] rd_addr;
  logic [15:0] rd_left;
  logic [31:0] rd_word;
  logic        rd_word_valid;
  logic        rd_busy;     // a read is outstanding on the bus

  // A function of registers only. `req_valid` must never look at `req_ready`
  // (k2g_chan.sv rule 3), and this is where that would be easy to break.
  wire logic rd_issue = (rd_left != 16'd0) && !rd_word_valid && !rd_busy;

  assign bus.req_valid = wr_pend || rd_issue;
  assign bus.req.addr  = wr_pend ? wr_addr : {rd_addr[31:2], 2'b00};
  assign bus.req.len   = 5'd0;
  assign bus.req.we    = wr_pend ? (4'b0001 << wr_addr[1:0]) : 4'b0000;
  assign bus.req.wdata = {4{wr_byte}};

  wire logic [7:0] rd_byte = rd_word[{rd_addr[1:0], 3'b000} +: 8];

  // ---- what a header commits to -------------------------------------------
  // Everything about admissibility is decided from the header, before a
  // payload byte is consumed, because WRITE starts writing during its own
  // payload.
  function automatic logic known_type(input logic [7:0] t);
    known_type = (t == HF_PING) || (t == HF_STATUS) || (t == HF_PAUSE) ||
                 (t == HF_RESUME) || (t == HF_RESET) || (t == HF_WRITE) ||
                 (t == HF_READ) || (t == HF_CONSOLE_IN);
  endfunction

  function automatic logic needs_pause(input logic [7:0] t);
    needs_pause = (t == HF_RESET) || (t == HF_WRITE) || (t == HF_READ);
  endfunction

  function automatic logic implemented(input logic [7:0] t);
    implemented = known_type(t) &&
                  !(!HAS_RUN_CONTROL && (t == HF_RESET)) &&
                  !(!(HAS_CONSOLE && HAS_CONSOLE_IN) && (t == HF_CONSOLE_IN));
  endfunction

  function automatic logic len_ok(input logic [7:0] t, input logic [15:0] n);
    unique case (t)
      HF_WRITE:      len_ok = (n > 16'(WRITE_HDR_LEN));
      HF_READ:       len_ok = (n == 16'(READ_REQ_LEN));
      HF_CONSOLE_IN: len_ok = (n != 16'd0);
      default:       len_ok = (n == 16'd0);
    endcase
  endfunction

  // ---- reply payloads -----------------------------------------------------
  wire logic [7:0] state_flags = {4'd0,
                                  bus_own,
                                  core_faulted && HAS_RUN_CONTROL,
                                  core_halted  && HAS_RUN_CONTROL,
                                  paused_r};

  wire logic [31:0] caps = (CAP_MEMORY |
                            (HAS_RUN_CONTROL ? CAP_RUN_CONTROL : 32'd0) |
                            (HAS_CONSOLE     ? CAP_CONSOLE     : 32'd0) |
                            (HAS_CONSOLE_IN  ? CAP_CONSOLE_IN  : 32'd0));

  // Little-endian on the wire, so the first byte is the low end of the vector
  // and each field sits above the one before it.
  wire logic [STATE_LEN*8-1:0] ident_pay =
      {32'd0, caps, 32'(MEM_BYTES), CORE_ID,
       16'(MAX_PAYLOAD), 16'(PROTO_VERSION)};

  wire logic [STATE_LEN*8-1:0] state_pay =
      {core_cycles, core_fault_info, core_fault_addr,
       16'd0, {3'd0, core_fault_cause}, state_flags};

  // ---- the byte going out -------------------------------------------------
  logic [7:0] tx_pay_byte;
  always_comb begin
    unique case (tx_src)
      SRC_READ: tx_pay_byte = rd_byte;
      SRC_CON:  tx_pay_byte = ctx_mem[ctx_rp[CTX_W-2:0]];
      default:
        unique case (tx_ty)
          HF_IDENT: tx_pay_byte = ident_pay[{tx_ix[4:0], 3'b000} +: 8];
          HF_ACK:   tx_pay_byte = tx_ix[0] ? {{(16-LEN_W){1'b0}}, rep_ack}[15:8]
                                           : rep_ack[7:0];
          HF_NAK:   tx_pay_byte = rep_nak;
          default:  tx_pay_byte = rpay[{tx_ix[4:0], 3'b000} +: 8];
        endcase
    endcase
  end

  always_comb begin
    unique case (tx_st)
      T_M0:    tx_data = MAGIC0;
      T_M1:    tx_data = MAGIC1;
      T_TY:    tx_data = tx_ty;
      T_L0:    tx_data = tx_len[7:0];
      // Widened to 16 and then shifted, rather than indexing `tx_len`'s top
      // bit: `tx_len[LEN_W-1]` is bit 8 while LEN_W is 9 and bit 7 the moment
      // it is 8, at which point a length of 128 goes out as 384. It did.
      T_L1:    tx_data = 8'(16'(tx_len) >> 8);
      T_PAY:   tx_data = tx_pay_byte;
      T_CRC:   tx_data = tx_crc_hi ? tx_crc[15:8] : tx_crc[7:0];
      default: tx_data = 8'd0;
    endcase
  end

  // A DATA frame's payload comes off the bus, so there are cycles in which the
  // next byte does not exist yet. Offering it anyway would ship a byte memory
  // had not answered, under a CRC that covers it -- silent corruption the host
  // would believe. `rd_word_valid` is a register, so this is not `tx_valid`
  // looking at `tx_ready` (k2g_chan.sv rule 3); it is looking at whether the
  // data is there.
  wire logic tx_pay_ok = (tx_src != SRC_READ) || rd_word_valid;

  // `tx_crc_bits` is in here because a serial CRC is not ready the cycle after
  // a byte is taken: offering the next byte early would fold it into a CRC
  // still being computed, and offering the CRC itself early would send the
  // wrong two bytes. It is a register, so this is not `tx_valid` looking at
  // `tx_ready` (k2g_chan.sv rule 3).
  assign tx_valid = (tx_st != T_IDLE) && (tx_crc_bits == 4'd0) &&
                    ((tx_st != T_PAY) || tx_pay_ok);

  wire logic tx_take = tx_valid && tx_ready;

  // The byte fed to the CRC is always the byte going out, and the magic and
  // the CRC itself are not covered.
  wire logic tx_crc_en = tx_take && (tx_st != T_M0) && (tx_st != T_M1) &&
                         (tx_st != T_CRC);

  // ---- who gets the transmitter -------------------------------------------
  // A reply takes priority, and cannot deadlock against console output: see
  // the header. `C_START` is the only state in which a reply is ready, and it
  // is only reached once whatever the command was waiting for has happened.
  wire logic rep_start = (cmd_st == C_START) && tx_idle;
  wire logic con_start = ctx_due && tx_idle && !rep_start;

  // =========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_st         <= R_M0;
      rx_ty         <= 8'd0;
      rx_len_lo     <= 8'd0;
      rx_len        <= '0;
      rx_ix         <= '0;
      rx_crc        <= CRC_INIT;
      rx_crc_bits   <= 4'd0;
      rx_crc_lo     <= 8'd0;
      rx_err        <= 8'd0;

      tx_st         <= T_IDLE;
      tx_src        <= SRC_RPAY;
      tx_ty         <= 8'd0;
      tx_len        <= '0;
      tx_ix         <= '0;
      tx_crc        <= CRC_INIT;
      tx_crc_bits   <= 4'd0;
      tx_crc_hi     <= 1'b0;
      rpay          <= '0;
      rep_ack       <= '0;
      rep_nak       <= 8'd0;

      ctx_wp        <= '0;
      ctx_rp        <= '0;
      crx_wp        <= '0;
      crx_rp        <= '0;
      ctx_quiet     <= '0;

      cmd_st        <= C_IDLE;
      rep_ty        <= 8'd0;
      rep_len       <= '0;
      rep_src       <= SRC_RPAY;

      paused_r      <= 1'b0;
      fetch_hold    <= 1'b0;
      bus_own       <= 1'b0;
      core_rst      <= 1'b0;
      cmaint_req    <= 1'b0;
      rst_cnt       <= '0;

      wr_pend       <= 1'b0;
      wr_addr       <= 32'd0;
      wr_byte       <= 8'd0;
      wr_ptr        <= 32'd0;
      wr_count      <= '0;

      rd_addr       <= 32'd0;
      rd_left       <= 16'd0;
      rd_word       <= 32'd0;
      rd_word_valid <= 1'b0;
      rd_busy       <= 1'b0;
    end else begin

      // ---- console buffers ------------------------------------------------
      if (HAS_CONSOLE && con_tx_valid && !ctx_full) begin
        ctx_mem[ctx_wp[CTX_W-2:0]] <= con_tx_data;
        ctx_wp                     <= ctx_wp + CTX_W'(1);
        ctx_quiet                  <= '0;
      end else if (ctx_quiet != CIDLE_W'(CONSOLE_IDLE)) begin
        ctx_quiet <= ctx_quiet + CIDLE_W'(1);
      end

      if (HAS_CONSOLE && HAS_CONSOLE_IN && con_rx_take && (crx_count != '0)) begin
        crx_rp <= crx_rp + CRX_W'(1);
      end

      // ---- the bus --------------------------------------------------------
      if (wr_pend && bus.req_ready)  wr_pend <= 1'b0;
      if (rd_issue && bus.req_ready) rd_busy <= 1'b1;
      if (rd_busy && bus.rsp_valid) begin
        rd_word       <= bus.rsp_data;
        rd_word_valid <= 1'b1;
        rd_busy       <= 1'b0;
      end

      // ---- receive --------------------------------------------------------
      //
      // The CRC update comes BEFORE the state machine, so that R_M1's
      // reinitialization wins over a shift still running from the frame before.
      if (rx_crc_en) begin
        rx_crc      <= rx_crc ^ {rx_data, 8'h00};
        rx_crc_bits <= 4'd8;
      end else if (rx_crc_bits != 4'd0) begin
        rx_crc      <= rx_crc[15] ? ((rx_crc << 1) ^ CRC_POLY) : (rx_crc << 1);
        rx_crc_bits <= rx_crc_bits - 4'd1;
      end

      if (rx_valid) begin
        unique case (rx_st)
          R_M0: if (rx_data == MAGIC0) rx_st <= R_M1;

          // `1B 1B 4B` is a valid start, so a repeated first byte holds here
          // rather than restarting -- otherwise a doubled magic byte swallows
          // the frame behind it.
          R_M1: begin
            if (rx_data == MAGIC1) begin
              rx_st       <= R_TY;
              rx_crc      <= CRC_INIT;
              rx_crc_bits <= 4'd0;
              rx_err      <= 8'd0;
            end else if (rx_data != MAGIC0) begin
              rx_st <= R_M0;
            end
          end

          R_TY: begin
            rx_ty <= rx_data;
            rx_st <= R_L0;
          end

          R_L0: begin
            rx_len_lo <= rx_data;
            rx_st     <= R_L1;
          end

          R_L1: begin
            rx_ix <= '0;

            // A length this build cannot hold is abandoned WITHOUT consuming a
            // payload, which is what stops a corrupt header from swallowing
            // the frames behind it. There is no reply: the type field of a
            // frame whose length is already wrong is not worth trusting.
            if ({rx_data, rx_len_lo} > 16'(MAX_PAYLOAD)) begin
              rx_st <= R_M0;
            end else begin
              rx_len   <= LEN_W'({rx_data, rx_len_lo});
              wr_count <= '0;
              rx_st    <= ({rx_data, rx_len_lo} == 16'd0) ? R_C0 : R_PAY;

              if (cmd_busy)                                 rx_err <= NAK_BUSY;
              else if (!implemented(rx_ty))                 rx_err <= NAK_TYPE;
              else if (!len_ok(rx_ty, {rx_data, rx_len_lo})) rx_err <= NAK_LENGTH;
              else if (needs_pause(rx_ty) && !paused_r)     rx_err <= NAK_STATE;
            end
          end

          R_PAY: begin
            rx_ix <= rx_ix + LEN_W'(1);
            if (rx_ix + LEN_W'(1) == rx_len) rx_st <= R_C0;

            unique case (rx_ty)
              HF_WRITE: begin
                if (rx_ix < LEN_W'(WRITE_HDR_LEN)) begin
                  wr_ptr[{rx_ix[1:0], 3'b000} +: 8] <= rx_data;
                  // The address is complete on its last byte, and bounded
                  // then, so a WRITE that starts outside memory issues nothing
                  // at all.
                  if (rx_ix == LEN_W'(WRITE_HDR_LEN) - LEN_W'(1) && rx_err == 8'd0 &&
                      {rx_data, wr_ptr[23:0]} >= 32'(MEM_BYTES))
                    rx_err <= NAK_ADDRESS;
                end else if (rx_err == 8'd0) begin
                  if (wr_ptr >= 32'(MEM_BYTES)) begin
                    rx_err <= NAK_ADDRESS;
                  end else if (wr_pend) begin
                    // The bus failed to keep up with a line that delivers a
                    // byte roughly every 1200 cycles, against the six a write
                    // takes. Reported rather than dropped in silence.
                    rx_err <= NAK_BUSY;
                  end else begin
                    wr_pend  <= 1'b1;
                    wr_addr  <= wr_ptr;
                    wr_byte  <= rx_data;
                    wr_ptr   <= wr_ptr + 32'd1;
                    wr_count <= wr_count + LEN_W'(1);
                  end
                end
              end

              HF_READ: begin
                if (rx_ix < LEN_W'(WRITE_HDR_LEN))
                  rd_addr[{rx_ix[1:0], 3'b000} +: 8] <= rx_data;
                else if (rx_ix == LEN_W'(WRITE_HDR_LEN))
                  rd_left[7:0] <= rx_data;
                else
                  rd_left[15:8] <= rx_data;
              end

              HF_CONSOLE_IN: begin
                // Bytes beyond what the buffer holds are not taken, and the
                // ACK says how many were -- which is the first real flow
                // control this link has had.
                if (HAS_CONSOLE_IN && rx_err == 8'd0 && !crx_full) begin
                  crx_mem[crx_wp[CRX_W-2:0]] <= rx_data;
                  crx_wp                     <= crx_wp + CRX_W'(1);
                  wr_count                   <= wr_count + LEN_W'(1);
                end
              end

              default: ;
            endcase
          end

          R_C0: begin
            rx_crc_lo <= rx_data;
            rx_st     <= R_C1;
          end

          // A frame that fails its CRC is discarded in silence. Answering it
          // would mean trusting the type field of a frame just proved damaged;
          // the host re-sends on its own timeout. A frame arriving while a
          // command is still in progress is dropped for the same reason -- its
          // header already set NAK_BUSY, and there is nowhere to put a second
          // command's state.
          R_C1: begin
            rx_st <= R_M0;
            if ({rx_data, rx_crc_lo} == rx_crc && cmd_st == C_IDLE) begin
              if (rx_err != 8'd0) begin
                rep_nak <= rx_err;
                rep_ty  <= HF_NAK;
                rep_len <= LEN_W'(NAK_LEN);
                rep_src <= SRC_RPAY;
                cmd_st  <= C_START;
              end else begin
                unique case (rx_ty)
                  HF_PING: begin
                    rep_ty  <= HF_IDENT;
                    rep_len <= LEN_W'(IDENT_LEN);
                    rep_src <= SRC_RPAY;
                    cmd_st  <= C_START;
                  end

                  HF_STATUS: begin
                    rep_ty  <= HF_STATE;
                    rep_len <= LEN_W'(STATE_LEN);
                    rep_src <= SRC_RPAY;
                    cmd_st  <= C_START;
                  end

                  HF_PAUSE: begin
                    rep_ty  <= HF_STATE;
                    rep_len <= LEN_W'(STATE_LEN);
                    rep_src <= SRC_RPAY;
                    if (!HAS_RUN_CONTROL) begin
                      paused_r <= 1'b1;
                      bus_own  <= 1'b1;
                      cmd_st   <= C_PAUSE_CM;
                    end else begin
                      fetch_hold <= 1'b1;
                      cmd_st     <= C_PAUSE_WAIT;
                    end
                  end

                  HF_RESUME: begin
                    // Ownership moves only with nothing in flight
                    // (k2g_membus_mux.sv), which holds here: the core has not
                    // been let go and this module's last request has been
                    // answered.
                    bus_own    <= 1'b0;
                    fetch_hold <= 1'b0;
                    paused_r   <= 1'b0;
                    rep_ty     <= HF_STATE;
                    rep_len    <= 16'(STATE_LEN);
                    rep_src    <= SRC_RPAY;
                    cmd_st     <= C_START;
                  end

                  HF_RESET: begin
                    core_rst <= 1'b1;
                    rst_cnt  <= '0;
                    rep_ty   <= HF_STATE;
                    rep_len  <= 16'(STATE_LEN);
                    rep_src  <= SRC_RPAY;
                    cmd_st   <= C_RESET;
                  end

                  HF_WRITE, HF_CONSOLE_IN: begin
                    rep_ack <= wr_count;
                    rep_ty  <= HF_ACK;
                    rep_len <= LEN_W'(ACK_LEN);
                    rep_src <= SRC_RPAY;
                    cmd_st  <= C_START;
                  end

                  HF_READ: begin
                    // The count is known now, so two things are bounded before
                    // a single request is issued: the range, and the reply
                    // itself. A count above MAX_PAYLOAD would build a frame no
                    // receiver will accept, which reads on the host as a dead
                    // link rather than as a refused command.
                    //
                    // 33 bits on the range, because address plus count is what
                    // has to fit.
                    rd_word_valid <= 1'b0;   // whatever a previous read left
                    if (rd_left > 16'(MAX_PAYLOAD)) begin
                      rd_left <= 16'd0;
                      rep_nak <= NAK_LENGTH;
                      rep_ty  <= HF_NAK;
                      rep_len <= LEN_W'(NAK_LEN);
                      rep_src <= SRC_RPAY;
                    end else if ({1'b0, rd_addr} + {17'd0, rd_left} >
                                 33'(MEM_BYTES)) begin
                      rd_left <= 16'd0;
                      rep_nak <= NAK_ADDRESS;
                      rep_ty  <= HF_NAK;
                      rep_len <= LEN_W'(NAK_LEN);
                      rep_src <= SRC_RPAY;
                    end else begin
                      rep_ty  <= HF_DATA;
                      rep_len <= LEN_W'(rd_left);
                      rep_src <= SRC_READ;
                    end
                    cmd_st <= C_START;
                  end

                  default: ;
                endcase
              end
            end
          end

          default: rx_st <= R_M0;
        endcase
      end

      // ---- command engine -------------------------------------------------
      unique case (cmd_st)
        C_IDLE: ;

        // Fetch is held; the pipeline drains on its own. Console frames keep
        // flowing throughout -- see the header. Without that, a printing
        // program never drains and this wait never ends.
        C_PAUSE_WAIT: if (core_idle) begin
          cmaint_req <= 1'b1;
          cmd_st     <= C_PAUSE_CM;
        end

        // Clean the write-back data cache, then drop the instruction cache.
        // The bus is taken only after that finishes, because the flush issues
        // its writeback bursts through the same bus.
        C_PAUSE_CM: if (!HAS_RUN_CONTROL || cmaint_done) begin
          cmaint_req <= 1'b0;
          paused_r   <= 1'b1;
          bus_own    <= 1'b1;
          cmd_st     <= C_START;
        end

        C_RESET: if (rst_cnt == RSTW'(RESET_CYCLES)) begin
          core_rst <= 1'b0;
          cmd_st   <= C_START;
        end else begin
          rst_cnt <= rst_cnt + RSTW'(1);
        end

        C_START: if (tx_idle) cmd_st <= C_SEND;

        C_SEND: if (tx_idle) cmd_st <= C_IDLE;

        default: cmd_st <= C_IDLE;
      endcase

      // Every STATE reply is sampled here rather than where the command was
      // decided, because the flags it reports are set by the command itself:
      // read a cycle earlier it would say "running" on the reply to a PAUSE.
      // Sampling in C_START also keeps `rpay` stable for the whole of C_SEND,
      // which is when the transmitter indexes it.
      if (cmd_st == C_START && rep_ty == HF_STATE) rpay <= state_pay;

      // ---- transmit -------------------------------------------------------
      // Before the case, for the same reason as the receive side.
      if (tx_crc_en) begin
        tx_crc      <= tx_crc ^ {tx_data, 8'h00};
        tx_crc_bits <= 4'd8;
      end else if (tx_crc_bits != 4'd0) begin
        tx_crc      <= tx_crc[15] ? ((tx_crc << 1) ^ CRC_POLY) : (tx_crc << 1);
        tx_crc_bits <= tx_crc_bits - 4'd1;
      end

      unique case (tx_st)
        T_IDLE: begin
          if (rep_start) begin
            tx_ty     <= rep_ty;
            tx_len    <= rep_len;
            tx_src    <= rep_src;
            tx_ix     <= 16'd0;
            tx_crc      <= CRC_INIT;
            tx_crc_bits <= 4'd0;
            tx_crc_hi   <= 1'b0;
            tx_st       <= T_M0;
          end else if (con_start) begin
            tx_ty     <= HF_CONSOLE_OUT;
            tx_len    <= 16'(ctx_count);
            tx_src    <= SRC_CON;
            tx_ix     <= 16'd0;
            tx_crc      <= CRC_INIT;
            tx_crc_bits <= 4'd0;
            tx_crc_hi   <= 1'b0;
            ctx_quiet   <= '0;
            tx_st       <= T_M0;
          end
        end

        T_M0: if (tx_take) tx_st <= T_M1;
        T_M1: if (tx_take) tx_st <= T_TY;

        T_TY: if (tx_take) tx_st <= T_L0;
        T_L0: if (tx_take) tx_st <= T_L1;
        T_L1: if (tx_take) tx_st <= (tx_len == '0) ? T_CRC : T_PAY;

        T_PAY: if (tx_take) begin
          tx_ix <= tx_ix + LEN_W'(1);
          if (tx_ix + LEN_W'(1) == tx_len) tx_st <= T_CRC;

          unique case (tx_src)
            SRC_READ: begin
              rd_addr <= rd_addr + 32'd1;
              rd_left <= rd_left - 16'd1;
              // Crossing into the next word means the one held is spent.
              if (rd_addr[1:0] == 2'b11) rd_word_valid <= 1'b0;
            end
            SRC_CON: ctx_rp <= ctx_rp + CTX_W'(1);
            default: ;
          endcase
        end

        T_CRC: if (tx_take) begin
          if (tx_crc_hi) tx_st     <= T_IDLE;
          else           tx_crc_hi <= 1'b1;
        end

        default: tx_st <= T_IDLE;
      endcase

    end
  end

`ifdef SIMULATION
  // The receive side has no way to wait: `rx_valid` is a pulse and a byte that
  // arrives mid-shift is folded into a CRC that is not there yet. At 115200
  // baud there are about 1170 cycles between bytes against the eight this
  // takes, so it cannot happen on a board -- but a testbench driving the byte
  // interface directly can outrun it, and the symptom would be a frame
  // rejected for a CRC error that is the testbench's fault.
  always_ff @(posedge clk) begin
    if (rst_n && rx_crc_en && rx_crc_bits != 4'd0)
      $error("k2g_mon: a byte arrived %0d cycles into the previous CRC",
             8 - rx_crc_bits);
  end
`endif

endmodule
