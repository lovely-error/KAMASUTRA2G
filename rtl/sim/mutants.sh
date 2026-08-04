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
cosim40nc
--
abandoned-fetch-not-dropped
k2g_core.sv
  assign f2d_in.valid = if_answer && (drop == 3'd0);
  assign f2d_in.valid = if_answer;
detect
-
icosim
--
csp-side-effect-while-held
k2g_core.sv
                            !mem_pending && !mulw_pending &&
                            1'b1 &&
detect
-
cosim40nc
--
no-value-forwarding
k2g_core.sv
  wire logic [31:0] xa_value = (ma && we_value)    ? w_value    : ra_value;
  wire logic [31:0] xa_value = ra_value;
detect
-
cosim0
--
no-tag-forwarding
k2g_core.sv
  wire logic [2:0]  xb_tag   = (mb && we_tag)      ? w_tag      : rb_tag;
  wire logic [2:0]  xb_tag   = rb_tag;
detect
-
cosim0
--
core-f32-operand-not-checked
k2g_core.sv
  wire logic f32_a    = reads_a && (xa_tag == RDT_F32);
  wire logic f32_a    = 1'b0;
detect
f32_operand
cosim1
--
core-f32-predicate-not-checked
k2g_core.sv
  wire logic f32_cond = (uop.cond != CCK_NONE) && (xc_tag == RDT_F32);
  wire logic f32_cond = 1'b0;
detect
f32_predicate
cosim1
--
core-f32-csp-write-escapes
k2g_core.sv
  wire logic csp_req      = uop_valid && cond_met && !halted_r && !f32_any &&
  wire logic csp_req      = uop_valid && cond_met && !halted_r &&
detect
f32_csp
cosim1
--
core-f32-store-reaches-memory
k2g_core.sv
                          !misaligned && !out_of_range && !halted_r && !f32_any &&
                          !misaligned && !out_of_range && !halted_r &&
detect
f32_store
cosim1
--
core-store-never-written
k2g_core.sv
  assign dbus.req.we    = is_store ? store_we : 4'b0000;
  assign dbus.req.we    = 4'b0000;
detect
hazard
cosim1
--
core-misaligned-not-detected
k2g_core.sv
      end else if ((is_load || is_store) && misaligned) begin
      end else if (1'b0) begin
detect
fault_access
cosim1
--
core-out-of-range-not-detected
k2g_core.sv
      end else if ((is_load || is_store) && out_of_range) begin
      end else if (1'b0) begin
detect
fault_range
cosim1
--
core-bad-port-not-detected
k2g_core.sv
      end else if (csp_bad_port) begin
      end else if (1'b0) begin
detect
fault_port
cosim1
--
core-odd-jump-target-accepted
k2g_core.sv
      end else if ((uop.kind == UOP_PREP_JUMP) && jump_target[0]) begin
      end else if (1'b0) begin
detect
fault_fetch
cosim1
--
decode-fault-info-dropped
k2g_core.sv
        detect_info  = uop.imm;
        detect_info  = 32'd0;
detect
fault_prefix
cosim1
--
cdc-binary-not-gray-pointer
k2g_cdc_fifo.sv
  assign wgray_next = to_gray(wbin_next);
  assign wgray_next = wbin_next;
detect
tb_cdc_fifo
run
--
psram-write-beat-select
k2g_psram.sv
  wire logic [4:0] mask_lo = {beat[3:0], 1'b0};
  wire logic [4:0] mask_lo = 5'd0;
detect
tb_psram_adapter
run
--
psram-write-odd-words-masked-off
k2g_psram.sv
    data_mask[7:4] = in_win_hi ? ~p_we : 4'hF;
    data_mask[7:4] = 4'hF;
detect
tb_psram_adapter
run
--
psram-write-data-not-walked
k2g_psram.sv
  wire logic [3:0] lb_ridx = (state == S_DRAIN) ? fill[4:1] : beat[3:0];
  wire logic [3:0] lb_ridx = (state == S_DRAIN) ? fill[4:1] : 4'd0;
detect
tb_psram_adapter
run
--
psram-read-half-select
k2g_psram.sv
          lbuf_hi[beat[3:0]] <= rd_data[63:32];
          lbuf_hi[beat[3:0]] <= rd_data[31:0];
detect
tb_psram_adapter
run
--
fetch-halfword-select
k2g_core.sv
  wire logic [15:0] ans_cp   = ans_addr[1] ? ibus.rsp_data[31:16]
  wire logic [15:0] ans_cp   = ans_addr[1] ? ibus.rsp_data[15:0]
detect
-
cosim0
--
psram-burst-read-window
k2g_psram.sv
            left  <= p_len + 5'd1;
            left  <= 5'd1;
detect
tb_psram_adapter
run
--
psram-burst-write-window
k2g_psram.sv
                         (mask_lo >= p_off) && ((mask_lo - p_off) <= p_len);
                         (mask_lo >= p_off) && ((mask_lo - p_off) <= 5'd0);
detect
tb_psram_adapter
run
--
psram-burst-arbiter-not-held
k2g_psram.sv
  wire logic pick_d = wb_active ?  wb_src : rr_d;
  wire logic pick_d = rr_d;
detect
tb_psram_adapter
run
--
psram-drain-ignores-full
k2g_psram.sv
  wire logic drain_go = (state == S_DRAIN) && !rspf_wfull;
  wire logic drain_go = (state == S_DRAIN);
detect
tb_psram_adapter
run
--
psram-response-routing
k2g_psram.sv
      irsp_v <= rspf_pop && !rsp_out.src;
      irsp_v <= rspf_pop;
detect
tb_psram_adapter
run
--
psram-command-interval-ignored
k2g_psram.sv
  localparam logic [5:0] TCMD = 6'd32;
  localparam logic [5:0] TCMD = 6'd2;
detect
tb_psram_adapter
run
--
psram-command-before-calibration
k2g_psram.sv
                      && init_calib
                      && 1'b1
detect
tb_psram_adapter
run
--
icache-tag-not-checked
k2g_icache.sv
  wire logic hit = up.req_valid && valid[req_idx] && (tags[req_idx] == req_tag);
  wire logic hit = up.req_valid && valid[req_idx];
detect
tb_icache
run
--
icache-valid-not-checked
k2g_icache.sv
  wire logic hit = up.req_valid && valid[req_idx] && (tags[req_idx] == req_tag);
  wire logic hit = up.req_valid && (tags[req_idx] == req_tag);
detect
tb_icache
run
--
icache-refill-stops-early
k2g_icache.sv
          if (fill_cnt == 5'(WPL - 1)) begin
          if (fill_cnt == 5'd0) begin
detect
tb_icache
run
--
icache-refill-all-one-word
k2g_icache.sv
  wire logic [31:0] fill_addr = fill_base | {25'd0, fill_cnt, 2'b00};
  wire logic [31:0] fill_addr = fill_base;
detect
tb_icache
run
--
icache-fetches-one-word-not-a-line
k2g_icache.sv
  assign down.req.len   = 5'(WPL - 1);
  assign down.req.len   = 5'd0;
detect
tb_icache
run
--
icache-serves-stale-lines
k2g_icache.sv
  wire logic hit = up.req_valid && valid[req_idx] && (tags[req_idx] == req_tag);
  wire logic hit = up.req_valid && valid[req_idx] && (tags[req_idx] != req_tag);
detect
-
cosim0
--
dcache-dirty-line-not-written-back
k2g_dcache.sv
          if (valid[req_idx] && dirty[req_idx]) begin
          if (1'b0) begin
detect
tb_dcache
run
--
dcache-store-does-not-dirty
k2g_dcache.sv
      if (take && is_store) dirty[req_idx] <= 1'b1;
      if (take && is_store) dirty[req_idx] <= 1'b0;
detect
tb_dcache
run
--
dcache-writeback-to-the-new-address
k2g_dcache.sv
          wb_base <= {{(32 - ADDR_W){1'b0}}, tags[req_idx], req_idx,
          wb_base <= {{(32 - ADDR_W){1'b0}}, req_tag, req_idx,
detect
tb_dcache
run
--
dcache-store-ignores-byte-lanes
k2g_dcache.sv
      b_we    = (take && is_store) ? up.req.we : 4'b0000;
      b_we    = (take && is_store) ? 4'b1111 : 4'b0000;
detect
tb_dcache
run
--
dcache-flush-drops-dirty-lines
k2g_dcache.sv
          if (valid[fl_idx] && dirty[fl_idx]) begin
          if (1'b0) begin
detect
tb_dcache
run
--
dcache-loses-stores-in-cosim
k2g_dcache.sv
      b_we    = (take && is_store) ? up.req.we : 4'b0000;
      b_we    = 4'b0000;
detect
-
cosim0
--
copier-ignores-backpressure
board/k2g_soc.sv
    end else if (booting && cbus.req_ready) begin
    end else if (booting) begin
detect
tb_soc
run
--
bus-mux-ignores-select
k2g_membus_mux.sv
  assign down.req_valid = sel ? up_b.req_valid : up_a.req_valid;
  assign down.req_valid = up_b.req_valid;
detect
tb_soc
run
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
# Questa's `vsim` spawns `vish` and `vsimk`, and they outlive it by a moment.
# On Windows an open handle makes the directory they ran in unremovable, so the
# `rm -rf` below fails while they linger -- and it used to fail QUIETLY, leaving
# the next mutant to run against the previous one's compiled library. Waiting
# for them costs a second and is the difference between that and a clean tree.
wait_for_questa_exit() {
    local i
    for i in $(seq 1 40); do
        ps -W 2>/dev/null | grep -qiE 'vsim|vish|vsimk' || return 0
        sleep 0.25
    done
    return 1
}

reset_scratch() {
    wait_for_questa_exit || true
    local i
    for i in 1 2 3 4 5; do
        rm -rf "$SCRATCH" 2>/dev/null
        [ -e "$SCRATCH" ] || break
        sleep 1
    done
    # Fatal rather than a warning. A scratch tree that did not clear means the
    # mutation after this one is applied on top of whatever is left, and every
    # verdict from there on is about a design nobody wrote.
    if [ -e "$SCRATCH" ]; then
        echo "cannot clear $SCRATCH -- a simulator still holds it" >&2
        echo "run 'bash rtl/sim/mutants.sh' again once it has exited" >&2
        exit 1
    fi
    mkdir -p "$SCRATCH/rtl/sim"
    cp "$RTL"/*.sv "$RTL"/*.svh "$SCRATCH/rtl/" 2>/dev/null
    cp -r "$RTL/tb" "$SCRATCH/rtl/tb"
    cp "$RTL"/sim/*.sh "$SCRATCH/rtl/sim/"
    mkdir -p "$SCRATCH/rtl/board"
    # The board sources run.sh compiles -- the UART, the PLL, the generated ROM
    # and the SoC itself. Not the other tops, which are pins and LEDs.
    cp "$RTL"/board/*.sv "$RTL"/board/*.svh "$SCRATCH/rtl/board/" 2>/dev/null
}

run_case() {
    local runner="$1" tb="$2" log="$3"
    case "$runner" in
        run)     K2G_RTL="$SCRATCH/rtl" bash "$HERE/run.sh" "$tb" > "$log" 2>&1 ;;
        cosim0)  K2G_RTL="$SCRATCH/rtl" LATENCY=0  bash "$HERE/cosim.sh" 1 > "$log" 2>&1 ;;
        cosim40) K2G_RTL="$SCRATCH/rtl" LATENCY=40 bash "$HERE/cosim.sh" 1 > "$log" 2>&1 ;;
        # WITHOUT THE CACHES. Neither cache ever accepts a request it cannot
        # answer next cycle, so with them in the path the core never sees a
        # slow response and its variable-latency machinery is not exercised at
        # all. These two mutants went MISSED the day the data cache landed.
        cosim40nc) K2G_RTL="$SCRATCH/rtl" NOCACHE=1 LATENCY=40 bash "$HERE/cosim.sh" 1 > "$log" 2>&1 ;;
        icosim)  K2G_RTL="$SCRATCH/rtl" ILATENCY=25 bash "$HERE/cosim.sh" 1 > "$log" 2>&1 ;;
        # One program rather than the whole sweep: the fault guards each have a
        # program written for them, and a full cosim run is 90 seconds against
        # this one's 11. `tb` names the program.
        cosim1)  K2G_RTL="$SCRATCH/rtl" PROGRAMS="$tb" bash "$HERE/cosim.sh" 0 > "$log" 2>&1 ;;
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

    # A run that produced no log did not happen -- the work directory was
    # unusable, or the runner never started. Its exit status still looks like a
    # verdict: non-zero reads as `caught` for a `detect` entry, which is a false
    # PASS in the one script whose whole purpose is to disbelieve passes.
    if [ ! -s "$log" ]; then
        printf '%-46s %-8s %s\n' "$name" "$expect" "ERROR (no log; the test never ran)"
        bad=$((bad + 1))
        return
    fi

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
