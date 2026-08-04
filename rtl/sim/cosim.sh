#!/usr/bin/env bash
# Lockstep cosimulation: the RTL core against the Rust emulator.
#
# After every instruction the RTL retires, the emulator is stepped once and all
# architectural state is compared -- 32 register values, 32 tags, 32 flag
# pairs, and the jump latch. Roughly 1200 bits per instruction, versus the
# couple of dozen output bytes a program's UART traffic checks.
#
# Memory is compared once, at the stop, over the words either machine wrote.
# It went unchecked for a long time, and a store is invisible in every register
# -- so a core that faulted AND stored, or that suppressed a store it should
# have made, passed everything else.
#
#   bash rtl/sim/cosim.sh                 # shipped programs + 20 random seeds
#   bash rtl/sim/cosim.sh 5               # shipped programs + 5 random seeds
#   bash rtl/sim/cosim.sh 0 hello.bin     # one specific image
#
# Every run also sweeps the ten faulting generator programs, one per cause,
# where the expected cause comes from the generator that built the image.
# The shipped programs' own expected causes live in emu/tests/programs.rs:
# agreement between the two machines is not the same as either being right.
#
# A failing seed is reproducible:
        ( cd "$ROOT/emu" && cargo run --release --quiet --bin kgen -- \
            --seed "$((k + 1))" --count "$COUNT" --fault "$k" \
            -o "$WORK/randf_$k.bin" ) > /dev/null 2>&1

set -u

QUESTA="${QUESTA:-E:/Quartus/questa_fse/win64}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Fail clearly if this is WSL rather than Git Bash; the Windows toolchains
# are not reachable from WSL and the resulting error is misleading.
. "$HERE/shell_check.sh"
k2g_require_windows_shell || exit 1
# ROOT comes from this script's own location, never from RTL: `mutants.sh`
# points K2G_RTL at a throwaway copy of the sources, and the emulator, the
# programs and the DPI object must still come from the real tree.
ROOT="$(cd "$HERE/../.." && pwd)"
RTL="$(cd "${K2G_RTL:-$HERE/..}" && pwd)"
WORK="$RTL/sim/work"

SEEDS="${1:-20}"
ONE_IMAGE="${2:-}"
COUNT="${COUNT:-250}"

# Extra data-memory latency, drawn per access from [0, LATENCY]. Zero
# reproduces the fixed one-cycle BSRAM port exactly.
#
# This is not decoration. A memory that always answers in one cycle cannot
# distinguish a core that tolerates variable latency from one that happens to
# work at one cycle -- and Phase 3 puts caches behind this bus, where a miss
# costs tens of cycles. A stall is architecturally invisible by construction
# (nothing commits during one), so every latency setting must produce byte-for
# -byte identical results. If one does not, the core is reading something it
# does not own.
LATENCY="${LATENCY:-0}"

# Instruction-side latency, swept separately. A slow fetch and a slow load
# exercise completely different machinery: credit-limited issue and abandoning
# a mis-fetched stream on one side, the pending-load path on the other. A
# single knob would let one hide the other's bugs.
ILATENCY="${ILATENCY:-0}"

# A space-separated subset of the shipped programs, for when a run is aimed at
# one thing: rtl/sim/mutants.sh breaks a single guard and wants the one program
# that guard protects, not a 90-second sweep of everything. Empty runs the
# whole set, which is what a phase gate wants.
PROGRAMS="${PROGRAMS:-}"

[ -x "$QUESTA/vsim.exe" ] || { echo "questa not found at $QUESTA" >&2; exit 1; }

# The emulator is loaded as a DPI-C shared object, so it must be built first.
echo "building emulator (release, cdylib) ..."
( cd "$ROOT/emu" && cargo build --release --quiet ) || exit 1
DPI="$ROOT/emu/target/release/emu"
[ -f "$DPI.dll" ] || { echo "missing $DPI.dll" >&2; exit 1; }

mkdir -p "$WORK"
cd "$WORK" || exit 1
rm -rf work
"$QUESTA/vlib.exe" work > /dev/null || exit 1

RTL_WIN="$(cygpath -m "$RTL" 2>/dev/null || echo "$RTL")"
# Every tb_*.sv is compiled here, including tb_soc, which includes k2g_rom.svh
# from beside the SoC rather than from rtl/. Only tb_cosim is ever elaborated,
# so the board modules themselves do not have to be in the source list -- but
# an unfound `include is a compile error rather than an elaboration one.
BRD_WIN="$(cygpath -m "$RTL/board" 2>/dev/null || echo "$RTL/board")"
SOURCES=("$RTL/k2g_pkg.sv" "$RTL/k2g_types.svh")
for f in "$RTL"/k2g_*.sv; do
    [ "$(basename "$f")" = "k2g_pkg.sv" ] || SOURCES+=("$f")
done
# Simulation-only models first; they are instantiated by the testbenches.
SOURCES+=("$RTL"/tb/k2g_*.sv)
SOURCES+=("$RTL"/tb/tb_*.sv)

if ! "$QUESTA/vlog.exe" -sv -quiet +define+SIMULATION "+incdir+$RTL_WIN" "+incdir+$BRD_WIN" "${SOURCES[@]}" > vlog.log 2>&1 \
   || grep -qE '^\*\* Error' vlog.log; then
    echo "COMPILE FAILED"
    grep -E '^\*\* Error' vlog.log | head -20
    exit 1
