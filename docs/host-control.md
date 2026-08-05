# Host control over the UART

The board and a host talk over one 8N1 serial link at 115200. This document is
the wire protocol: what a frame looks like, what each command does, and which
of them need the core stopped first.

The constants live in `emu/src/hostproto.rs` and are rendered into
`rtl/k2g_host_pkg.sv` by `gen_defs`, so the host tool and the monitor cannot
disagree about a type code. The prose here is maintained by hand; a test
requires every frame type to appear in it.

## Every byte is framed

Two very different kinds of traffic share the link: the program's own console
output, and the commands that load, start, stop and inspect that program. Both
are inside frames.

The alternative — raw console bytes with framed commands interleaved — was
rejected because a program that happens to emit the magic sequence becomes
indistinguishable from a command, and the symptom of that is a wedged machine
diagnosed over a serial cable.

The cost is that a plain terminal no longer shows the console. `kctl console`
does. `docs/bring-up.md` records what changed for the `soc` bring-up stage; the
`loopback` stage is unaffected and still echoes typed characters.

```
1B 4B   type   len_lo len_hi   payload...   crc_lo crc_hi
```

- **Magic** is `ESC` `K`. Two bytes rather than one, because a single byte
  resynchronizes far too eagerly on a noisy line.
- **len** is little-endian and bounded by `MAX_PAYLOAD` (128). A length above
  it is rejected *before* the payload is consumed, so a corrupt header cannot
  swallow the frames behind it.
- **crc** is CRC-16/CCITT-FALSE — polynomial `0x1021`, initial value `0xFFFF`,
  no reflection, no final XOR — little-endian, over `type | len | payload`. The
  magic is not covered: it is a delimiter rather than data, and a receiver
  hunting for it has not started accumulating yet.
- Resynchronizing is always "go back to hunting for the magic". There is no
  attempt to recover the tail of a damaged frame, because a length field that
  cannot be trusted makes every such attempt a guess.

Host-to-board type codes are `0x0x`; board-to-host codes have the top bit set,
so a capture is readable by direction alone.

## Commands

| Type | Code | Payload | Needs paused |
|---|---|---|---|
| `PING` | `0x01` | — | no |
| `STATUS` | `0x02` | — | no |
| `PAUSE` | `0x03` | — | no |
| `RESUME` | `0x04` | — | no |
| `RESET` | `0x05` | — | yes |
| `WRITE` | `0x06` | `addr` u32 LE, then the bytes | yes |
| `READ` | `0x07` | `addr` u32 LE, `count` u16 LE | yes |
| `CONSOLE_IN` | `0x08` | the bytes | no |

## Replies

| Type | Code | Payload |
|---|---|---|
| `IDENT` | `0x81` | `version` u16, `max_payload` u16, `core_id` u32, `mem_bytes` u32, `caps` u32 |
| `STATE` | `0x82` | `flags` u8, `fault_cause` u8, reserved u16, `fault_addr` u32, `fault_info` u32, `cycles` u64 |
| `ACK` | `0x83` | `count` u16 LE — how many bytes were taken |
| `DATA` | `0x84` | the bytes |
| `NAK` | `0x8E` | `reason` u8 |
| `CONSOLE_OUT` | `0x8F` | the bytes |

`IDENT` answers `PING`. `STATE` answers `STATUS`, `PAUSE`, `RESUME` and
`RESET`. `ACK` answers `WRITE` and `CONSOLE_IN`. `DATA` answers `READ`.

`CONSOLE_OUT` is **unsolicited** and may arrive at any time, including between a
command and its answer. A host that reads a fixed number of bytes after sending
a command will eventually read console output instead of its reply; `kctl`
routes every frame through one decoder for that reason.

### `STATE` flags

| Bit | Meaning |
|---|---|
| 0 | `PAUSED` — fetch is held and the machine has gone quiet |
| 1 | `HALTED` — the core executed `HALT` |
| 2 | `FAULTED` — the core stopped on a fault; `fault_cause` says which |
| 3 | `BUS_OWNED` — the monitor holds the memory bus |

`fault_cause` is the `FAULT_*` encoding from `docs/isa-spec.md` §8. This is how
a fault cause becomes readable: a halted core cannot execute the CSP read that
would report its own, which is why `docs/bring-up.md` called the LEDs the
debugger.

### `IDENT` capabilities

| Bit | Meaning |
|---|---|
| 0 | `MEMORY` — `READ` and `WRITE` are implemented |
| 1 | `RUN_CONTROL` — `PAUSE`, `RESUME` and `RESET` are implemented |
| 2 | `CONSOLE` — the board sends `CONSOLE_OUT` |
| 3 | `CONSOLE_IN` — the board accepts `CONSOLE_IN` |

Capabilities differ per build, and `kctl ping` prints them so a host can say
"this build cannot do that" instead of timing out:

