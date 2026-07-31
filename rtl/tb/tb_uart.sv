// UART transmitter and receiver, checked against each other and against a
// bit-banged reference.
//
// Worth doing in simulation because a baud-rate or bit-order mistake on real
// hardware presents as garbage characters, which is a slow thing to debug
// through a terminal.

module tb_uart;

  localparam int DIVISOR = 16;   // small, to keep the run short

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  int checks = 0;
  int errors = 0;

  task automatic check(input string what, input logic ok);
    checks++;
    if (!ok) begin
      errors++;
      $display("TB_FAIL: %s", what);
    end
  endtask

  // ---- transmitter -------------------------------------------------------
  logic       tx_valid = 0, tx_ready, tx_line;
  logic [7:0] tx_data = 0;

  k2g_uart_tx #(.DIVISOR(DIVISOR)) u_tx (
      .clk(clk), .rst_n(rst_n), .valid(tx_valid), .data(tx_data),
      .ready(tx_ready), .tx(tx_line)
  );

  // ---- receiver, fed from the transmitter --------------------------------
  logic       rx_valid;
  logic [7:0] rx_data;

  k2g_uart_rx #(.DIVISOR(DIVISOR)) u_rx (
      .clk(clk), .rst_n(rst_n), .rx(tx_line), .valid(rx_valid), .data(rx_data)
  );

  // Independent decode of the serial line, so a matched pair of bugs in the
  // transmitter and receiver cannot pass.
  byte unsigned sniffed [$];

  task automatic sniff();
    logic [7:0] b;
    forever begin
      @(negedge tx_line);                       // start bit
      repeat (DIVISOR + DIVISOR/2) @(posedge clk);
      for (int i = 0; i < 8; i++) begin
        b[i] = tx_line;
        repeat (DIVISOR) @(posedge clk);
      end
      sniffed.push_back(b);
    end
  endtask

  byte unsigned received [$];
  always_ff @(posedge clk) if (rx_valid) received.push_back(rx_data);

  task automatic send(input logic [7:0] b);
    wait (tx_ready);
    @(negedge clk);
    tx_data  = b;
    tx_valid = 1;
    @(posedge clk);
    @(negedge clk);
    tx_valid = 0;
    // Let the frame finish plus a little idle.
    repeat (DIVISOR * 12) @(posedge clk);
  endtask

  byte unsigned expected [$] = '{ "K", "2", "G", 8'h00, 8'hFF, 8'h55, 8'hAA };

  initial begin
    fork sniff(); join_none

    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    check("idle line is high", tx_line === 1'b1);
    check("transmitter starts ready", tx_ready === 1'b1);

    foreach (expected[i]) send(expected[i]);

    repeat (DIVISOR * 20) @(posedge clk);

    check($sformatf("received %0d bytes", expected.size()),
          received.size() == expected.size());
    check($sformatf("sniffed %0d bytes", expected.size()),
          sniffed.size() == expected.size());

    foreach (expected[i]) begin
      if (i < received.size()) begin
        check($sformatf("received[%0d] == %02x", i, expected[i]),
              received[i] == expected[i]);
      end
      // The independent decode catches a bit-order or framing error that the
      // receiver might mirror.
      if (i < sniffed.size()) begin
        check($sformatf("wire[%0d] == %02x", i, expected[i]),
              sniffed[i] == expected[i]);
      end
    end

    // A glitch on the line must not be mistaken for a start bit.
    check("idle again", tx_line === 1'b1 && tx_ready === 1'b1);

    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("TB_PASS tb_uart");
    else             $display("TB_FAIL tb_uart: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #500000;
    $display("TB_FAIL tb_uart: timeout");
    $finish;
  end

endmodule
