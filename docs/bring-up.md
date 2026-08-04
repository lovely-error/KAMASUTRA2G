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
sequence and wraps back to zero after 2971215073.

**Its term rate is a clock-speed measurement, not a feature.** The delay is a
software loop of 1125000 iterations, tuned once for v1: three instructions at
six cycles each at 6.75 MHz, giving one second. Neither number has held.

| | cycles per iteration | term period | how |
|---|---|---|---|
| v1, BSRAM at 6.75 MHz | 6 | 1.00 s | as tuned |
| after Phase 2, BSRAM at 13.5 MHz | **9** | 0.75 s | measured, `tb_core` |
| after Phase 3, PSRAM at 13.5 MHz | **59.4** | **4.95 s** | measured, `tb_soc` |
| after Phase 4b, with the I-cache | **9** | **0.75 s** | measured, `tb_soc` |

The loop touches no data memory, so every one of those cycles is instruction
fetch. Measured in the loop: **3 code points per instruction, and 6.6 `clk_sys`
cycles per bus access** against 1.0 over BSRAM. 6.6 cycles at 13.5 MHz is
489 ns, which is the PSRAM command interval — 32 `clk_out` cycles at 67.5 MHz
is 474 ns — plus the clock crossing.

The slowdown was not the core, the crossing or the adapter being wasteful: it
was that every code point was a separate 128-byte burst of which 124 bytes were
discarded, and the discarded part was where the next 63 code points were.
**The instruction cache closed it exactly as predicted** -- its line is one
burst, this nine-code-point loop fits inside one line, and the loop is back to
1.0 cycle per code point with zero bus traffic. The 0.75 s row is computed from
that measured CPI and has not been timed on a board.

**Stage 4 has run with PSRAM as memory**, executing `fibforever` out of the
in-package PSRAM and printing the sequence correctly. `hello` has not been
flashed since the change.

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

### The PSRAM interface, as measured

Everything the adapter needs, confirmed on hardware rather than inferred. Each
line here cost a flash; none of it should be re-derived.

| Property | Value |
|---|---|
| `addr` | word address, 4 bytes per word, 21 bits = 8 MB |
| One burst | **128 bytes** — 32 word addresses, 16 user beats of 64 bits |
| `cmd` | `0` read, `1` write |
| Minimum gap between commands | **26 user clocks** at burst 64 (Table 4-2) |
| Write beat 0 | **the same cycle as `cmd_en`** — lead 0 |
| Write data | must be **held for all 16 beats** |
| `data_mask` | per **byte** of the 64-bit beat, `1` masks, `0` writes |
| `data_mask` timing | sampled **per beat**, so partial writes work |
| Reads | self-timed — count `rd_data_valid`, beat 0 is the first |
| `cmd_rdy` | high before `init_calib`; not a "ready to use" gate |
| `clk_out` | `memory_clk / 2` = 67.5 MHz |

For a 32-bit access at byte address `A`: `word = A[22:2]`, burst base is
`word & ~31`, the word sits in beat `word[4:1]` and in the low half when
`word[0]` is 0. A partial write opens `data_mask` for that beat only, with
`~we` on the relevant four byte lanes and `4'hF` on the others.

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

**A dark LED4 does not necessarily mean the phase is wrong.** The first run of
this search reported failure for all sixteen leads, and the fault was in the
test: it changed `wr_data` the cycle after `cmd_en`, while the uniform fill
burst was still streaming, so the background was half one value and half the
other and no lead could ever match. Write data must be **held for the whole
burst**.

That is worth remembering generally — `cmd_en` is one cycle but the transfer it
starts is sixteen, and anything feeding it has to stay still for all of them.
The geometry test escaped this only because it changed the address after
issuing, never the data.

If LED4 is dark *after* that fix, then the phase really is not the problem, and
the next thing to question is whether `data_mask` is sampled per beat at all
rather than once per command. If it is not, partial writes need read-modify-
write with a full-burst writeback and the mask held wide open — more work per
write, but no masking to get wrong.

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

### The PLL will not take every divider, and says nothing when it refuses

Retuning to 81 MHz took four builds because `ODIV_SEL` is not free and every
rejection is `gw_sh exit 1` with a **zero-byte log**:

| FBDIV_SEL | ODIV_SEL | CLKOUT | VCO | |
|---|---|---|---|---|
| 2 | 8 | 81 | 648 | fails |
| 4 | 8 | 135 | 1080 | fails — so it is ODIV 8 itself, not the frequency |
| 2 | 6 | 81 | 486 | fails — VCO too low in practice |
| 4 | 6 | 135 | 810 | **works** (the old setting) |
| 2 | 10 | 81 | 810 | **works** (the current one) |

