//! Enforces the behaviours marked **[E]** in `docs/isa-spec.md`.
//!
//! These are the quirks an implementer would most plausibly "clean up" while
//! writing the RTL, and each is cheap to reproduce in hardware when known and a
//! long debugging session when not. Pinning them here means a well-intentioned
//! fix to the emulator fails a test named after the spec section it violates,
//! rather than silently desynchronizing the RTL from its reference.
//!
//! Every test names the spec section it enforces.

use emu::insns::*;
use emu::interp::{DataKind, Flags, Interpreter, Reg};

/// Assembles code points at address 0 and runs to `HALT`.
fn run(code: &[u16]) -> Interpreter {
	let mut mem = vec![0u16; 4096];
	let ptr = mem.as_mut_ptr();
	for (i, &cp) in code.iter().enumerate() {
		unsafe { ptr.add(i).write(cp) };
	}
	let mut interp = Interpreter::new(ptr as *mut (), mem.len() * 2);
	interp.run();
	interp
}

/// Concatenates encoder outputs.
fn asm(parts: &[&[u16]]) -> Vec<u16> {
	parts.iter().flat_map(|p| p.iter().copied()).collect()
}

fn sub_rr(dst: u16, src: u16) -> [u16; 1] {
	// No encode_sub exists in insns.rs -- SUB has never had test coverage.
	[pack_6_5_5(LB::LB_SUB as u16, dst, src)]
}

fn mul_rr(dst: u16, src: u16) -> [u16; 1] {
	[pack_6_5_5(LB::LB_MUL as u16, dst, src)]
}

// -------------------------------------------------------------------------
// 5.4 -- `overflow` means "the true result did not fit"
// -------------------------------------------------------------------------

/// One meaning across all three arithmetic ops: ADD sets it on carry-out, SUB
/// on borrow, MUL when the high half is nonzero.
///
/// SUB previously formed the two's complement in 32 bits and took *that*
/// carry, which made the flag a not-borrow flag and, because `~0 + 1 == 0`
/// wraps, left it wrong for `b == 0` specifically.
#[test]
fn spec_5_4_sub_overflow_is_a_borrow_flag() {
	let cases: [(i32, i32, bool); 5] = [
		// (a, b, expect borrow)
		(7, 0, false),  // the case the old formulation got wrong
		(5, 3, false),
		(10, 10, false),
		(3, 5, true),
		(0, 1, true),
	];
	for (a, b, expect_borrow) in cases {
		let interp = run(&asm(&[
			&encode_lc_i5_b32(1, a as isize),
			&encode_lc_i5_b32(2, b as isize),
			&sub_rr(1, 2),
			&encode_halt(),
		]));
		assert_eq!(interp.regs[1].bits, (a as u32).wrapping_sub(b as u32), "{a} - {b}");
		assert_eq!(
			interp.regs[1].flags.overflow, expect_borrow,
			"{a} - {b}: overflow must mean 'borrowed' (spec 5.4)"
		);
	}
}

/// ADD's flag is the ordinary unsigned carry-out, unaffected by the SUB change.
#[test]
fn spec_5_4_add_overflow_is_carry_out() {
	let no_carry = run(&asm(&[
		&encode_lc_i5_b32(1, 5),
		&encode_add_ri(1, 3),
		&encode_halt(),
	]));
	assert!(!no_carry.regs[1].flags.overflow);

	let carry = run(&asm(&[
		&encode_llc_b32(1, 0xFFFF_FFFF),
		&encode_add_ri(1, 1),
		&encode_halt(),
	]));
	assert_eq!(carry.regs[1].bits, 0);
	assert!(carry.regs[1].flags.overflow, "0xFFFFFFFF + 1 carries out");
}

// -------------------------------------------------------------------------
// 5.1 / 5.2 -- tags and whole-register moves
// -------------------------------------------------------------------------

