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
// ---- one command at a time, and why that is not a mistake ----
//
// The controller's smallest transfer is a 128-byte burst: 16 user beats of 64
// bits, 32 word addresses (docs/bring-up.md, measured on hardware). A single
// 32-bit access therefore costs a whole burst, and this adapter issues one and
// throws 124 of the 128 bytes away.
//
// That is deliberate. Keeping a burst's worth of data would be a cache, and
// the caches are Phase 4 with tags, dirty bits, a refill path and a bus lock
// designed together. Half a cache built here would be sized against the wrong
// constraints and then thrown away. The machine runs -- slowly -- in the
// meantime, which is exactly what swapping Phases 3 and 4 was for.
//
// Cost of the choice: ~32 clk_out cycles per access, about 6 cycles of a
// 13.5 MHz core, plus the crossing each way.
//
// ---- the fetch port is 16 bits wide ----
//
// `ibus` responses carry a CODE POINT in bits [15:0], not a word. That is the
// contract k2g_mem's port A has always provided and k2g_core relies on
// (`f2d_in.data = {..., ibus.rsp_data[15:0]}`), so whatever answers the fetch
// port has to keep providing it. The select is by bit 1 of the request
// address, which is why requests carry addr[22:1] and not just the word.
//
// The tidier long-term home for that select is the core's fetch unit -- it
// already keeps `issue_addr` alongside each outstanding request, so it has the
// bit -- or the I-cache in front of it. Worth moving when Phase 4 touches both
// ends anyway; not worth a core change in the middle of this one.
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

    k2g_membus.slave ibus,      // instruction fetch: 16-bit responses
    k2g_membus.slave dbus,      // data: 32-bit responses, per-byte writes

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

  // Request address bits [22:1]: the 21-bit word address the controller wants,
  // plus the halfword bit the fetch port needs. 8 MB, which is the whole space
  // the IP addresses -- anything above it aliases, and does not arise because
  // the core faults ADDR_OUT_OF_RANGE first.
  localparam int HA_W = 22;

  typedef struct packed {
    logic            src;       // 1 = data bus, 0 = fetch
    logic [HA_W-1:0] haddr;     // request address [22:1]
    logic [3:0]      we;        // 0 = read
    logic [31:0]     wdata;
  } psreq_t;

  typedef struct packed {
    logic        src;
    logic [31:0] data;
  } psrsp_t;

  localparam int REQ_W = 1 + HA_W + 4 + 32;
  localparam int RSP_W = 1 + 32;

  // Four deep on the request side because the core's fetch credit is four and
  // every one of them can be outstanding at once on a bus this slow; the
  // response side only ever holds one, since the sequencer runs one command at
  // a time, and is four for symmetry.
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

  // Round robin: whoever lost the last tie wins the next one. Fixed priority
  // is one gate cheaper and was rejected -- with fetch first, a data access
  // waits behind a fetch stream that always has credit; with data first, a
  // store loop holds the bus for as long as it runs. Neither deadlocks, but
  // both make the machine's speed depend on which port is louder.
  wire logic want_i = ibus.req_valid;
  wire logic want_d = dbus.req_valid;

  wire logic pick_d = want_d && (!want_i || !last_d);
  wire logic pick_i = want_i && !pick_d;

  wire logic reqf_push = !reqf_wfull && (pick_i || pick_d);

  // A slave's `req_ready` may look at `req_valid` (k2g_membus.sv); a master's
  // `req_valid` may not look back.
  assign ibus.req_ready = !reqf_wfull && pick_i;
  assign dbus.req_ready = !reqf_wfull && pick_d;

  always_ff @(posedge clk_sys) begin
    if (!rst_n)         last_d <= 1'b0;
    else if (reqf_push) last_d <= pick_d;
  end

  psreq_t req_in;
  always_comb begin
    if (pick_d) begin
      req_in.src   = 1'b1;
      req_in.haddr = dbus.req.addr[HA_W:1];
      req_in.we    = dbus.req.we;
      req_in.wdata = dbus.req.wdata;
    end else begin
      req_in.src   = 1'b0;
      req_in.haddr = ibus.req.addr[HA_W:1];
      req_in.we    = 4'b0000;
      req_in.wdata = 32'd0;
    end
  end

  wire logic [REQ_W-1:0] reqf_wdata = req_in;

  logic                  reqf_rempty, reqf_pop;
  logic [REQ_W-1:0]      reqf_rdata;
  psreq_t                req_out;
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
  typedef enum logic [1:0] { S_IDLE, S_WRITE, S_READ } seq_e;

  seq_e            state;
  logic            p_src;
  logic [HA_W-1:0] p_haddr;
  logic [3:0]      p_we;
  logic [31:0]     p_wdata;
  logic [4:0]      beat;
  logic [5:0]      gap;

  wire logic [20:0] p_word = p_haddr[HA_W-1:1];   // request address [22:2]
  wire logic [3:0]  p_beat = p_word[4:1];         // which of the 16 beats
  wire logic        p_high = p_word[0];           // which 32-bit half of it

  logic             rspf_wfull, rspf_push;
  psrsp_t           rsp_in;
  wire  logic [RSP_W-1:0] rspf_wdata = rsp_in;

  // A guarded rule, per docs/v2-plan.md: every input, every output and every
  // resource the effect needs, named in one expression. `rspf_wfull` is in
  // here because a read's answer has nowhere to go otherwise -- it cannot
  // happen with one command in flight and a four-deep FIFO, and it is named
  // anyway, because a guard that has to name what it consumes is the only
  // reason this does not have to be re-argued later.
  wire logic can_issue = (state == S_IDLE)
                      && !reqf_rempty
                      && init_calib      // NOT cmd_rdy alone: that is high
                      && cmd_rdy         // before calibration ever finishes
                      && (gap == 6'd0)
                      && !rspf_wfull;

  assign reqf_pop = can_issue;

  // The burst containing the addressed word: 32 word addresses, aligned.
  assign addr = {p_word[20:5], 5'b00000};

  // Replicated into both halves so the mask alone decides where the bytes
  // land, and constant for the whole burst -- which it must be. `cmd_en` is
  // one cycle and the transfer it starts is sixteen; changing `wr_data` inside
  // that window is what made the hardware write-beat search report failure for
  // every candidate phase.
  assign wr_data = {p_wdata, p_wdata};

  // `1` masks, `0` writes, per byte of the 64-bit beat, sampled per beat.
  // Everything is masked except the four lanes of the one word being written,
  // on the one beat that holds it.
  always_comb begin
    data_mask = 8'hFF;
    if ((state == S_WRITE) && (beat == {1'b0, p_beat})) begin
      if (p_high) data_mask = {~p_we, 4'hF};
      else        data_mask = {4'hF, ~p_we};
    end
  end

  // Which 32 bits of the beat, and then which 16 of those if this was a fetch.
  wire logic [31:0] beat_word = p_high ? rd_data[63:32] : rd_data[31:0];
  wire logic [15:0] beat_half = p_haddr[0] ? beat_word[31:16] : beat_word[15:0];

  always_ff @(posedge clk_out) begin
    if (!orst_n) begin
      state     <= S_IDLE;
      cmd       <= 1'b0;
      cmd_en    <= 1'b0;
      p_src     <= 1'b0;
      p_haddr   <= '0;
      p_we      <= 4'b0000;
      p_wdata   <= 32'd0;
      beat      <= 5'd0;
      // Not zero. A reset can abandon a burst the controller is still
      // streaming, and the interval has to hold across that too.
      gap       <= TCMD;
      rspf_push <= 1'b0;
      rsp_in    <= '0;
    end else begin
      cmd_en    <= 1'b0;
      rspf_push <= 1'b0;
      if (gap != 6'd0) gap <= gap - 6'd1;

      unique case (state)
        S_IDLE: if (can_issue) begin
          p_src   <= req_out.src;
          p_haddr <= req_out.haddr;
          p_we    <= req_out.we;
          p_wdata <= req_out.wdata;
          cmd     <= |req_out.we;          // IPUG943: 1 write, 0 read
          cmd_en  <= 1'b1;
          gap     <= TCMD;
          beat    <= 5'd0;
          state   <= (|req_out.we) ? S_WRITE : S_READ;
        end

        // Write beat 0 is the cycle `cmd_en` is high -- lead 0, searched for
        // on hardware rather than assumed. `cmd_en` is registered, so it and
        // `beat == 0` land together, and beats 1..15 follow one per cycle.
        S_WRITE: begin
          beat <= beat + 5'd1;
          if (beat == 5'd15) state <= S_IDLE;
        end

        // Reads are self-timed: the beat index is the count of `rd_data_valid`
        // pulses, whatever the controller's latency turns out to be. The
        // answer goes out as soon as its beat arrives, but the state stays
        // here until all sixteen have, so a leftover pulse can never be
        // counted against the next command.
        S_READ: if (rd_data_valid) begin
          beat <= beat + 5'd1;
          if (beat == {1'b0, p_beat}) begin
            rspf_push   <= 1'b1;
            rsp_in.src  <= p_src;
            rsp_in.data <= p_src ? beat_word : {16'd0, beat_half};
          end
          if (beat == 5'd15) state <= S_IDLE;
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
  // are 16.
  always_ff @(posedge clk_sys) begin
    if (rst_n && ibus.req_valid && ibus.req_ready && (ibus.req.we != 4'b0000))
      $error("k2g_psram: write on the fetch port");
  end
`endif

endmodule
