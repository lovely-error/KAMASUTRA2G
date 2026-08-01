// Directed test for the channel skid buffer.
//
// Checks the three things the rest of v2 relies on and nothing else:
// no item is lost, duplicated or reordered under arbitrary backpressure; full
// throughput is available when downstream never stalls; and `up.ready` is not
// a function of `down.ready`.
//
// The last one is the reason this testbench exists. A skid buffer that passes
// a lossless-transfer test can still have a combinational path from
// `down.ready` to `up.ready`, and that does not fail in simulation at all --
// it fails later as an unroutable timing path, or as the loop the
// single-cycle core already hit once (see k2g_chan.sv, rule 3).

module tb_chan;

  localparam int WIDTH = 16;
  localparam int N     = 500;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  k2g_chan #(.WIDTH(WIDTH)) up ();
  k2g_chan #(.WIDTH(WIDTH)) down ();

  k2g_skid #(.WIDTH(WIDTH)) dut (
      .clk  (clk),
      .rst_n(rst_n),
      .up   (up),
      .down (down)
  );

  // ---- stall patterns ----------------------------------------------------
  // `open` lifts both stall patterns for the throughput measurement. Two
  // independent LFSRs otherwise: a producer and consumer that stall together
  // never fill the skid entry, which is the only state in which the second
  // entry does anything at all.
  bit          open = 0;
  int unsigned lfsr_a = 32'h1234_5678;
  int unsigned lfsr_b = 32'h9E37_79B9;

  always @(posedge clk) begin
    lfsr_a <= {lfsr_a[30:0], lfsr_a[31] ^ lfsr_a[21] ^ lfsr_a[1] ^ lfsr_a[0]};
    lfsr_b <= {lfsr_b[30:0], lfsr_b[31] ^ lfsr_b[21] ^ lfsr_b[1] ^ lfsr_b[0]};
  end

  // The producer's offer is a function of its own pattern only. It must not
  // consult `down.ready`, or the test would satisfy rule 3 by accident.
  wire logic want_send = open || (lfsr_a[3:0] != 4'd0);
  wire logic want_recv = open || (lfsr_b[2:0] != 3'd0);

  // Rule 2: an offer, once made, stands until it is taken. The stall pattern
  // therefore gets to decide whether to START offering, never to retract.
  //
  // Driving `up.valid` straight from the pattern instead is what a careless
  // producer looks like, and the skid buffer's own assertion caught it here
  // before any of this reached the core -- but only under a consumer slow
  // enough to leave an offer standing, which is exactly the condition a
  // fast-accepting buffer hides.
  bit offering = 0;
  always @(posedge clk) begin
    if (!rst_n)                    offering <= 1'b0;
    else if (up.valid && up.ready) offering <= want_send;
    else                           offering <= offering || want_send;
  end

  // ---- producer and consumer --------------------------------------------
  // The producer runs forever; `N` only says when to stop measuring. That
  // avoids resetting counters mid-test, which SystemVerilog would reject
  // anyway once they are driven from a clocked process.
  int send_next = 0;
  int recv_next = 0;

  assign up.valid   = offering;
  assign up.data    = WIDTH'(send_next);
  assign down.ready = want_recv;

  int checks = 0;
  int errors = 0;

  always @(posedge clk) begin
    if (!rst_n) begin
      send_next <= 0;
      recv_next <= 0;
    end else begin
      if (up.valid && up.ready) send_next <= send_next + 1;

      if (down.valid && down.ready) begin
        checks <= checks + 1;
        if (down.data !== WIDTH'(recv_next)) begin
          $display("TB_FAIL tb_chan: expected item %0d, got %0d",
                   recv_next, down.data);
          errors <= errors + 1;
        end
        recv_next <= recv_next + 1;
      end
    end
  end

  // ---- rule 3 ------------------------------------------------------------
  // With the clock parked, glitch `down.ready` and confirm `up.ready` does not
  // move. `up.ready` is a register output, so a combinational path shows up
  // here as an immediate change.
  int r3_checks = 0;
  int r3_errors = 0;

  task automatic check_no_ready_path();
    logic observed;
    observed = up.ready;

    force down.ready = 1'b0;
    #1;
    r3_checks++;
    if (up.ready !== observed) begin
      $display("TB_FAIL tb_chan: up.ready followed down.ready low (rule 3)");
      r3_errors++;
    end

    force down.ready = 1'b1;
    #1;
    r3_checks++;
    if (up.ready !== observed) begin
      $display("TB_FAIL tb_chan: up.ready followed down.ready high (rule 3)");
      r3_errors++;
    end

    release down.ready;
    #1;
  endtask

  // ---- run ---------------------------------------------------------------
  int base;
  int moved;
  int total_checks;
  int total_errors;

  initial begin
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;

    // Mid-stream, with the buffer in an arbitrary state, prove rule 3. Done
    // twice, because `up.ready` differs between the skid entry being free and
    // full and only the second case has anything to leak.
    repeat (7) @(posedge clk);
    @(negedge clk);
    check_no_ready_path();

    repeat (31) @(posedge clk);
    @(negedge clk);
    check_no_ready_path();

    // Let the random patterns push the rest of the stream through.
    while (recv_next < N) @(posedge clk);

    // Throughput: with both sides always ready a skid buffer moves one item
    // per cycle. A one-entry registered stage passes every check above and
    // fails this one at exactly half rate.
    @(negedge clk);
    open = 1;
    base = recv_next;
    repeat (100) @(posedge clk);
    @(negedge clk);
    moved = recv_next - base;
    open  = 0;

    total_checks = checks + r3_checks + 2;
    total_errors = errors + r3_errors;

    if (moved < 98) begin
      $display("TB_FAIL tb_chan: %0d items in 100 unobstructed cycles, want >= 98",
               moved);
      total_errors++;
    end
    if (recv_next < N) begin
      $display("TB_FAIL tb_chan: only %0d of %0d items arrived", recv_next, N);
      total_errors++;
    end

    $display("checks=%0d errors=%0d (%0d items, %0d/100 at full rate)",
             total_checks, total_errors, recv_next, moved);
    if (total_errors == 0) $display("TB_PASS tb_chan");
    else                   $display("TB_FAIL tb_chan: %0d error(s)", total_errors);
    $finish;
  end

  initial begin
    #500000;
    $display("TB_FAIL tb_chan: timeout");
    $finish;
  end

endmodule
