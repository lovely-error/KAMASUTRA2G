/// Declares an ISA opcode enum *and* a reflected table of its variants.
///
/// The whole point is that `VARIANTS` is generated from the same tokens as the
/// enum body, so the SystemVerilog header emitted by `crate::sv_gen` cannot
/// drift from the Rust definition. The superseded `decoder.sv` diverged exactly
/// this way -- it had `LB_ADD = 62` against the emulator's 53, and duplicate
/// labels (`LB_GTE` at both 53 and 35) that nothing detected.
///
/// `BITS` is the width of the field the opcode occupies in a code point, which
/// the generator needs to emit `typedef enum logic [BITS-1:0]`.
macro_rules! isa_enum {
	(
		$(#[$meta:meta])*
		$vis:vis enum $name:ident : $bits:literal {
			$( $variant:ident = $value:expr ),* $(,)?
		}
	) => {
		#[allow(nonstandard_style)]
		#[derive(Debug, Clone, Copy, PartialEq, Eq)]
		#[repr(u16)]
		$(#[$meta])*
		$vis enum $name {
			$( $variant = $value ),*
		}

		impl $name {
			/// Width in bits of the code-point field this enum occupies.
			pub const BITS: u32 = $bits;

			/// Every variant as `(name, value)`, in declaration order.
			pub const VARIANTS: &'static [(&'static str, u16)] = &[
				$( (stringify!($variant), $value) ),*
			];

			/// Name of the variant with this value, if any.
			#[allow(dead_code)]
			pub fn name_of(value: u16) -> Option<&'static str> {
				let mut i = 0;
				while i < Self::VARIANTS.len() {
					if Self::VARIANTS[i].1 == value {
						return Some(Self::VARIANTS[i].0);
					}
					i += 1;
				}
				None
			}
		}
	};
}

isa_enum! {
pub enum LB : 6 {
  LB_EP1 = 0b111111, // 63
  LB_PUC8 = 0b111110, // 62
  LB_PUC16 = 0b111101, // 61
  LB_PUC32 = 0b111100, // 60
  LB_CPY = 0b111011, // 59
  LB_LD8 = 0b111010, // 58
  LB_LD16 = 0b111001, // 57
  LB_LD32 = 0b111000, // 56

  LB_LDF32 = 0b110111, // 55
  LB_ST = 0b110110, // 54
  LB_ADD = 0b110101, // 53
  LB_SUB = 0b110100, // 52
  LB_MUL = 0b110011, // 51
  LB_DIV = 0b110010, // 50
  LB_AND = 0b110001, // 49
  LB_OR = 0b110000, // 48

  LB_XOR = 0b101111, // 47
  LB_SHL = 0b101110, // 46
  LB_SHR = 0b101101, // 45
  LB_SHRA = 0b101100, // 44
  LB_SHLI = 0b101011, // 43
  LB_SHRI = 0b101010, // 42
  LB_SHRAI = 0b101001, // 41
  LB_TST = 0b101000, // 40

  LB_TSTN = 0b100111, // 39
  LB_LT = 0b100110, // 38
  LB_GT = 0b100101, // 37
  LB_LTE = 0b100100, // 36
  LB_GTE = 0b100011, // 35
  LB_DISP = 0b100010, // 34
  LB_DISPI = 0b100001, // 33
  LB_XCN = 0b100000, // 32

  LB_XCP = 0b011111, // 31
  LB_XI = 0b011110, // 30
  LB_XIZEXT = 0b011101, // 29
  LB_BMX_0_0 = 0b011100, // 28
  LB_RDT = 0b011011, // 27
  LB_UNCLAIMED_26 = 0b011010, // 26
  LB_UNCLAIMED_25 = 0b011001, // 25
  LB_UNCLAIMED_24 = 0b011000, // 24

  LB_UNCLAIMED_23 = 0b010111, // 23
  LB_UNCLAIMED_22 = 0b010110, // 22
  LB_UNCLAIMED_21 = 0b010101, // 21
  LB_UNCLAIMED_20 = 0b010100, // 20
  LB_UNCLAIMED_19 = 0b010011, // 19
  LB_UNCLAIMED_18 = 0b010010, // 18
  LB_UNCLAIMED_17 = 0b010001, // 17
  LB_UNCLAIMED_16 = 0b010000, // 16

  LB_UNCLAIMED_15 = 0b001111, // 15
  LB_UNCLAIMED_14 = 0b001110, // 14
  LB_UNCLAIMED_13 = 0b001101, // 13
  LB_UNCLAIMED_12 = 0b001100, // 12
  LB_UNCLAIMED_11 = 0b001011, // 11
  LB_UNCLAIMED_10 = 0b001010, // 10
  LB_UNCLAIMED_9 = 0b001001, // 9
  LB_UNCLAIMED_8 = 0b001000, // 8

  LB_UNCLAIMED_7 = 0b000111, // 7
  LB_UNCLAIMED_6 = 0b000110, // 6
  LB_UNCLAIMED_5 = 0b000101, // 5
  LB_UNCLAIMED_4 = 0b000100, // 4
  LB_UNCLAIMED_3 = 0b000011, // 3
  LB_UNCLAIMED_2 = 0b000010, // 2
  LB_UNCLAIMED_1 = 0b000001, // 1
  LB_UNCLAIMED_0 = 0b000000 // 0
}
}

