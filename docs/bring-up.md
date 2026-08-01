# Board bring-up — Tang Nano 9K

Four bitstreams, built in order so that a failure says which layer is at
fault rather than just "it doesn't work".

**Use Git Bash, not WSL.** On a Windows box with WSL installed, `bash` from
PowerShell resolves to WSL's bash, whose filesystem has no `C:/Gowin` or
`E:/Quartus`. Every script checks for this and says so rather than reporting a
missing toolchain.

From a Git Bash prompt:

```bash
bash rtl/board/build.sh blink       # 1. toolchain, pinout, clock
bash rtl/board/build.sh loopback    # 2. UART pins and baud rate
bash rtl/board/build.sh psram       # 3. PLL, PSRAM controller, calibration
bash rtl/board/build.sh soc         # 4. the whole machine
```

Or from PowerShell, naming Git Bash explicitly:

```powershell
& "C:\Program Files\Git\bin\bash.exe" rtl/board/build.sh soc
```

Flash with either the Gowin Programmer GUI or:

```bash
openFPGALoader -b tangnano9k rtl/board/out/soc/impl/pnr/project.fs
```

**All four stages have run on hardware**, on a Tang Nano 9K over the on-board
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

## Stage 3 — PSRAM

The in-package PSRAM on its own: a PLL, the Gowin controller, its calibration,
and a write-then-read-back check. **Passes on hardware** — LED0 through LED4
all lit, so the PLL locks, calibration completes, and every readback matches.

It earns a stage because it brings three things nothing before it has — a PLL,
a controller that must calibrate before it answers, and a clock domain that is
not the core's. There is deliberately no UART and no clock crossing here; a
crossing is exactly what should not be in the picture while PSRAM itself is
unproven. Everything runs in the controller's own `clk_out` domain and the
result is on the LEDs.

| LED | Meaning (lit = 1) |
|---|---|
| 0 | PLL locked |
| 1 | controller finished calibrating |
| 2 | **write/read test passed** |
| 3 | searching (see below for the finished display) |
| 4 | — |
| 5 | heartbeat, proving `clk_out` runs |

**A burst covers 128 bytes — confirmed on hardware.** The earlier version of
this test wrote a burst at word 16, then one at word 0, then read word 24; only
a 32-word burst reaches word 24 from a write at 0, and it did.

### The write-beat search

The remaining unknown is the dangerous one: **when the 16 write beats are
sampled relative to `cmd_en`**. Reads are self-timed by `rd_data_valid` and
need no guess. Writes do, and a masked write that guesses wrong puts the right
word in the wrong place and clobbers its neighbours with no symptom.

The probe fills a burst uniformly (mask open, so phase-insensitive), writes a
different value over it with the mask open for **one beat only**, and reads that
beat back — the low half must have changed and the high half must not. It tries
every lead from 0 to 15 rather than one per flash.

**The LEDs change meaning once it finishes:**

| | while searching | when finished |
|---|---|---|
| LED5 | heartbeat | heartbeat |
| LED4 | off | **a lead was found** |
| LED3..0 | progress as above | **the lead, in binary** |

A lead of 1 was tried first and failed, so LED4 lit with `0001` on LED3..0 is
not what will come back.

**If LED4 is dark after all sixteen**, the phase is not the problem — per-beat
masking does not work the way this assumes, and the next thing to question is
whether `data_mask` is sampled per beat at all rather than once per command.

0 and 1 lit but never 2 is a controller that calibrated and then would not
accept a command. Reaching 3 without 4 is a memory that is wired and answering
but returning wrong data, which points at the memory clock rather than the
logic.

**LED0 and LED5 only — PLL locked, `clk_out` running, calibration never
finishing — was the first hardware result.** The cause found so far: the
controller was handed the raw reset button, which is pulled up and therefore
reads released from the instant power is applied, so it came out of reset
before the PLL had locked and never got another one. It now waits for lock to
hold for ~10 us. ### What the IP user guide settles

