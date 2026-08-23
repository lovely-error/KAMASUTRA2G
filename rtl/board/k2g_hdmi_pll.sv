// Pixel and serial clocks for the HDMI output.
//
// The second of the GW1NR-9C's two rPLLs. k2g_pll.sv has the first, and the
// `soc` build already uses it for the PSRAM controller, so this is the last
// one on the device -- a third clock generator would have to come from a
// CLKDIV off an existing one.
//
//   CLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1)
//   PFD    = FCLKIN / (IDIV_SEL+1)          must be 3..400 MHz
//   VCO    = CLKOUT * ODIV_SEL              must be 400..1200 MHz
//
// With FCLKIN = 27 MHz, IDIV_SEL = 2, FBDIV_SEL = 13, ODIV_SEL = 8:
//
//   PFD    = 27 / 3    = 9 MHz       in range
//   CLKOUT = 27 * 14/3 = 126 MHz     the TMDS serial clock
//   VCO    = 126 * 8   = 1008 MHz    in range
//
// A CLKDIV divides that by five for the 25.2 MHz pixel clock, which is why the
// serial clock is 5x and not 10x: OSER10 is a DDR serializer, so ten bits per
// pixel come out on both edges of a clock running at five times the pixel rate.
// Feeding it 252 MHz would be wrong as well as unroutable.
//
// WHY 126 AND NOT 125.875. 640x480@60 nominally wants 25.175 MHz, so 5x is
// 125.875 -- and 125.875/27 is not a ratio of small integers, so the rPLL
// cannot make it from this crystal. 126 is 0.1% fast, putting the frame rate
// at 60.06 Hz, which is well inside what a DMT monitor must accept. See
// k2g_video_timing.sv.
//
// ---- ODIV_SEL TAKES A FIXED SET OF VALUES, AND SUBSTITUTES SILENTLY ----
//
// This file first said ODIV_SEL = 6, VCO = 756. The build SUCCEEDED and the
// netlist came out with ODIV_SEL = 8. The only trace is one line, buried in a
// log that build.sh does not print on success:
//
//   WARN (EX0205) : Instance "u_rpll" 's parameter "ODIV_SEL" value invalid,
//   replaced by default value "8"
//
// So 6 is not a legal value, the tool picked 8 for itself, and the part ran at
// a VCO 252 MHz away from the one documented here. A comment can be wrong
// about the hardware while the hardware works, which is the worst kind of
// wrong: nothing fails until someone changes a number on the strength of it.
// THE VALUE IS NOW 8 BECAUSE 8 IS WHAT RUNS. Verified by reading ODIV_SEL back
// out of impl/gwsynthesis/project.vg, which is the only place it is stated
// truthfully.
//
// IF YOU CHANGE ANY DIVIDER HERE, grep the build log for EX0205 before
// believing the arithmetic above:
//
//   grep EX0205 rtl/board/out/hdmi/build.log
//
// ---- THE SAME THING IS HAPPENING IN k2g_pll.sv, AND IT HAS BEEN ALL ALONG ----
//
// MEASURED, not inferred. `soc` was rebuilt and its netlist read:
//
//   k2g_pll.sv source          .ODIV_SEL (10)      // comment says VCO = 810
//   out/soc/.../project.vg     ODIV_SEL=8
//   out/soc/build.log          WARN (EX0205) ... replaced by default value "8"
//
// So the memory clock that has been on hardware since the PSRAM came up runs
// at a VCO of 81 x 8 = 648 MHz. Not 810. That file's headline number has never
// been the one in the part.
//
// It also dissolves the puzzle that file is built around. Its table records
//
//   FBDIV 2, ODIV 8    81 MHz, VCO 648    FAILS
//   FBDIV 2, ODIV 10   81 MHz, VCO 810    works   (the shipped setting)
//
// and after substitution THOSE ARE THE SAME CONFIGURATION. One of them cannot
// have failed for the reason recorded. Whatever killed those builds, it was
// not ODIV_SEL = 8 and it was not a VCO of 648, because that is what the
// working bitstream contains. The conclusion drawn there -- "keeping the VCO
// at 810, a value proven twice, is the cheap way to stay out of it" -- rests
// on a VCO that was never reached.
//
// NOTHING IN k2g_pll.sv HAS BEEN CHANGED. It produces a working machine and
// the fix is not obvious: making the source say 8 would be more truthful and
// would not alter a single bit of the bitstream, but the analysis around it
// would then need rewriting by someone who can put the result back on a board.
// This note is here so the next person to touch those dividers starts from the
// netlist instead of the comment.

module k2g_hdmi_pll (
    input  logic clk_in,        // 27 MHz crystal
    output logic clk_serial,    // 126 MHz, TMDS bit clock / 5
    output logic clk_pixel,     // 25.2 MHz
    output logic pll_lock
);

  wire logic unused_p, unused_d, unused_d3;

  rPLL #(
      .FCLKIN         ("27"),
      .DEVICE         ("GW1NR-9C"),
      .IDIV_SEL       (2),        // /3
      .FBDIV_SEL      (13),       // x14
      .ODIV_SEL       (8),        // VCO = 1008 MHz -- see EX0205 above
      .DYN_IDIV_SEL   ("false"),
      .DYN_FBDIV_SEL  ("false"),
      .DYN_ODIV_SEL   ("false"),
      .DYN_SDIV_SEL   (2),
      .PSDA_SEL       ("0000"),
      .DYN_DA_EN      ("false"),
      .DUTYDA_SEL     ("1000"),
      .CLKOUT_FT_DIR  (1'b1),
      .CLKOUTP_FT_DIR (1'b1),
      .CLKOUT_DLY_STEP(0),
      .CLKOUTP_DLY_STEP(0),
      .CLKFB_SEL      ("internal"),
      .CLKOUT_BYPASS  ("false"),
      .CLKOUTP_BYPASS ("false"),
      .CLKOUTD_BYPASS ("false"),
      .CLKOUTD_SRC    ("CLKOUT"),
      .CLKOUTD3_SRC   ("CLKOUT")
  ) u_rpll (
      .CLKOUT  (clk_serial),
      .LOCK    (pll_lock),
      .CLKOUTP (unused_p),
      .CLKOUTD (unused_d),
      .CLKOUTD3(unused_d3),
      .RESET   (1'b0),
      .RESET_P (1'b0),
      .CLKIN   (clk_in),
      .CLKFB   (1'b0),
      .FBDSEL  (6'b000000),
      .IDSEL   (6'b000000),
      .ODSEL   (6'b000000),
      .PSDA    (4'b0000),
      .DUTYDA  (4'b0000),
      .FDLY    (4'b0000)
  );

  // The pixel clock MUST come from this divider rather than from a second PLL
  // output or a counter. OSER10 takes both clocks and requires them
  // phase-related -- it samples its ten inputs on PCLK and shifts them out on
  // FCLK -- and CLKDIV is the dedicated hardware that guarantees the
  // relationship. A pixel clock made with a fabric divide-by-5 would be
  // correct in frequency and wrong in phase, which produces a picture with
  // torn pixels rather than no picture at all.
  //
  // Held in reset until the PLL locks, so the divider starts from a clean
  // edge rather than counting garbage.
  CLKDIV #(
      .DIV_MODE("5"),
      .GSREN   ("false")
  ) u_div5 (
      .CLKOUT (clk_pixel),
      .HCLKIN (clk_serial),
      .RESETN (pll_lock),
      .CALIB  (1'b0)
  );

endmodule
