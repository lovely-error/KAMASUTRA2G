#!/usr/bin/env bash
# Build a Tang Nano 9K bitstream through the full Gowin flow.
#
#   bash rtl/board/build.sh blink       # stage 1: LEDs only
#   bash rtl/board/build.sh loopback    # stage 2: UART echo, no CPU
#   bash rtl/board/build.sh psram       # stage 3: PLL, PSRAM controller, calibration
#   bash rtl/board/build.sh mon         # stage 4: the host monitor over PSRAM, no CPU
#   bash rtl/board/build.sh soc         # stage 5: the whole machine
#   bash rtl/board/build.sh hdmi        # stage 6: HDMI colour bars, no CPU
#
# Staged deliberately. If the board misbehaves, the stage that fails says which
# layer is at fault: blink means toolchain/pinout/clock, loopback means UART
# pins or baud rate, psram means the memory or its PLL, mon means the host
# protocol or the bus behind it, soc means the CPU or the memory image,
# hdmi means the video PLL, the serializers or the HDMI pinout.
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
    mon)
        # The host monitor over real PSRAM, with NO CORE. First stage in which
        # framing, a baud rate, a clock crossing and 8 MB of memory are in the
        # same design; put all of that straight into `soc` and a board that
        # will not answer could be any of them, plus the CPU and the caches.
        #
        # Sources are named rather than globbed: this stage is deliberately a
        # short list, and a module appearing in it by accident would defeat the
        # point of building it separately.
        TOP="k2g_mon_probe"
        SRC=("$RTL/k2g_pkg.sv" "$RTL/k2g_host_pkg.sv" "$RTL/k2g_types.svh"
             "$RTL/k2g_membus.sv" "$RTL/k2g_cdc_fifo.sv" "$RTL/k2g_psram.sv"
             "$RTL/k2g_mon.sv"
             "$HERE/k2g_uart.sv" "$HERE/k2g_pll.sv" "$HERE/k2g_mon_probe.sv"
             "$ROOT/K2606/src/psram_memory_interface_hs/psram_memory_interface_hs.v")
        ;;
    soc)
        TOP="k2g_soc"
        SRC=("$RTL/k2g_pkg.sv" "$RTL/k2g_host_pkg.sv" "$RTL/k2g_types.svh")
        for f in "$RTL"/k2g_*.sv; do
            case "$(basename "$f")" in
                k2g_pkg.sv|k2g_host_pkg.sv) ;;
                *) SRC+=("$f") ;;
            esac
        done
        # The PLL and the PSRAM controller come with the SoC now: memory is the
        # in-package PSRAM rather than BSRAM, so the same IP the `psram` stage
        # proves is part of the machine.
        SRC+=("$HERE/k2g_uart.sv" "$HERE/k2g_rom.sv" "$HERE/k2g_pll.sv"
              "$HERE/k2g_soc.sv"
              "$ROOT/K2606/src/psram_memory_interface_hs/psram_memory_interface_hs.v")
        ;;
    hdmi)
        # HDMI colour bars with NO CPU, NO PSRAM and NO UART. The video path is
        # four things that can each fail silently -- a PLL whose dividers the
        # part rejects, a CLKDIV that does not divide, a serializer fed the
        # wrong clock, and a differential pair on pins that cannot drive it --
        # and a dark monitor does not say which. This stage contains only
        # those; the TMDS encoding underneath them is already proved by
        # rtl/sim/run.sh tb_tmds.
        #
        # The two pure-logic modules come from rtl/ rather than here, the same
        # split k2g_psram.sv uses: logic that can be simulated lives where the
        # simulator's glob can reach it, and the pin-level primitives live next
        # to the .cst that names their pins.
        TOP="k2g_hdmi_probe"
        SRC=("$RTL/k2g_video_timing.sv" "$RTL/k2g_tmds_encode.sv"
             "$HERE/k2g_hdmi_pll.sv" "$HERE/k2g_hdmi_out.sv"
             "$HERE/k2g_hdmi_probe.sv")
        ;;
    *) echo "unknown stage '$STAGE' (blink | loopback | psram | mon | soc | hdmi)" >&2; exit 1 ;;
esac