`IPUG943-1.5E`, in `C:\Gowin\...\IDE\doc\EN\`, answers most of what was
otherwise guesswork. Read it before changing anything here.

| Question | Answer |
|---|---|
| What is `clk`? | "Reference input clock, usually on-board crystal oscillator clock" — 27 MHz is right |
| What is `clk_out`? | "user-Logic design clock, 1/2 Memory Clk" — confirms the measured 67.5 |
| Is 135 MHz legal? | **Only if the IP was generated for it.** See below |
| `cmd` polarity | Read `1'b0`, Write `1'b1` |
| What does `addr` index? | A word; single-channel drives two ×8 dies so each address holds 4 bytes. 21 bits = 8 MB |
| How big is a burst, really? | **128 bytes.** `Burst Mode` is bytes *per die* and there are two. See below |
| Command spacing | Table 4-2 by burst length: 16→14, 32→18, **64→26**, 128→42 user clocks |

The command interval was being violated outright — commands were issued about
two cycles apart, gated only on `cmd_rdy`, which does not enforce it.

### A burst is 128 bytes, not 64

`Burst Mode = 64` is bytes **per die**, and single-channel mode drives two ×8
dies in parallel. Derived from two statements in the guide that agree:

- §4.4.3: "The write data occupies **16 CLK cycles** if the burst length is
  64" — 16 beats × 64 bits = 128 bytes.
- §4.4.2: successive bursts step the address by "burst length / 2" = 32 word
  addresses, and each address holds 4 bytes = 128 bytes.

So one burst covers 128 bytes, 16 user beats, 32 word addresses. A cache line
matching one burst is **128 bytes**, which for an 8 KB direct-mapped cache is
64 lines — 6-bit index, 7-bit offset, and about 768 tag flip-flops.

The probe now tests this directly — see LED4 above.

### The IP has a Simulation option, and it must be OFF for hardware

`SIMULATION=true` in `psram_memory_interface_hs.ipc`, and `` `define SIM `` in
the generated `psram_define.v`. The IP's own help page
(`IDE/ipcore/PSRAM_HS/doc/psramhs_help.html`) says of it:

> When simulate the project, click this will speed up. **When running the board
> test must cancel it and generate the IP again.**

It shortens the initialization timing. That is why calibration never completed
on hardware, and it is consistent with everything else observed: the controller
looked healthy in the fabric, ran both clocks, and reached the bus at ~497 µs
before stopping — which is what a shortened init sequence against a real device
would do.

It had been set since before any of this work started and survived a
regeneration, because it is a checkbox that stays where it was left.

**Consequence for simulation.** A board-test netlist and a simulation netlist
cannot be the same file. `rtl/sim/psram_hs_sim.vo` is a tracked copy of the
`SIM` build, kept because it cannot be regenerated without setting the option
again and overwriting the one the bitstream needs. `rtl/sim/psram.sh` uses that
copy; `K2606/` holds the board-test build.

That copy is a **135 MHz, 32-byte-burst** generation and the board build is now
64-byte. It is still the right tool for "does the controller start, does it
reach the bus" — the questions it was written for — but it does not model the
current burst behaviour and should not be trusted for anything at that level.
Regenerating a matching one means toggling the Simulation option on and off
again, which is the trap that cost a day; it is not worth doing without a
reason.

**And expect it to be slower.** With `SIM` cleared the real power-on delays
return — the protocol wants around 150 µs before the first transaction, and the
shortened build already took ~497 µs to reach the bus. Allow a second or two
after reset before reading anything into the LEDs.

### The memory clock is a GENERATION parameter, not an operating range

"Memory Clock — Expected frequency — 50 MHz~166 MHz" appears in Table 6-1,
**Static Parameters**. It is what the IP is *generated* for, and the generated
instance bakes in latency and calibration timing for that number. It is not a
range a given instance tolerates at runtime.

The IP in `K2606/` was generated at **166 MHz** (`MEMORY_CLK=166` in the
`.ipc`) and `k2g_pll.sv` feeds it **135**. That mismatch is the standing
explanation for calibration never completing, and it supersedes an earlier
claim here that 135 was "comfortably legal" — that misread a configuration
option as an operating tolerance.

Two ways to resolve it, and the second is better:

1. **Feed it 166 as generated.** `k2g_pll.sv` can make 166.5 MHz with
   `IDIV_SEL=5, FBDIV_SEL=36, ODIV_SEL=4`. But `clk_out` is then 83 MHz and
   the probe logic placed at about 82 — it would not meet timing, which is
   what drove the clock down in the first place.
