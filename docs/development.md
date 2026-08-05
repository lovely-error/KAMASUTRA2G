# Working on K2G

Start here if you are going to change something. What the pieces are, which
script does what, and the traps that have already cost someone a day.

For what the machine *is*, read [isa-spec.md](isa-spec.md). For where it is
going, [v2-plan.md](v2-plan.md).

## The one rule that is not obvious

**Everything that shells out to Gowin or Questa needs Git Bash, not WSL.** On a
Windows box with WSL installed, `bash` resolves to WSL's bash, whose filesystem
has no `C:/Gowin` or `E:/Quartus`. Every script checks and says so rather than
reporting a missing toolchain.

From PowerShell, name it:

```powershell
& "C:\Program Files\Git\bin\bash.exe" rtl/sim/run.sh
```

**And run one simulation script at a time.** The Questa licence here is
nodelocked. A second instance is refused, the error goes into a per-test log
rather than the console, and the run reports failures that are about the licence
rather than the design — a sweep started next to another one comes back full of
mutants that "were not caught" because nothing ever ran. The scripts now refuse
to start rather than let that happen.

## Layout

| Path | What |
|---|---|
| `emu/` | Rust. The emulator is the **normative specification**; the assembler, disassembler, generators and host tool live beside it. |
| `emu/programs/` | 20 `.kasm` test programs. |
| `rtl/` | SystemVerilog. `k2g_pkg.sv` and `k2g_host_pkg.sv` are **generated**. |
| `rtl/tb/` | Testbenches, plus simulation-only models. Kept out of `rtl/` so the board build's `k2g_*.sv` glob cannot reach them. |
| `rtl/sim/` | Simulation scripts. |
| `rtl/board/` | FPGA tops, pin and timing constraints, the build script. |
| `rtl/sv-probe/` | Measures what GowinSynthesis actually accepts. |
| `docs/` | This, and the specifications. |
| `K2606/` | Gowin IDE project. **Not the build path** — it holds the PSRAM IP and nothing else. |

## The Rust side

One crate, `emu/`, with **no dependencies** — deliberately. It is loaded into
Questa as a DPI-C shared object and it is the specification of an instruction
set, so anything added to it has to build in both roles.

```bash
cd emu && cargo test
```

| Binary | What it does |
|---|---|
| `emu` | Runs a program. `--trace` emits per-instruction state for cosimulation; also `--regs`, `--dump <file>`, `--max-steps <n>`, `--mem <n>`, `--org <a>`, `--quiet`. |
| `kasm` | Assembler. `kasm src.kasm -o out.bin`, plus `--listing` (disassembles what it produced) and `--labels`. |
| `kdis` | Disassembler, built on the emulator's own decoder, so it cannot disagree with what would execute. `--org`, `--limit`. |
| `kgen` | Random programs for differential testing. `--seed`, `--count`, `--fault <k>`, `--fault-cause <k>`. |
| `gen_defs` | Regenerates `rtl/k2g_pkg.sv`, `rtl/k2g_host_pkg.sv` and `docs/isa-opcodes.md`. `--check` is the CI form. |
| `mkrom` | Turns an image into `rtl/board/k2g_rom.sv` — the boot ROM, in BSRAM. |
| `kctl` | Drives a board over the serial link. See [host-control.md](host-control.md). |

Tests in `emu/tests/`: `programs.rs` (assemble, run, check output),
`reference_programs.rs` (hand-encoded, cross-checks the assembler),
`spec_conformance.rs` (pins the documented quirks so they cannot be "fixed"),
`faults_and_io.rs`, and `generated_pkg_is_current.rs` (fails if a checked-in
generated file is stale).

**After changing any opcode enum**, regenerate:

```bash
cd emu && cargo run --bin gen_defs
```

`cargo test` fails if you forget.

## Simulating

```bash
bash rtl/sim/run.sh              # every testbench
bash rtl/sim/run.sh tb_decode    # one
```

`GUI=1` keeps the GUI open. `QUESTA=<dir>` overrides the tool location
(`E:/Quartus/questa_fse/win64`).

A testbench prints its own verdict, `TB_PASS <name>` or `TB_FAIL`. The runner
requires the pass line **and** no Questa error **and** a zero exit, so a
testbench cannot pass by saying nothing.

| Testbench | Covers |
|---|---|
| `tb_cosim` | Lockstep against the emulator. Driven by `cosim.sh`, skipped here. |
| `tb_core` | The whole core running real assembled images, UART output checked. |
| `tb_soc` | The whole SoC out of PSRAM, and host control through the pins. |
| `tb_mon` | The host monitor against a bus. |
| `tb_decode` | The prefix accumulator, from spec vectors. |
| `tb_datapath` | ALU, shifter, register file. |
| `tb_icache` / `tb_dcache` | Hit, miss, eviction, dirty writeback, flush. |
| `tb_chan` | The skid buffer under backpressure. |
| `tb_cdc_fifo` | The clock crossing at several ratios. |
| `tb_psram_adapter` | The adapter against a behavioural controller. |
| `tb_uart` | Transmitter and receiver against each other. |
| `tb_psram` | The Gowin IP itself. Needs `psram.sh`. |