So the documented VCO range of 400–1200 MHz is wider than this part accepts,
and `ODIV_SEL` takes some values and not others. Keeping VCO at **810** — the
one value proven twice — is the cheap way to stay out of it. `k2g_pll.sv`
carries this table too.

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
   Mode 64, Fixed Latency. At 135 MHz the user clock is 67.5 MHz. An earlier
   version of this line claimed 11.5% margin there; the place-and-route report
   for the `psram` stage says **67.196 MHz against a 67.500 requirement**, so
   the probe does not quite close on that clock and never did. It works on
   hardware anyway. The `soc` build reports 68.63 MHz for the same clock, under
   a constraint set that names the PLL output as well — see stage 4. Lower still — 108, for a 54 MHz user clock
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
| `memory_clk` from the rPLL | 81 MHz (27 × 3), was 135 |
| `clk_out` | **40.5 MHz** (was 67.5, measured) |
| Logic in that domain | 75.25 MHz actual, 11.5% margin |

**135 MHz, not the 166 the IP was configured for.** At 162 the user clock is
81 MHz and this design placed at 81.1 then 82.2 MHz against it — one and a half
percent, which is not a margin. There is nothing to defend by running fast: a
13.5 MHz core wants about 0.4 Gbit/s and 67.5 MHz × 64 bits is 4.3. **If
`init_calib` never rises on hardware, the memory clock is the first thing to
suspect** — 162 MHz is `FBDIV_SEL=5, ODIV_SEL=4` in `k2g_pll.sv`.

## Stage 4 — the full machine

```
boot ROM -> copier -> 8 MB in-package PSRAM -> K2G core -> UART
```

Runs `emu/programs/hello.kasm` by default and should print
`Hello from KAMASUTRA2G!` once at reset. Build a different program with:

```bash
PROG=fib bash rtl/board/build.sh soc
```

**Memory is PSRAM as of Phase 3.** `k2g_mem`'s four BSRAM blocks are gone, and
the controller IP takes four of its own, so the total is unchanged at 7 of 26 —
see the table. Three things follow that are worth knowing before reading an
LED:

- The machine takes **hundreds of microseconds to start**, waiting for the
  controller to calibrate, and the boot copy itself now takes about 100 µs
  rather than 168 cycles: a byte write to PSRAM is a whole 128-byte burst.
  Both are invisible to a human.
- **PSRAM does not power up as zeros.** The BSRAM did. A program that reads a
  location it never wrote used to get 0 and now gets whatever was there.
  Nothing in `emu/programs/` does, but a program that behaves differently here
  than under cosimulation should be suspected of it first.
- The core and the memory are **two clock domains**, crossed only inside
  `k2g_psram` through `k2g_cdc_fifo`. `tangnano9k_soc.sdc` declares them
  asynchronous; nothing in simulation can check that.

| | before PSRAM | with PSRAM |
|---|---|---|
| Logic | 4412 / 8640 (51%) | **7637 / 8640 (89%)** |
| Registers | 1155 / 6771 (17%) | **2239 / 6771 (34%)** |
| BSRAM | 7 / 26 (4 `k2g_mem` + 3 regfile) | **15 / 26** (4 IP + 3 regfile + 4 I$ + 4 D$) |
| Bitstream | 3.5 MB | 3.5 MB |

The controller IP is most of the growth: the `psram` stage builds the IP with
almost nothing else and comes to 1540 logic and 839 registers. `k2g_psram`
itself measures 362 logic cells and 220 registers.

**The register file is still in BSRAM**, three `SDPB` in `k2g_regfile`,
confirmed in the netlist. It moved there at Phase 2b when registering the uop
gave synthesis a registered read address, and nothing since has disturbed it —
none of the logic growth here is the register file falling back to flip-flops,
which would have cost about 1120 registers and 3700 LUTs on its own.

**The cache budget is 19 blocks, not 26.** Deleting `k2g_mem` freed four and
the IP took four back. That happens to be the number `docs/v2-plan.md` already
assumed, but for a different reason than it says.

### The LEDs are the debugger

A halted core cannot execute the `CSP` read that would report its own fault
cause (spec §8), so the LEDs carry it instead. Active low, so a lit LED is a 1.

| Pattern | Meaning |
|---|---|
| LED5 blinking, LED0 lit, nothing else | **PSRAM has not calibrated** — see stage 3 |
| all six lit | boot copier running |
| LED5 blinking, LED0-4 from `GPIO_OUT` | running normally |
| `100000` | clean `HALT` |
| `1cccccc` — top bit set, low five the cause | faulted; cause per spec §8 |

So `1` followed by `00110` is cause 0x06, `MISALIGNED_LOAD`.

