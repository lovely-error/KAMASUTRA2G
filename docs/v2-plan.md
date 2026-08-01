# K2G v2 — pipelined core, caches, PSRAM

The v1 machine works and is tagged `v1`. This is the plan for the next one.

## Why

`docs/bring-up.md` records v1 on hardware:

| | v1, measured |
|---|---|
| `clk_sys` Fmax | **10.0 MHz**, 28 logic levels |
| Actual clock | 6.75 MHz (27 MHz ÷ 4) |
| Logic | 4695 / 8640 (55%) |
| BSRAM | 4 / 26 |
| Memory | 8 KB unified BSRAM |

The 28-level path is one combinational chain — fetch → decode → register read → ALU → writeback —
because `k2g_core.sv` deliberately collapsed the planned F/D/X pipeline to get correctness first.
That file records the decision as a debt to be repaid once cosimulation is green. It is green.

The target: a 5-stage core at the full 27 MHz crystal rate, executing out of 8 MB of in-package
PSRAM through an instruction and a data cache, with lockstep cosimulation green at every step.

## Decisions

- **PSRAM is all of memory.** Flat 8 MB at address 0. The BSRAM blocks are re-spent entirely as
  cache storage; no TCM, no two-region address decode.
- **The core stays on the 27 MHz crystal.** The PSRAM IP runs from its own PLL and the memory
  channel crosses domains through an asynchronous FIFO.
- **Write-back data cache.** `ICINVR` is the ISA's answer to self-modifying code.
- **Five stages, full rate.** F / D / X / M / W, targeting `CLK_DIV = 1`.

## On the word "CSP"

`CSP` already means the `EP2_CSP` prefix and the I/O port space of spec §9, implemented in
`rtl/k2g_csp.sv`. The Communicating-Sequential-Processes structuring idea is therefore written
throughout as **channels** — module `k2g_chan`. The design idea is unchanged: sequential processes
connected only by typed, buffered, back-pressured channels. Only the label moves out of the way.

## Stages are guarded atomic transactions

A stage is not "some logic with a stall input". It is a **rule**: a guard, and an effect that
happens entirely or not at all.

```
guard   = every input has an item
        & every output has room
        & every resource the effect needs is free
effect  = consume those inputs, produce those outputs, update that state
```

Nothing partially commits. There is no global `stall` signal in v2 — a stage that cannot fire
simply does not fire, and its inputs stay offered.

This is not an aesthetic choice. The v1 `stall` expression is a disjunction of independently-added
terms, and getting one wrong is easy in a way that reads fine: the first Phase 1 rewrite of it
allowed the next instruction to retire in the same cycle a load wrote back, because that term was
reasoned about on its own and the value array's **single write port** was not in view. A guard that
has to name every resource it consumes does not let that mistake be spelled.

So the register file's one write port (`k2g_regfile.sv`) is an explicit resource in the guard of
every rule that writes it, alongside the obvious ones. Same for the jump latch and the data bus.

### The one real tension, resolved

Guarded firing wants a rule's guard to include downstream readiness. Channels forbid `valid` from
depending combinationally on `ready` (`k2g_chan.sv`, rule 3). Taken naively together these
contradict each other, and the contradiction is the combinational loop the decoder's `hold` input
already exists to avoid.

Bluespec resolves this with a scheduler. Hand-written RTL resolves it by placement:

- A stage's **output `valid` is a function of its own state** — "my output register holds an item" —
  and never of `ready`.
- A stage's **guard** may read downstream `ready`, and drives its **input `ready`**. `ready`
  depending on `ready` is legal and loop-free.

That leaves one long combinational chain: `ready` propagating backwards through every stage at
once. `k2g_skid` is where that chain is cut — its `up.ready` is a register. Put one wherever the
backward path gets long enough to cost timing, which is measured, not guessed.

## The constraint that shapes the order of work

`rtl/tb/tb_cosim.sv` is what makes this refactor attemptable, and it is also the most fragile
thing in the repository. It used to reach into the core for `take_uop`, `mem_pending` and
`mulw_pending` and open-code the wait for a load's second cycle — which pins it to a two-stage
machine, the one shape the core is about to stop having.

So the safety net is rebuilt **first**, against the working core. If it were rebuilt at the same
time as the thing it protects, neither could be trusted when they disagree.

---

## Phase 0 — tag v1, define retirement ✅ done

`v1` tags 39ef3ea, the commit whose figures are quoted above.