isa_enum! {
pub enum EP1 : 5 {

  EP1_EP2 = 0b11111, // 31
  EP1_UTO = 0b11110, // 30
  EP1_SS = 0b11101, // 29
  EP1_NOT = 0b11100, // 28
  EP1_NEG = 0b11011, // 27
  EP1_DISP_OFF = 0b11010, // 26
  EP1_DISP_ABS = 0b11001, // 25
  EP1_SR = 0b11000, // 24

  EP1_ESP = 0b10111, // 23
  EP1_LTL = 0b10110, // 22
  EP1_SL = 0b10101, // 21
  EP1_LLC_B8 = 0b10100, // 20
  EP1_LLC_B16 = 0b10011, // 19
  EP1_LLC_B32 = 0b10010, // 18
  EP1_LLC_F32 = 0b10001, // 17
  EP1_UNCLAIMED_16 = 0b10000, // 16

  EP1_UNCLAIMED_15 = 0b01111, // 15
  EP1_UNCLAIMED_14 = 0b01110, // 14
  EP1_UNCLAIMED_13 = 0b01101, // 13
  EP1_UNCLAIMED_12 = 0b01100, // 12
  EP1_UNCLAIMED_11 = 0b01011, // 11
  EP1_UNCLAIMED_10 = 0b01010, // 10
  EP1_UNCLAIMED_9 = 0b01001, // 9
  EP1_UNCLAIMED_8 = 0b01000, // 8

  EP1_UNCLAIMED_7 = 0b00111, // 7
  EP1_UNCLAIMED_6 = 0b00110, // 6
  EP1_UNCLAIMED_5 = 0b00101, // 5
  EP1_UNCLAIMED_4 = 0b00100, // 4
  EP1_UNCLAIMED_3 = 0b00011, // 3
  EP1_UNCLAIMED_2 = 0b00010, // 2
  EP1_UNCLAIMED_1 = 0b00001, // 1
  EP1_UNCLAIMED_0 = 0b00000 // 0

}
}

isa_enum! {
pub enum EP2 : 5 {

  EP2_FLAG = 0b11111, // 31
  EP2_CSP = 0b11110, // 30
  EP2_TC = 0b11101, // 29
  EP2_DNO = 0b11100, // 28
  EP2_MPI = 0b11011, // 27
  EP2_MPD = 0b11010, // 26
  EP2_HALT = 0b11001, // 25
  EP2_ICINVR = 0b11000, // 24

  EP2_UNCLAIMED_23 = 0b10111, // 23
  EP2_UNCLAIMED_22 = 0b10110, // 22
  EP2_UNCLAIMED_21 = 0b10101, // 21
  EP2_UNCLAIMED_20 = 0b10100, // 20
  EP2_UNCLAIMED_19 = 0b10011, // 19
  EP2_UNCLAIMED_18 = 0b10010, // 18
  EP2_UNCLAIMED_17 = 0b10001, // 17
  EP2_UNCLAIMED_16 = 0b10000, // 16

  EP2_UNCLAIMED_15 = 0b01111, // 15
  EP2_UNCLAIMED_14 = 0b01110, // 14
  EP2_UNCLAIMED_13 = 0b01101, // 13
  EP2_UNCLAIMED_12 = 0b01100, // 12
  EP2_UNCLAIMED_11 = 0b01011, // 11
  EP2_UNCLAIMED_10 = 0b01010, // 10
  EP2_UNCLAIMED_9 = 0b01001, // 9
  EP2_UNCLAIMED_8 = 0b01000, // 8

  EP2_UNCLAIMED_7 = 0b00111, // 7
  EP2_UNCLAIMED_6 = 0b00110, // 6
  EP2_UNCLAIMED_5 = 0b00101, // 5
  EP2_UNCLAIMED_4 = 0b00100, // 4
  EP2_UNCLAIMED_3 = 0b00011, // 3
  EP2_UNCLAIMED_2 = 0b00010, // 2
  EP2_UNCLAIMED_1 = 0b00001, // 1
  EP2_UNCLAIMED_0 = 0b00000 // 0

}
}

