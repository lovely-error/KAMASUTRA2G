#!/usr/bin/env bash
# Compile and run a K2G testbench under Questa.
#
#   bash rtl/sim/run.sh tb_decode          # one testbench
#   bash rtl/sim/run.sh                    # all of them
#   GUI=1 bash rtl/sim/run.sh tb_decode    # keep the GUI open
#
# Questa is used rather than Verilator because it accepts the full
# SystemVerilog the design uses and supports DPI-C, which the lockstep
# cosimulation against the Rust emulator depends on.

set -u

QUESTA="${QUESTA:-E:/Quartus/questa_fse/win64}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$RTL/.." && pwd)"
WORK="$HERE/work"

VLOG="$QUESTA/vlog.exe"
VSIM="$QUESTA/vsim.exe"
VLIB="$QUESTA/vlib.exe"

for t in "$VLOG" "$VSIM" "$VLIB"; do
    [ -x "$t" ] || { echo "not found: $t (set QUESTA=<dir>)" >&2; exit 1; }
done

[ -f "$RTL/k2g_pkg.sv" ] || {
    echo "rtl/k2g_pkg.sv missing -- run: cd emu && cargo run --bin gen_defs" >&2
    exit 1
}

mkdir -p "$WORK"
cd "$WORK" || exit 1
rm -rf work
"$VLIB" work > /dev/null || exit 1

# Order matters: the generated opcode package first, then shared types.
SOURCES=(
    "$RTL/k2g_pkg.sv"
    "$RTL/k2g_types.svh"
)
for f in "$RTL"/k2g_*.sv; do
    case "$(basename "$f")" in
        k2g_pkg.sv) ;;
        *) SOURCES+=("$f") ;;
    esac
done
for f in "$RTL"/tb/tb_*.sv; do
    [ -e "$f" ] && SOURCES+=("$f")
done

# Questa is a Windows binary, so +incdir+ needs a Windows-style path even
# when this script runs under git bash.
RTL_WIN="$(cygpath -m "$RTL" 2>/dev/null || echo "$RTL")"

log="$WORK/vlog.log"
if ! "$VLOG" -sv -quiet "+incdir+$RTL_WIN" "${SOURCES[@]}" > "$log" 2>&1; then
    echo "COMPILE FAILED"
    grep -E '^\*\* (Error|Fatal)' "$log" | head -20
    exit 1
fi
if grep -qE '^\*\* Error' "$log"; then
    echo "COMPILE FAILED"
    grep -E '^\*\* Error' "$log" | head -20
    exit 1
fi

tests=("$@")
if [ ${#tests[@]} -eq 0 ]; then
    tests=()
    for f in "$RTL"/tb/tb_*.sv; do
        [ -e "$f" ] && tests+=("$(basename "$f" .sv)")
    done
fi

fail=0
for t in "${tests[@]}"; do
    out="$WORK/$t.log"
    if [ "${GUI:-0}" = "1" ]; then
        "$VSIM" -sv_lib "$ROOT/emu/target/release/k2g_dpi" "$t" &
        continue
    fi
    "$VSIM" -c -quiet \
        -do "onerror {quit -code 1}; run -all; quit -f" \
        "$t" > "$out" 2>&1
    rc=$?

    # A testbench reports its own verdict; also treat any assertion or Questa
    # error as failure so a silent testbench cannot pass by saying nothing.
    if grep -q "TB_PASS" "$out" && ! grep -qE '^# \*\* (Error|Fatal)' "$out" && [ $rc -eq 0 ]; then
        n=$(grep -oE 'checks=[0-9]+' "$out" | tail -1 | cut -d= -f2)
        printf '%-24s PASS  %s\n' "$t" "${n:+$n checks}"
    else
        printf '%-24s FAIL\n' "$t"
        grep -E '^# \*\* (Error|Fatal)|TB_FAIL|Mismatch' "$out" | head -12
        fail=1
    fi
done

exit $fail
