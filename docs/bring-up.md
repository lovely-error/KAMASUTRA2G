# Board bring-up — Tang Nano 9K

Three bitstreams, built in order so that a failure says which layer is at
fault rather than just "it doesn't work".

```bash
bash rtl/board/build.sh blink       # 1. toolchain, pinout, clock
bash rtl/board/build.sh loopback    # 2. UART pins and baud rate
bash rtl/board/build.sh soc         # 3. the whole machine
```

Flash with either the Gowin Programmer GUI or:

```bash
openFPGALoader -b tangnano9k rtl/board/out/soc/impl/pnr/project.fs
```

**These have not been run on hardware.** Everything below is from
place-and-route reports and simulation.

## Stage 1 — blink

Six LEDs walk in a pattern at roughly 0.4 Hz. A walking pattern rather than a
single flash, so "running" is distinguishable from "one output stuck".

If this does not blink, the problem is the board, the pinout, the bitstream or
the programmer — not the design.

| | |
|---|---|
| Logic | 33 / 8640 |
| Registers | 26 / 6480 |

## Stage 2 — UART loopback

Echoes typed characters back with their case flipped, so a round trip is
visibly a round trip and not the terminal echoing locally. 115200 8N1. LED0
flickers on receive, LED1 on transmit, LED5 is a heartbeat.

Connect at **115200 8N1** to the board's USB serial port and type.

| | |
|---|---|
| Logic | 101 / 8640 |
| Registers | 88 / 6480 |

## Stage 3 — the full machine

```
boot ROM -> copier -> 8 KB unified memory -> K2G core -> UART
```

Runs `emu/programs/hello.kasm` by default and should print
`Hello from KAMASUTRA2G!` once at reset. Build a different program with:

```bash
PROG=fib bash rtl/board/build.sh soc
```

| | |
|---|---|
| Logic | 4695 / 8640 (55%) |
| Registers | 758 / 6480 (12%) |
| BSRAM | 4 / 26 (16%) |
| Bitstream | 3.5 MB |

### The LEDs are the debugger

A halted core cannot execute the `CSP` read that would report its own fault
cause (spec §8), so the LEDs carry it instead. Active low, so a lit LED is a 1.

| Pattern | Meaning |
|---|---|
| all six lit, briefly | boot copier running |
| LED5 blinking, LED0-4 from `GPIO_OUT` | running normally |
| `100000` | clean `HALT` |
| `1cccccc` — top bit set, low five the cause | faulted; cause per spec §8 |

So `1` followed by `00110` is cause 0x06, `MISALIGNED_LOAD`.

## Timing

The design does **not** meet timing at the board's 27 MHz crystal, so the core
runs on a divide-by-4 at **6.75 MHz**.

| Clock | Constraint | Actual Fmax | Logic levels |
|---|---|---|---|
| `clk_27m` | 27.0 MHz | 448.6 MHz | 2 |
| `clk_sys` | 6.75 MHz | 11.5 MHz | 29 |

Zero negative slack on both.

The 29-level path is the single-cycle execute chain: fetch → decode → register
read → ALU → writeback, all combinational within one cycle. That is the direct
cost of the simplification recorded in `k2g_core.sv` — the plan's 3-stage
F/D/X pipeline exists precisely to break this path. Pipelining is the reward
for the lockstep cosimulation being green: it makes the change safe to attempt.

Raising `CLK_DIV` to 2 would need an Fmax above 13.5 MHz; the current design is
about 2 MHz short.

## What the toolchain would not do

Recorded because each cost real time and none of it is discoverable from the
documentation.

**GowinSynthesis will not initialize inferred memory.** `$readmemh` produced no
`INIT_RAM` data at all, and with a synchronous read it exited with status 1 and
*no diagnostic whatsoever*. Hence `mkrom`: the program becomes a case-statement
ROM in logic, and a copier moves it into RAM at reset while the CPU is held
in reset. That also mirrors what a real system does copying from flash.

**Inferred true-dual-port BSRAM comes out unusable.** A read port and a write
port on one array infers `WRITE_MODE = 2'b10` (read-before-write), which the
DPB primitive does not support and place-and-route rejects.
`syn_ramstyle="no_rw_check"` did not change it. `k2g_mem` now instantiates
`DPB` explicitly with `WRITE_MODE = 2'b00`, keeping a behavioural model under
`` `ifdef SIMULATION `` so testbenches and the cosimulation are unaffected.

Memory is 8 KB so each byte lane is exactly one DPB in x8 mode, which removes
multi-block address decoding entirely. The largest program here is 124 bytes.

**Guard simulation-only code on `SIMULATION`, never on `SYNTHESIS`.**
GowinSynthesis does not define `SYNTHESIS`, so `` `ifndef SYNTHESIS `` leaves
the code visible to it — and the tasks in `k2g_mem` made it exit silently.

**Bank 3 is locked to 1.8 V** because it is shared with the in-package PSRAM,
so constraining the LEDs to `LVCMOS33` is rejected. The constraints file leaves
I/O standards at the bank defaults. The LEDs still light: they sit between the
3.3 V rail and the pin, so pulling low sinks current regardless.

**Silent crashes are common.** Several constructs make `gw_sh` exit 1 with zero
output — not even its startup banner. One was two 22-bit down-counters in a
module that synthesized fine with either counter alone. When a build fails with
no message, bisect the source; there will be no diagnostic to read.
