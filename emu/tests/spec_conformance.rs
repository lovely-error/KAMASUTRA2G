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
	let mut interp = Interpreter::new(ptr as *mut ());
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
// 5.4 -- SUB's overflow is not the adder's carry-out
// -------------------------------------------------------------------------

/// Subtracting zero must leave `overflow` clear, even though a hardware
/// `a + ~b + 1` produces carry-out 1. The emulator forms the two's complement
/// in 32 bits, discarding the carry, so `~0 + 1 == 0` and no overflow occurs.
///
/// Hardware must therefore compute `overflow = cout & (src2 != 0)`.
#[test]
fn spec_5_4_sub_zero_does_not_set_overflow() {
	let interp = run(&asm(&[
		&encode_lc_i5_b32(1, 7),
		&encode_lc_i5_b32(2, 0),
		&sub_rr(1, 2),
		&encode_halt(),
	]));
	assert_eq!(interp.regs[1].bits, 7);
	assert!(
		!interp.regs[1].flags.overflow,
		"SUB by zero must not set overflow (spec 5.4); naive a+~b+1 carry-out would"
	);
}

/// Despite its name, `overflow` on SUB is a **not-borrow (carry)** flag, not a
/// signed-overflow flag: it is set exactly when `a >= b`. Together with the
/// zero case above, the full rule is `ov = (a >= b) && (b != 0)`.
#[test]
fn spec_5_4_sub_overflow_is_a_not_borrow_flag() {
	// a > b: no borrow -> flag SET.
	let no_borrow = run(&asm(&[
		&encode_lc_i5_b32(1, 5),
		&encode_lc_i5_b32(2, 3),
		&sub_rr(1, 2),
		&encode_halt(),
	]));
	assert_eq!(no_borrow.regs[1].bits, 2);
	assert!(no_borrow.regs[1].flags.overflow, "5-3 does not borrow, so the flag is set");

	// a < b: borrow -> flag CLEAR.
	let borrow = run(&asm(&[
		&encode_lc_i5_b32(1, 3),
		&encode_lc_i5_b32(2, 5),
		&sub_rr(1, 2),
		&encode_halt(),
	]));
	assert_eq!(borrow.regs[1].bits, 3u32.wrapping_sub(5));
	assert!(!borrow.regs[1].flags.overflow, "3-5 borrows, so the flag is clear");

	// a == b: no borrow -> flag SET.
	let equal = run(&asm(&[
		&encode_lc_i5_b32(1, 10),
		&encode_lc_i5_b32(2, 10),
		&sub_rr(1, 2),
		&encode_halt(),
	]));
	assert_eq!(equal.regs[1].bits, 0);
	assert!(equal.regs[1].flags.overflow, "equal operands do not borrow");
}

// -------------------------------------------------------------------------
// 5.1 / 5.2 -- tags and whole-register moves
// -------------------------------------------------------------------------

/// `PUC*` sets the tag but does **not** truncate the value to it.
#[test]
fn spec_5_1_put_constant_does_not_truncate_to_tag() {
	let interp = run(&asm(&[&encode_lc_i5_b16(2, -1), &encode_halt()]));
	assert_eq!(interp.regs[2].bits, 0xFFFF_FFFF, "value must not be masked to 16 bits");
	assert_eq!(interp.regs[2].datatype, DataKind::B16);
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
	assert_eq!(interp.regs[3].datatype, DataKind::B8, "CPY must carry the tag");
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

/// Comparisons are unsigned, but `XI` sign-extends the immediate -- so
/// comparing against -1 compares against 0xFFFFFFFF, and almost everything is
/// less than it.
#[test]
fn spec_5_9_comparisons_are_unsigned_against_sign_extended_immediates() {
	let interp = run(&asm(&[
		&encode_lc_i5_b32(1, 1),
		&encode_cmp_lt_ri(1, -1),
		&encode_halt(),
	]));
	assert!(
		interp.regs[1].flags.flag_bit,
		"1 < 0xFFFFFFFF unsigned must hold (spec 5.9); a signed compare would give 1 < -1 = false"
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
	assert_eq!(widening.regs[4].datatype, DataKind::B32, "UTO register tag set to B32");
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

/// `SHRA` sign-extends from bit 31 regardless of the register's tag, and only
/// then truncates to it. On a B8 register that means sign-filling from bit 31.
#[test]
fn spec_5_7_shra_sign_extends_from_bit31_then_truncates_to_tag() {
	// r1 = 0xFFFFFFFF tagged B8. SHRA by 4 sign-fills, then masks to 8 bits.
	let interp = run(&asm(&[
		&encode_lc_i5_b8(1, -1),
		&encode_shra_ri(1, 4),
		&encode_halt(),
	]));
	assert_eq!(interp.regs[1].bits, 0xFF, "sign-filled then masked to the B8 tag");
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
	assert_eq!(ins.regs[3].datatype, DataKind::B8, "BINS must not touch the tag");
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
	assert_eq!(ext.regs[3].datatype, DataKind::B32, "BEXT must set the tag to B32");
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

/// `PerformJump` with no primed `nisa` falls through. This must never be
/// "fixed": test_fibonacci's forward branch targets a TC and depends on it.
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
	assert_eq!(interp.regs[7].datatype, DataKind::B32);
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
