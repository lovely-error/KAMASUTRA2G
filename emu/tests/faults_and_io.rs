//! Faults (`docs/isa-spec.md` §8) and the CSP I/O port space (§9).
//!
//! Everything here used to be a `panic!` or an `unimplemented!()`, which made
//! the emulator unusable as a program: a single stray byte in an image aborted
//! the process instead of reporting a cause.

use emu::devices::{Devices, UartIo, port};
use emu::fault::{FaultCause, StopReason};
use emu::insns::*;
use emu::interp::Interpreter;

const MEM_WORDS: usize = 2048;

fn run_with(code: &[u16], dev: Devices) -> (Interpreter, StopReason) {
	let mut mem = vec![0u16; MEM_WORDS];
	for (i, &cp) in code.iter().enumerate() {
		mem[i] = cp;
	}
	let len = mem.len() * 2;
	let mut interp = Interpreter::with_devices(mem.as_mut_ptr() as *mut (), len, dev);
	let stop = interp.run_bounded(100_000);
	(interp, stop)
}

fn run(code: &[u16]) -> (Interpreter, StopReason) {
	run_with(code, Devices::default())
}

fn asm(parts: &[&[u16]]) -> Vec<u16> {
	parts.iter().flat_map(|p| p.iter().copied()).collect()
}

fn expect_fault(code: &[u16], want: FaultCause) -> Interpreter {
	let (interp, stop) = run(code);
	match stop {
		StopReason::Faulted(f) if f.cause == want => interp,
		other => panic!("expected {:?}, got {other:?}", want.name()),
	}
}

// -------------------------------------------------------------------------
// 8 -- faults
// -------------------------------------------------------------------------

/// A zeroed image decodes as an unassigned opcode. This is what `main()` used
/// to hit immediately, panicking before it could do anything.
#[test]
fn zeroed_memory_faults_rather_than_panicking() {
	expect_fault(&[0x0000], FaultCause::IllegalOpcode);
}

#[test]
fn halt_is_a_clean_stop_not_a_fault() {
	let (_, stop) = run(&encode_halt());
	assert_eq!(stop, StopReason::Halted);
	assert!(stop.is_ok());
}

/// The decode loop was previously unbounded, so a run of `XI` prefixes hung the
/// emulator forever rather than failing.
#[test]
fn runaway_prefix_chain_faults_instead_of_hanging() {
	let xi = pack_6_10(LB::LB_XI as u16, 1);
	let code: Vec<u16> = std::iter::repeat(xi).take(64).collect();
	expect_fault(&code, FaultCause::PrefixChainTooLong);
}

/// A chain just inside the limit still assembles into a working instruction.
#[test]
fn prefix_chain_at_the_limit_is_accepted() {
	let xi = pack_6_10(LB::LB_XI as u16, 0);
	let mut code = vec![xi; emu::fault::MAX_PREFIX_CHAIN];
	code.extend_from_slice(&encode_lc_i5_b32(1, 3));
	code.extend_from_slice(&encode_halt());
	let (interp, stop) = run(&code);
	assert_eq!(stop, StopReason::Halted, "7 prefixes must be legal");
	assert_eq!(interp.regs[1].bits, 3);
}

#[test]
fn div_faults_since_it_is_cut_from_v1() {
	let code = asm(&[
		&encode_lc_i5_b32(1, 10),
		&encode_lc_i5_b32(2, 2),
		&[pack_6_5_5(LB::LB_DIV as u16, 1, 2)],
		&encode_halt(),
	]);
	expect_fault(&code, FaultCause::DivUnimplemented);
}

/// Division by zero used to panic; now it is the same defined fault as any
/// other division.
#[test]
fn div_by_zero_faults_like_any_other_div() {
	let code = asm(&[
		&encode_lc_i5_b32(1, 10),
		&encode_lc_i5_b32(2, 0),
		&[pack_6_5_5(LB::LB_DIV as u16, 1, 2)],
		&encode_halt(),
	]);
	expect_fault(&code, FaultCause::DivUnimplemented);
}

#[test]
fn misaligned_load_faults() {
	// Address 3 is not 4-byte aligned.
	let code = asm(&[
		&encode_lc_i5_b32(1, 3),
		&encode_ld_b32(2, 1),
		&encode_halt(),
	]);
	let interp = expect_fault(&code, FaultCause::MisalignedLoad);
	assert_eq!(interp.faults.info, 3, "FAULT_INFO carries the offending address");
}

#[test]
fn misaligned_store_faults() {
	let code = asm(&[
		&encode_lc_i5_b32(1, 1), // odd address
		&encode_lc_i5_b32(2, 7), // U32 tag -> 4-byte store
		&encode_st(1, 2),
		&encode_halt(),
	]);
	expect_fault(&code, FaultCause::MisalignedStore);
}

