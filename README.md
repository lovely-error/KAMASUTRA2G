# KAMASUTRA2G

A custom 16-bit-codepoint / 32-bit-datapath instruction set, its emulator, and an in-progress
implementation targeting a Gowin **GW1NR-9C** (Tang Nano 9K class) FPGA.

The goal is a machine that boots a program from on-chip BSRAM and talks to a UART console, with
the Rust emulator as the normative specification and differential cosimulation proving the RTL
matches it.

## What makes this ISA unusual

- **Variable-length instructions built from a prefix chain.** Zero or more 16-bit prefix code
  points accumulate flags, then one main code point commits. Several prefixes don't modify the
  main opcode — they *replace* it (`BMX`+`SHL` is a bit-field extract, `CSP`+`LD` is an I/O port
  read).
- **Per-register type tags and flags.** Each register carries 32 bits of value plus a 2-bit width
  tag and 2 flag bits. Stores take their width from the *source register's tag*; comparisons write
  only the *left operand's* flag bit. There is no global condition register.
- **Split branches.** `PrepareJump` primes a hidden latch; a separate `PerformJump` commits it.
  The gap is where hardware prefetches the target, which makes a taken branch free.
- **Universal predication.** Any instruction may be guarded on any register's flags or value.

## Layout

| Path | What |
|---|---|
| `emu/` | Rust emulator — **the normative spec**. Also generates the RTL opcode package. |
| `rtl/` | SystemVerilog. `k2g_pkg.sv` is generated; do not edit it by hand. |
| `rtl/sv-probe/` | Measures which SystemVerilog constructs GowinSynthesis accepts. |
| `docs/` | Specification and findings. |
| `K2606/` | Gowin IDE project (currently PSRAM IP only). |
| `docs/attic/` | Superseded code kept for design information. Not built. See caveat below. |

## Documents

- **[docs/development.md](docs/development.md)** — how to work here: every script,
  what it does, the phase gate, and the traps that have already cost someone a day.
  **Start here if you are going to change something.**
- **[docs/isa-spec.md](docs/isa-spec.md)** — the specification. Start here to
  understand the machine.
- **[docs/isa-opcodes.md](docs/isa-opcodes.md)** — opcode encodings. *Generated.*
- **[docs/toolchain.md](docs/toolchain.md)** — `kasm` and `kdis`: assembly syntax, every
  mnemonic, prefixes, directives and diagnostics.
- **[docs/bring-up.md](docs/bring-up.md)** — getting the machine onto a Tang Nano 9K.
- **[docs/host-control.md](docs/host-control.md)** — the wire protocol `kctl` speaks to
  the board: framing, commands, and what a pause actually does.
- **[docs/gowin-sv-support.md](docs/gowin-sv-support.md)** — which SystemVerilog constructs the
  Gowin toolchain actually accepts, measured rather than assumed.

## Running a program

```bash
cd emu
cargo run --bin kasm -- programs/hello.kasm -o hello.bin
cargo run --bin emu  -- hello.bin
```

```
Hello from KAMASUTRA2G!
halted after 181 instructions
```

## Running one on a board

The program no longer has to be built into the bitstream. With the `soc`
bitstream flashed:

```bash
cd emu && K2G_PORT=COM3 cargo run --bin kctl -- run hello.bin
```

`kctl` stops the core, writes the image over the serial link, reads it back and
compares, resets and lets go. `kctl console` shows what the program prints,
`kctl peek <addr> <count>` dumps memory, and `kctl status` reports why a stopped
machine stopped — which used to be readable only from six LEDs, since a halted
core cannot execute the CSP read that would report its own fault cause.

Every byte on that link is framed, so a plain terminal will not show the console.
[docs/host-control.md](docs/host-control.md) says why and what the frames are.

| Tool | What it does |
|---|---|
| `kasm` | Assembler. `--listing` disassembles what it produced; `--labels` dumps the symbol table. |
| `kdis` | Disassembler. Built on the emulator's own decoder, so it cannot disagree with what would execute. |
| `emu` | Runner. `--trace` emits per-instruction architectural state for cosimulation; also `--regs`, `--dump`, `--max-steps`. |
| `gen_defs` | Regenerates `rtl/k2g_pkg.sv` and `docs/isa-opcodes.md`. |
| `kgen` | Generates random programs for differential testing. |
| `kctl` | Drives a board over the serial link: load, run, pause, read and write memory, console. |

## Verifying

Everything that shells out to Gowin or Questa needs **Git Bash, not WSL** —
WSL cannot reach the Windows toolchains. From PowerShell, name it explicitly:
`& "C:\Program Files\Git\bin\bash.exe" <script>`. The scripts detect this
and say so.

**Run one of these at a time.** The Questa licence here is nodelocked and refuses
a second concurrent instance:

```
** Error: License checkout has been disallowed because ... an instance of
QuestaSim is already running with a nodelocked license on this machine.
```

That error lands in the per-test log rather than on the console, so a second run
started while `mutants.sh` is going does not fail loudly — it produces a sweep
full of mutants that "were not caught" because nothing ever ran. `mutants.sh`
already waits for its own simulator to exit between mutants; what it cannot do
is wait for yours.

```bash
cd emu && cargo test          # emulator, assembler, spec conformance
bash rtl/sim/run.sh           # RTL directed testbenches + program runs
bash rtl/sim/cosim.sh         # lockstep RTL vs emulator, incl. random programs
bash rtl/sim/mutants.sh       # break the RTL on purpose; the tests must notice
```

