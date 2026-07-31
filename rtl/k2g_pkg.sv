// -------------------------------------------------------------------------
// GENERATED FILE -- DO NOT EDIT BY HAND.
//
// Produced by emu/src/sv_gen.rs from the enums in emu/src/insns.rs,
// which are the normative definition of the K2G instruction set.
//
// Regenerate:  cd emu && cargo run --bin gen_defs
// Verify:      cd emu && cargo test  (golden-file test fails on drift)
// -------------------------------------------------------------------------

`ifndef K2G_PKG_SV
`define K2G_PKG_SV

package k2g_pkg;

  // ---- Code point layout -------------------------------------------------
  // Two formats share one 16-bit code point:
  //   6/5/5 : LB[15:10] | arg1[9:5] | arg2[4:0]
  //   6/10  : LB[15:10] | imm10[9:0]
  // arg1 and imm10 share a left edge, which is why the predicate register
  // index needs no address mux on register read port A.
  localparam int CP_W      = 16;
  localparam int LB_LSB    = 10;
  localparam int LB_W      = 6;
  localparam int ARG1_LSB  = 5;
  localparam int ARG1_W    = 5;
  localparam int ARG2_LSB  = 0;
  localparam int ARG2_W    = 5;
  localparam int IMM10_LSB = 0;
  localparam int IMM10_W   = 10;

  localparam int REG_COUNT = 32;
  localparam int XLEN      = 32;

  // ---- Register data type tag -------------------------------------------
  // rdt_e is a flat enum, but its values carry structure the datapath can
  // use directly: bit 2 selects signed interpretation, and the low bits
  // give the width code (00=8, 01=16, 10=32, 11=reserved).
  localparam int RDT_W          = 3;
  localparam int RDT_SIGNED_BIT = 2;
  localparam logic [2:0] RDT_WIDTH_MASK = 3'b011;

  // LB -- 64 variants, 6 bits. Rust: `insns::LB`.
  typedef enum logic [5:0] {
    LB_EP1 = 6'b111111, // 63
    LB_PUC8 = 6'b111110, // 62
    LB_PUC16 = 6'b111101, // 61
    LB_PUC32 = 6'b111100, // 60
    LB_CPY = 6'b111011, // 59
    LB_LD8 = 6'b111010, // 58
    LB_LD16 = 6'b111001, // 57
    LB_LD32 = 6'b111000, // 56

    LB_LDF32 = 6'b110111, // 55
    LB_ST = 6'b110110, // 54
    LB_ADD = 6'b110101, // 53
    LB_SUB = 6'b110100, // 52
    LB_MUL = 6'b110011, // 51
    LB_DIV = 6'b110010, // 50
    LB_AND = 6'b110001, // 49
    LB_OR = 6'b110000, // 48

    LB_XOR = 6'b101111, // 47
    LB_SHL = 6'b101110, // 46
    LB_SHR = 6'b101101, // 45
    LB_SHRA = 6'b101100, // 44
    LB_SHLI = 6'b101011, // 43
    LB_SHRI = 6'b101010, // 42
    LB_SHRAI = 6'b101001, // 41
    LB_TST = 6'b101000, // 40

    LB_TSTN = 6'b100111, // 39
    LB_LT = 6'b100110, // 38
    LB_GT = 6'b100101, // 37
    LB_LTE = 6'b100100, // 36
    LB_GTE = 6'b100011, // 35
    LB_DISP = 6'b100010, // 34
    LB_DISPI = 6'b100001, // 33
    LB_XCN = 6'b100000, // 32

    LB_XCP = 6'b011111, // 31
    LB_XI = 6'b011110, // 30
    LB_XIZEXT = 6'b011101, // 29
    LB_BMX_0_0 = 6'b011100, // 28
    LB_RDT = 6'b011011, // 27
    LB_UNCLAIMED_26 = 6'b011010, // 26
    LB_UNCLAIMED_25 = 6'b011001, // 25
    LB_UNCLAIMED_24 = 6'b011000, // 24

    LB_UNCLAIMED_23 = 6'b010111, // 23
    LB_UNCLAIMED_22 = 6'b010110, // 22
    LB_UNCLAIMED_21 = 6'b010101, // 21
    LB_UNCLAIMED_20 = 6'b010100, // 20
    LB_UNCLAIMED_19 = 6'b010011, // 19
    LB_UNCLAIMED_18 = 6'b010010, // 18
    LB_UNCLAIMED_17 = 6'b010001, // 17
    LB_UNCLAIMED_16 = 6'b010000, // 16

    LB_UNCLAIMED_15 = 6'b001111, // 15
    LB_UNCLAIMED_14 = 6'b001110, // 14
    LB_UNCLAIMED_13 = 6'b001101, // 13
    LB_UNCLAIMED_12 = 6'b001100, // 12
    LB_UNCLAIMED_11 = 6'b001011, // 11
    LB_UNCLAIMED_10 = 6'b001010, // 10
    LB_UNCLAIMED_9 = 6'b001001, // 9
    LB_UNCLAIMED_8 = 6'b001000, // 8

    LB_UNCLAIMED_7 = 6'b000111, // 7
    LB_UNCLAIMED_6 = 6'b000110, // 6
    LB_UNCLAIMED_5 = 6'b000101, // 5
    LB_UNCLAIMED_4 = 6'b000100, // 4
    LB_UNCLAIMED_3 = 6'b000011, // 3
    LB_UNCLAIMED_2 = 6'b000010, // 2
    LB_UNCLAIMED_1 = 6'b000001, // 1
    LB_UNCLAIMED_0 = 6'b000000 // 0
  } lb_e;

  // EP1 -- 32 variants, 5 bits. Rust: `insns::EP1`.
  typedef enum logic [4:0] {
    EP1_EP2 = 5'b11111, // 31
    EP1_UTO = 5'b11110, // 30
    EP1_SS = 5'b11101, // 29
    EP1_NOT = 5'b11100, // 28
    EP1_NEG = 5'b11011, // 27
    EP1_DISP_OFF = 5'b11010, // 26
    EP1_DISP_ABS = 5'b11001, // 25
    EP1_SR = 5'b11000, // 24

    EP1_ESP = 5'b10111, // 23
    EP1_LTL = 5'b10110, // 22
    EP1_SL = 5'b10101, // 21
    EP1_LLC_B8 = 5'b10100, // 20
    EP1_LLC_B16 = 5'b10011, // 19
    EP1_LLC_B32 = 5'b10010, // 18
    EP1_LLC_F32 = 5'b10001, // 17
    EP1_UNCLAIMED_16 = 5'b10000, // 16

    EP1_UNCLAIMED_15 = 5'b01111, // 15
    EP1_UNCLAIMED_14 = 5'b01110, // 14
    EP1_UNCLAIMED_13 = 5'b01101, // 13
    EP1_UNCLAIMED_12 = 5'b01100, // 12
    EP1_UNCLAIMED_11 = 5'b01011, // 11
    EP1_UNCLAIMED_10 = 5'b01010, // 10
    EP1_UNCLAIMED_9 = 5'b01001, // 9
    EP1_UNCLAIMED_8 = 5'b01000, // 8

    EP1_UNCLAIMED_7 = 5'b00111, // 7
    EP1_UNCLAIMED_6 = 5'b00110, // 6
    EP1_UNCLAIMED_5 = 5'b00101, // 5
    EP1_UNCLAIMED_4 = 5'b00100, // 4
    EP1_UNCLAIMED_3 = 5'b00011, // 3
    EP1_UNCLAIMED_2 = 5'b00010, // 2
    EP1_UNCLAIMED_1 = 5'b00001, // 1
    EP1_UNCLAIMED_0 = 5'b00000 // 0
  } ep1_e;

  // EP2 -- 32 variants, 5 bits. Rust: `insns::EP2`.
  typedef enum logic [4:0] {
    EP2_FLAG = 5'b11111, // 31
    EP2_CSP = 5'b11110, // 30
    EP2_TC = 5'b11101, // 29
    EP2_DNO = 5'b11100, // 28
    EP2_MPI = 5'b11011, // 27
    EP2_MPD = 5'b11010, // 26
    EP2_HALT = 5'b11001, // 25
    EP2_ICINVR = 5'b11000, // 24

    EP2_UNCLAIMED_23 = 5'b10111, // 23
    EP2_UNCLAIMED_22 = 5'b10110, // 22
    EP2_UNCLAIMED_21 = 5'b10101, // 21
    EP2_UNCLAIMED_20 = 5'b10100, // 20
    EP2_UNCLAIMED_19 = 5'b10011, // 19
    EP2_UNCLAIMED_18 = 5'b10010, // 18
    EP2_UNCLAIMED_17 = 5'b10001, // 17
    EP2_UNCLAIMED_16 = 5'b10000, // 16

    EP2_UNCLAIMED_15 = 5'b01111, // 15
    EP2_UNCLAIMED_14 = 5'b01110, // 14
    EP2_UNCLAIMED_13 = 5'b01101, // 13
    EP2_UNCLAIMED_12 = 5'b01100, // 12
    EP2_UNCLAIMED_11 = 5'b01011, // 11
    EP2_UNCLAIMED_10 = 5'b01010, // 10
    EP2_UNCLAIMED_9 = 5'b01001, // 9
    EP2_UNCLAIMED_8 = 5'b01000, // 8

    EP2_UNCLAIMED_7 = 5'b00111, // 7
    EP2_UNCLAIMED_6 = 5'b00110, // 6
    EP2_UNCLAIMED_5 = 5'b00101, // 5
    EP2_UNCLAIMED_4 = 5'b00100, // 4
    EP2_UNCLAIMED_3 = 5'b00011, // 3
    EP2_UNCLAIMED_2 = 5'b00010, // 2
    EP2_UNCLAIMED_1 = 5'b00001, // 1
    EP2_UNCLAIMED_0 = 5'b00000 // 0
  } ep2_e;

  // CC -- 32 variants, 5 bits. Rust: `insns::CC`.
  typedef enum logic [4:0] {
    CC_OVERFLOW_SET = 5'b11111, // 31
    CC_FLAG_SET = 5'b11110, // 30
    CC_VALUE_ZERO = 5'b11101, // 29
    CC_VALUE_NEGATIVE = 5'b11100, // 28
    CC_VALUE_POSITIVE = 5'b11011, // 27
    CC_UNCLAIMED_26 = 5'b11010, // 26
    CC_UNCLAIMED_25 = 5'b11001, // 25
    CC_UNCLAIMED_24 = 5'b11000, // 24

    CC_UNCLAIMED_23 = 5'b10111, // 23
    CC_UNCLAIMED_22 = 5'b10110, // 22
    CC_UNCLAIMED_21 = 5'b10101, // 21
    CC_UNCLAIMED_20 = 5'b10100, // 20
    CC_UNCLAIMED_19 = 5'b10011, // 19
    CC_UNCLAIMED_18 = 5'b10010, // 18
    CC_UNCLAIMED_17 = 5'b10001, // 17
    CC_UNCLAIMED_16 = 5'b10000, // 16

    CC_UNCLAIMED_15 = 5'b01111, // 15
    CC_UNCLAIMED_14 = 5'b01110, // 14
    CC_UNCLAIMED_13 = 5'b01101, // 13
    CC_UNCLAIMED_12 = 5'b01100, // 12
    CC_UNCLAIMED_11 = 5'b01011, // 11
    CC_UNCLAIMED_10 = 5'b01010, // 10
    CC_UNCLAIMED_9 = 5'b01001, // 9
    CC_UNCLAIMED_8 = 5'b01000, // 8

    CC_UNCLAIMED_7 = 5'b00111, // 7
    CC_UNCLAIMED_6 = 5'b00110, // 6
    CC_UNCLAIMED_5 = 5'b00101, // 5
    CC_UNCLAIMED_4 = 5'b00100, // 4
    CC_UNCLAIMED_3 = 5'b00011, // 3
    CC_UNCLAIMED_2 = 5'b00010, // 2
    CC_UNCLAIMED_1 = 5'b00001, // 1
    CC_UNCLAIMED_0 = 5'b00000 // 0
  } cc_e;

  // RDT -- 8 variants, 3 bits. Rust: `insns::RDT`.
  typedef enum logic [2:0] {
    RDT_UNCLAIMED_7 = 3'b111, // 7
    RDT_S32 = 3'b110, // 6
    RDT_S16 = 3'b101, // 5
    RDT_S8 = 3'b100, // 4
    RDT_F32 = 3'b011, // 3
    RDT_U32 = 3'b010, // 2
    RDT_U16 = 3'b001, // 1
    RDT_U8 = 3'b000 // 0
  } rdt_e;

endpackage

`endif  // K2G_PKG_SV
