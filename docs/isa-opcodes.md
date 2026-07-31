<!-- GENERATED FILE -- DO NOT EDIT BY HAND. -->
<!-- Produced by emu/src/sv_gen.rs from emu/src/insns.rs. -->
<!-- Regenerate: cd emu && cargo run --bin gen_defs -->

# K2G opcode tables

Generated from the opcode enums in `emu/src/insns.rs`, which are the
normative definition. Semantics live in [isa-spec.md](isa-spec.md); this
file carries only the encodings, so the numbers cannot drift from the
implementation. The same enums generate `rtl/k2g_pkg.sv`.

## `LB` — 6 bits

Rust `insns::LB`, SystemVerilog `k2g_pkg::lb_e`. 37 of 64 encodings assigned.

| Dec | Bin | Name |
|----:|-----|------|
| 63 | `111111` | `LB_EP1` |
| 62 | `111110` | `LB_PUC8` |
| 61 | `111101` | `LB_PUC16` |
| 60 | `111100` | `LB_PUC32` |
| 59 | `111011` | `LB_CPY` |
| 58 | `111010` | `LB_LD8` |
| 57 | `111001` | `LB_LD16` |
| 56 | `111000` | `LB_LD32` |
| 55 | `110111` | `LB_LDF32` |
| 54 | `110110` | `LB_ST` |
| 53 | `110101` | `LB_ADD` |
| 52 | `110100` | `LB_SUB` |
| 51 | `110011` | `LB_MUL` |
| 50 | `110010` | `LB_DIV` |
| 49 | `110001` | `LB_AND` |
| 48 | `110000` | `LB_OR` |
| 47 | `101111` | `LB_XOR` |
| 46 | `101110` | `LB_SHL` |
| 45 | `101101` | `LB_SHR` |
| 44 | `101100` | `LB_SHRA` |
| 43 | `101011` | `LB_SHLI` |
| 42 | `101010` | `LB_SHRI` |
| 41 | `101001` | `LB_SHRAI` |
| 40 | `101000` | `LB_TST` |
| 39 | `100111` | `LB_TSTN` |
| 38 | `100110` | `LB_LT` |
| 37 | `100101` | `LB_GT` |
| 36 | `100100` | `LB_LTE` |
| 35 | `100011` | `LB_GTE` |
| 34 | `100010` | `LB_DISP` |
| 33 | `100001` | `LB_DISPI` |
| 32 | `100000` | `LB_XCN` |
| 31 | `011111` | `LB_XCP` |
| 30 | `011110` | `LB_XI` |
| 29 | `011101` | `LB_XIZEXT` |
| 28 | `011100` | `LB_BMX_0_0` |
| 27 | `011011` | `LB_RDT` |

Unassigned: 0-26.

## `EP1` — 5 bits

Rust `insns::EP1`, SystemVerilog `k2g_pkg::ep1_e`. 15 of 32 encodings assigned.

| Dec | Bin | Name |
|----:|-----|------|
| 31 | `11111` | `EP1_EP2` |
| 30 | `11110` | `EP1_UTO` |
| 29 | `11101` | `EP1_SS` |
| 28 | `11100` | `EP1_NOT` |
| 27 | `11011` | `EP1_NEG` |
| 26 | `11010` | `EP1_DISP_OFF` |
| 25 | `11001` | `EP1_DISP_ABS` |
| 24 | `11000` | `EP1_SR` |
| 23 | `10111` | `EP1_ESP` |
| 22 | `10110` | `EP1_LTL` |
| 21 | `10101` | `EP1_SL` |
| 20 | `10100` | `EP1_LLC_B8` |
| 19 | `10011` | `EP1_LLC_B16` |
| 18 | `10010` | `EP1_LLC_B32` |
| 17 | `10001` | `EP1_LLC_F32` |

Unassigned: 0-16.

## `EP2` — 5 bits

Rust `insns::EP2`, SystemVerilog `k2g_pkg::ep2_e`. 8 of 32 encodings assigned.

| Dec | Bin | Name |
|----:|-----|------|
| 31 | `11111` | `EP2_FLAG` |
| 30 | `11110` | `EP2_CSP` |
| 29 | `11101` | `EP2_TC` |
| 28 | `11100` | `EP2_DNO` |
| 27 | `11011` | `EP2_MPI` |
| 26 | `11010` | `EP2_MPD` |
| 25 | `11001` | `EP2_HALT` |
| 24 | `11000` | `EP2_ICINVR` |

Unassigned: 0-23.

## `CC` — 5 bits

Rust `insns::CC`, SystemVerilog `k2g_pkg::cc_e`. 5 of 32 encodings assigned.

| Dec | Bin | Name |
|----:|-----|------|
| 31 | `11111` | `CC_OVERFLOW_SET` |
| 30 | `11110` | `CC_FLAG_SET` |
| 29 | `11101` | `CC_VALUE_ZERO` |
| 28 | `11100` | `CC_VALUE_NEGATIVE` |
| 27 | `11011` | `CC_VALUE_POSITIVE` |

Unassigned: 0-26.

## `RDT` — 3 bits

Rust `insns::RDT`, SystemVerilog `k2g_pkg::rdt_e`. 7 of 8 encodings assigned.

| Dec | Bin | Name |
|----:|-----|------|
| 6 | `110` | `RDT_S32` |
| 5 | `101` | `RDT_S16` |
| 4 | `100` | `RDT_S8` |
| 3 | `011` | `RDT_F32` |
| 2 | `010` | `RDT_U32` |
| 1 | `001` | `RDT_U16` |
| 0 | `000` | `RDT_U8` |

Unassigned: 7.

