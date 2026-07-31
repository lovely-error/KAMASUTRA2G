#!/usr/bin/env bash
# Probe which SystemVerilog constructs GowinSynthesis actually accepts.
#
# SUG550 claims "Supports Verilog/SystemVerilog" but publishes no
# construct-level support matrix, so the only way to know is to measure.
# Results feed docs/gowin-sv-support.md, which sets the RTL coding style.
#
# Usage:  bash run_probe.sh [probe.sv ...]      (default: all p*.sv)

set -u

GW_SH="${GW_SH:-C:/Gowin/Gowin_V1.9.12.02_SP2_x64/IDE/bin/gw_sh.exe}"
DEVICE_NAME="GW1NR-9C"
DEVICE_PN="GW1NR-LV9QN88PC6/I5"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"

[ -x "$GW_SH" ] || { echo "gw_sh not found at $GW_SH" >&2; exit 1; }

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
    files=("$HERE"/p*.sv)
fi

printf '%-28s %-8s %s\n' "PROBE" "RESULT" "DETAIL"
printf '%-28s %-8s %s\n' "----------------------------" "--------" "------------------------------"

for f in "${files[@]}"; do
    name="$(basename "$f" .sv)"
    work="$OUT/$name"
    rm -rf "$work"; mkdir -p "$work"

    # Gowin resolves add_file paths relative to its own working directory and
    # ignores the leading absolute path, so copy the source in and run isolated.
    cp "$f" "$work/"

    cat > "$work/syn.tcl" <<EOF
set_device -name $DEVICE_NAME $DEVICE_PN
add_file -type verilog {$name.sv}
set_option -top_module probe
set_option -verilog_std sysv2017
set_option -print_all_synthesis_warning 1
run syn
EOF

    ( cd "$work" && "$GW_SH" syn.tcl ) > "$work/log.txt" 2>&1
    rc=$?

    # gw_sh can exit 0 even on synthesis failure; trust the log, not just rc.
    if grep -qiE '^ERROR|\bERROR \(' "$work/log.txt"; then
        detail="$(grep -iE '^ERROR|\bERROR \(' "$work/log.txt" | head -1 | cut -c1-70)"
        printf '%-28s %-8s %s\n' "$name" "FAIL" "$detail"
    elif [ $rc -ne 0 ]; then
        printf '%-28s %-8s %s\n' "$name" "FAIL" "gw_sh exit $rc, no ERROR line"
    else
        warn="$(grep -ciE '^WARN|\bWARN \(' "$work/log.txt")"
        printf '%-28s %-8s %s\n' "$name" "PASS" "${warn} warning(s)"
    fi
done

echo
echo "Full logs under: $OUT/<probe>/log.txt"
