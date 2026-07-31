// K2G shifter and bit-field unit.
//
// SHL/SHR/SHRA, plus the BMX-prefixed extract and insert that reuse the shift
// opcodes (spec 3.2, 5.8). Sharing one barrel rather than building four is the
// difference between roughly 280 LUTs and over a thousand on a 9K part.
//
// SHRA needs no special case for sub-word tags: because a register's bits
// always match its tag (spec 1.1.1), a signed value is already sign-filled to
// 32 bits and an unsigned one is non-negative, so a plain 32-bit arithmetic
// shift is correct for both. The emulator originally sign-extended from bit 31
// regardless of tag, which was incoherent for U8/U16 registers.

`include "k2g_types.svh"

module k2g_shift
  import k2g_types::*;
(
    input  logic [31:0] value,      // shift operand, and the BINS destination
    input  logic [31:0] src,        // BEXT source, and the BINS insert source
    input  logic [4:0]  amount,     // shift amount, already masked to 5 bits
    input  shift_e      shift_op,
    input  logic [4:0]  bm_start,
    input  logic [4:0]  bm_span,

    output logic [31:0] shift_result,
    output logic [31:0] bext_result,
    output logic [31:0] bins_result
);

  // ---- shifts ------------------------------------------------------------
  wire logic signed [31:0] value_s = value;

  always_comb begin
    unique case (shift_op)
      SHIFT_LL: shift_result = value << amount;
      SHIFT_LR: shift_result = value >> amount;
      default:  shift_result = value_s >>> amount;
    endcase
  end

  // ---- bit-field mask ----------------------------------------------------
  // A span of 32 would overflow a 5-bit field, so span is 0..31 by
  // construction; span 0 yields an all-zero mask, which makes BINS a no-op --
  // the defined behaviour (spec 5.8). BEXT with span 0 is caught in decode.
  wire logic [31:0] span_mask = (bm_span == 5'd0)
                              ? 32'd0
                              : ((32'd1 << bm_span) - 32'd1);

  // Extract reads the SOURCE register (arg2), not the destination. Extracting
  // from `value` instead was an actual bug, caught by randomized lockstep
  // cosimulation -- the unit test had encoded the same misunderstanding, so it
  // passed against wrong RTL.
  assign bext_result = (src >> bm_start) & span_mask;

  wire logic [31:0] placed_mask = span_mask << bm_start;
  wire logic [31:0] placed_src  = (src & span_mask) << bm_start;

  assign bins_result = (value & ~placed_mask) | placed_src;

endmodule
