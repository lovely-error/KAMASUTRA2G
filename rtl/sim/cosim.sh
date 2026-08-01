#!/usr/bin/env bash
# Lockstep cosimulation: the RTL core against the Rust emulator.
#
# After every instruction the RTL retires, the emulator is stepped once and all
# architectural state is compared -- 32 register values, 32 tags, 32 flag
# pairs, and the jump latch. Roughly 1200 bits per instruction, versus the
# couple of dozen output bytes a program's UART traffic checks.
#
#   bash rtl/sim/cosim.sh                 # shipped programs + 20 random seeds
#   bash rtl/sim/cosim.sh 5               # shipped programs + 5 random seeds
#   bash rtl/sim/cosim.sh 0 hello.bin     # one specific image
#
# A failing seed is reproducible:
#   cd emu && cargo run --release --bin kgen -- --seed N --count 250 -o r.bin

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
SOURCES=("$RTL/k2g_pkg.sv" "$RTL/k2g_types.svh")
for f in "$RTL"/k2g_*.sv; do
    [ "$(basename "$f")" = "k2g_pkg.sv" ] || SOURCES+=("$f")
done
# Simulation-only models first; they are instantiated by the testbenches.
SOURCES+=("$RTL"/tb/k2g_*.sv)
SOURCES+=("$RTL"/tb/tb_*.sv)

if ! "$QUESTA/vlog.exe" -sv -quiet +define+SIMULATION "+incdir+$RTL_WIN" "${SOURCES[@]}" > vlog.log 2>&1 \
   || grep -qE '^\*\* Error' vlog.log; then
    echo "COMPILE FAILED"
    grep -E '^\*\* Error' vlog.log | head -20
    exit 1
fi

run_one() {
    local img="$1" label="$2"
    local log="$WORK/cosim_${label}.log"
    "$QUESTA/vsim.exe" -c -quiet -sv_lib "$DPI" \
        -do "onerror {quit -code 1}; run -all; quit -f" \
        "+image=$img" "+latency=$LATENCY" "+ilatency=$ILATENCY" tb_cosim > "$log" 2>&1
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

if [ -n "$ONE_IMAGE" ]; then
    run_one "$ONE_IMAGE" "$(basename "$ONE_IMAGE" .bin)" || fail=1
else
    # The shipped programs first: they exercise control flow, which the random
    # generator deliberately does not.
    for prog in hello fib hazard; do
        src="$ROOT/emu/programs/$prog.kasm"
        [ -f "$src" ] || continue
        ( cd "$ROOT/emu" && cargo run --release --quiet --bin kasm -- \
            "programs/$prog.kasm" -o "$WORK/$prog.bin" ) > /dev/null 2>&1
        run_one "$WORK/$prog.bin" "$prog" || fail=1
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