/// A byte store is legal at any address -- alignment is per width.
#[test]
fn byte_access_is_always_aligned() {
	let code = asm(&[
		&encode_lc_i5_b32(1, 1),
		&encode_lc_i5_b8(2, 7),
		&encode_st(1, 2),
		&encode_halt(),
	]);
	let (_, stop) = run(&code);
	assert_eq!(stop, StopReason::Halted);
}

#[test]
fn out_of_range_access_faults() {
	let code = asm(&[
		&encode_lc_i5_b32(1, 1),
		&encode_shl_ri(1, 30), // 2^30, far past our memory
		&encode_ld_b32(2, 1),
		&encode_halt(),
	]);
	expect_fault(&code, FaultCause::AddrOutOfRange);
}

/// Jumping to an odd address is caught at the point of commit.
#[test]
fn misaligned_fetch_faults_at_perform_jump() {
	let code = asm(&[
		&encode_lc_i5_b32(1, 7), // odd
		&encode_disp_reg_addr(1),
		&encode_ctrl_trn(),
		&encode_halt(),
	]);
	let interp = expect_fault(&code, FaultCause::MisalignedFetch);
	assert_eq!(interp.faults.info, 7);
}

#[test]
fn bit_extract_with_zero_span_faults() {
	let code = asm(&[
		&encode_lc_i5_b32(2, 5),
		&encode_bext(1, 2, 0, 0),
		&encode_halt(),
	]);
	expect_fault(&code, FaultCause::BextZeroSpan);
}

#[test]
fn rdt_with_the_unassigned_tag_faults() {
	// 0b111 is the one RDT encoding with no meaning.
	let code = asm(&[&[pack_6_5_5(LB::LB_RDT as u16, 1, 0b111)], &encode_halt()]);
	expect_fault(&code, FaultCause::IllegalOpcode);
}

/// Faults are precise: the offending instruction commits nothing.
#[test]
fn a_faulting_instruction_commits_nothing() {
	let code = asm(&[
		&encode_lc_i5_b32(1, 9),
		&encode_lc_i5_b32(2, 3), // address 3, misaligned for a 32-bit load
		&encode_ld_b32(1, 2),    // would overwrite r1 if it committed
		&encode_halt(),
	]);
	let interp = expect_fault(&code, FaultCause::MisalignedLoad);
	assert_eq!(interp.regs[1].bits, 9, "the destination must be untouched");
}

/// `fault_addr` reports the start of the whole prefixed instruction, not the
/// code point that happened to trip.
#[test]
fn fault_addr_is_the_instruction_start_not_the_code_point() {
	let mut code = encode_lc_i5_b32(1, 3).to_vec(); // 0
	let faulting_isa = code.len() * 2; // 2
	code.extend_from_slice(&encode_xcn(1, CC::CC_VALUE_ZERO)); // prefix at 2
	code.extend_from_slice(&encode_ld_b32(2, 1)); // main at 4, misaligned
	code.extend_from_slice(&encode_halt());

	let interp = expect_fault(&code, FaultCause::MisalignedLoad);
	assert_eq!(
		interp.faults.addr as usize, faulting_isa,
		"fault_addr must be the isa (2), not the main code point (4)"
	);
}

/// The step budget catches a runaway program without pretending it is a fault.
#[test]
fn infinite_loop_hits_the_step_limit() {
	// disp -1 code point: jumps back onto itself.
	let code = asm(&[&encode_disp_imm(0), &encode_ctrl_trn()]);
	let mut mem = vec![0u16; MEM_WORDS];
	for (i, &cp) in code.iter().enumerate() {
		mem[i] = cp;
	}
	let len = mem.len() * 2;
	let mut interp = Interpreter::new(mem.as_mut_ptr() as *mut (), len);
	assert_eq!(interp.run_bounded(1000), StopReason::StepLimit);
}

// -------------------------------------------------------------------------
// 9 -- CSP I/O port space
// -------------------------------------------------------------------------

/// Writes a byte to the UART: `PUC` the port number, `PUC` the byte, `CSP+ST`.
fn uart_put(byte: u8) -> Vec<u16> {
	asm(&[
		&encode_lc_i5_b32(10, port::UART_DATA as isize),
		// A printable byte does not fit the 5-bit immediate form.
		&encode_llc_b32(11, byte as usize),
		&encode_st_mcr(10, 11),
	])
}

#[test]
fn uart_transmit_reaches_the_host() {
	let code = asm(&[&uart_put(b'H'), &uart_put(b'i'), &encode_halt()]);
	let (interp, stop) = run_with(&code, Devices::new(UartIo::buffered()));
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(interp.dev.uart.output(), b"Hi");
}

#[test]
fn uart_receive_returns_queued_input() {
	let code = asm(&[
		&encode_lc_i5_b32(10, port::UART_DATA as isize),
		&encode_ld_msr_32(1, 10),
		&encode_ld_msr_32(2, 10),
		&encode_halt(),
	]);
	let (interp, stop) = run_with(&code, Devices::new(UartIo::with_input(b"ab")));
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(interp.regs[1].bits, b'a' as u32);
	assert_eq!(interp.regs[2].bits, b'b' as u32);
}