/// `PUC*` truncates the value to its tag, so a register's bits always match
/// what its tag claims.
#[test]
fn spec_5_1_put_constant_truncates_to_tag() {
	let interp = run(&asm(&[&encode_lc_i5_b16(2, -1), &encode_halt()]));
	assert_eq!(
		interp.regs[2].bits, 0xFFFF,
		"the sign-extended immediate must be masked to the U16 tag (spec 5.1)"
	);
	assert_eq!(interp.regs[2].datatype, DataKind::U16);

	let byte = run(&asm(&[&encode_lc_i5_b8(3, -1), &encode_halt()]));
	assert_eq!(byte.regs[3].bits, 0xFF);
}

// -------------------------------------------------------------------------
// 5.10 -- RDT: the only way to make a register signed
// -------------------------------------------------------------------------

/// `RDT` sets the tag *and* re-normalizes, so retagging a truncated unsigned
/// value as signed sign-extends it back out.
#[test]
fn spec_5_10_rdt_retags_and_renormalizes() {
	let interp = run(&asm(&[
		&encode_lc_i5_b16(1, -1), // U16, bits = 0x0000FFFF
		&encode_rdt(1, RDT::RDT_S16),
		&encode_halt(),
	]));
	assert_eq!(interp.regs[1].datatype, DataKind::S16);
	assert_eq!(
		interp.regs[1].bits, 0xFFFF_FFFF,
		"retagging as S16 must sign-extend 0xFFFF back to -1 (spec 5.10)"
	);
}

/// A sign-extending byte load is `LD8` followed by `RDT`, which is why no
/// separate signed-load opcodes are needed.
#[test]
fn spec_5_10_rdt_gives_sign_extending_byte_loads() {
	let interp = run(&asm(&[
		&encode_lc_i5_b32(1, 12), // address 192, past this code
		&encode_shl_ri(1, 4),
		&encode_lc_i5_b8(2, -1), // 0xFF, tag U8
		&encode_st(1, 2),        // store one byte
		&encode_ld_b8(3, 1),     // load it back: 0x000000FF, tag U8
		&encode_rdt(3, RDT::RDT_S8),
		&encode_halt(),
	]));
	assert_eq!(interp.regs[3].datatype, DataKind::S8);
	assert_eq!(interp.regs[3].bits, 0xFFFF_FFFF, "LD8 + RDT S8 sign-extends");
}

/// `CPY` is a full 36-bit move: value, tag, and both flag bits.
#[test]
fn spec_5_2_copy_moves_tag_and_flags() {
	// r1 gets tag B8; comparing r1 to itself sets its flag_bit.
	let interp = run(&asm(&[
		&encode_lc_i5_b8(1, 5),
		&encode_cmp_eq(1, 1),
		&encode_cpy(3, 1),
		&encode_halt(),
	]));
	assert!(interp.regs[1].flags.flag_bit, "precondition: TST set r1.flag_bit");
	assert_eq!(interp.regs[3].bits, 5);
	assert_eq!(interp.regs[3].datatype, DataKind::U8, "CPY must carry the tag");
	assert!(interp.regs[3].flags.flag_bit, "CPY must carry flag_bit");
}

// -------------------------------------------------------------------------
// 5.9 -- comparisons write only flag_bit of the left operand
// -------------------------------------------------------------------------

#[test]
fn spec_5_9_compare_writes_only_flag_bit() {
	let before = run(&asm(&[&encode_lc_i5_b8(1, 9), &encode_halt()]));
	let after = run(&asm(&[
		&encode_lc_i5_b8(1, 9),
		&encode_lc_i5_b32(2, 9),
		&encode_cmp_eq(1, 2),
		&encode_halt(),
	]));
	assert!(after.regs[1].flags.flag_bit);
	assert_eq!(after.regs[1].bits, before.regs[1].bits, "value must be untouched");
	assert_eq!(after.regs[1].datatype, before.regs[1].datatype, "tag must be untouched");
	assert!(!after.regs[1].flags.overflow, "overflow must be untouched");
}

