// Directed tests for the prefix accumulator.
//
// Every vector is a real encoding taken from the ISA spec, and the checks
// target the reinterpretation cases and the quirks in spec 12 -- the places a
// decoder is most likely to be quietly wrong. The superseded decoder.sv had no
// testbench at all.

`include "k2g_types.svh"

module tb_decode
  import k2g_pkg::*;
  import k2g_types::*;
;

  logic        clk = 0;
  logic        rst_n = 0;
  logic [15:0] cp;
  logic        cp_valid;
  logic        flush = 0;
  logic        hold = 0;
  logic        accept;
  uop_t        uop;
  logic        uop_valid;

  k2g_decode dut (.*);

  always #5 clk = ~clk;

  int checks = 0;
  int errors = 0;

  // Collected result of the most recently completed instruction.
  uop_t last;
  int   last_words;

  task automatic check(input string what, input logic ok);
    checks++;
    if (!ok) begin
      errors++;
      $display("TB_FAIL: %s", what);
    end
  endtask

  // Feeds a sequence of code points and captures the emitted uop.
  //
  // `uop` is combinational and the prefix accumulator clears on the same edge
  // that completes an instruction, so the outputs are sampled while the code
  // point is applied and *before* the clock edge -- which is exactly what a
  // downstream pipeline register captures.
  task automatic feed(input logic [15:0] words [], input string label);
    last_words = 0;
    foreach (words[i]) begin
      @(negedge clk);
      cp       = words[i];
      cp_valid = 1;
      #1;                       // let combinational decode settle
      last_words++;
      if (uop_valid) begin
        last = uop;
        @(posedge clk);         // retire it
        cp_valid = 0;
        if (i != words.size() - 1) begin
          $display("TB_FAIL: %s completed after %0d of %0d code points",
                   label, last_words, words.size());
          errors++;
        end
        return;
      end
      @(posedge clk);
    end
    cp_valid = 0;
    $display("TB_FAIL: %s never completed", label);
    errors++;
  endtask

  // ---- encoding helpers, mirroring emu/src/insns.rs ----------------------
  function automatic logic [15:0] p655(input logic [5:0] lb,
                                       input logic [4:0] a1,
                                       input logic [4:0] a2);
    return {lb, a1, a2};
  endfunction

  function automatic logic [15:0] p610(input logic [5:0] lb,
                                       input logic [9:0] imm);
    return {lb, imm};
  endfunction

  initial begin
    cp = '0; cp_valid = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ---- plain instructions -------------------------------------------
    feed('{p655(LB_CPY, 5'd3, 5'd7)}, "cpy");
    check("cpy kind", last.kind == UOP_COPY);
    check("cpy dst",  last.dst == 5'd3);
    check("cpy src",  last.src == 5'd7);
    check("cpy size", last.size_bytes == 32'd2);

    feed('{p655(LB_ADD, 5'd1, 5'd2)}, "add rr");
    check("add kind",    last.kind == UOP_ARITH);
    check("add op",      last.arith_op == ARITH_ADD);
    check("add reg src", last.use_imm == 1'b0);

    feed('{p655(LB_EP1, EP2_HALT, EP1_EP2)}, "halt");
    check("halt", last.kind == UOP_HALT);

    feed('{p655(LB_EP1, EP2_TC, EP1_EP2)}, "tc");
    check("tc", last.kind == UOP_PERFORM_JUMP);

    // ---- immediate combining (spec 4) ----------------------------------
    // ALU form: (sext10(prefix) << 5) | arg2
    feed('{p610(LB_XI, 10'h3FF), p655(LB_ADD, 5'd1, 5'd31)}, "add ri -1");
    check("add ri kind", last.kind == UOP_ARITH);
    check("add ri uses imm", last.use_imm);
    check("add ri value", last.imm == 32'hFFFF_FFFF);
    check("add ri size", last.size_bytes == 32'd4);

    // Load/store form: the prefix is the raw offset, arg2 stays a register.
    feed('{p610(LB_XI, 10'd8), p655(LB_LD32, 5'd2, 5'd1)}, "ld32 +8");
    check("ld kind",   last.kind == UOP_LOAD);
    check("ld offset", last.imm == 32'd8);
    check("ld base",   last.src == 5'd1);
    check("ld dst",    last.dst == 5'd2);

    // Immediate shifts ignore XI entirely.
    feed('{p610(LB_XI, 10'd7), p655(LB_SHLI, 5'd1, 5'd4)}, "shli");
    check("shli kind", last.kind == UOP_SHIFT);
    check("shli amount ignores XI", last.imm == 32'd4);

    // ---- XIZEXT must not sign-extend (spec 4.1) -------------------------
    // XI with a negative displacement.
    feed('{p610(LB_XI, 10'h3FF), p610(LB_DISPI, 10'h3FF)}, "dispi xi -1");
    check("dispi xi kind", last.kind == UOP_PREP_JUMP);
    check("dispi xi negative", last.imm == 32'hFFFF_FFFE);

    // XIZEXT with the same bit pattern must stay positive. This is the case
    // that previously sign-extended regardless of the prefix.
    feed('{p610(LB_XIZEXT, 10'd512), p610(LB_DISPI, 10'd0)}, "dispi xizext");
    check("dispi xizext positive", last.imm == 32'd1048576);

    // ---- reinterpretation (spec 3.2) ------------------------------------
    // BMX + SHL is an extract, not a shift.
    feed('{p655(LB_BMX_0_0, 5'd4, 5'd8), p655(LB_SHL, 5'd1, 5'd2)}, "bext");
    check("bext kind",  last.kind == UOP_BEXT);
    check("bext start", last.bm_start == 5'd4);
    check("bext span",  last.bm_span == 5'd8);

    // BMX + SHR is an insert.
    feed('{p655(LB_BMX_0_0, 5'd4, 5'd8), p655(LB_SHR, 5'd1, 5'd2)}, "bins");
    check("bins kind", last.kind == UOP_BINS);

    // BMX + SHRA has no meaning.
    feed('{p655(LB_BMX_0_0, 5'd4, 5'd8), p655(LB_SHRA, 5'd1, 5'd2)}, "bmx+shra");
    check("bmx+shra faults", last.kind == UOP_FAULT &&
                             last.fault == FAULT_ILLEGAL_PREFIX_COMBO);

    // A zero span makes an extract meaningless, but an insert is a defined
    // no-op -- the asymmetry is deliberate (spec 5.8).
    feed('{p655(LB_BMX_0_0, 5'd0, 5'd0), p655(LB_SHL, 5'd1, 5'd2)}, "bext span0");
    check("bext span 0 faults", last.kind == UOP_FAULT &&
                                last.fault == FAULT_BEXT_ZERO_SPAN);
    feed('{p655(LB_BMX_0_0, 5'd0, 5'd0), p655(LB_SHR, 5'd1, 5'd2)}, "bins span0");
    check("bins span 0 is legal", last.kind == UOP_BINS);

    // UTO + MUL is the widening multiply; UTO + DISPI is jump-and-link.
    feed('{p655(LB_EP1, 5'd9, EP1_UTO), p655(LB_MUL, 5'd1, 5'd2)}, "mulw");
    check("mulw kind",   last.kind == UOP_ARITH);
    check("mulw op",     last.arith_op == ARITH_MUL);
    check("mulw uto",    last.uto_valid && last.uto_reg == 5'd9);
    feed('{p655(LB_EP1, 5'd7, EP1_UTO), p610(LB_DISPI, 10'd4)}, "jal");
    check("jal kind", last.kind == UOP_PREP_JUMP);
    check("jal link", last.uto_valid && last.uto_reg == 5'd7);

    // CSP redirects loads and stores into the port space.
    feed('{p655(LB_EP1, EP2_CSP, EP1_EP2), p655(LB_LD32, 5'd1, 5'd10)}, "csp ld");
    check("csp load kind", last.kind == UOP_CSP_LOAD);
    check("csp load dst",  last.dst == 5'd1);
    check("csp load port", last.src == 5'd10);
    feed('{p655(LB_EP1, EP2_CSP, EP1_EP2), p655(LB_ST, 5'd10, 5'd1)}, "csp st");
    check("csp store kind", last.kind == UOP_CSP_STORE);
    check("csp store port", last.dst == 5'd10);
    check("csp store data", last.src == 5'd1);

    // The three prefixes that turn their main opcode into a no-op. Getting
    // these wrong performs a real store or compare (spec 3.2).
    feed('{p655(LB_EP1, EP2_ICINVR, EP1_EP2), p655(LB_ST, 5'd1, 5'd2)}, "icinvr");
    check("icinvr+st is a nop", last.kind == UOP_NOP);
    feed('{p655(LB_EP1, 5'd0, EP1_ESP), p655(LB_ST, 5'd1, 5'd2)}, "esp");
    check("esp+st is a nop", last.kind == UOP_NOP);
    feed('{p655(LB_EP1, EP2_MPD, EP1_EP2), p655(LB_TST, 5'd1, 5'd2)}, "pfd");
    check("mpd+tst is a nop", last.kind == UOP_NOP);

    // FLAG redirects logic onto the flag bit, but has no immediate form.
    feed('{p655(LB_EP1, EP2_FLAG, EP1_EP2), p655(LB_AND, 5'd1, 5'd2)}, "flag and");
    check("flag and kind",     last.kind == UOP_LOGIC);
    check("flag and on_flags", last.on_flags);
    feed('{p655(LB_EP1, EP2_FLAG, EP1_EP2), p610(LB_XI, 10'd1),
           p655(LB_AND, 5'd1, 5'd2)}, "flag and imm");
    check("flag+immediate faults", last.kind == UOP_FAULT &&
                                   last.fault == FAULT_ILLEGAL_PREFIX_COMBO);
    feed('{p655(LB_EP1, EP2_FLAG, EP1_EP2), p655(LB_EP1, 5'd1, EP1_NEG)}, "flag neg");
    check("flag+neg faults", last.kind == UOP_FAULT &&
                             last.fault == FAULT_ILLEGAL_PREFIX_COMBO);

    // ---- predication (spec 7) -------------------------------------------
    feed('{p655(LB_XCP, 5'd3, CC_VALUE_ZERO), p655(LB_ADD, 5'd1, 5'd2)}, "xcp");
    check("xcp cond",     last.cond == CCK_ZERO);
    check("xcp reg",      last.cond_reg == 5'd3);
    check("xcp not inv",  last.cond_invert == 1'b0);
    check("xcp main kind",last.kind == UOP_ARITH);
    feed('{p655(LB_XCN, 5'd3, CC_FLAG_SET), p655(LB_ADD, 5'd1, 5'd2)}, "xcn");
    check("xcn inverted", last.cond_invert == 1'b1);
    check("xcn cond",     last.cond == CCK_FLAG);

    // An unassigned condition code is illegal rather than silently reread as
    // a main opcode.
    feed('{p655(LB_XCP, 5'd3, 5'd0)}, "xcp bad cc");
    check("bad condition code faults", last.kind == UOP_FAULT &&
                                       last.fault == FAULT_ILLEGAL_PREFIX_COMBO);

    // ---- long constants (spec 4.2) --------------------------------------
    feed('{p655(LB_EP1, 5'd1, EP1_LLC_B16), 16'hBEEF}, "llc16");
    check("llc16 kind", last.kind == UOP_PUT_IMM);
    check("llc16 dst",  last.dst == 5'd1);
    check("llc16 imm",  last.imm == 32'h0000_BEEF);

    // The 32-bit form stores its HIGH halfword first.
    feed('{p655(LB_EP1, 5'd2, EP1_LLC_B32), 16'h1234, 16'h5678}, "llc32");
    check("llc32 imm high-first", last.imm == 32'h1234_5678);
    check("llc32 size", last.size_bytes == 32'd6);

    // ---- cut features fault rather than mis-execute (spec 10) -----------
    feed('{p655(LB_DIV, 5'd1, 5'd2)}, "div");
    check("div faults", last.kind == UOP_FAULT &&
                        last.fault == FAULT_DIV_UNIMPLEMENTED);
    feed('{p655(LB_LDF32, 5'd1, 5'd2)}, "ldf32");
    check("ldf32 faults", last.kind == UOP_FAULT &&
                          last.fault == FAULT_FP_UNIMPLEMENTED);

    // ---- illegal encodings ----------------------------------------------
    feed('{16'h0000}, "zero word");
    check("unassigned opcode faults", last.kind == UOP_FAULT &&
                                      last.fault == FAULT_ILLEGAL_OPCODE);
    feed('{p655(LB_DISP, 5'd1, 5'd0)}, "disp bad arg2");
    check("disp with bad arg2 faults", last.kind == UOP_FAULT &&
                                       last.fault == FAULT_ILLEGAL_OPCODE);
    feed('{p655(LB_RDT, 5'd1, 5'b00111)}, "rdt bad tag");
    check("rdt unassigned tag faults", last.kind == UOP_FAULT &&
                                       last.fault == FAULT_ILLEGAL_OPCODE);

    // ---- prefix chain bound (spec 3) -------------------------------------
    // Seven prefixes then a main opcode is legal.
    feed('{p610(LB_XI, 10'd0), p610(LB_XI, 10'd0), p610(LB_XI, 10'd0),
           p610(LB_XI, 10'd0), p610(LB_XI, 10'd0), p610(LB_XI, 10'd0),
           p610(LB_XI, 10'd0), p655(LB_ADD, 5'd1, 5'd2)}, "7 prefixes");
    check("7 prefixes legal", last.kind == UOP_ARITH);
    check("7 prefixes size", last.size_bytes == 32'd16);

    // An eighth faults instead of accumulating forever.
    feed('{p610(LB_XI, 10'd0), p610(LB_XI, 10'd0), p610(LB_XI, 10'd0),
           p610(LB_XI, 10'd0), p610(LB_XI, 10'd0), p610(LB_XI, 10'd0),
           p610(LB_XI, 10'd0), p610(LB_XI, 10'd0)}, "8 prefixes");
    check("8 prefixes fault", last.kind == UOP_FAULT &&
                              last.fault == FAULT_PREFIX_CHAIN_TOO_LONG);

    // ---- a later prefix of the same kind overrides an earlier one --------
    feed('{p655(LB_XCP, 5'd3, CC_VALUE_ZERO),
           p655(LB_XCP, 5'd9, CC_FLAG_SET),
           p655(LB_ADD, 5'd1, 5'd2)}, "repeated xcp");
    check("last prefix wins", last.cond_reg == 5'd9 && last.cond == CCK_FLAG);

    // ---- flush abandons a partial instruction ----------------------------
    @(negedge clk);
    cp = p610(LB_XI, 10'd5); cp_valid = 1;
    @(posedge clk);
    @(negedge clk);
    cp_valid = 0; flush = 1;
    @(posedge clk);
    @(negedge clk);
    flush = 0;
    feed('{p655(LB_ADD, 5'd1, 5'd2)}, "after flush");
    check("flush drops the prefix", last.use_imm == 1'b0);

    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("TB_PASS tb_decode");
    else             $display("TB_FAIL tb_decode: %0d error(s)", errors);
    $finish;
  end

  // Guard against a hang if the DUT never completes an instruction.
  initial begin
    #200000;
    $display("TB_FAIL tb_decode: timeout");
    $finish;
  end

endmodule
