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
RTL="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$RTL/.." && pwd)"
WORK="$HERE/work"

SEEDS="${1:-20}"
ONE_IMAGE="${2:-}"
COUNT="${COUNT:-250}"

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
SOURCES+=("$RTL"/tb/tb_*.sv)

if ! "$QUESTA/vlog.exe" -sv -quiet "+incdir+$RTL_WIN" "${SOURCES[@]}" > vlog.log 2>&1 \
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
        "+image=$img" tb_cosim > "$log" 2>&1
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
    for prog in hello fib; do
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
    echo "COSIM PASS -- $total_checks architectural state comparisons, no divergence"
else
    echo "COSIM FAIL"
fi
exit $fail
