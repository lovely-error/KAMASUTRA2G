// Constraints for the `mon` stage. SELF-CONTAINED.
//
// A stage file replaces the shared tangnano9k.sdc rather than adding to it:
// Gowin will not resolve a clock created in one file from a constraint in
// another, so `set_clock_groups` naming clk_27m fails with "Cannot get clock
// with name" when the crystal is constrained next door. Every file that needs
// a clock creates it.
//
// This is the `soc` file without the core. The three clocks and the asynchronous
// grouping are identical, because the parts they constrain are the same parts:
// the monitor runs in clk_sys and the PSRAM adapter crosses to the controller's
// clk_out through k2g_cdc_fifo and nothing else.

create_clock -name clk_27m -period 37.037 -waveform {0 18.5} [get_ports {clk_27m}]

// THE NET NAME HERE MUST MATCH k2g_mon_probe's CLK_DIV. The divider bit is
// named directly because `clk_sys` does not survive synthesis as a net name.
// div[0] is divide-by-2, div[1] divide-by-4. Constraining the wrong bit does
// not error -- it reports timing against a clock the design does not have.
create_clock -name clk_sys -period 74.074 -waveform {0 37.037} [get_nets {div[0]}]

// The PSRAM controller's user clock, declared as a chain from the crystal so
// it has a master to hang from. Declaring it with `create_clock` instead is
// wrong: a base clock has no master, the tool stops knowing this and the
// memory clock share a source, and it analyses every path between them with an
// invented relation. 27 x 3 = 81 MHz, halved by the IP to 40.5 MHz. MUST TRACK
// k2g_pll.sv and the IP's MEMORY_CLK -- the same number in three places, and it
// is a generation parameter, so changing it means regenerating the IP.
create_generated_clock -name memclk -source [get_ports {clk_27m}] -multiply_by 3 [get_nets {memory_clk}]
create_generated_clock -name clk_out -source [get_nets {memory_clk}] -divide_by 2 [get_nets {psram_clk_out}]

// Load-bearing rather than tidy: clk_sys and the controller's clk_out are two
// PLL paths with nothing holding them in phase, so every path between them is a
// real crossing. Without this the tool tries to close timing on paths that can
// never be met, and may report success at something meaningless.
//
// ONE LINE. Gowin's SDC parser does not accept a backslash continuation.
set_clock_groups -asynchronous -group [get_clocks {clk_27m}] -group [get_clocks {clk_sys}] -group [get_clocks {memclk clk_out}]
