// Stage 6: HDMI colour bars. NO CPU, NO PSRAM, NO UART.
//
//   bash rtl/board/build.sh hdmi
//
// The bring-up gate for the video path, and staged for the same reason every
// other stage here is: a monitor showing nothing is equally consistent with a
// dead PLL, a serializer clocked wrong, a swapped differential pair, an
// unroutable clock, and an encoder bug. This design contains only the first
// four of those, and rtl/tb/tb_tmds.sv has already ruled out the fifth.
//
// What a working board looks like:
//
//   LED0   heartbeat off the 27 MHz crystal -- the bitstream is loaded and the
//          crystal is running. Dark means the toolchain or the board, and
//          nothing here.
//   LED1   PLL locked. Dark with LED0 blinking means k2g_hdmi_pll's dividers,
//          which is the parameter that file says to suspect first.
//   LED2   pixel clock alive -- a heartbeat divided down from clk_pixel, so it
//          only moves if the CLKDIV is producing edges. Dark with LED1 lit
//          means the divider, not the PLL.
//   screen eight colour bars, full height.
//
// LEDs are ACTIVE LOW on this board (see tangnano9k.cst), so the outputs are
// inverted at the port.
//
// The bars are generated from `x` alone, which makes a wrong picture readable:
// bars in the wrong order is a bit-order or channel-assignment mistake, bars
// that roll is a pixel clock the monitor does not accept, and bars with the
// left edge wrapped around to the right is a porch off by one.

module k2g_hdmi_probe (
    input  logic       clk_27m,
    input  logic       rst_n,

    output logic [5:0] led,
    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n
);

  // ---- clocks -------------------------------------------------------------

  logic clk_serial, clk_pixel, pll_lock;

  k2g_hdmi_pll u_pll (
      .clk_in    (clk_27m),
      .clk_serial(clk_serial),
      .clk_pixel (clk_pixel),
      .pll_lock  (pll_lock)
  );

  // Reset for the pixel domain: held until the PLL locks, then released
  // through two flops in that domain. `pll_lock` is asynchronous to
  // `clk_pixel` by construction -- the clock does not exist until the signal
  // asserts -- so it cannot be used as a reset directly.
  logic [1:0] px_rst_sync;
  logic       px_rst_n;
  always_ff @(posedge clk_pixel or negedge pll_lock) begin
    if (!pll_lock) px_rst_sync <= 2'b00;
    else           px_rst_sync <= {px_rst_sync[0], rst_n};
  end
  assign px_rst_n = px_rst_sync[1];

  // ---- timing -------------------------------------------------------------

  logic       hsync, vsync, de;
  logic [9:0] x, y;
  logic       line_start, vblank_start;
  logic [9:0] next_line;

  k2g_video_timing u_timing (
      .clk         (clk_pixel),
      .rst_n       (px_rst_n),
      .hsync       (hsync),
      .vsync       (vsync),
      .de          (de),
      .x           (x),
      .y           (y),
      .line_start  (line_start),
      .next_line   (next_line),
      .vblank_start(vblank_start)
  );

  // ---- colour bars --------------------------------------------------------
  //
  // Eight bars of 80 pixels across a 640-pixel line, in descending luminance,
  // which is the order a monitor's own test pattern uses and therefore the
  // order a mistake is most obvious against.

  logic [7:0] red, green, blue;
  logic [2:0] bar;

  // 640 / 8 = 80, which is not a power of two, so the bar index is a
  // comparison chain rather than a slice of `x`. A slice would be free and
  // wrong: x[9:7] is x/128 and produces five bars, not eight.
  always_comb begin
    if      (x < 10'd80)  bar = 3'd0;
    else if (x < 10'd160) bar = 3'd1;
    else if (x < 10'd240) bar = 3'd2;
    else if (x < 10'd320) bar = 3'd3;
    else if (x < 10'd400) bar = 3'd4;
    else if (x < 10'd480) bar = 3'd5;
    else if (x < 10'd560) bar = 3'd6;
    else                  bar = 3'd7;
  end

  always_comb begin
    unique case (bar)
      3'd0: {red, green, blue} = {8'hFF, 8'hFF, 8'hFF};   // white
      3'd1: {red, green, blue} = {8'hFF, 8'hFF, 8'h00};   // yellow
      3'd2: {red, green, blue} = {8'h00, 8'hFF, 8'hFF};   // cyan
      3'd3: {red, green, blue} = {8'h00, 8'hFF, 8'h00};   // green
      3'd4: {red, green, blue} = {8'hFF, 8'h00, 8'hFF};   // magenta
      3'd5: {red, green, blue} = {8'hFF, 8'h00, 8'h00};   // red
      3'd6: {red, green, blue} = {8'h00, 8'h00, 8'hFF};   // blue
      3'd7: {red, green, blue} = {8'h20, 8'h20, 8'h20};   // near-black
    endcase
  end

  // ---- encode -------------------------------------------------------------
  //
  // Channel 0 is blue and carries both syncs; 1 and 2 carry green and red with
  // their control bits tied low. That split is fixed by DVI.

  logic [9:0] sym_ch0, sym_ch1, sym_ch2;

  k2g_tmds_encode u_enc0 (
      .clk(clk_pixel), .rst_n(px_rst_n),
      .de(de), .din(blue), .c1(vsync), .c0(hsync), .dout(sym_ch0)
  );
  k2g_tmds_encode u_enc1 (
      .clk(clk_pixel), .rst_n(px_rst_n),
      .de(de), .din(green), .c1(1'b0), .c0(1'b0), .dout(sym_ch1)
  );
  k2g_tmds_encode u_enc2 (
      .clk(clk_pixel), .rst_n(px_rst_n),
      .de(de), .din(red), .c1(1'b0), .c0(1'b0), .dout(sym_ch2)
  );

  k2g_hdmi_out u_out (
      .clk_pixel (clk_pixel),
      .clk_serial(clk_serial),
      .rst_n     (px_rst_n),
      .sym_ch0   (sym_ch0),
      .sym_ch1   (sym_ch1),
      .sym_ch2   (sym_ch2),
      .tmds_clk_p(tmds_clk_p),
      .tmds_clk_n(tmds_clk_n),
      .tmds_d_p  (tmds_d_p),
      .tmds_d_n  (tmds_d_n)
  );

  // ---- status -------------------------------------------------------------

  // Heartbeat on the crystal: about 1.6 Hz at 27 MHz.
  logic [23:0] beat_xtal;
  always_ff @(posedge clk_27m) beat_xtal <= beat_xtal + 24'd1;

  // Heartbeat on the pixel clock. Runs at all only if the CLKDIV is dividing.
  logic [23:0] beat_pixel;
  always_ff @(posedge clk_pixel) begin
    if (!px_rst_n) beat_pixel <= '0;
    else           beat_pixel <= beat_pixel + 24'd1;
  end

  always_comb begin
    led    = 6'b111111;                 // all dark
    led[0] = ~beat_xtal[23];
    led[1] = ~pll_lock;
    led[2] = ~beat_pixel[23];
  end

endmodule