/// `CORE_ID` is the simplest end-to-end proof that a port read works.
#[test]
fn core_id_reads_back() {
	let code = asm(&[
		&encode_lc_i5_b32(10, port::CORE_ID as isize),
		&encode_ld_msr_32(1, 10),
		&encode_halt(),
	]);
	let (interp, stop) = run(&code);
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(interp.regs[1].bits, emu::devices::CORE_ID_VALUE);
	assert_eq!(&interp.regs[1].bits.to_be_bytes(), b"K2G1");
}

/// The two directions take the port number from *different* operands, which is
/// the easiest thing to get backwards when writing the RTL.
#[test]
fn csp_load_and_store_use_different_operand_positions() {
	// Store form: port in arg1, data in arg2.
	let st = encode_st_mcr(10, 11);
	let (_, a1, a2) = unpack_6_5_5(st[st.len() - 1]);
	assert_eq!((a1, a2), (10, 11), "CSP+ST: port=arg1, data=arg2");

	// Load form: destination in arg1, port in arg2.
	let ld = encode_ld_msr_32(1, 10);
	let (_, b1, b2) = unpack_6_5_5(ld[ld.len() - 1]);
	assert_eq!((b1, b2), (1, 10), "CSP+LD: dst=arg1, port=arg2");
}

#[test]
fn unmapped_port_faults() {
	let code = asm(&[
		&encode_llc_b32(10, 30), // no such port
		&encode_ld_msr_32(1, 10),
		&encode_halt(),
	]);
	let interp = expect_fault(&code, FaultCause::BadCspPort);
	assert_eq!(interp.faults.info, 30, "FAULT_INFO carries the port number");
}

/// Writing a read-only port faults rather than being quietly dropped, so a
/// program bug shows up where it happens.
#[test]
fn writing_a_read_only_port_faults() {
	let code = asm(&[
		&encode_lc_i5_b32(10, port::CORE_ID as isize),
		&encode_lc_i5_b32(11, 0),
		&encode_st_mcr(10, 11),
		&encode_halt(),
	]);
	expect_fault(&code, FaultCause::BadCspPort);
}

#[test]
fn gpio_round_trips() {
	let code = asm(&[
		&encode_lc_i5_b32(10, port::GPIO_OUT as isize),
		&encode_lc_i5_b32(11, 13),
		&encode_st_mcr(10, 11),
		&encode_ld_msr_32(1, 10),
		&encode_halt(),
	]);
	let (interp, stop) = run(&code);
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(interp.regs[1].bits, 13);
	assert_eq!(interp.dev.gpio_out, 13);
}

#[test]
fn cycle_counter_advances() {
	let code = asm(&[
		&encode_lc_i5_b32(10, port::CYCLE_COUNT_LO as isize),
		&encode_ld_msr_32(1, 10),
		&encode_ld_msr_32(2, 10),
		&encode_halt(),
	]);
	let (interp, _) = run(&code);
	assert!(
		interp.regs[2].bits > interp.regs[1].bits,
		"the counter must advance between two reads"
	);
}

/// Ordering prefixes are ignored in v1, but their use is recorded so a program
/// written for a multicore machine can be spotted.
#[test]
fn ignored_ordering_prefix_sets_sticky_status() {
	let code = asm(&[
		&encode_llc_b32(1, 64),
		&encode_ld_seq_b32(2, 1, 0),
		&encode_lc_i5_b32(10, port::STICKY_STATUS as isize),
		&encode_ld_msr_32(3, 10),
		&encode_halt(),
	]);
	let (interp, stop) = run(&code);
	assert_eq!(stop, StopReason::Halted, "the load itself must still happen");
	assert_eq!(
		interp.regs[3].bits & emu::devices::STICKY_REMOVED_ORDERING_PREFIX,
		emu::devices::STICKY_REMOVED_ORDERING_PREFIX
	);
}

/// Double priming is legal by default and faults only when asked (spec §6.6).
#[test]
fn compat_flag_restores_double_prime_fault() {
	let code = asm(&[
		&encode_lc_i5_b32(10, port::COMPAT_FLAGS as isize),
		&encode_lc_i5_b32(11, 1), // COMPAT_TRAP_ON_DOUBLE_PRIME
		&encode_st_mcr(10, 11),
		&encode_disp_imm(4),
		&encode_disp_imm(6), // second prime
		&encode_ctrl_trn(),
		&encode_halt(),
	]);
	expect_fault(&code, FaultCause::DoublePrime);

	// Without the flag the same sequence is fine.
	let ok = asm(&[
		&encode_disp_imm(3),
		&encode_disp_imm(3),
		&encode_ctrl_trn(),
		&encode_halt(),
	]);
	let (_, stop) = run(&ok);
	assert_ne!(
		stop,
		StopReason::Faulted(emu::fault::Fault::bare(FaultCause::DoublePrime)),
		"double priming must be legal by default"
	);
}
