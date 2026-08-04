// Memory clock for the PSRAM controller.
//
// The GW1NR-9C's rPLL, instantiated rather than generated through the IDE, so
// the arithmetic is visible and reviewable instead of living in a .ipc file.
//
//   CLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1)
//   PFD    = FCLKIN / (IDIV_SEL+1)          must be 3..400 MHz
//   VCO    = CLKOUT * ODIV_SEL              must be 400..1200 MHz
//
// With FCLKIN = 27 MHz, IDIV_SEL = 0, FBDIV_SEL = 2, ODIV_SEL = 10:
//
//   PFD    = 27 / 1   = 27 MHz    in range, and high, which is the low-jitter
//                                 end -- 27/6 = 4.5 MHz would also be legal
//                                 and much worse
//   CLKOUT = 27 * 3   = 81 MHz
//   VCO    = 81 * 10  = 810 MHz
//
// ODIV_SEL IS NOT FREE, AND THE TOOL WILL NOT SAY SO. Three combinations were
// tried on the way to this one and every failure was `gw_sh exit 1` with a
// ZERO-BYTE log -- the silent mode docs/bring-up.md warns about, found by
// bisecting because there is nothing to read:
//
//   FBDIV 2, ODIV 8   81 MHz, VCO 648    FAILS
//   FBDIV 4, ODIV 8   135 MHz, VCO 1080  FAILS   -- so it is ODIV 8 itself,
//                                                   not the frequency
//   FBDIV 2, ODIV 6   81 MHz, VCO 486    FAILS   -- VCO too low in practice,
//                                                   despite the 400 MHz floor
//   FBDIV 4, ODIV 6   135 MHz, VCO 810   works  (the previous setting)
//   FBDIV 2, ODIV 10  81 MHz, VCO 810    works  (this one)
//
// So the documented VCO range of 400..1200 is wider than what this part
// actually accepts, and ODIV_SEL takes some values and not others. Keeping the
// VCO at 810 -- a value proven twice -- is the cheap way to stay out of it.
//
// WHY 81. Two caches took utilization to 89%, and the congestion pushed the
// controller's own clk_out domain from +0.7% margin to -4.3%: 64.63 MHz
// against a 67.500 requirement. Nothing in the core or the caches is in that
// domain -- they are all in clk_sys -- but they compete for the same fabric,
// so the fix is to make the requirement smaller rather than the logic faster.
//
// 81 was chosen over 108 to close the controller's INTERNAL memclk <-> clk_out
// paths as well, which have never met timing at any frequency including
// Gowin's own 166 MHz default. Those needed the memory-clock period 1.59x
// longer, so <= 85 MHz, and 81 is the clean 27 x 3 point below it. The IP was
// regenerated for it -- the memory clock is a generation parameter, not an
// operating range, and everything else in the .ipc is unchanged.
//
// The cost is miss latency and nothing else. Bandwidth at 40.5 MHz x 64 bits
// is 2.6 Gbit/s against the 0.4 a 13.5 MHz core can use.
//
// WHY NOT 166, THE IP'S ORIGINAL CONFIGURATION. The controller halves it
// for the user side, so 162 MHz gives a 81 MHz clk_out -- and the logic in
// that domain placed at 81.1 and then 82.2 MHz against an 81.0 requirement.
// One and a half percent is not a margin, it is a coin flip across voltage and
// temperature.
//
// The bandwidth says there is nothing to defend. A 13.5 MHz core reading 32
// bits per cycle wants about 0.4 Gbit/s; 67.5 MHz by 64 bits is 4.3, an order
// of magnitude spare. Nothing here is bandwidth-bound, so the memory clock
// should be chosen for margin, and 135 leaves 22%.
//
// UNVERIFIED ON HARDWARE, and this is the parameter to suspect first if the
// controller never raises init_calib: its latency is configured for 166 MHz,
// and while running slower should only add setup margin, that is reasoning
// rather than measurement. 162 MHz is FBDIV_SEL=5, ODIV_SEL=4.

module k2g_pll (
    input  logic clk_in,        // 27 MHz crystal
    output logic memory_clk,    // 81 MHz to the PSRAM controller
    output logic pll_lock
);

  wire logic unused_p, unused_d, unused_d3;

  rPLL #(
      .FCLKIN         ("27"),
      .DEVICE         ("GW1NR-9C"),
      .IDIV_SEL       (0),        // /1
      .FBDIV_SEL      (2),        // x3
      .ODIV_SEL       (10),       // VCO = 810 MHz
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
      .CLKOUT  (memory_clk),
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

endmodule
