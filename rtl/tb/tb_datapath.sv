// Directed tests for the ALU, shifter and register file.
//
// The ALU cases mirror `emu/tests/spec_conformance.rs` deliberately: the same
// inputs are pinned on both sides, so a divergence shows up here rather than
// deep in a cosimulation trace.

`include "k2g_types.svh"

module tb_datapath
  import k2g_pkg::*;
  import k2g_types::*;
;

  logic clk = 0;
  always #5 clk = ~clk;

  int checks = 0;
  int errors = 0;

  task automatic check(input string what, input logic ok);
    checks++;
    if (!ok) begin
      errors++;
      $display("TB_FAIL: %s", what);
    end
  endtask

  // ---- ALU ---------------------------------------------------------------
  logic [31:0] a, b;
  logic [2:0]  a_tag, b_tag;
  arith_e      arith_op;
  logic_e      logic_op;
  cmp_e        cmp_op;
  unary_e      unary_op;
  logic [31:0] arith_result, logic_result, unary_result;
  logic        arith_overflow, cmp_result;

  k2g_alu alu (.*);

  // ---- shifter -----------------------------------------------------------
  logic [31:0] value, src;
  logic [4:0]  amount, bm_start, bm_span;
  shift_e      shift_op;
  logic [31:0] shift_result, bext_result, bins_result;

  k2g_shift shifter (.*);

  // ---- register file -----------------------------------------------------
  logic        rst_n = 0;
  logic [4:0]  ra_addr = 0, rb_addr = 0, rc_addr = 0, w_addr = 0;
  logic [31:0] ra_value, rb_value, rc_value, w_value = 0;
  logic        rc_overflow, rc_flag;
  logic [2:0]  ra_tag, rb_tag, rc_tag, w_tag = RDT_U32;
  logic        ra_overflow, rb_overflow, ra_flag, rb_flag;
  logic        we_value = 0, we_tag = 0, we_overflow = 0, we_flag = 0;
  logic        w_overflow = 0, w_flag = 0;

  k2g_regfile rf (.*);

  task automatic rf_write(input logic [4:0] addr, input logic [31:0] v,
                          input logic [2:0] t);
    @(negedge clk);
    w_addr = addr; w_value = v; w_tag = t;
    we_value = 1; we_tag = 1;
    @(posedge clk);
    @(negedge clk);
    we_value = 0; we_tag = 0;
  endtask

  initial begin
    // ---- arithmetic: `overflow` means "did not fit" (spec 5.4) ----------
    arith_op = ARITH_ADD;
    a = 32'd5; b = 32'd3; #1;
    check("5+3", arith_result == 32'd8 && !arith_overflow);
    a = 32'hFFFF_FFFF; b = 32'd1; #1;
    check("0xFFFFFFFF+1 carries", arith_result == 32'd0 && arith_overflow);

    arith_op = ARITH_SUB;
    // The case the emulator's original formulation got wrong: subtracting
    // zero must not set the flag.
    a = 32'd7; b = 32'd0; #1;
    check("7-0 no borrow", arith_result == 32'd7 && !arith_overflow);
    a = 32'd5; b = 32'd3; #1;
    check("5-3 no borrow", arith_result == 32'd2 && !arith_overflow);
    a = 32'd10; b = 32'd10; #1;
    check("10-10 no borrow", arith_result == 32'd0 && !arith_overflow);
    a = 32'd3; b = 32'd5; #1;
    check("3-5 borrows", arith_result == 32'hFFFF_FFFE && arith_overflow);
    a = 32'd0; b = 32'd1; #1;
    check("0-1 borrows", arith_overflow);

    // ---- logic ----------------------------------------------------------
    a = 32'hF0F0_F0F0; b = 32'h00FF_00FF;
    logic_op = LOGIC_AND; #1; check("and", logic_result == 32'h00F0_00F0);
    logic_op = LOGIC_OR;  #1; check("or",  logic_result == 32'hF0FF_F0FF);
    logic_op = LOGIC_XOR; #1; check("xor", logic_result == 32'hF00F_F00F);

    // ---- unary ----------------------------------------------------------
    a = 32'd5;
    unary_op = UNARY_NOT; #1; check("not", unary_result == 32'hFFFF_FFFA);
    unary_op = UNARY_NEG; #1; check("neg", unary_result == 32'hFFFF_FFFB);

    // ---- comparison: 33-bit widening by each operand's own tag (5.9) -----
    // Same signedness reduces to the ordinary comparison.
    a = 32'd1; b = 32'd2; a_tag = RDT_U32; b_tag = RDT_U32;
    cmp_op = CMP_LT; #1; check("1 < 2 unsigned", cmp_result);
    cmp_op = CMP_GT; #1; check("1 > 2 unsigned false", !cmp_result);
    cmp_op = CMP_EQ; #1; check("1 == 2 false", !cmp_result);

    a = 32'hFFFF_FFFF; b = 32'd1; a_tag = RDT_S32; b_tag = RDT_S32;
    cmp_op = CMP_LT; #1; check("-1 < 1 signed", cmp_result);

    a = 32'hFFFF_FFFF; b = 32'd1; a_tag = RDT_U32; b_tag = RDT_U32;
    cmp_op = CMP_LT; #1; check("0xFFFFFFFF < 1 unsigned false", !cmp_result);

    // The mixed cases a 32-bit comparator cannot get right.
    a = 32'hFFFF_FFFF; b = 32'd1; a_tag = RDT_S32; b_tag = RDT_U32;
    cmp_op = CMP_LT; #1;
    check("-1 (S32) < 1 (U32)", cmp_result);

    a = 32'd3; b = 32'hFFFF_FFFF; a_tag = RDT_S32; b_tag = RDT_U32;
    cmp_op = CMP_LT; #1;
    check("3 (S32) < 4294967295 (U32)", cmp_result);

    a = 32'd1; b = 32'hFFFF_FFFF; a_tag = RDT_U32; b_tag = RDT_S32;
    cmp_op = CMP_GT; #1;
    check("1 (U32) > -1 (S32)", cmp_result);

    // Equality is by value, not bit pattern: identical bits under different
    // signedness denote different numbers (spec 5.9).
    a = 32'hFFFF_FFFF; b = 32'hFFFF_FFFF; a_tag = RDT_U32; b_tag = RDT_S32;
    cmp_op = CMP_EQ; #1;
    check("same bits, different signedness, not equal", !cmp_result);
    a_tag = RDT_S32; #1;
    check("same bits, same signedness, equal", cmp_result);

    // ---- shifter --------------------------------------------------------
    value = 32'h0000_00FF; amount = 5'd4;
    shift_op = SHIFT_LL; #1; check("shl",  shift_result == 32'h0000_0FF0);
    shift_op = SHIFT_LR; #1; check("shr",  shift_result == 32'h0000_000F);
    shift_op = SHIFT_AR; #1; check("shra non-negative", shift_result == 32'h0000_000F);

    // A sign-filled value keeps its sign; this is what makes SHRA correct for
    // signed tags without a special case.
    value = 32'hFFFF_FFFF; shift_op = SHIFT_AR; #1;
    check("shra of -1 stays -1", shift_result == 32'hFFFF_FFFF);
    shift_op = SHIFT_LR; #1;
    check("shr of -1 is logical", shift_result == 32'h0FFF_FFFF);

    // ---- bit fields -----------------------------------------------------
    // Extract reads `src` (the arg2 register). `value` is set to something
    // different on purpose: reading the wrong operand is exactly the bug this
    // test previously failed to catch.
    src = 32'h0000_ABCD; value = 32'hDEAD_BEEF;
    bm_start = 5'd4; bm_span = 5'd8; #1;
    check("bext reads the source operand", bext_result == 32'h0000_00BC);

    value = 32'hFFFF_FFFF; src = 32'd0; bm_start = 5'd4; bm_span = 5'd4; #1;
    check("bins clears a field", bins_result == 32'hFFFF_FF0F);

    value = 32'd0; src = 32'h0000_0007; bm_start = 5'd4; bm_span = 5'd3; #1;
    check("bins sets a field", bins_result == 32'h0000_0070);

    // Span 0 is a defined no-op for insert (spec 5.8).
    value = 32'hDEAD_BEEF; src = 32'hFFFF_FFFF; bm_start = 5'd0; bm_span = 5'd0; #1;
    check("bins span 0 is a no-op", bins_result == 32'hDEAD_BEEF);

    // Only the low `span` bits of the source are taken.
    value = 32'd0; src = 32'hFFFF_FFFF; bm_start = 5'd8; bm_span = 5'd4; #1;
    check("bins masks the source", bins_result == 32'h0000_0F00);

    // ---- register file --------------------------------------------------
    @(negedge clk); rst_n = 1;
    @(posedge clk);

    ra_addr = 5'd3; @(negedge clk); #1;
    check("reset value", ra_value == 32'd0);
    check("reset tag",   ra_tag == RDT_U32);

    rf_write(5'd3, 32'hCAFE_BABE, RDT_S16);
    ra_addr = 5'd3; @(negedge clk); #1;
    check("write then read value", ra_value == 32'hCAFE_BABE);
    check("write then read tag",   ra_tag == RDT_S16);

    // Two ports read independently.
    rf_write(5'd7, 32'd42, RDT_U8);
    ra_addr = 5'd3; rb_addr = 5'd7; @(negedge clk); #1;
    check("port A", ra_value == 32'hCAFE_BABE);
    check("port B", rb_value == 32'd42);
    check("port B tag", rb_tag == RDT_U8);

    // Reads are read-before-write: a read in the same cycle as a write sees
    // the OLD value, and the write lands at the edge.
    rf_write(5'd9, 32'hAAAA_0000, RDT_U32);
    @(posedge clk);
    ra_addr = 5'd9;
    w_addr = 5'd9; w_value = 32'h1234_5678; we_value = 1;
    @(negedge clk); #1;
    check("read sees the old value during a write", ra_value == 32'hAAAA_0000);
    @(posedge clk); @(negedge clk); we_value = 0;
    #1; check("write landed on the edge", ra_value == 32'h1234_5678);

    // Per-field enables: a comparison writes only flag_bit, an arithmetic op
    // only overflow. This is why the array is flops rather than RAM.
    rf_write(5'd11, 32'hAAAA_AAAA, RDT_U32);
    @(negedge clk);
    w_addr = 5'd11; w_flag = 1; we_flag = 1;
    @(posedge clk); @(negedge clk); we_flag = 0;
    ra_addr = 5'd11; @(negedge clk); #1;
    check("flag written alone",   ra_flag);
    check("value untouched",      ra_value == 32'hAAAA_AAAA);
    check("tag untouched",        ra_tag == RDT_U32);
    check("overflow untouched",   !ra_overflow);

    @(negedge clk);
    w_addr = 5'd11; w_overflow = 1; we_overflow = 1;
    @(posedge clk); @(negedge clk); we_overflow = 0;
    ra_addr = 5'd11; @(negedge clk); #1;
    check("overflow written alone", ra_overflow);
    check("flag still set",         ra_flag);
    check("value still untouched",  ra_value == 32'hAAAA_AAAA);

    // Reset leaves tags defined even though the value array has no reset --
    // an undefined tag would be observable, since it decides store width and
    // comparison signedness.
    ra_addr = 5'd20; @(negedge clk); #1;
    check("unwritten register has a defined tag", ra_tag == RDT_U32);
    check("unwritten register has clear flags", !ra_flag && !ra_overflow);

    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("TB_PASS tb_datapath");
    else             $display("TB_FAIL tb_datapath: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("TB_FAIL tb_datapath: timeout");
    $finish;
  end

endmodule
