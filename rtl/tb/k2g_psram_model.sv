// A behavioural stand-in for PSRAM_Memory_Interface_HS_Top.
//
// The real IP cannot be simulated usefully: nothing in the Gowin install
// models the W955D8MBYA, so calibration reads back a strobe that never arrives
// and `init_calib` never rises (docs/bring-up.md, and rtl/tb/tb_psram.sv which
// exists to say how far it does get). A controller that never calibrates
// cannot be used to test an adapter that waits for calibration.
//
// So this models the user side instead, and only the user side. It is written
// from the table of MEASURED properties in docs/bring-up.md -- every line of
// which cost a flash of the board -- rather than from the user guide:
//
//   * `addr` is a word address, 4 bytes per word, 21 bits = 8 MB;
//   * a burst is 128 bytes: 16 user beats of 64 bits over 32 word addresses,
//     aligned down to a multiple of 32;
//   * `cmd` is 0 read, 1 write;
//   * write beat 0 is the same cycle as `cmd_en` -- lead 0 -- and the data
//     must be held for all sixteen;
//   * `data_mask` is per byte of the beat, 1 masks and 0 writes, and is
//     sampled per beat;
//   * reads are self-timed: `rd_data_valid` for sixteen beats, beat 0 first;
//   * `cmd_rdy` is high before `init_calib` and is not a ready-to-use gate;
//   * `clk_out` is `memory_clk / 2`.
//
// WHAT IT IS FOR is as much the checking as the answering. The three ways to
// drive this controller wrongly all corrupt memory silently on hardware and
// all of them are errors here:
//
//   * a command inside the minimum interval (26 user clocks at burst 64,
//     IPUG943 Table 4-2), which `cmd_rdy` does not enforce and which the probe
//     violated for two revisions before anyone noticed;
//   * a command while the previous burst is still streaming;
//   * a command before `init_calib`.
//
// And it reproduces the trap directly rather than checking for it: write data
// is sampled per beat, so an adapter that lets `wr_data` move mid-burst writes
// the wrong bytes here exactly as it would on the board.
//
// WHAT IT IS NOT. It is not the IP. It does not model calibration, the memory
// clock, the device protocol, refresh, or anything on the far side of the
// pins, and passing against it says nothing about whether the real controller
// is configured correctly -- that is what the psram bring-up stage is for. It
// models the contract the adapter is written against, so that a change to the
// adapter can be checked against the contract without a flash.

