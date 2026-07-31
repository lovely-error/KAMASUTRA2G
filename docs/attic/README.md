# Attic

Superseded code kept for the design information it carries, not because it
runs. Nothing here is built or tested. Do not treat any of it as a
specification — `emu/src/insns.rs` and `emu/src/interp.rs` are normative.

| File | Was | Why kept |
|---|---|---|
| `gen_enum.rs` | Standalone SystemVerilog enum generator | Superseded by `emu/src/sv_gen.rs`, which is driven by `insns.rs` instead of a hand-copied list. Its commented-out blocks hold an aspirational ~70-entry instruction list including `CHECK_CARRY`, `MULW_RI`, `DISP_REG_ADDR_WIC`, and richer test codes (`TestV_RegCarry`, `TestV_RegOne`, `TestV_RegMinusOne`) that exist in **neither** the emulator nor `decoder.sv`. Closest thing to a record of intended-but-dropped features. |
| `idk.rs` | Sketch of an instruction cache | Existed only as a staged git blob with no working-tree copy; recovered during the repo restructure. Sketches a 4-way column-interleaved memory whose write pattern is essentially the byte-lane striping the BSRAM design uses. |
| `chan.rs` | Two-slot channel | Rust analogue of `pipe.sv`'s handshake. Became dead when `aprox_machine_model.rs` was removed. Note its `has_space = six == rix` allows only one outstanding item, which contradicts the two-slot capacity the deleted `chan_tests.rs` assumed — worth knowing before reusing the semantics. |

Also superseded but left at the repository root for now, being larger and more
frequently referenced: `decoder.sv`, `ifas.sv`, `padb.sv`, `pipe.sv`,
`forwards.sv`. Of these only `pipe.sv` is expected to inform new RTL (its
`PipeCDC` is the right pattern for the phase-6 PSRAM clock crossing).
`decoder.sv` encodes a **different ISA** than the emulator and does not
compile; see `docs/gowin-sv-support.md` for why its failures say nothing about
Gowin's SystemVerilog support.
