// Stage 2 of bring-up: UART echo, no CPU.
//
// Typed characters come back with their case flipped, so the round trip is
// visibly a round trip rather than a terminal echoing locally. If this works,
// the pins, the baud rate and the USB-serial bridge are all good, and any
// later failure belongs to the CPU or the program image.
//
// NOTE. The activity indicators use one shared prescaler and sticky bits
// rather than a down-counter per LED. The obvious version -- two 22-bit
// counters loaded with '1 and decremented -- makes GowinSynthesis exit(1) with
// no diagnostic at all, not even its usual banner. Each piece synthesizes
// alone; only the combination trips it. This form is equivalent, smaller, and
// does not hit whatever the tool dislikes.

module k2g_loopback (
    input  logic       clk_27m,
    input  logic       rst_n,
    output logic [5:0] led,
    output logic       uart_tx,
    input  logic       uart_rx
);

  localparam int DIVISOR = 27_000_000 / 115_200;   // 234

  logic       rx_valid, tx_ready;
  logic [7:0] rx_data;

  k2g_uart_rx #(.DIVISOR(DIVISOR)) u_rx (
      .clk  (clk_27m),
      .rst_n(rst_n),
      .rx   (uart_rx),
      .valid(rx_valid),
      .data (rx_data)
  );

  // One byte of buffering is enough: a terminal cannot outpace the echo.
  logic       pending;
  logic [7:0] pending_data;
  wire  logic send = pending && tx_ready;

  always_ff @(posedge clk_27m) begin
    if (!rst_n) begin
      pending      <= 1'b0;
      pending_data <= 8'd0;
    end else if (rx_valid) begin
      pending_data <= (rx_data >= "a" && rx_data <= "z") ? (rx_data - 8'd32) :
                      (rx_data >= "A" && rx_data <= "Z") ? (rx_data + 8'd32) :
                                                           rx_data;
      pending      <= 1'b1;
    end else if (send) begin
      pending <= 1'b0;
    end
  end

  k2g_uart_tx #(.DIVISOR(DIVISOR)) u_tx (
      .clk  (clk_27m),
      .rst_n(rst_n),
      .valid(send),
      .data (pending_data),
      .ready(tx_ready),
      .tx   (uart_tx)
  );

  // Activity indication: sticky bits sampled and cleared by a slow prescaler,
  // so a single byte is visible without stretching each pulse individually.
  logic [21:0] prescale;
  logic        rx_seen, tx_seen, rx_led, tx_led;

  always_ff @(posedge clk_27m) begin
    if (!rst_n) begin
      prescale <= '0;
      rx_seen  <= 1'b0;
      tx_seen  <= 1'b0;
      rx_led   <= 1'b0;
      tx_led   <= 1'b0;
    end else begin
      prescale <= prescale + 22'd1;
      if (rx_valid) rx_seen <= 1'b1;
      if (send)     tx_seen <= 1'b1;
      if (prescale == '1) begin
        rx_led  <= rx_seen;
        tx_led  <= tx_seen;
        rx_seen <= 1'b0;
        tx_seen <= 1'b0;
      end
    end
  end

  // Active low. LED5 is a slow heartbeat so a silent link still shows life.
  assign led = ~{prescale[21], 3'b000, tx_led, rx_led};

endmodule
