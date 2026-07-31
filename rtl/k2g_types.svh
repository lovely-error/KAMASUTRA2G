// Shared K2G types: the decoded micro-operation and fault causes.
//
// Hand-written, unlike k2g_pkg.sv which is generated from emu/src/insns.rs.
// This file describes the *internal* decode form -- the RTL analogue of
// `CanonInsn` in emu/src/interp.rs -- rather than the instruction encoding.
//
// Expressed as packed structs and enums because rtl/sv-probe measured
// GowinSynthesis accepting both (see docs/gowin-sv-support.md); the fallback of
// flat vectors with localparam bit offsets is not needed.

`ifndef K2G_TYPES_SVH
`define K2G_TYPES_SVH

package k2g_types;

  import k2g_pkg::*;

  // ---- Fault causes (docs/isa-spec.md 8) --------------------------------
  // Values match emu/src/fault.rs exactly; the cosimulation compares them.
  typedef enum logic [4:0] {
    FAULT_NONE                 = 5'h00,
    FAULT_ILLEGAL_OPCODE       = 5'h01,
    FAULT_ILLEGAL_PREFIX_COMBO = 5'h02,
    FAULT_PREFIX_CHAIN_TOO_LONG= 5'h03,
    FAULT_DIV_UNIMPLEMENTED    = 5'h04,
    FAULT_FP_UNIMPLEMENTED     = 5'h05,
    FAULT_MISALIGNED_LOAD      = 5'h06,
    FAULT_MISALIGNED_STORE     = 5'h07,
    FAULT_MISALIGNED_FETCH     = 5'h08,
    FAULT_ADDR_OUT_OF_RANGE    = 5'h09,
    FAULT_BAD_CSP_PORT         = 5'h0A,
    FAULT_BEXT_ZERO_SPAN       = 5'h0B,
    FAULT_DOUBLE_PRIME         = 5'h0D,
    FAULT_HALT_INSN            = 5'h1F
  } fault_e;

  // Longest legal prefix chain (spec 3). The emulator enforces the same bound.
  localparam int MAX_PREFIX_CHAIN = 7;

  // ---- Micro-operation kinds --------------------------------------------
  // One per arm of `CanonInsn`. Kept flat so the execute stage is a single
  // case rather than a nest of prefix conditionals -- all reinterpretation
  // (BMX+SHL becoming an extract, CSP+LD becoming a port read, and so on)
  // is resolved during decode.
  typedef enum logic [4:0] {
    UOP_NOP,
    UOP_PUT_IMM,
    UOP_SET_TAG,
    UOP_COPY,
    UOP_LOAD,
    UOP_STORE,
    UOP_CSP_LOAD,
    UOP_CSP_STORE,
    UOP_ARITH,
    UOP_LOGIC,
    UOP_SHIFT,
    UOP_BEXT,
    UOP_BINS,
    UOP_CMP,
    UOP_PREP_JUMP,
    UOP_PERFORM_JUMP,
    UOP_UNARY,
    UOP_HALT,
    UOP_FAULT
  } uop_kind_e;

  typedef enum logic [1:0] { ARITH_ADD, ARITH_SUB, ARITH_MUL, ARITH_DIV } arith_e;
  typedef enum logic [1:0] { LOGIC_AND, LOGIC_OR,  LOGIC_XOR }            logic_e;
  typedef enum logic [1:0] { SHIFT_LL,  SHIFT_LR,  SHIFT_AR }             shift_e;
  typedef enum logic [2:0] {
    CMP_EQ, CMP_NE, CMP_LT, CMP_GT, CMP_LE, CMP_GE
  } cmp_e;
  typedef enum logic [1:0] { UNARY_NOT, UNARY_NEG }                       unary_e;
  typedef enum logic [1:0] { JT_REL_IMM, JT_REL_REG, JT_ABS_REG }         jump_e;

  // ---- Condition codes ---------------------------------------------------
  typedef enum logic [2:0] {
    CCK_NONE,        // unpredicated
    CCK_OVERFLOW,
    CCK_FLAG,
    CCK_ZERO,
    CCK_NEGATIVE,
    CCK_POSITIVE
  } cond_kind_e;

  // ---- The decoded instruction ------------------------------------------
  //
  // The RTL analogue of `DecodedInsn`. Sized generously and left to synthesis
  // to prune: only a handful of fields are live for any given kind, and the
  // execute stage reads them under a single case on `kind`.
  typedef struct packed {
    uop_kind_e   kind;

    logic [4:0]  dst;      // arg1 for most forms
    logic [4:0]  src;      // arg2 for most forms
    logic [31:0] imm;      // immediate / offset / displacement
    logic        use_imm;  // src2 is `imm` rather than register `src`

    // Predication (spec 7). Resolved during the prefix's own decode cycle.
    cond_kind_e  cond;
    logic [4:0]  cond_reg;
    logic        cond_invert;

    // Operation selectors, valid per `kind`.
    arith_e      arith_op;
    logic_e      logic_op;
    shift_e      shift_op;
    cmp_e        cmp_op;
    unary_e      unary_op;
    jump_e       jump_kind;

    // Modifiers.
    logic        on_flags;   // FLAG prefix: operate on flag_bit
    logic [4:0]  uto_reg;    // link register / widening-multiply high half
    logic        uto_valid;
    logic [2:0]  datakind;   // rdt_e, for loads / put-constant / retag
    logic [4:0]  bm_start;   // BMX
    logic [4:0]  bm_span;

    // Set when decode itself failed; `fault` says why.
    fault_e      fault;

    logic [31:0] size_bytes; // length of the whole prefixed instruction
  } uop_t;

  // A uop that does nothing, for reset and bubbles.
  function automatic uop_t uop_nop();
    uop_t u;
    u = '0;
    u.kind = UOP_NOP;
    u.cond = CCK_NONE;
    u.fault = FAULT_NONE;
    return u;
  endfunction

  function automatic uop_t uop_fault(input fault_e cause);
    uop_t u;
    u = uop_nop();
    u.kind = UOP_FAULT;
    u.fault = cause;
    return u;
  endfunction

  // ---- Data type tag helpers --------------------------------------------
  // rdt_e is flat, but its values carry structure (see k2g_pkg): bit 2 is
  // signedness, the low bits are the width code.

  function automatic logic rdt_is_signed(input logic [2:0] t);
    return t[RDT_SIGNED_BIT];
  endfunction

  // 1, 2 or 4. The reserved width code 2'b11 (F32) reports 4.
  function automatic logic [2:0] rdt_width_bytes(input logic [2:0] t);
    case (t[1:0])
      2'b00:   return 3'd1;
      2'b01:   return 3'd2;
      default: return 3'd4;
    endcase
  endfunction

  function automatic logic rdt_is_reserved(input logic [2:0] t);
    // F32 (3'b011) is reserved, and 3'b111 is unassigned (spec 1.1.1, 11).
    return (t == 3'b011) || (t == 3'b111);
  endfunction

  // Normalizes a value to a tag: zero-extend if unsigned, sign-extend if
  // signed. Maintains the invariant that a register's bits always match what
  // its tag claims (spec 1.1.1).
  function automatic logic [31:0] rdt_normalize(
      input logic [31:0] v,
      input logic [2:0]  t
  );
    case (t[1:0])
      2'b00:   return rdt_is_signed(t) ? {{24{v[7]}},  v[7:0]}  : {24'd0, v[7:0]};
      2'b01:   return rdt_is_signed(t) ? {{16{v[15]}}, v[15:0]} : {16'd0, v[15:0]};
      default: return v;
    endcase
  endfunction

endpackage

`endif  // K2G_TYPES_SVH
