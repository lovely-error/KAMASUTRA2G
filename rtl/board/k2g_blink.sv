// Stage 1 of bring-up: prove the toolchain, the constraints and the clock.
//
// No CPU, no memory, no UART. If this does not blink, the problem is the
// board, the pinout, the bitstream or the programmer -- not the design. That
// separation is the entire point of building it.
//
// The LEDs are ACTIVE LOW on this board, so the counter is inverted on its way
// out. A design that looks correct but drives the LEDs the wrong way round
// still "works" and is easy to misread, hence the explicit inversion.

module k2g_blink (
    input  logic       clk_27m,
    input  logic       rst_n,
    output logic [5:0] led,
    // Declared so the constraints file matches the port list; held idle.
    output logic       uart_tx,
    input  logic       uart_rx
);

  localparam int CLK_HZ = 27_000_000;

  // A counter wide enough that bit 25 toggles at roughly 0.4 Hz -- slow enough
  // to see, fast enough not to look dead.
  logic [25:0] counter;

  always_ff @(posedge clk_27m) begin
    if (!rst_n) counter <= '0;
    else        counter <= counter + 26'd1;
  end

  // A walking pattern rather than a single flashing LED: it distinguishes "the
  // design is running" from "one output happens to be stuck".
  always_comb begin
    led = ~(6'b000001 << counter[25:23]);
  end

  assign uart_tx = 1'b1;   // idle high

  wire logic _unused = &{1'b0, uart_rx, CLK_HZ[0]};

endmodule
