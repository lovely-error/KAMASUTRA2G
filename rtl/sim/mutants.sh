#!/usr/bin/env bash
# Negative tests: break the design on purpose, and require the testbenches to
# notice.
#
#   bash rtl/sim/mutants.sh              # all of them
#   bash rtl/sim/mutants.sh rule-3       # just the ones whose name matches
#
# WHY THIS EXISTS. A testbench that passes tells you nothing on its own -- it
# might be checking something that cannot fail. Every guard in this repository
# is supposed to have been watched failing before it was trusted, which is what
# the README claims about the four drift guards in emu/. Those demonstrations
# used to live in whoever's terminal ran them. These ones live here.
#
# Each entry below is a defect that a specific testbench is supposed to catch,
# stated as an exact source substitution. The runner applies it to a THROWAWAY
# COPY of rtl/ and never touches the real tree: the sim scripts take a
# K2G_RTL override for exactly this.
#
# Three outcomes are distinguished, and the third is the point:
#
#   ok        the test behaved as the entry predicts
#   MISSED    the mutant compiled, ran, and the test did not notice -- either
#             the defect is real and untested, or the test is vacuous
#   STALE     the pattern no longer appears exactly once in the file, so the
#             mutation could not be applied at all
#
# STALE is an error rather than a skip. A mutation that silently stops applying
# is a guard that has quietly stopped guarding, which is the exact failure mode
# this script exists to prevent -- so it must be loud.
#
# A mutant that fails to COMPILE is also an error. It proves the mutation was
# malformed, not that anything caught a defect.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/shell_check.sh"
k2g_require_windows_shell || exit 1

ROOT="$(cd "$HERE/../.." && pwd)"
RTL="$(cd "$HERE/.." && pwd)"
SCRATCH="$HERE/work/mutants"

FILTER="${1:-}"

# ---- the mutants -------------------------------------------------------
#
# Fields, separated by the record marker below:
#   name | file (relative to rtl/) | exact old text | replacement | expectation
#
# `expectation` is `detect` (the run must fail) or `survive` (the run must
# still pass -- used where the point is that ANOTHER configuration catches it).

read -r -d '' MUTANTS <<'EOF'
rule-3-ready-path
k2g_chan.sv
  assign up.ready   = !skid_full;
  assign up.ready   = !out_valid || down.ready;
detect
tb_chan
run
--
single-entry-buffer
k2g_chan.sv
  assign up.ready   = !skid_full;
  assign up.ready   = !out_valid;
