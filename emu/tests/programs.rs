//! End-to-end tests: assemble a `.kasm` source, run it, check what it printed.
//!
//! This is the first path that exercises the whole toolchain at once — parser,
//! layout, encoders, decoder, execution, and the CSP UART. `reference_programs.rs`
//! covers the same semantics through hand-built encoder calls, so a bug in the
//! assembler cannot hide behind a matching bug in the interpreter.

use std::path::PathBuf;

use emu::asm::assemble;
use emu::devices::{Devices, UartIo};
use emu::fault::{FaultCause, StopReason};
use emu::interp::Interpreter;

const MEM: usize = 64 * 1024;

/// The v2 address space, which must match `MEM_BYTES` in `rtl/k2g_core.sv`.
///
/// The fault programs below run against this rather than against `MEM`,
/// because one of them is about the edge of memory: `fault_range` loads from
/// the first address past the end, and under a 64 KiB test memory it would
/// fault for a reason that has nothing to do with what it is testing -- and
/// would keep passing if the real address space grew past its address.
const ADDRESS_SPACE: usize = 8 * 1024 * 1024;

fn programs_dir() -> PathBuf {
	PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("programs")
}

/// Assembles source text, runs it, and returns (UART output, stop reason).
fn run_source(src: &str, input: &[u8]) -> (String, StopReason, Vec<u32>) {
	let program = match assemble(src) {
		Ok(p) => p,
		Err(errors) => {
			let msgs: Vec<String> = errors.iter().map(|e| e.to_string()).collect();
			panic!("assembly failed:\n  {}", msgs.join("\n  "));
		}
	};

	let mut mem = vec![0u16; MEM / 2];
	let bytes = program.to_bytes();
	{
		let dst = unsafe { std::slice::from_raw_parts_mut(mem.as_mut_ptr() as *mut u8, MEM) };
		let o = program.origin as usize;
		dst[o..o + bytes.len()].copy_from_slice(&bytes);
	}

	let uart = if input.is_empty() { UartIo::buffered() } else { UartIo::with_input(input) };
	let mut interp =
		Interpreter::with_devices(mem.as_mut_ptr() as *mut (), MEM, Devices::new(uart));
	interp.ip = program.origin;
	let stop = interp.run_bounded(1_000_000);

	let out = String::from_utf8_lossy(interp.dev.uart.output()).into_owned();
	let regs = interp.regs.iter().map(|r| r.bits).collect();
	(out, stop, regs)
}

fn run_file(name: &str) -> (String, StopReason, Vec<u32>) {
	let path = programs_dir().join(name);
	let src = std::fs::read_to_string(&path)
		.unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
	run_source(&src, b"")
}

/// How each shipped program is required to stop. `None` means a clean `HALT`.
///
/// This is the half of the fault programs' job that the cosimulation cannot
/// do. The cosimulation asks only whether the two machines agree, and they
/// agree perfectly well about a program that was meant to fault and did not --
/// which is not hypothetical: the first out-of-range program written here
/// squared an address until it wrapped to 0, then compared two identical clean
/// halts and passed.
///
/// Stating it here rather than in a header comment in the `.kasm` means a
/// wrong cause is a compile error and a missing entry is a missing test,
/// instead of a line the harness quietly fails to parse and then checks
/// nothing. Together with the cosimulation's cause comparison it also pins the
/// RTL: if the emulator stops the way this table says, and the RTL stops the
/// way the emulator does, the RTL stops the way this table says.
const PROGRAM_OUTCOMES: &[(&str, Option<FaultCause>)] = &[
	("hazard.kasm", None),
	// F32 is reserved (spec 11).
	("f32_operand.kasm", Some(FaultCause::FpUnimplemented)),
	("f32_store.kasm", Some(FaultCause::FpUnimplemented)),
	("f32_predicate.kasm", Some(FaultCause::FpUnimplemented)),
	("f32_escape.kasm", None),
	// The access faults, which depend on a register value.
	("fault_access.kasm", Some(FaultCause::MisalignedLoad)),
	("fault_store.kasm", Some(FaultCause::MisalignedStore)),
	("fault_range.kasm", Some(FaultCause::AddrOutOfRange)),
	("fault_port.kasm", Some(FaultCause::BadCspPort)),
	("fault_fetch.kasm", Some(FaultCause::MisalignedFetch)),
	("fault_squashed.kasm", None),
	// The decode faults, which are properties of the encoding (spec 8.1).
	("fault_unpredicated.kasm", Some(FaultCause::DivUnimplemented)),
	("fault_prefix.kasm", Some(FaultCause::PrefixChainTooLong)),
	("fault_opcode.kasm", Some(FaultCause::IllegalOpcode)),
	("fault_condcode.kasm", Some(FaultCause::IllegalPrefixCombo)),
];

