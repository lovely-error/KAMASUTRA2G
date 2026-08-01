// Real timing constraints for the Tang Nano 9K.
//
// Without these the tool assumes 50 MHz everywhere, which reports a violation
// that means nothing (the crystal is 27 MHz) while saying nothing about
// whether the design meets the clock it will actually run at.

create_clock -name clk_27m -period 37.037 -waveform {0 18.5} [get_ports {clk_27m}]

// The core runs on a divide-by-2 of the crystal: 13.5 MHz, 74.074 ns. With
// decode split into its own stage the execute path places at 14.53 MHz, so it
// meets this with about 7% to spare; it would still fail at the full 27 MHz.
//
// THE NET NAME HERE MUST MATCH k2g_soc's CLK_DIV. The divider bit is named
// directly because `clk_sys` itself does not survive synthesis as a net name.
// div[0] is divide-by-2, div[1] divide-by-4. Constraining the wrong bit does
// not error -- it reports timing against a clock the design does not have.
create_clock -name clk_sys -period 74.074 -waveform {0 37.037} [get_nets {div[0]}]

// The two are related by construction, but every path that matters is inside
// one domain or the other, and treating them as unrelated stops the tool
// reporting cross-domain paths that never occur.
set_clock_groups -asynchronous -group [get_clocks {clk_27m}] -group [get_clocks {clk_sys}]
