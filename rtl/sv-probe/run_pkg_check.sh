#!/usr/bin/env bash
# Synthesize the *generated* k2g_pkg.sv with GowinSynthesis.
#
# `cargo test` proves the package is current with respect to insns.rs; this
# proves the toolchain actually accepts it. Both matter -- a package that is
# perfectly in sync but that Gowin rejects is no use.
#
# Usage:  bash run_pkg_check.sh

set -u

GW_SH="${GW_SH:-C:/Gowin/Gowin_V1.9.12.02_SP2_x64/IDE/bin/gw_sh.exe}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Fail clearly if this is WSL rather than Git Bash; the Windows toolchains
# are not reachable from WSL and the resulting error is misleading.
. "$HERE/../sim/shell_check.sh"
k2g_require_windows_shell || exit 1
RTL="$(cd "$HERE/.." && pwd)"
WORK="$HERE/out/pkg_check"

[ -x "$GW_SH" ] || { echo "gw_sh not found at $GW_SH" >&2; exit 1; }
[ -f "$RTL/k2g_pkg.sv" ] || {
    echo "$RTL/k2g_pkg.sv missing -- run: cd emu && cargo run --bin gen_defs" >&2
    exit 1
}

rm -rf "$WORK"; mkdir -p "$WORK"
cp "$RTL/k2g_pkg.sv" "$HERE/pkg_probe.sv" "$WORK/"

cat > "$WORK/syn.tcl" <<'EOF'
set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5
add_file -type verilog {k2g_pkg.sv}
add_file -type verilog {pkg_probe.sv}
set_option -top_module probe
set_option -verilog_std sysv2017
set_option -print_all_synthesis_warning 1
run syn
EOF

( cd "$WORK" && "$GW_SH" syn.tcl ) > "$WORK/log.txt" 2>&1
rc=$?

if grep -qiE '^ERROR|\bERROR \(' "$WORK/log.txt"; then
    echo "FAIL: GowinSynthesis rejected the generated package"
    grep -iE '^ERROR|\bERROR \(' "$WORK/log.txt" | head -5
    exit 1
fi
if [ $rc -ne 0 ]; then
    echo "FAIL: gw_sh exited $rc"
    tail -15 "$WORK/log.txt"
    exit 1
fi

vg="$WORK/impl/gwsynthesis/project.vg"
if [ ! -f "$vg" ]; then
    echo "FAIL: no netlist produced"
    exit 1
fi

# Guard against a vacuous pass: decode logic must actually appear.
luts=$(grep -cE '^  LUT[0-9]' "$vg")
if [ "$luts" -lt 3 ]; then
    echo "FAIL: netlist has only $luts LUTs -- the design was optimized away,"
    echo "      so this run proves nothing about the package."
    exit 1
fi

echo "PASS: generated package synthesizes ($luts LUTs of decode logic)"
grep -icE 'WARN' "$WORK/log.txt" | xargs -I{} echo "      {} warning(s); full log: $WORK/log.txt"