/// An immediate carries no tag, so it takes the left operand's interpretation.
/// Against an unsigned register, `XI`'s sign-extended -1 reads as 0xFFFFFFFF.
#[test]
fn spec_5_9_immediate_takes_the_left_operands_signedness() {
	let unsigned_lhs = run(&asm(&[
		&encode_lc_i5_b32(1, 1), // U32
		&encode_cmp_lt_ri(1, -1),
		&encode_halt(),
	]));
	assert!(
		unsigned_lhs.regs[1].flags.flag_bit,
		"with a U32 lhs, -1 reads as 0xFFFFFFFF, so 1 < it (spec 5.9)"
	);

	let signed_lhs = run(&asm(&[
		&encode_lc_i5_b32(1, 1),
		&encode_rdt(1, RDT::RDT_S32),
		&encode_cmp_lt_ri(1, -1),
		&encode_halt(),
	]));
	assert!(
		!signed_lhs.regs[1].flags.flag_bit,
		"with an S32 lhs, -1 reads as -1, so 1 < -1 is false (spec 5.9)"
	);
}

/// Both operands widen to 33 bits by their **own** tag, so every combination of
/// signedness is mathematically correct -- no operand is privileged and there
/// is no C-style conversion trap.
#[test]
fn spec_5_9_mixed_signedness_compares_in_33_bits() {
	// -1 as S32 vs 1 as U32. A C-style "convert to unsigned" rule would make
	// this 0xFFFFFFFF < 1 = false. The 33-bit rule gives -1 < 1 = true.
	let interp = run(&asm(&[
		&encode_lc_i5_b32(1, -1),
		&encode_rdt(1, RDT::RDT_S32), // r1 = -1, signed
		&encode_lc_i5_b32(2, 1),      // r2 = 1, unsigned
		&encode_cmp_lt_rr(1, 2),
		&encode_halt(),
	]));
	assert!(
		interp.regs[1].flags.flag_bit,
		"-1 (S32) < 1 (U32) must be true (spec 5.9); a 32-bit comparator cannot get this right"
	);

	// 3 as S32 vs 0xFFFFFFFF as U32 -> 3 < 4294967295, true.
	let big = run(&asm(&[
		&encode_lc_i5_b32(1, 3),
		&encode_rdt(1, RDT::RDT_S32),
		&encode_llc_b32(2, 0xFFFF_FFFF), // U32
		&encode_cmp_lt_rr(1, 2),
		&encode_halt(),
	]));
	assert!(
		big.regs[1].flags.flag_bit,
		"3 (S32) < 4294967295 (U32) must be true; treating rhs as signed would give 3 < -1 = false"
	);
}

/// Equality is value equality, not bit-pattern equality: the same 32 bits under
/// different signedness denote different numbers.
#[test]
fn spec_5_9_equality_is_by_value_not_bit_pattern() {
	let interp = run(&asm(&[
		&encode_llc_b32(1, 0xFFFF_FFFF), // U32 = 4294967295
		&encode_llc_b32(2, 0xFFFF_FFFF),
		&encode_rdt(2, RDT::RDT_S32), // S32 = -1
		&encode_cmp_eq(1, 2),
		&encode_halt(),
	]));
	assert!(
		!interp.regs[1].flags.flag_bit,
		"4294967295 (U32) != -1 (S32) despite identical bits (spec 5.9)"
	);
}

// -------------------------------------------------------------------------
// 5.5 -- widening multiply
// -------------------------------------------------------------------------

