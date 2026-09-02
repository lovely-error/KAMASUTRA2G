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
k2g_require_no_questa || exit 1
# ROOT is derived from this script's own location, never from RTL: `mutants.sh`
# points K2G_RTL at a throwaway copy of the sources, and the emulator, the
# programs and the DPI object must still come from the real tree.
ROOT="$(cd "$HERE/../.." && pwd)"
RTL="$(cd "${K2G_RTL:-$HERE/..}" && pwd)"
WORK="$RTL/sim/work"

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

# The boot ROM is generated, not committed -- both k2g_rom.sv and the
# k2g_rom.svh beside it come out of mkrom. Without this a fresh clone compiles
# k2g_soc against a module that does not exist and tb_soc dies with "Module
# 'k2g_rom' is not defined", which says nothing about the cause. Regenerated
# every run rather than only when missing, for the same reason the test
# programs below are: RTL and emulator then always run the same bits.
if [ -f "$ROOT/emu/programs/hello.kasm" ]; then
    ( cd "$ROOT/emu"         && cargo run --release --quiet --bin kasm              -- programs/hello.kasm -o "$ROOT/rtl/board/hello.bin"         && cargo run --release --quiet --bin mkrom              -- "$ROOT/rtl/board/hello.bin" -o "$ROOT/rtl/board/k2g_rom.sv"     ) > /dev/null 2>&1 || echo "warning: could not generate the boot ROM; tb_soc will fail" >&2
fi

mkdir -p "$WORK"
cd "$WORK" || exit 1
rm -rf work
"$VLIB" work > /dev/null || exit 1

# Order matters: the generated packages first, then shared types. Both are
# named here rather than left to the glob below, which happens to sort them
# early today and would stop doing so the moment a module is renamed.
SOURCES=(
    "$RTL/k2g_pkg.sv"
    "$RTL/k2g_host_pkg.sv"
    "$RTL/k2g_types.svh"
)
for f in "$RTL"/k2g_*.sv; do
    case "$(basename "$f")" in
        k2g_pkg.sv|k2g_host_pkg.sv) ;;
        *) SOURCES+=("$f") ;;
    esac
done
for f in "$RTL"/board/k2g_*.sv; do
    # Most board-level tops are pins and LEDs and are not simulated here. The
    # SoC is, because it is where the copier, the bus mux and the PSRAM adapter
    # first meet -- and the only alternative to simulating that is flashing it.
    # It needs the PLL and the generated ROM with it; the Gowin primitives they
    # bottom out in are modelled in rtl/tb (k2g_rpll_model, k2g_psram_model).
    case "$(basename "$f")" in
        k2g_uart.sv|k2g_pll.sv|k2g_rom.sv|k2g_soc.sv) SOURCES+=("$f") ;;
        *) ;;
    esac
done
# Simulation-only models (k2g_mem_slow) live in tb/ rather than rtl/ so the
# board build's `k2g_*.sv` glob cannot reach them. They must be compiled
# before the testbenches that instantiate them.
for f in "$RTL"/tb/k2g_*.sv; do
    [ -e "$f" ] && SOURCES+=("$f")
done
for f in "$RTL"/tb/tb_*.sv; do
    # tb_psram instantiates the Gowin IP model; rtl/sim/psram.sh compiles it
    # with that model and the primitive library.
    [ "$(basename "$f")" = "tb_psram.sv" ] && continue
    [ -e "$f" ] && SOURCES+=("$f")
done

# Questa is a Windows binary, so +incdir+ needs a Windows-style path even
# when this script runs under git bash.
RTL_WIN="$(cygpath -m "$RTL" 2>/dev/null || echo "$RTL")"
# k2g_soc includes k2g_rom.svh, which lives beside it rather than in rtl/.
BRD_WIN="$(cygpath -m "$RTL/board" 2>/dev/null || echo "$RTL/board")"

log="$WORK/vlog.log"
if ! "$VLOG" -sv -quiet +define+SIMULATION "+incdir+$RTL_WIN" "+incdir+$BRD_WIN" "${SOURCES[@]}" > "$log" 2>&1; then
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
    "hazard.bin:"
)

# Assemble the images from source so RTL and emulator always run the same bits.
for spec in "${PROGRAMS[@]}"; do
    img="${spec%%:*}"
    src="$ROOT/emu/programs/${img%.bin}.kasm"
    [ -f "$src" ] || continue
    ( cd "$ROOT/emu" && cargo run --quiet --bin kasm --         "programs/$(basename "$src")" -o "$WORK/$img" ) > /dev/null 2>&1
done

fail=0
for t in "${tests[@]}"; do
    out="$WORK/$t.log"
    # tb_cosim needs an image and the DPI shared object; rtl/sim/cosim.sh
    # drives it, including the random-seed sweep.
    # tb_psram needs the IP's post-place-and-route model and Gowin's primitive
    # library, neither of which this script compiles.
    if [ "$t" = "tb_psram" ]; then
        printf '%-24s SKIP  (run: bash rtl/sim/psram.sh)
' "$t"
        continue
    fi

    if [ "$t" = "tb_cosim" ]; then
        printf '%-24s SKIP  (run: bash rtl/sim/cosim.sh)
' "$t"
        continue
    fi

    if [ "$t" = "tb_core" ]; then
        for spec in "${PROGRAMS[@]}"; do
            img="${spec%%:*}"
            want="${spec##*:}"
            [ -f "$WORK/$img" ] || continue
            plog="$WORK/tb_core_${img%.bin}.log"
            "$VSIM" -c -quiet -do "onerror {quit -code 1}; run -all; quit -f"                 "+image=$WORK/$img" "+expect=$want" tb_core > "$plog" 2>&1
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

    # tb_soc loads a program over the serial link and runs it, so it needs an
    # image and the text that program prints. `fib` rather than `hello`: the
    # boot ROM already prints Hello, so a loaded program printing the same thing
    # would pass whether or not it ever ran.
    if [ "$t" = "tb_soc" ] && [ -f "$WORK/fib.bin" ]; then
        "$VSIM" -c -quiet -do "onerror {quit -code 1}; run -all; quit -f"             "+image=$WORK/fib.bin" tb_soc > "$out" 2>&1
        rc=$?
        if grep -q "TB_PASS" "$out" && ! grep -qE '^# \*\* (Error|Fatal)' "$out" && [ $rc -eq 0 ]; then
            n=$(grep -oE 'checks=[0-9]+' "$out" | tail -1 | cut -d= -f2)
            printf '%-24s PASS  %s
' "$t" "${n:+$n checks}"
        else
            printf '%-24s FAIL
' "$t"
            grep -E '^# \*\* (Error|Fatal)|TB_FAIL|Mismatch' "$out" | head -12
            fail=1
        fi
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
