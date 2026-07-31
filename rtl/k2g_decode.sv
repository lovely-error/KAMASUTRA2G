// K2G instruction decoder: the prefix accumulator.
//
// Consumes one 16-bit code point per cycle. Prefix code points fold into an
// accumulator; the first non-prefix code point is the main opcode and completes
// the instruction, at which point a `uop_t` is emitted. Long-constant forms
// (`LLC_*`) additionally consume one or two trailing literal code points.
//
// This is the software prefix loop of `decode_instruction` in
// emu/src/interp.rs turned into a state machine. The superseded decoder.sv
// attempted eight of these in parallel over a 128-bit fetch window; that does
// not fit a GW1NR-9C once the PSRAM IP is accounted for, so this is
// deliberately one code point per cycle.
//
// Prefixes that *reinterpret* their main opcode are resolved here, so the
// execute stage never sees a prefix: BMX+SHL is an extract, UTO+MUL is a
// widening multiply, CSP+LD is a port read, and MPD/MPI+TST, ICINVR+ST and
// ESP+ST are no-ops rather than the compares and stores they would otherwise
// be (spec 3.2).

`include "k2g_types.svh"

module k2g_decode
  import k2g_pkg::*;
  import k2g_types::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Code point stream. `cp_valid` gates consumption; `flush` abandons a
    // partially accumulated instruction on a branch redirect.
    input  logic [15:0] cp,
    input  logic        cp_valid,
    input  logic        flush,

    // Number of code points consumed so far for this instruction, including
    // the one presented this cycle. Fetch uses it for `size_bytes`.
    output logic        accept,      // this code point was consumed
    output uop_t        uop,
    output logic        uop_valid    // `uop` completes an instruction
);

  // ---- accumulated prefix state -----------------------------------------
  typedef struct packed {
    logic        xi_valid;
    logic        xi_zext;      // XIZEXT rather than XI (spec 4.1)
    logic [31:0] xi_value;     // already sign- or zero-extended

    cond_kind_e  cond;
    logic [4:0]  cond_reg;
    logic        cond_invert;

    logic        uto_valid;
    logic [4:0]  uto_reg;

    logic        bmx_valid;
    logic [4:0]  bm_start;
    logic [4:0]  bm_span;

    logic        flag;
    logic        csp;
    logic        icinvr;
    logic        esp;
    logic        prefetch_d;
    logic        prefetch_i;
    logic        ordering;     // any of LTL/SL/SS/SR: ignored, but recorded

    logic [3:0]  count;        // prefix code points consumed
    logic [31:0] bytes;        // total code point bytes consumed
  } pfx_t;

  pfx_t pfx, pfx_next;

  // LLC forms need trailing literal code points; the FSM waits for them.
  typedef enum logic [1:0] { S_PREFIX, S_LLC_HI, S_LLC_LO } state_e;
  state_e state, state_next;

  logic [4:0]  llc_dst;
  logic [2:0]  llc_kind;
  logic [15:0] llc_hi;
  logic [4:0]  llc_dst_next;
  logic [2:0]  llc_kind_next;
  logic [15:0] llc_hi_next;

  // ---- field extraction --------------------------------------------------
  wire logic [5:0] lb    = cp[LB_LSB   +: LB_W];
  wire logic [4:0] arg1  = cp[ARG1_LSB +: ARG1_W];
  wire logic [4:0] arg2  = cp[ARG2_LSB +: ARG2_W];
  wire logic [9:0] imm10 = cp[IMM10_LSB +: IMM10_W];

  // ---- prefix classification --------------------------------------------
  // EP1 selects on arg2; EP2 escapes again and selects on arg1. Note the field
  // swap between the two levels (spec 2).
  wire logic is_ep1  = (lb == LB_EP1);
  wire logic is_ep2  = is_ep1 && (arg2 == EP1_EP2);
  wire logic [4:0] ep1_op = arg2;
  wire logic [4:0] ep2_op = arg1;

  wire logic pfx_xi     = (lb == LB_XI) || (lb == LB_XIZEXT);
  wire logic pfx_bmx    = (lb == LB_BMX_0_0);
  wire logic pfx_xc     = (lb == LB_XCP) || (lb == LB_XCN);
  wire logic pfx_uto    = is_ep1 && !is_ep2 && (ep1_op == EP1_UTO);
  wire logic pfx_order  = is_ep1 && !is_ep2 &&
                          ((ep1_op == EP1_SS) || (ep1_op == EP1_SR) ||
                           (ep1_op == EP1_SL) || (ep1_op == EP1_LTL));
  wire logic pfx_esp    = is_ep1 && !is_ep2 && (ep1_op == EP1_ESP);
  wire logic pfx_flag   = is_ep2 && (ep2_op == EP2_FLAG);
  wire logic pfx_csp    = is_ep2 && (ep2_op == EP2_CSP);
  wire logic pfx_mpi    = is_ep2 && (ep2_op == EP2_MPI);
  wire logic pfx_mpd    = is_ep2 && (ep2_op == EP2_MPD);
  wire logic pfx_icinvr = is_ep2 && (ep2_op == EP2_ICINVR);

  // A condition code outside the assigned set makes XCP/XCN illegal. The
  // emulator used to fall back to treating the code point as a main opcode,
  // which then decoded as garbage; here it faults (spec 7).
  cond_kind_e xc_cond;
  logic       xc_cond_ok;
  always_comb begin
    xc_cond_ok = 1'b1;
    unique case (arg2)
      CC_OVERFLOW_SET:   xc_cond = CCK_OVERFLOW;
      CC_FLAG_SET:       xc_cond = CCK_FLAG;
      CC_VALUE_ZERO:     xc_cond = CCK_ZERO;
      CC_VALUE_NEGATIVE: xc_cond = CCK_NEGATIVE;
      CC_VALUE_POSITIVE: xc_cond = CCK_POSITIVE;
      default: begin
        xc_cond    = CCK_NONE;
        xc_cond_ok = 1'b0;
      end
    endcase
  end

  wire logic is_prefix = pfx_xi | pfx_bmx | pfx_xc | pfx_uto | pfx_order |
                         pfx_esp | pfx_flag | pfx_csp | pfx_mpi | pfx_mpd |
                         pfx_icinvr;

  // ---- immediate assembly ------------------------------------------------
  // XI sign-extends from bit 9, XIZEXT zero-extends (spec 4.1).
  wire logic [31:0] xi_ext = (lb == LB_XI) ? {{22{imm10[9]}}, imm10}
                                           : {22'd0, imm10};

  // Three different combining rules depending on the main opcode (spec 4).
  wire logic [31:0] imm_alu = pfx.xi_valid ? {pfx.xi_value[26:0], arg2}
                                           : {{27{arg2[4]}}, arg2};
  wire logic [31:0] imm_mem = pfx.xi_valid ? pfx.xi_value : 32'd0;

  // DISPI assembles a 20-bit displacement then shifts left by one. The
  // extension follows the prefix that supplied it -- previously this
  // sign-extended unconditionally, so XIZEXT could yield a negative
  // displacement (spec 4.1).
  wire logic [19:0] disp20 = {pfx.xi_value[9:0], imm10};
  wire logic [31:0] disp_ext =
      pfx.xi_valid ? (pfx.xi_zext ? {12'd0, disp20}
                                  : {{12{disp20[19]}}, disp20})
                   : {{22{imm10[9]}}, imm10};
  wire logic [31:0] disp_bytes = {disp_ext[30:0], 1'b0};

  // ---- main decode -------------------------------------------------------
  uop_t main_uop;
  logic main_is_llc;
  logic [2:0] main_llc_kind;

  always_comb begin
    main_uop      = uop_nop();
    main_is_llc   = 1'b0;
    main_llc_kind = RDT_U32;

    // Carry accumulated prefix state onto every decoded instruction.
    main_uop.cond        = pfx.cond;
    main_uop.cond_reg    = pfx.cond_reg;
    main_uop.cond_invert = pfx.cond_invert;
    main_uop.uto_valid   = pfx.uto_valid;
    main_uop.uto_reg     = pfx.uto_reg;
    main_uop.on_flags    = pfx.flag;
    main_uop.bm_start    = pfx.bm_start;
    main_uop.bm_span     = pfx.bm_span;
    main_uop.dst         = arg1;
    main_uop.src         = arg2;

    unique case (lb)
      // ---- put constant ----
      LB_PUC8, LB_PUC16, LB_PUC32: begin
        main_uop.kind     = UOP_PUT_IMM;
        main_uop.imm      = imm_alu;
        main_uop.datakind = (lb == LB_PUC8)  ? RDT_U8  :
                            (lb == LB_PUC16) ? RDT_U16 : RDT_U32;
      end

      LB_RDT: begin
        // 3'b111 is the one unassigned tag encoding.
        if (arg2[2:0] == 3'b111 || arg2[4:3] != 2'b00) begin
          main_uop = uop_fault(FAULT_ILLEGAL_OPCODE);
        end else begin
          main_uop.kind     = UOP_SET_TAG;
          main_uop.datakind = arg2[2:0];
        end
      end

      LB_CPY: main_uop.kind = UOP_COPY;

      // ---- loads ----
      LB_LD8, LB_LD16, LB_LD32, LB_LDF32: begin
        main_uop.datakind = (lb == LB_LD8)  ? RDT_U8  :
                            (lb == LB_LD16) ? RDT_U16 :
                            (lb == LB_LD32) ? RDT_U32 : RDT_F32;
        if (lb == LB_LDF32) begin
          main_uop = uop_fault(FAULT_FP_UNIMPLEMENTED);  // reserved (spec 11)
        end else if (pfx.csp) begin
          // CSP+LD: port number in arg2, destination arg1 (spec 9).
          main_uop.kind = UOP_CSP_LOAD;
        end else begin
          main_uop.kind = UOP_LOAD;
          main_uop.imm  = imm_mem;
        end
      end

      // ---- stores, and the prefixes that replace them ----
      LB_ST: begin
        if (pfx.icinvr || pfx.esp) begin
          // Honoured as a no-op. Ignoring the prefix would perform a real
          // store, which is a silent wrong answer rather than a missing
          // feature (spec 3.2, 10).
          main_uop.kind = UOP_NOP;
        end else if (pfx.csp) begin
          // CSP+ST: port number in arg1, data in arg2 -- the opposite operand
          // positions from the load form.
          main_uop.kind = UOP_CSP_STORE;
        end else begin
          main_uop.kind = UOP_STORE;
          main_uop.imm  = imm_mem;
        end
      end

      // ---- arithmetic ----
      LB_ADD, LB_SUB, LB_MUL, LB_DIV: begin
        if (lb == LB_DIV) begin
          main_uop = uop_fault(FAULT_DIV_UNIMPLEMENTED);  // cut from v1
        end else begin
          main_uop.kind     = UOP_ARITH;
          main_uop.arith_op = (lb == LB_ADD) ? ARITH_ADD :
                              (lb == LB_SUB) ? ARITH_SUB : ARITH_MUL;
          main_uop.use_imm  = pfx.xi_valid;
          main_uop.imm      = imm_alu;
        end
      end

      // ---- logic ----
      LB_AND, LB_OR, LB_XOR: begin
        main_uop.kind     = UOP_LOGIC;
        main_uop.logic_op = (lb == LB_AND) ? LOGIC_AND :
                            (lb == LB_OR)  ? LOGIC_OR  : LOGIC_XOR;
        main_uop.use_imm  = pfx.xi_valid;
        main_uop.imm      = imm_alu;
        // There is no immediate flag bit, so FLAG with an immediate is
        // meaningless (spec 5.6).
        if (pfx.flag && pfx.xi_valid) begin
          main_uop = uop_fault(FAULT_ILLEGAL_PREFIX_COMBO);
        end
      end

      // ---- shifts, and the bit-field ops that replace them ----
      LB_SHL, LB_SHR, LB_SHRA: begin
        if (pfx.bmx_valid) begin
          unique case (lb)
            LB_SHL: begin
              main_uop.kind = UOP_BEXT;
              if (pfx.bm_span == 5'd0) begin
                main_uop = uop_fault(FAULT_BEXT_ZERO_SPAN);
              end
            end
            LB_SHR: main_uop.kind = UOP_BINS;   // span 0 is a defined no-op
            default: main_uop = uop_fault(FAULT_ILLEGAL_PREFIX_COMBO);
          endcase
        end else begin
          main_uop.kind     = UOP_SHIFT;
          main_uop.shift_op = (lb == LB_SHL) ? SHIFT_LL :
                              (lb == LB_SHR) ? SHIFT_LR : SHIFT_AR;
        end
      end

      // Immediate shift amounts ignore XI entirely (spec 4).
      LB_SHLI, LB_SHRI, LB_SHRAI: begin
        main_uop.kind     = UOP_SHIFT;
        main_uop.shift_op = (lb == LB_SHLI) ? SHIFT_LL :
                            (lb == LB_SHRI) ? SHIFT_LR : SHIFT_AR;
        main_uop.use_imm  = 1'b1;
        main_uop.imm      = {27'd0, arg2};
      end

      // ---- comparisons, and the prefetch that replaces them ----
      LB_TST, LB_TSTN, LB_LT, LB_GT, LB_LTE, LB_GTE: begin
        if (pfx.prefetch_d || pfx.prefetch_i) begin
          // Also a no-op that must be honoured: ignoring it would perform a
          // real compare and write a flag bit (spec 3.2).
          main_uop.kind = UOP_NOP;
        end else begin
          main_uop.kind    = UOP_CMP;
          main_uop.use_imm = pfx.xi_valid;
          main_uop.imm     = imm_alu;
          unique case (lb)
            LB_TST:  main_uop.cmp_op = CMP_EQ;
            LB_TSTN: main_uop.cmp_op = CMP_NE;
            LB_LT:   main_uop.cmp_op = CMP_LT;
            LB_GT:   main_uop.cmp_op = CMP_GT;
            LB_LTE:  main_uop.cmp_op = CMP_LE;
            default: main_uop.cmp_op = CMP_GE;
          endcase
        end
      end

      // ---- control transfer ----
      LB_DISP: begin
        main_uop.kind = UOP_PREP_JUMP;
        unique case (arg2)
          EP1_DISP_OFF: main_uop.jump_kind = JT_REL_REG;
          EP1_DISP_ABS: main_uop.jump_kind = JT_ABS_REG;
          default:      main_uop = uop_fault(FAULT_ILLEGAL_OPCODE);
        endcase
      end

      LB_DISPI: begin
        main_uop.kind      = UOP_PREP_JUMP;
        main_uop.jump_kind = JT_REL_IMM;
        main_uop.imm       = disp_bytes;
      end

      // ---- escapes ----
      LB_EP1: begin
        if (is_ep2) begin
          unique case (ep2_op)
            EP2_HALT: main_uop.kind = UOP_HALT;
            EP2_DNO:  main_uop.kind = UOP_NOP;
            EP2_TC:   main_uop.kind = UOP_PERFORM_JUMP;
            default:  main_uop = uop_fault(FAULT_ILLEGAL_OPCODE);
          endcase
        end else begin
          unique case (ep1_op)
            EP1_NOT, EP1_NEG: begin
              main_uop.kind     = UOP_UNARY;
              main_uop.unary_op = (ep1_op == EP1_NOT) ? UNARY_NOT : UNARY_NEG;
              // Negating a single bit is meaningless (spec 5.6).
              if (pfx.flag && ep1_op == EP1_NEG) begin
                main_uop = uop_fault(FAULT_ILLEGAL_PREFIX_COMBO);
              end
            end
            EP1_LLC_B8, EP1_LLC_B16: begin
              main_is_llc   = 1'b1;
              main_llc_kind = (ep1_op == EP1_LLC_B8) ? RDT_U8 : RDT_U16;
            end
            EP1_LLC_B32: begin
              main_is_llc   = 1'b1;
              main_llc_kind = RDT_U32;
            end
            EP1_LLC_F32: main_uop = uop_fault(FAULT_FP_UNIMPLEMENTED);
            default:     main_uop = uop_fault(FAULT_ILLEGAL_OPCODE);
          endcase
        end
      end

      default: main_uop = uop_fault(FAULT_ILLEGAL_OPCODE);
    endcase
  end

  // ---- next-state logic --------------------------------------------------
  logic emit;

  always_comb begin
    pfx_next      = pfx;
    state_next    = state;
    llc_dst_next  = llc_dst;
    llc_kind_next = llc_kind;
    llc_hi_next   = llc_hi;
    uop           = uop_nop();
    emit          = 1'b0;
    accept        = cp_valid;

    if (cp_valid) begin
      pfx_next.bytes = pfx.bytes + 32'd2;

      unique case (state)
        // ---- collecting prefixes, then one main code point ----
        S_PREFIX: begin
          if (is_prefix) begin
            // A chain longer than the bound is a fault rather than a hang;
            // the emulator's loop was previously unbounded (spec 3).
            if (pfx.count >= MAX_PREFIX_CHAIN[3:0]) begin
              uop  = uop_fault(FAULT_PREFIX_CHAIN_TOO_LONG);
              emit = 1'b1;
            end else begin
              pfx_next.count = pfx.count + 4'd1;
              if (pfx_xi) begin
                pfx_next.xi_valid = 1'b1;
                pfx_next.xi_zext  = (lb == LB_XIZEXT);
                pfx_next.xi_value = xi_ext;
              end
              if (pfx_bmx) begin
                pfx_next.bmx_valid = 1'b1;
                pfx_next.bm_start  = arg1;
                pfx_next.bm_span   = arg2;
              end
              if (pfx_xc) begin
                if (!xc_cond_ok) begin
                  uop  = uop_fault(FAULT_ILLEGAL_PREFIX_COMBO);
                  emit = 1'b1;
                end else begin
                  pfx_next.cond        = xc_cond;
                  pfx_next.cond_reg    = arg1;
                  pfx_next.cond_invert = (lb == LB_XCN);
                end
              end
              if (pfx_uto) begin
                pfx_next.uto_valid = 1'b1;
                pfx_next.uto_reg   = arg1;
              end
              if (pfx_flag)   pfx_next.flag       = 1'b1;
              if (pfx_csp)    pfx_next.csp        = 1'b1;
              if (pfx_icinvr) pfx_next.icinvr     = 1'b1;
              if (pfx_esp)    pfx_next.esp        = 1'b1;
              if (pfx_mpd)    pfx_next.prefetch_d = 1'b1;
              if (pfx_mpi)    pfx_next.prefetch_i = 1'b1;
              if (pfx_order)  pfx_next.ordering   = 1'b1;
            end
          end else if (main_is_llc) begin
            // The literal follows the main code point.
            llc_dst_next  = arg1;
            llc_kind_next = main_llc_kind;
            state_next    = (main_llc_kind == RDT_U32) ? S_LLC_HI : S_LLC_LO;
          end else begin
            uop  = main_uop;
            emit = 1'b1;
          end
        end

        // LLC_B32 stores its immediate HIGH halfword first -- big-endian
        // inside an otherwise little-endian stream (spec 4.2).
        S_LLC_HI: begin
          llc_hi_next = cp;
          state_next  = S_LLC_LO;
        end

        S_LLC_LO: begin
          uop          = uop_nop();
          uop.kind     = UOP_PUT_IMM;
          uop.dst      = llc_dst;
          uop.datakind = llc_kind;
          uop.imm      = (llc_kind == RDT_U32) ? {llc_hi, cp}
                                               : {16'd0, cp};
          uop.cond        = pfx.cond;
          uop.cond_reg    = pfx.cond_reg;
          uop.cond_invert = pfx.cond_invert;
          emit            = 1'b1;
          state_next      = S_PREFIX;
        end

        default: state_next = S_PREFIX;
      endcase
    end

    // The instruction's total length, needed for PC advance and the link
    // register. Counted here rather than in fetch so the two cannot disagree.
    uop.size_bytes = pfx.bytes + 32'd2;
    uop_valid      = emit;
  end

  // ---- state ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      pfx      <= '0;
      pfx.cond <= CCK_NONE;
      state    <= S_PREFIX;
      llc_dst  <= '0;
      llc_kind <= RDT_U32;
      llc_hi   <= '0;
    end else if (cp_valid) begin
      if (emit) begin
        // Instruction complete: start the next one clean.
        pfx      <= '0;
        pfx.cond <= CCK_NONE;
        state    <= S_PREFIX;
      end else begin
        pfx      <= pfx_next;
        state    <= state_next;
      end
      llc_dst  <= llc_dst_next;
      llc_kind <= llc_kind_next;
      llc_hi   <= llc_hi_next;
    end
  end

endmodule
