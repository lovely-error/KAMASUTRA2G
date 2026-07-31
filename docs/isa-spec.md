# KAMASUTRA2G (K2G) instruction set — specification

**Status:** normative for the FPGA implementation.
**Derived from:** `emu/src/interp.rs` and `emu/src/insns.rs`, which remain the executable
definition of record. Where this document and the emulator disagree, that is a bug in one of them
— report it rather than picking a side.

Opcode encodings are **not** listed here. They live in [isa-opcodes.md](isa-opcodes.md), which is
generated from the same enums that generate `rtl/k2g_pkg.sv`, so the numbers cannot drift from the
implementation.

Two conventions used throughout:

- **[E]** — behaviour *observed in the emulator*. Binding; the RTL must reproduce it exactly.
- **[N]** — behaviour *newly defined by this document*. The emulator does not implement it yet
  (it panics, hangs, or silently does something else) and must be updated to match.

> `decoder.sv` at the repository root describes a **different** instruction set — opcodes at
> `lane[5:0]` rather than `cp[15:10]`, `LB_ADD` numbered 62 rather than 53. It is superseded and
> is not a source for anything in this document.

---

## 1. Machine state

### 1.1 Registers

32 general-purpose registers, `r0`–`r31`. **There is no hardwired-zero register**; `r0` is
ordinary. Each register holds **36 bits** of architectural state:

| Field | Width | Meaning |
|---|---|---|
| `bits` | 32 | The value |
| `datatype` | 2 | Width tag: `B8`, `B16`, `B32` (`F32` — see §11) |
| `overflow` | 1 | Set by `ADD`/`SUB`/`MUL` |
| `flag_bit` | 1 | Set by comparisons; operand of `FLAG`-prefixed logic |

**The tag and flags are per-register, not global.** This is the single most consequential
difference from a conventional ISA and it shapes the whole implementation:

- `ST` takes its **width from the source register's tag**, not from the opcode. [E]
- Shifts and unary ops **truncate to the destination register's tag**. [E]
- Comparisons write **only `flag_bit` of the left-hand register** — not its value, not `overflow`,
  not its tag. [E]
- Predication reads the flags *or the value* of an **arbitrary** register named in the prefix, not
  of a global condition register. [E]

### 1.2 Program counter and the jump latch

- `ip` — 32-bit, byte-granular. Always even (§6.4).
- `nisa` — a hidden "next instruction address" latch, plus a valid bit. Written by `PrepareJump`,
  consumed by `PerformJump`. Not directly readable. [E]

`isa` denotes the address of the **first code point of the whole prefixed instruction** — the base
for relative displacements and the value reported in a fault. [E]

### 1.3 Memory

Flat, byte-addressed, 32-bit addresses, von Neumann (code and data share one space). No MMU, no
protection, no privilege levels. [E]

Accesses must be **naturally aligned** (§6.4). [N]

### 1.4 What does not exist

No interrupts. No timers that interrupt. No privilege modes. No vectored exceptions. The fault
mechanism in §8 is a halt, not a trap — a resumable path is reserved but not implemented.

---

## 2. Code point encoding

Instructions are built from **16-bit code points**, stored little-endian. Two formats share the
opcode field:

```
 15        10 9        5 4        0
+------------+----------+----------+
|     LB     |   arg1   |   arg2   |   6/5/5
+------------+----------+----------+
|     LB     |        imm10        |   6/10
+------------+---------------------+
```

`arg1` and `imm10` **share a left edge at bit 9**. This is load-bearing for the hardware: the
predicate register index in an `XCP`/`XCN` prefix occupies `cp[9:5]`, the same position as `arg1`,
so the register file's read port needs no address mux to fetch it.

Opcode space is layered. `LB = LB_EP1` escapes into the `EP1` table selected by `arg2`;
`EP1 = EP1_EP2` escapes again into the `EP2` table selected by `arg1`. Note the field swap between
the two levels. [E]

---

## 3. Instruction structure: the prefix chain

An instruction is **zero or more prefix code points followed by exactly one main code point**.
Instructions are therefore variable length, and length is discovered only by decoding — there is
no length field.

The decoder consumes code points in a loop, accumulating flags, until it reaches one that is not a
prefix. That code point is the main opcode and terminates the instruction. [E]

**A prefix chain is limited to 7 prefix code points.** Exceeding it raises
`PREFIX_CHAIN_TOO_LONG`. [N] — *the emulator's loop is currently unbounded, so `XI XI XI …` hangs
it; hardware needs a bound and so does the emulator.*