`k2g_core` now exports a retirement port, `retire_valid` + `retire_t` (`rtl/k2g_types.svh`):

> `retire_valid` is high in the cycle **after** every architectural write belonging to an
> instruction has committed, and `retire` names that instruction.

That wording is chosen to survive a pipeline — "after the last write commits" stays meaningful
however many stages there are. `tb_cosim` steps the emulator on it and compares immediately,
with no knowledge of how the core sequences anything. The register arrays are still read
hierarchically (`dut.u_rf.*`), deliberately: they *are* the architectural state and `k2g_regfile`
survives the rewrite.

Measured cost: SoC 4695 → 4670 LUTs, 758 → 772 registers. Free.

---

## Phase 1 — the channel primitive and the memory contract 🔶 data side done

**Goal:** every interface that will later have variable latency has it now, before anything real
is variable.

**Done:** `rtl/k2g_chan.sv` (channel interface + `k2g_skid`, with `tb_chan`), `rtl/k2g_membus.sv`,
`rtl/k2g_bsram_port.sv` (synthesizable slave) and `rtl/tb/k2g_mem_slow.sv` (the latency injector).
The core's **data** port is now a `k2g_membus` master. `LATENCY=40 bash rtl/sim/cosim.sh` produces
results identical to `LATENCY=0`, across all 22 programs.

The **instruction** port followed as Phase 2's first step (below); both buses now tolerate
arbitrary latency.

- **`rtl/k2g_chan.svh`** — `docs/gowin-sv-support.md` measured `interface` + `modport` as PASS
  (probe 04) and `struct packed` as PASS (02, 08), so `docs/attic/pipe.sv`'s handshake shape is
  viable. Rewrite it properly: the attic version uses `bit` rather than `logic`, initializes state
  at declaration instead of on reset, and has no parameterized depth. Two forms:
  - a **skid buffer** (2-entry, registered ready) where a combinational ready path must be broken;
  - a **pass-through** (wires only) where backpressure cannot occur.

  The module boundary is channel-shaped either way; only the pass-through form is free. This is
  what keeps the channel discipline without paying elastic-buffer area on the tight D→X path.

- **`rtl/k2g_membus.svh`** — the request/response contract shared by fetch, load/store, both caches
  and the PSRAM wrapper. Responses strictly in order. Nothing in the core may assume a fixed
  latency again.

- Wrap `rtl/k2g_mem.sv` behind it as `k2g_mem_slow`, with a seeded 0–40 cycle latency injector.

**Gate:** cosim green across the full seed sweep **with random latency injected**. This proves the
core tolerates variable-latency memory before a cache or a PSRAM exists — the highest-value early
result in the plan.

---

## Phase 2 — the five-stage pipeline

**Goal:** break the 28-level path. Still on BSRAM; no caches yet.

**2a done — elastic fetch.** The instruction port is a `k2g_membus` master with credit-limited
issue and a `k2g_skid` F→D buffer. Fetch never asks for a code point the buffer might not have room
for, which is what lets the bus have no response backpressure. A branch redirect flushes the buffer
and *counts* the answers still owed to the abandoned stream, discarding them as they arrive —
requests already accepted cannot be recalled.

Measured: cosim identical at `ILATENCY=25`; credit of 2 rather than 1 is worth 29% on `fib`
(570 vs 736 cycles) and 1.4% on `hello`, which is UART-bound. Fmax unchanged at 10.66 MHz / 28
levels, and area is up ~200 LUT — this step buys latency tolerance, not timing. Timing is 2b/2c.

**2b done — decode is its own stage.** A one-entry D→X register (not a skid: the backward `ready`
path is short and a skid on a ~210-bit uop costs twice the flops for throughput D cannot use).
`isa` travels with the uop, because by the time X runs, the F→D buffer has moved on.

| | v1 | after 2a | after 2b |
|---|---|---|---|
| Fmax | 10.0 MHz | 10.66 MHz | **14.53 MHz** |
| Logic levels | 28 | 28 | **21** |
| Logic | 4695 | 4845 | 4280 |

LUTs went *down* 565: with a register in the middle, synthesis optimizes decode and execute
separately instead of flattening one cone.

**It also found a real bug**, which is the argument for latency injection restated. Letting D run
ahead meant a CSP store could sit in X behind a pending load and hand its byte to the transmitter
*before* the instruction fired, then hand it over again on retiring — `fib` emitted five UART bytes
against four, with every register still matching. Gating it on `take_uop` closes the
`csp_req → csp_stall → stall → take_uop` loop, so it is gated on every *other* reason X might not
fire. Locked in as the `csp-side-effect-while-held` mutant. The fix cost about 1.1 MHz.

