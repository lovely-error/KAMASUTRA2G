// PSRAM adapter: two k2g_membus slaves in the core's clock domain, one Gowin
// controller in its own, and nothing but k2g_cdc_fifo in between.
//
//   ibus ---\                        +---------+
//            >-- arbiter --> req fifo -> burst  --> cmd/addr/wr_data/data_mask
//   dbus ---/                        | sequencer|
//                                    |         |
//        rsp routing <-- rsp fifo <--+---------+ <-- rd_data/rd_data_valid
//
// The controller itself is NOT instantiated here. It is a black box with pins
// on it, so it belongs at the board level next to the .cst that names those
// pins; this module takes its user-side interface as ports. That also makes
// the adapter simulatable against a behavioural controller
// (rtl/tb/k2g_psram_model.sv) and synthesizable on its own, which a module
// carrying the IP instance would not be.
//
// ---- one PSRAM command per bus transaction ----
//
// The controller's smallest transfer is a 128-byte burst: 16 user beats of 64
// bits, 32 word addresses (docs/bring-up.md, measured on hardware). A
// `k2g_membus` burst of up to 32 words maps onto exactly one of those, which is
// why the bus grew a length field and why a cache line is 128 bytes.
//
// A SINGLE-WORD ACCESS STILL COSTS A WHOLE BURST, and 124 of the 128 bytes are
// discarded. That is what makes the machine slow without caches -- measured at
// 6.6 core cycles per code point against 1.0 over BSRAM -- and it is not fixed
// here. Keeping the discarded bytes is a cache, with tags and dirty bits and a
// refill path designed together; half of one built inside this adapter would be
// sized against the wrong constraints. What this module does is make the cache
// possible: a 32-word refill is one command rather than thirty-two.
//
// ---- the line buffer, and why one buffer serves both directions ----
//
// A write burst cannot be issued until every word of it is in hand: `cmd_en` is
// one cycle and the write beats start in that same cycle, so the data has to be
// sitting in `clk_out` before the command goes out. A read burst has the
// mirror-image problem at the other end -- the controller delivers two words
// per `clk_out` cycle and the response channel carries one word per `clk_sys`
// cycle, five times slower, and the beats cannot be stalled.
//
// Both are solved by the same 32-word buffer, and it can be one buffer because
// only one command is ever in flight: a burst is either filling it from the
// request stream or draining it into the response stream, never both.
//
// ---- crossings ----
//
// Three k2g_cdc_fifo instances and no other crossing structure, per the
// standing rule in docs/v2-plan.md. Requests out, responses back, and
// calibration status -- which is a level, and is crossed as a stream of tokens
// pushed for as long as `init_calib` is high rather than as an ad-hoc
// synchronizer. That costs about twenty flops and buys the rule staying true,
// which is the only enforcement available here: there is no static CDC tool in
// this toolchain, so "there is exactly one crossing primitive and it has been
// read carefully" is the whole argument.
//
// A token stream rather than a single token because the two sides do not reset
// together (below), and a status bit that could be lost by a reset on one side
// only would be lost forever.
//
// ---- resets ----
//
// `rst_n` is the system reset, in clk_sys. The controller's own reset is NOT
// derived from it and is not this module's business: calibration takes
// hundreds of microseconds, and re-running it every time the button is pressed
// would stall the machine for that long to no purpose. The board holds the
// controller in reset until the PLL has locked and then leaves it alone.
//
// So the clk_out side of this module resets from `rst_n` through an
// asynchronous-assert, synchronous-release chain. That is a reset
// synchronizer, not a data crossing: it carries no value, and it cannot be
// built out of k2g_cdc_fifo because the FIFO needs a reset in each domain
// before it can carry anything at all.
//
// The two sides therefore leave reset a few cycles apart. That is safe here
// and the reason is worth writing down: both FIFO pointers are zeroed by their
// own side's reset, so a side held in reset longer simply sits at zero while
// the other starts from zero too -- the pointers cannot end up mismatched.
// What a reset CAN do is abandon a burst the controller is still streaming, so
// `gap` comes out of reset at its maximum rather than at zero, and the minimum
// command interval is honoured across the reset as well as within a run.

