// Constraints for the `hdmifb` stage. SELF-CONTAINED.
//
// Every clock in the machine except the core's, which this stage does not
// have. Both rPLLs are here, so this is also the file the full soc+video
// build will start from.

create_clock -name clk_27m -period 37.037 -waveform {0 18.5} [get_ports {clk_27m}]

// The bus clock: crystal / 2 = 13.5 MHz.
//
// THE NET NAME MUST MATCH k2g_hdmi_fb_probe's divider. `clk_sys` does not
// survive synthesis as a net name, so the divider bit is named directly --
// div[0] is divide-by-2. Constraining the wrong bit does not error, it reports
// timing against a clock the design does not have.
create_clock -name clk_sys -period 74.074 -waveform {0 37.037} [get_nets {div[0]}]

// ---- memory side ----
//
// Declared as a CHAIN from the crystal, and generated rather than base, for
// the reasons tangnano9k_soc.sdc sets out at length: a base clock has no
// master, so the tool stops knowing these share a source and invents a skew
// between them.
create_generated_clock -name memclk -source [get_ports {clk_27m}] -multiply_by 3 [get_nets {memory_clk}]
create_generated_clock -name clk_out -source [get_nets {memory_clk}] -divide_by 2 [get_nets {psram_clk_out}]

// ---- video side ----
//
// 27 x 14 / 3 = 126 MHz, divided by five for the 25.2 MHz pixel clock.
// MUST TRACK k2g_hdmi_pll.sv.
create_generated_clock -name clk_serial -source [get_ports {clk_27m}] -multiply_by 14 -divide_by 3 [get_nets {clk_serial}]
create_generated_clock -name clk_pixel -source [get_nets {clk_serial}] -divide_by 5 [get_nets {clk_pixel}]

// Four asynchronous domains, and every crossing between them goes through a
// synchronizer that this line is what makes meaningful:
//
//   clk_sys <-> clk_out     k2g_cdc_fifo, inside k2g_psram
//   clk_sys <-> clk_pixel   the request toggle in k2g_video_scanout, and the
//                           line buffer itself, which is written in one domain
//                           and read in the other
//   clk_27m <-> everything  reset only
//
// clk_serial and clk_pixel are deliberately NOT split apart: they are phase
// related by the CLKDIV and OSER10 depends on exactly that, so declaring them
// asynchronous would switch off the one check that has to happen.
//
// ONE LINE. Gowin's SDC parser does not accept a backslash continuation.
set_clock_groups -asynchronous -group [get_clocks {clk_27m}] -group [get_clocks {clk_sys}] -group [get_clocks {memclk clk_out}] -group [get_clocks {clk_serial clk_pixel}]