**2c done — writeback is its own stage, with per-field forwarding.** X computes a writeback packet;
W drives the register file's write port. Forwarding is per field (value, tag, overflow, flag),
because a comparison writes only `flag_bit` and an arithmetic op only `overflow` — forwarding a
whole register on any write would clobber the three fields the instruction in W is not touching.
The tag matters most and is least obvious: a store takes its width from the source register's tag,
so an unforwarded tag writes the wrong *number of bytes* rather than the wrong value.

Two things had to move into the retirement contract, both because X now runs ahead of retirement:

- `nisa` and `nisa_valid` are in `retire_t`. The jump latch is architectural state no instruction
  can read back, so cosim is the only thing checking it — and reading the live latch reports a
  value belonging to an instruction two further on. That showed up immediately as a phantom
  divergence.
- `tb_cosim` no longer synchronises on `halted` at all. `halted` rises when the stopping
  instruction executes; its retirement follows once every write commits. A loop exiting on `halted`
  drops the last instruction and reports "RTL stopped, emulator did not", which reads exactly like
  a core bug and is not one.

### Two bottlenecks, one of them in the testbench

Chasing why forwarding was never exercised found both, and they compounded.

**`k2g_mem_slow` accepted a request only every other cycle.** Its zero-latency path went
`S_IDLE → S_RESP → S_IDLE`, so `req_ready` was false half the time — capping the bus at 0.5
requests per cycle. The synthesizable `k2g_bsram_port` it stands in for ties `req_ready` high and
is fully pipelined, so **simulation was starving the core in a way hardware never did**, and every
cycles-per-instruction figure measured before this was measuring the model. The response is now a
register rather than a state.

**Credit must cover the round trip, not the buffer.** A code point holds a credit from issue until
decode consumes it — issue at *k*, answer at *k+1*, buffer output at *k+2*, consumed at *k+2*:
three cycles. Sustained rate is credit/3, so a credit of 2 caps fetch at 0.67 code points per cycle
however fast memory is. The F→D buffer is now two chained skids, depth 4, with `issue_addr`
widened to 4 entries to match — a queue shorter than the credit wraps and pairs code points with
the wrong addresses, which corrupts `isa` rather than the instruction and would surface as wrong
fault addresses and branch targets.

| CPI | before | model fixed | + depth 4 |
|---|---|---|---|
| `fib` | 3.26 | 3.35 | **2.33** |
| `hazard` | 3.50 | 3.57 | **1.86** |
| `hello` | 5.65 | — | 5.60 (UART-bound) |

Cost: 4412 LUT and 1155 registers, up from 4374/1052. Fmax still meets 13.5 MHz.

### Forwarding: value and tag proven, flag unreachable

With both bottlenecks fixed, hazards appear: `fib` went from 0 to 19 read-after-write pairs
crossing X→W, `hazard.kasm` from 0 to 16. `no-value-forwarding` and `no-tag-forwarding` are now
**caught** and are back in `mutants.sh`.

The flag and predicate paths are a different matter, and it is structural rather than a gap in the
tests: **every instruction that reads a flag carries a prefix** — `XCP`/`XCN` to predicate, `FLAG`
for a flag-wise logic op. So it is at least two code points, and at one code point per cycle its
execute stage lands at least two cycles after its producer's — by which time the producer has
committed out of W and the register file already holds the value. Those muxes cannot be reached.

They are kept, because that is a property of the front end and not of the ISA: a wider fetch closes
the gap and makes them live. `mutants.sh` does not carry a mutant for them, because it would report
`MISSED` forever and a test that cannot fail is worse than no test. `k2g_core.sv` says so at the
declaration.

### 2d — shadow prefetch: attempted, reverted

**Measured first.** A redirect costs exactly 3 cycles — the fetch round trip — which is 60 of
`fib`'s 407 cycles (14.7%) and 78 of `hello`'s 1013 (7.7%). Eliminating it would take `fib` from
CPI 2.33 to about 1.98.

**Prime-time prefetch cannot work here.** The ISA's idiom puts `DISP` and `TC` adjacent, so priming
executes one cycle before performing; a shadow started at the prime issues its first request as the
branch is already being taken. The target must instead be computed in **D**, where for an immediate
displacement it is just `isa + imm` and needs no register — two cycles earlier, exactly the round
trip. Register-target jumps cannot do this and keep the bubble.