`include "k2g_types.svh"

module k2g_psram
  import k2g_types::*;
(
    // ---- core domain ----
    input logic clk_sys,
    input logic rst_n,

    k2g_membus.slave ibus,      // instruction fetch
    k2g_membus.slave dbus,      // data, and per-byte writes

    // Calibration finished, in clk_sys and sticky. Nothing here needs it --
    // requests simply queue until the controller is ready -- but a board with
    // no working PSRAM otherwise shows only a machine that never starts, and
    // that is a bad thing to have to debug from an LED.
    output logic calib,

    // ---- controller domain (PSRAM_Memory_Interface_HS_Top user side) ----
    input  logic        clk_out,
    input  logic        init_calib,
    input  logic        cmd_rdy,
    output logic        cmd,
    output logic        cmd_en,
    output logic [20:0] addr,
    output logic [63:0] wr_data,
    output logic [7:0]  data_mask,
    input  logic [63:0] rd_data,
    input  logic        rd_data_valid
);

  // Word address bits [22:2]: 21 bits, the whole 8 MB the IP addresses.
  // Anything above it aliases, and does not arise because the core faults
  // ADDR_OUT_OF_RANGE first.
  localparam int WA_W = 21;

  typedef struct packed {
    logic            src;       // 1 = data bus, 0 = fetch
    logic [WA_W-1:0] waddr;     // request address [22:2]
    logic [4:0]      len;       // beats - 1
    logic [3:0]      we;        // 0 = read
    logic [31:0]     wdata;
  } psreq_t;

  typedef struct packed {
    logic        src;
    logic [31:0] data;
  } psrsp_t;

  localparam int REQ_W = 1 + WA_W + 5 + 4 + 32;
  localparam int RSP_W = 1 + 32;

  // The request side is four deep because the core's fetch credit is four and
  // every one of them can be outstanding at once on a bus this slow. The
  // response side only needs to keep the drain busy: it is filled from the
  // line buffer a word at a time and emptied a word at a time, so its depth
  // sets nothing but how far ahead the drain can run.
  localparam int REQ_DEPTH = 4;
  localparam int RSP_DEPTH = 4;

  // MINIMUM COMMAND INTERVAL, in clk_out cycles. IPUG943 Table 4-2 requires 26
  // for a 64-byte burst configuration and `cmd_rdy` does not enforce it -- the
  // probe issued commands two cycles apart for a while and the readback it was
  // checking was quietly wrong. 32 is what has actually run on hardware
  // (k2g_psram_probe), so it is what runs here.
  localparam logic [5:0] TCMD = 6'd32;

  // ---- reset into the controller's domain ---------------------------------
  logic [3:0] orsync;
  wire  logic orst_n = orsync[3];

  always_ff @(posedge clk_out or negedge rst_n) begin
    if (!rst_n) orsync <= 4'd0;
    else        orsync <= {orsync[2:0], 1'b1};
  end

  // ---- arbitration, in clk_sys --------------------------------------------
  logic reqf_wfull;
  logic last_d;

  // A WRITE BURST OWNS THE REQUEST CHANNEL until its last beat, because that
  // is where its data rides (k2g_membus.sv). This is what the bus lock used to
  // be, except that the length field says how long to hold rather than a
  // separate signal saying whether to.
  logic       wb_active;
  logic [4:0] wb_left;
  logic       wb_src;

  // Round robin: whoever lost the last tie wins the next one. Fixed priority
  // is one gate cheaper and was rejected -- with fetch first, a data access
  // waits behind a fetch stream that always has credit; with data first, a
  // store loop holds the bus for as long as it runs. Neither deadlocks, but
  // both make the machine's speed depend on which port is louder.
  wire logic want_i = ibus.req_valid;
  wire logic want_d = dbus.req_valid;

  wire logic rr_d   = want_d && (!want_i || !last_d);
  wire logic pick_d = wb_active ?  wb_src : rr_d;
  wire logic pick_i = wb_active ? !wb_src : (want_i && !rr_d);

  wire logic grant_i = pick_i && want_i;
  wire logic grant_d = pick_d && want_d;

  wire logic reqf_push = !reqf_wfull && (grant_i || grant_d);

  // A slave's `req_ready` may look at `req_valid` (k2g_membus.sv); a master's
  // `req_valid` may not look back.
  assign ibus.req_ready = !reqf_wfull && pick_i;
  assign dbus.req_ready = !reqf_wfull && pick_d;

  psreq_t req_in;
  always_comb begin
    if (grant_d) begin
      req_in.src   = 1'b1;
      req_in.waddr = dbus.req.addr[WA_W+1:2];
      req_in.len   = dbus.req.len;
      req_in.we    = dbus.req.we;
      req_in.wdata = dbus.req.wdata;
    end else begin
      req_in.src   = 1'b0;
      req_in.waddr = ibus.req.addr[WA_W+1:2];
      req_in.len   = ibus.req.len;
      req_in.we    = 4'b0000;
      req_in.wdata = 32'd0;
    end
  end

  // The header of a write burst is what starts the hold; every beat after it
  // decrements the count. Nothing else may be granted in between.
  wire logic wb_start = reqf_push && !wb_active &&
                        (req_in.we != 4'b0000) && (req_in.len != 5'd0);

  always_ff @(posedge clk_sys) begin
    if (!rst_n) begin
      last_d    <= 1'b0;
      wb_active <= 1'b0;
      wb_left   <= 5'd0;
      wb_src    <= 1'b0;
    end else begin
      if (reqf_push && !wb_active) last_d <= grant_d;

      if (wb_start) begin
        wb_active <= 1'b1;
        wb_left   <= req_in.len;
        wb_src    <= grant_d;
      end else if (wb_active && reqf_push) begin
        if (wb_left == 5'd1) wb_active <= 1'b0;
        wb_left <= wb_left - 5'd1;
      end
    end
  end

  wire logic [REQ_W-1:0] reqf_wdata = req_in;

  logic             reqf_rempty, reqf_pop;
  logic [REQ_W-1:0] reqf_rdata;
  psreq_t           req_out;
  assign req_out = reqf_rdata;

  k2g_cdc_fifo #(.WIDTH(REQ_W), .DEPTH(REQ_DEPTH)) u_reqf (
      .wclk  (clk_sys),
      .wrst_n(rst_n),
      .wpush (reqf_push),
      .wdata (reqf_wdata),
      .wfull (reqf_wfull),
      .rclk  (clk_out),
      .rrst_n(orst_n),
      .rpop  (reqf_pop),
      .rdata (reqf_rdata),
      .rempty(reqf_rempty)
  );

  // ---- the burst sequencer, in clk_out ------------------------------------
  //
  // THE TIGHT PATH IN THIS DOMAIN IS NOT IN THIS MODULE, and an attempt to fix
  // it here made it worse. Place-and-route puts the worst `clk_out` path at
  // 0.7% margin, running from inside the controller -- its temperature
  // auto-adjust logic -- out through `rd_data` and into the line buffer below.
  // Almost all of that delay is the IP's.
  //
  // Registering `rd_data`/`rd_data_valid` at the boundary was tried, on the
  // reasoning that it would at least remove this module's contribution.
  // GowinSynthesis retimed the stage straight back out again -- the buffer's
  // write address and enable are delayed by the same cycle, so folding the
  // register into the RAM's input is legal, and `rdd_q` came back as a wire.
  // With `syn_preserve` forcing it to stay, the reported Fmax went from
  // 67.98 MHz to 66.05 and forty more endpoints failed. Measured twice, both
  // times worse, so it is not here.
  //
  // What that leaves is a clock with very little margin whose critical path
  // this module does not own. The `psram` bring-up stage reports 67.196 MHz
  // against the same 67.500 requirement -- a violation -- and runs on hardware.
  // Worth revisiting only with a lower memory clock, which costs nothing:
  // docs/bring-up.md works out that even 54 MHz has an order of magnitude more
  // bandwidth than a 13.5 MHz core can use.
  typedef enum logic [2:0] {
    S_IDLE, S_WCOLLECT, S_WRITE, S_READ, S_DRAIN
  } seq_e;

  seq_e            state;
  logic            p_src;
  logic [WA_W-1:0] p_waddr;
  logic [4:0]      p_len;
  logic [3:0]      p_we;
  logic [4:0]      beat;        // write beat, or read beat, 0..15/0..16
  logic [4:0]      fill;        // next word offset to collect or drain
  logic [4:0]      left;        // words still to collect or drain
  logic [5:0]      gap;

  // ONE BUFFER, SPLIT INTO EVEN AND ODD WORDS rather than held as 32 entries
  // of 32 bits. A beat is two consecutive words, so the write path wants both
  // halves of an entry in the same cycle -- and a 32-entry array read twice per
  // cycle is two copies of the storage in distributed RAM, since a RAM16 has
  // one read port. Splitting by the low address bit gives each array a single
  // read port and halves the area for nothing.
  //
  // Word offset `o` within the line lives at index o[4:1] of `lbuf_hi` when
  // o[0] is 1 and of `lbuf_lo` when it is 0.
  logic [31:0] lbuf_lo [0:15];
  logic [31:0] lbuf_hi [0:15];

  wire logic [4:0] p_off  = p_waddr[4:0];        // first word within the burst
  wire logic [4:0] in_off = req_out.waddr[4:0];

  logic   rspf_wfull;
  psrsp_t rsp_in;
  wire logic [RSP_W-1:0] rspf_wdata = rsp_in;

  // A guarded rule, per docs/v2-plan.md: every input, every output and every
  // resource the effect needs, named in one expression. `cmd_rdy` is in there
  // but `init_calib` is the one that matters -- `cmd_rdy` is high before
  // calibration ever finishes and is not a ready-to-use gate.
  wire logic can_issue = (state == S_IDLE)
                      && !reqf_rempty
                      && init_calib
                      && cmd_rdy
                      && (gap == 6'd0);

  wire logic in_write = (req_out.we != 4'b0000);
  wire logic in_burst = (req_out.len != 5'd0);

  // A read, or a single-word write, can go straight out. A write burst has to
  // collect its remaining words first.
  assign reqf_pop = can_issue || ((state == S_WCOLLECT) && !reqf_rempty);

  // The burst containing the addressed word: 32 word addresses, aligned.
  assign addr = {p_waddr[WA_W-1:5], 5'b00000};

  // Read address for both halves. The write path walks beats and the drain
  // walks word offsets, and they never run at once, so one port serves both.
  wire logic [3:0] lb_ridx = (state == S_DRAIN) ? fill[4:1] : beat[3:0];
  wire logic [31:0] lb_rlo = lbuf_lo[lb_ridx];
  wire logic [31:0] lb_rhi = lbuf_hi[lb_ridx];

  // Each beat carries two consecutive words of the line.
  assign wr_data = {lb_rhi, lb_rlo};

  // `1` masks, `0` writes, per byte of the 64-bit beat, sampled per beat.
  // A word is written only if its offset falls in this transaction's window;
  // everything else in the line is masked off and keeps whatever it held.
  wire logic [4:0] mask_lo = {beat[3:0], 1'b0};
  wire logic [4:0] mask_hi = {beat[3:0], 1'b1};
  wire logic in_win_lo = (state == S_WRITE) &&
                         (mask_lo >= p_off) && ((mask_lo - p_off) <= p_len);
  wire logic in_win_hi = (state == S_WRITE) &&
                         (mask_hi >= p_off) && ((mask_hi - p_off) <= p_len);

  always_comb begin
    data_mask[3:0] = in_win_lo ? ~p_we : 4'hF;
    data_mask[7:4] = in_win_hi ? ~p_we : 4'hF;
  end

  // COMBINATIONAL, not registered. A registered push decided from the previous
  // cycle's `wfull` is a lost word: the FIFO's `wfull` is a flop, so a push
  // that filled it is only visible the cycle after, and the drain would offer
  // one more word that `wpush && !wfull` silently drops. Deciding and pushing
  // in the same cycle removes the question.
  wire logic drain_go = (state == S_DRAIN) && !rspf_wfull;
  wire logic rspf_push = drain_go;

  always_comb begin
    rsp_in.src  = p_src;
    rsp_in.data = fill[0] ? lb_rhi : lb_rlo;
  end

  always_ff @(posedge clk_out) begin
    if (!orst_n) begin
      state     <= S_IDLE;
      cmd       <= 1'b0;
      cmd_en    <= 1'b0;
      p_src     <= 1'b0;
      p_waddr   <= '0;
      p_len     <= 5'd0;
      p_we      <= 4'b0000;
      beat      <= 5'd0;
      fill      <= 5'd0;
      left      <= 5'd0;
      // Not zero. A reset can abandon a burst the controller is still
      // streaming, and the interval has to hold across that too.
      gap       <= TCMD;
    end else begin
      cmd_en    <= 1'b0;
      if (gap != 6'd0) gap <= gap - 6'd1;

      unique case (state)
        S_IDLE: if (can_issue) begin
          p_src   <= req_out.src;
          p_waddr <= req_out.waddr;
          p_len   <= req_out.len;
          p_we    <= req_out.we;
          beat    <= 5'd0;

          if (in_write) begin
            if (in_off[0]) lbuf_hi[in_off[4:1]] <= req_out.wdata;
            else           lbuf_lo[in_off[4:1]] <= req_out.wdata;
          end

          if (in_write && in_burst) begin
            // Only the first word is here; the rest follow on the request
            // channel and the command waits for them.
            fill  <= in_off + 5'd1;
            left  <= req_out.len;
            state <= S_WCOLLECT;
          end else begin
            cmd    <= in_write;              // IPUG943: 1 write, 0 read
            cmd_en <= 1'b1;
            gap    <= TCMD;
            state  <= in_write ? S_WRITE : S_READ;
          end
        end

        // Later beats of a write burst carry `wdata` and nothing else.
        S_WCOLLECT: if (!reqf_rempty) begin
          if (fill[0]) lbuf_hi[fill[4:1]] <= req_out.wdata;
          else         lbuf_lo[fill[4:1]] <= req_out.wdata;
          fill <= fill + 5'd1;
          if (left == 5'd1) begin
            cmd    <= 1'b1;
            cmd_en <= 1'b1;
            gap    <= TCMD;
            beat   <= 5'd0;
            state  <= S_WRITE;
          end
          left <= left - 5'd1;
        end

        // Write beat 0 is the cycle `cmd_en` is high -- lead 0, searched for
        // on hardware rather than assumed. `cmd_en` is registered, so it and
        // `beat == 0` land together, and beats 1..15 follow one per cycle.
        S_WRITE: begin
          beat <= beat + 5'd1;
          if (beat == 5'd15) state <= S_IDLE;
        end

        // Reads are self-timed: the beat index is the count of `rd_data_valid`
        // pulses, whatever the controller's latency turns out to be. Every
        // beat lands in the buffer; which words are wanted is decided on the
        // way out, because the response channel is five times slower than the
        // beats and cannot be made to keep up.
        S_READ: if (rd_data_valid) begin
          lbuf_lo[beat[3:0]] <= rd_data[31:0];
          lbuf_hi[beat[3:0]] <= rd_data[63:32];
          beat <= beat + 5'd1;
          if (beat == 5'd15) begin
            fill  <= p_off;
            left  <= p_len + 5'd1;
            state <= S_DRAIN;
          end
        end

        S_DRAIN: if (drain_go) begin
          fill <= fill + 5'd1;
          if (left == 5'd1) state <= S_IDLE;
          left <= left - 5'd1;
        end

        default: ;
      endcase
    end
  end

  // ---- responses, back into clk_sys ---------------------------------------
  logic             rspf_rempty;
  logic [RSP_W-1:0] rspf_rdata;
  psrsp_t           rsp_out;
  assign rsp_out = rspf_rdata;

  wire logic rspf_pop = !rspf_rempty;

  k2g_cdc_fifo #(.WIDTH(RSP_W), .DEPTH(RSP_DEPTH)) u_rspf (
      .wclk  (clk_out),
      .wrst_n(orst_n),
      .wpush (rspf_push),
      .wdata (rspf_wdata),
      .wfull (rspf_wfull),
      .rclk  (clk_sys),
      .rrst_n(rst_n),
      .rpop  (rspf_pop),
      .rdata (rspf_rdata),
      .rempty(rspf_rempty)
  );

  // Registered rather than combinational off the FIFO's array read: the
  // response is what the core's fetch buffer and load path see, and there is
  // no reason to hand them an asynchronous RAM output when a burst already
  // took two hundred cycles to arrive.
  logic        irsp_v, drsp_v;
  logic [31:0] rsp_data_q;

  always_ff @(posedge clk_sys) begin
    if (!rst_n) begin
      irsp_v <= 1'b0;
      drsp_v <= 1'b0;
    end else begin
      irsp_v <= rspf_pop && !rsp_out.src;
      drsp_v <= rspf_pop &&  rsp_out.src;
    end
  end

  always_ff @(posedge clk_sys) begin
    if (rspf_pop) rsp_data_q <= rsp_out.data;
  end

  assign ibus.rsp_valid = irsp_v;
  assign dbus.rsp_valid = drsp_v;
  assign ibus.rsp_data  = rsp_data_q;
  assign dbus.rsp_data  = rsp_data_q;

  // ---- calibration status, crossed as tokens ------------------------------
  logic calf_wfull, calf_rempty;

  // Four deep because that is the smallest k2g_cdc_fifo there is -- the
  // full-detect compares the top two pointer bits, which needs an address bit
  // under them. One entry would do.
  k2g_cdc_fifo #(.WIDTH(1), .DEPTH(4)) u_calf (
      .wclk  (clk_out),
      .wrst_n(orst_n),
      .wpush (init_calib && !calf_wfull),
      .wdata (1'b1),
      .wfull (calf_wfull),
      .rclk  (clk_sys),
      .rrst_n(rst_n),
      .rpop  (!calf_rempty),
      .rdata (),
      .rempty(calf_rempty)
  );

  always_ff @(posedge clk_sys) begin
    if (!rst_n)            calib <= 1'b0;
    else if (!calf_rempty) calib <= 1'b1;
  end

`ifdef SIMULATION
  // A write must produce no response (k2g_membus.sv) and the fetch port must
  // never write. Both are properties of the masters rather than of this
  // module, and both would show up here as silent corruption: an unasked-for
  // response desynchronizes the core's issue-address queue, and a write on
  // the fetch port would put 32 bits into memory from a port whose responses
  // the core reads as code points.
  always_ff @(posedge clk_sys) begin
    if (rst_n && ibus.req_valid && ibus.req_ready && (ibus.req.we != 4'b0000))
      $error("k2g_psram: write on the fetch port");
  end

  // A BURST IS ONE PSRAM COMMAND, so it must not cross a 128-byte boundary.
  // Wrapping instead of crossing is exactly the failure the length field was
  // introduced to make detectable: a line half-filled from two addresses
  // answers wrong forever from a tag that says it is valid.
  always_ff @(posedge clk_sys) begin
    if (rst_n && ibus.req_valid && ibus.req_ready &&
        ((32'(ibus.req.addr[6:2]) + 32'(ibus.req.len)) > 32'd31))
      $error("k2g_psram: ibus burst crosses a 128-byte boundary");
    if (rst_n && dbus.req_valid && dbus.req_ready && !wb_active &&
        ((32'(dbus.req.addr[6:2]) + 32'(dbus.req.len)) > 32'd31))
      $error("k2g_psram: dbus burst crosses a 128-byte boundary");
  end
`endif

endmodule
