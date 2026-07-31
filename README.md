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
| `docs/attic/` | Superseded code kept for design information. Not built. |
| `decoder.sv`, `ifas.sv`, `padb.sv`, `pipe.sv`, `forwards.sv` | Superseded HDL. See caveat below. |

## Documents

- **[docs/isa-spec.md](docs/isa-spec.md)** — the specification. Start here.
- **[docs/isa-opcodes.md](docs/isa-opcodes.md)** — opcode encodings. *Generated.*
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
halted after 174 instructions
```

| Tool | What it does |
|---|---|
| `kasm` | Assembler. `--listing` disassembles what it produced; `--labels` dumps the symbol table. |
| `kdis` | Disassembler. Built on the emulator's own decoder, so it cannot disagree with what would execute. |
| `emu` | Runner. `--trace` emits per-instruction architectural state for cosimulation; also `--regs`, `--dump`, `--max-steps`. |
| `gen_defs` | Regenerates `rtl/k2g_pkg.sv` and `docs/isa-opcodes.md`. |
| `kgen` | Generates random programs for differential testing. |

## Verifying

```bash
cd emu && cargo test          # emulator, assembler, spec conformance
bash rtl/sim/run.sh           # RTL directed testbenches + program runs
bash rtl/sim/cosim.sh         # lockstep RTL vs emulator, incl. random programs
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

`decoder.sv` and its companions describe a **different instruction set** than the emulator and do
not compile. They are kept for the one idea worth carrying forward — a prefix-carry chain across a
fixed-width fetch window — and for `pipe.sv`'s handshake style. They are **not** a specification,
and their compile failures say nothing about Gowin's SystemVerilog support (see
`docs/gowin-sv-support.md`).