**Built, and reverted.** Two symmetric F→D buffers indexed by a `sel` bit, a stream tag on
in-flight requests, shadow started from decode, adopted only when the address it started from
equals the `nisa` being performed (so a predicated-away `DISP`, a double prime, or a register
target all fall through to the old flush path and are never wrong). Cosim was green and **20 of 20
branches adopted their shadow** — but CPI did not move, because arbitration gave decode's own
stream priority and it always had credit, so the shadow never won a bus slot and was always empty
when adopted.

Giving the shadow priority made it fetch, and broke the machine: `hello` printed `HHHH…` forever,
`fib` faulted `ADDR_OUT_OF_RANGE` at `0xfffffff0`. Two real bugs were found and fixed on the way
and are worth having written down:

- **Same-cycle adopt and retarget.** Adoption swaps `sel`, so a shadow started by decode in that
  same cycle retargets `fpc` of the very buffer being adopted — contents right, continuation
  address wrong.
- **Credit underflow on dropped answers.** `fdrop` is only ever set alongside `finfl <= 0`, so
  decrementing `finfl` again when a dropped answer arrives underflows it to 7, fails
  `finfl < DEPTH` forever and silently kills that stream. Invisible while the shadow never had
  requests outstanding — which is precisely what the original arbitration guaranteed.

A third defect remains unisolated, which is why this is reverted rather than committed. Shipping
the working arbitration would have meant ~200 flops of provably dead logic; shipping the effective
one would have meant a broken machine.

**Worth retrying, and the value grows.** Behind an I-cache a redirect costs 3 cycles *plus* the
miss penalty, so the same mechanism is worth considerably more after Phase 3 than before it — and
building it against the cache's real latency avoids sizing it twice. Start from the notes above
rather than from scratch.

| Stage | Work |
|---|---|
| **F** | PC generation, I-fetch request, shadow prefetch stream |
| **D** | prefix accumulator (`k2g_decode`), uop formation |
| **X** | register read + forwarding + ALU / shift / multiply + address generation + fault detection |
| **M** | data memory access |
| **W** | writeback |

Split `k2g_core.sv` into `k2g_fetch.sv`, `k2g_exec.sv`, `k2g_lsu.sv`, `k2g_forward.sv`, leaving
`k2g_core.sv` as stage instantiation and channel wiring.

Each stage is written as a guarded atomic rule per the section above — one `*_can_fire` expression
naming every input, output and resource, with every state update and every handshake gated on it.
The v1 global `stall` disappears; it does not get carried forward and renamed.

The ISA-specific traps, each of which is a real one:

- **Forwarding must be per field.** `k2g_regfile.sv` has independent write enables for value, tag,
  overflow and flag because a comparison writes only `flag_bit` and an arithmetic op writes only
  `overflow`. A single "forward the register" mux is wrong here. Tags and flags are 5 bits, so
  three-source forwarding on them is cheap.
- **Store width comes from the *source* register's tag** (spec §5.3). The tag must be forwarded and
  resolved in X, because it decides `store_we`, `store_data` *and* `misaligned` — and fault
  precision depends on those being known before anything commits.
- **The value array keeps exactly one write port.** `docs/gowin-sv-support.md` measured a second
  port collapsing the array from 32 SSRAM primitives to 1120 flip-flops and ~3700 LUTs. The
  widening multiply's high half and the jump link register stay serialized (spec §5.5, §6.3). Do
  not "fix" this while pipelining.
- **Read-before-write in the register file stays.** The note at `k2g_regfile.sv` explains that a
  write-first bypass closed a combinational loop in the *single-cycle* core. Pipelined, the
  in-flight write comes from an earlier instruction, so bypassing becomes correct and necessary —
  but it belongs in `k2g_forward.sv`. Update that comment rather than deleting it.
- **The predicate read.** Keep the third read port and read `rc` in X alongside `ra`/`rb`.
  Evaluating the predicate in D, as `k2g_regfile.sv` once intended, would need a second forwarding
  network reaching back into D, or a stall — worse than the port. Revisit only if area forces it.
- **Zero-bubble branches.** `PrepareJump` primes `nisa` in X; `PerformJump` commits it later. F
  starts fetching the primed target into a shadow stream the moment the prime commits, so by the
  time `PerformJump` reaches X the target's code points are already in the F→D channel. This is
  why the split-branch design exists. An unprimed `PerformJump` stays a defined NOP (spec §6.5).
