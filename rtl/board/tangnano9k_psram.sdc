// Constraints specific to the `psram` stage.
//
// `memory_clk` comes from the rPLL at 162 MHz (see k2g_pll.sv). `clk_out` is
// produced by the PSRAM controller itself and its frequency is not knowable
// from the sources -- the IP body is encrypted -- so it is left for the tool
// to derive from the PLL rather than asserted here and asserted wrongly.
// Nothing to add beyond the shared crystal constraint: the PLL output and the
// controller's clk_out are both derived, and the tool infers them. A
// set_clock_groups naming only one group is not meaningful and Gowin rejects
// it.