Because prefix and main code points are one instruction, **nothing can modify a register between
them**. Hardware may therefore evaluate a prefix's operands as soon as the prefix is decoded; this
is exact, not an approximation.

### 3.1 Prefixes

| Prefix | Carries | Effect |
|---|---|---|
| `XCP` | reg index, condition code | Execute the instruction only if the condition holds |
| `XCN` | reg index, condition code | …only if it does **not** hold |
| `XI` | `imm10` | Immediate extension, **sign**-extended from bit 9 |
| `XIZEXT` | `imm10` | Immediate extension, **zero**-extended |
| `BMX_0_0` | `start`, `span` | Reinterpret `SHL`/`SHR` as bit-field extract/insert |
| `EP1_UTO` | reg index | Link register for jumps; high-half destination for widening multiply |
| `EP2_FLAG` | — | Operate on `flag_bit` instead of the value |
| `EP2_CSP` | — | Redirect `LD`/`ST` to the I/O port space (§9) |
| `EP2_MPI` / `EP2_MPD` | — | Reinterpret a comparison as a prefetch |
| `EP2_ICINVR` | — | Reinterpret `ST` as an instruction-cache range invalidate |
| `EP1_ESP` | `gix` | Reinterpret `ST` as an export-memory-range |
| `EP1_SS`/`SR`/`SL`/`LTL` | `gix` | Memory ordering (§11) |

A repeated prefix simply overwrites its accumulated value; last one wins. [E]

### 3.2 Reinterpretation

Several prefixes do not modify their main opcode — they **replace** it. This is the most
error-prone corner of the ISA, because ignoring such a prefix does not degrade gracefully, it
silently performs a completely different operation:

| Prefix + main | Becomes | Ignoring the prefix would… |
|---|---|---|
| `BMX` + `SHL` | Bit-field **extract** | shift instead |
| `BMX` + `SHR` | Bit-field **insert** | shift instead |
| `UTO` + `MUL` | Widening 32×32→64 multiply | discard the high half |
| `UTO` + `DISP`/`DISPI` | Jump **and link** | lose the return address |
| `FLAG` + `AND`/`OR`/`XOR`/`NOT` | Boolean op on `flag_bit` | corrupt the register value |
| `CSP` + `LD*` / `ST` | I/O port read / write | **access memory instead of a device** |
| `MPD`/`MPI` + `TST` | Prefetch (a no-op) | **perform a real compare, writing a flag** |
| `ICINVR` + `ST` | I-cache invalidate (a no-op) | **perform a real store** |
| `ESP` + `ST` | Export range (a no-op) | **perform a real store** |

The last four are why §11's "cut" features cannot simply be ignored: the prefix must still be
decoded and still suppress the main operation, even when the operation it names does nothing.

---

## 4. Immediates

`XI`/`XIZEXT` supply a 10-bit field that combines with the main code point in **three different
ways depending on the main opcode**. This is a genuine irregularity, not a simplification: [E]

| Main opcode | Combination | Effective range |
|---|---|---|
| `PUC*`, `ADD`/`SUB`/`MUL`/`DIV`, `AND`/`OR`/`XOR`, all comparisons | `(ext10 << 5) \| arg2` | 15-bit |
| `LD8/16/32`, `ST` | `ext10` **raw**; `arg2` remains the address register | ±512 bytes |
| `DISPI` | `sext20((ext10 << 10) \| imm10) << 1` | ±1 MiB |

Without an `XI` prefix:

- `PUC*` sign-extends `arg2` from 5 bits. [E]
- ALU and comparison instructions take `arg2` as a **register index**, not an immediate. [E]
- `SHLI`/`SHRI`/`SHRAI` take `arg2` as a raw unsigned 5-bit shift amount and **ignore `XI`
  entirely**. [E]

### 4.1 `XIZEXT` + `DISPI` still sign-extends

The `DISPI` path re-sign-extends the assembled 20-bit displacement from bit 19 **unconditionally**,
regardless of whether the prefix was `XI` or `XIZEXT`. A "zero-extended" prefix value ≥ 512
therefore produces a **negative** displacement. [E]

This is surprising but free to reproduce in hardware (just sign-extend from bit 19) and expensive
to rediscover, so it is specified rather than fixed.

### 4.2 Long constants