isa_enum! {
pub enum CC : 5 {

  CC_OVERFLOW_SET = 0b11111, // 31
  CC_FLAG_SET = 0b11110, // 30
  CC_VALUE_ZERO = 0b11101, // 29
  CC_VALUE_NEGATIVE = 0b11100, // 28
  CC_VALUE_POSITIVE = 0b11011, // 27
  CC_UNCLAIMED_26 = 0b11010, // 26
  CC_UNCLAIMED_25 = 0b11001, // 25
  CC_UNCLAIMED_24 = 0b11000, // 24

  CC_UNCLAIMED_23 = 0b10111, // 23
  CC_UNCLAIMED_22 = 0b10110, // 22
  CC_UNCLAIMED_21 = 0b10101, // 21
  CC_UNCLAIMED_20 = 0b10100, // 20
  CC_UNCLAIMED_19 = 0b10011, // 19
  CC_UNCLAIMED_18 = 0b10010, // 18
  CC_UNCLAIMED_17 = 0b10001, // 17
  CC_UNCLAIMED_16 = 0b10000, // 16

  CC_UNCLAIMED_15 = 0b01111, // 15
  CC_UNCLAIMED_14 = 0b01110, // 14
  CC_UNCLAIMED_13 = 0b01101, // 13
  CC_UNCLAIMED_12 = 0b01100, // 12
  CC_UNCLAIMED_11 = 0b01011, // 11
  CC_UNCLAIMED_10 = 0b01010, // 10
  CC_UNCLAIMED_9 = 0b01001, // 9
  CC_UNCLAIMED_8 = 0b01000, // 8

  CC_UNCLAIMED_7 = 0b00111, // 7
  CC_UNCLAIMED_6 = 0b00110, // 6
  CC_UNCLAIMED_5 = 0b00101, // 5
  CC_UNCLAIMED_4 = 0b00100, // 4
  CC_UNCLAIMED_3 = 0b00011, // 3
  CC_UNCLAIMED_2 = 0b00010, // 2
  CC_UNCLAIMED_1 = 0b00001, // 1
  CC_UNCLAIMED_0 = 0b00000 // 0

}
}

isa_enum! {
/// Register data type tag. Named `RDT` after the author's original enum in the
/// superseded generator (`docs/attic/gen_enum.rs`), extended from 4 entries to
/// 8 to carry signedness.
///
/// The values are chosen so that although this is a flat enum, it still has
/// exploitable structure -- the RTL may read it either way:
///
/// ```text
///   bit 2      : 0 = unsigned, 1 = signed
///   bits [1:0] : 00 = 8-bit, 01 = 16-bit, 10 = 32-bit, 11 = reserved
/// ```
pub enum RDT : 3 {
  RDT_UNCLAIMED_7 = 0b111, // 7
  RDT_S32 = 0b110, // 6
  RDT_S16 = 0b101, // 5
  RDT_S8 = 0b100, // 4
  RDT_F32 = 0b011, // 3
  RDT_U32 = 0b010, // 2
  RDT_U16 = 0b001, // 1
  RDT_U8 = 0b000 // 0
}
}

/// Bit within an `RDT` value that selects signed interpretation.
pub const RDT_SIGNED_BIT: u32 = 2;
/// Mask selecting the width code within an `RDT` value.
pub const RDT_WIDTH_MASK: u16 = 0b011;

