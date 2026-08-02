// The PSRAM adapter against a behavioural controller.
//
// What this can and cannot prove is worth being clear about up front, because
// the module under test is the one place in the design where a passing
// simulation is least conclusive.
//
// CANNOT: anything about the clock crossing. Metastability does not exist in a
// zero-delay simulator, so an adapter that sampled a multi-bit value mid-flight
// would pass every line of this. That property is carried by there being
// exactly one crossing primitive (k2g_cdc_fifo, gray-coded and doubly
// synchronized), by rtl/tb/tb_cdc_fifo.sv for everything about it that IS
// testable, and by the .sdc declaring the domains asynchronous.
//
// CAN, and these are the ones that would otherwise only be checked by
// argument:
//
//   * a 32-bit access lands in the right beat and the right half of it. The
//     controller's smallest transfer is 128 bytes and the adapter writes four
//     of them, so getting the mask wrong does not lose the write -- it writes
//     the right bytes somewhere else and clobbers a neighbour. Writing 32
//     consecutive words one at a time and reading all of them back is the
//     direct test of that, and it is the same experiment the hardware
//     write-beat search ran;
//   * partial writes, in both halves of a beat. `data_mask` is per byte of 64
//     and the request's byte enables are per byte of 32, so there are two ways
//     to be off by four lanes;
//   * responses go to the bus that asked, in order, with two masters
//     interleaving through one in-order sequencer;
//   * the fetch port gets a 16-bit code point selected by address bit 1;
//   * requests made before calibration are queued and answered rather than
//     lost -- which on a real board is every request, for the first few
//     hundred microseconds.
//
// The model checks the other direction: minimum command interval, no command
// before calibration, no command into a burst that is still streaming. Those
// are errors from inside k2g_psram_model.sv and fail the run.

`include "k2g_types.svh"
`timescale 1ns/1ps

module tb_psram_adapter
  import k2g_types::*;
