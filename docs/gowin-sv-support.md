# GowinSynthesis SystemVerilog support — measured

**Tool:** GowinSynthesis V1.9.12.02_SP2 (64-bit), Gowin IDE V1.9.12.02_SP2_x64
**Device:** GW1NR-9C / GW1NR-LV9QN88PC6/I5
**Date measured:** 2026-07-31
**Method:** `rtl/sv-probe/run_probe.sh` — one construct per file, each pushed through
`gw_sh.exe` with `set_option -verilog_std sysv2017`, then the emitted netlist
(`impl/gwsynthesis/project.vg`) inspected to confirm the *expected* primitives appeared.

## Why this document exists

SUG550 (GowinSynthesis User Guide, p.10) says only *"Supports Verilog/SystemVerilog, VHDL and
mixed design input"* and publishes **no construct-level support matrix** anywhere in its 98 pages.
Planning assumed a restrictive subset. **That assumption was wrong** — measurement contradicted it
on every point, so the RTL coding style is set by this table, not by guesswork.

## Results

| # | Construct | Result | Netlist evidence |
|---|---|---|---|
| 01 | `typedef enum logic [N:0]` + `case` | **PASS** | `LUT4:2 LUT3:1` — case decoded to logic |
| 02 | `typedef struct packed` | **PASS** | pure wiring (bit permutation), as expected |
| 03 | `union packed` | **PASS** | pure wiring; see note below |
| 04 | `interface` + `modport` | **PASS** | `DFF:16 ALU:15` — counter across the interface |
| 05 | `module #(parameter type T)` | **PASS** | `DFF:16` — `T=logic[15:0]` elaborated correctly |
| 06 | assignment patterns `'{f: v}` | **PASS** | pure wiring |
| 07 | multi-dim packed `logic [7:0][15:0]` | **PASS** | `LUT3:64 MUX2_LUT5:32 MUX2_LUT6:16` — 8:1 mux |
| 08 | packed array of structs | **PASS** | `LUT3:16 MUX2_LUT5:8` — 4:1 mux |
| 09 | `always_comb` / `always_ff` / `logic` | **PASS** | `DFFR:8 ALU:7` |
| 10 | `package` / `endpackage` / `import ::*` | **PASS** | `LUT4:1 LUT3:1` — comparator against enum |
| 11 | `function automatic` (both `name=` and `return`) | **PASS** | pure wiring |
| 12 | `generate` / `genvar` + part-select | **PASS** | `DFFE:32` — 4 byte lanes with enables |

**12 of 12 pass.** No construct tested required a workaround.

### Notes on the three probes that emitted warnings

All three warnings are `CV0016`/`CV0020` "input unused", and in each case the input genuinely *is*
unused — they confirm correct elaboration rather than indicating a problem:

- **p03 (`union packed`)** warns that `pick` is unused. Both arms of the `pick ? :` reduce to
  `cp[9:0]`: `u.f610.imm` is `cp[9:0]`, and `{u.f655.a1, u.f655.a2}` is `{cp[9:5], cp[4:0]}`. The
  tool could only prove those equal by mapping the union's overlapping fields correctly. This is
  positive evidence.
- **p10 / p11** warn that `cp[4:0]` is unused, which is correct — neither module outputs `arg2`.

## Consequences for the K2G RTL

Two findings change the plan's design freedom:

1. **`interface` + `modport` works** (p04), so `pipe.sv`'s handshake style can be kept as an
   interface rather than being flattened into `put`/`full`/`data` port triples.
2. **`struct packed` and packed arrays of structs work** (p02, p08), so the ~210-bit D→X uop
   bundle can be a named struct instead of a flat vector with `localparam` bit offsets. This is a
   large maintainability win in the decoder.

Also confirmed, and load-bearing for the area estimate: **GowinSynthesis emits the dedicated
`MUX2_LUT5` / `MUX2_LUT6` mux primitives** (p07, p08) rather than building wide muxes out of
LUT4s. The register file's 32:1 tag/flag read muxes were budgeted assuming this; that assumption
now has evidence behind it.

