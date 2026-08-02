#!/usr/bin/env bash
# Build a Tang Nano 9K bitstream through the full Gowin flow.
#
#   bash rtl/board/build.sh blink       # stage 1: LEDs only
#   bash rtl/board/build.sh loopback    # stage 2: UART echo, no CPU
#   bash rtl/board/build.sh psram       # stage 3: PLL, PSRAM controller, calibration
#   bash rtl/board/build.sh soc         # stage 4: the whole machine
#
# Staged deliberately. If the board misbehaves, the stage that fails says which
# layer is at fault: blink means toolchain/pinout/clock, loopback means UART
# pins or baud rate, psram means the memory or its PLL, soc means the CPU or
# the memory image.
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
        # The PLL and the PSRAM controller come with the SoC now: memory is the
        # in-package PSRAM rather than BSRAM, so the same IP the `psram` stage
        # proves is part of the machine.
        SRC+=("$HERE/k2g_uart.sv" "$HERE/k2g_rom.sv" "$HERE/k2g_pll.sv"
              "$HERE/k2g_soc.sv"
              "$ROOT/K2606/src/psram_memory_interface_hs/psram_memory_interface_hs.v")
        ;;
    *) echo "unknown stage '$STAGE' (blink | loopback | psram | soc)" >&2; exit 1 ;;
esac

rm -rf "$WORK"; mkdir -p "$WORK"
for f in "${SRC[@]}"; do cp "$f" "$WORK/"; done
cp "$HERE/tangnano9k.cst" "$WORK/"
# Timing: a stage file REPLACES the shared one rather than adding to it. Gowin
# will not resolve a clock created in one .sdc from a constraint in another, so
# split constraints fail with "Cannot get clock with name". Stage files are
# self-contained; stages without one use the shared file.
if [ -f "$HERE/tangnano9k_$STAGE.sdc" ]; then
    SDC="tangnano9k_$STAGE.sdc"
else
    SDC="tangnano9k.sdc"
fi
cp "$HERE/$SDC" "$WORK/"
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
    echo "add_file -type sdc {$SDC}"
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
# NOT `head -8`. It was, and the PSRAM build added an IOLOGIC row that pushed
# the BSRAM line off the end -- which was read as "no BSRAM used" and written
# into two documents before anyone checked the report itself.
if [ -f "$rpt" ]; then
    grep -iE 'Logic|Register|BSRAM|SSRAM|DSP|I/O Port|Slice|IOLOGIC' "$rpt" |
        grep -iE '[0-9]+/' | sed 's/^/  /'
fi

# Timing. This is the number that says whether the clock target is real; the
# simulation and cosimulation say nothing about it.
#
# From project_tr_content.html, NOT project.tr.html -- the latter is only a
# frameset, so the pattern that used to be matched against it never matched
# anything and every build silently reported no timing at all.
tim="$WORK/impl/pnr/project_tr_content.html"
if [ -f "$tim" ]; then
    python - "$tim" <<'PYEND' || true
import html, re, sys

t = open(sys.argv[1], encoding='utf-8', errors='replace').read()
rows = []
for r in re.findall(r'<tr.*?</tr>', t, re.S):
    cells = [html.unescape(re.sub('<[^>]*>', '', c)).strip().replace(' ', '')
             for c in re.findall(r'<t[dh].*?</t[dh]>', r, re.S)]
    rows.append([c for c in cells if c])

# Per-clock Fmax against its constraint, then how much did not close.
show = False
for cells in rows:
    line = ' | '.join(cells)
    if 'Constraint' in line and 'Actual Fmax' in line:
        show = True
        continue
    if show:
        if len(cells) >= 4 and '(MHz)' in cells[2]:
            want = float(cells[2].split('(')[0])
            got = float(cells[3].split('(')[0])
            flag = '  <-- VIOLATED' if got < want else ''
            print(f"  {cells[1]:<12} {got:>9.3f} MHz against {want:.3f}, "
                  f"{cells[4]} levels{flag}")
        else:
            show = False
for cells in rows:
    if len(cells) == 2 and 'Violated Endpoints' in cells[0]:
        print(f"  {cells[0]}: {cells[1]}")
PYEND
fi
echo "  full log: $WORK/build.log"