// ---- Code point field layout ----
//
// Mirrored into the generated SystemVerilog package so the RTL never hardcodes
// bit positions. `layout_matches_pack_functions` below asserts these agree with
// pack_6_5_5 / pack_6_10, which remain the definition of record.
pub const CP_WIDTH: u32 = 16;
pub const LB_LSB: u32 = 10;
pub const LB_WIDTH: u32 = 6;
pub const ARG1_LSB: u32 = 5;
pub const ARG1_WIDTH: u32 = 5;
pub const ARG2_LSB: u32 = 0;
pub const ARG2_WIDTH: u32 = 5;
pub const IMM10_LSB: u32 = 0;
pub const IMM10_WIDTH: u32 = 10;

pub const fn pack_6_5_5(lb: u16, arg1: u16, arg2: u16) -> u16 {
	assert!(lb <= 0x3f);
	assert!(arg1 <= 0x1f);
	assert!(arg2 <= 0x1f);
	((lb & 0x3f) << 10) | ((arg1 & 0x1f) << 5) | (arg2 & 0x1f)
}

pub const fn pack_6_10(lb: u16, imm10: u16) -> u16 {
	((lb & 0x3f) << 10) | (imm10 & 0x3ff)
}

pub const fn unpack_6_5_5(cp: u16) -> (u16, u16, u16) {
	(
		(cp >> 10) & 0x3f,
		(cp >> 5) & 0x1f,
		cp & 0x1f
	)
}

pub const fn unpack_6_10(cp: u16) -> (u16, u16) {
	(
		(cp >> 10) & 0x3f , 
		(cp & 0x3ff)
	)
}

pub const fn reg_index_in_bounds(reg_index:usize) -> bool {
	reg_index <= 31
}

pub fn extract_bits<T>(num: T, start: usize, span: usize) -> T
	where
		T: Copy
			+ core::convert::From<u8>
			+ core::ops::BitAnd<Output = T>
			+ core::ops::Shl<usize, Output = T>
			+ core::ops::Shr<usize, Output = T>
			+ core::ops::Sub<Output = T>
			+ core::ops::BitOr<Output = T>
			+ core::cmp::PartialEq
			+ core::ops::Not<Output = T>,
{
	let start = start;
	let width = span;
	assert!(width > 0);
	assert!(width <= core::mem::size_of::<T>() * 8);

	let mask = !(!T::from(0u8) << width) << start;

	(num & mask) >> start
}

pub const fn max_val_for_two_comp_int(bitwidth: usize) -> isize {
	assert!(bitwidth != 0);
	((1<<(bitwidth - 1))-1) as isize
}
pub const fn min_val_for_two_comp_int(bitwidth: usize) -> isize {
	assert!(bitwidth != 0);
	let max = max_val_for_two_comp_int(bitwidth) as usize;
	let min = !(max) .wrapping_add(1) .wrapping_add(!0usize);
	return min as isize
}

pub const fn imm_in_bounds(imm:isize, bitwidth: usize) -> bool {
	let max = max_val_for_two_comp_int(bitwidth);
	let min = min_val_for_two_comp_int(bitwidth);
	let inbounds = min <= imm && imm <= max;
	return inbounds
}

// --- Encoding Functions ---

// Loads and Constants

pub const fn encode_lc_i5_b8(rix1: u16, imm5: isize) -> [u16;1] {
	assert!(imm_in_bounds(imm5, 5));
	let imm5 = (imm5 as u16) & ((1u16<<5)-1);
	[
		pack_6_5_5(LB::LB_PUC8 as _, rix1, imm5)
	]
}

pub const fn encode_lc_i5_b16(rix1: u16, imm5: isize) -> [u16;1] {
	assert!(imm_in_bounds(imm5, 5));
	let imm5 = (imm5 as u16) & ((1u16<<5)-1);
	[
		pack_6_5_5(LB::LB_PUC16 as _, rix1, imm5)
	]
}

pub const fn encode_lc_i5_b32(rix1: u16, imm5: isize) -> [u16;1] {
	assert!(imm_in_bounds(imm5, 5));
	let imm5 = (imm5 as u16) & ((1u16<<5)-1);
	[
		pack_6_5_5(LB::LB_PUC32 as _, rix1, imm5)
	]
}

pub const fn encode_llc_b8(rix1: u16, imm: usize) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, rix1, EP1::EP1_LLC_B8 as _),
		imm as _
	]
}

