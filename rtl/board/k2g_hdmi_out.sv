// TMDS serializers and differential output buffers: the last stage before the
// HDMI connector.
//
// Three encoded symbols in, four differential pairs out. Each OSER10 takes ten
// bits at the pixel rate and shifts them out on both edges of the 126 MHz
// serial clock -- 252 Mbit/s per lane, which is the 25.2 MHz pixel clock times
// ten. D0 LEAVES FIRST, and TMDS is little-endian on the wire, so D0 takes
// bit 0 of the symbol.
//
// ELVDS_OBUF, NOT TLVDS_OBUF, and this is not interchangeable. The Gowin
// device file (IDE/data/device/GW1NR-9C/QFN88P.json) marks pins 68..75 as
// differential PAIRs but does NOT mark them `TRUELVDS` -- that flag appears
// only on bank 2 and parts of banks 1 and 3, and none of those pins go to the
// HDMI connector on this board. So the pairs are driven as emulated LVDS: two
// ordinary LVCMOS outputs into the resistor network Sipeed puts on the board.
// Instantiating TLVDS_OBUF on a pin without the capability is a placement
// error, and given how this toolchain reports errors it may well be a silent
// one.
//
// ---- the clock lane ----
//
// Sent through an OSER10 like the data, carrying a fixed 11111_00000 pattern,
// rather than routing the pixel clock straight into an ELVDS_OBUF. Both work
// -- Sipeed's own example does the latter -- and the reason to prefer this one
// is skew: the clock then travels the identical path to the data, through the
// same primitive with the same latency, instead of arriving via the clock tree
// with an unrelated delay. At 252 Mbit/s the eye is 4 ns wide and there is
// room for either, so IF THE MONITOR WILL NOT LOCK, swapping this lane for a
// direct ELVDS_OBUF on clk_pixel is a cheap thing to try and is the
// configuration with the most field evidence behind it.

module k2g_hdmi_out (
    input  logic       clk_pixel,
    input  logic       clk_serial,
    input  logic       rst_n,          // released once the PLL has locked

    // Channel 0 carries blue and the syncs, 1 green, 2 red. That assignment is
    // fixed by DVI, not by us: a receiver takes its sync from channel 0.
    input  logic [9:0] sym_ch0,
    input  logic [9:0] sym_ch1,
    input  logic [9:0] sym_ch2,

    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n
);

  // Five ones then five zeros, D0 first, which reconstructs the pixel clock at
  // the receiver with the same edge placement the data was launched against.
  localparam logic [9:0] CLK_PATTERN = 10'b1111100000;

  logic [9:0] sym[4];
  assign sym[0] = sym_ch0;
  assign sym[1] = sym_ch1;
  assign sym[2] = sym_ch2;
  assign sym[3] = CLK_PATTERN;

  logic [3:0] ser_out;

  // OSER10's RESET is active high.
  wire logic ser_reset = ~rst_n;

  generate
    for (genvar i = 0; i < 4; i++) begin : g_ser
      OSER10 #(
          .GSREN("false"),
          .LSREN("true")
      ) u_ser (
          .Q    (ser_out[i]),
          .D0   (sym[i][0]),      // first onto the wire
          .D1   (sym[i][1]),
          .D2   (sym[i][2]),
          .D3   (sym[i][3]),
          .D4   (sym[i][4]),
          .D5   (sym[i][5]),
          .D6   (sym[i][6]),
          .D7   (sym[i][7]),
          .D8   (sym[i][8]),
          .D9   (sym[i][9]),      // last
          .PCLK (clk_pixel),
          .FCLK (clk_serial),
          .RESET(ser_reset)
      );
    end
  endgenerate

  generate
    for (genvar i = 0; i < 3; i++) begin : g_buf_d
      ELVDS_OBUF u_buf (
          .I (ser_out[i]),
          .O (tmds_d_p[i]),
          .OB(tmds_d_n[i])
      );
    end
  endgenerate

  ELVDS_OBUF u_buf_clk (
      .I (ser_out[3]),
      .O (tmds_clk_p),
      .OB(tmds_clk_n)
  );

endmodule