### The one that matters

```bash
bash rtl/sim/cosim.sh              # shipped programs + 20 random seeds
bash rtl/sim/cosim.sh 5            # + 5 seeds
bash rtl/sim/cosim.sh 0 hello.bin  # one image
```

It steps both machines one instruction at a time and compares **all**
architectural state after each — 32 values, 32 tags, 32 flag pairs and the jump
latch, about 1200 bits per instruction — then compares memory at the stop.

| Variable | Effect |
|---|---|
| `LATENCY=n` | Extra data-memory latency, 0..n per access. |
| `ILATENCY=n` | The same for fetch, swept separately: a slow fetch and a slow load exercise completely different machinery. |
| `PAUSE=n` | Random host pauses into the core's `fetch_hold`. |
| `NOCACHE=1` | Takes both caches out, so the core faces the latency directly. |
| `PROGRAMS="hello fib"` | A subset. |
| `COUNT=n` | Random program length. |

**`LATENCY` and `PAUSE` are the same argument.** A stall commits nothing and a
pause commits nothing, so every setting must give byte-for-byte identical
results. Anything else means the core is reading state it does not own. A model
that always answers in one cycle cannot tell a design that tolerates variable
latency from one that merely works at one cycle.

Reproduce a failing seed:

```bash
cd emu && cargo run --release --bin kgen -- --seed 7 --count 250 -o r.bin
```

### Tests that are supposed to fail

```bash
bash rtl/sim/mutants.sh          # all of them
bash rtl/sim/mutants.sh rule-3   # those whose name matches
```

A passing testbench proves nothing on its own — it might be checking something
that cannot fail. This breaks the design on purpose and requires the tests to
notice. Mutations apply to a throwaway copy of `rtl/`, never to the tree.

Three outcomes, and the third is the point:

- **ok** — the test behaved as the entry predicts
- **MISSED** — it compiled, ran, and nothing noticed. Either the defect is real
  and untested, or the test is vacuous
- **STALE** — the pattern no longer matches, so nothing was mutated. **This is
  an error, not a skip**: a guard that has quietly stopped guarding is exactly
  what this exists to prevent. Five entries were stale from Phase 2e until
  Phase 5 found them.

**Every new guard gets a mutant it is required to catch.** If a mutant reports
`MISSED` forever because the defect is unreachable, delete it and say why at the
declaration — a test that cannot fail is worse than no test.

### The PSRAM IP alone

```bash
bash rtl/sim/psram.sh
```

Not a pass/fail gate: there is no model of the memory device, so calibration
cannot complete. `rtl/tb/tb_psram.sv` says what it does answer.

## Building for the board

Five staged bitstreams, in order, so a failure says which layer is at fault.

```bash
bash rtl/board/build.sh blink       # 1. toolchain, pinout, clock
bash rtl/board/build.sh loopback    # 2. UART pins and baud rate
bash rtl/board/build.sh psram       # 3. PLL, controller, calibration
bash rtl/board/build.sh mon         # 4. the host protocol, no CPU
bash rtl/board/build.sh soc         # 5. the whole machine
```

`PROG=hello` picks the program built into the SoC's boot ROM (default `hello`);
`GW_SH=<path>` overrides the toolchain. Flash with the Gowin programmer, or:

```bash
"C:/Gowin/Gowin_V1.9.12.02_SP2_x64/Programmer/bin/programmer_cli.exe" --device GW1NR-9C --run 2 --fsFile rtl/board/out/soc/impl/pnr/project.fs
```

`--run 2` is SRAM, which reverts on a power cycle. [bring-up.md](bring-up.md)
has the LED codes, the measured PSRAM timings, and what each stage proves.

**The build script's verdict is the bitstream, not the exit code.** `gw_sh`
exits 1 on builds that produced a perfectly good bitstream, and writes its
output to the console device rather than stdout, so no redirection captures it.
When a build fails and the log is empty, run it by hand and read what it says:

```bash
cd rtl/board/out/soc && "$GW_SH" build.tcl
```

### Does it fit, and does it meet timing

Read the numbers from the place-and-route report at every phase gate, not only
at the end. `build.sh` prints utilization and per-clock Fmax.

**Logic is the binding constraint.** The design is at 97% of 8640 cells. At that
utilization nothing is linear: a change of any size perturbs packing, and the
first thing to fall out of BSRAM is the boot ROM, which costs 128 cells when it
does. Measured deltas do not transfer between builds — a saving of 33 cells
measured on the `mon` stage cost 194 when reversed in the SoC.