/// Plain `MUL` writes `overflow`; the widening form does not.
#[test]
fn spec_5_5_mulw_does_not_write_overflow_but_mul_does() {
	let big = 0x1234_5678usize;

	let plain = run(&asm(&[
		&encode_llc_b32(1, big),
		&encode_llc_b32(2, big),
		&mul_rr(1, 2),
		&encode_halt(),
	]));
	assert!(plain.regs[1].flags.overflow, "plain MUL must set overflow on truncation");

	let widening = run(&asm(&[
		&encode_llc_b32(1, big),
		&encode_llc_b32(2, big),
		&encode_mulw_rr(1, 2, 4),
		&encode_halt(),
	]));
	let expect = (big as u64) * (big as u64);
	assert_eq!(widening.regs[1].bits, expect as u32, "low half");
	assert_eq!(widening.regs[4].bits, (expect >> 32) as u32, "high half to the UTO register");
	assert_eq!(widening.regs[4].datatype, DataKind::U32, "UTO register tag set to B32");
	assert!(
		!widening.regs[1].flags.overflow,
		"widening MUL must not write overflow (spec 5.5)"
	);
}

/// When destination and UTO register alias, the low half wins -- a write-order
/// artifact that hardware must reproduce.
#[test]
fn spec_5_5_mulw_aliased_destination_keeps_low_half() {
	let big = 0x1234_5678usize;
	let interp = run(&asm(&[
		&encode_llc_b32(1, big),
		&encode_llc_b32(2, big),
		&encode_mulw_rr(1, 2, 1), // dst == uto == r1
		&encode_halt(),
	]));
	let expect = (big as u64) * (big as u64);
	assert_eq!(
		interp.regs[1].bits, expect as u32,
		"low half must win on aliasing (spec 5.5), not the high half"
	);
}

// -------------------------------------------------------------------------
// 5.7 / 5.8 -- shifts and bit fields
// -------------------------------------------------------------------------

/// `SHRA` now respects the tag's signedness, as a consequence of the
/// bits-match-tag invariant rather than any special case in the shifter.
///
/// Previously it sign-extended from bit 31 regardless of tag, which was
/// incoherent for sub-word registers. Because a register's bits are now always
/// extended to match its tag, a 32-bit arithmetic shift does the right thing
/// for both: signed values are already sign-filled, unsigned values are already
/// non-negative so the shift degenerates to logical.
#[test]
fn spec_5_7_shra_follows_the_tags_signedness() {
	// U8 holding 255. Arithmetic-shifting a non-negative value is a logical
	// shift: 255 >> 4 = 15.
	let unsigned = run(&asm(&[
		&encode_lc_i5_b8(1, -1), // truncated to 0xFF, tag U8
		&encode_shra_ri(1, 4),
		&encode_halt(),
	]));
	assert_eq!(unsigned.regs[1].bits, 15, "255 (U8) >> 4 arithmetically is 15");

	// S8 holding -1. Arithmetic shift keeps it -1.
	let signed = run(&asm(&[
		&encode_lc_i5_b8(1, -1),
		&encode_rdt(1, RDT::RDT_S8), // bits become 0xFFFFFFFF
		&encode_shra_ri(1, 4),
		&encode_halt(),
	]));
	assert_eq!(
		signed.regs[1].bits, 0xFFFF_FFFF,
		"-1 (S8) arithmetically shifted stays -1"
	);
	assert_eq!(signed.regs[1].datatype, DataKind::S8);
}

/// `U32` is where the rule and the reasoning behind it come apart, so it is
/// pinned separately.
///
/// The argument in 5.7 -- unsigned values are non-negative, so an arithmetic
/// shift degenerates to a logical one -- holds only while the tag leaves bit 31
/// clear, which is true of `U8` and `U16` but not of `U32`. `SHRA` is
/// nonetheless specified as a plain 32-bit arithmetic shift, and stays one: the
/// alternative is a shifter that changes behaviour on a runtime tag, which is
/// exactly what made the old float path unimplementable in hardware.
#[test]
fn spec_5_7_shra_on_u32_shifts_bit_31_in() {
	let r = run(&asm(&[
		&encode_llc_b32(1, 0x8000_0000),
		&encode_shra_ri(1, 1),
		&encode_halt(),
	]));
	assert_eq!(
		r.regs[1].bits, 0xC000_0000,
		"SHRA is a 32-bit arithmetic shift regardless of tag (spec 5.7)"
	);
	assert_eq!(r.regs[1].datatype, DataKind::U32);
}