pub const fn encode_llc_b16(rix1: u16, imm: usize) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, rix1, EP1::EP1_LLC_B16 as _),
		imm as _
	]
}

pub const fn encode_llc_b32(rix1: u16, imm: usize) -> [u16;3] {
	[
		pack_6_5_5(LB::LB_EP1 as _, rix1, EP1::EP1_LLC_B32 as _),
		(imm >> 16) as u16,
		imm as u16
	]
}

pub fn encode_ld_b32(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_LD32 as _, rix1, rix2)
	]
}

pub fn encode_ld_b16(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_LD16 as _, rix1, rix2)
	]
}

pub fn encode_ld_b8(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_LD8 as _, rix1, rix2)
	]
}

pub fn encode_ld_b32_soff(rix1: u16, rix2: u16, imm10: u16) -> [u16;2] {
	[
		pack_6_10(LB::LB_XI as _, imm10),
		pack_6_5_5(LB::LB_LD32 as _, rix1, rix2),
	]
}

pub fn encode_ld_b16_soff(rix1: u16, rix2: u16, imm10: u16) -> [u16;2] {
	[
		pack_6_10(LB::LB_XI as _, imm10),
		pack_6_5_5(LB::LB_LD16 as _, rix1, rix2),
	]
}

pub fn encode_ld_b8_soff(rix1: u16, rix2: u16, imm10: u16) -> [u16;2] {
	[
		pack_6_10(LB::LB_XI as _, imm10),
		pack_6_5_5(LB::LB_LD8 as _, rix1, rix2),
	]
}

pub fn encode_ld_b32_uoff(rix1: u16, rix2: u16, imm10: u16) -> [u16;2] {
	[
		pack_6_10(LB::LB_XIZEXT as _, imm10),
		pack_6_5_5(LB::LB_LD32 as _, rix1, rix2),
	]
}

pub fn encode_ld_b16_uoff(rix1: u16, rix2: u16, imm10: u16) -> [u16;2] {
	[
		pack_6_10(LB::LB_XIZEXT as _, imm10),
		pack_6_5_5(LB::LB_LD16 as _, rix1, rix2),
	]
}

pub fn encode_ld_b8_uoff(rix1: u16, rix2: u16, imm10: u16) -> [u16;2] {
	[
		pack_6_10(LB::LB_XIZEXT as _, imm10),
		pack_6_5_5(LB::LB_LD8 as _, rix1, rix2),
	]
}

pub fn encode_ld_lock_b32(rix1: u16, rix2: u16, gix: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, gix, EP1::EP1_LTL as _),
		pack_6_5_5(LB::LB_LD32 as _, rix1, rix2),
	]
}

pub fn encode_ld_lock_b16(rix1: u16, rix2: u16, gix: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, gix, EP1::EP1_LTL as _),
		pack_6_5_5(LB::LB_LD16 as _, rix1, rix2),
	]
}

pub fn encode_ld_lock_b8(rix1: u16, rix2: u16, gix: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, gix, EP1::EP1_LTL as _),
		pack_6_5_5(LB::LB_LD8 as _, rix1, rix2),
	]
}

pub fn encode_ld_seq_b32(rix1: u16, rix2: u16, gix: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, gix, EP1::EP1_SL as _),
		pack_6_5_5(LB::LB_LD32 as _, rix1, rix2),
	]
}

pub fn encode_ld_seq_b16(rix1: u16, rix2: u16, gix: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, gix, EP1::EP1_SL as _),
		pack_6_5_5(LB::LB_LD16 as _, rix1, rix2),
	]
}

pub fn encode_ld_seq_b8(rix1: u16, rix2: u16, gix: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, gix, EP1::EP1_SL as _),
		pack_6_5_5(LB::LB_LD8 as _, rix1, rix2),
	]
}

/// `RDT rd, kind` -- set the register's data type tag and re-normalize its
/// value to that tag (sign- or zero-extending from the tag's width).
///
/// This is the only way to make a register signed: `PUC*` and `LD*` set the
/// unsigned variant of their width, so a sign-extended byte load is
/// `LD8 rd, [ra]` followed by `RDT rd, RDT_S8`.
pub fn encode_rdt(rix1: u16, kind: RDT) -> [u16;1] {
	assert!(reg_index_in_bounds(rix1 as usize));
	[
		pack_6_5_5(LB::LB_RDT as _, rix1, kind as _)
	]
}