- **Faults stay precise.** Detection in X, before any commit. `fault_addr` is `isa`, which now
  travels down the pipeline with the uop rather than being computed from `pc_d`.

**Gate:** cosim green with latency injection, then synthesize and read the actual Fmax.

---

> **Phases 3 and 4 were swapped.** As originally written, caches came first and the 8 KB BSRAM
> served as main memory. That is degenerate: an 8 KB cache over 8 KB of memory has one line per
> address, so every miss is a cold miss and the write-back path never evicts anything dirty. Making
> the cache small enough to exercise properly would mean sizing it for this phase and again for the
> next, and building a refill path against 4-byte BSRAM reads that PSRAM's burst then replaces.
>
> The original justification — prove caches "before PSRAM's timing enters" — has already been
> banked elsewhere: what needed de-risking was whether the core tolerates variable latency, and that
> is Phase 1's gate, green at `LATENCY=40`. Cosim never sees real PSRAM in either order anyway;
> simulating the Gowin IP through calibration is not practical, so main memory in simulation is
> `k2g_mem_slow` at high latency regardless.
>
> The core already tolerates arbitrary latency, so PSRAM without a cache works — slowly — and the
> machine stays runnable in between.

## Phase 3 — PSRAM

- **`rtl/k2g_psram.sv`** — wraps `PSRAM_Memory_Interface_HS_Top` from
  `K2606/src/psram_memory_interface_hs/`: 21-bit address, 64-bit user data, 32-byte bursts,
  `memory_clk` 135 MHz, initial latency 6. `K2606/src/psram_ctrl.sv` is **empty** — there is no
  existing controller to build on. Nothing may issue a command before `init_calib`.
- **`rtl/k2g_cdc_fifo.sv`** — core domain ↔ PSRAM `clk_out`. Do **not** port `docs/attic/pipe.sv`'s
  `PipeCDC` as written: its salt bits cross domains with no synchronizer flops, which is a
  metastability bug rather than a style difference. Gray-coded async FIFO, two-flop synchronizers
  on each pointer, and constrain the crossing in `rtl/board/tangnano9k.sdc` — an unconstrained CDC
  passes timing analysis and fails on hardware.
- **Boot.** The ROM-and-copier scheme in `k2g_soc.sv` stays; GowinSynthesis still will not
  initialize memory from `$readmemh`. The copier targets PSRAM and waits for `init_calib`.
- **`MEM_BYTES` becomes 8 MB** in `k2g_core.sv`, `k2g_soc.sv`, `tb_cosim.sv` and the emulator. That
  moves the `ADDR_OUT_OF_RANGE` boundary, which is architecturally visible, so both move in one
  commit.
- Add a **`psram` bring-up stage** to `rtl/board/build.sh` and `docs/bring-up.md`, between
  `loopback` and `soc`. The staged structure exists so a failure says which layer is at fault; a
  new layer earns a new stage.

**Gate:** psram bitstream passes on hardware; `soc` runs `hello` and `fibforever` at `CLK_DIV = 1`;
cosim green.

---

## Phase 4 — instruction and data caches

