#!/usr/bin/env bash
# Simulate the Gowin PSRAM controller on its own.
#
#   bash rtl/sim/psram.sh
#
# Separate from run.sh because it needs two things nothing else in this
# repository does: the IP's post-place-and-route model, and Gowin's primitive
# library. It also cannot be a pass/fail gate -- there is no model of the
# memory device, so calibration cannot complete. See rtl/tb/tb_psram.sv for
# what it does answer.

set -u

QUESTA="${QUESTA:-E:/Quartus/questa_fse/win64}"
GOWIN="${GOWIN:-/c/Gowin/Gowin_V1.9.12.02_SP2_x64}"
HERE="$(cd "$(dirname "$0")" && pwd)"

. "$HERE/shell_check.sh"
k2g_require_windows_shell || exit 1

ROOT="$(cd "$HERE/../.." && pwd)"
RTL="$(cd "$HERE/.." && pwd)"
WORK="$HERE/work/psram"

IP="$ROOT/K2606/src/psram_memory_interface_hs/psram_memory_interface_hs.vo"
[ -f "$IP" ] || { echo "IP model not found: $IP" >&2; exit 1; }

# prim_sim.v is shipped several times over inside the IDE; any copy will do.
PRIM="$(find "$GOWIN/IDE" -name prim_sim.v 2>/dev/null | head -1)"
[ -n "$PRIM" ] || { echo "prim_sim.v not found under $GOWIN/IDE" >&2; exit 1; }
echo "primitives: $PRIM"

mkdir -p "$WORK"
cd "$WORK" || exit 1
rm -rf work
"$QUESTA/vlib.exe" work > /dev/null || exit 1

# The IP model and the primitive library are plain Verilog; only the testbench
# is SystemVerilog.
if ! "$QUESTA/vlog.exe" -quiet "$PRIM" "$IP" > vlog.log 2>&1 \
   || ! "$QUESTA/vlog.exe" -sv -quiet "$RTL/tb/tb_psram.sv" >> vlog.log 2>&1; then
    echo "COMPILE FAILED"
    grep -E '^\*\* (Error|Fatal)' vlog.log | head -20
    exit 1
fi
if grep -qE '^\*\* Error' vlog.log; then
    echo "COMPILE FAILED"
    grep -E '^\*\* Error' vlog.log | head -20
    exit 1
fi

# The Starter Edition warns off designs over 5000 instances and then refuses to
# elaborate; a gate-level IP model plus the primitive library is about 18000.
# The message is suppressible, but only by its own id: `-suppress 14408` is
# accepted and silently does nothing, and `-voptargs=-suppress=...` is rejected
# outright. It has to be `-suppress vopt-14408`.
"$QUESTA/vsim.exe" -c -quiet -suppress vopt-14408 \
    -do "onerror {quit -code 1}; run -all; quit -f" \
    tb_psram 2>&1 | sed -e 's/^# //'