/// Extract writes the whole register; insert writes only the value.
#[test]
fn spec_5_8_extract_writes_all_state_insert_writes_only_value() {
	// Give r3 a non-default tag and a set flag, then bit-insert into it.
	let ins = run(&asm(&[
		&encode_lc_i5_b8(3, 0),
		&encode_cmp_eq(3, 3), // sets r3.flag_bit
		&encode_lc_i5_b32(2, 7),
		&encode_bins(3, 2, 4, 3),
		&encode_halt(),
	]));
	assert_eq!(ins.regs[3].bits, 0b111 << 4);
	assert_eq!(ins.regs[3].datatype, DataKind::U8, "BINS must not touch the tag");
	assert!(ins.regs[3].flags.flag_bit, "BINS must not touch the flags");

	// Extract replaces everything.
	let ext = run(&asm(&[
		&encode_lc_i5_b8(3, 0),
		&encode_cmp_eq(3, 3), // sets r3.flag_bit
		&encode_lc_i5_b32(2, -1),
		&encode_bext(3, 2, 4, 3),
		&encode_halt(),
	]));
	assert_eq!(ext.regs[3].bits, 0b111);
	assert_eq!(ext.regs[3].datatype, DataKind::U32, "BEXT must set the tag to B32");
	assert!(!ext.regs[3].flags.flag_bit, "BEXT must clear the flags");
}

// -------------------------------------------------------------------------
// 4.2 -- long constants
// -------------------------------------------------------------------------

/// `LLC_B32` stores its immediate high-halfword-first, against the grain of the
/// otherwise little-endian instruction stream.
#[test]
fn spec_4_2_llc_b32_is_high_halfword_first() {
	let code = encode_llc_b32(1, 0x1234_5678);
	assert_eq!(code[1], 0x1234, "second code point carries the HIGH half");
	assert_eq!(code[2], 0x5678, "third code point carries the LOW half");

	let interp = run(&asm(&[&code, &encode_halt()]));
	assert_eq!(interp.regs[1].bits, 0x1234_5678);
}

// -------------------------------------------------------------------------
// 6 -- control transfer
// -------------------------------------------------------------------------

/// `PerformJump` with no primed `nisa` falls through.
///
/// This is structural, not incidental: it is what makes predicated branches
/// work. In `XCP rA, c : DISPI target` followed by `TC`, a false predicate
/// suppresses the DISPI, so `nisa` is never primed and the TC *must* do
/// nothing. See `spec_6_5_predicated_branch_not_taken` below.
#[test]
fn spec_6_5_perform_jump_without_primed_nisa_is_a_nop() {
	let interp = run(&asm(&[
		&encode_ctrl_trn(), // no PrepareJump before it
		&encode_lc_i5_b32(1, 11),
		&encode_halt(),
	]));
	assert_eq!(
		interp.regs[1].bits, 11,
		"execution must fall through an unprimed TC (spec 6.5)"
	);
}

/// The real reason 6.5 must hold: a not-taken predicated branch leaves `nisa`
/// unprimed, and the TC that follows has to fall through into the next
/// instruction. Without this, conditional branches would be impossible.
#[test]
fn spec_6_5_predicated_branch_not_taken_falls_through() {
	let interp = run(&asm(&[
		&encode_lc_i5_b32(1, 1), // non-zero, so VALUE_ZERO is false
		&encode_xcp(1, CC::CC_VALUE_ZERO),
		&encode_disp_imm(6), // suppressed: nisa never primed
		&encode_ctrl_trn(),  // must be a NOP
		&encode_lc_i5_b32(2, 7),
		&encode_halt(),
	]));
	assert_eq!(
		interp.regs[2].bits, 7,
		"a not-taken predicated branch must fall through its TC (spec 6.5)"
	);
}