`timescale 1ns/1ps

module PSRAM_Memory_Interface_HS_Top #(
    // Real calibration takes hundreds of microseconds. Shortened here, but not
    // to zero: requests arriving before calibration and having to wait is a
    // path worth exercising, because on a real board every request does.
    parameter int CALIB_CYCLES = 200,

    // "Fixed Latency", initial latency 6. The adapter must not depend on this
    // number -- reads are self-timed -- so it is a parameter partly so a test
    // can move it and prove that.
    parameter int RD_LATENCY = 6,

    // IPUG943 Table 4-2, burst 64.
    parameter int TCMD_MIN = 26
) (
    input  wire        clk,
    input  wire        memory_clk,
    input  wire        pll_lock,
    input  wire        rst_n,

    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    inout  wire [15:0] IO_psram_dq,
    inout  wire [1:0]  IO_psram_rwds,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,

    input  wire [63:0] wr_data,
    output reg  [63:0] rd_data,
    output reg         rd_data_valid,
    input  wire [20:0] addr,
    input  wire        cmd,
    input  wire        cmd_en,
    output wire        cmd_rdy,
    output reg         init_calib,
    output reg         clk_out,
    input  wire [7:0]  data_mask
);

  // ---- clocks and calibration ---------------------------------------------
  initial clk_out = 1'b0;
  always @(posedge memory_clk) clk_out <= ~clk_out;

  integer calib_cnt;

  always @(posedge clk_out or negedge rst_n) begin
    if (!rst_n) begin
      calib_cnt  <= 0;
      init_calib <= 1'b0;
    end else if (!pll_lock) begin
      calib_cnt  <= 0;
      init_calib <= 1'b0;
    end else if (calib_cnt < CALIB_CYCLES) begin
      calib_cnt <= calib_cnt + 1;
    end else begin
      init_calib <= 1'b1;
    end
  end

  // Measured: high before calibration completes, so it is not a "ready to use"
  // gate and an adapter that treats it as one issues commands into a
  // controller that is not listening.
  assign cmd_rdy = 1'b1;

  // ---- storage ------------------------------------------------------------
  // Associative, so 8 MB costs only what the test touches -- and so a read of
  // a location nothing ever wrote returns X rather than a plausible zero.
  logic [31:0] store [logic [20:0]];

  function automatic logic [31:0] word_at(input logic [20:0] a);
    if (store.exists(a)) return store[a];
    else                 return 32'hxxxx_xxxx;
  endfunction

  // ---- burst state --------------------------------------------------------
  reg        w_active, r_active;
  reg [4:0]  w_beat, r_beat;
  reg [20:0] w_base, r_base;
  integer    r_wait;

  wire busy = w_active || r_active;

  // Cycle counter purely for the interval check.
  integer cyc, last_cmd_cyc;

  task automatic apply_beat(input logic [20:0] base,
                            input logic [4:0]  b,
                            input logic [63:0] d,
                            input logic [7:0]  m);
    logic [20:0] lo_a, hi_a;
    logic [31:0] lo_v, hi_v;
    int          i;
    begin
      // Beat b holds word base+2b in its low half and base+2b+1 in its high.
      lo_a = base + {15'd0, b, 1'b0};
      hi_a = lo_a + 21'd1;
      lo_v = word_at(lo_a);
      hi_v = word_at(hi_a);
      for (i = 0; i < 4; i++) begin
        if (!m[i])     lo_v[i*8 +: 8] = d[i*8 +: 8];
        if (!m[4 + i]) hi_v[i*8 +: 8] = d[32 + i*8 +: 8];
      end
      if (m[3:0] != 4'hF) store[lo_a] = lo_v;
      if (m[7:4] != 4'hF) store[hi_a] = hi_v;
    end
  endtask

  always @(posedge clk_out or negedge rst_n) begin
    if (!rst_n) begin
      w_active      <= 1'b0;
      r_active      <= 1'b0;
      w_beat        <= 5'd0;
      r_beat        <= 5'd0;
      r_wait        <= 0;
      rd_data_valid <= 1'b0;
      rd_data       <= 64'd0;
      cyc           <= 0;
      last_cmd_cyc  <= -1000;
    end else begin
      cyc           <= cyc + 1;
      rd_data_valid <= 1'b0;

      if (cmd_en) begin
        if (!init_calib)
          $error("psram model: command at cycle %0d, before init_calib", cyc);
        // What the controller does with a command whose address is not on a
        // 32-word boundary is NOT MEASURED. The hardware geometry probe read
        // word 24 of a burst written at word 0 and got the right answer, which
        // is consistent both with the controller aligning internally and with
        // it starting the burst there -- the probe's own comment says so. The
        // adapter aligns, so the question never arises; this refuses to guess
        // an answer rather than inventing one a test could then rely on.
        if (addr[4:0] != 5'd0)
          $error("psram model: command address %0h is not burst-aligned", addr);
        if (busy)
          $error("psram model: command at cycle %0d while a burst is still streaming", cyc);
        if ((cyc - last_cmd_cyc) < TCMD_MIN)
          $error("psram model: commands %0d cycles apart, minimum is %0d",
                 cyc - last_cmd_cyc, TCMD_MIN);
        last_cmd_cyc <= cyc;
      end

      // ---- writes: beat 0 is this cycle, lead 0 ----
      if (cmd_en && cmd) begin
        apply_beat({addr[20:5], 5'b00000}, 5'd0, wr_data, data_mask);
        w_base   <= {addr[20:5], 5'b00000};
        w_beat   <= 5'd1;
        w_active <= 1'b1;
      end else if (w_active) begin
        apply_beat(w_base, w_beat, wr_data, data_mask);
        if (w_beat == 5'd15) w_active <= 1'b0;
        w_beat <= w_beat + 5'd1;
      end

      // ---- reads: fixed latency, then sixteen beats ----
      if (cmd_en && !cmd) begin
        r_base   <= {addr[20:5], 5'b00000};
        r_wait   <= RD_LATENCY;
        r_beat   <= 5'd0;
        r_active <= 1'b1;
      end else if (r_active) begin
        if (r_wait > 0) begin
          r_wait <= r_wait - 1;
        end else begin
          rd_data_valid <= 1'b1;
          rd_data       <= {word_at(r_base + {15'd0, r_beat, 1'b1}),
                            word_at(r_base + {15'd0, r_beat, 1'b0})};
          if (r_beat == 5'd15) r_active <= 1'b0;
          r_beat <= r_beat + 5'd1;
        end
      end
    end
  end

  // ---- pins ---------------------------------------------------------------
  // Present so the port list matches the IP's; nothing on the far side is
  // modelled.
  assign O_psram_ck      = {2{clk_out}};
  assign O_psram_ck_n    = {2{~clk_out}};
  assign O_psram_cs_n    = busy ? 2'b00 : 2'b11;
  assign O_psram_reset_n = {2{rst_n}};
  assign IO_psram_dq     = 16'bz;
  assign IO_psram_rwds   = 2'bz;

  // `clk` is the IP's 27 MHz reference. Measured on the real netlist: 155 of
  // its flip-flops are on clk_out and the 14 on clk are the reset chain, so
  // nothing the user side sees comes from it.
  wire _unused = &{1'b0, clk};

endmodule
