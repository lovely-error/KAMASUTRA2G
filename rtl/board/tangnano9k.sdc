// Real timing constraints for the Tang Nano 9K.
//
// Without these the tool assumes 50 MHz everywhere, which reports a violation
// that means nothing (the crystal is 27 MHz) while saying nothing about
// whether the design meets the clock it will actually run at.

create_clock -name clk_27m -period 37.037 -waveform {0 18.5} [get_ports {clk_27m}]

// The core runs on a divide-by-4 of the crystal: 6.75 MHz, 148.148 ns. Its
// single-cycle execute path places at an Fmax around 11.7 MHz, so it meets
// this comfortably but would fail at the full 27 MHz.
create_clock -name clk_sys -period 148.148 -waveform {0 74.07} [get_nets {div[1]}]

// The two are related by construction, but every path that matters is inside
// one domain or the other, and treating them as unrelated stops the tool
// reporting cross-domain paths that never occur.
set_clock_groups -asynchronous -group [get_clocks {clk_27m}] -group [get_clocks {clk_sys}]