/// Double priming is legal and the last prime wins, which makes the
/// two-target select idiom well defined.
#[test]
fn spec_6_6_double_prime_last_one_wins() {
	// r1 == 0, so the XCP arm primes and the XCN arm does not: target A.
	let take_first = run(&asm(&[
		&encode_lc_i5_b32(1, 0),
		&encode_xcp(1, CC::CC_VALUE_ZERO),
		&encode_disp_imm(6), // isa=2 -> 2+12 = 14
		&encode_xcn(1, CC::CC_VALUE_ZERO),
		&encode_disp_imm(7), // isa=6 -> 6+14 = 20
		&encode_ctrl_trn(),  // 10
		&encode_lc_i5_b32(2, 1), // 12: skipped
		&encode_lc_i5_b32(3, 11), // 14: target A
		&encode_halt(),           // 16
		&encode_nop(),            // 18
		&encode_lc_i5_b32(3, 12), // 20: target B
		&encode_halt(),
	]));
	assert_eq!(take_first.regs[3].bits, 11, "predicate true -> first target");

	// Both arms prime unconditionally: the second must win.
	let last_wins = run(&asm(&[
		&encode_disp_imm(7),      // isa=0 -> 0+14 = 14
		&encode_disp_imm(9),      // isa=2 -> 2+18 = 20
		&encode_ctrl_trn(),       // 4
		&encode_nop(),            // 6
		&encode_nop(),            // 8
		&encode_nop(),            // 10
		&encode_nop(),            // 12
		&encode_lc_i5_b32(3, 11), // 14: first target
		&encode_halt(),           // 16
		&encode_nop(),            // 18
		&encode_lc_i5_b32(3, 12), // 20: second target
		&encode_halt(),
	]));
	assert_eq!(
		last_wins.regs[3].bits, 12,
		"the last PrepareJump must win (spec 6.6); this used to panic"
	);
}

// -------------------------------------------------------------------------
// 4 -- the encoders must reject what they cannot encode
// -------------------------------------------------------------------------
//
// Spec 4's table fixes the effective widths: 15 bits for an ALU or comparison
// immediate, 20 for an extended DISPI. The comparison helpers used to assert 19
// and the DISPI helpers 24, so an out-of-range value was not rejected -- it
// truncated to a *different, valid* instruction. The asserts are unconditional
// rather than debug-only for the same reason: a release build silently
// encoding the wrong branch is the worst of the three outcomes.

/// The exact aliasing the wrong bound allowed: 32768 encoded identically to 0.
#[test]
#[should_panic(expected = "does not fit 15 bits")]
fn spec_4_comparison_immediate_beyond_15_bits_is_rejected() {
	encode_cmp_gt_ri(1, 32768);
}

/// And 1 << 20 encoded identically to 0.
#[test]
#[should_panic(expected = "does not fit 20 bits")]
fn spec_4_extended_dispi_beyond_20_bits_is_rejected() {
	encode_disp_imm_xim(1 << 20);
}

/// The boundaries themselves still encode, and still round-trip through the
/// decoder -- the fix must not shrink the usable range.
#[test]
fn spec_4_immediate_boundaries_still_encode() {
	for imm in [16383isize, -16384] {
		let cps = encode_cmp_gt_ri(1, imm);
		let decoded =
			emu::interp::decode_instruction(cps.as_ptr() as *const (), cps.len() * 2, 0)
				.expect("decode");
		match decoded.insn {
			emu::interp::CanonInsn::Compare { rhs: emu::interp::CmpSrc::Imm(v), .. } => {
				assert_eq!(v as i32, imm as i32, "15-bit comparison immediate {imm}");
			}
			other => panic!("expected Compare, got {other:?}"),
		}
	}

	for disp in [524287isize, -524288] {
		let cps = encode_disp_imm_xim(disp);
		let decoded =
			emu::interp::decode_instruction(cps.as_ptr() as *const (), cps.len() * 2, 0)
				.expect("decode");
		match decoded.insn {
			emu::interp::CanonInsn::PrepareJump {
				target: emu::interp::JumpTarget::RelImm(v),
				..
			} => {
				// Displacements are scaled by 2 (spec 6.2).
				assert_eq!(v as isize, disp * 2, "20-bit displacement {disp}");
			}
			other => panic!("expected PrepareJump, got {other:?}"),
		}
	}
}

