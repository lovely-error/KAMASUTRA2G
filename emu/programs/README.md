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

`tests/programs.rs` assembles and runs each of these and checks the output, so
they are regression tests rather than samples.

