// Constraints for the `hdmi` stage. SELF-CONTAINED.
//
// A stage file replaces the shared tangnano9k.sdc rather than adding to it:
// Gowin will not resolve a clock created in one file from a constraint in
// another. Every file that needs a clock creates it.

create_clock -name clk_27m -period 37.037 -waveform {0 18.5} [get_ports {clk_27m}]

// The TMDS serial clock: 27 x 14 / 3 = 126 MHz, 7.937 ns.
//
// Declared as GENERATED rather than base, for the reason tangnano9k_soc.sdc
// spells out at length: a base clock has no master, so the tool stops knowing
// that this and the pixel clock divided from it share a source, and analyses
// every path between them with an invented relation and several nanoseconds of
// skew. That makes the report look better and mean less.
//
// MUST TRACK k2g_hdmi_pll.sv. The ratio is in two places and they are the same
// number.
create_generated_clock -name clk_serial -source [get_ports {clk_27m}] -multiply_by 14 -divide_by 3 [get_nets {clk_serial}]

// The pixel clock out of the CLKDIV: 126 / 5 = 25.2 MHz, 39.683 ns.
create_generated_clock -name clk_pixel -source [get_nets {clk_serial}] -divide_by 5 [get_nets {clk_pixel}]

// The crystal domain holds only the LED heartbeat and the reset input. The
// reset crosses into the pixel domain through the two-flop synchronizer in
// k2g_hdmi_probe, which is what makes that crossing safe; without this line
// the tool tries to close timing on a path that is asynchronous by
// construction.
//
// clk_serial and clk_pixel are NOT grouped apart from each other. They are
// phase-related by the CLKDIV and OSER10 depends on exactly that relationship
// -- it samples on the pixel clock and shifts out on the serial one. Declaring
// them asynchronous would tell the tool to stop checking the one path in this
// design that genuinely has to be checked.
//
// ONE LINE. Gowin's SDC parser does not accept a backslash continuation.
set_clock_groups -asynchronous -group [get_clocks {clk_27m}] -group [get_clocks {clk_serial clk_pixel}]
