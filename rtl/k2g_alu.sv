// K2G arithmetic, logic and comparison unit.
//
// Purely combinational. The multiplier lives in k2g_mul.sv because it is
// multi-cycle and wants the DSP primitives.
//
// Two details here are load-bearing and easy to get subtly wrong:
//
//   * `overflow` has one meaning across ADD, SUB and MUL -- "the true result
//     did not fit". For SUB that is a borrow. The emulator originally formed
//     the two's complement in 32 bits and took *that* carry, which made the
//     flag a not-borrow flag and left it wrong for `b == 0` (spec 5.4).
//
//   * Comparisons widen both operands to 33 bits by their OWN tag before
//     comparing. s32 spans [-2^31, 2^31-1] and u32 spans [0, 2^32-1]; their
//     union does not fit in 32 bits, so a 32-bit comparator must misorder some
//     mixed-tag pairs -- the same trap as C's usual arithmetic conversions
//     making `-1 < 1u` false. The extra bit costs about one LUT since the
//     comparator is already a subtractor (spec 5.9).

`include "k2g_types.svh"

module k2g_alu
  import k2g_types::*;
(
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [2:0]  a_tag,     // rdt_e of the left operand
    input  logic [2:0]  b_tag,     // rdt_e of the right operand
    input  arith_e      arith_op,
    input  logic_e      logic_op,
    input  cmp_e        cmp_op,
    input  unary_e      unary_op,

    output logic [31:0] arith_result,
    output logic        arith_overflow,
    output logic [31:0] logic_result,
    output logic        cmp_result,
    output logic [31:0] unary_result
);

  // ---- add / subtract ----------------------------------------------------
  // One adder shared between both directions.
  wire logic [32:0] sum  = {1'b0, a} + {1'b0, b};
  wire logic [32:0] diff = {1'b0, a} - {1'b0, b};

  always_comb begin
    unique case (arith_op)
      ARITH_SUB: begin
        arith_result   = diff[31:0];
        arith_overflow = diff[32];   // borrow
      end
      default: begin
        arith_result   = sum[31:0];
        arith_overflow = sum[32];    // carry out
      end
    endcase
  end

  // ---- logic -------------------------------------------------------------
  always_comb begin
    unique case (logic_op)
      LOGIC_AND: logic_result = a & b;
      LOGIC_OR:  logic_result = a | b;
      default:   logic_result = a ^ b;
    endcase
  end

  // ---- unary -------------------------------------------------------------
  // Truncation to the destination tag happens in the writeback path, not here.
  always_comb begin
    unique case (unary_op)
      UNARY_NOT: unary_result = ~a;
      default:   unary_result = (~a) + 32'd1;
    endcase
  end

  // ---- comparison --------------------------------------------------------
  // Each operand widens by its own tag: replicate bit 31 if signed, prepend 0
  // if unsigned. Then one signed 33-bit comparison covers all four tag
  // combinations exactly.
  wire logic        a_signed = rdt_is_signed(a_tag);
  wire logic        b_signed = rdt_is_signed(b_tag);
  wire logic signed [32:0] a33 = {a_signed & a[31], a};
  wire logic signed [32:0] b33 = {b_signed & b[31], b};

  always_comb begin
    unique case (cmp_op)
      CMP_EQ:  cmp_result = (a33 == b33);
      CMP_NE:  cmp_result = (a33 != b33);
      CMP_LT:  cmp_result = (a33 <  b33);
      CMP_GT:  cmp_result = (a33 >  b33);
      CMP_LE:  cmp_result = (a33 <= b33);
      default: cmp_result = (a33 >= b33);
    endcase
  end

endmodule