2. **Regenerate the IP for a lower Memory Clock.** Everything else unchanged:
   `W955D8MBYA`, 1 channel, Psram Width 8, Dq Width 16, Addr Width 21, Burst
   Mode 64, Fixed Latency. At 135 MHz the user clock is 67.5 and the probe has
   11.5% margin, already measured. Lower still — 108, for a 54 MHz user clock
   — costs nothing that matters: a 13.5 MHz core wants about 0.4 Gbit/s and
   even 54 MHz × 64 bits is 3.4.

Ruled out by measurement rather than argument: the IP's `clk` input. The
post-synthesis netlist has 155 flip-flops on `clk_out` and 14 on `clk_27m`,
and those 14 are the reset chain above — so the controller drives nothing from
`clk` in this configuration and its frequency cannot be the problem.

### Simulating it — `bash rtl/sim/psram.sh`

`psram_memory_interface_hs.vo` is a readable post-PnR model (plain LUTs and
DFFs, not encrypted) and `prim_sim.v` ships with the IDE, so the controller
simulates. **No model of the memory device exists anywhere in the install**, so
calibration cannot converge and `init_calib` will not rise here. The run
answers a narrower question instead: does the controller ever get as far as the
memory?

Two obstacles, neither discoverable:

- Questa Starter refuses to elaborate past 5000 instances and this is about
  18000. Suppressible, but **only by its own id**: `-suppress 14408` is
  accepted and silently does nothing, `-voptargs=-suppress=...` is rejected,
  and `-suppress vopt-14408` works.
- It takes about 18 minutes of wall time for 2 ms of simulated time.

Result, with the memory clock at 135 MHz:

| | |
|---|---|
| `clk_out` edges in 2 ms | 135105 → 67.5 MHz, confirming memory_clk/2 |
| `O_psram_ck` edges | 530510 → ~135 MHz reaching the device |
| `cs_n` first driven low | ~497 µs |
| `cmd_rdy` / `init_calib` | 1 / 0 |

**So the controller is healthy inside the fabric.** It runs both clocks,
finishes its internal startup and addresses the memory; it is not wedged on
clocks, reset, or its own state machine. That rules out the whole class the
reset fix was chasing, and explains why that fix changed nothing on hardware.

It reaches the memory and waits — which in simulation is expected, and on
hardware means the problem is in the interaction with the device. That is where
an IP generated for 166 MHz and driven at 135 would fail.

Incidental but useful: `cmd_rdy` is high while `init_calib` is still low, so
`cmd_rdy` alone is not a valid "ready to use" gate. And initialization takes
around half a millisecond before anything appears on the bus.

| | |
|---|---|
| Logic | 1395 / 8640 (17%) |
| Registers | 719 / 6771 (11%) |
| IOLOGIC | 41 / 97 |

### Clocks, measured rather than assumed

The IP's body is encrypted, so `clk_out` cannot be read from the sources. From
the place-and-route report: the controller divides `memory_clk` by two.

| | |
|---|---|
| `memory_clk` from the rPLL | 135 MHz (27 × 5) |
| `clk_out` | **67.5 MHz**, measured |
| Logic in that domain | 75.25 MHz actual, 11.5% margin |

**135 MHz, not the 166 the IP was configured for.** At 162 the user clock is
81 MHz and this design placed at 81.1 then 82.2 MHz against it — one and a half
percent, which is not a margin. There is nothing to defend by running fast: a
13.5 MHz core wants about 0.4 Gbit/s and 67.5 MHz × 64 bits is 4.3. **If
`init_calib` never rises on hardware, the memory clock is the first thing to
suspect** — 162 MHz is `FBDIV_SEL=5, ODIV_SEL=4` in `k2g_pll.sv`.

## Stage 4 — the full machine

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
module that synthesized fine with either counter alone. Three more are expressions in the wrong place: `$clog2` inline in a part-select
index (`div[$clog2(CLK_DIV)-1]`), a width cast in an expression
(`21'(STEP * (N-1))`, `(AW+1)'(a && b)`), and a **function call inside a
ternary in a continuous assign** (`assign x = c ? y : f(z);`). All are fine in
Questa. All are fine rewritten with the value assigned to a `localparam`
first, built with a concatenation, or moved into an `always_comb`.

The family is the point: GowinSynthesis dies silently on expressions it will
not elaborate, and gives no clue which. When a build fails with an empty log,
suspect the most recently added expression before suspecting anything else. When a build fails with no
message, bisect the source; there will be no diagnostic to read.
