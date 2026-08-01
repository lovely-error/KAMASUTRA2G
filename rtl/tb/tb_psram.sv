// Does the PSRAM controller do anything at all?
//
// On hardware `init_calib` never rises: the PLL locks and clk_out runs, but
// calibration never completes. This drives the IP's post-place-and-route model
// (psram_memory_interface_hs.vo, plain Gowin primitives plus prim_sim.v) to
// find out how far it gets.
//
// THERE IS NO MEMORY MODEL. Nothing in the Gowin install models the
// W955D8MBYA, so `IO_psram_dq` and `IO_psram_rwds` float. Calibration reads
// back a read strobe that never arrives and cannot converge, so init_calib is
// NOT expected to rise here. That is fine -- the question this answers is a
// different one:
//
//   * does the controller ever drive the bus at all?   (cs_n falling)
//   * does it toggle the memory clock?                 (ck transitions)
//   * does it get as far as asking for anything?
//
// A controller that never lowers `cs_n` is stuck before it reaches the memory,
// which is a problem in the fabric -- clocks, reset, the IP's own state
// machine. One that drives the bus and then waits is stuck ON the memory, and
// on hardware that points at the device, the pin assignment or the calibration
// parameters instead. Those are very different next steps, which is why this
// is worth running without a device model.

`timescale 100ps/100ps

module tb_psram;

  // The IP's model is compiled at 100 ps resolution, so periods are in those
  // units. 27 MHz is 370.4; 135 MHz is 74.07.
  localparam int CLK27_HALF = 185;   // 37.0 ns period
  localparam int MEMCLK_HALF = 37;   // 7.4 ns period -> ~135.1 MHz

  logic clk_27m    = 1'b0;
  logic memory_clk = 1'b0;
  logic pll_lock   = 1'b0;
  logic rst_n      = 1'b0;

  always #CLK27_HALF  clk_27m    = ~clk_27m;
  always #MEMCLK_HALF memory_clk = ~memory_clk;

  logic [1:0]  O_psram_ck, O_psram_ck_n, O_psram_cs_n, O_psram_reset_n;
  wire  [15:0] IO_psram_dq;
  wire  [1:0]  IO_psram_rwds;

  logic [63:0] wr_data = 64'd0;
  logic [63:0] rd_data;
  logic        rd_data_valid;
  logic [20:0] addr = 21'd0;
  logic        cmd = 1'b0, cmd_en = 1'b0;
  logic        cmd_rdy, init_calib, clk_out;
  logic [7:0]  data_mask = 8'h00;

  PSRAM_Memory_Interface_HS_Top dut (
      .clk            (clk_27m),
      .memory_clk     (memory_clk),
      .pll_lock       (pll_lock),
      .rst_n          (rst_n),
      .O_psram_ck     (O_psram_ck),
      .O_psram_ck_n   (O_psram_ck_n),
      .IO_psram_dq    (IO_psram_dq),
      .IO_psram_rwds  (IO_psram_rwds),
      .O_psram_cs_n   (O_psram_cs_n),
      .O_psram_reset_n(O_psram_reset_n),
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

  // ---- observations ------------------------------------------------------
  int  ck_edges     = 0;
  int  clkout_edges = 0;
  time first_cs_low = 0;
  time calib_at     = 0;

  always @(O_psram_ck[0]) ck_edges++;
  always @(posedge clk_out) clkout_edges++;

  always @(negedge O_psram_cs_n[0]) begin
    if (first_cs_low == 0) begin
      first_cs_low = $time;
      $display("  cs_n[0] first driven low at %0t", $time);
    end
  end

  always @(posedge init_calib) begin
    calib_at = $time;
    $display("  init_calib rose at %0t", $time);
  end

  initial begin
    $display("tb_psram: no memory device model -- calibration is not expected");
    $display("          to complete. Watching how far the controller gets.");

    // Reset held while the PLL settles, exactly as k2g_psram_probe does.
    rst_n    = 1'b0;
    pll_lock = 1'b0;
    #20000;                     // 2 us
    pll_lock = 1'b1;
    #100000;                    // 10 us of lock before release
    rst_n    = 1'b1;

    // Long enough for initialization and read calibration many times over.
    #20000000;                  // 2 ms

    $display("");
    $display("after 2 ms:");
    $display("  clk_out edges      %0d %s", clkout_edges,
             clkout_edges > 0 ? "" : "  <-- user clock never ran");
    $display("  O_psram_ck edges   %0d %s", ck_edges,
             ck_edges > 0 ? "" : "  <-- memory clock never driven");
    $display("  cs_n first low     %0t %s", first_cs_low,
             first_cs_low > 0 ? "" : "  <-- controller never addressed the memory");
    $display("  cmd_rdy            %0b", cmd_rdy);
    $display("  init_calib         %0b", init_calib);

    if (first_cs_low == 0)
      $display("VERDICT: stuck BEFORE the memory -- clocks, reset or the IP's own FSM.");
    else if (!init_calib)
      $display("VERDICT: reaches the memory and waits -- consistent with no device model here, and on hardware points at the device, pins or calibration parameters.");
    else
      $display("VERDICT: calibration completed even without a device model.");

    $finish;
  end

endmodule
