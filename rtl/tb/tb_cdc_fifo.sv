// Directed test for the clock-domain-crossing FIFO.
//
// Simulation cannot prove a CDC correct -- metastability does not exist in a
// zero-delay event simulator, so a design that samples a multi-bit value
// mid-flight behaves perfectly here and fails on a board. What simulation CAN
// check is everything else, and those are the parts that would otherwise only
// be checked by argument:
//
//   * nothing is lost, duplicated or reordered across the crossing;
//   * `wfull` and `rempty` are honest, so the FIFO never overflows or
//     underflows (both assert inside the design if they do);
//   * it works with the clocks in either ratio, and at a ratio that is not an
//     integer -- the real pair are 13.5 and 67.5 MHz, but a design that
//     quietly relies on a whole-number ratio would pass at 1:5 and fail on a
//     board whose PLL drifts.
//
// The one structural property worth stating because it is NOT tested here:
// pointers must be gray coded and doubly synchronized. That is checked by
// reading k2g_cdc_fifo.sv, and by the .sdc declaring the clocks asynchronous.

module tb_cdc_fifo;

  localparam int WIDTH = 32;
  localparam int DEPTH = 8;
  localparam int N     = 2000;

  logic wclk = 0, rclk = 0;
  logic wrst_n = 0, rrst_n = 0;

  // Deliberately not an integer ratio: 7 against 23 time units.
  always #7  wclk = ~wclk;
  always #23 rclk = ~rclk;

  logic              wpush, wfull;
  logic [WIDTH-1:0]  wdata;
  logic              rpop, rempty;
  logic [WIDTH-1:0]  rdata;

  k2g_cdc_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
      .wclk(wclk), .wrst_n(wrst_n), .wpush(wpush), .wdata(wdata), .wfull(wfull),
      .rclk(rclk), .rrst_n(rrst_n), .rpop(rpop), .rdata(rdata), .rempty(rempty)
  );

  // ---- producer ----------------------------------------------------------
  int sent = 0;
  int unsigned wlfsr = 32'hACE1_2345;

  assign wdata = 32'(sent);
  assign wpush = !wfull && (wlfsr[2:0] != 3'd0) && (sent < N);

  always @(posedge wclk) begin
    if (!wrst_n) begin
      sent <= 0;
    end else begin
      wlfsr <= {wlfsr[30:0], wlfsr[31] ^ wlfsr[21] ^ wlfsr[1] ^ wlfsr[0]};
      if (wpush && !wfull) sent <= sent + 1;
    end
  end

  // ---- consumer ----------------------------------------------------------
  int recv = 0;
  int errors = 0;
  int unsigned rlfsr = 32'h1357_9BDF;

  assign rpop = !rempty && (rlfsr[3:0] != 4'd0);

  always @(posedge rclk) begin
    if (!rrst_n) begin
      recv <= 0;
    end else begin
      rlfsr <= {rlfsr[30:0], rlfsr[31] ^ rlfsr[21] ^ rlfsr[1] ^ rlfsr[0]};
      if (rpop && !rempty) begin
        if (rdata !== 32'(recv)) begin
          $display("TB_FAIL tb_cdc_fifo: expected %0d, got %0d", recv, rdata);
          errors <= errors + 1;
        end
        recv <= recv + 1;
      end
    end
  end

  // ---- run ---------------------------------------------------------------
  int guard;

  initial begin
    wrst_n = 0; rrst_n = 0;
    repeat (8) @(posedge rclk);
    wrst_n = 1; rrst_n = 1;

    guard = 0;
    while (recv < N && guard < 4000000) begin
      @(posedge rclk);
      guard++;
    end

    if (recv < N) begin
      $display("TB_FAIL tb_cdc_fifo: only %0d of %0d crossed", recv, N);
      errors++;
    end

    // Both sides must agree on how many items existed.
    if (sent != recv) begin
      $display("TB_FAIL tb_cdc_fifo: wrote %0d but read %0d", sent, recv);
      errors++;
    end

    $display("checks=%0d errors=%0d (%0d items, w:r clock ratio 23:7)",
             recv + 2, errors, recv);
    if (errors == 0) $display("TB_PASS tb_cdc_fifo");
    else             $display("TB_FAIL tb_cdc_fifo: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #200000000;
    $display("TB_FAIL tb_cdc_fifo: timeout");
    $finish;
  end

endmodule