| Build | Capabilities |
|---|---|
| `mon` bring-up stage | `memory, console-out, console-in` — no CPU, so no run control |
| `soc` | `memory, run-control, console-out` — no console **input** |

The two console directions are separate bits because they are separately
affordable. The receive buffer and its accept logic are 33 logic cells, measured,
and `soc` places at 99% of the part — it did not fit with them. **So you cannot
type into a running program over the link on the `soc` build.** Nothing in
`emu/programs/` reads the UART, so no existing program notices. It is a
parameter (`HAS_CONSOLE_IN` on `k2g_mon`), not a deletion, and `tb_mon` goes on
testing the feature; it comes back the day the boot ROM stops costing 128 cells
of logic, which `emu/src/bin/mkrom.rs` records the measurements for.

### `NAK` reasons

| Reason | Code | Meaning |
|---|---|---|
| `CRC` | `0x01` | For the host's own bookkeeping. The monitor never sends it — a frame that fails CRC is discarded silently, because answering it would mean trusting its type field |
| `TYPE` | `0x02` | A frame type this build does not implement |
| `LENGTH` | `0x03` | `len` outside what the command allows |
| `ADDRESS` | `0x04` | The address, or address plus count, falls outside memory |
| `STATE` | `0x05` | The command needs the core paused and it is running |
| `BUSY` | `0x06` | The monitor is still finishing the previous command |

## What pause means

`PAUSE` does three things in order, and the order is the whole command:

1. **Hold fetch.** The core stops issuing instruction fetches and the pipeline
   *drains*: buffered code points decode, in-flight instructions execute and
   retire, outstanding responses come back. No instruction is frozen part-way,
   so there is no partial commit to reason about. Nothing architectural
   changes during a pause, which is why `PAUSE=1 bash rtl/sim/cosim.sh` must
   produce results identical to an unpaused run.
2. **Make memory tell the truth.** The data cache is write-back, so the bytes a
   program has stored may be sitting dirty in it while memory holds something
   older. Every dirty line is written back and both caches are invalidated —
   the same `k2g_cache_maint` sequence `ICINVR` uses.
3. **Take the bus.** Only then, because the flush in step 2 issues its writeback
   bursts through the same bus, and `k2g_membus_mux` requires that ownership
   move only when nothing is in flight.

A core that has already stopped — `HALT`, or a fault — is quiet by definition,
so `PAUSE` returns immediately with the flags to say so.

`PAUSE` stops at a **code point** boundary, not an instruction boundary: a
partial prefix chain may sit in the decoder across a pause. That is harmless for
reading memory and for resuming, but it means a host that has rewritten the
program must `RESET` before `RESUME` — which is what `kctl run` does.

`RESUME` gives the bus back and releases fetch. `pc` was never disturbed, so the
core carries on from where it stopped.

`RESET` clears `pc` to 0 and invalidates the caches. It does **not** re-run the
boot copier, so a host-loaded program survives it.

## Loading a program

There is no `LOAD` command. Loading is `PAUSE`, a run of `WRITE`s, `RESET`,
`RESUME` — which is also exactly what "write a memory range" is, so the two
features are one mechanism.

```bash
kctl --port COM3 run hello.bin
```

**`WRITE` streams; it does not buffer.** Each payload byte becomes one byte
write as it arrives. At 87 microseconds per byte on the wire the bus is never
the bottleneck, and a payload buffer would be LUTs the part does not have — it
is at 89% before any of this.

The consequence is that a frame failing CRC has already written part of its
range. The board cannot undo that. `kctl load` reads the range back and compares
it, which closes the hole on the host side at the cost of one extra pass over a
link that is already the slow part.

A corrupt header is bounded rather than unbounded: `len` above `MAX_PAYLOAD` is
refused before any payload byte is taken, and an address at or beyond
`mem_bytes` is refused before any bus request. The worst a bad frame can do is
put up to 128 bytes at a legal but wrong address, which the read-back finds.

## `kctl`

```text
kctl [--port <name>] [--baud <n>] [--quiet] <command>

  ping                       identify the board
  status                     what the machine is doing
  pause                      stop the core and make memory readable
  resume                     let the core run on from where it stopped
  reset                      reset the core (pc to 0); requires paused
  load <file> [--addr <a>]   pause, write, verify. Leaves the core paused
  run [file] [--addr <a>]    load if given, then reset and resume
  peek <addr> <count>        hex dump a memory range; requires paused
  poke <addr> <byte>...      write bytes; requires paused
  console                    print program output until interrupted
```

The port defaults to `$K2G_PORT`, which is what makes these short enough to type
repeatedly. It is `COM3` on Windows and `/dev/ttyUSB0` on Linux.

`kctl` has no dependencies: `emu/src/serial.rs` opens the port through
`CreateFileW`/`SetCommState` on Windows and termios on Linux. The crate is
loaded into Questa as a DPI shared object and is the normative specification of
an instruction set, and every crate added to it is one that has to build in both
roles.