The first row is deliberately unlike the others: it is the one failure that is
about the board rather than the program, and a machine that never starts is
otherwise indistinguishable from a machine with no memory.

## Timing

The design does **not** meet timing at the board's 27 MHz crystal, so the core
runs on a divided clock. It is now a divide-by-**2** at **13.5 MHz**.

| | Constraint | Actual Fmax | Logic levels |
|---|---|---|---|
| v1, single-cycle execute | 6.75 MHz | 10.0 MHz | 28 |
| after Phase 2b, decode split out | **13.5 MHz** | **16.3 MHz** | **13** |
| after Phase 3, memory is PSRAM | **13.5 MHz** | **17.99 MHz** | 22 |
| after Phase 4b, with the I-cache | **13.5 MHz** | **15.85 MHz** | 24 |
| after Phase 4c, with both caches | **13.5 MHz** | **14.35 MHz** | 22 |

**Observed running on hardware** at 13.5 MHz after a rebuild and reflash, from
the Phase 2b build.

### Three clocks, and what does and does not close

Phase 3 added the memory domain. The design's own clocks all meet:

| Clock | Constraint | Actual Fmax | Logic levels |
|---|---|---|---|
| `clk_27m` | 27.000 MHz | 120.7 MHz | 5 |
| `clk_sys` | 13.500 MHz | 14.35 MHz | 22 |
| `clk_out` (PSRAM user side) | 40.500 MHz | 55.39 MHz | 7 |

**Every setup path closes.** That took regenerating the IP for a **81 MHz**
memory clock, down from 135, which makes `clk_out` 40.5 MHz.

It was not always so. With both caches in and the memory clock still at 135,
`clk_out` reported **64.63 MHz against a 67.500 requirement** — 29 failing
setup endpoints. The caches are not in that domain and never were; they are
entirely in `clk_sys`. What they did was take up area, and at 89% utilization
the placer had less room, so the `clk_out` logic spread out and its routes
grew. The same endpoints measured **+0.10 ns at 76% utilization** and
**-0.66 ns at 89%**.

Lowering the memory clock fixes it by making the requirement smaller rather
than the logic faster, which is the only lever that reaches paths this design
mostly does not own. 81 was picked over 108 to close the controller's INTERNAL
`memclk` <-> `clk_out` group as well: those needed the memory-clock period
1.59x longer, so <= 85 MHz, and 81 is the clean 27 x 3 point below it.

| | at 135 MHz | at 81 MHz |
|---|---|---|
| setup violations | 29 | **0** |
| `clk_out` | 64.63 against 67.50 | **55.39 against 40.50** |
| `clk_sys` | 15.89 against 13.50 | 14.35 against 13.50 |

Two things worth keeping in view. `clk_sys` moved from 15.89 to 14.35 across
that rebuild although nothing in its domain changed — that is placement spread
at 89% utilization, and 6% is the narrowest margin it has had. And the cost of
the slower memory clock is miss latency only: 40.5 MHz x 64 bits is 2.6 Gbit/s
against the 0.4 a 13.5 MHz core can use.


**The fifteen hold violations are all inside the IP** — the DLL's step signals and the SERDES `CALIB` pins, on paths
between the controller's own 135 MHz and its 67.5 MHz user clock. None touch
the core, the adapter or the CDC FIFOs. The `psram` stage, which passes on
hardware, reports **557** violated endpoints of the same class, so this is
pre-existing to anything in this repository.

### Constraining the PSRAM user clock, which is easy to get wrong

`clk_out` comes from a `CLKDIV` inside the IP. Three things had to be
discovered by building:

- The tool derives it correctly by itself, as
  `<instance>/u_psram_top/clkdiv/CLKOUT.default_gen_clk` — but **that name
  cannot be used in `set_clock_groups`**. Auto-derivation happens after the
  constraints are read, so `get_clocks` on it fails with "Cannot get clock with
  name". It has to be declared to be named.
- Declaring it with **`create_clock` is wrong**. A base clock has no master, so
  the tool stops knowing that this clock and the 135 MHz it is divided from
  share a source, and analyses every path between them with an invented 7.4 ns
  relation and 4.5 ns of skew. The reported Fmax *rose* from 67.2 to 70.0 MHz
  and fifty IP-internal paths became violations — a constraint that made the
  report look better while meaning less.
- `create_generated_clock -source` will only accept a point where a clock has
  already been declared, which the PLL output is not. So the PLL's 135 MHz is
  declared too, at the ratio the tool would have derived, purely to give
  `clk_out` a master to hang from.

And Gowin's SDC parser does **not** accept a backslash line continuation:
`syntax error near token ''`, and the build stops.

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
