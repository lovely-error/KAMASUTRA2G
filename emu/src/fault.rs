//! Machine-check faults — `docs/isa-spec.md` §8.
//!
//! The ISA has no exception mechanism, so a fault is a *precise halt*: the
//! offending instruction commits nothing, execution stops, and the cause is
//! latched where a debugger (or, on hardware, the LEDs and the halt-dump
//! monitor) can read it.
//!
//! Before this existed the emulator simply panicked, which is unusable in a
//! program that loads arbitrary images — a single stray byte aborted the
//! process instead of reporting a fault.

/// Why the machine stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FaultCause {
	/// Unassigned `LB`/`EP1`/`EP2` encoding, `DISP` with a bad `arg2`, or
	/// `RDT` naming the unassigned tag.
	IllegalOpcode = 0x01,
	/// A prefix that cannot combine with the main opcode it precedes.
	IllegalPrefixCombo = 0x02,
	/// More than [`MAX_PREFIX_CHAIN`] prefix code points.
	PrefixChainTooLong = 0x03,
	/// `DIV` is not implemented in v1; do it in software.
	DivUnimplemented = 0x04,
	/// `LDF32`, or an `F32`-tagged operand. Reserved — see spec §11.
	FpUnimplemented = 0x05,
	MisalignedLoad = 0x06,
	MisalignedStore = 0x07,
	/// A jump was primed with an odd target.
	MisalignedFetch = 0x08,
	/// Address at or beyond the end of implemented memory.
	AddrOutOfRange = 0x09,
	/// A `CSP` access to an unmapped I/O port.
	BadCspPort = 0x0A,
	/// Bit-field extract with a zero span.
	BextZeroSpan = 0x0B,
	/// A normal `HALT`, not an error. Distinguished by `StopReason`.
	HaltInsn = 0x1F,
}

/// Maximum prefix code points in one instruction (spec §3).
///
/// The emulator's decode loop was previously unbounded, so `XI XI XI …` hung
/// it. Hardware needs a bound regardless.
pub const MAX_PREFIX_CHAIN: usize = 7;

impl FaultCause {
	pub fn code(self) -> u32 {
		self as u32
	}

	pub fn name(self) -> &'static str {
		match self {
			FaultCause::IllegalOpcode => "ILLEGAL_OPCODE",
			FaultCause::IllegalPrefixCombo => "ILLEGAL_PREFIX_COMBO",
			FaultCause::PrefixChainTooLong => "PREFIX_CHAIN_TOO_LONG",
			FaultCause::DivUnimplemented => "DIV_UNIMPLEMENTED",
			FaultCause::FpUnimplemented => "FP_UNIMPLEMENTED",
			FaultCause::MisalignedLoad => "MISALIGNED_LOAD",
			FaultCause::MisalignedStore => "MISALIGNED_STORE",
			FaultCause::MisalignedFetch => "MISALIGNED_FETCH",
			FaultCause::AddrOutOfRange => "ADDR_OUT_OF_RANGE",
			FaultCause::BadCspPort => "BAD_CSP_PORT",
			FaultCause::BextZeroSpan => "BEXT_ZERO_SPAN",
			FaultCause::HaltInsn => "HALT_INSN",
		}
	}
}

/// A fault together with the extra word reported in `FAULT_INFO`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fault {
	pub cause: FaultCause,
	/// Offending address, raw code point, or 0 — depends on the cause.
	pub info: u32,
}

impl Fault {
	pub fn new(cause: FaultCause, info: u32) -> Self {
		Fault { cause, info }
	}
	pub fn bare(cause: FaultCause) -> Self {
		Fault { cause, info: 0 }
	}
}

/// Why [`crate::interp::Interpreter::run`] returned.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopReason {
	/// Executed a `HALT`.
	Halted,
	/// Faulted. `fault_addr` holds the `isa` of the offending instruction.
	Faulted(Fault),
	/// Hit the step budget without halting — a runaway program, not a fault.
	StepLimit,
}

impl StopReason {
	pub fn is_ok(self) -> bool {
		matches!(self, StopReason::Halted)
	}
}
