// Constraints for the `soc` stage. SELF-CONTAINED.
//
// A stage file replaces the shared tangnano9k.sdc rather than adding to it:
// Gowin will not resolve a clock created in one file from a constraint in
// another, so `set_clock_groups` naming clk_27m failed with "Cannot get clock
// with name" when the crystal was constrained next door. Every file that needs
// a clock creates it.

create_clock -name clk_27m -period 37.037 -waveform {0 18.5} [get_ports {clk_27m}]

// The core runs on a divide-by-2 of the crystal: 13.5 MHz, 74.074 ns. With
// decode split into its own stage the execute path places at 16.3 MHz, so it
// meets this with margin; it would still fail at the full 27 MHz.
//
// THE NET NAME HERE MUST MATCH k2g_soc's CLK_DIV. The divider bit is named
// directly because `clk_sys` does not survive synthesis as a net name.
// div[0] is divide-by-2, div[1] divide-by-4. Constraining the wrong bit does
// not error -- it reports timing against a clock the design does not have.
create_clock -name clk_sys -period 74.074 -waveform {0 37.037} [get_nets {div[0]}]

// The PSRAM controller's user clock: a CLKDIV inside the IP halving the PLL's
// 135 MHz, so 67.5 MHz.
//
// GENERATED, NOT BASE, and the difference is the whole point. The tool derives
// this clock on its own when nothing declares it -- as
// `<instance>/u_psram_top/clkdiv/CLKOUT.default_gen_clk` -- but that name
// cannot be used in `set_clock_groups`, because auto-derivation happens after
// the constraints are read and `get_clocks` on it fails outright. So it has to
// be declared to be named, and declaring it with `create_clock` is wrong: a
// base clock has no master, so the tool stops knowing that this and the
// memory clock it is divided from share a source, and analyses every path
// between them with an invented relation and 4.5 ns of skew. That is how a
// constraint makes a report look better while meaning less -- it raised the
// reported Fmax from 67.2 to 70.0 MHz and turned fifty IP-internal paths into
// violations.
// Declared as a CHAIN from the crystal, because `-source` will only accept a
// point where a clock has been declared -- the PLL output the tool derives by
// itself cannot be named here, in `-source` or in `get_clocks`, since
// auto-derivation happens after these constraints are read. So the PLL's
// memory clock is declared too, at the same ratio the tool would have derived,
// purely so that clk_out has a master to hang from.
//
// 27 x 3 = 81 MHz, halved by the IP to 40.5 MHz. MUST TRACK k2g_pll.sv AND THE
// IP's MEMORY_CLK -- all three are the same number in three places, and the
// memory clock is a generation parameter, so changing it means regenerating
// the IP as well as editing here.
create_generated_clock -name memclk -source [get_ports {clk_27m}] -multiply_by 3 [get_nets {memory_clk}]
create_generated_clock -name clk_out -source [get_nets {memory_clk}] -divide_by 2 [get_nets {psram_clk_out}]

// This line is load-bearing rather than tidy. The core and the controller are
// two PLL paths with nothing holding them in phase, so every path between them
// is a real clock-domain crossing -- and they all go through k2g_cdc_fifo,
// whose two synchronizer flops are the only thing making them safe. Without it
// the tool tries to close timing on paths that can never be met, and may
// report success at something meaningless.
//
// docs/v2-plan.md calls this out as the one thing cosimulation cannot check:
// metastability does not exist in a zero-delay simulator, so nothing in
// rtl/sim/ will ever notice if this line is missing.
//
// ONE LINE. Gowin's SDC parser does not accept a backslash continuation -- it
// reports `syntax error near token '\'` and the build stops.
set_clock_groups -asynchronous -group [get_clocks {clk_27m}] -group [get_clocks {clk_sys}] -group [get_clocks {memclk clk_out}]