```bash
bash rtl/sv-probe/run_synth_check.sh   # synthesize the RTL, report utilization
bash rtl/sv-probe/run_pkg_check.sh     # the generated package still synthesizes
bash rtl/sv-probe/run_probe.sh         # what SystemVerilog Gowin accepts
```

## Running a program on the board

```bash
cd emu
K2G_PORT=COM3 cargo run --release --bin kctl -- run hello.bin
```

Loads it over the serial link, verifies by reading back, resets, resumes, prints
what the program prints and reports the halt. Also `ping`, `status`, `pause`,
`resume`, `peek <addr> <n>`, `poke <addr> <byte>...` and `console`.

Every byte on that link is framed, so **a plain terminal will not show the
console** — `kctl console` does. [host-control.md](host-control.md) is the
protocol and explains what a pause actually does.

## The phase gate

Everything below has to pass, from Git Bash, one at a time:

```bash
cd emu && cargo test
```

```bash
bash rtl/sim/run.sh
```

```bash
bash rtl/sim/cosim.sh
```

```bash
bash rtl/sim/mutants.sh
```

Then synthesize and read the Fmax.

## How drift is prevented

The opcode map exists once, in `emu/src/insns.rs`, declared through a macro that
emits the enum *and* a reflected variant table from the same tokens. `sv_gen`
renders that into `rtl/k2g_pkg.sv` and `docs/isa-opcodes.md`. The host protocol
works the same way: `emu/src/hostproto.rs` into `rtl/k2g_host_pkg.sv`.

This is not incidental tidiness. The superseded `decoder.sv` kept a
hand-maintained copy of the opcode map and silently diverged — `LB_ADD`
numbered 62 against the emulator's 53, the opcode field read from the wrong
bits, duplicate labels no tool flagged. Nothing compared the two, so nothing
noticed.

Four guards make that uncommittable, each verified to actually fail rather than
pass vacuously: `tests/generated_pkg_is_current.rs`, `sv_gen::validate()`
(duplicate enum *values* — SystemVerilog only rejects duplicate *labels*),
`insns::layout_tests`, and `tests/spec_conformance.rs`.

**Never edit a generated file.** They say so at the top.

## Traps, all of them paid for

- **GowinSynthesis fails silently.** It has exited with no diagnostic at all on
  `$clog2` inline in a part-select, on a combinational read with a block-RAM
  attribute, and on simulation-only tasks left visible to it. When a build fails
  with nothing to read, bisect the source.
- **Guard simulation-only code on `SIMULATION`, never `SYNTHESIS`.**
  GowinSynthesis does not define the latter, so `ifndef SYNTHESIS` leaves the
  code visible to it.
- **It will not initialize inferred memory.** `$readmemh` produced no data at
  all. Hence `mkrom`: the program becomes a case statement, and a copier moves
  it into RAM at reset. The read must be **registered** or it costs 128 logic
  cells instead of one BSRAM block.
- **Every clock-domain crossing goes through `k2g_cdc_fifo`.** No ad-hoc
  synchronizers, anywhere. There is no static CDC tool in this toolchain, and
  cosimulation structurally cannot catch metastability — one crossing primitive,
  read carefully, is the only enforcement there is.
- **The `.sdc` must declare unrelated clocks asynchronous.** Until it does, the
  tool tries to close timing on paths that can never be met and may report
  success at something meaningless. A stage file **replaces** the shared one
  rather than adding to it; Gowin will not resolve a clock created in one file
  from a constraint in another.
- **`CLK_DIV` and the `.sdc` move together.** The constraint names the divider
  bit directly, because `clk_sys` does not survive synthesis as a net name.
  Constraining the wrong bit does not error — it reports timing against a clock
  the design does not have.
- **PSRAM does not power up as zeros.** The BSRAM did. A program that reads
  what it has not written gets whatever was there.

## House style

Read `rtl/k2g_shift.sv` for a short example. Two-space indent, `always_comb` and
`always_ff` only, `unique case` with an explicit `default`, active-low
synchronous reset tested first, `u_<name>` instances, `_e`/`_t` type suffixes.

Every module opens with prose saying **why it exists and what it does not do**,
citing spec sections, quoting measured numbers, and naming the specific bug that
motivated the design. Emphasis is capitals, not markup. Inline comments explain
the reasoning, not the code.

Commit subjects are `Phase <N><letter>: <what>` for phase work and plain
imperative sentences otherwise. Bodies are long-form: what was built and why,
the measured cost, the mutants added and whether each was caught, any bug the
work found, and a closing gate line quoting real numbers. Negative results get
their own commits — a measured, reverted attempt is worth more written down than
discarded.
