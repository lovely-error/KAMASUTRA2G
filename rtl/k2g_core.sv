// K2G core.
//
// Fetch requests code points from a bus that answers whenever it can, and they
// queue in an elastic buffer that decode drains at its own rate. A completed
// instruction still executes in its decode cycle -- register reads are
// asynchronous, so read, ALU and writeback all fit -- except for memory and
// I/O accesses, which wait for the bus and hold the front end.
//
// NOTE ON STRUCTURE. This is mid-conversion, and deliberately so. Both memory
// ports now speak k2g_membus and tolerate arbitrary latency, which is what a
// cache in front of PSRAM will need; the execute path is still v1's single
// combinational cycle, which is why Fmax is still around 10 MHz and 28 logic
// levels deep.
//
// Splitting decode from execute, and then execute from writeback, is what
// breaks that path -- see docs/v2-plan.md Phase 2. Those stages become guarded
// atomic rules and this file's global `stall` disappears rather than being
// carried forward and renamed. The pieces that make it possible -- the prefix
// accumulator, the split register file, the separate jump latch -- are all
// here already.

`include "k2g_types.svh"

module k2g_core
  import k2g_pkg::*;
  import k2g_types::*;
#(
    // The size of the address space, which is architecture rather than
    // configuration: it is where ADDR_OUT_OF_RANGE begins (spec 8), so the
    // emulator has to agree with it exactly and the cosimulation is what
    // checks that they do.
    //
    // 8 MB is the in-package PSRAM, flat at address 0, which is all of memory
    // in v2 -- no TCM and no two-region decode.
    parameter int MEM_BYTES = 8 * 1024 * 1024
) (
    input  logic        clk,
    input  logic        rst_n,

    // Instruction fetch port. Read-only; the code point is the low halfword
    // of each response.
    k2g_membus.master   ibus,

    // Data port. A channel rather than a fixed one-cycle access: what answers
    // it is BSRAM today and a write-back data cache over PSRAM later, and the
    // core must not care which.
    k2g_membus.master   dbus,

    // UART, through the CSP port space.
    output logic        uart_tx_valid,
    output logic [7:0]  uart_tx_data,
    input  logic        uart_tx_ready,
    input  logic        uart_rx_valid,
    input  logic [7:0]  uart_rx_data,
    output logic        uart_rx_take,

    output logic [31:0] gpio_out,

    // Instruction retirement. See the note further down: this is what the
    // lockstep cosimulation compares against, rather than reaching into the
    // core for whatever signals happen to mean "done" today.
    output logic        retire_valid,
    output retire_t     retire,

    // Machine status, for the LEDs and the halt-time dump.
    output logic        halted,
    output logic        faulted,
    output logic [4:0]  fault_cause_o,
    output logic [31:0] fault_addr_o,
    output logic [31:0] fault_info_o,
    output logic [63:0] cycle_count_o
);

  // ---- fetch -------------------------------------------------------------
  // Fetch asks the bus for one code point at a time and the answers arrive
  // whenever the bus gets to them -- next cycle from BSRAM, tens of cycles
  // from an instruction cache that misses. They land in an elastic buffer that
  // decode drains at its own rate.
  //
  // ISSUE IS CREDIT-LIMITED, NOT ACKNOWLEDGED. Nothing is requested unless the
  // F->D buffer is guaranteed to have room for the answer, because the bus has
  // no response backpressure by design (k2g_membus.sv). Waiting for each
  // answer before asking again would be simpler and would halve fetch
  // throughput: BSRAM answers in one cycle, so a request must go out in the
  // same cycle the previous answer arrives to keep one code point per cycle.
  // CREDIT MUST COVER THE ROUND TRIP, NOT JUST THE BUFFER.
  //
  // A code point holds a credit from the cycle it is requested until decode
  // consumes it: issue at k, the bus answers at k+1, it appears at the
  // buffer's output at k+2, and decode takes it at k+2. Three cycles of
  // occupancy. Sustained throughput is therefore credit/3 code points per
  // cycle, so a credit of 2 caps fetch at 0.67 -- decode can never be fed
  // every cycle no matter how fast the memory is.
  //
  // That single number was responsible for three separate symptoms: a CPI of
  // 3.3 to 5.7, X sitting empty 70% of the time, and instructions never
  // retiring back-to-back -- which in turn made the W->X forwarding
  // impossible to exercise or test at all.
  //
  // Two chained skid buffers give depth 4. Chaining rather than widening
  // reuses a module that already has its own assertions and mutants, and the
  // extra cycle of latency costs nothing here: throughput depends on
  // occupancy, not on latency.
  localparam int F2D_DEPTH = 4;

  logic [31:0] pc;
  logic [2:0]  inflight;     // requested, not yet handed to decode
  logic [2:0]  outstanding;  // requested, not yet answered
  logic [2:0]  drop;         // answers still owed to a stream we walked away from
  logic        redirect;
  logic [31:0] redirect_pc;
  logic        stall;
  logic        d_block;   // D is holding a uop X will not take
  logic        take_uop;  // X fires this cycle

  // X's multi-cycle states, declared here because the CSP request has to know
  // that something else is already holding the instruction.
  logic        mem_pending, mulw_pending;

  // Declared here rather than with the rest of the sequential state because
  // the bus requests below have to know the machine is stopped.
  logic        halted_r, faulted_r;

  // A pure function of state. Nothing here looks at `req_ready` (rule 3) or at
  // `redirect`, which would drag the data bus's ready into the fetch path.
  //
  // `rst_n` IS IN HERE, and it is not defensive tidiness. `halted_r` and
  // `inflight` are both zero while the core is held, so without it a core in
  // reset offers a fetch every cycle and a slave that is not in reset accepts
  // them -- while `issue_wp`, `outstanding` and `inflight` are all pinned at
  // zero, so the core records none of them. Every one of those requests is a
  // response the core will receive after release and pair with an
  // `issue_addr` entry it never wrote, which corrupts `isa` rather than the
  // code point: wrong fault addresses and wrong branch targets, from
  // instructions that decode perfectly.
  //
  // It was harmless while every slave shared the core's reset and dropped
  // everything with it -- `k2g_mem_slow` still does. It stopped being true in
  // `k2g_soc` the moment memory became PSRAM: the boot copier needs the bus
  // live while the core is still held, so the memory side comes out of reset
  // first, by the whole length of the copy. `tb_soc` measures it.
  //
  // The data port needs no such guard -- `mem_access` requires `uop_valid`,
  // which comes from the D->X register and is reset with everything else.
  assign ibus.req_valid = rst_n && !halted_r && (inflight < 3'(F2D_DEPTH));
  assign ibus.req.addr  = pc;
  assign ibus.req.we    = 4'b0000;
  assign ibus.req.wdata = 32'd0;

  wire logic if_issue  = ibus.req_valid && ibus.req_ready;
  wire logic if_answer = ibus.rsp_valid;

  // Responses are in order, so the address that belongs to each one is simply
  // the oldest still-unanswered request. FOUR entries, matching the credit:
  // on a slow bus every credit can be outstanding at once, and a queue shorter
  // than the credit wraps and pairs code points with the wrong addresses --
  // which corrupts `isa` rather than the instruction, so it would surface as
  // wrong fault addresses and wrong branch targets, not as a decode failure.
  logic [31:0] issue_addr [0:3];
  logic [1:0]  issue_wp, issue_rp;

  // ---- F->D buffer -------------------------------------------------------
  // Payload is the code point and the address it came from. The address has to
  // travel with it: `isa` is computed from it, and by the time an instruction
  // completes, fetch has long since moved on.
  k2g_chan #(.WIDTH(48)) f2d_in ();
  k2g_chan #(.WIDTH(48)) f2d ();

  // An answer belonging to an abandoned stream is discarded here rather than
  // buffered. `valid` is a pulse and never has to be held, because the credit
  // above guarantees the buffer has room -- which is the only reason a
  // response with no `ready` can drive a channel at all.
  assign f2d_in.valid = if_answer && (drop == 3'd0);
  assign f2d_in.data  = {issue_addr[issue_rp], ibus.rsp_data[15:0]};

  k2g_chan #(.WIDTH(48)) f2d_mid ();

  k2g_skid #(.WIDTH(48)) u_f2d_a (
      .clk  (clk),
      .rst_n(rst_n),
      .flush(redirect),
      .up   (f2d_in),
      .down (f2d_mid)
  );

  k2g_skid #(.WIDTH(48)) u_f2d_b (
      .clk  (clk),
      .rst_n(rst_n),
      .flush(redirect),
      .up   (f2d_mid),
      .down (f2d)
  );

  wire logic [31:0] pc_d     = f2d.data[47:16];
  wire logic [15:0] cp_d     = f2d.data[15:0];
  wire logic        cp_valid = f2d.valid;

  // `f2d.ready` is driven by the D stage below, where the guard that decides
  // whether a code point can be consumed lives.
  wire logic f2d_take = f2d.valid && f2d.ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc          <= 32'd0;
      inflight    <= 3'd0;
      outstanding <= 3'd0;
      drop        <= 3'd0;
      issue_wp    <= 2'd0;
      issue_rp    <= 2'd0;
    end else begin
      if (if_issue) begin
        issue_addr[issue_wp] <= pc;
        issue_wp             <= issue_wp + 2'd1;
        pc                   <= pc + 32'd2;
      end
      if (if_answer) issue_rp <= issue_rp + 2'd1;

      outstanding <= outstanding + (if_issue ? 3'd1 : 3'd0)
                                 - (if_answer ? 3'd1 : 3'd0);

      if (redirect) begin
        // Everything already asked for belongs to the old stream, including a
        // request issued this very cycle -- it used the old `pc`. The buffer
        // is flushed, but answers already in the bus cannot be recalled, so
        // they are counted and thrown away as they arrive.
        pc       <= redirect_pc;
        inflight <= 3'd0;
        drop     <= outstanding + (if_issue ? 3'd1 : 3'd0)
                                - (if_answer ? 3'd1 : 3'd0);
      end else begin
        inflight <= inflight + (if_issue  ? 3'd1 : 3'd0)
                             - (f2d_take  ? 3'd1 : 3'd0);
        if (if_answer && (drop != 3'd0)) drop <= drop - 3'd1;
      end
    end
  end

  // ---- D: decode ---------------------------------------------------------
  // A rule with one guard: there is a code point, the machine is running, and
  // if this code point finishes an instruction then X has somewhere to put it.
  // Nothing else can hold decode up -- in particular a stalled execute stage no
  // longer reaches back into the accumulator, which is what the old global
  // `stall` did.
  uop_t duop;                 // combinational, from the accumulator
  logic duop_valid;           // this code point completes an instruction
  logic decode_en;

  // Deliberately NOT gated by anything downstream of the decoder's own output:
  // the decoder is combinational, and routing execute's state into `cp_valid`
  // closes a loop through cp_valid -> uop_valid -> the CSP request -> stall.
  // `hold` freezes the accumulator without touching that output.
  assign decode_en = cp_valid && !halted_r;

  k2g_decode u_decode (
      .clk      (clk),
      .rst_n    (rst_n),
      .cp       (cp_d),
      .cp_valid (decode_en),
      .flush    (redirect),
      .hold     (d_block),
      .accept   (),
      .uop      (duop),
      .uop_valid(duop_valid)
  );

  // Address of the first code point of the instruction being completed.
  // `size_bytes` counts every code point including the current one, so the
  // start is that many bytes back. Displacements are relative to this, not to
  // the DISPI code point (spec 6.2).
  wire logic [31:0] isa_d = pc_d - (duop.size_bytes - 32'd2);

  // ---- D -> X ------------------------------------------------------------
  // One entry, not a skid. The backward `ready` path is short here -- X's
  // occupancy to D's hold -- and a skid on a ~210-bit uop would cost twice the
  // flops for throughput this stage cannot use, since D produces at most one
  // uop per code point anyway. Put a skid here only if timing says to.
  //
  // `isa` travels with the uop. It is computed from `pc_d`, which belongs to
  // the code point still sitting in the F->D buffer, and by the time X runs
  // that buffer has moved on.
  uop_t        uop;
  logic        uop_valid;
  logic [31:0] isa;

  // X has room when it is empty, or is about to empty by firing.
  wire logic x_ready = !uop_valid || take_uop;

  // D is blocked only when it is holding a finished instruction that X will
  // not take. A partial prefix chain never blocks: it has nowhere to go yet.
  assign d_block   = duop_valid && !x_ready;
  assign f2d.ready = !d_block && !halted_r;

  wire logic d_emit = f2d.valid && !d_block && !halted_r && duop_valid;

  always_ff @(posedge clk) begin
    if (!rst_n || redirect) begin
      // A redirect discards whatever D just produced along with the buffer and
      // the accumulator: it was fetched down the path not taken.
      uop_valid <= 1'b0;
    end else if (d_emit) begin
      uop       <= duop;
      isa       <= isa_d;
      uop_valid <= 1'b1;
    end else if (take_uop) begin
      uop_valid <= 1'b0;
    end
  end

  // ---- register file -----------------------------------------------------
  logic [4:0]  ra_addr, rb_addr, rc_addr, w_addr;
  logic [31:0] ra_value, rb_value, rc_value, w_value;
  logic [2:0]  ra_tag, rb_tag, rc_tag, w_tag;
  logic        ra_overflow, rb_overflow, rc_overflow;
  logic        ra_flag, rb_flag, rc_flag;
  logic        we_value, we_tag, we_overflow, we_flag;
  logic        w_overflow, w_flag;

  // What X computed this cycle; it becomes the W packet at the next edge.
  logic [4:0]  nw_addr;
  logic [31:0] nw_value;
  logic [2:0]  nw_tag;
  logic        nw_overflow, nw_flag;
  logic        nwe_value, nwe_tag, nwe_overflow, nwe_flag;
  logic        w_active;    // an instruction occupies W (even if it writes nothing)

  k2g_regfile u_rf (.*);

  // The read addresses stay raw register outputs. That is load-bearing beyond
  // tidiness: GowinSynthesis retimes these flops into the value array's BSRAM
  // address ports (see docs/v2-plan.md), and it can only do that while nothing
  // combinational sits between the register and the read. Forwarding therefore
  // muxes read DATA, never addresses.
  assign ra_addr = uop.dst;
  assign rb_addr = uop.src;
  assign rc_addr = uop.cond_reg;

  // ---- forwarding W -> X -------------------------------------------------
  // The register file reads before it writes, so an instruction in X cannot
  // see the write its immediate predecessor is committing out of W this very
  // cycle. There is exactly one source to forward from -- W is the only place
  // a write is in flight -- which keeps this a mux rather than a priority
  // network.
  //
  // PER FIELD, NOT PER REGISTER. A comparison writes only `flag_bit`, an
  // arithmetic op writes only `overflow`, and a copy writes everything
  // (k2g_regfile.sv). Forwarding a whole register on any write would overwrite
  // the three fields the instruction in W is not touching with whatever its
  // packet happens to carry. So each field is forwarded on its own enable.
  //
  // The tag matters most and is the least obvious: a store takes its width
  // from the SOURCE register's tag (spec 5.3), so an unforwarded tag does not
  // corrupt a value, it silently writes the wrong number of bytes.
  wire logic hit_a = we_value | we_tag | we_overflow | we_flag;   // W is writing
  wire logic ma    = hit_a && (w_addr == ra_addr);
  wire logic mb    = hit_a && (w_addr == rb_addr);
  wire logic mc    = hit_a && (w_addr == rc_addr);

  wire logic [31:0] xa_value = (ma && we_value)    ? w_value    : ra_value;
  wire logic [31:0] xb_value = (mb && we_value)    ? w_value    : rb_value;
  wire logic [31:0] xc_value = (mc && we_value)    ? w_value    : rc_value;
  wire logic [2:0]  xa_tag   = (ma && we_tag)      ? w_tag      : ra_tag;
  wire logic [2:0]  xb_tag   = (mb && we_tag)      ? w_tag      : rb_tag;
  wire logic [2:0]  xc_tag   = (mc && we_tag)      ? w_tag      : rc_tag;
  wire logic        xa_ovf   = (ma && we_overflow) ? w_overflow : ra_overflow;
  wire logic        xb_ovf   = (mb && we_overflow) ? w_overflow : rb_overflow;
  wire logic        xc_ovf   = (mc && we_overflow) ? w_overflow : rc_overflow;
  // The flag and predicate paths below are believed UNREACHABLE at one code
  // point per cycle, and are kept because that is a property of the front end
  // rather than of the ISA. Every instruction that reads a flag carries a
  // prefix -- XCP/XCN to predicate, FLAG for a flag-wise logic op -- so it is
  // at least two code points, and its execute cycle therefore lands at least
  // two after its producer's, by which time the producer has committed and the
  // register file already has the value. A wider fetch closes that gap and
  // makes them live again. Mutating them is not detectable today, so
  // mutants.sh does not claim to.
  wire logic        xa_flag  = (ma && we_flag)     ? w_flag     : ra_flag;
  wire logic        xb_flag  = (mb && we_flag)     ? w_flag     : rb_flag;
  wire logic        xc_flag  = (mc && we_flag)     ? w_flag     : rc_flag;

  // ---- predication -------------------------------------------------------
  // Zero and negative are computed from the register value on demand; there is
  // no global condition register (spec 7).
  logic cond_raw, cond_met;
  always_comb begin
    unique case (uop.cond)
      CCK_OVERFLOW: cond_raw = xc_ovf;
      CCK_FLAG:     cond_raw = xc_flag;
      CCK_ZERO:     cond_raw = (xc_value == 32'd0);
      CCK_NEGATIVE: cond_raw = xc_value[31];
      CCK_POSITIVE: cond_raw = (xc_value != 32'd0) && !xc_value[31];
      default:      cond_raw = 1'b1;
    endcase
    cond_met = (uop.cond == CCK_NONE) ? 1'b1 : (cond_raw ^ uop.cond_invert);
  end

  // ---- reserved F32 operands ---------------------------------------------
  // `F32` is reserved (spec 11), so reading a register that carries the tag
  // faults. The two opcodes that would *create* one, `LDF32` and `LLC_F32`,
  // already fault in decode; this covers the remaining way to get the tag,
  // which is `RDT rd, f32`.
  //
  // Expressed as "which read ports does this uop architecturally use", because
  // that is what the check physically is: a comparison against `RDT_F32` on a
  // read port. The ports themselves read every cycle regardless -- port A is
  // `uop.dst` and port B is `uop.src` -- so an unqualified check would fault on
  // registers the instruction never looks at.
  //
  // Destination-only operands are exempt, which is what leaves `RDT rd, u32`
  // as the way back out of the tag. The emulator's `check_no_f32_operands`
  // (emu/src/interp.rs) enumerates the same set, in the same A-before-B order,
  // so `FAULT_INFO` agrees when both operands carry the tag.
  logic reads_a, reads_b;
  always_comb begin
    reads_a = 1'b0;
    reads_b = 1'b0;
    unique case (uop.kind)
      UOP_COPY:      begin                 reads_b = 1'b1; end
      UOP_LOAD:      begin                 reads_b = 1'b1; end
      UOP_CSP_LOAD:  begin                 reads_b = 1'b1; end
      // Extract writes the whole destination; insert merges into it (spec 5.8).
      UOP_BEXT:      begin                 reads_b = 1'b1; end
      UOP_STORE:     begin reads_a = 1'b1; reads_b = 1'b1; end
      UOP_CSP_STORE: begin reads_a = 1'b1; reads_b = 1'b1; end
      UOP_BINS:      begin reads_a = 1'b1; reads_b = 1'b1; end
      UOP_UNARY:     begin reads_a = 1'b1;                 end
      UOP_ARITH,
      UOP_LOGIC,
      UOP_SHIFT,
      UOP_CMP:       begin reads_a = 1'b1; reads_b = !uop.use_imm; end
      // The link register is written, not read.
      UOP_PREP_JUMP: begin reads_a = (uop.jump_kind != JT_REL_IMM); end
      // NOP, PUT_IMM, SET_TAG, PERFORM_JUMP, HALT and FAULT read no register.
      // `uop_fault` clears `dst` and `src` anyway, so a decode fault reports
      // its own cause rather than a tag it never read.
      default: ;
    endcase
  end

  wire logic f32_a    = reads_a && (xa_tag == RDT_F32);
  wire logic f32_b    = reads_b && (xb_tag == RDT_F32);
  // The predicate register is read whatever the predicate decides, so its tag
  // is checked outside the `cond_met` gate below.
  wire logic f32_cond = (uop.cond != CCK_NONE) && (xc_tag == RDT_F32);

  // The fault suppresses the writeback on its own (`detect_valid` gates it),
  // but a request leaves the core before the fault block is consulted, so the
  // two request paths have to be gated here. A store or a CSP write is not
  // recoverable after the fact: the byte is on the bus, or out of the UART.
  wire logic f32_any  = f32_a || f32_b || f32_cond;

  // ---- functional units --------------------------------------------------
  logic [31:0] alu_a, alu_b;
  logic [2:0]  alu_a_tag, alu_b_tag;
  logic [31:0] arith_result, logic_result, unary_result;
  logic        arith_overflow, cmp_result;

  // An immediate carries no tag of its own, so it takes the left operand's
  // interpretation (spec 5.9).
  assign alu_a     = xa_value;
  assign alu_b     = uop.use_imm ? uop.imm : xb_value;
  assign alu_a_tag = xa_tag;
  assign alu_b_tag = uop.use_imm ? xa_tag : xb_tag;

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
      .value       (xa_value),
      .src         (xb_value),
      .amount      (uop.use_imm ? uop.imm[4:0] : xb_value[4:0]),
      .shift_op    (uop.shift_op),
      .bm_start    (uop.bm_start),
      .bm_span     (uop.bm_span),
      .shift_result(shift_result),
      .bext_result (bext_result),
      .bins_result (bins_result)
  );

  // Widening multiply. Full 64-bit product; the high half goes to the UTO
  // register on a second cycle so the value array keeps one write port.
  wire logic [63:0] product = xa_value * alu_b;

  // ---- memory access -----------------------------------------------------
  wire logic        is_load     = (uop.kind == UOP_LOAD);
  wire logic        is_store    = (uop.kind == UOP_STORE);
  wire logic [31:0] load_addr   = xb_value + uop.imm;
  wire logic [31:0] store_addr  = xa_value + uop.imm;
  wire logic [31:0] access_addr = is_load ? load_addr : store_addr;

  // Store width comes from the SOURCE register's tag, not the opcode
  // (spec 5.3).
  wire logic [2:0] access_tag   = is_load ? uop.datakind : xb_tag;
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
      3'd1:    store_data = {4{xb_value[7:0]}};
      3'd2:    store_data = {2{xb_value[15:0]}};
      default: store_data = xb_value;
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
  // A CSP access has SIDE EFFECTS -- it hands a byte to the transmitter, or
  // consumes one from the receiver -- so it must not be issued merely because
  // the instruction is sitting in X. It has to be issued only when nothing
  // else is holding that instruction back.
  //
  // Before decode had its own stage this was safe by accident: a stalled
  // execute stage froze the decoder, so the next instruction did not exist
  // yet. Now D runs ahead, and a CSP store parked behind a pending load sent
  // its byte during the wait and sent it again on retiring. `fib` emitted five
  // UART bytes against the emulator's four, with every register still
  // matching -- caught only under injected latency.
  //
  // It cannot be gated on `take_uop`: that closes the loop this file's `hold`
  // input already exists to avoid, csp_req -> csp_stall -> stall -> take_uop.
  // So it is gated on every OTHER reason X might not fire. For a CSP uop the
  // data-bus term is always false (it is not a load or a store), which leaves
  // exactly these two.
  wire logic csp_req      = uop_valid && cond_met && !halted_r && !f32_any &&
                            !mem_pending && !mulw_pending &&
                            (is_csp_load || is_csp_store);

  logic [31:0] csp_rdata;
  logic        csp_bad_port;
  logic        csp_stall;
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
      .port           (is_csp_store ? xa_value : xb_value),
      .wdata          (xb_value),
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
      .gpio_out       (gpio_out)
  );

  // ---- multi-cycle sequencing --------------------------------------------
  // A load needs the memory read result, which arrives a cycle later; a
  // widening multiply needs a second cycle to write the high half.
  logic [4:0]  pend_dst;
  logic [2:0]  pend_tag;
  logic [31:0] pend_lo;
  logic [1:0]  pend_addr_lo;

  assign     take_uop   = uop_valid && !stall && !halted_r;
  wire logic start_load = take_uop && cond_met && is_load &&
                          !misaligned && !out_of_range;
  wire logic start_mulw = take_uop && cond_met && (uop.kind == UOP_ARITH) &&
                          (uop.arith_op == ARITH_MUL) && uop.uto_valid;

  // ---- data bus request --------------------------------------------------
  // `req_valid` is deliberately NOT qualified by `!stall`, and this is the
  // one place in the core where that matters. `stall` includes "my request
  // has not been accepted", so a `req_valid` that consulted the stall would
  // consult `req_ready` through it -- the rule 3 violation in k2g_chan.sv,
  // and the same shape as the loop the decoder's `hold` input exists to
  // avoid. What the request depends on is the decoded instruction and
  // nothing else.
  //
  // `mem_pending` gates it because this master keeps at most one request
  // outstanding, which is what lets the bus have no response backpressure
  // (see k2g_membus.sv).
  wire logic mem_access = uop_valid && cond_met && (is_load || is_store) &&
                          !misaligned && !out_of_range && !halted_r && !f32_any &&
                          !mem_pending && !mulw_pending;

  assign dbus.req_valid = mem_access;
  assign dbus.req.addr  = access_addr;
  assign dbus.req.we    = is_store ? store_we : 4'b0000;
  assign dbus.req.wdata = store_data;

  // A CSP access that cannot complete holds the instruction instead of
  // retiring it, and so does a memory access the bus has not accepted or not
  // answered. Because nothing commits, the architectural state after each
  // retired instruction is unchanged -- the cosimulation cannot see a stall,
  // which is what makes variable-latency memory invisible to it.
  //
  // `mem_pending` covers the whole wait INCLUDING the cycle the response
  // arrives, not just the cycles before it. The response cycle is when the
  // load writes back, and the value array has exactly one write port
  // (k2g_regfile.sv) -- letting the next instruction retire alongside would
  // put two writes on it.
  assign stall = mem_pending || mulw_pending || csp_stall ||
                 (mem_access && !dbus.req_ready);

  // ---- jump latch --------------------------------------------------------
  logic [31:0] nisa;
  logic        nisa_valid;

  logic [31:0] jump_target;
  always_comb begin
    unique case (uop.jump_kind)
      JT_REL_REG: jump_target = isa + xa_value;   // NOT shifted (spec 6.2)
      JT_ABS_REG: jump_target = xa_value;
      default:    jump_target = isa + uop.imm;
    endcase
  end

  // ---- fault detection ---------------------------------------------------
  fault_e      detected;
  logic        detect_valid;
  logic [31:0] detect_info;

  always_comb begin
    detected     = FAULT_NONE;
    detect_valid = 1'b0;
    detect_info  = 32'd0;

    if (take_uop && f32_cond) begin
      detected     = FAULT_FP_UNIMPLEMENTED;
      detect_valid = 1'b1;
      detect_info  = {27'd0, uop.cond_reg};
    end else if (take_uop && cond_met) begin
      if (uop.kind == UOP_FAULT) begin
        detected     = uop.fault;
        detect_valid = 1'b1;
        // The offending code point, carried through decode in `imm`.
        detect_info  = uop.imm;
      end else if (f32_a || f32_b) begin
        // Before the access checks below: the emulator rejects the operand
        // before the instruction executes, so an `F32` address register faults
        // as FP rather than as whatever address it would have computed.
        detected     = FAULT_FP_UNIMPLEMENTED;
        detect_valid = 1'b1;
        detect_info  = f32_a ? {27'd0, uop.dst} : {27'd0, uop.src};
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
        detect_info  = is_csp_store ? xa_value : xb_value;
      end else if ((uop.kind == UOP_PREP_JUMP) && jump_target[0]) begin
        // Rejected by the instruction that computed the target, not by the
        // `TC` that would have taken it (spec 6.4). `do_prep_jump` is already
        // gated on `!detect_valid`, so the latch keeps whatever it held and
        // the link register is not written.
        detected     = FAULT_MISALIGNED_FETCH;
        detect_valid = 1'b1;
        detect_info  = jump_target;
      end
    end
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

  // A load returns whenever the bus answers; everything else is immediate.
  wire logic        load_done    = mem_pending && dbus.rsp_valid;
  wire logic [31:0] load_shifted = dbus.rsp_data >> {pend_addr_lo, 3'b000};
  wire logic [31:0] load_value   = rdt_normalize(load_shifted, pend_tag);

  always_comb begin
    nwe_value    = 1'b0;
    nwe_tag      = 1'b0;
    nwe_overflow = 1'b0;
    nwe_flag     = 1'b0;
    nw_addr      = uop.dst;
    nw_value     = 32'd0;
    nw_tag       = uop.datakind;
    nw_overflow  = 1'b0;
    nw_flag      = 1'b0;
    wb_value    = 32'd0;
    wb_tag      = RDT_U32;

    if (load_done) begin
      // The cycle the bus answers a load.
      nw_addr   = pend_dst;
      nw_value  = load_value;
      nw_tag    = pend_tag;
      nwe_value = 1'b1;
      nwe_tag   = 1'b1;
    end else if (mulw_pending) begin
      // Second cycle of a widening multiply: the LOW half, written last so
      // that when both halves name the same register the low half wins,
      // matching the emulator (spec 5.5). The tag written back is the
      // destination's original tag -- a widening multiply leaves the low
      // destination's tag alone, and restoring it here also produces the
      // right answer in the aliased case, where cycle one set it to U32.
      nw_addr   = pend_dst;
      nw_value  = pend_lo;
      nw_tag    = pend_tag;
      nwe_value = 1'b1;
      nwe_tag   = 1'b1;
    end else if (take_uop && cond_met && !detect_valid) begin
      unique case (uop.kind)
        UOP_PUT_IMM: begin
          // Normalized to the tag, so a register's bits always match what its
          // tag claims (spec 5.1, 1.1.1).
          nw_value     = rdt_normalize(uop.imm, uop.datakind);
          nw_tag       = uop.datakind;
          nwe_value    = 1'b1;
          nwe_tag      = 1'b1;
          nwe_overflow = 1'b1;
          nwe_flag     = 1'b1;   // put-constant clears both flags
        end
        UOP_SET_TAG: begin
          // RDT re-normalizes, which is what makes LD8 + RDT S8 a
          // sign-extending byte load (spec 5.10).
          nw_value  = rdt_normalize(xa_value, uop.datakind);
          nw_tag    = uop.datakind;
          nwe_value = 1'b1;
          nwe_tag   = 1'b1;
        end
        UOP_COPY: begin
          // A full move: value, tag and both flags (spec 5.2).
          nw_value     = xb_value;
          nw_tag       = xb_tag;
          nw_overflow  = xb_ovf;
          nw_flag      = xb_flag;
          nwe_value    = 1'b1;
          nwe_tag      = 1'b1;
          nwe_overflow = 1'b1;
          nwe_flag     = 1'b1;
        end
        UOP_CSP_LOAD: begin
          nw_value  = rdt_normalize(csp_rdata, uop.datakind);
          nw_tag    = uop.datakind;
          nwe_value = 1'b1;
          nwe_tag   = 1'b1;
        end
        UOP_ARITH: begin
          if (uop.uto_valid && (uop.arith_op == ARITH_MUL)) begin
            // Widening multiply, first cycle: the HIGH half into the UTO
            // register, tagged U32. The low half follows next cycle.
            nw_addr   = uop.uto_reg;
            nw_value  = product[63:32];
            nw_tag    = RDT_U32;
            nwe_value = 1'b1;
            nwe_tag   = 1'b1;
            // A widening multiply writes no overflow; plain MUL does.
          end else begin
            nw_value     = (uop.arith_op == ARITH_MUL) ? product[31:0] : arith_result;
            nwe_value    = 1'b1;
            nw_overflow  = (uop.arith_op == ARITH_MUL) ? (|product[63:32])
                                                      : arith_overflow;
            nwe_overflow = 1'b1;
          end
        end
        UOP_LOGIC: begin
          if (uop.on_flags) begin
            unique case (uop.logic_op)
              LOGIC_AND: nw_flag = xa_flag & xb_flag;
              LOGIC_OR:  nw_flag = xa_flag | xb_flag;
              default:   nw_flag = xa_flag ^ xb_flag;
            endcase
            nwe_flag = 1'b1;
          end else begin
            nw_value  = logic_result;
            nwe_value = 1'b1;
          end
        end
        UOP_SHIFT: begin
          nw_value  = rdt_normalize(shift_result, xa_tag);
          nwe_value = 1'b1;
        end
        UOP_BEXT: begin
          // Extract writes the whole register; insert writes only the value
          // (spec 5.8).
          nw_value     = bext_result;
          nw_tag       = RDT_U32;
          nw_overflow  = 1'b0;
          nw_flag      = 1'b0;
          nwe_value    = 1'b1;
          nwe_tag      = 1'b1;
          nwe_overflow = 1'b1;
          nwe_flag     = 1'b1;
        end
        UOP_BINS: begin
          nw_value  = bins_result;
          nwe_value = 1'b1;
        end
        UOP_CMP: begin
          // Comparisons write only flag_bit of the left operand (spec 5.9).
          nw_flag  = cmp_result;
          nwe_flag = 1'b1;
        end
        UOP_UNARY: begin
          if (uop.on_flags) begin
            nw_flag  = ~xa_flag;
            nwe_flag = 1'b1;
          end else begin
            nw_value  = rdt_normalize(unary_result, xa_tag);
            nwe_value = 1'b1;
          end
        end
        UOP_PREP_JUMP: begin
          // The link register points at the code point after the DISP, which
          // in the usual idiom is the TC itself (spec 6.3).
          if (uop.uto_valid) begin
            nw_addr   = uop.uto_reg;
            nw_value  = isa + uop.size_bytes;
            nw_tag    = RDT_U32;
            nwe_value = 1'b1;
            nwe_tag   = 1'b1;
          end
        end
        default: ;
      endcase
    end
  end

  // ---- retirement --------------------------------------------------------
  // THE CONTRACT: `retire_valid` is high in the cycle AFTER every
  // architectural write belonging to an instruction has committed. Sample the
  // register file while it is high and you are looking at exactly the state
  // the emulator has after being stepped once.
  //
  // This exists so the testbench does not have to know how the core is built.
  // It used to reach in for `take_uop`, `mem_pending` and `mulw_pending` and
  // open-code the wait for a second cycle, which pins it to a two-stage
  // machine -- and that testbench is the only thing that makes rebuilding the
  // machine safe. The contract is worded to survive a pipeline: "after the
  // last write commits" stays meaningful however many stages there are.
  //
  // A load and a widening multiply commit their last write on their second
  // cycle; everything else commits on its first. The three terms below are
  // mutually exclusive, because both pending flags assert `stall` and
  // `take_uop` requires `!stall`.
  wire logic retire_now = (take_uop && !start_load && !start_mulw) ||
                          load_done || mulw_pending;

  // Captured at `take_uop`, not at retirement. `isa` is valid only in the
  // cycle the instruction is taken: during a second cycle the front end has
  // already presented the next code point, so `pc_d`, `imem_data` and
  // therefore `uop.size_bytes` have all moved on. Recomputing `isa` at
  // retirement names the wrong instruction -- exactly the class of confusion
  // this port exists to remove.
  retire_t taken;

  always_comb begin
    taken          = '0;
    taken.isa      = isa;
    taken.kind     = uop.kind;
    taken.dst      = uop.dst;
    taken.src      = uop.src;
    taken.imm      = uop.imm;
    taken.cond_met = cond_met;

    // The latch AFTER this instruction, mirroring the sequential update below.
    // Priming and performing are different uop kinds, so they cannot both
    // happen at once.
    taken.nisa       = do_prep_jump ? jump_target : nisa;
    taken.nisa_valid = do_prep_jump ? 1'b1
                     : do_perform   ? 1'b0
                                    : nisa_valid;

    // Only ever sampled under `take_uop`, which `detect_valid` already
    // implies.
    if (detect_valid)                            taken.cause = detected;
    else if (cond_met && (uop.kind == UOP_HALT)) taken.cause = FAULT_HALT_INSN;
    else                                         taken.cause = FAULT_NONE;
  end

  retire_t pend_retire;
  retire_t w_retire;      // the instruction sitting in W

  // Deliberately NOT inside the `!halted_r` guard below: a faulting
  // instruction retires on the very edge that halts the machine, so the pulse
  // has to be produced then -- and cleared on the next edge, which a halted
  // core would otherwise never reach.
  // ---- W: commit ---------------------------------------------------------
  // X computes a writeback packet; W is what actually drives the register
  // file's write port. That is the split -- X's cycle now ends at a register
  // instead of running on into the array.
  //
  // Not gated by `halted_r`. A faulting instruction stops the machine on the
  // same edge that loads W with its predecessor's packet, and that predecessor
  // committed before the fault was known: precision means the FAULTING
  // instruction writes nothing, not that the one before it loses its result.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      we_value    <= 1'b0;
      we_tag      <= 1'b0;
      we_overflow <= 1'b0;
      we_flag     <= 1'b0;
      w_active    <= 1'b0;
      w_retire    <= '0;
    end else begin
      we_value    <= nwe_value;
      we_tag      <= nwe_tag;
      we_overflow <= nwe_overflow;
      we_flag     <= nwe_flag;
      w_addr      <= nw_addr;
      w_value     <= nw_value;
      w_tag       <= nw_tag;
      w_overflow  <= nw_overflow;
      w_flag      <= nw_flag;

      // Retirement follows the commit by one more cycle now: the packet is in
      // W during one cycle and lands in the register file at the edge out of
      // it. Sampling any earlier would compare against state not yet written.
      w_active    <= retire_now;
      w_retire    <= take_uop ? taken : pend_retire;
      if (take_uop) pend_retire <= taken;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      retire_valid <= 1'b0;
      retire       <= '0;
    end else begin
      retire_valid <= w_active;
      retire       <= w_retire;
    end
  end

  // ---- sequential state --------------------------------------------------
  assign halted        = halted_r;
  assign faulted       = faulted_r;
  assign fault_cause_o = fault_cause;
  assign fault_addr_o  = fault_addr;
  assign fault_info_o  = fault_info;
  assign cycle_count_o = cycle_count;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
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
      // Fetch sequencing lives in its own block above; this one is execute.

      // Second cycles complete here. A load's does not: `mem_pending` is
      // cleared by the bus answering, however many cycles that takes, rather
      // than unconditionally on the next edge.
      if (load_done) mem_pending <= 1'b0;
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
        pend_tag     <= xa_tag;   // the low destination keeps its own tag
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