pub fn encode_cpy(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_CPY as _, rix1, rix2)
	]
}

// Stores and Synchronization
pub fn encode_st(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_ST as _, rix1, rix2)
	]
}

pub fn encode_st_seq(rix1: u16, rix2: u16, gix: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, gix, EP1::EP1_SS as _),
		pack_6_5_5(LB::LB_ST as _, rix1, rix2),
	]
}

pub fn encode_st_seq_rel(rix1: u16, rix2: u16, gix: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, gix, EP1::EP1_SR as _),
		pack_6_5_5(LB::LB_ST as _, rix1, rix2),
	]
}

pub fn encode_export_span(rix1: u16, rix2: u16, gix: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, gix, EP1::EP1_ESP as _),
		pack_6_5_5(LB::LB_ST as _, rix1, rix2),
	]
}

pub fn encode_st_seq_insn(rix1: u16, rix2: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_ICINVR as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_ST as _, rix1, rix2),
	]
}

// Status and Machine Control
pub fn encode_ld_msr_32(rix1: u16, rix2: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_CSP as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_LD32 as _, rix1, rix2),
	]
}

pub fn encode_ld_msr_16(rix1: u16, rix2: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_CSP as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_LD16 as _, rix1, rix2),
	]
}

pub fn encode_ld_msr_8(rix1: u16, rix2: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_CSP as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_LD8 as _, rix1, rix2),
	]
}

pub fn encode_st_mcr(rix1: u16, rix2: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_CSP as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_ST as _, rix1, rix2),
	]
}

// ALU Operations
pub fn encode_neg(rix1: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_EP1 as _, rix1, EP1::EP1_NEG as _)
	]
}

pub fn encode_add_rr(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_ADD as _, rix1, rix2)
	]
}

pub fn encode_add_ri(rix1: u16, imm:isize) -> [u16;2] {
	debug_assert!(imm_in_bounds(imm, 15));
	let imm5 = extract_bits(imm, 0, 5) as u16;
	let imm10 = extract_bits(imm, 5, 10) as u16;
	[
		pack_6_10(LB::LB_XI as _, imm10),
		pack_6_5_5(LB::LB_ADD as _, rix1, imm5),
	]
}

pub fn encode_shl_ri(rix1: u16, imm5: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_SHLI as _, rix1, imm5)
	]
}

pub fn encode_shl_rr(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_SHL as _, rix1, rix2),
	]
}

pub fn encode_shr_rr(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_SHR as _, rix1, rix2),
	]
}

pub fn encode_shr_ri(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_SHRI as _, rix1, rix2),
	]
}

pub fn encode_shra_rr(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_SHRA as _, rix1, rix2),
	]
}

pub fn encode_shra_ri(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_SHRAI as _, rix1, rix2),
	]
}

// Multi-word Subword Extractions & Insertions
pub fn encode_bext(rix1: u16, rix2: u16, start: u16, span: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_BMX_0_0 as _, start, span),
		pack_6_5_5(LB::LB_SHL as _, rix1, rix2),
	]
}

pub fn encode_bins(rix1: u16, rix2: u16, start: u16, span: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_BMX_0_0 as _, start, span),
		pack_6_5_5(LB::LB_SHR as _, rix1, rix2),
	]
}

pub fn encode_inv(rix1: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_EP1 as _, rix1, EP1::EP1_NOT as _)
	]
}

// Flags Operations
pub fn encode_flag_and(rix1: u16, rix2: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_FLAG as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_AND as _, rix1, rix2),
	]
}
pub fn encode_flag_or(rix1: u16, rix2: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_FLAG as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_OR as _, rix1, rix2),
	]
}
pub fn encode_flag_xor(rix1: u16, rix2: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_FLAG as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_XOR as _, rix1, rix2),
	]
}
pub fn encode_flag_not(rix1: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_FLAG as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_EP1 as _, rix1, EP1::EP1_NOT as _),
	]
}

// Comparisons
pub fn encode_cmp_eq(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_TST as _, rix1, rix2)
	]
}

pub fn encode_cmp_neq(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_TSTN as _, rix1, rix2)
	]
}