// -------------------------------------------------------------------------
// 4.1 -- XIZEXT does not sign-extend
// -------------------------------------------------------------------------

/// A zero-extended immediate prefix must stay zero-extended. This previously
/// re-sign-extended from bit 19 unconditionally, so any XIZEXT value >= 512
/// silently produced a negative displacement.
#[test]
fn spec_4_1_xizext_dispi_stays_positive() {
	// Assemble XIZEXT(512) + DISPI(0) by hand: encode_disp_imm_xim only emits
	// the sign-extending XI form.
	let xizext = pack_6_10(LB::LB_XIZEXT as u16, 512);
	let dispi = pack_6_10(LB::LB_DISPI as u16, 0);
	let disp_cps = [xizext, dispi];

	// Displacement = (512 << 10 | 0) << 1 = 1048576 bytes -- far past the end
	// of this program, so a correct run halts at the instruction after the TC
	// without ever taking the branch target. Under the old behaviour the same
	// encoding produced a large NEGATIVE displacement.
	let mut code: Vec<u16> = Vec::new();
	code.extend_from_slice(&disp_cps);
	code.extend_from_slice(&encode_lc_i5_b32(1, 9));
	code.extend_from_slice(&encode_halt());

	// Decode-only check: run would jump out of bounds, so inspect the target
	// the decoder computes rather than executing it.
	let target = emu::interp::decode_instruction(code.as_ptr() as *const (), code.len() * 2, 0).expect("decode");
	match target.insn {
		emu::interp::CanonInsn::PrepareJump {
			target: emu::interp::JumpTarget::RelImm(disp),
			..
		} => {
			assert_eq!(
				disp, 1_048_576,
				"XIZEXT must not sign-extend (spec 4.1); the old code gave a negative displacement"
			);
		}
		other => panic!("expected PrepareJump, got {other:?}"),
	}
}

/// The XI form still sign-extends, so negative displacements keep working.
#[test]
fn spec_4_1_xi_dispi_still_sign_extends() {
	let cps = encode_disp_imm_xim(-2048);
	let decoded = emu::interp::decode_instruction(
		cps.as_ptr() as *const (),
		cps.len() * 2,
		0,
	)
	.expect("decode");
	match decoded.insn {
		emu::interp::CanonInsn::PrepareJump {
			target: emu::interp::JumpTarget::RelImm(disp),
			..
		} => assert_eq!(disp, -4096, "XI keeps sign-extending"),
		other => panic!("expected PrepareJump, got {other:?}"),
	}
}

/// The link register points at the code point immediately after the DISP --
/// which in the standard idiom is the TC itself, not the instruction past it.
#[test]
fn spec_6_3_link_register_points_at_the_tc() {
	// Lay the call sequence at a known address by padding with NOPs.
	let pad = encode_nop();
	let call = encode_disp_imm_xim_link(7, 4);
	let mut code: Vec<u16> = Vec::new();
	code.extend_from_slice(&pad); // 0
	code.extend_from_slice(&pad); // 2
	let call_isa = code.len() * 2; // 4
	code.extend_from_slice(&call);
	let tc_addr = code.len() * 2; // address of the TC
	code.extend_from_slice(&encode_ctrl_trn());
	code.extend_from_slice(&encode_halt());

	let interp = run(&code);
	assert_eq!(
		interp.regs[7].bits as usize, tc_addr,
		"link must be isa+len, i.e. the TC at {tc_addr}, not past it (spec 6.3); isa was {call_isa}"
	);
	assert_eq!(interp.regs[7].datatype, DataKind::U32);
}

// -------------------------------------------------------------------------
// 7 -- predication
// -------------------------------------------------------------------------