fi

run_one() {
    local img="$1" label="$2" want="${3:-}"
    local log="$WORK/cosim_${label}.log"
    "$QUESTA/vsim.exe" -c -quiet -sv_lib "$DPI" \
        -do "onerror {quit -code 1}; run -all; quit -f" \
        "+image=$img" "+latency=$LATENCY" "+ilatency=$ILATENCY" \
        ${want:+"+expect_cause=$want"} tb_cosim > "$log" 2>&1
    if grep -q TB_PASS "$log"; then
        local n c
        n=$(grep -oE 'retired=[0-9]+' "$log" | tail -1 | cut -d= -f2)
        c=$(grep -oE 'checks=[0-9]+' "$log" | tail -1 | cut -d= -f2)
        printf '%-18s PASS  %5s instructions, %6s state checks\n' "$label" "$n" "$c"
        return 0
    fi
    printf '%-18s FAIL\n' "$label"
    grep -A6 'divergence' "$log" | head -8
    grep -E 'TB_FAIL' "$log" | head -3
    return 1
}

fail=0
total_checks=0
# The totals below add up every cosim_*.log in the work directory, so last
# run's logs have to go first -- otherwise a filtered run reports the whole
# suite's comparison count for the one program it actually ran.
rm -f "$WORK"/cosim_*.log

if [ -n "$ONE_IMAGE" ]; then
    run_one "$ONE_IMAGE" "$(basename "$ONE_IMAGE" .bin)" || fail=1
else
    # The shipped programs first: they exercise control flow, which the random
    # generator deliberately does not.
    #
    # The f32_* programs are here rather than among the emulator's own tests
    # because what they check is a two-sided property: the reserved F32 tag
    # (spec 11) must fault with the SAME cause in both machines, and each model
    # was previously wrong in its own direction. `kgen` cannot reach them --
    # it deliberately never emits `RDT f32` -- so without these the random
    # seeds below would sweep straight past the check.
    #
    # The fault_* programs cover the execute-time faults, which nothing on the
    # RTL side pinned: deleting the misaligned check from k2g_core.sv left
    # every testbench and the whole cosimulation passing. `kgen` cannot reach
    # them either -- it picks every address so it cannot fault.
    #
    # fault_prefix and fault_opcode exist for FAULT_INFO rather than for their
    # causes: a halted machine cannot read its own fault registers, so the
    # cosimulation is the only thing that ever looks at them. fault_condcode
    # is for the cause, which used to be ILLEGAL_OPCODE here and
    # ILLEGAL_PREFIX_COMBO in the RTL.
    all_programs="hello fib hazard
                  f32_operand f32_store f32_predicate f32_escape f32_csp
                  fault_access fault_store fault_range fault_port fault_fetch
                  fault_squashed fault_unpredicated
                  fault_prefix fault_opcode fault_condcode"
    for prog in ${PROGRAMS:-$all_programs}; do
        src="$ROOT/emu/programs/$prog.kasm"
        [ -f "$src" ] || continue
        ( cd "$ROOT/emu" && cargo run --release --quiet --bin kasm -- \
            "programs/$prog.kasm" -o "$WORK/$prog.bin" ) > /dev/null 2>&1
        run_one "$WORK/$prog.bin" "$prog" || fail=1
    done

    # Then the same generator ending in a deliberate fault, one cause per
    # seed. The directed fault_* programs above reach each fault from four
    # instructions of setup; these reach it after a few hundred, with the
    # register file, the tags and the flags in whatever state the random
    # program left them -- which is the part a hand-written program cannot
    # arrange. The expected cause comes from kgen rather than a table here.
    for k in $(seq 0 9); do
        [ -n "$PROGRAMS" ] && break
        ( cd "$ROOT/emu" && cargo run --release --quiet --bin kgen -- \
            --seed "$((k + 1))" --count "$COUNT" --fault "$k" \
            -o "$WORK/randf_$k.bin" ) > /dev/null 2>&1
        want=$( cd "$ROOT/emu" && cargo run --release --quiet --bin kgen -- \
            --fault-cause "$k" )
        run_one "$WORK/randf_$k.bin" "random-fault[$k]" "$want" || fail=1
    done

    # Then random straight-line programs, which cover the execute path the two
    # shipped programs barely touch.
    for s in $(seq 1 "$SEEDS"); do
        ( cd "$ROOT/emu" && cargo run --release --quiet --bin kgen -- \
            --seed "$s" --count "$COUNT" -o "$WORK/rand_$s.bin" ) > /dev/null 2>&1
        run_one "$WORK/rand_$s.bin" "random[seed=$s]" || fail=1
    done
fi

for f in "$WORK"/cosim_*.log; do
    [ -e "$f" ] || continue
    c=$(grep -oE 'checks=[0-9]+' "$f" | tail -1 | cut -d= -f2)
    total_checks=$((total_checks + ${c:-0}))
done

echo
if [ $fail -eq 0 ]; then
    echo "COSIM PASS -- $total_checks architectural state comparisons, no divergence (data 0..$LATENCY, insn 0..$ILATENCY)"
else
    echo "COSIM FAIL"
fi
exit $fail
