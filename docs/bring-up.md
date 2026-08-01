# Board bring-up — Tang Nano 9K

Three bitstreams, built in order so that a failure says which layer is at
fault rather than just "it doesn't work".

**Use Git Bash, not WSL.** On a Windows box with WSL installed, `bash` from
PowerShell resolves to WSL's bash, whose filesystem has no `C:/Gowin` or
`E:/Quartus`. Every script checks for this and says so rather than reporting a
missing toolchain.

From a Git Bash prompt:

```bash
bash rtl/board/build.sh blink       # 1. toolchain, pinout, clock
bash rtl/board/build.sh loopback    # 2. UART pins and baud rate
bash rtl/board/build.sh soc         # 3. the whole machine
```

Or from PowerShell, naming Git Bash explicitly:

```powershell
& "C:\Program Files\Git\bin\bash.exe" rtl/board/build.sh soc
```

Flash with either the Gowin Programmer GUI or:

```bash
openFPGALoader -b tangnano9k rtl/board/out/soc/impl/pnr/project.fs
```

**All three stages have run on hardware**, on a Tang Nano 9K over the on-board
USB serial bridge at 115200 8N1. `fibforever` counts the 32-bit Fibonacci
sequence a term per second and wraps back to zero after 2971215073.

Utilization and timing figures below come from place-and-route reports; the
behaviour is observed.

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
runs on a divided clock. It is now a divide-by-**2** at **13.5 MHz**.

| | Constraint | Actual Fmax | Logic levels |
|---|---|---|---|
| v1, single-cycle execute | 6.75 MHz | 10.0 MHz | 28 |
| after Phase 2b, decode split out | **13.5 MHz** | **16.3 MHz** | **13** |

Zero negative slack, about 21% margin, and **observed running on hardware** at
13.5 MHz after a rebuild and reflash.

v1's 28-level path was the whole single-cycle execute chain — fetch → decode →
register read → ALU → writeback, all combinational within one cycle. Giving
decode its own stage (`docs/v2-plan.md`, Phase 2b) roughly halved it and took
Fmax past the 13.5 MHz that a divide-by-2 needs. Going to divide-by-1 needs
27 MHz and is what splitting execute from writeback is for.

**`CLK_DIV` and the `.sdc` must move together.** The constraint names the
divider bit directly — `div[0]` is divide-by-2, `div[1]` divide-by-4 — because
`clk_sys` does not survive synthesis as a net name. Constraining the wrong bit
is not an error; it reports timing against a clock the design does not have.

The baud divisor follows `CLK_DIV` automatically, and got better on the way:
13.5 MHz / 117 is 115385 baud, 0.16% off, against 1.02% before.

## Terminal conventions

Programs emit **CRLF**, not a bare LF. A serial terminal treats LF as "move
down one row" and leaves the column alone, so a bare newline makes each line
start where the previous one ended — output marches diagonally off the right
of the screen. This is a terminal convention, not a bug in the machine: the
same bytes look correct piped to a file or through the emulator's stdout.

PuTTY can paper over it with *Terminal → Implicit CR in every LF*, but sending
CRLF is what a serial device is expected to do.

## Reset

The board has no hardware debounce on the button, so one press produced a
burst of edges and the machine ran its program once per edge. `k2g_soc`
synchronizes the button and then requires the level to hold for 10 ms before
believing it. That also gives a clean power-on reset, since the debounced
signal starts asserted.

## Flow control on the UART

The core is roughly fifty times faster than a 115200 baud line, so a `CSP`
write to `UART_DATA` **stalls** until the transmitter is free.

Without that the first hardware run printed `H` and a newline and nothing else:
each new byte overwrote the one still being shifted out, so after the `H`
completed the holding register contained the last byte of the string. The
symptom looks like a CPU that stopped after one instruction; it is not.

Stalling costs nothing architecturally. A stalled instruction has not retired,
so nothing commits and the lockstep comparison cannot see it — the RTL and the
emulator still agree instruction for instruction, and `hello` still takes 181.

Two things made this reachable, both worth avoiding elsewhere:

- The testbenches held `uart_tx_ready` high forever, so simulation could not
  distinguish a design with backpressure from one without. They now model a
  transmitter that is busy for 40 cycles per byte.
- Routing the stall back into the decoder's `cp_valid` closes a combinational
  loop: stall → decode → CSP request → stall. The decoder takes a separate
  `hold` input that freezes its accumulator while leaving its combinational
  output alone.

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
module that synthesized fine with either counter alone. Another was
`div[$clog2(CLK_DIV)-1]`: `$clog2` inline in a part-select index, which is fine
in Questa and fine as a `localparam` assigned first. When a build fails with no
message, bisect the source; there will be no diagnostic to read.