**Goal:** caches over the real 8 MB backing store, built once. (Was: before PSRAM's timing enters.

- **`rtl/k2g_icache.sv`**, **`rtl/k2g_dcache.sv`** — direct-mapped, 8 KB each, 32-byte lines
  matching the PSRAM IP's configured 32-byte burst so a refill is exactly one burst. D$ is
  write-back with dirty bits and a victim writeback path. Confirm the IP's user-side beat count and
  `clk_out` from the IP sources rather than assuming them.
- **Data arrays reuse `k2g_mem.sv`'s shape** — four byte lanes, one DPB each, instantiated not
  inferred. That structure exists because Gowin BSRAM has no per-byte write enables, and it is
  exactly what a cache data array needs. 8 blocks of the 22 free.
- **A refill takes a bus lock.** `k2g_membus` carries one beat per request and has no burst length,
  so the requests of a 32-byte line fill are not marked as one thing. The refilling master
  holds the bus across the whole run. A line half-filled from two addresses is undetectable
  afterwards — it answers wrong forever, from a tag that says it is valid. The full reasoning is
  in `rtl/k2g_membus.sv`; the lock is the first thing to write, before either cache.
- Tags in flip-flops: 23-bit space, 7-bit index, 6-bit offset → 10 tag bits + valid (+ dirty) ×
  128 lines. Registers are at 12% utilization.

**Four currently-no-op prefixes become real hardware.** Spec §3.2 warns that ignoring a
reinterpreting prefix does not degrade gracefully:

| Prefix | v1 | v2 |
|---|---|---|
| `ICINVR` + `ST` | decoded, no-op | **real** range operation |
| `MPI` / `MPD` + `TST` | decoded, no-op | prefetch hint into I$ / D$ |
| `ESP` + `ST` | decoded, no-op | stays a no-op |
| `LTL`/`SL`/`SS`/`SR` | ignored, sets `STICKY_STATUS.0` | still ignored — single core, still correct |

`ICINVR` needs care given the write-back D$. Spec §3.2 calls it "instruction-cache range
invalidate", but that is not sufficient to make self-modifying code work: the newly written
instructions may still be sitting dirty in the D$ when the I$ refills from memory. **`ICINVR` must
clean the D$ over the range and then invalidate the I$ over the range** — "make stores visible to
fetch across this range". Spec §3.2 and §10 need widening to say so.

**Gate:** cosim green; new `tb_icache` / `tb_dcache` green; a self-modifying-code program passes on
both machines.

---

## Risks

- **Logic utilization is the binding constraint, not BSRAM.** v1 is at 55% of 8640 LUTs before a
  pipeline, two caches, a CDC FIFO and the PSRAM IP. BSRAM is comfortable (8 of 22 free blocks);
  LUTs may not be. Synthesize each module as it is written and record the number. If it overflows,
  the levers in order are cache size, tag width, then the register file's third read port.
- **The register file moved into 3 BSRAM blocks at 2b — investigated, and it is a win.** The
  netlist has three `SDPB`, one per read port, holding the value array. Cause: registering the uop
  gave synthesis a *registered read address*, which is exactly the shape a synchronous BSRAM read
  needs, so it retimed those pipeline flops into the RAM's own address port. `grep -c '.Q(\uop.dst'`
  over the netlist returns **0** — no flip-flop drives the read address, confirming absorption
  rather than an added cycle. Register-then-async-read and address-register-then-sync-read are the
  same timing, so the read is not delayed.

  The array's reset-to-zero survived too: a per-entry written-mask is ANDed with the RAM output
  (`LUT2 ... INIT=4'h8`), so an unwritten register still reads zero. That mask is what the SSRAM
  left in `u_rf` now is.

  Consequences: it is a large part of the 565-LUT drop, and it costs 3 blocks from the cache budget
  (22 free → 19; the two 8 KB caches need 8). One fragility to keep in mind — the retiming depends
  on the read address being a clean register output. Forwarding in 2c muxes read *data*, not
  addresses, so it should hold; if a read address ever becomes combinational, expect a silent
  fallback to SSRAM and a different Fmax.
- **Silent toolchain failures.** `gw_sh` has exited 1 with no output at all. When a build fails
  without a message, bisect the source; there will be nothing to read.
- **Guard simulation-only code on `SIMULATION`, never `SYNTHESIS`** — GowinSynthesis does not
  define the latter, and this has already caused one silent exit.
- **The CDC is the one thing cosimulation cannot catch.** Lockstep comparison runs in one clock
  domain and will never see a metastability failure. It needs constraints and hardware testing.

## Verification

Every phase ends at the same gate, from **Git Bash, not WSL**:

```bash
cd emu && cargo test
```

```bash
bash rtl/sim/run.sh
```

```bash
bash rtl/sim/cosim.sh
```

The third is the one that matters. New verification this plan adds:

- **Latency injection in cosim from Phase 1 onward.** A memory model that always answers in one
  cycle cannot distinguish a design that tolerates variable latency from one that does not — the
  same blind spot as the testbench that held `uart_tx_ready` high forever and let a flow-control
  bug reach hardware.
- **`rtl/tb/tb_chan.sv`** — the channel primitive under full/empty/backpressure.
- **`rtl/tb/tb_icache.sv`, `rtl/tb/tb_dcache.sv`** — hit, miss, eviction, dirty writeback, `ICINVR`
  range, `MPI`/`MPD` prefetch.
- **A self-modifying-code program** in `emu/programs/`, run under cosim. The only test that proves
  the write-back D$ and the I$ agree.
- **`rtl/sim/mutants.sh`** — negative tests. Every new guard added by a phase gets a mutant that it
  is required to catch, so "this test passes" is never the whole claim. A mutation whose pattern
  stops matching fails the run rather than being skipped.
- **Fmax read from the place-and-route report at every phase gate**, not only at the end.