`EP1_LLC_B8`/`LLC_B16` append one literal code point; `LLC_B32` appends two.

**`LLC_B32` stores the high halfword first** — big-endian, inside an otherwise little-endian
instruction stream. [E]

---

## 5. Data operations

### 5.1 Put constant

`PUC8`/`PUC16`/`PUC32` write the immediate and set the destination tag to `B8`/`B16`/`B32`.

**The value is not truncated to the tag.** `PUC16` with an all-ones immediate yields
`bits = 0xFFFFFFFF, tag = B16`. [E] Only shifts and unary ops truncate.

### 5.2 Copy

`CPY` is a **full 36-bit move** — value, tag, and both flag bits. [E]

### 5.3 Load and store

`LD8`/`LD16`/`LD32` load, zero-extend, and set the destination tag accordingly.

`ST` takes its **width from the source register's tag**. There is no `ST8`/`ST16`/`ST32`. [E]

Address = `regs[addr_reg].bits + offset`, wrapping. Both must be naturally aligned (§6.4). [N]

### 5.4 Arithmetic

`ADD`, `SUB`, `MUL`, `DIV`, all two-address: `dst = dst op src2`, where `src2` is a register or an
immediate (§4). The destination is also the first source — **back-to-back dependencies are the
normal case in this ISA**, which is why a short pipeline suits it.

`overflow` is written by `ADD`, `SUB`, and non-widening `MUL`. [E]

**On `SUB`, `overflow` is misnamed — it is a not-borrow (carry) flag, not signed overflow.** It is
set exactly when no borrow occurs, i.e. when `a >= b`, **except for `b == 0`, where it is
incorrectly clear**. [E]

| `a` | `b` | result | `overflow` | borrow? |
|---:|---:|---:|---|---|
| 7 | 0 | 7 | **0** | no — *the anomaly* |
| 5 | 3 | 2 | 1 | no |
| 10 | 10 | 0 | 1 | no |
| 3 | 5 | −2 | 0 | yes |

The anomaly arises because the emulator forms the two's complement of the right operand in 32
bits — *discarding the carry* — so `~0 + 1 == 0`, and adding zero never carries. A hardware
`a + ~b + 1` would produce `cout = 1` here. The correct hardware form is therefore:

```
overflow_sub = cout(a + ~b + 1) & (src2 != 0)     // equivalently: (a >= b) && (b != 0)
```

Note `ADD` is unaffected: its `overflow` is the ordinary unsigned carry-out.

`DIV` by zero is undefined in the emulator (it panics). Under this specification `DIV` raises
`DIV_UNIMPLEMENTED` (§11). [N]

### 5.5 Widening multiply

`UTO` + `MUL` computes the full 64-bit product: low half to `dst`, high half to the `UTO` register
(whose tag is set to `B32`).

Two details that differ from plain `MUL`: [E]

- **Widening multiply does not write `overflow`.** Plain `MUL` does.
- **When `dst` and the `UTO` register are the same, the low half wins** (a write-order artifact,
  specified so hardware reproduces it).

### 5.6 Logic and unary

`AND`, `OR`, `XOR` on values; with `FLAG`, on `flag_bit`.

`FLAG` + logic with an **immediate** operand is illegal → `ILLEGAL_PREFIX_COMBO`. [N]
(*emulator panics*)

`NOT` and `NEG` truncate the result to the destination's tag. `NEG` computes `(~v)+1`.

`FLAG` + `NOT` **toggles** `flag_bit`. `FLAG` + `NEG` is illegal → `ILLEGAL_PREFIX_COMBO`. [N]
(*emulator panics*)

### 5.7 Shifts

`SHL`, `SHR`, `SHRA` (register amount) and `SHLI`, `SHRI`, `SHRAI` (5-bit immediate amount).

- **Shift amounts are masked to 5 bits.** [E]
- **The result is truncated to the destination's tag.** [E]
- **`SHRA` sign-extends from bit 31 regardless of the tag**, and only then truncates. So `SHRA` on
  a `B8`-tagged register sign-fills from bit 31 and masks to 8 bits. [E]

### 5.8 Bit field extract and insert

`BMX(start, span)` + `SHL` = **extract**: `dst = (regs[src] >> start) & ((1<<span)-1)`.
`BMX(start, span)` + `SHR` = **insert**: replace `span` bits of `dst` at `start` with the low
`span` bits of `regs[src]`.

They write different amounts of state: [E]

