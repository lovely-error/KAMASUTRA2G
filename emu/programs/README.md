# Programs

Source for the K2G test and demonstration programs.

```bash
cd emu
cargo run --bin kasm -- programs/hello.kasm -o hello.bin
cargo run --bin emu  -- hello.bin
```

| Program | What it does |
|---|---|
| `hello.kasm` | Prints a string over the CSP UART. The "is it a computer" milestone. |
| `fib.kasm` | Computes fib(10) and prints it as decimal. Divides by repeated subtraction, since `DIV` is cut from v1. |
| `fibforever.kasm` | Prints the whole 32-bit Fibonacci sequence, one term per second, restarting when the next term would overflow. Divides by reciprocal multiply rather than repeated subtraction — the latter would take about 45 seconds for the leading digit of a nine-digit number. |
| `hazard.kasm` | Nothing but back-to-back register dependencies, to exercise W→X forwarding. Measured on `hello` and `fib`, the number of hazards crossing that boundary was zero. |
| `f32_*.kasm` | The reserved `F32` tag (spec §11) faults with the same cause in both machines. See below — these are cosimulation programs and halt on a fault. |

`tests/programs.rs` assembles and runs each of these and checks the output, so
they are regression tests rather than samples.

## The `f32_*` programs

These four are driven by `rtl/sim/cosim.sh` rather than by `tests/programs.rs`,
because what they check is a property of *both* machines: `f32_operand`,
`f32_store` and `f32_predicate` each fault, and the cosimulation compares the
cause the RTL retires against the one the emulator reports. `f32_escape` is the
other side of the boundary and must halt cleanly.

They exist because `kgen` cannot reach this behaviour: it deliberately never
emits `RDT f32`, so the random seeds sweep straight past it.

