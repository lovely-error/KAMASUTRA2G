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

**Still to do:** the **instruction** port still assumes a fixed one-cycle answer. Converting it
needs credit-based issue and an elastic F→D buffer — otherwise one-outstanding-request fetch halves
throughput — and that is a rewrite of the fetch unit, which is Phase 2's first job. It is done
there rather than twice.

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

| Stage | Work |
|---|---|
| **F** | PC generation, I-fetch request, shadow prefetch stream |
| **D** | prefix accumulator (`k2g_decode`), uop formation |
| **X** | register read + forwarding + ALU / shift / multiply + address generation + fault detection |
| **M** | data memory access |
| **W** | writeback |

Split `k2g_core.sv` into `k2g_fetch.sv`, `k2g_exec.sv`, `k2g_lsu.sv`, `k2g_forward.sv`, leaving
`k2g_core.sv` as stage instantiation and channel wiring.

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

## Phase 3 — instruction and data caches

**Goal:** caches proven against BSRAM-backed slow memory, before PSRAM's timing enters.

- **`rtl/k2g_icache.sv`**, **`rtl/k2g_dcache.sv`** — direct-mapped, 8 KB each, 64-byte lines
  matching the PSRAM IP's configured 64-byte burst so a refill is exactly one burst. D$ is
  write-back with dirty bits and a victim writeback path. Confirm the IP's user-side beat count and
  `clk_out` from the IP sources rather than assuming them.
- **Data arrays reuse `k2g_mem.sv`'s shape** — four byte lanes, one DPB each, instantiated not
  inferred. That structure exists because Gowin BSRAM has no per-byte write enables, and it is
  exactly what a cache data array needs. 8 blocks of the 22 free.
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

## Phase 4 — PSRAM

- **`rtl/k2g_psram.sv`** — wraps `PSRAM_Memory_Interface_HS_Top` from
  `K2606/src/psram_memory_interface_hs/`: 21-bit address, 64-bit user data, 64-byte bursts,
  `memory_clk` 166 MHz, initial latency 6. `K2606/src/psram_ctrl.sv` is **empty** — there is no
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

## Risks

- **Logic utilization is the binding constraint, not BSRAM.** v1 is at 55% of 8640 LUTs before a
  pipeline, two caches, a CDC FIFO and the PSRAM IP. BSRAM is comfortable (8 of 22 free blocks);
  LUTs may not be. Synthesize each module as it is written and record the number. If it overflows,
  the levers in order are cache size, tag width, then the register file's third read port.
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
