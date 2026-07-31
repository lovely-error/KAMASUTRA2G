// K2G core.
//
// Fetch presents an address every cycle and the code point arrives the next,
// so decode runs one stage behind. A completed instruction executes in that
// same decode cycle -- register reads are asynchronous, so read, ALU and
// writeback all fit -- except for memory and I/O accesses, which take one more
// cycle and stall the front end.
//
// NOTE ON STRUCTURE. The plan calls for a 3-stage F/D/X pipeline with
// zero-bubble branches via a shadow fetch on the free data port. This is
// simpler than that: correctness first, measured against the emulator by
// cosimulation, with pipelining as a follow-on the cosimulation then makes
// safe to attempt. The pieces that make the fast version possible -- the
// prefix accumulator, the split register file, the separate jump latch -- are
// all here already.

`include "k2g_types.svh"

module k2g_core
  import k2g_pkg::*;
  import k2g_types::*;
#(
    parameter int MEM_BYTES = 8192
) (
    input  logic        clk,
    input  logic        rst_n,

    // Instruction fetch port.
    output logic [31:0] imem_addr,
    output logic        imem_en,
    input  logic [15:0] imem_data,

    // Data port.
    output logic [31:0] dmem_addr,
    output logic        dmem_en,
    output logic [3:0]  dmem_we,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata,

    // UART, through the CSP port space.
    output logic        uart_tx_valid,
    output logic [7:0]  uart_tx_data,
    input  logic        uart_tx_ready,
    input  logic        uart_rx_valid,
    input  logic [7:0]  uart_rx_data,
    output logic        uart_rx_take,

    output logic [31:0] gpio_out,

    // Machine status, for the LEDs and the halt-time dump.
    output logic        halted,
    output logic        faulted,
    output logic [4:0]  fault_cause_o,
    output logic [31:0] fault_addr_o,
    output logic [31:0] fault_info_o,
    output logic [63:0] cycle_count_o
);

  // ---- fetch -------------------------------------------------------------
  logic [31:0] pc;        // address presented to IMEM this cycle
  logic [31:0] pc_d;      // address of the code point available this cycle
  logic        cp_valid;
  logic        redirect;
  logic [31:0] redirect_pc;
  logic        stall;

  assign imem_addr = pc;
  assign imem_en   = !stall;

  // ---- decode ------------------------------------------------------------
  uop_t uop;
  logic uop_valid;
  logic decode_en;

  // Deliberately NOT gated by `stall`: the decoder's output is combinational,
  // and routing the stall into it closes a loop through the CSP request. The
  // stall freezes the accumulator via `hold` instead, and `take_uop` is what
  // actually prevents an instruction retiring.
  assign decode_en = cp_valid && !halted;

  k2g_decode u_decode (
      .clk      (clk),
      .rst_n    (rst_n),
      .cp       (imem_data),
      .cp_valid (decode_en),
      .flush    (redirect),
      .hold     (stall),
      .accept   (),
      .uop      (uop),
      .uop_valid(uop_valid)
  );

  // Address of the first code point of the instruction being completed.
  // `size_bytes` counts every code point including the current one, so the
  // start is that many bytes back. Displacements are relative to this, not to
  // the DISPI code point (spec 6.2).
  wire logic [31:0] isa = pc_d - (uop.size_bytes - 32'd2);

  // ---- register file -----------------------------------------------------
  logic [4:0]  ra_addr, rb_addr, rc_addr, w_addr;
  logic [31:0] ra_value, rb_value, rc_value, w_value;
  logic [2:0]  ra_tag, rb_tag, w_tag;
  logic        ra_overflow, rb_overflow, rc_overflow;
  logic        ra_flag, rb_flag, rc_flag;
  logic        we_value, we_tag, we_overflow, we_flag;
  logic        w_overflow, w_flag;

  k2g_regfile u_rf (.*);

  assign ra_addr = uop.dst;
  assign rb_addr = uop.src;
  assign rc_addr = uop.cond_reg;

  // ---- predication -------------------------------------------------------
  // Zero and negative are computed from the register value on demand; there is
  // no global condition register (spec 7).
  logic cond_raw, cond_met;
  always_comb begin
    unique case (uop.cond)
      CCK_OVERFLOW: cond_raw = rc_overflow;
      CCK_FLAG:     cond_raw = rc_flag;
      CCK_ZERO:     cond_raw = (rc_value == 32'd0);
      CCK_NEGATIVE: cond_raw = rc_value[31];
      CCK_POSITIVE: cond_raw = (rc_value != 32'd0) && !rc_value[31];
      default:      cond_raw = 1'b1;
    endcase
    cond_met = (uop.cond == CCK_NONE) ? 1'b1 : (cond_raw ^ uop.cond_invert);
  end

  // ---- functional units --------------------------------------------------
  logic [31:0] alu_a, alu_b;
  logic [2:0]  alu_a_tag, alu_b_tag;
  logic [31:0] arith_result, logic_result, unary_result;
  logic        arith_overflow, cmp_result;

  // An immediate carries no tag of its own, so it takes the left operand's
  // interpretation (spec 5.9).
  assign alu_a     = ra_value;
  assign alu_b     = uop.use_imm ? uop.imm : rb_value;
  assign alu_a_tag = ra_tag;
  assign alu_b_tag = uop.use_imm ? ra_tag : rb_tag;

  k2g_alu u_alu (
      .a             (alu_a),
      .b             (alu_b),
      .a_tag         (alu_a_tag),
      .b_tag         (alu_b_tag),
      .arith_op      (uop.arith_op),
      .logic_op      (uop.logic_op),
      .cmp_op        (uop.cmp_op),
      .unary_op      (uop.unary_op),
      .arith_result  (arith_result),
      .arith_overflow(arith_overflow),
      .logic_result  (logic_result),
      .cmp_result    (cmp_result),
      .unary_result  (unary_result)
  );

  logic [31:0] shift_result, bext_result, bins_result;

  k2g_shift u_shift (
      .value       (ra_value),
      .src         (rb_value),
      .amount      (uop.use_imm ? uop.imm[4:0] : rb_value[4:0]),
      .shift_op    (uop.shift_op),
      .bm_start    (uop.bm_start),
      .bm_span     (uop.bm_span),
      .shift_result(shift_result),
      .bext_result (bext_result),
      .bins_result (bins_result)
  );

  // Widening multiply. Full 64-bit product; the high half goes to the UTO
  // register on a second cycle so the value array keeps one write port.
  wire logic [63:0] product = ra_value * alu_b;

  // ---- memory access -----------------------------------------------------
  wire logic        is_load     = (uop.kind == UOP_LOAD);
  wire logic        is_store    = (uop.kind == UOP_STORE);
  wire logic [31:0] load_addr   = rb_value + uop.imm;
  wire logic [31:0] store_addr  = ra_value + uop.imm;
  wire logic [31:0] access_addr = is_load ? load_addr : store_addr;

  // Store width comes from the SOURCE register's tag, not the opcode
  // (spec 5.3).
  wire logic [2:0] access_tag   = is_load ? uop.datakind : rb_tag;
  wire logic [2:0] access_width = rdt_width_bytes(access_tag);

  logic [3:0] store_we;
  always_comb begin
    unique case (access_width)
      3'd1:    store_we = 4'b0001 << store_addr[1:0];
      3'd2:    store_we = store_addr[1] ? 4'b1100 : 4'b0011;
      default: store_we = 4'b1111;
    endcase
  end

  // Byte lanes are replicated so a narrow store lands wherever the enables
  // select.
  logic [31:0] store_data;
  always_comb begin
    unique case (access_width)
      3'd1:    store_data = {4{rb_value[7:0]}};
      3'd2:    store_data = {2{rb_value[15:0]}};
      default: store_data = rb_value;
    endcase
  end

  // Alignment and range are checked before anything commits, which is what
  // makes faults precise (spec 8).
  logic misaligned, out_of_range;
  always_comb begin
    unique case (access_width)
      3'd1:    misaligned = 1'b0;
      3'd2:    misaligned = access_addr[0];
      default: misaligned = |access_addr[1:0];
    endcase
    out_of_range = (access_addr + {29'd0, access_width}) > MEM_BYTES[31:0];
  end

  // ---- CSP ---------------------------------------------------------------
  wire logic is_csp_load  = (uop.kind == UOP_CSP_LOAD);
  wire logic is_csp_store = (uop.kind == UOP_CSP_STORE);
  wire logic csp_req      = uop_valid && cond_met && (is_csp_load || is_csp_store);

  logic [31:0] csp_rdata;
  logic        csp_bad_port;
  logic        csp_stall;
  logic [31:0] compat_flags;
  logic        sticky_ordering;
  logic [63:0] cycle_count;
  logic [4:0]  fault_cause;
  logic [31:0] fault_addr, fault_info;

  k2g_csp u_csp (
      .clk            (clk),
      .rst_n          (rst_n),
      .req            (csp_req),
      .is_write       (is_csp_store),
      // CSP load takes the port from arg2, CSP store from arg1 -- opposite
      // operand positions (spec 9).
      .port           (is_csp_store ? ra_value : rb_value),
      .wdata          (rb_value),
      .rdata          (csp_rdata),
      .bad_port       (csp_bad_port),
      .stall          (csp_stall),
      .cycle_count    (cycle_count),
      .fault_cause    (fault_cause),
      .fault_addr     (fault_addr),
      .fault_info     (fault_info),
      .sticky_ordering(sticky_ordering),
      .uart_tx_valid  (uart_tx_valid),
      .uart_tx_data   (uart_tx_data),
      .uart_tx_ready  (uart_tx_ready),
      .uart_rx_valid  (uart_rx_valid),
      .uart_rx_data   (uart_rx_data),
      .uart_rx_take   (uart_rx_take),
      .gpio_out       (gpio_out),
      .compat_flags   (compat_flags)
  );

  // ---- multi-cycle sequencing --------------------------------------------
  // A load needs the memory read result, which arrives a cycle later; a
  // widening multiply needs a second cycle to write the high half.
  logic        mem_pending, mulw_pending;
  logic [4:0]  pend_dst;
  logic [2:0]  pend_tag;
  logic [31:0] pend_lo;
  logic [1:0]  pend_addr_lo;

  wire logic take_uop   = uop_valid && !stall && !halted;
  wire logic start_load = take_uop && cond_met && is_load &&
                          !misaligned && !out_of_range;
  wire logic start_mulw = take_uop && cond_met && (uop.kind == UOP_ARITH) &&
                          (uop.arith_op == ARITH_MUL) && uop.uto_valid;

  // A CSP access that cannot complete holds the instruction instead of
  // retiring it. Because nothing commits, the architectural state after each
  // retired instruction is unchanged -- the cosimulation cannot see a stall.
  assign stall = mem_pending || mulw_pending || csp_stall;

  assign dmem_addr  = access_addr;
  assign dmem_en    = take_uop && cond_met && (is_load || is_store) &&
                      !misaligned && !out_of_range;
  assign dmem_we    = is_store ? store_we : 4'b0000;
  assign dmem_wdata = store_data;

  // ---- jump latch --------------------------------------------------------
  logic [31:0] nisa;
  logic        nisa_valid;

  // ---- fault detection ---------------------------------------------------
  fault_e      detected;
  logic        detect_valid;
  logic [31:0] detect_info;

  always_comb begin
    detected     = FAULT_NONE;
    detect_valid = 1'b0;
    detect_info  = 32'd0;

    if (take_uop && cond_met) begin
      if (uop.kind == UOP_FAULT) begin
        detected     = uop.fault;
        detect_valid = 1'b1;
      end else if ((is_load || is_store) && misaligned) begin
        detected     = is_load ? FAULT_MISALIGNED_LOAD : FAULT_MISALIGNED_STORE;
        detect_valid = 1'b1;
        detect_info  = access_addr;
      end else if ((is_load || is_store) && out_of_range) begin
        detected     = FAULT_ADDR_OUT_OF_RANGE;
        detect_valid = 1'b1;
        detect_info  = access_addr;
      end else if (csp_bad_port) begin
        detected     = FAULT_BAD_CSP_PORT;
        detect_valid = 1'b1;
        detect_info  = is_csp_store ? ra_value : rb_value;
      end else if ((uop.kind == UOP_PERFORM_JUMP) && nisa_valid && nisa[0]) begin
        detected     = FAULT_MISALIGNED_FETCH;
        detect_valid = 1'b1;
        detect_info  = nisa;
      end
    end
  end

  logic [31:0] jump_target;
  always_comb begin
    unique case (uop.jump_kind)
      JT_REL_REG: jump_target = isa + ra_value;   // NOT shifted (spec 6.2)
      JT_ABS_REG: jump_target = ra_value;
      default:    jump_target = isa + uop.imm;
    endcase
  end

  wire logic do_prep_jump = take_uop && cond_met && (uop.kind == UOP_PREP_JUMP) &&
                            !detect_valid;
  // An unprimed TC is a defined NOP, and must stay one: a not-taken predicated
  // branch leaves nisa unprimed, so every conditional branch depends on it
  // (spec 6.5).
  wire logic do_perform  = take_uop && cond_met && (uop.kind == UOP_PERFORM_JUMP) &&
                           nisa_valid && !detect_valid;

  assign redirect    = do_perform;
  assign redirect_pc = nisa;

  // ---- writeback ---------------------------------------------------------
  logic [31:0] wb_value;
  logic [2:0]  wb_tag;

  // Loads return in the cycle after the access; everything else is immediate.
  wire logic [31:0] load_shifted = dmem_rdata >> {pend_addr_lo, 3'b000};
  wire logic [31:0] load_value   = rdt_normalize(load_shifted, pend_tag);

  always_comb begin
    we_value    = 1'b0;
    we_tag      = 1'b0;
    we_overflow = 1'b0;
    we_flag     = 1'b0;
    w_addr      = uop.dst;
    w_value     = 32'd0;
    w_tag       = uop.datakind;
    w_overflow  = 1'b0;
    w_flag      = 1'b0;
    wb_value    = 32'd0;
    wb_tag      = RDT_U32;

    if (mem_pending) begin
      // Second cycle of a load.
      w_addr   = pend_dst;
      w_value  = load_value;
      w_tag    = pend_tag;
      we_value = 1'b1;
      we_tag   = 1'b1;
    end else if (mulw_pending) begin
      // Second cycle of a widening multiply: the LOW half, written last so
      // that when both halves name the same register the low half wins,
      // matching the emulator (spec 5.5). The tag written back is the
      // destination's original tag -- a widening multiply leaves the low
      // destination's tag alone, and restoring it here also produces the
      // right answer in the aliased case, where cycle one set it to U32.
      w_addr   = pend_dst;
      w_value  = pend_lo;
      w_tag    = pend_tag;
      we_value = 1'b1;
      we_tag   = 1'b1;
    end else if (take_uop && cond_met && !detect_valid) begin
      unique case (uop.kind)
        UOP_PUT_IMM: begin
          // Normalized to the tag, so a register's bits always match what its
          // tag claims (spec 5.1, 1.1.1).
          w_value     = rdt_normalize(uop.imm, uop.datakind);
          w_tag       = uop.datakind;
          we_value    = 1'b1;
          we_tag      = 1'b1;
          we_overflow = 1'b1;
          we_flag     = 1'b1;   // put-constant clears both flags
        end
        UOP_SET_TAG: begin
          // RDT re-normalizes, which is what makes LD8 + RDT S8 a
          // sign-extending byte load (spec 5.10).
          w_value  = rdt_normalize(ra_value, uop.datakind);
          w_tag    = uop.datakind;
          we_value = 1'b1;
          we_tag   = 1'b1;
        end
        UOP_COPY: begin
          // A full move: value, tag and both flags (spec 5.2).
          w_value     = rb_value;
          w_tag       = rb_tag;
          w_overflow  = rb_overflow;
          w_flag      = rb_flag;
          we_value    = 1'b1;
          we_tag      = 1'b1;
          we_overflow = 1'b1;
          we_flag     = 1'b1;
        end
        UOP_CSP_LOAD: begin
          w_value  = rdt_normalize(csp_rdata, uop.datakind);
          w_tag    = uop.datakind;
          we_value = 1'b1;
          we_tag   = 1'b1;
        end
        UOP_ARITH: begin
          if (uop.uto_valid && (uop.arith_op == ARITH_MUL)) begin
            // Widening multiply, first cycle: the HIGH half into the UTO
            // register, tagged U32. The low half follows next cycle.
            w_addr   = uop.uto_reg;
            w_value  = product[63:32];
            w_tag    = RDT_U32;
            we_value = 1'b1;
            we_tag   = 1'b1;
            // A widening multiply writes no overflow; plain MUL does.
          end else begin
            w_value     = (uop.arith_op == ARITH_MUL) ? product[31:0] : arith_result;
            we_value    = 1'b1;
            w_overflow  = (uop.arith_op == ARITH_MUL) ? (|product[63:32])
                                                      : arith_overflow;
            we_overflow = 1'b1;
          end
        end
        UOP_LOGIC: begin
          if (uop.on_flags) begin
            unique case (uop.logic_op)
              LOGIC_AND: w_flag = ra_flag & rb_flag;
              LOGIC_OR:  w_flag = ra_flag | rb_flag;
              default:   w_flag = ra_flag ^ rb_flag;
            endcase
            we_flag = 1'b1;
          end else begin
            w_value  = logic_result;
            we_value = 1'b1;
          end
        end
        UOP_SHIFT: begin
          w_value  = rdt_normalize(shift_result, ra_tag);
          we_value = 1'b1;
        end
        UOP_BEXT: begin
          // Extract writes the whole register; insert writes only the value
          // (spec 5.8).
          w_value     = bext_result;
          w_tag       = RDT_U32;
          w_overflow  = 1'b0;
          w_flag      = 1'b0;
          we_value    = 1'b1;
          we_tag      = 1'b1;
          we_overflow = 1'b1;
          we_flag     = 1'b1;
        end
        UOP_BINS: begin
          w_value  = bins_result;
          we_value = 1'b1;
        end
        UOP_CMP: begin
          // Comparisons write only flag_bit of the left operand (spec 5.9).
          w_flag  = cmp_result;
          we_flag = 1'b1;
        end
        UOP_UNARY: begin
          if (uop.on_flags) begin
            w_flag  = ~ra_flag;
            we_flag = 1'b1;
          end else begin
            w_value  = rdt_normalize(unary_result, ra_tag);
            we_value = 1'b1;
          end
        end
        UOP_PREP_JUMP: begin
          // The link register points at the code point after the DISP, which
          // in the usual idiom is the TC itself (spec 6.3).
          if (uop.uto_valid) begin
            w_addr   = uop.uto_reg;
            w_value  = isa + uop.size_bytes;
            w_tag    = RDT_U32;
            we_value = 1'b1;
            we_tag   = 1'b1;
          end
        end
        default: ;
      endcase
    end
  end

  // ---- sequential state --------------------------------------------------
  logic halted_r, faulted_r;

  assign halted        = halted_r;
  assign faulted       = faulted_r;
  assign fault_cause_o = fault_cause;
  assign fault_addr_o  = fault_addr;
  assign fault_info_o  = fault_info;
  assign cycle_count_o = cycle_count;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc              <= 32'd0;
      pc_d            <= 32'd0;
      cp_valid        <= 1'b0;
      nisa            <= 32'd0;
      nisa_valid      <= 1'b0;
      halted_r        <= 1'b0;
      faulted_r       <= 1'b0;
      fault_cause     <= 5'd0;
      fault_addr      <= 32'd0;
      fault_info      <= 32'd0;
      cycle_count     <= 64'd0;
      mem_pending     <= 1'b0;
      mulw_pending    <= 1'b0;
      pend_dst        <= 5'd0;
      pend_tag        <= RDT_U32;
      pend_lo         <= 32'd0;
      pend_addr_lo    <= 2'd0;
      sticky_ordering <= 1'b0;
    end else if (!halted_r) begin
      // Fetch advances unless something is stalling the front end.
      if (redirect) begin
        pc       <= redirect_pc;
        cp_valid <= 1'b0;
      end else if (!stall) begin
        pc       <= pc + 32'd2;
        pc_d     <= pc;
        cp_valid <= 1'b1;
      end

      // Second cycles complete here.
      mem_pending  <= 1'b0;
      mulw_pending <= 1'b0;

      if (start_load) begin
        mem_pending  <= 1'b1;
        pend_dst     <= uop.dst;
        pend_tag     <= uop.datakind;
        pend_addr_lo <= access_addr[1:0];
      end
      if (start_mulw) begin
        mulw_pending <= 1'b1;
        pend_dst     <= uop.dst;
        pend_lo      <= product[31:0];
        pend_tag     <= ra_tag;   // the low destination keeps its own tag
      end

      if (take_uop) begin
        cycle_count <= cycle_count + 64'd1;

        if (detect_valid) begin
          halted_r    <= 1'b1;
          faulted_r   <= 1'b1;
          fault_cause <= detected;
          fault_addr  <= isa;
          fault_info  <= detect_info;
        end else if (cond_met && (uop.kind == UOP_HALT)) begin
          halted_r    <= 1'b1;
          fault_cause <= FAULT_HALT_INSN;
          fault_addr  <= isa;
        end

        // Double priming is legal: the last prime wins (spec 6.6).
        if (do_prep_jump) begin
          nisa       <= jump_target;
          nisa_valid <= 1'b1;
        end
        if (do_perform) begin
          nisa_valid <= 1'b0;
        end
      end
    end
  end

endmodule