/// A false predicate suppresses the instruction's effects but still advances
/// the PC by the instruction's full length -- including its prefixes.
#[test]
fn spec_7_false_predicate_still_advances_pc_by_full_length() {
	// r1 = 1, so CC_VALUE_ZERO on r1 is false and the guarded ADD is skipped.
	// If the PC advanced by the wrong amount, decoding would desynchronize and
	// the following instruction would not produce 42.
	let interp = run(&asm(&[
		&encode_lc_i5_b32(1, 1),
		&encode_xcp(1, CC::CC_VALUE_ZERO),
		&encode_add_ri(1, 5), // 2 code points; skipped
		&encode_lc_i5_b32(2, 13),
		&encode_halt(),
	]));
	assert_eq!(interp.regs[1].bits, 1, "guarded ADD must be suppressed");
	assert_eq!(
		interp.regs[2].bits, 13,
		"decode must resume at the right address after a skipped multi-code-point instruction"
	);
}

/// The taken case, for contrast.
#[test]
fn spec_7_true_predicate_executes() {
	let interp = run(&asm(&[
		&encode_lc_i5_b32(1, 0),
		&encode_xcp(1, CC::CC_VALUE_ZERO),
		&encode_add_ri(1, 5),
		&encode_halt(),
	]));
	assert_eq!(interp.regs[1].bits, 5);
}

// -------------------------------------------------------------------------
// Appendix -- the reference program's branch targets
// -------------------------------------------------------------------------

/// The spec appendix claims both branches in the canonical fibonacci program
/// land one code point "early". Verified here so the claim cannot rot: the
/// forward branch targets the TC rather than the HALT, which is precisely what
/// makes spec 6.5 load-bearing.
#[test]
fn spec_appendix_fibonacci_forward_branch_targets_the_tc() {
	// Reproduces the layout of test_fibonacci in src/main.rs.
	let mut code: Vec<u16> = Vec::new();
	code.extend_from_slice(&encode_lc_i5_b32(1, 0)); // 0
	code.extend_from_slice(&encode_lc_i5_b32(2, 1)); // 2
	code.extend_from_slice(&encode_lc_i5_b32(3, 10)); // 4
	code.extend_from_slice(&encode_lc_i5_b32(5, 0)); // 6

	let branch_isa = code.len() * 2; // 8
	code.extend_from_slice(&encode_xcp(3, CC::CC_VALUE_ZERO)); // 8
	code.extend_from_slice(&encode_disp_imm(10)); // 10
	let forward_tc = code.len() * 2; // 12

	assert_eq!(branch_isa, 8);
	// Displacement is relative to the START of the whole prefixed instruction
	// (spec 6.2), and is shifted left by one.
	let target = branch_isa + (10 << 1);
	assert_eq!(target, 28);

	code.extend_from_slice(&encode_ctrl_trn()); // 12
	code.extend_from_slice(&encode_cpy(4, 1)); // 14
	code.extend_from_slice(&encode_add_rr(4, 2)); // 16
	code.extend_from_slice(&encode_cpy(1, 2)); // 18
	code.extend_from_slice(&encode_cpy(2, 4)); // 20
	code.extend_from_slice(&encode_add_ri(3, -1)); // 22, 2 code points
	code.extend_from_slice(&encode_disp_imm(-10)); // 26
	let loop_tc = code.len() * 2; // 28
	code.extend_from_slice(&encode_ctrl_trn()); // 28
	let halt_addr = code.len() * 2; // 30
	code.extend_from_slice(&encode_halt()); // 30

	let _ = forward_tc;
	assert_eq!(loop_tc, 28, "the loop's TC sits at 28");
	assert_eq!(halt_addr, 30, "the HALT sits at 30");
	assert_eq!(
		target, loop_tc,
		"the forward branch targets the TC at 28, not the HALT at 30 -- so it \
		 relies on TC-with-empty-nisa falling through (spec 6.5)"
	);

	let interp = run(&code);
	assert_eq!(interp.regs[1].bits, 55, "fib(10) = 55 regardless");
}