detect
tb_chan
run
--
flush-ignored
k2g_chan.sv
    end else if (flush) begin
    end else if (1'b0) begin
detect
tb_chan
run
--
load-assumes-one-cycle-at-zero-latency
k2g_core.sv
      if (load_done) mem_pending <= 1'b0;
      mem_pending <= 1'b0;
survive
-
cosim0
--
load-assumes-one-cycle-under-latency
k2g_core.sv
      if (load_done) mem_pending <= 1'b0;
      mem_pending <= 1'b0;
detect
-
cosim40
--
abandoned-fetch-not-dropped
k2g_core.sv
  assign f2d_in.valid = if_answer && (drop == 2'd0);
  assign f2d_in.valid = if_answer;
detect
-
icosim
EOF

# ---- runner ------------------------------------------------------------

pass=0
bad=0

apply_mutation() {
    local file="$1" old="$2" new="$3"
    local path="$SCRATCH/rtl/$file"
    local content hits

    [ -f "$path" ] || { echo "no such file: rtl/$file"; return 2; }

    hits=$(grep -F -c -- "$old" "$path" 2>/dev/null || true)
    [ "$hits" = "1" ] || { echo "pattern found $hits times, want 1"; return 2; }

    content="$(cat "$path")"
    printf '%s\n' "${content//"$old"/"$new"}" > "$path"
    return 0
}

# Fresh copy of just the sources; the out/ trees under board/ and sv-probe/
# hold bitstreams and are large.
reset_scratch() {
    rm -rf "$SCRATCH"
    mkdir -p "$SCRATCH/rtl/sim"
    cp "$RTL"/*.sv "$RTL"/*.svh "$SCRATCH/rtl/" 2>/dev/null
    cp -r "$RTL/tb" "$SCRATCH/rtl/tb"
    cp "$RTL"/sim/*.sh "$SCRATCH/rtl/sim/"
    mkdir -p "$SCRATCH/rtl/board"
    cp "$RTL"/board/k2g_uart.sv "$SCRATCH/rtl/board/" 2>/dev/null
}

run_case() {
    local runner="$1" tb="$2" log="$3"
    case "$runner" in
        run)     K2G_RTL="$SCRATCH/rtl" bash "$HERE/run.sh" "$tb" > "$log" 2>&1 ;;
        cosim0)  K2G_RTL="$SCRATCH/rtl" LATENCY=0  bash "$HERE/cosim.sh" 1 > "$log" 2>&1 ;;
        cosim40) K2G_RTL="$SCRATCH/rtl" LATENCY=40 bash "$HERE/cosim.sh" 1 > "$log" 2>&1 ;;
        icosim)  K2G_RTL="$SCRATCH/rtl" ILATENCY=25 bash "$HERE/cosim.sh" 1 > "$log" 2>&1 ;;
    esac
}

printf '%-46s %-8s %s\n' "mutant" "expect" "result"
printf '%-46s %-8s %s\n' "----------------------------------------------" "--------" "------"

name=""; file=""; old=""; new=""; expect=""; tb=""; runner=""; field=0

process_one() {
    local log="$SCRATCH/$name.log"
    local msg rc

    reset_scratch
    if ! msg=$(apply_mutation "$file" "$old" "$new"); then
        printf '%-46s %-8s %s\n' "$name" "$expect" "STALE ($msg)"
        bad=$((bad + 1))
        return
    fi

    run_case "$runner" "$tb" "$log"
    rc=$?

    if grep -q "COMPILE FAILED" "$log"; then
        printf '%-46s %-8s %s\n' "$name" "$expect" "ERROR (mutant does not compile)"
        bad=$((bad + 1))
        return
    fi

    if [ "$expect" = "detect" ]; then
        if [ $rc -ne 0 ]; then
            printf '%-46s %-8s %s\n' "$name" "$expect" "caught      ok"
            pass=$((pass + 1))
        else
            printf '%-46s %-8s %s\n' "$name" "$expect" "MISSED"
            bad=$((bad + 1))
        fi
    else
        if [ $rc -eq 0 ]; then
            printf '%-46s %-8s %s\n' "$name" "$expect" "survived    ok"
            pass=$((pass + 1))
        else
            printf '%-46s %-8s %s\n' "$name" "$expect" "UNEXPECTEDLY CAUGHT"
            bad=$((bad + 1))
        fi
    fi
}

while IFS= read -r line; do
    if [ "$line" = "--" ]; then
        [ -z "$FILTER" ] || case "$name" in *"$FILTER"*) ;; *) field=0; continue ;; esac
        process_one
        field=0
        continue
    fi
    case $field in
        0) name="$line" ;;
        1) file="$line" ;;
        2) old="$line" ;;
        3) new="$line" ;;
        4) expect="$line" ;;
        5) tb="$line" ;;
        6) runner="$line" ;;
    esac
    field=$((field + 1))
done <<< "$MUTANTS"

# The heredoc's last record has no trailing marker.
if [ $field -gt 0 ]; then
    if [ -z "$FILTER" ]; then
        process_one
    else
        case "$name" in *"$FILTER"*) process_one ;; esac
    fi
fi

rm -rf "$SCRATCH"

echo
if [ $bad -eq 0 ]; then
    echo "MUTANTS OK -- $pass of $pass behaved as predicted"
    exit 0
fi
echo "MUTANTS FAIL -- $bad of $((pass + bad)) did not"
exit 1