- **Extract writes the whole register** — value, tag ← `B32`, both flags ← 0.
- **Insert writes only the value.**

`span == 0` is asymmetric in the emulator: extract asserts, insert is a silent no-op. This
specification defines **`span == 0` as `BEXT_ZERO_SPAN` for extract and a no-op for insert**,
preserving the observed insert behaviour and making the extract case an explicit fault. [N]

`BMX` + `SHRA` is illegal → `ILLEGAL_PREFIX_COMBO`. [N]

### 5.9 Comparisons

`TST` (=), `TSTN` (≠), `LT`, `GT`, `LTE`, `GTE`.

**All comparisons are unsigned.** [E] Combined with §4 this has a sharp edge: `XI` *sign-extends*
the immediate, which is then compared *unsigned* — so comparing against `-1` compares against
`0xFFFFFFFF`.

The result goes to **`flag_bit` of the left-hand register only**. [E]

---

## 6. Control transfer

### 6.1 The split

Branching is two instructions:

1. **`PrepareJump`** (`DISP`, `DISPI`) computes a target and primes `nisa`.
2. **`PerformJump`** (`EP2_TC`) commits it: `ip ← nisa`.

The gap between them is deliberate — it is where hardware prefetches the target. Because
`PrepareJump` is never a memory operation, the data port is free in that cycle to fetch the target
speculatively, which makes a taken branch cost **zero bubbles**.

### 6.2 Targets

| Form | Target |
|---|---|
| `DISPI` | `isa + (sext(disp) << 1)` |
| `DISP` + `EP1_DISP_OFF` | `isa + regs[arg1].bits` — **not shifted** |
| `DISP` + `EP1_DISP_ABS` | `regs[arg1].bits` |

`DISP` with any other `arg2` → `ILLEGAL_OPCODE`. [N] (*emulator panics*)

Displacements are relative to **`isa`**, the start of the whole prefixed instruction — not to the
`DISPI` code point, and not to the following instruction. [E]

### 6.3 Link register

`UTO` + `DISP`/`DISPI` writes `isa + instruction_length` to the `UTO` register and sets its tag to
`B32`. [E]

Note this is the address of the code point **immediately after the `DISP`**, which in the normal
idiom is the `TC` itself, not the instruction after it. A return therefore re-executes a `TC`.
That is harmless (§6.5) but must be understood when defining a calling convention.

### 6.4 Alignment

All instruction fetch is halfword-aligned. `DISPI` shifts by 1 so it cannot produce an odd target;
`DISP_OFF`/`DISP_ABS` can. An odd target raises `MISALIGNED_FETCH` at `PerformJump`. [N]

Data accesses must be naturally aligned — `LD32`/`ST` of a `B32` source require `addr[1:0] == 0`,
`LD16`/`ST` of a `B16` source require `addr[0] == 0`, `B8` is always legal. Otherwise
`MISALIGNED_LOAD` / `MISALIGNED_STORE`. [N]

*Rationale: the emulator currently performs unaligned reads via `ptr.cast::<u32>().read()`, which
is undefined behaviour in Rust and merely happens to work on x86. Supporting it in hardware costs
250–450 LUT or a doubling of memory width, to support something no program relies on.*

### 6.5 `PerformJump` with no primed `nisa` is a defined NOP

If `nisa` is not valid, `PerformJump` does nothing and execution falls through. [E]

**This must not be "fixed".** It is load-bearing: in the reference `test_fibonacci` program the
predicated forward branch targets the `TC` code point itself, and the program only produces the
right answer because that `TC` finds `nisa` empty and falls through.

### 6.6 Double priming

Two `PrepareJump`s without an intervening `PerformJump`: **the last one wins**. [N]
(*the emulator panics*)

This costs nothing in hardware — `nisa` is a plain register — and it legalizes a genuinely useful
idiom for selecting between two targets:

```
XCP rA, FLAG_SET : DISPI  then_target
XCN rA, FLAG_SET : DISPI  else_target
TC
```

A `COMPAT_FLAGS` bit (§9) restores the trap-on-double-prime behaviour for emulator-parity testing.

### 6.7 Halt

`EP2_HALT` stops the machine. `EP2_DNO` is a no-op.

---

## 7. Predication

Any instruction may carry one `XCP` (execute if) or `XCN` (execute if not) prefix, naming **a
register** and a condition code:

| Condition | Tests |
|---|---|
| `CC_OVERFLOW_SET` | that register's `overflow` flag |
| `CC_FLAG_SET` | that register's `flag_bit` |
| `CC_VALUE_ZERO` | that register's **value** `== 0` |
| `CC_VALUE_NEGATIVE` | that register's **value**, bit 31 set |
| `CC_VALUE_POSITIVE` | value neither zero nor negative |

Any other condition code → `ILLEGAL_PREFIX_COMBO`. [N] (*the emulator falls back to treating the
code point as a non-prefix, which then usually decodes as garbage*)

Two properties matter for implementation:

- Zero and negative are **computed from the register value on demand**, not stored. There is no
  global Z/N flag.
- **A false predicate suppresses all architectural effects, but the instruction still advances the
  PC by its full length.** [E] Predication is squash-on-writeback, not a branch.

---

## 8. Faults [N]

The ISA has no exception mechanism. This specification adds the minimum needed to make a debuggable
machine: a **precise machine-check halt**.

On a fault the offending instruction is squashed before it writes anything, fetch stops, the
machine halts, and four values latch:

| State | Contents |
|---|---|
| `fault` | sticky, distinguishes a fault from a normal `HALT` |
| `fault_cause` | code below |
| `fault_addr` | `isa` of the faulting instruction |
| `fault_info` | offending address, or the raw code point |

| Code | Name | Raised by |
|---|---|---|
| 0x01 | `ILLEGAL_OPCODE` | unassigned `LB`/`EP1`/`EP2` encoding; `DISP` with bad `arg2` |
| 0x02 | `ILLEGAL_PREFIX_COMBO` | `BMX`+`SHRA`; `FLAG`+non-logic; `FLAG`+immediate; `FLAG`+`NEG`; `CSP`+non-memory; unassigned condition code |
| 0x03 | `PREFIX_CHAIN_TOO_LONG` | more than 7 prefix code points |
| 0x04 | `DIV_UNIMPLEMENTED` | `DIV` (§11) |
| 0x05 | `FP_UNIMPLEMENTED` | `LDF32`, or any `F32`-tagged operand (§11) |
| 0x06 / 0x07 | `MISALIGNED_LOAD` / `MISALIGNED_STORE` | §6.4 |
| 0x08 | `MISALIGNED_FETCH` | odd `nisa` at `PerformJump` |
| 0x09 | `ADDR_OUT_OF_RANGE` | address beyond implemented memory |
| 0x0A | `BAD_CSP_PORT` | unmapped I/O port |
| 0x0B | `BEXT_ZERO_SPAN` | `BMX` span 0 with `SHL` |
| 0x0D | `DOUBLE_PRIME` | only when `COMPAT_FLAGS.0` is set |
| 0x1F | `HALT_INSN` | normal `HALT`; distinguished by `fault == 0` |

**Precision is structural, not an added guarantee**: register writes happen only at the end of
execute, and stores are gated by checks performed during address generation, so nothing commits
before a fault is known.

A halted core cannot execute a `CSP` read to report its own cause, so implementations must expose
`fault_cause` externally — on LEDs, and via a monitor that dumps the fault registers over the UART
when the machine halts.

### 8.1 Reserved for later

`TRAP_VECTOR` and `TRAP_ENABLE` (§9) are allocated but must read as 0 and have no effect. When
implemented, a fault will redirect fetch instead of halting. Since there are no interrupts, a
single-level non-reentrant handler is sufficient — no shadow register file is needed.

---

## 9. I/O: the CSP port space [N]

I/O is **not memory-mapped**. The `CSP` prefix redirects `LD`/`ST` to a separate 32-bit **port
space**, keeping the memory path free of device address decoding.

Note the operand positions differ between the two directions, matching the underlying `LD`/`ST`
forms: [E]

- `CSP` + `LD*` → port number in `regs[arg2]`, result to `regs[arg1]`; the `LD` width sets the
  destination tag.
- `CSP` + `ST` → port number in `regs[arg1]`, data from `regs[arg2]`.

`CSP` with any other main opcode → `ILLEGAL_PREFIX_COMBO`.