/// Runs a program against the real address space and reports how it stopped.
fn stop_of(name: &str) -> StopReason {
	let path = programs_dir().join(name);
	let src = std::fs::read_to_string(&path)
		.unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
	let program = match assemble(&src) {
		Ok(p) => p,
		Err(errors) => {
			let msgs: Vec<String> = errors.iter().map(|e| e.to_string()).collect();
			panic!("{name}: assembly failed:
  {}", msgs.join("
  "));
		}
	};
	let mut mem = vec![0u16; ADDRESS_SPACE / 2];
	let bytes = program.to_bytes();
	{
		let dst =
			unsafe { std::slice::from_raw_parts_mut(mem.as_mut_ptr() as *mut u8, ADDRESS_SPACE) };
		let o = program.origin as usize;
		dst[o..o + bytes.len()].copy_from_slice(&bytes);
	}
	let mut interp = Interpreter::with_devices(
		mem.as_mut_ptr() as *mut (),
		ADDRESS_SPACE,
		Devices::new(UartIo::buffered()),
	);
	interp.ip = program.origin;
	interp.run_bounded(1_000_000)
}

#[test]
fn shipped_programs_stop_the_way_they_are_meant_to() {
	for (name, want) in PROGRAM_OUTCOMES {
		let stop = stop_of(name);
		let ok = match (want, stop) {
			(Some(cause), StopReason::Faulted(f)) => f.cause == *cause,
			(None, StopReason::Halted) => true,
			_ => false,
		};
		assert!(ok, "{name}: expected {want:?}, got {stop:?}");
	}
}

// -------------------------------------------------------------------------
// The shipped programs
// -------------------------------------------------------------------------

#[test]
fn hello_prints_over_the_uart() {
	let (out, stop, _) = run_file("hello.kasm");
	assert_eq!(stop, StopReason::Halted, "hello.kasm must halt cleanly");
	assert_eq!(out, "Hello from KAMASUTRA2G!\r\n");
}

#[test]
fn fib_prints_55() {
	let (out, stop, regs) = run_file("fib.kasm");
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(out, "55\r\n");
	// r2 holds fib(11) once the loop has run its course.
	assert_eq!(regs[2], 89);
}

// -------------------------------------------------------------------------
// Assembler behaviour
// -------------------------------------------------------------------------

/// The three constant-load tiers. Getting this wrong is what made three
/// separate hand-written tests fail against `encode_lc_i5_*`'s range assert.
#[test]
fn constants_pick_the_shortest_encoding() {
	for (value, want_words) in [(5i64, 1usize), (-16, 1), (100, 2), (-2000, 2), (0x12345678, 3)] {
		let src = format!("puc32 r1, {value}\nhalt\n");
		let p = assemble(&src).expect("assemble");
		assert_eq!(
			p.words.len(),
			want_words + 1, // + halt
			"puc32 r1, {value} should take {want_words} code point(s), got {}",
			p.words.len() - 1
		);
	}
}

/// Whatever encoding is chosen, the value must survive.
#[test]
fn constants_round_trip_through_every_tier() {
	for value in [0i64, 5, -1, -16, 15, 100, -2000, 16383, -16384, 0x12345678, -123456] {
		let src = format!("puc32 r1, {value}\nhalt\n");
		let (_, stop, regs) = run_source(&src, b"");
		assert_eq!(stop, StopReason::Halted, "value {value}");
		assert_eq!(regs[1], value as u32, "value {value} did not round-trip");
	}
}

#[test]
fn labels_resolve_forwards_and_backwards() {
	let src = "
        dispi   forward
        tc
        puc32   r1, 1       ; skipped
        halt
forward:
        puc32   r2, 7
        dispi   back
        tc
back:
        puc32   r3, 9
        halt
";
	let (_, stop, regs) = run_source(src, b"");
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(regs[1], 0, "the skipped instruction must not run");
	assert_eq!(regs[2], 7);
	assert_eq!(regs[3], 9);
}

/// A branch far enough away needs the two-code-point form; the assembler must
/// widen it without the programmer noticing.
#[test]
fn distant_branch_widens_automatically() {
	let mut src = String::from("dispi far\ntc\n");
	for _ in 0..600 {
		src.push_str("nop\n");
	}
	src.push_str("far:\nputc:\nputc32 r1, 1\n");
	// `putc32` is not a mnemonic; use the real one.
	let src = src.replace("putc:\nputc32 r1, 1\n", "puc32 r1, 1\nhalt\n");

	let (_, stop, regs) = run_source(&src, b"");
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(regs[1], 1, "the far branch must land on its target");
}

#[test]
fn equates_are_usable_as_immediates() {
	let src = "
PORT = 0x0A
        puc32   r1, PORT
        in      r2, r1
        halt
";
	let (_, stop, regs) = run_source(src, b"");
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(regs[1], 0x0A);
	assert_eq!(regs[2], emu::devices::CORE_ID_VALUE, "CORE_ID read through an equate");
}

#[test]
fn data_directives_emit_the_right_bytes() {
	let p = assemble(".word 0x1234\n.byte 1, 2, 3\n.ascii \"AB\"\n.asciz \"C\"\n").expect("assemble");
	assert_eq!(p.words[0], 0x1234);
	assert_eq!(p.words[1], 0x0201); // little-endian byte packing
	assert_eq!(p.words[2] & 0xff, 3);
	// "AB" then "C\0"
	assert_eq!(p.words[3], u16::from_le_bytes([b'A', b'B']));
	assert_eq!(p.words[4], u16::from_le_bytes([b'C', 0]));
}

#[test]
fn if_clause_assembles() {
	let src = "
        puc32   r1, 0
        puc32   r2, 5           if r1.zero
        puc32   r3, 6           if !r1.zero
        halt
";
	let (_, stop, regs) = run_source(src, b"");
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(regs[2], 5, "the taken predicate must execute");
	assert_eq!(regs[3], 0, "the untaken predicate must not");
}

/// The clause is whitespace-delimited but operands are comma-delimited, so on a
/// memory operand the keyword lands inside what would otherwise be one operand.
#[test]
fn if_clause_survives_bracketed_operands() {
	let src = "
        puc32   r1, 0
        puc32   r5, 0x40
        puc32   r7, 0xab
        st      [r5], r7        if r1.zero
        ld32    r8, [r5]        if r1.zero
        halt
";
	let (_, stop, regs) = run_source(src, b"");
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(regs[8], 0xab, "both predicated memory ops must execute");
}

/// `.flag` writes flag bits and `if rN.flag` reads them; the two spellings sit
/// in different grammatical slots and must not interfere.
#[test]
fn flag_suffix_and_flag_condition_coexist() {
	// `.flag` combines flag bits, not values, so both operands need a
	// comparison to set theirs first.
	let src = "
        puc32   r1, 1
        puc32   r2, 2
        puc32   r4, 5
        lt      r1, r4          ; 1 < 5, sets r1's flag
        lt      r2, r4          ; 2 < 5, sets r2's flag
        and.flag r1, r2
        puc32   r3, 0
        puc32   r3, 7           if r1.flag
        halt
";
	let (_, stop, regs) = run_source(src, b"");
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(regs[3], 7, "both flags set, so their AND must be set");
}

#[test]
fn signed_comparison_via_rdt() {
	// -1 signed is less than 1 unsigned; the 33-bit rule (spec 5.9) gets this
	// right where a 32-bit comparator cannot.
	let src = "
        puc32   r1, -1
        rdt     r1, s32
        puc32   r2, 1
        lt      r1, r2
        puc32   r3, 0
        puc32   r3, 1           if r1.flag
        halt
";
	let (_, stop, regs) = run_source(src, b"");
	assert_eq!(stop, StopReason::Halted);
	assert_eq!(regs[3], 1, "-1 (S32) < 1 (U32) must hold");
}

// -------------------------------------------------------------------------
// Error reporting
// -------------------------------------------------------------------------

#[test]
fn undefined_label_is_reported_with_a_line_number() {
	let errors = assemble("        dispi   nowhere\n        halt\n").unwrap_err();
	assert_eq!(errors.len(), 1);
	assert_eq!(errors[0].line, 1);
	assert!(errors[0].message.contains("nowhere"), "got: {}", errors[0].message);
}

#[test]
fn unknown_mnemonic_is_reported() {
	let errors = assemble("        frobnicate r1\n").unwrap_err();
	assert!(errors[0].message.contains("frobnicate"), "got: {}", errors[0].message);
}

#[test]
fn duplicate_label_is_reported() {
	let errors = assemble("a:\n        halt\na:\n        halt\n").unwrap_err();
	assert!(errors.iter().any(|e| e.message.contains("duplicate")), "got: {errors:?}");
}

#[test]
fn bad_operand_count_is_reported() {
	let errors = assemble("        cpy r1\n").unwrap_err();
	assert!(errors[0].message.contains("operand"), "got: {}", errors[0].message);
}

#[test]
fn if_is_reserved_and_cannot_name_a_label() {
	for src in ["if:\n        halt\n", "if = 4\n        halt\n"] {
		let errors = assemble(src).unwrap_err();
		assert!(errors[0].message.contains("reserved"), "got: {}", errors[0].message);
	}
}

#[test]
fn malformed_if_clauses_are_reported() {
	for (src, want) in [
		("        halt if\n", "needs a condition"),
		("        halt if r4\n", "register and a flag"),
		("        halt if r4.bogus\n", "bogus"),
		("        halt if r99.zero\n", "r99"),
		("        puc32 r1, 0 if r1.zero if r2.zero\n", "only one"),
	] {
		let errors = assemble(src).unwrap_err();
		assert!(
			errors[0].message.contains(want),
			"`{src}` should mention `{want}`, got: {}",
			errors[0].message
		);
	}
}

/// The old prefix form silently dropped `flag:` wherever the encoder ignored
/// it, so a typo'd modifier assembled to something that did nothing.
#[test]
fn flag_suffix_on_an_unsupported_mnemonic_is_reported() {
	let errors = assemble("        add.flag r1, r2\n").unwrap_err();
	assert!(errors[0].message.contains(".flag"), "got: {}", errors[0].message);
}

#[test]
fn unknown_mnemonic_suffix_is_reported() {
	let errors = assemble("        add.wat r1, r2\n").unwrap_err();
	assert!(errors[0].message.contains(".wat"), "got: {}", errors[0].message);
}

// -------------------------------------------------------------------------
// Assembler / disassembler agreement
// -------------------------------------------------------------------------

/// The disassembler is built on the emulator's own decoder, so this checks the
/// assembler produced what the source said rather than checking decode twice.
#[test]
fn disassembly_matches_the_source() {
	let src = "
start:
        puc32   r1, 5
        cpy     r2, r1
        add     r2, 3
        ld32    r3, [r1+8]
        st      [r1], r2
        shl     r2, 4
        bext    r4, r2, 4, 8
        tst     r1, r2
        and.flag r1, r2
        dispi   start
        tc
        dispi   start           if r4.ov
        tc
        dispi   start           if !r3.z
        tc
        dispil  r30, start
        tc
        dispal  r30, r5
        tc
        halt
";
	let p = assemble(src).expect("assemble");
	let text = emu::dis::disassemble_range(&p.to_bytes(), 0, 0, &p.labels);
	for expect in [
		"puc32 r1, 5",
		"cpy r2, r1",
		"add r2, 3",
		"ld32 r3, [r1+8]",
		"st [r1], r2",
		"shl r2, 4",
		"bext r4, r2, 4, 8",
		"tst r1, r2",
		"and.flag r1, r2",
		"dispi start",
		"dispi start if r4.overflow",
		"dispi start if !r3.zero",
		"dispil r30, start",
		"dispal r30, r5",
		"tc",
		"halt",
	] {
		assert!(text.contains(expect), "disassembly missing `{expect}`:\n{text}");
	}
	for gone in ["xcp ", "xcn ", "uto ", "flag: "] {
		assert!(!text.contains(gone), "old prefix form `{gone}` survived:\n{text}");
	}
}

/// Closes the loop: whatever `kdis` prints must feed straight back into `kasm`
/// and produce the same bytes. This is what stops the two spellings drifting.
#[test]
fn disassembly_reassembles_to_the_same_bytes() {
	let src = "
start:
        puc32   r1, 5
        and.flag r1, r1
        puc32   r2, 6           if r1.flag
        puc32   r3, 7           if !r1.zero
        dispil  r30, start
        tc
        dispa   r30
        tc
        halt
";
	let p = assemble(src).expect("assemble");
	let bytes = p.to_bytes();
	let text = emu::dis::disassemble_range(&bytes, 0, 0, &p.labels);

	// Strip the address and encoding columns. `disassemble_range` indents
	// instructions by two spaces and emits label lines flush-left, and no
	// instruction text contains a double space, so the last column is the text.
	let round: String = text
		.lines()
		.map(|l| match l.strip_prefix("  ") {
			Some(_) => format!("        {}\n", l.rsplit("  ").next().unwrap_or("").trim()),
			None => format!("{l}\n"),
		})
		.collect();

	let p2 = assemble(&round).expect("reassemble the disassembly");
	assert_eq!(bytes, p2.to_bytes(), "round trip changed the bytes:\n{round}");
}