rm -rf "$WORK"; mkdir -p "$WORK"
for f in "${SRC[@]}"; do cp "$f" "$WORK/"; done
# Constraints: a stage file REPLACES the shared one, exactly as the .sdc files
# below do. The shared tangnano9k.cst names uart_tx and uart_rx, so every top
# using it must declare those ports even when idle (k2g_blink.sv says so). A
# stage with a different set of pins brings its own file instead.
if [ -f "$HERE/tangnano9k_$STAGE.cst" ]; then
    CST="tangnano9k_$STAGE.cst"
else
    CST="tangnano9k.cst"
fi
cp "$HERE/$CST" "$WORK/"
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
    echo "add_file -type cst {$CST}"
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
# THROUGH A PIPE, NOT A FILE REDIRECT, and the difference is not cosmetic.
# `> file 2>&1` captured NOTHING from gw_sh -- every failing build produced an
# empty log, which is the "silent toolchain failure" docs/bring-up.md tells you
# to bisect blindly. It is not silent: run it in a pipe and it says exactly what
# is wrong. The overflow that this comment was written for reported
#
#   ERROR (RP0006) : The number(8645(...)) of logic in the design exceeds the
#   resource limit(8640) of current device
#
# and cost an hour of bisection that reading it would have cost a minute.
# PIPESTATUS, because `$?` after a pipe is `tee`'s.
set -o pipefail
( cd "$WORK" && "$GW_SH" build.tcl ) 2>&1 | tee "$WORK/build.log"
rc=${PIPESTATUS[0]}
set +o pipefail

# THE BITSTREAM IS THE VERDICT, not gw_sh's exit code and not the log.
#
# Both of the obvious signals lie. `gw_sh` exits 1 on builds that produced a
# perfectly good bitstream, so `rc` alone reports failures that did not happen.
# And it writes its output to the console device rather than to stdout, so
# `> file` captures nothing and `| tee` captures nothing either -- the log is
# empty however this is redirected, which is the "silent toolchain failure"
# docs/bring-up.md tells you to bisect blindly. It is only silent when captured:
# run `gw_sh build.tcl` by hand in the work directory and it says exactly what
# is wrong.
#
# So: a fresh bitstream means success, and its absence means failure. `rc` and
# the log are reported as evidence when there is a failure to explain, never
# used to declare one.
FS="$WORK/impl/pnr/project.fs"
if [ ! -f "$FS" ] || [ "$FS" -ot "$WORK/build.tcl" ]; then
    echo "BUILD FAILED (gw_sh exit $rc)"
    echo "No fresh bitstream. gw_sh's own output is not captured -- to see it:"
    echo "    cd $WORK && \"\$GW_SH\" build.tcl"
    grep -iE '^ERROR|\bERROR \(' "$WORK/build.log" 2>/dev/null | head -12
    exit 1
fi
if grep -qiE '^ERROR|\bERROR \(' "$WORK/build.log" 2>/dev/null; then
    echo "BUILD FAILED"
    grep -iE '^ERROR|\bERROR \(' "$WORK/build.log" | head -12
    exit 1
fi

echo "BUILD OK: $STAGE"
echo "  bitstream: $FS ($(stat -c%s "$FS") bytes)"

# WARNINGS ARE PRINTED ON SUCCESS, and this exists because one of them mattered
# and nobody saw it. `k2g_hdmi_pll.sv` asked for ODIV_SEL = 6; the tool decided
# 6 was not a legal value, substituted 8, built a working bitstream, and said so
# only here:
#
#   WARN (EX0205) : Instance "u_rpll" 's parameter "ODIV_SEL" value invalid,
#   replaced by default value "8"
#
# The part ran at a VCO 252 MHz from the one the source documented, and every
# signal a person actually looks at -- exit status, bitstream, utilization,
# timing -- was green. A parameter the tool silently rewrites is exactly the
# class of defect this whole staged build exists to catch, so the log's own
# report of it goes on the screen.
warns="$(grep -iE '^WARN|WARN \(' "$WORK/build.log" 2>/dev/null)"
if [ -n "$warns" ]; then
    n="$(printf '%s
' "$warns" | wc -l | tr -d ' ')"
    echo "  $n warning(s):"
    printf '%s
' "$warns" | head -12 | sed 's/^/    /'
    [ "$n" -gt 12 ] && echo "    ... $((n - 12)) more in $WORK/build.log"
fi

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
