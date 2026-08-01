# `kasm` and `kdis` — assembler and disassembler

Both live in the `emu` crate and share its instruction definitions, so neither
can disagree with the emulator about what an encoding means.

```bash
cd emu
cargo run --release --bin kasm -- programs/hello.kasm -o hello.bin
cargo run --release --bin kdis -- hello.bin
cargo run --release --bin emu  -- hello.bin
```

---

# kasm

```
kasm <source.kasm> [-o <out.bin>] [--listing] [--labels]
```

| Option | Effect |
|---|---|
| `-o <file>` | Output image. Defaults to the source name with `.bin`. |
| `--listing` | Disassemble what was produced instead of writing a file. |
| `--labels` | Print the symbol table, sorted by address. |

The output is a flat little-endian image, loaded at `.org` (0 unless set).

`--listing` disassembles the *emitted bytes* rather than echoing the source, so
it shows the encoding actually chosen — which is the point when an instruction
has several forms:

```
  0x0000:  7800 f03c             puc32 r1, 28
  0x0004:  f040                  puc32 r2, 0
loop:
  0x0006:  e861                  ld8 r3, [r1]
  0x0008:  7c7d 8409             dispi done if r3.zero
```

## Lines

```
label:                          ; a label
NAME = value                    ; a compile-time constant
        mnemonic op, op         ; an instruction
        prefix: mnemonic op     ; an instruction with a prefix
        .directive args         ; data or layout
```

Comments run from `;` or `//` to end of line. Labels may share a line with what
follows. Everything is case-insensitive except string and character literals.

## Numbers

`10`, `0x1F`, `0b1010`, `-7`, `+3`, `1_000_000`, `'A'`.

Underscores are ignored. Character literals accept the same escapes as strings.

## Registers

`r0`–`r31`. There is no hardwired-zero register; `r0` is ordinary.

## Operands

| Form | Meaning |
|---|---|
| `r5` | register |
| `42`, `-1`, `0x20` | immediate |
| `label`, `NAME` | resolved to an address or constant |
| `[r5]` | memory at `r5` |
| `[r5+8]`, `[r5-4]` | memory at `r5` plus a signed offset |

## Instructions

### Constants and moves

```
puc8 rd, imm      puc16 rd, imm      puc32 rd, imm
rdt  rd, kind                        ; retag and re-normalize
cpy  rd, rs                          ; `mov` is an accepted spelling
```

`kasm` picks the shortest of three encodings automatically:

| Immediate range | Code points |
|---|---|
| −16 … 15 | 1 |
| −16384 … 16383 | 2 (an `XI` prefix) |
| anything else | 3 (a long constant) |

Nothing in the source changes; the assembler measures the value. This selection
is why `kasm` exists — `encode_lc_i5_*` asserts a 5-bit range, and a value as
ordinary as an ASCII letter needs a wider form.

`rdt` takes `u8 u16 u32 s8 s16 s32 f32`. It sets the tag **and re-normalizes**
the value, so `ld8 rd,[ra]` followed by `rdt rd, s8` is a sign-extending byte
load (spec §5.10). `f32` is reserved and faults at run time.

### Memory

```
ld8  rd, [ra]        ld16 rd, [ra]        ld32 rd, [ra]
ld8  rd, [ra+off]    ...                  ; off is −512 … 511
st   [ra], rs        st   [ra+off], rs
```

**A store's width comes from the source register's tag, not the mnemonic**
(spec §5.3). To write one byte, tag the source first:

```
        rdt     r7, u8
        st      [r5], r7
```

Without the `rdt` this writes four bytes and faults on an unaligned address.
There is no `st8`/`st16`/`st32` to reach for instead.

### I/O

```
in   rd, rport      ; read a CSP port  (port number in rport)
out  rport, rs      ; write a CSP port (port number in rport)
```

Port numbers come from a register, not an immediate — usually via an equate:

```
UART_DATA = 0x00
        puc32   r2, UART_DATA
        out     r2, r3
```

The two directions take the port from opposite operand positions in the
encoding; the mnemonics hide that, but it is worth knowing when reading a
disassembly (spec §9).

### Arithmetic and logic

```
add rd, rs | imm        sub rd, rs | imm        mul rd, rs | imm
and rd, rs | imm        or  rd, rs | imm        xor rd, rs | imm
not rd                  neg rd
mulw rd, rs, rhi        ; 64-bit product: low in rd, high in rhi
mul  rd, rs, rhi        ; the same thing, three-operand spelling
div  rd, rs | imm       ; assembles, but faults: cut from v1
```

All are two-address: `rd = rd op src`. Immediates are −16384 … 16383 (15-bit
signed, assembled with an `XI` prefix).

`overflow` means *the true result did not fit*: carry out for `add`, borrow for
`sub`, a nonzero high half for non-widening `mul`. The widening form writes no
overflow, and when `rd` and `rhi` name the same register the **low** half wins
(spec §5.5).

### Shifts and bit fields

```
shl rd, rs | imm        shr rd, rs | imm        shra rd, rs | imm
bext rd, rs, start, span    ; rd = span bits of rs starting at start
bins rd, rs, start, span    ; splice span bits of rs into rd at start
```

Shift amounts are 0–31; `start` and `span` likewise. `shra` follows the
destination's tag, so it is arithmetic on a signed tag and logical on an
unsigned one.

`bext` reads its **source** operand, `bins` reads both (`rd` is the destination
being spliced into). A zero span faults for `bext` and is a defined no-op for
`bins`.

### Comparisons

```
tst rd, rs | imm    ; ==        tstn rd, rs | imm   ; !=
lt  rd, rs | imm                gt   rd, rs | imm
lte rd, rs | imm                gte  rd, rs | imm
```