| Port | Name | Access | Meaning |
|---:|---|---|---|
| 0x00 | `UART_DATA` | R/W | R: receive byte. W: transmit byte. |
| 0x01 | `UART_STATUS` | R/W | R: `{…, tx_full, rx_empty}`. W: baud divisor. |
| 0x02 | `CYCLE_COUNT_LO` | R | Free-running cycle counter, low 32 bits |
| 0x03 | `CYCLE_COUNT_HI` | R | high 32 bits |
| 0x04 | `FAULT_CAUSE` | R | §8 |
| 0x05 | `FAULT_ADDR` | R | §8 |
| 0x06 | `FAULT_INFO` | R | §8 |
| 0x07 | `TRAP_VECTOR` | R/W | reserved, reads 0 |
| 0x08 | `TRAP_ENABLE` | R/W | reserved, resets to 0 |
| 0x09 | `GPIO_OUT` | R/W | board LEDs |
| 0x0A | `CORE_ID` | R | `0x4B324731` ("K2G1") |
| 0x0B | `COMPAT_FLAGS` | R/W | bit 0: trap on double prime (§6.6), resets to 0 |
| 0x0C | `STICKY_STATUS` | R | bit 0: a removed ordering prefix was executed (§11) |

Any other port → `BAD_CSP_PORT`.

---

## 10. Implementation subset (v1)

The first hardware implementation omits the following. Each omission is a **fault**, never a
silent difference in results.

| Omitted | Behaviour | Why |
|---|---|---|
| `F32` and all float ops | `FP_UNIMPLEMENTED` | Expensive on a 9K-LUT part, and the emulator's float path is not IEEE-754 anyway (§11) |
| `DIV` | `DIV_UNIMPLEMENTED` | Multi-cycle divider not worth the area; do it in software |
| Ordering prefixes `LTL`/`SL`/`SS`/`SR` | Ignored; the load/store still happens. Sets `STICKY_STATUS.0` | Single core — ignoring them is semantically correct |
| `ESP`, `ICINVR`, `MPI`/`MPD` | **Decoded and honoured as no-ops** | They *reinterpret* their main opcode; ignoring the prefix would perform a real store or compare (§3.2) |
| Resumable traps | Halt instead | §8.1 |

---

## 11. Notes on `F32`

`F32` is specified as reserved rather than defined, because the emulator's float support is not
usable as a reference:

- It converts rather than reinterprets — `bits as f32` and `f32 as u32` are *numeric conversions*,
  so an `F32` register does not hold an IEEE-754 bit pattern at all.
- `SUB` on the float path computes `a + b`.
- Float behaviour is selected dynamically by *both* operands being `F32`-tagged, making the
  arithmetic unit's behaviour depend on runtime tags.

Any future `F32` must be designed from scratch against IEEE-754, not derived from the current
emulator. Until then it faults.

---

## 12. Normative details that are easy to get wrong

Collected for implementers. Each is cheap to reproduce when known, and a long debugging session
when not. All are [E] unless marked.

1. `SUB`'s `overflow` is a not-borrow flag, and is wrong when subtracting 0 — §5.4.
2. Comparisons are unsigned, but `XI` sign-extends — §5.9, §4.
3. `XI` combines three different ways depending on the main opcode — §4.
4. `XIZEXT` + `DISPI` yields negative displacements for prefix values ≥ 512 — §4.1.
5. `PUC*` does not truncate to its own tag — §5.1.
6. `SHRA` sign-extends from bit 31 regardless of tag, then truncates — §5.7.
7. Immediate shifts ignore `XI` — §4.
8. `LLC_B32` is high-halfword-first — §4.2.
9. Widening `MUL` writes no `overflow`; plain `MUL` does; on aliasing, low wins — §5.5.
10. Extract writes value+tag+flags; insert writes only the value — §5.8.
11. `CPY` copies tag and flags too — §5.2.
12. Comparisons write only `flag_bit` of the left operand — §5.9.
13. `PerformJump` with empty `nisa` is a NOP and must stay one — §6.5.
14. Displacements are relative to the start of the *whole prefixed instruction* — §6.2.
15. The link register points at the `TC`, not past it — §6.3.
16. A false predicate still advances the PC by the full instruction length — §7.
17. `CSP` load and store take the port number from *different* operand positions — §9.

---

## Appendix: reference program

`test_fibonacci` in `emu/src/main.rs` is the canonical end-to-end program and the first
cosimulation vector. Two things about it are deliberate and must not be "corrected":

- Both of its branch targets land one code point earlier than the source comments suggest. The
  forward branch targets the `TC` at offset 28 rather than the `HALT` at 30; the backward branch
  targets offset 6 rather than 8, harmlessly re-executing a register initialization.
- It produces 55 regardless, and the forward case is the proof that §6.5 must hold.