The third is the one that matters most. It steps both machines one instruction
at a time and compares **all** architectural state after each — 32 register
values, 32 type tags, 32 flag pairs, and the jump latch, roughly 1200 bits per
instruction. Programs come from `emu/programs/` plus `kgen`, which generates
random straight-line programs weighted toward the combinatorial part of the
ISA: prefixes × main opcodes × tags × condition codes.

A failing seed is reproducible:

```bash
cd emu && cargo run --release --bin kgen -- --seed 7 --count 250 -o r.bin
```

Injectable memory latency, because a model that always answers in one cycle cannot tell a design
that tolerates variable latency from one that merely works at one cycle:

```bash
LATENCY=40 bash rtl/sim/cosim.sh
```

A stall is architecturally invisible by construction — nothing commits during one — so every
latency setting must give byte-for-byte identical results. Anything else means the core is reading
state it does not own.

The same argument, and the same shape of test, for the host's pause:

```bash
PAUSE=8 bash rtl/sim/cosim.sh
```

`fetch_hold` stops the front end and the pipeline drains, so the stop lands mid
prefix chain, with a load outstanding, between a widening multiply's two cycles —
and none of it may be visible. The run reports how many pauses actually fired, so
a rate that never paused cannot pass by looking like success.

### Tests that are supposed to fail

A passing testbench proves nothing on its own; it might be checking something that cannot fail.
`rtl/sim/mutants.sh` breaks the design on purpose and requires the testbenches to *notice*:

| Mutant | Caught by |
|---|---|
| `up.ready` follows `down.ready` — a channel's rule 3 | `tb_chan` |
| one-entry buffer instead of two — passes everything else, runs at half rate | `tb_chan` |
| skid buffer ignores `flush` | `tb_chan` |
| a load assumes memory answers in one cycle | `cosim` |
| a pause abandons the fetch stream | `cosim` **only with `PAUSE` set** |
| the monitor accepts a frame with a bad CRC | `tb_mon` |
| the monitor takes the memory bus before the caches are coherent | `tb_mon` |

The last row of that table used to be the load mutant, with the note that it passes the entire
cosimulation at `LATENCY=0` and diverges after 41 instructions at `LATENCY=40` — one defect,
invisible without latency injection and fatal with it. **That is no longer true**, and the reason
is Phase 2e: the bus request is registered now, so an access occupies the memory stage for at least
two cycles even against memory that answers immediately, and the mutant is caught in every
configuration the design still has. Latency injection is not thereby less valuable — it is how the
whole variable-latency contract was proved — but this particular demonstration of it is gone, and
`rtl/sim/mutants.sh` records the reversal where the entry used to be.

The pause row is the replacement argument, for host control: a pause commits nothing, so `PAUSE=0`
cannot tell a correct one from a broken one.

Mutations apply to a throwaway copy of `rtl/`, never to the tree. A mutation whose pattern no
longer matches is reported as `STALE` and fails the run, rather than being skipped — a guard that
has quietly stopped guarding is the exact thing this is meant to prevent.

## Building

```bash
cd emu && cargo test
```

Regenerate the RTL opcode package and the opcode tables after changing any opcode enum:

```bash
cd emu && cargo run --bin gen_defs
```

`cargo test` fails if the checked-in generated files are stale, and `gen_defs --check` is the CI
form. Verify the generated package still synthesizes:

```bash
bash rtl/sv-probe/run_pkg_check.sh
```

## How drift is prevented

The opcode map exists once, in `emu/src/insns.rs`. The four opcode enums are declared through a
macro that emits the enum *and* a reflected variant table from the same tokens; `sv_gen` renders
that into both `rtl/k2g_pkg.sv` and `docs/isa-opcodes.md`.

This is not incidental tidiness. The superseded `decoder.sv` kept a hand-maintained copy of the
opcode map and silently diverged: `LB_ADD` numbered 62 against the emulator's 53, the opcode field
read from `lane[5:0]` instead of `cp[15:10]`, and duplicate labels (`LB_GTE` at both 53 and 35)
that no tool ever flagged. Nothing compared the two, so nothing noticed.

Four guards now make that uncommittable, each verified to actually fail rather than pass
vacuously:

| Guard | Catches |
|---|---|
| `tests/generated_pkg_is_current.rs` | generated files out of sync with `insns.rs` |
| `sv_gen::validate()` | duplicate enum *values* (SystemVerilog only rejects duplicate *labels*) |
| `insns::layout_tests` | field positions disagreeing with `pack_6_5_5`/`pack_6_10` |
| `tests/spec_conformance.rs` | the spec's documented quirks being "fixed" in the emulator |

## A caveat about the superseded HDL

An earlier attempt at this machine — `decoder.sv`, `ifas.sv`, `padb.sv`, `forwards.sv` — described
a **different instruction set** than the emulator and did not compile. It has been deleted; `v1`
and earlier tags still have it. Only `docs/attic/pipe.sv` is kept, for its handshake style, which
v2 builds on (see [docs/v2-plan.md](docs/v2-plan.md)). It is **not** a specification, it is not
built, and its compile failures say nothing about Gowin's SystemVerilog support — see
`docs/gowin-sv-support.md`, which measures that directly.