The result goes to `rd`'s **flag bit** only — the value and tag are untouched.

Both operands widen to 33 bits by their own tag before comparing, so signed and
unsigned mix correctly and there is one set of opcodes rather than two. An
immediate has no tag of its own and takes the left operand's (spec §5.9).

### Control transfer

```
dispi label     ; prime the jump latch, PC-relative
disp  rs        ; ... PC-relative by a register
dispa rs        ; ... absolute from a register
tc              ; commit the primed jump
halt
nop
```

**Branching is two instructions.** `dispi` primes a latch; `tc` commits it.
Nothing happens until the `tc`:

```
        dispi   done            if r3.zero
        tc                              ; falls through when r3 != 0
```

When the predicate is false the `dispi` is suppressed, the latch is never
primed, and the `tc` does nothing. That is what makes conditional branches
work, so an unprimed `tc` is a defined no-op rather than an error.

`kasm` widens a displacement automatically when the target is far, and computes
everything from labels — the reference program originally shipped with both its
branches miscalculated by hand, which is what motivated writing this.

## Modifiers

An instruction is one or more prefix code points followed by a single main one.
Rather than spell that split out, the assembly syntax folds each prefix into the
instruction it modifies:

```
<mnemonic>[.flag] <operands> [if [!]rN.cond]
```

```
insn  ops   if rN.cond      ; execute only if the condition holds  (XCP)
insn  ops   if !rN.cond     ; execute only if it does not          (XCN)
insn.flag   ops             ; operate on flag bits rather than values
```

The link prefix is folded into the mnemonic instead — see the `l` forms below.

Conditions, with accepted spellings:

| Tests | Spellings |
|---|---|
| that register's overflow flag | `overflow`, `ov`, `overflow_set` |
| that register's flag bit | `flag`, `flag_set` |
| its **value** is zero | `zero`, `z`, `value_zero` |
| its **value** is negative | `neg`, `negative`, `value_negative` |
| its value is neither | `pos`, `positive`, `value_positive` |

Any instruction may be predicated, on any register — there is no global
condition register. A false predicate suppresses every effect but still
advances the PC by the instruction's full length.

Note that `flag` appears in both roles: `and.flag` *writes* flag bits, while
`if rN.flag` *reads* one. They sit in different slots, so there is no ambiguity.

An `l` suffix adds a link register, turning a jump into a call. The link
register is the first operand, and the link value points at the `tc` that
follows the jump, not past it, so returning to it re-executes a harmless
unprimed `tc`:

| Jump | Call |
|---|---|
| `dispi target` | `dispil rL, target` |
| `disp rN` | `displ rL, rN` |
| `dispa rN` | `dispal rL, rN` |

```
        dispil  r30, subroutine
        tc
        ...
subroutine:
        ...
        dispa   r30
        tc
```

The same underlying prefix supplies the high half of a widening multiply, which
is spelled `mulw` (see above) rather than as a modifier.

`.flag` applies to `and`, `or`, `xor` and `not`. It has no immediate form —
there is no such thing as an immediate flag bit — and `neg.flag` is illegal.
`kasm` rejects the suffix anywhere else rather than silently ignoring it.

## Directives

| Directive | Effect |
|---|---|
| `.org addr` | Before any output, sets the image's load address. After output has begun, pads forward to `addr` with zeros; moving backwards is an error. |
| `.align n` | Pad with zeros to an `n`-byte boundary. |
| `.space n` | Reserve `n` zero bytes. |
| `.word v, …` | 16-bit values. `.half` is a synonym. |
| `.long v, …` | 32-bit values, little-endian. `.dword` is a synonym. |
| `.byte v, …` | 8-bit values, packed two per code point, zero-padded if odd. |
| `.ascii "…"` | String, no terminator. |
| `.asciz "…"` | String with a trailing NUL. |

String escapes: `\n \r \t \0 \\ \"`.

Use **CRLF** (`\r\n`) for terminal output. A serial terminal treats a bare LF
as "down one row" without returning the column, so output marches diagonally
off the screen.

## Layout

Addresses and instruction lengths are mutually dependent — a displacement's
magnitude decides its encoding, which changes the layout, which changes the
displacement. `kasm` iterates to a fixed point rather than making one pass, so
forward references resolve without any `near`/`far` annotation.

## Errors

Reported with a line number, all of them, rather than stopping at the first:

```
line 1: load offset 512 does not fit 10 bits signed
line 1: immediate 16384 does not fit 15 bits signed
line 1: shift amount 32 must be 0..31
line 1: undefined label `nowhere`
line 3: duplicate label `loop`
line 1: unknown mnemonic `frobnicate`
```

---

# kdis

```
kdis <image.bin> [--org <addr>] [--limit <bytes>]
```

| Option | Effect |
|---|---|
| `--org <addr>` | Address the image is loaded at. Default 0. |
| `--limit <bytes>` | How much to decode. Defaults to the last non-zero byte, so a mostly empty memory dump stays readable. |

Built on the emulator's own `decode_instruction`, so a listing cannot disagree
with what would actually execute.

```
  0x0000:  f020                  puc32 r1, 0
  0x0008:  7c7d 840a             dispi 0x1c if r3.zero
  0x000c:  ffbf                  tc
  0x0016:  7bff d47f             add r3, -1
```

Each line is address, raw code points, then the decoded instruction — modifiers
and all, since a prefixed instruction is one instruction.

An undecodable code point is reported inline and decoding continues at the next
halfword, so a partly valid image still produces a useful listing:

```
  0x001c:  6548                  .word 0x6548   ; undecodable: ILLEGAL_OPCODE
```

`kdis` cannot tell code from data — a string in the image will decode as
nonsense instructions. That is expected. Use `kasm --listing`, which knows
where the labels are, when reading your own program.
