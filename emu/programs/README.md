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

`tests/programs.rs` assembles and runs each of these and checks the output, so
they are regression tests rather than samples.

## A note on `test.bc`

A 2 KiB raw memory dump used to sit at `emu/test.bc`. It was orphaned — nothing
read it — and it was stale twice over: it encoded the pre-fix fibonacci
displacements, and its final code point (`0xfeff`) placed `HALT` at `EP2` slot
23, where the current opcode map has 25. It predated an opcode renumbering that
nothing detected at the time.

It is deleted rather than regenerated: `kasm` reproduces an equivalent image
from `fib.kasm`, and a checked-in binary that can drift from its source is
exactly the problem `rtl/k2g_pkg.sv`'s generator exists to prevent.