pub fn encode_cmp_gt_rr(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_GT as _, rix1, rix2)
	]
}

pub fn encode_cmp_gte_rr(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_GTE as _, rix1, rix2)
	]
}

pub fn encode_cmp_lt_rr(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_LT as _, rix1, rix2)
	]
}

pub fn encode_cmp_lte_rr(rix1: u16, rix2: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_LTE as _, rix1, rix2)
	]
}

pub fn encode_cmp_gt_ri(rix1: u16, imm:isize) -> [u16;2] {
	debug_assert!(imm_in_bounds(imm, 19));
	let imm10 = extract_bits(imm, 5, 10) as u16;
	let imm5 = extract_bits(imm, 0, 5) as u16;
	[
		pack_6_10(LB::LB_XI as _, imm10),
		pack_6_5_5(LB::LB_GT as _, rix1, imm5),
	]
}

pub fn encode_cmp_gte_ri(rix1: u16, imm:isize) -> [u16;2] {
	debug_assert!(imm_in_bounds(imm, 19));
	let imm10 = extract_bits(imm, 5, 10) as u16;
	let imm5 = extract_bits(imm, 0, 5) as u16;
	[
		pack_6_10(LB::LB_XI as _, imm10),
		pack_6_5_5(LB::LB_GTE as _, rix1, imm5),
	]
}

pub fn encode_cmp_lt_ri(rix1: u16, imm:isize) -> [u16;2] {
	debug_assert!(imm_in_bounds(imm, 19));
	let imm10 = extract_bits(imm, 5, 10) as u16;
	let imm5 = extract_bits(imm, 0, 5) as u16;
	[
		pack_6_10(LB::LB_XI as _, imm10),
		pack_6_5_5(LB::LB_LT as _, rix1, imm5),
	]
}

pub fn encode_cmp_lte_ri(rix1: u16, imm:isize) -> [u16;2] {
	debug_assert!(imm_in_bounds(imm, 19));
	let imm10 = extract_bits(imm, 5, 10) as u16;
	let imm5 = extract_bits(imm, 0, 5) as u16;
	[
		pack_6_10(LB::LB_XI as _, imm10),
		pack_6_5_5(LB::LB_LTE as _, rix1, imm5),
	]
}

// Control Flow (Disp & Transition)
pub fn encode_disp_imm(imm: isize) -> [u16;1] {
	debug_assert!(imm_in_bounds(imm, 10));
	[
		pack_6_10(LB::LB_DISPI as _, imm as _)
	]
}

pub fn encode_disp_imm_xim(imm:isize) -> [u16;2] {
	debug_assert!(imm_in_bounds(imm, 24));
	let imm2 = extract_bits(imm, 10, 20) as u16;
	let imm1 = extract_bits(imm, 0, 10) as u16;
	[
		pack_6_10(LB::LB_XI as _, imm2),
		pack_6_10(LB::LB_DISPI as _, imm1),
	]
}

pub fn encode_disp_imm_xim_link(rix3: u16, imm:isize) -> [u16;3] {
	debug_assert!(imm_in_bounds(imm, 24));
	let imm2 = extract_bits(imm, 10, 20) as u16;
	let imm1 = extract_bits(imm, 0, 10) as u16;
	[
		pack_6_5_5(LB::LB_EP1 as _, rix3, EP1::EP1_UTO as _),
		pack_6_10(LB::LB_XI as _, imm2),
		pack_6_10(LB::LB_DISPI as _, imm1),
	]
}

pub fn encode_disp_reg_off(rix: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_DISP as _, rix, EP1::EP1_DISP_OFF as _)
	]
}

pub fn encode_disp_reg_off_link(rix3: u16, rix: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, rix3, EP1::EP1_UTO as _),
		pack_6_5_5(LB::LB_DISP as _, rix, EP1::EP1_DISP_OFF as _),
	]
}

pub fn encode_disp_reg_addr(rix: u16) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_DISP as _, rix, EP1::EP1_DISP_ABS as _)
	]
}

pub fn encode_disp_reg_addr_link(dst: u16, ba: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, ba, EP1::EP1_UTO as _),
		pack_6_5_5(LB::LB_DISP as _, dst, EP1::EP1_DISP_ABS as _),
	]
}

pub fn encode_ctrl_trn() -> [u16;1] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_TC as _, EP1::EP1_EP2 as _)
	]
}

