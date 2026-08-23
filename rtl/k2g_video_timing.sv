// Video timing generator: 640x480 @ 60 Hz, the VESA DMT mode every monitor
// accepts without an EDID negotiation.
//
//   H: 640 active, 16 front, 96 sync, 48 back  = 800 total
//   V: 480 active, 10 front,  2 sync, 33 back  = 525 total
//
//   800 x 525 x 60 = 25.20 MHz pixel clock
//
// THE NOMINAL PIXEL CLOCK IS 25.175 MHz AND THIS RUNS AT 25.20. The 27 MHz
// crystal cannot produce 25.175 through an rPLL at any sane divider, and
// 25.20 is what 126/5 gives -- 0.1% fast, which puts the frame rate at 60.06 Hz.
// That is an order of magnitude inside the +/-0.5% a DMT monitor must accept,
// and it is what every Tang Nano 9K video design ships. See k2g_hdmi_pll.sv
// for why 126 MHz and not something closer.
//
// BOTH SYNCS ARE ACTIVE LOW in this mode. That is a property of 640x480@60
// specifically -- most higher DMT modes are active high -- and getting it
// backwards produces a picture that is present but shifted and often rejected
// outright, so the polarity is named here rather than assumed at the pin.
//
// `de` (data enable) is the DVI island signal: high exactly over the active
// area, and the TMDS encoders switch between pixel encoding and control
// encoding on it. `x` and `y` are only meaningful while `de` is high.
//
// Counters are free-running and there is no reset input beyond `rst_n`: a
// scanout source that wants to know where the beam is watches `x`/`y`, and one
// that wants to prefetch watches `line_start`, which fires one full line
// before the line it names is displayed.

module k2g_video_timing #(
    parameter int H_ACTIVE = 640,
    parameter int H_FRONT  = 16,
    parameter int H_SYNC   = 96,
    parameter int H_BACK   = 48,
    parameter int V_ACTIVE = 480,
    parameter int V_FRONT  = 10,
    parameter int V_SYNC   = 2,
    parameter int V_BACK   = 33
) (
    input  logic       clk,          // pixel clock
    input  logic       rst_n,

    output logic       hsync,        // active low
    output logic       vsync,        // active low
    output logic       de,           // active area
    output logic [9:0] x,            // 0..H_ACTIVE-1, valid while `de`
    output logic [9:0] y,            // 0..V_ACTIVE-1, valid while `de`

    // One cycle high at the start of every line, including the blanked ones.
    // `next_line` is the line that will be displayed one line from now, which
    // is the number a prefetching scanout wants -- by the time the beam
    // reaches it the data must already be in hand.
    output logic       line_start,
    output logic [9:0] next_line,
    // One cycle high at the start of vertical blanking. A framebuffer swap
    // that happens here is not torn.
    output logic       vblank_start
);

  localparam int H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;   // 800
  localparam int V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;   // 525

  // Sync pulse starts after the front porch and ends before the back porch.
  localparam int H_SYNC_BEG = H_ACTIVE + H_FRONT;                  // 656
  localparam int H_SYNC_END = H_ACTIVE + H_FRONT + H_SYNC;         // 752
  localparam int V_SYNC_BEG = V_ACTIVE + V_FRONT;                  // 490
  localparam int V_SYNC_END = V_ACTIVE + V_FRONT + V_SYNC;         // 492

  logic [9:0] hcount, vcount;

  wire logic h_last = (hcount == 10'(H_TOTAL - 1));
  wire logic v_last = (vcount == 10'(V_TOTAL - 1));

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hcount <= '0;
      vcount <= '0;
    end else if (h_last) begin
      hcount <= '0;
      vcount <= v_last ? 10'd0 : vcount + 10'd1;
    end else begin
      hcount <= hcount + 10'd1;
    end
  end

  // Combinational off the counters. One pixel of latency through the encoders
  // shifts sync and data together, so nothing here needs to be pre-skewed.
  assign de    = (hcount < 10'(H_ACTIVE)) && (vcount < 10'(V_ACTIVE));
  assign hsync = !((hcount >= 10'(H_SYNC_BEG)) && (hcount < 10'(H_SYNC_END)));
  assign vsync = !((vcount >= 10'(V_SYNC_BEG)) && (vcount < 10'(V_SYNC_END)));
  assign x     = hcount;
  assign y     = vcount;

  assign line_start   = (hcount == 10'd0);
  // Wraps to 0 on the last line of the frame, which is correct: the line after
  // the last one is the first line of the next frame.
  assign next_line    = v_last ? 10'd0 : vcount + 10'd1;
  assign vblank_start = (hcount == 10'd0) && (vcount == 10'(V_ACTIVE));

endmodule
