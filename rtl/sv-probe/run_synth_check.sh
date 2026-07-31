#!/usr/bin/env bash
# Synthesize the K2G RTL with GowinSynthesis and report device utilization.
#
# Simulation proves the design is correct; this proves it fits. The plan's
# budget is a GW1NR-9C: 8640 LUT4, 6480 FF, 26 BSRAM, 20 DSP, with the PSRAM IP
# already claiming 1160 LUT / 666 FF / 4 BSRAM when it is eventually added.
#
#   bash rtl/sv-probe/run_synth_check.sh [top_module]

set -u

GW_SH="${GW_SH:-C:/Gowin/Gowin_V1.9.12.02_SP2_x64/IDE/bin/gw_sh.exe}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/.." && pwd)"
TOP="${1:-k2g_core}"
WORK="$HERE/out/synth_$TOP"

[ -x "$GW_SH" ] || { echo "gw_sh not found at $GW_SH" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
cp "$RTL"/k2g_*.sv "$RTL"/k2g_types.svh "$WORK/" 2>/dev/null

{
    echo "set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5"
    echo "add_file -type verilog {k2g_pkg.sv}"
    for f in "$WORK"/k2g_*.sv; do
        b="$(basename "$f")"
        [ "$b" = "k2g_pkg.sv" ] && continue
        echo "add_file -type verilog {$b}"
    done
    echo "set_option -top_module $TOP"
    echo "set_option -verilog_std sysv2017"
    echo "set_option -include_path {.}"
    echo "run syn"
} > "$WORK/syn.tcl"

( cd "$WORK" && "$GW_SH" syn.tcl ) > "$WORK/log.txt" 2>&1
rc=$?

if grep -qiE '^ERROR|\bERROR \(' "$WORK/log.txt"; then
    echo "SYNTH FAILED ($TOP)"
    grep -iE '^ERROR|\bERROR \(' "$WORK/log.txt" | head -10
    exit 1
fi
if [ $rc -ne 0 ]; then
    echo "SYNTH FAILED ($TOP): gw_sh exit $rc"
    tail -15 "$WORK/log.txt"
    exit 1
fi

vg="$WORK/impl/gwsynthesis/project.vg"
[ -f "$vg" ] || { echo "SYNTH FAILED ($TOP): no netlist"; exit 1; }

echo "SYNTH OK: $TOP"

# Gowin's own resource report is authoritative: it counts ALU cells and DSP
# macros separately from LUTs, which a raw primitive tally in the netlist gets
# wrong. GW1NR-9C budget: 8640 LUT, 6480 REG, 26 BSRAM, 20 DSP.
rpt="$WORK/impl/gwsynthesis/project_syn_resource.html"
if [ -f "$rpt" ]; then
    python - "$rpt" <<'PYEND'
import html, re, sys
t = open(sys.argv[1], encoding='utf-8', errors='replace').read()
rows = re.findall(r'<tr.*?</tr>', t, re.S)
data = []
for r in rows:
    cells = [html.unescape(re.sub('<[^>]*>', '', c)).strip().replace(' ', '')
             for c in re.findall(r'<t[dh].*?</t[dh]>', r, re.S)]
    cells = [c for c in cells if c]
    if len(cells) >= 5:
        data.append(cells)
if len(data) >= 2:
    hdr, top = data[0], data[1]
    name = top[0].split(' (')[0]
    def num(x):
        try: return int(x)
        except ValueError: return 0
    reg, alu, lut, dsp = num(top[1]), num(top[2]), num(top[3]), num(top[4])
    print(f"  module   {name}")
    print(f"  LUT      {lut:>6}  of 8640  ({lut*100//8640}%)")
    print(f"  ALU      {alu:>6}")
    print(f"  REG      {reg:>6}  of 6480  ({reg*100//6480}%)")
    print(f"  DSP      {dsp:>6}  of 20")
PYEND
fi

echo "  primitives:"
grep -oE '^  [A-Z][A-Z0-9_]*' "$vg" | tr -d ' ' | sort | uniq -c | sort -rn |
    head -12 | while read -r n prim; do printf '    %-14s %s
' "$prim" "$n"; done
echo "  full log: $WORK/log.txt"