pub fn encode_halt() -> [u16;1] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_HALT as _, EP1::EP1_EP2 as _)
	]
}

pub fn encode_nop() -> [u16;1] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_DNO as _, EP1::EP1_EP2 as _)
	]
}

// Prefetch
pub fn encode_pfd(rix1: u16, rix2: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_MPD as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_TST as _, rix1, rix2),
	]
}

pub fn encode_pfi(rix1: u16, rix2: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, EP2::EP2_MPI as _, EP1::EP1_EP2 as _),
		pack_6_5_5(LB::LB_TST as _, rix1, rix2),
	]
}

// Extended Math
pub fn encode_mulw_rr(rix1: u16, rix2: u16, rix3: u16) -> [u16;2] {
	[
		pack_6_5_5(LB::LB_EP1 as _, rix3, EP1::EP1_UTO as _),
		pack_6_5_5(LB::LB_MUL as _, rix1, rix2),
	]
}

// Conditionals
pub fn encode_xcp(rix: u16, cc: CC) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_XCP as _, rix, cc as _)
	]
}

pub fn encode_xcn(rix: u16, cc: CC) -> [u16;1] {
	[
		pack_6_5_5(LB::LB_XCN as _, rix, cc as _)
	]
}


#[cfg(test)]
mod layout_tests {
	use super::*;

	/// The exported field-position constants must describe what pack/unpack
	/// actually do. The constants are mirrored into the generated SystemVerilog
	/// package; if they drifted, the RTL would decode different bits than the
	/// emulator -- the precise failure mode that made `decoder.sv` unusable
	/// (it read the opcode from `lane[5:0]` rather than `cp[15:10]`).
	#[test]
	fn layout_matches_pack_functions() {
		// A field of all ones lands exactly where the constants claim.
		let lb_only = pack_6_5_5((1 << LB_WIDTH) - 1, 0, 0);
		assert_eq!(lb_only, (((1 << LB_WIDTH) - 1) as u16) << LB_LSB);

		let arg1_only = pack_6_5_5(0, (1 << ARG1_WIDTH) - 1, 0);
		assert_eq!(arg1_only, (((1 << ARG1_WIDTH) - 1) as u16) << ARG1_LSB);

		let arg2_only = pack_6_5_5(0, 0, (1 << ARG2_WIDTH) - 1);
		assert_eq!(arg2_only, (((1 << ARG2_WIDTH) - 1) as u16) << ARG2_LSB);

		let imm_only = pack_6_10(0, (1 << IMM10_WIDTH) - 1);
		assert_eq!(imm_only, (((1 << IMM10_WIDTH) - 1) as u16) << IMM10_LSB);

		// The three 6/5/5 fields tile the code point with no gap or overlap.
		assert_eq!(LB_WIDTH + ARG1_WIDTH + ARG2_WIDTH, CP_WIDTH);
		assert_eq!(ARG2_LSB + ARG2_WIDTH, ARG1_LSB);
		assert_eq!(ARG1_LSB + ARG1_WIDTH, LB_LSB);
		assert_eq!(LB_LSB + LB_WIDTH, CP_WIDTH);

		// The 6/10 format shares the same opcode field.
		assert_eq!(IMM10_LSB + IMM10_WIDTH, LB_LSB);
	}

	/// arg1 and imm10 share a left edge at bit 9. The RTL depends on this:
	/// the predicate register index in an XCP/XCN prefix sits at cp[9:5],
	/// the same position as arg1, so register read port A needs no address mux.
	#[test]
	fn arg1_and_imm10_share_a_left_edge() {
		assert_eq!(ARG1_LSB + ARG1_WIDTH, IMM10_LSB + IMM10_WIDTH);
	}

	#[test]
	fn pack_unpack_round_trips() {
		for lb in [0u16, 1, 31, 53, 63] {
			for a1 in [0u16, 1, 17, 31] {
				for a2 in [0u16, 1, 30, 31] {
					assert_eq!(unpack_6_5_5(pack_6_5_5(lb, a1, a2)), (lb, a1, a2));
				}
			}
			for imm in [0u16, 1, 512, 1023] {
				assert_eq!(unpack_6_10(pack_6_10(lb, imm)), (lb, imm));
			}
		}
	}
}
