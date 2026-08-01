// Sipeed Tang Nano 9K -- GW1NR-LV9QN88PC6/I5.
//
// Constraints every stage shares. Anything naming a net that only exists in
// one design belongs in tangnano9k_<stage>.sdc instead: Gowin treats a
// constraint on a missing object as a hard error, so putting the core's clock
// here made `blink` and `loopback` unbuildable while nobody was building them.

create_clock -name clk_27m -period 37.037 -waveform {0 18.5} [get_ports {clk_27m}]
