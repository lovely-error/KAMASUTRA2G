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

# Fail clearly if this is WSL rather than Git Bash; the Windows toolchains
# are not reachable from WSL and the resulting error is misleading.
. "$HERE/shell_check.sh"
k2g_require_windows_shell || exit 1
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
for f in "$RTL"/board/k2g_*.sv; do
    # The board-level tops instantiate pins and are not simulated here; only
    # the reusable blocks (the UART) are.
    case "$(basename "$f")" in
        k2g_uart.sv) SOURCES+=("$f") ;;
        *) ;;
    esac
done
for f in "$RTL"/tb/tb_*.sv; do
    [ -e "$f" ] && SOURCES+=("$f")
done

# Questa is a Windows binary, so +incdir+ needs a Windows-style path even
# when this script runs under git bash.
RTL_WIN="$(cygpath -m "$RTL" 2>/dev/null || echo "$RTL")"

log="$WORK/vlog.log"
if ! "$VLOG" -sv -quiet +define+SIMULATION "+incdir+$RTL_WIN" "${SOURCES[@]}" > "$log" 2>&1; then
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

# tb_core runs a real assembled program rather than directed vectors, so it is
# driven once per image, with the UART output the program is expected to print.
PROGRAMS=(
    "hello.bin:Hello"
    "fib.bin:55"
)

# Assemble the images from source so RTL and emulator always run the same bits.
for spec in "${PROGRAMS[@]}"; do
    img="${spec%%:*}"
    src="$ROOT/emu/programs/${img%.bin}.kasm"
    [ -f "$src" ] || continue
    ( cd "$ROOT/emu" && cargo run --quiet --bin kasm --         "programs/$(basename "$src")" -o "$HERE/$img" ) > /dev/null 2>&1
done

fail=0
for t in "${tests[@]}"; do
    out="$WORK/$t.log"
    # tb_cosim needs an image and the DPI shared object; rtl/sim/cosim.sh
    # drives it, including the random-seed sweep.
    if [ "$t" = "tb_cosim" ]; then
        printf '%-24s SKIP  (run: bash rtl/sim/cosim.sh)
' "$t"
        continue
    fi

    if [ "$t" = "tb_core" ]; then
        for spec in "${PROGRAMS[@]}"; do
            img="${spec%%:*}"
            want="${spec##*:}"
            [ -f "$HERE/$img" ] || continue
            plog="$WORK/tb_core_${img%.bin}.log"
            "$VSIM" -c -quiet -do "onerror {quit -code 1}; run -all; quit -f"                 "+image=$HERE/$img" "+expect=$want" tb_core > "$plog" 2>&1
            if grep -q "TB_PASS" "$plog" && ! grep -qE '^# \*\* (Error|Fatal)' "$plog"; then
                n=$(grep -oE 'instructions: [0-9]+' "$plog" | tail -1 | cut -d' ' -f2)
                printf '%-24s PASS  %s instructions
' "tb_core[${img%.bin}]" "$n"
            else
                printf '%-24s FAIL
' "tb_core[${img%.bin}]"
                grep -E 'TB_FAIL|^# \*\* (Error|Fatal)|uart output' "$plog" | head -8
                fail=1
            fi
        done
        continue
    fi

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