;

  // 13.5 MHz core, 135 MHz memory clock -> 67.5 MHz clk_out. Deliberately
  // rounded so the ratio is not exactly 5 and the edges drift against each
  // other over the run.
  localparam real SYS_HALF = 37.037;    // ns
  localparam real MEM_HALF = 3.704;     // ns

  logic clk_sys    = 1'b0;
  logic memory_clk = 1'b0;
  logic rst_n      = 1'b0;
  logic pll_lock   = 1'b0;
  logic ctrl_rst_n = 1'b0;

  always #SYS_HALF clk_sys    = ~clk_sys;
  always #MEM_HALF memory_clk = ~memory_clk;

  // ---- device under test --------------------------------------------------
  k2g_membus ibus ();
  k2g_membus dbus ();

  logic        clk_out, init_calib, cmd_rdy;
  logic        cmd, cmd_en, rd_data_valid;
  logic [20:0] addr;
  logic [63:0] wr_data, rd_data;
  logic [7:0]  data_mask;
  logic        calib;

  wire [1:0]  psram_ck, psram_ck_n, psram_cs_n, psram_reset_n;
  wire [15:0] psram_dq;
  wire [1:0]  psram_rwds;

  k2g_psram dut (
      .clk_sys      (clk_sys),
      .rst_n        (rst_n),
      .ibus         (ibus),
      .dbus         (dbus),
      .calib        (calib),
      .clk_out      (clk_out),
      .init_calib   (init_calib),
      .cmd_rdy      (cmd_rdy),
      .cmd          (cmd),
      .cmd_en       (cmd_en),
      .addr         (addr),
      .wr_data      (wr_data),
      .data_mask    (data_mask),
      .rd_data      (rd_data),
      .rd_data_valid(rd_data_valid)
  );

  // Shortened calibration -- 80 clk_out cycles rather than the real hundreds
  // of microseconds -- but not zero, so the "requests before calibration" path
  // is still exercised.
  PSRAM_Memory_Interface_HS_Top #(.CALIB_CYCLES(80)) u_ctrl (
      .clk            (1'b0),
      .memory_clk     (memory_clk),
      .pll_lock       (pll_lock),
      .rst_n          (ctrl_rst_n),
      .O_psram_ck     (psram_ck),
      .O_psram_ck_n   (psram_ck_n),
      .IO_psram_dq    (psram_dq),
      .IO_psram_rwds  (psram_rwds),
      .O_psram_cs_n   (psram_cs_n),
      .O_psram_reset_n(psram_reset_n),
      .wr_data        (wr_data),
      .rd_data        (rd_data),
      .rd_data_valid  (rd_data_valid),
      .addr           (addr),
      .cmd            (cmd),
      .cmd_en         (cmd_en),
      .cmd_rdy        (cmd_rdy),
      .init_calib     (init_calib),
      .clk_out        (clk_out),
      .data_mask      (data_mask)
  );

  // ---- scoreboard ---------------------------------------------------------
  int checks = 0;
  int errors = 0;

  task automatic fail(input string msg);
    $display("TB_FAIL tb_psram_adapter: %s", msg);
    errors++;
  endtask

  // A shadow of what memory should hold. Unwritten words are X on both sides,
  // so a partial write to a word nothing has written yet compares equal
  // instead of quietly agreeing on a zero neither machine promised.
  logic [31:0] shadow [logic [20:0]];

  function automatic logic [31:0] sh_word(input logic [20:0] w);
    if (shadow.exists(w)) return shadow[w];
    else                  return 32'hxxxx_xxxx;
  endfunction

  mem_req_t    iq[$], dq[$];
  logic [31:0] iexp[$], dexp[$];

  // Expectations are computed when a request is ENQUEUED, not when it is
  // issued, which is only sound because each bus is answered in order and the
  // stimulus never leaves a write to a word outstanding while the other bus
  // reads it. The interleaved phase keeps the two on disjoint regions for
  // exactly that reason.
  task automatic q_write(input logic [31:0] a, input logic [3:0] we,
                         input logic [31:0] d);
    mem_req_t    r;
    logic [20:0] w;
    logic [31:0] v;
    int          i;
    r.addr  = a;
    r.we    = we;
    r.wdata = d;
    dq.push_back(r);
    w = a[22:2];
    v = sh_word(w);
    for (i = 0; i < 4; i++) if (we[i]) v[i*8 +: 8] = d[i*8 +: 8];
    shadow[w] = v;
  endtask

  task automatic q_read_d(input logic [31:0] a);
    mem_req_t r;
    r.addr  = a;
    r.we    = 4'b0000;
    r.wdata = 32'd0;
    dq.push_back(r);
    dexp.push_back(sh_word(a[22:2]));
  endtask

  task automatic q_read_i(input logic [31:0] a);
    mem_req_t    r;
    logic [31:0] w;
    r.addr  = a;
    r.we    = 4'b0000;
    r.wdata = 32'd0;
    iq.push_back(r);
    w = sh_word(a[22:2]);
    iexp.push_back(a[1] ? {16'd0, w[31:16]} : {16'd0, w[15:0]});
  endtask

  // ---- drivers ------------------------------------------------------------
  logic     ireq_v, dreq_v;
  mem_req_t ireq, dreq;

  assign ibus.req_valid = ireq_v;
  assign ibus.req       = ireq;
  assign dbus.req_valid = dreq_v;
  assign dbus.req       = dreq;

  always_ff @(posedge clk_sys) begin
    if (!rst_n) begin
      ireq_v <= 1'b0;
    end else if (!ireq_v || ibus.req_ready) begin
      if (iq.size() > 0) begin
        ireq   <= iq.pop_front();
        ireq_v <= 1'b1;
      end else begin
        ireq_v <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_sys) begin
    if (!rst_n) begin
      dreq_v <= 1'b0;
    end else if (!dreq_v || dbus.req_ready) begin
      if (dq.size() > 0) begin
        dreq   <= dq.pop_front();
        dreq_v <= 1'b1;
      end else begin
        dreq_v <= 1'b0;
      end
    end
  end

  // ---- checkers -----------------------------------------------------------
  // Plain `always`, not `always_ff`: the run below also counts checks that are
  // not responses, and always_ff would make that a second driver.
  always @(posedge clk_sys) begin
    if (rst_n && ibus.rsp_valid) begin
      if (iexp.size() == 0) begin
        fail($sformatf("ibus response %08x nobody asked for", ibus.rsp_data));
      end else begin
        checks++;
        if (ibus.rsp_data !== iexp[0])
          fail($sformatf("ibus expected %08x, got %08x", iexp[0], ibus.rsp_data));
        void'(iexp.pop_front());
      end
    end
    if (rst_n && dbus.rsp_valid) begin
      if (dexp.size() == 0) begin
        fail($sformatf("dbus response %08x nobody asked for", dbus.rsp_data));
      end else begin
        checks++;
        if (dbus.rsp_data !== dexp[0])
          fail($sformatf("dbus expected %08x, got %08x", dexp[0], dbus.rsp_data));
        void'(dexp.pop_front());
      end
    end
  end

  task automatic drain(input string what);
    int n;
    n = 0;
    while ((iq.size() > 0 || dq.size() > 0 || iexp.size() > 0 ||
            dexp.size() > 0 || ireq_v || dreq_v) && n < 200000) begin
      @(posedge clk_sys);
      n++;
    end
    if (n >= 200000) fail($sformatf("%s: timed out with %0d responses owed",
                                    what, iexp.size() + dexp.size()));
    // A write produces no response, so the last one may still be streaming.
    repeat (40) @(posedge clk_sys);
  endtask

  // ---- the run ------------------------------------------------------------
  localparam logic [31:0] BURST_A = 32'h0000_2000;   // burst-aligned
  localparam logic [31:0] BURST_B = 32'h0000_2080;   // the next burst along
  localparam logic [31:0] FETCH_R = 32'h0000_4000;   // read by ibus only
  localparam logic [31:0] DATA_R  = 32'h0010_0000;   // written by dbus only
  localparam logic [31:0] TOP_W   = 32'h007F_FFFC;   // last word of the 8 MB

  int i;

  initial begin
    rst_n      = 1'b0;
    ctrl_rst_n = 1'b0;
    pll_lock   = 1'b0;
    repeat (4) @(posedge clk_sys);
    pll_lock   = 1'b1;
    repeat (4) @(posedge clk_sys);
    rst_n      = 1'b1;
    ctrl_rst_n = 1'b1;

    // ---- before calibration ----
    // Issued immediately, while init_calib is still low. They must queue and
    // be answered, not disappear; the model errors if a command reaches it
    // early.
    q_write(BURST_A, 4'b1111, 32'hFEED_0001);
    q_read_d(BURST_A);
    drain("pre-calibration");

    if (!calib) fail("calibration never reported into the core's domain");
    checks++;

    // ---- one whole burst, a word at a time ----
    // 32 words is exactly the span of one 128-byte burst, so this walks every
    // beat index and both halves of each. Each write is its own burst command
    // with one word unmasked: if the mask or the beat were off, a later write
    // would land on an earlier word and the readback would find it.
    for (i = 0; i < 32; i++)
      q_write(BURST_A + 32'(4 * i), 4'b1111, 32'hA5A5_0000 + 32'(i));
    drain("burst fill");

    for (i = 0; i < 32; i++)
      q_read_d(BURST_A + 32'(4 * i));
    drain("burst readback");

    // ---- the neighbouring burst is a different burst ----
    for (i = 0; i < 4; i++)
      q_write(BURST_B + 32'(4 * i), 4'b1111, 32'h1234_0000 + 32'(i));
    drain("second burst");
    for (i = 0; i < 4; i++) q_read_d(BURST_B + 32'(4 * i));
    for (i = 0; i < 4; i++) q_read_d(BURST_A + 32'(4 * i));
    drain("second burst readback");

    // ---- partial writes, in both halves of a beat ----
    // Word 8 of the burst is even, so it sits in the low 32 bits of beat 4;
    // word 9 is odd and sits in the high 32. The byte enables have to be
    // shifted by four lanes for one and not the other.
    q_write(BURST_A + 32'd32, 4'b1111, 32'hDDCC_BBAA);
    q_write(BURST_A + 32'd36, 4'b1111, 32'h8877_6655);
    drain("partial setup");

    q_write(BURST_A + 32'd32, 4'b0001, 32'h0000_0011);   // byte 0, low half
    q_write(BURST_A + 32'd36, 4'b0001, 32'h0000_0022);   // byte 0, high half
    drain("byte writes");
    q_read_d(BURST_A + 32'd32);
    q_read_d(BURST_A + 32'd36);
    drain("byte readback");

    q_write(BURST_A + 32'd32, 4'b1100, 32'h9999_0000);   // halfword, low half
    q_write(BURST_A + 32'd36, 4'b0110, 32'h00EE_EE00);   // middle two bytes
    drain("halfword writes");
    q_read_d(BURST_A + 32'd32);
    q_read_d(BURST_A + 32'd36);
    drain("halfword readback");

    // ---- the fetch port is 16 bits ----
    q_write(FETCH_R,        4'b1111, 32'hBEEF_CAFE);
    q_write(FETCH_R + 32'd4, 4'b1111, 32'h0BAD_F00D);
    drain("fetch setup");

    q_read_i(FETCH_R);            // expects 0000_CAFE
    q_read_i(FETCH_R + 32'd2);    // expects 0000_BEEF
    q_read_i(FETCH_R + 32'd4);    // expects 0000_F00D
    q_read_i(FETCH_R + 32'd6);    // expects 0000_0BAD
    drain("fetch readback");

    // ---- both masters at once ----
    // Disjoint regions, both queues loaded before either drains, so the
    // arbiter has something to choose between on nearly every cycle. Responses
    // must come back on the bus that asked and in that bus's own order.
    for (i = 0; i < 8; i++)
      q_write(DATA_R + 32'(4 * i), 4'b1111, 32'hC0DE_0000 + 32'(i));
    drain("interleave setup");

    for (i = 0; i < 8; i++) begin
      q_read_i(FETCH_R + 32'(2 * i));
      q_read_d(DATA_R + 32'(4 * i));
    end
    drain("interleaved");

    // ---- the top of the address space ----
    q_write(TOP_W, 4'b1111, 32'h5A5A_F00F);
    drain("top-of-range write");
    q_read_d(TOP_W);
    q_read_i(TOP_W + 32'd2);
    drain("top-of-range readback");

    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("TB_PASS tb_psram_adapter");
    else             $display("TB_FAIL tb_psram_adapter: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #500000000;
    $display("TB_FAIL tb_psram_adapter: timeout");
    $finish;
  end

endmodule
