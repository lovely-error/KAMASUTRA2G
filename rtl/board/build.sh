#!/usr/bin/env bash
# Build a Tang Nano 9K bitstream through the full Gowin flow.
#
#   bash rtl/board/build.sh blink       # stage 1: LEDs only
#   bash rtl/board/build.sh loopback    # stage 2: UART echo, no CPU
#   bash rtl/board/build.sh soc         # stage 3: the whole machine
#
# Staged deliberately. If the board misbehaves, the stage that fails says which
# layer is at fault: blink means toolchain/pinout/clock, loopback means UART
# pins or baud rate, soc means the CPU or the memory image.
#
# Flash with (openFPGALoader, or the Gowin programmer GUI):
#   openFPGALoader -b tangnano9k rtl/board/out/<stage>/impl/pnr/project.fs

set -u

GW_SH="${GW_SH:-C:/Gowin/Gowin_V1.9.12.02_SP2_x64/IDE/bin/gw_sh.exe}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Fail clearly if this is WSL rather than Git Bash; the Windows toolchains
# are not reachable from WSL and the resulting error is misleading.
. "$HERE/../sim/shell_check.sh"
k2g_require_windows_shell || exit 1
RTL="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$RTL/.." && pwd)"

STAGE="${1:-blink}"
WORK="$HERE/out/$STAGE"

[ -x "$GW_SH" ] || { echo "gw_sh not found at $GW_SH (set GW_SH=<path>)" >&2; exit 1; }

# The SoC embeds a program, so regenerate the boot ROM from source first.
if [ "$STAGE" = "soc" ]; then
    PROG="${PROG:-hello}"
    echo "generating boot ROM from programs/$PROG.kasm ..."
    ( cd "$ROOT/emu"       && cargo run --release --quiet --bin kasm  -- "programs/$PROG.kasm" -o "$HERE/$PROG.bin"       && cargo run --release --quiet --bin mkrom -- "$HERE/$PROG.bin" -o "$HERE/k2g_rom.sv" ) || exit 1
fi

case "$STAGE" in
    blink)    TOP="k2g_blink";    SRC=("$HERE/k2g_blink.sv") ;;
    loopback) TOP="k2g_loopback"; SRC=("$HERE/k2g_uart.sv" "$HERE/k2g_loopback.sv") ;;
    psram)
        # The in-package PSRAM on its own: PLL, controller, calibration and a
        # readback check, reported on the LEDs. No UART and no clock crossing,
        # so a failure here is about the memory and nothing else.
        TOP="k2g_psram_probe"
        SRC=("$HERE/k2g_pll.sv" "$HERE/k2g_psram_probe.sv"
             "$ROOT/K2606/src/psram_memory_interface_hs/psram_memory_interface_hs.v")
        ;;
    soc)
        TOP="k2g_soc"
        SRC=("$RTL/k2g_pkg.sv" "$RTL/k2g_types.svh")
        for f in "$RTL"/k2g_*.sv; do
            [ "$(basename "$f")" = "k2g_pkg.sv" ] || SRC+=("$f")
        done
        SRC+=("$HERE/k2g_uart.sv" "$HERE/k2g_rom.sv" "$HERE/k2g_soc.sv")
        ;;
    *) echo "unknown stage '$STAGE' (blink | loopback | psram | soc)" >&2; exit 1 ;;
esac

rm -rf "$WORK"; mkdir -p "$WORK"
for f in "${SRC[@]}"; do cp "$f" "$WORK/"; done
cp "$HERE/tangnano9k.cst" "$HERE/tangnano9k.sdc" "$WORK/"
# Stage-specific timing, if any. Constraints naming nets that exist in only one
# design must not go in the shared file: Gowin errors on a missing object.
[ -f "$HERE/tangnano9k_$STAGE.sdc" ] && cp "$HERE/tangnano9k_$STAGE.sdc" "$WORK/"
cp "$RTL/k2g_types.svh" "$WORK/" 2>/dev/null || true
cp "$HERE/k2g_rom.svh" "$WORK/" 2>/dev/null || true
# Memory init files, if the stage needs them.
cp "$HERE"/*.hex "$WORK/" 2>/dev/null || true

{
    echo "set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5"
    for f in "${SRC[@]}"; do
        b="$(basename "$f")"
        case "$b" in
            *.svh) ;;                                    # included, not compiled
            *) echo "add_file -type verilog {$b}" ;;
        esac
    done
    echo "add_file -type cst {tangnano9k.cst}"
    echo "add_file -type sdc {tangnano9k.sdc}"
    [ -f "$WORK/tangnano9k_$STAGE.sdc" ] && echo "add_file -type sdc {tangnano9k_$STAGE.sdc}"
    echo "set_option -top_module $TOP"
    echo "set_option -verilog_std sysv2017"
    echo "set_option -include_path {.}"
    # Leave the unused-pin state defined rather than floating.
    echo "set_option -use_mspi_as_gpio 1"
    echo "set_option -use_sspi_as_gpio 1"
    echo "set_option -use_ready_as_gpio 1"
    echo "set_option -use_done_as_gpio 1"
    echo "set_option -use_reconfign_as_gpio 1"
    echo "run all"
} > "$WORK/build.tcl"

echo "building '$STAGE' (top=$TOP) ..."
( cd "$WORK" && "$GW_SH" build.tcl ) > "$WORK/build.log" 2>&1
rc=$?

if grep -qiE '^ERROR|\bERROR \(' "$WORK/build.log"; then
    echo "BUILD FAILED"
    grep -iE '^ERROR|\bERROR \(' "$WORK/build.log" | head -12
    exit 1
fi
if [ $rc -ne 0 ]; then
    echo "BUILD FAILED: gw_sh exit $rc"
    tail -20 "$WORK/build.log"
    exit 1
fi

FS="$WORK/impl/pnr/project.fs"
if [ ! -f "$FS" ]; then
    echo "BUILD FAILED: no bitstream produced"
    tail -20 "$WORK/build.log"
    exit 1
fi

echo "BUILD OK: $STAGE"
echo "  bitstream: $FS ($(stat -c%s "$FS") bytes)"

# Utilization, from the place-and-route report.
rpt="$WORK/impl/pnr/project.rpt.txt"
[ -f "$rpt" ] || rpt="$(ls "$WORK"/impl/pnr/*.rpt.txt 2>/dev/null | head -1)"
if [ -f "$rpt" ]; then
    grep -iE 'Logic|Register|BSRAM|SSRAM|DSP|I/O Port|Slice' "$rpt" |
        grep -iE '[0-9]+/' | head -8 | sed 's/^/  /'
fi

# Timing. This is the number that says whether the clock target is real; the
# simulation and cosimulation say nothing about it.
tim="$(ls "$WORK"/impl/pnr/*.tr.html "$WORK"/impl/pnr/*timing*.html 2>/dev/null | head -1)"
if [ -f "$tim" ]; then
    python - "$tim" <<'PYEND' || true
import html, re, sys
t = open(sys.argv[1], encoding='utf-8', errors='replace').read()
txt = html.unescape(re.sub('<[^>]*>', ' ', t))
m = re.search(r'Max\s*Freq[^0-9]*([0-9.]+)\s*MHz', txt, re.I)
if m:
    print(f"  Fmax: {m.group(1)} MHz")
for label in ("Setup", "Hold"):
    m = re.search(label + r'[^0-9-]*(-?[0-9.]+)\s*ns', txt, re.I)
    if m:
        slack = float(m.group(1))
        print(f"  {label} slack: {slack} ns" + ("  <-- VIOLATED" if slack < 0 else ""))
PYEND
fi
echo "  full log: $WORK/build.log"