`parameter type T` also works (p05), but **keep avoiding it** — it is a thin corner of SV that
Vivado and Design Compiler handle inconsistently, and parameterizing by `WIDTH` costs nothing.
This is a portability choice, not a Gowin limitation.

## Scope and limits of this measurement

- Covers **synthesis only** (`run syn`). Place-and-route was not run; language constructs fail at
  synthesis, but resource-level surprises can still appear later.
- Probes are small and exercise one construct each. Deeply nested combinations (e.g. a packed
  array of structs containing unions, passed through a parameterized interface) are untested.
- `decoder.sv`'s failure to compile is **not** evidence about SV support. Its errors — duplicate
  enum labels (`LB_GTE` at both 53 and 35; `EP2_SHRR` at both 26 and 21), undeclared
  `prefix_out_valid` / `store_aug` / `Lane`, and typedefs declared after the module using them —
  fail in every tool. It was also never listed in `K2606.gprj`, so it has never been synthesized.

## Reproducing

```bash
bash rtl/sv-probe/run_probe.sh
```

Override the toolchain location with `GW_SH=/path/to/gw_sh.exe`. Per-probe logs and netlists land
in `rtl/sv-probe/out/<probe>/`. Re-run after any Gowin IDE upgrade.

## Questa (simulation) — verified separately

`E:\Quartus\questa_fse\win64`, **Questa Altera Starter FPGA Edition-64 2025.2**.

| Capability | Result |
|---|---|
| SystemVerilog structs, packed unions, enums | works |
| **DPI-C, SV → Rust** | works — a `cdylib` built with the MSVC toolchain loads via `vsim -sv_lib` |
| DPI-C array transfer | works with **fixed-size** unpacked arrays (`output int unsigned regs [4]`), which pass a pointer to the first element |

Unsized open arrays (`regs []`) pass an `svOpenArrayHandle`, not a pointer, and
silently read back as zeros against a plain `*mut u32` — declare fixed sizes.

This matters because the whole Phase 4 verification strategy is lockstep
cosimulation driving the Rust emulator through DPI, so it was proven before any
RTL was written.

## SSRAM inference — measured, and it decides the pipeline

The 3-stage F/D/X design depends on the register file's value array having an
**asynchronous** read: that is what lets one decode cycle do register read →
forward → address add → memory address. A synchronous (BSRAM) read would force
a fourth stage. So whether GowinSynthesis infers async-read SSRAM matters more
than any other synthesis question here.

It does, but only from a specific shape. Measured on 32×32 arrays:

| Shape | Result |
|---|---|
| 1 write port, 1 async read, no reset | `RAM16SDP4:16` ✅ |
| 1 write port, **2** async reads, no reset | `RAM16SDP4:32` ✅ |
| 1 write port, 2 async reads, **reset loop over the array** | `RAM16SDP4:32` plus `RAM16SDP1:8`, `DFFRE:8` and ~85 extra LUTs — infers, but pays for it |
| **2 write ports** | **no RAM at all** — collapses to flip-flops |

The last row is the one that bites. A first version of `k2g_regfile` added a
second write port for the widening multiply's high half and the jump link
register. A RAM cannot have two write ports, so the array became 1120
flip-flops with ~3700 LUTs of read muxing — against a ~375 LUT budget for the
whole file.

Both of those writes are already specified as separate cycles (spec 5.5, 6.3),
so the core serializes them and the array keeps one port:

| | LUT | FF | RAM prims |
|---|---:|---:|---|
| two write ports | ~3700 | 1120 | 0 |
| **one write port** | **~580** | **~112** | `RAM16SDP4:32` |

The value array deliberately has no reset, which is what keeps it clean; the
tag and flag arrays do reset, because an undefined tag is architecturally
observable (it decides store width and comparison signedness).

**Rule of thumb: synthesize each module as it is written, not at integration.**
Both of the significant area surprises so far were invisible in simulation.
