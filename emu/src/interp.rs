use core::mem::transmute;

use crate::devices::{Devices, FaultRegs};
use crate::fault::{Fault, FaultCause, MAX_PREFIX_CHAIN, StopReason};
use crate::insns::{
	LB, EP1, EP2, CC, unpack_6_10, unpack_6_5_5, extract_bits
};

pub struct Interpreter {
	pub ip: u32,
	pub mem_ptr: *mut (),
	/// Size of the memory behind `mem_ptr`. Needed for `ADDR_OUT_OF_RANGE`;
	/// without it the interpreter would happily dereference anything.
	pub mem_bytes: usize,
	pub regs: [Reg; 32],
	/// The "next instruction address" latch: primed by `PrepareJump`, consumed
	/// by `PerformJump`. Architectural state, so it lives here rather than as a
	/// local of the run loop — the cosimulation trace needs to see it.
	pub nisa: Option<u32>,
	/// Retired instruction count, exposed via the `CYCLE_COUNT_*` ports.
	pub cycles: u64,
	pub dev: Devices,
	pub faults: FaultRegs,
}

const RESET_REG: Reg = Reg {
	bits: 0,
	datatype: DataKind::U32,
	flags: Flags { overflow: false, flag_bit: false },
};

impl Interpreter {
	pub fn new(mem_ptr: *mut (), mem_bytes: usize) -> Self {
		Interpreter {
			ip: 0,
			mem_ptr,
			mem_bytes,
			regs: [RESET_REG; 32],
			nisa: None,
			cycles: 0,
			dev: Devices::default(),
			faults: FaultRegs::default(),
		}
	}

	pub fn with_devices(mem_ptr: *mut (), mem_bytes: usize, dev: Devices) -> Self {
		let mut it = Interpreter::new(mem_ptr, mem_bytes);
		it.dev = dev;
		it
	}

	/// Runs until `HALT`, a fault, or `max_steps` instructions retire.
	///
	/// The step budget is what keeps a runaway program from hanging a test or
	/// the cosimulation harness; it is not an architectural limit.
	pub fn run_bounded(&mut self, max_steps: u64) -> StopReason {
		for _ in 0..max_steps {
			match self.step() {
				Ok(true) => {}
				Ok(false) => return StopReason::Halted,
				Err(fault) => return StopReason::Faulted(fault),
			}
		}
		StopReason::StepLimit
	}

	/// Convenience wrapper with a generous budget, for tests.
	pub fn run(&mut self) -> StopReason {
		self.run_bounded(10_000_000)
	}

	// ---- memory access -------------------------------------------------

	fn in_range(&self, addr: u32, width: u32) -> bool {
		let end = addr as u64 + width as u64;
		end <= self.mem_bytes as u64
	}

	fn read_mem(&self, addr: u32, width: u32) -> Result<u32, Fault> {
		if addr % width != 0 {
			return Err(Fault::new(FaultCause::MisalignedLoad, addr));
		}
		if !self.in_range(addr, width) {
			return Err(Fault::new(FaultCause::AddrOutOfRange, addr));
		}
		let ptr = unsafe { self.mem_ptr.byte_add(addr as usize) };
		Ok(match width {
			1 => unsafe { ptr.cast::<u8>().read() as u32 },
			2 => unsafe { ptr.cast::<u16>().read() as u32 },
			_ => unsafe { ptr.cast::<u32>().read() },
		})
	}

	fn write_mem(&mut self, addr: u32, width: u32, value: u32) -> Result<(), Fault> {
		if addr % width != 0 {
			return Err(Fault::new(FaultCause::MisalignedStore, addr));
		}
		if !self.in_range(addr, width) {
			return Err(Fault::new(FaultCause::AddrOutOfRange, addr));
		}
		let ptr = unsafe { self.mem_ptr.byte_add(addr as usize) };
		match width {
			1 => unsafe { ptr.cast::<u8>().write(value as u8) },
			2 => unsafe { ptr.cast::<u16>().write(value as u16) },
			_ => unsafe { ptr.cast::<u32>().write(value) },
		}
		Ok(())
	}
}

/// Normalizes a value to its register's tag.
///
/// **Invariant:** a register's 32 bits always hold its value already extended
/// according to its tag -- zero-extended for unsigned tags, sign-extended for
/// signed ones. Every write that sets a tag maintains this, which is what lets
/// comparisons and arithmetic work on the raw 32 bits without re-deriving the
/// width each time.
///
/// This replaces the older `truncate`, which only ever masked. Masking is still
/// what happens for unsigned tags; signed tags sign-extend instead.
pub fn normalize(bits: u32, datakind: DataKind) -> u32 {
	match datakind {
		DataKind::U32 | DataKind::S32 | DataKind::F32 => bits,
		DataKind::U16 => bits & 0xFFFF,
		DataKind::U8 => bits & 0xFF,
		DataKind::S16 => ((bits as i32) << 16 >> 16) as u32,
		DataKind::S8 => ((bits as i32) << 24 >> 24) as u32,
	}
}

impl DataKind {
	/// Whether this tag denotes a signed integer.
	pub fn is_signed(self) -> bool {
		matches!(self, DataKind::S8 | DataKind::S16 | DataKind::S32)
	}

	/// Access width in bytes. Drives load size and, via the *source* register's
	/// tag, store size -- there is no `ST8`/`ST16`/`ST32`.
	pub fn width_bytes(self) -> u32 {
		match self {
			DataKind::U8 | DataKind::S8 => 1,
			DataKind::U16 | DataKind::S16 => 2,
			DataKind::U32 | DataKind::S32 | DataKind::F32 => 4,
		}
	}

	/// Widens to 33 bits according to *this* tag, for mixed-signedness
	/// comparison (see `docs/isa-spec.md` §5.9).
	///
	/// s32 spans [-2^31, 2^31-1] and u32 spans [0, 2^32-1]; their union does
	/// not fit in 32 bits, so any 32-bit comparator must misorder some pairs.
	/// One extra bit makes every combination of tags exactly correct, and costs
	/// about one LUT in hardware since the comparator is already a subtractor.
	pub fn widen_to_i33(self, bits: u32) -> i64 {
		if self.is_signed() { (bits as i32) as i64 } else { bits as i64 }
	}
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Flags {
	pub overflow: bool,
	pub flag_bit: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Reg {
	pub bits: u32,
	pub datatype: DataKind,
	pub flags: Flags
}

/// Register data type tag. Discriminants match `insns::RDT` exactly, so the
/// instruction field and this enum are the same encoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum DataKind {
	U8  = 0b000,
	U16 = 0b001,
	U32 = 0b010,
	/// Reserved. Raises `FP_UNIMPLEMENTED`; see `docs/isa-spec.md` §11.
	F32 = 0b011,
	S8  = 0b100,
	S16 = 0b101,
	S32 = 0b110,
}

impl DataKind {
	/// Decodes an `RDT` instruction field. `0b111` is unassigned.
	pub fn from_rdt(value: u16) -> Option<DataKind> {
		Some(match value & 0b111 {
			0b000 => DataKind::U8,
			0b001 => DataKind::U16,
			0b010 => DataKind::U32,
			0b011 => DataKind::F32,
			0b100 => DataKind::S8,
			0b101 => DataKind::S16,
			0b110 => DataKind::S32,
			_ => return None,
		})
	}
}

fn sext_i5(val: u16) -> u32 {
	let mut val = val as u32;
	let ext = (1u32 << 4) & val != 0;
	if ext { val |= (-1i32 as u32) << 5 };
	return val
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoadOrdering {
	LoadLock, LoadSeq, Plain
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreOrdering {
	StoreUnLock, StoreSeq, Plain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AluSrc {
	Reg(u8),
	Imm(u32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShiftSrc {
	Reg(u8),
	Imm(u32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmpSrc {
	Reg(u8),
	Imm(u32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JumpTarget {
	RelImm(i32),
	RelReg(u8),
	AbsReg(u8),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnaryOp {
	AdditiveInverse, // two complement inverse
	BitwiseNot
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConditionCode {
	Overflowing,
	FlagSet,
	ValueIsZero,
	ValueIsNegative,
	ValueIsPositive
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComparisonKind {
	Equal,
	NotEqual,
	Greater,
	GreaterOrEq,
	Less,
	LessOrEq,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArithOp {
	Add,
	Sub,
	Mul,
	Div
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogicOp {
	And, Or, Xor
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShiftOp {
	LogicalShiftLeft,
	LogicalShiftRight,
	ArithmeticShiftRight,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CanonInsn {
	PutImmidiate {
		dst_reg: u8,
		imm: u32,
		datakind: DataKind,
	},
	Load {
		addr_reg: u8,
		dst_reg: u8,
		offset: u32,
		datakind: DataKind,
		gix: u8,
		ordering: LoadOrdering,
	},
	Copy {
		src: u8,
		dst: u8
	},
	/// `RDT rd, kind` -- retag a register and re-normalize its value to the new
	/// tag. The only way to make a register signed; `PUC*`/`LD*` always produce
	/// the unsigned variant of their width.
	SetDataType {
		dst: u8,
		datakind: DataKind,
	},
	Store {
		addr_reg: u8,
		src_reg: u8,
		offset: u32,
		gix: u8,
		ordering: StoreOrdering
	},
	ExportMem {
		start: u8,
		span: u8,
		gix: u8
	},
	DropICacheRange {
		start: u8,
		span: u8,
	},
	LoadStatusReg {
		addr: u8,
		dst: u8,
		datakind: DataKind
	},
	StoreStatusReg {
		addr: u8,
		src: u8,
	},
	Arith {
		op: ArithOp,
		dst: u8,
		src2: AluSrc,
		mulw_reg: Option<u8>,
	},
	Logic {
		op: LogicOp,
		on_flags: bool,
		dst: u8,
		src2: AluSrc,
	},
	BitShift {
		op: ShiftOp,
		dst: u8,
		src2: ShiftSrc,
	},
	BitExtr {
		dst: u8,
		src: u8,
		start: u8,
		span: u8,
	},
	BitInsr {
		dst: u8,
		src: u8,
		start: u8,
		span: u8,
	},
	Compare {
		op: ComparisonKind,
		lhs: u8,
		rhs: CmpSrc,
	},
	PrepareJump {
		target: JumpTarget,
		link_reg: Option<u8>,
	},
	Unary {
		op: UnaryOp,
		target: u8,
		on_flags: bool
	},
	Prefetch {
		on_instructions: bool,
		r1: u8,
		r2: u8,
	},
	Halt,
	Nop,
	PerformJump,
}

/// Decodes an immediate-extension prefix.
///
/// Returns the extended value and whether it came from `XIZEXT` (zero-extended)
/// rather than `XI` (sign-extended). `DISPI` needs to know which, because a
/// zero-extended prefix must not be re-sign-extended when the 20-bit
/// displacement is assembled -- see `docs/isa-spec.md` §4.1.
fn try_decode_xim(code_point: u16) -> Option<(u32, bool)> {
	let (lbs, imm) = unpack_6_10(code_point);
	let imm = imm as u32;
	if lbs == LB::LB_XI as _ {
		let neg = imm & (1 << 9) != 0;
		let sexted = if neg { imm | (u32::MAX << 10) } else { imm };
		return Some((sexted, false));
	}
	if lbs == LB::LB_XIZEXT as _ {
		return Some((imm, true));
	}
	return None
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Conditional {
	pub is_inverted: bool,
	pub rix: u8,
	pub cc: ConditionCode
}

/// Decodes an `XCP`/`XCN` predicate prefix.
///
/// `Ok(None)` means this code point is not one; `Err` means it is, and names a
/// condition code outside the assigned set.
///
/// Those two used to be the same answer. The opcode was checked *after* the
/// condition code, so an `XCP` with an unassigned code returned "not a prefix",
/// and the decoder went on to treat a predicate prefix as a main opcode --
/// which decoded as whatever `LB_XCP` happens to mean in the main table. Spec 7
/// calls it `ILLEGAL_PREFIX_COMBO`, and the RTL has always raised it.
fn try_decode_xc(code_point: u16) -> Result<Option<Conditional>, Fault> {
	let (lbs, arg1, arg2) = unpack_6_5_5(code_point);
	let is_inverted = if lbs == LB::LB_XCP as _ {
		false
	} else if lbs == LB::LB_XCN as _ {
		true
	} else {
		return Ok(None);
	};
	let cc = if arg2 == CC::CC_FLAG_SET as _ {
		ConditionCode::FlagSet
	} else if arg2 == CC::CC_OVERFLOW_SET as _ {
		ConditionCode::Overflowing
	} else if arg2 == CC::CC_VALUE_ZERO as _ {
		ConditionCode::ValueIsZero
	} else if arg2 == CC::CC_VALUE_POSITIVE as _ {
		ConditionCode::ValueIsPositive
	} else if arg2 == CC::CC_VALUE_NEGATIVE as _ {
		ConditionCode::ValueIsNegative
	} else {
		return Err(Fault::new(FaultCause::IllegalPrefixCombo, code_point as u32));
	};
	Ok(Some(Conditional { is_inverted, rix: arg1 as _, cc }))
}

#[derive(Debug, Clone, Copy)]
pub struct DecodedInsn {
	pub insn: CanonInsn,
	pub cond: Option<Conditional>,
	pub size_bytes: u32,
}

/// Decodes the instruction starting at `ip`.
///
/// Fallible because decode is where most faults originate: unassigned
/// encodings, impossible prefix combinations, and runaway prefix chains.
pub fn decode_instruction(
	mem_ptr: *const (),
	mem_bytes: usize,
	ip: u32,
) -> Result<DecodedInsn, Fault> {
	// Bounds-checked code point fetch. Instruction addresses are always
	// halfword aligned, so only the range needs checking.
	let fetch = |addr: u32| -> Result<u16, Fault> {
		if (addr as u64 + 2) > mem_bytes as u64 {
			return Err(Fault::new(FaultCause::AddrOutOfRange, addr));
		}
		Ok(unsafe { mem_ptr.byte_add(addr as usize).cast::<u16>().read() })
	};

	let mut extended_imm: Option<u32> = None;
	let mut imm_was_zext = false;
	let mut conditional: Option<Conditional> = None;
	let mut uto_reg: Option<u8> = None;
	let mut load_type = LoadOrdering::Plain;
	let mut store_type = StoreOrdering::Plain;
	let mut gix = 0u8;
	let mut export_mem = false;
	let mut drop_icache = false;
	let mut flag_op = false;
	let mut csp = false;
	let mut prefetch_data = false;
	let mut prefetch_insn = false;
	let mut bit_manip: Option<(u8, u8)> = None;

	let mut offset = 0;
	let mut prefix_count = 0usize;
	loop {
		if prefix_count > MAX_PREFIX_CHAIN {
			// The prefix that pushed the chain over the bound, re-read from
			// where it was consumed. Reporting `ip` here made `FAULT_INFO` an
			// address for this one fault and a code point for every other
			// decode fault; the RTL reports the code point it was looking at
			// when it decided, so this does too (spec 8).
			let offending = fetch(ip + offset as u32 - 2)?;
			return Err(Fault::new(FaultCause::PrefixChainTooLong, offending as u32));
		}
		let cp = fetch(ip + offset as u32)?;
		
		if let Some((imm, was_zext)) = try_decode_xim(cp) {
			extended_imm = Some(imm);
			imm_was_zext = was_zext;
			offset += 2;
			prefix_count += 1;
			continue;
		}
		
		if let Some(cond) = try_decode_xc(cp)? {
			conditional = Some(cond);
			offset += 2;
			prefix_count += 1;
			continue;
		}
		
		let (lbs, arg1, arg2) = unpack_6_5_5(cp);
		if lbs == LB::LB_BMX_0_0 as _ {
			bit_manip = Some((arg1 as u8, arg2 as u8));
			offset += 2;
			prefix_count += 1;
			continue;
		}
		
		if lbs == LB::LB_EP1 as _ {
			let ep1_op = arg2;
			if ep1_op == EP1::EP1_EP2 as _ {
				let ep2_op = arg1;
				if ep2_op == EP2::EP2_FLAG as _ {
					flag_op = true;
					offset += 2;
					prefix_count += 1;
					continue;
				}
				if ep2_op == EP2::EP2_ICINVR as _ {
					drop_icache = true;
					offset += 2;
					prefix_count += 1;
					continue;
				}
				if ep2_op == EP2::EP2_CSP as _ {
					csp = true;
					offset += 2;
					prefix_count += 1;
					continue;
				}
				if ep2_op == EP2::EP2_MPD as _ {
					prefetch_data = true;
					offset += 2;
					prefix_count += 1;
					continue;
				}
				if ep2_op == EP2::EP2_MPI as _ {
					prefetch_insn = true;
					offset += 2;
					prefix_count += 1;
					continue;
				}
				break;
			} else {
				if ep1_op == EP1::EP1_UTO as _ {
					uto_reg = Some(arg1 as u8);
					offset += 2;
					prefix_count += 1;
					continue;
				}
				if ep1_op == EP1::EP1_SS as _ {
					store_type = StoreOrdering::StoreSeq;
					gix = arg1 as u8;
					offset += 2;
					prefix_count += 1;
					continue;
				}
				if ep1_op == EP1::EP1_SR as _ {
					store_type = StoreOrdering::StoreUnLock;
					gix = arg1 as u8;
					offset += 2;
					prefix_count += 1;
					continue;
				}
				if ep1_op == EP1::EP1_ESP as _ {
					export_mem = true;
					gix = arg1 as u8;
					offset += 2;
					prefix_count += 1;
					continue;
				}
				if ep1_op == EP1::EP1_SL as _ {
					load_type = LoadOrdering::LoadSeq;
					gix = arg1 as u8;
					offset += 2;
					prefix_count += 1;
					continue;
				}
				if ep1_op == EP1::EP1_LTL as _ {
					load_type = LoadOrdering::LoadLock;
					gix = arg1 as u8;
					offset += 2;
					prefix_count += 1;
					continue;
				}
				break;
			}
		}
		break;
	}

	let main_cp = fetch(ip + offset as u32)?;
	offset += 2;

	let (lbs, arg1, arg2) = unpack_6_5_5(main_cp);
	let op = unsafe { transmute::<u16, LB>(lbs) };

	let insn = match op {
		LB::LB_PUC8 | LB::LB_PUC16 | LB::LB_PUC32 => {
			let datatype = match op {
				LB::LB_PUC8 => DataKind::U8,
				LB::LB_PUC16 => DataKind::U16,
				LB::LB_PUC32 => DataKind::U32,
				_ => unreachable!(),
			};
			let combined_imm = if let Some(p) = extended_imm {
				(p << 5) | (arg2 as u32)
			} else {
				sext_i5(arg2)
			};
			CanonInsn::PutImmidiate {
				dst_reg: arg1 as u8,
				// Normalized to the tag at execute time, maintaining the
				// invariant that a register's bits always match its tag.
				imm: combined_imm,
				datakind: datatype,
			}
		}
		LB::LB_RDT => {
			let Some(datakind) = DataKind::from_rdt(arg2) else {
				return Err(Fault::new(FaultCause::IllegalOpcode, main_cp as u32));
			};
			CanonInsn::SetDataType {
				dst: arg1 as u8,
				datakind,
			}
		}
		LB::LB_CPY => {
			CanonInsn::Copy {
				src: arg2 as u8,
				dst: arg1 as u8,
			}
		}
		LB::LB_LD8 | LB::LB_LD16 | LB::LB_LD32 | LB::LB_LDF32 => {
			// `LDF32` is the one opcode that exists only to produce an `F32`
			// register, so it faults on sight -- before the `CSP` split below,
			// since a float port read is no more implemented than a float load
			// (spec 8, 11).
			if op == LB::LB_LDF32 {
				return Err(Fault::new(FaultCause::FpUnimplemented, main_cp as u32));
			}
			let datatype = match op {
				LB::LB_LD8 => DataKind::U8,
				LB::LB_LD16 => DataKind::U16,
				LB::LB_LD32 => DataKind::U32,
				_ => unreachable!(),
			};
			if csp {
				CanonInsn::LoadStatusReg {
					addr: arg2 as u8,
					dst: arg1 as u8,
					datakind: datatype
				}
			} else {
				CanonInsn::Load {
					addr_reg: arg2 as u8,
					dst_reg: arg1 as u8,
					offset: extended_imm.unwrap_or(0),
					datakind: datatype,
					gix,
					ordering: load_type,
				}
			}
		}
		LB::LB_ST => {
			if drop_icache {
				CanonInsn::DropICacheRange {
					start: arg1 as u8,
					span: arg2 as u8,
				}
			} else if export_mem {
				CanonInsn::ExportMem {
					start: arg1 as u8,
					span: arg2 as u8,
					gix,
				}
			} else if csp {
				CanonInsn::StoreStatusReg {
					addr: arg1 as u8,
					src: arg2 as u8,
				}
			} else {
				CanonInsn::Store {
					addr_reg: arg1 as u8,
					src_reg: arg2 as u8,
					offset: extended_imm.unwrap_or(0),
					gix,
					ordering: store_type,
				}
			}
		}
		LB::LB_ADD | LB::LB_SUB | LB::LB_MUL | LB::LB_DIV => {
			// `DIV` is cut from v1 (spec 11), and being cut is a property of
			// the opcode, so it is rejected here rather than in execute.
			if op == LB::LB_DIV {
				return Err(Fault::new(FaultCause::DivUnimplemented, main_cp as u32));
			}
			let src2 = if let Some(p) = extended_imm {
				AluSrc::Imm((p << 5) | (arg2 as u32))
			} else {
				AluSrc::Reg(arg2 as u8)
			};
			let op = if op == LB::LB_ADD as _ {
				ArithOp::Add
			} else if op == LB::LB_SUB as _ {
				ArithOp::Sub
			} else if op == LB::LB_MUL as _ {
				ArithOp::Mul
			} else if op == LB::LB_DIV as _ {
				ArithOp::Div
			} else {
				unreachable!()
			};
			CanonInsn::Arith {
				op,
				dst: arg1 as u8,
				src2,
				mulw_reg: uto_reg
			}
		}
		LB::LB_AND | LB::LB_OR | LB::LB_XOR => {
			// `FLAG`-prefixed logic has no immediate form: there is no such
			// thing as an immediate flag bit. Both halves of that are visible
			// in decode -- the prefix and the presence of `XI`.
			if flag_op && extended_imm.is_some() {
				return Err(Fault::new(FaultCause::IllegalPrefixCombo, main_cp as u32));
			}
			let src2 = if let Some(p) = extended_imm {
				AluSrc::Imm((p << 5) | (arg2 as u32))
			} else {
				AluSrc::Reg(arg2 as u8)
			};
			let op = if op == LB::LB_AND as _ {
				LogicOp::And
			}else if op == LB::LB_OR as _ {
				LogicOp::Or
			} else if op == LB::LB_XOR as _ {
				LogicOp::Xor
			} else {
				unreachable!()
			};
			CanonInsn::Logic { 
				op: op, 
				on_flags: flag_op,
				dst: arg1 as u8,
				src2
			}
		},
		LB::LB_SHL | LB::LB_SHR | LB::LB_SHRA => {
			if let Some((start, span)) = bit_manip {
				match op {
					// A zero span is a property of the `BMX` prefix, so it is
					// rejected here rather than in execute -- see the note on
					// decode-detected faults in `step`.
					LB::LB_SHL if span == 0 => {
						return Err(Fault::new(FaultCause::BextZeroSpan, main_cp as u32));
					}
					LB::LB_SHL => CanonInsn::BitExtr {
						dst: arg1 as u8,
						src: arg2 as u8,
						start,
						span,
					},
					LB::LB_SHR => CanonInsn::BitInsr {
						dst: arg1 as u8,
						src: arg2 as u8,
						start,
						span,
					},
					// `BMX` reinterprets `SHL` and `SHR` and has no meaning on
					// `SHRA` (spec 5.8). This used to be `unreachable!()`, and
					// it was reachable: `BMX` then `SHRA` is two ordinary code
					// points, and the emulator panicked on them -- the exact
					// failure the fault mechanism exists to replace.
					_ => return Err(Fault::new(FaultCause::IllegalPrefixCombo, main_cp as u32)),
				}
			} else {
				let op = if op == LB::LB_SHL {
					ShiftOp::LogicalShiftLeft
				} else if op ==  LB::LB_SHR {
					ShiftOp::LogicalShiftRight
				} else if op ==  LB::LB_SHRA {
					ShiftOp::ArithmeticShiftRight
				} else {
					unreachable!()
				};
				CanonInsn::BitShift {
					op,
					dst: arg1 as u8,
					src2: ShiftSrc::Reg(arg2 as u8),
				}
			}
		}
		LB::LB_SHLI | LB::LB_SHRI | LB::LB_SHRAI => {
			let op = if op == LB::LB_SHLI {
				ShiftOp::LogicalShiftLeft
			} else if op ==  LB::LB_SHRI {
				ShiftOp::LogicalShiftRight
			} else if op ==  LB::LB_SHRAI {
				ShiftOp::ArithmeticShiftRight
			} else {
				unreachable!()
			};
			CanonInsn::BitShift {
				op,
				dst: arg1 as u8,
				src2: ShiftSrc::Imm(arg2 as u32),
			}
		}
		LB::LB_TST | LB::LB_TSTN | LB::LB_LT | LB::LB_GT | LB::LB_LTE | LB::LB_GTE => {
			if prefetch_data || prefetch_insn {
				CanonInsn::Prefetch {
					on_instructions: prefetch_insn,
					r1: arg1 as u8,
					r2: arg2 as u8,
				}
			} else {
				let rhs = if let Some(p) = extended_imm {
					CmpSrc::Imm((p << 5) | (arg2 as u32))
				} else {
					CmpSrc::Reg(arg2 as u8)
				};
				let op = match op {
					LB::LB_TST => ComparisonKind::Equal, 
					LB::LB_TSTN => ComparisonKind::NotEqual,
					LB::LB_LT => ComparisonKind::Less, 
					LB::LB_GT => ComparisonKind::Greater, 
					LB::LB_LTE => ComparisonKind::LessOrEq, 
					LB::LB_GTE => ComparisonKind::GreaterOrEq, 
					_ => unreachable!()
				};
				CanonInsn::Compare {
					op,
					lhs: arg1 as u8,
					rhs,
				}
			}
		}
		LB::LB_DISP => {
			let target = if arg2 == EP1::EP1_DISP_OFF as _ {
				JumpTarget::RelReg(arg1 as u8)
			} else if arg2 == EP1::EP1_DISP_ABS as _ {
				JumpTarget::AbsReg(arg1 as u8)
			} else {
				return Err(Fault::new(FaultCause::IllegalOpcode, main_cp as u32));
			};
			CanonInsn::PrepareJump {
				target,
				link_reg: uto_reg
			}
		}
		LB::LB_DISPI => {
			let (_, imm10) = unpack_6_10(main_cp);
			let disp = if let Some(p) = extended_imm {
				let mut d = (p << 10) | (imm10 as u32);
				// An XI prefix means a signed displacement, so sign-extend from
				// bit 19. XIZEXT means the caller asked for a zero-extended
				// value and must get one -- previously this extended
				// unconditionally, so any XIZEXT prefix >= 512 silently
				// produced a negative displacement (spec 4.1).
				if !imm_was_zext && (d & (1 << 19)) != 0 {
					d |= 0xfff00000;
				} else if imm_was_zext {
					d &= 0x000fffff;
				}
				d as i32
			} else {
				let mut d = imm10 as u32;
				if (d & (1 << 9)) != 0 {
					d |= 0xfffffc00;
				}
				d as i32
			};
			let disp = disp << 1;
			CanonInsn::PrepareJump {
				target: JumpTarget::RelImm(disp),
				link_reg: uto_reg
			}
		}
		LB::LB_EP1 => {
			let ep1_op = arg2;
			if ep1_op == EP1::EP1_EP2 as _ {
				let ep2_op = arg1;
				if ep2_op == EP2::EP2_HALT as _ {
					CanonInsn::Halt
				} else if ep2_op == EP2::EP2_DNO as _ {
					CanonInsn::Nop
				} else if ep2_op == EP2::EP2_TC as _ {
					CanonInsn::PerformJump
				} else {
					return Err(Fault::new(FaultCause::IllegalOpcode, main_cp as u32));
				}
			} else if ep1_op == EP1::EP1_NEG as _ || ep1_op == EP1::EP1_NOT as _ {
				let kind = if ep1_op == EP1::EP1_NEG as _ {
					UnaryOp::AdditiveInverse
				} else if ep1_op == EP1::EP1_NOT as _ {
					UnaryOp::BitwiseNot
				} else {
					return Err(Fault::new(FaultCause::IllegalOpcode, main_cp as u32));
				};
				// Negating a single bit is meaningless, and both the prefix
				// and the opcode saying so are in hand here.
				if flag_op && matches!(kind, UnaryOp::AdditiveInverse) {
					return Err(Fault::new(FaultCause::IllegalPrefixCombo, main_cp as u32));
				}
				CanonInsn::Unary {
					op: kind,
					target: arg1 as u8,
					on_flags: flag_op
				}
			} else if ep1_op == EP1::EP1_LLC_B8 as _ || ep1_op == EP1::EP1_LLC_B16 as _ {
				let imm = fetch(ip + offset as u32)?;
				offset += 2;
				let datatype = if ep1_op == EP1::EP1_LLC_B8 as _ { DataKind::U8 } else { DataKind::U16 };
				CanonInsn::PutImmidiate {
					dst_reg: arg1 as u8,
					imm: imm as u32,
					datakind: datatype,
				}
			} else if ep1_op == EP1::EP1_LLC_F32 as _ {
				// Previously decoded together with `LLC_B32` and tagged `U32`,
				// so the float long-constant silently became an integer one --
				// `LDF32` produced an `F32` register but `LLC_F32` did not.
				// Both are float opcodes and both now fault (spec 8, 11).
				return Err(Fault::new(FaultCause::FpUnimplemented, main_cp as u32));
			} else if ep1_op == EP1::EP1_LLC_B32 as _ {
				let high = fetch(ip + offset as u32)?;
				offset += 2;
				let low = fetch(ip + offset as u32)?;
				offset += 2;
				let imm = ((high as u32) << 16) | (low as u32);
				CanonInsn::PutImmidiate {
					dst_reg: arg1 as u8,
					imm,
					datakind: DataKind::U32,
				}
			} else {
				return Err(Fault::new(FaultCause::IllegalOpcode, main_cp as u32));
			}
		}
		_ => return Err(Fault::new(FaultCause::IllegalOpcode, main_cp as u32)),
	};

	Ok(DecodedInsn {
		insn,
		cond: conditional,
		size_bytes: offset as u32,
	})
}

/// Faults if the instruction reads any register carrying the reserved `F32`
/// tag (spec §8, §11).
///
/// The emulator used to *execute* on `F32` operands, along a path that
/// converted numerically instead of reinterpreting bits -- `3.0 + 4.0` in
/// registers holding 3 and 4 gave 7, not an IEEE-754 pattern. That was neither
/// the specified fault nor usable floating point, so the whole path is gone.
///
/// Only registers the instruction *reads* are checked; destination-only
/// operands are exempt. That is what leaves `RDT rd, u32` as the way back out
/// of the tag -- `RDT` re-tags a register rather than consuming its value, so
/// `F32` is a reserved encoding, not a state a program can get stuck in.
///
/// In hardware this is a comparison against tag `0b011` on each register read
/// port, which is why the check lives in one place rather than in each
/// execute arm.
fn check_no_f32_operands(state: &Interpreter, insn: &CanonInsn) -> Result<(), Fault> {
	let check = |rix: u8| -> Result<(), Fault> {
		if matches!(state.regs[rix as usize].datatype, DataKind::F32) {
			return Err(Fault::new(FaultCause::FpUnimplemented, rix as u32));
		}
		Ok(())
	};
	let check_alu = |src: AluSrc| -> Result<(), Fault> {
		match src {
			AluSrc::Reg(r) => check(r),
			AluSrc::Imm(_) => Ok(()),
		}
	};
	match *insn {
		// The destination is written whole, so its previous tag is not read.
		CanonInsn::PutImmidiate { .. } => {}
		// `RDT` -- the escape hatch described above.
		CanonInsn::SetDataType { .. } => {}
		CanonInsn::Load { addr_reg, .. } => check(addr_reg)?,
		CanonInsn::Copy { src, .. } => check(src)?,
		CanonInsn::Store { addr_reg, src_reg, .. } => {
			check(addr_reg)?;
			// The source tag picks the store width, so an `F32` source is a
			// float operand in the fullest sense.
			check(src_reg)?;
		}
		// `ESP`, `ICINVR` and `MPI`/`MPD` reinterpret their main opcode into a
		// no-op (spec 3.2, 10), and a no-op reads nothing. The RTL decodes them
		// to `UOP_NOP`, whose read ports are dead.
		CanonInsn::ExportMem { .. }
		| CanonInsn::DropICacheRange { .. }
		| CanonInsn::Prefetch { .. } => {}
		CanonInsn::LoadStatusReg { addr, .. } => check(addr)?,
		CanonInsn::StoreStatusReg { addr, src } => {
			check(addr)?;
			check(src)?;
		}
		// `mulw_reg` receives the high half and is not read.
		CanonInsn::Arith { dst, src2, .. } => {
			check(dst)?;
			check_alu(src2)?;
		}
		CanonInsn::Logic { dst, src2, .. } => {
			check(dst)?;
			check_alu(src2)?;
		}
		CanonInsn::BitShift { dst, src2, .. } => {
			check(dst)?;
			if let ShiftSrc::Reg(r) = src2 {
				check(r)?;
			}
		}
		// Extract writes the whole destination; insert merges into it (spec 5.8).
		CanonInsn::BitExtr { src, .. } => check(src)?,
		CanonInsn::BitInsr { dst, src, .. } => {
			check(dst)?;
			check(src)?;
		}
		CanonInsn::Compare { lhs, rhs, .. } => {
			check(lhs)?;
			if let CmpSrc::Reg(r) = rhs {
				check(r)?;
			}
		}
		// The link register is written, not read.
		CanonInsn::PrepareJump { target, .. } => match target {
			JumpTarget::RelReg(r) | JumpTarget::AbsReg(r) => check(r)?,
			JumpTarget::RelImm(_) => {}
		},
		CanonInsn::Unary { target, .. } => check(target)?,
		CanonInsn::Halt | CanonInsn::Nop | CanonInsn::PerformJump => {}
	}
	Ok(())
}

fn eval_condition(state: &Interpreter, cc: ConditionCode, rix: u8) -> bool {
	let r1 = state.regs[rix as usize];
	let vz = r1.bits == 0;
	let vneg = (state.regs[rix as usize].bits as i32) < 0;
	match cc {
		ConditionCode::Overflowing => {
			r1.flags.overflow
		}
		ConditionCode::FlagSet => {
			r1.flags.flag_bit
		}
		ConditionCode::ValueIsZero => {
			vz
		}
		ConditionCode::ValueIsNegative => {
			vneg
		}
		ConditionCode::ValueIsPositive => {
			!vz && !vneg
		}
	}
}

impl Interpreter {
	/// Executes one instruction.
	///
	/// Returns `Ok(true)` to continue, `Ok(false)` on `HALT`, or the fault that
	/// stopped the machine. Faults are precise: nothing this instruction would
	/// have written is committed.
	pub fn step(&mut self) -> Result<bool, Fault> {
		let state = self;
		// `isa` -- the address of the first code point of the whole prefixed
		// instruction. Displacements are relative to this, and it is what a
		// fault reports (spec 1.2).
		let isa = state.ip;

		let decoded = match decode_instruction(state.mem_ptr, state.mem_bytes, isa) {
			Ok(d) => d,
			Err(f) => return Err(state.take_fault(isa, f)),
		};
		let next_ip = isa + decoded.size_bytes;
		// Advance by default; PerformJump may override.
		state.ip = next_ip;
		state.cycles += 1;

		let cond_met = if let Some(cond) = &decoded.cond {
			// The predicate register is read whatever the outcome, so its tag
			// is checked here rather than with the operands below.
			if matches!(state.regs[cond.rix as usize].datatype, DataKind::F32) {
				let f = Fault::new(FaultCause::FpUnimplemented, cond.rix as u32);
				return Err(state.take_fault(isa, f));
			}
			eval_condition(state, cond.cc, cond.rix) == !cond.is_inverted
		} else {
			true
		};

		if cond_met {
			// Predicated off, an instruction faults on nothing -- the same rule
			// `DIV` already follows (spec 7).
			if let Err(f) = check_no_f32_operands(state, &decoded.insn) {
				return Err(state.take_fault(isa, f));
			}
			match decoded.insn {
				CanonInsn::PutImmidiate { dst_reg, imm, datakind: datatype } => {
					let reg = Reg {
						// Truncated/extended to the tag, so the register's bits
						// always match what its tag claims (spec 5.1).
						bits: normalize(imm, datatype),
						datatype: datatype,
						flags: Flags {
							overflow: false,
							flag_bit: false,
						}
					};
					state.regs[dst_reg as usize] = reg;
				}
				CanonInsn::SetDataType { dst, datakind } => {
					let r = &mut state.regs[dst as usize];
					r.bits = normalize(r.bits, datakind);
					r.datatype = datakind;
				}
				CanonInsn::Load { addr_reg, dst_reg, offset, datakind: datatype, gix: _, ordering: type_ } => {
					let addr = state.regs[addr_reg as usize].bits.wrapping_add(offset);
					let raw = match state.read_mem(addr, datatype.width_bytes()) {
						Ok(v) => v,
						Err(f) => return Err(state.take_fault(isa, f)),
					};
					// LD8/LD16/LD32 always yield unsigned tags, so this is a
					// zero-extension today; going through `normalize` keeps the
					// bits-match-tag invariant if signed loads are ever added.
					let val = normalize(raw, datatype);
					state.regs[dst_reg as usize].bits = val;
					state.regs[dst_reg as usize].datatype = datatype;

					if !matches!(type_, LoadOrdering::Plain) {
						state.dev.note_removed_ordering_prefix();
					}
				}
				CanonInsn::Copy { src, dst } => {
					state.regs[dst as usize] = state.regs[src as usize];
				}
				CanonInsn::Store { addr_reg, src_reg, offset, gix: _, ordering: type_ } => {
					let addr = state.regs[addr_reg as usize].bits.wrapping_add(offset);
					let src_val = state.regs[src_reg as usize].bits;
					let datatype = state.regs[src_reg as usize].datatype;
					if !matches!(type_, StoreOrdering::Plain) {
						state.dev.note_removed_ordering_prefix();
					}
					// Width comes from the SOURCE register's tag, signed or not.
					if let Err(f) = state.write_mem(addr, datatype.width_bytes(), src_val) {
						return Err(state.take_fault(isa, f));
					}
				}
				CanonInsn::ExportMem { .. } | CanonInsn::DropICacheRange { .. } | CanonInsn::Prefetch { .. } => {
					// No-op or diagnostic log in simulation
				}
				CanonInsn::LoadStatusReg { addr, dst, datakind } => {
					// Port number comes from arg2 (spec 9) -- the opposite
					// operand from the store form below.
					let port = state.regs[addr as usize].bits;
					let (cycles, faults) = (state.cycles, state.faults);
					match state.dev.read(port, cycles, faults) {
						Ok(v) => {
							state.regs[dst as usize].bits = normalize(v, datakind);
							state.regs[dst as usize].datatype = datakind;
						}
						Err(f) => return Err(state.take_fault(isa, f)),
					}
				}
				CanonInsn::StoreStatusReg { addr, src } => {
					// Port number comes from arg1 here (spec 9).
					let port = state.regs[addr as usize].bits;
					let value = state.regs[src as usize].bits;
					if let Err(f) = state.dev.write(port, value) {
						return Err(state.take_fault(isa, f));
					}
				}
				CanonInsn::Arith { op, dst, src2, mulw_reg } => {
					// The arithmetic unit is integer-only: `F32` operands were
					// rejected before this point, so nothing here depends on a
					// runtime tag (spec 11).
					let mut r1 = state.regs[dst as usize];
					let val1 = r1.bits;
					let val2 = match src2 {
						AluSrc::Reg(r) => state.regs[r as usize].bits,
						AluSrc::Imm(imm) => imm,
					};
					match op {
						ArithOp::Add => {
							let (res, ov) = u32::overflowing_add(val1, val2);
							r1.bits = res;
							r1.flags.overflow = ov;
						},
						ArithOp::Sub => {
							// `overflow` means "the true result did not fit",
							// consistently across ADD (carry out), SUB
							// (borrow) and MUL (high half nonzero).
							//
							// This previously formed the two's complement in
							// 32 bits, discarding its carry, which made the
							// flag a not-borrow flag AND left it wrong for
							// val2 == 0. See spec 5.4.
							let (res, borrow) = u32::overflowing_sub(val1, val2);
							r1.bits = res;
							r1.flags.overflow = borrow;
						},
						ArithOp::Mul => {
							if let Some(m_reg) = mulw_reg {
								let mul_res = (val1 as u64) * (val2 as u64);
								r1.bits = (mul_res & 0xffffffff) as u32;
								state.regs[m_reg as usize].bits = (mul_res >> 32) as u32;
								state.regs[m_reg as usize].datatype = DataKind::U32;
							} else {
								let (res, ov) = u32::overflowing_mul(val1, val2);
								r1.bits = res;
								r1.flags.overflow = ov;
							}
						},
						// Decode rejects `DIV`, so this is dead -- but a
						// reference model that loads arbitrary images must
						// fault rather than abort if that ever stops being
						// true, so it reports the cause decode would have.
						ArithOp::Div => {
							let f = Fault::bare(FaultCause::DivUnimplemented);
							return Err(state.take_fault(isa, f));
						}
					};
					state.regs[dst as usize] = r1;
				}
				CanonInsn::Logic { op, on_flags, dst, src2 } => {
					let r1 = &raw mut state.regs[dst as usize];
					if on_flags {
						let val1 = unsafe { (&*r1).flags.flag_bit };
						let val2 = match src2 {
							AluSrc::Reg(r) => {
								state.regs[r as usize].flags.flag_bit
							}
							// Rejected in decode; faulted here rather than
							// panicked for the same reason as `DIV` above.
							AluSrc::Imm(_) => {
								let f = Fault::bare(FaultCause::IllegalPrefixCombo);
								return Err(state.take_fault(isa, f));
							}
						};
						let res = match op {
							LogicOp::And => val1 && val2,
							LogicOp::Or => val1 || val2,
							LogicOp::Xor => val1 ^ val2,
						};
						unsafe { (&mut *r1).flags.flag_bit = res };
					} else {
						let r1 = unsafe { &mut*r1 };
						let val1 = r1.bits;
						let val2 = match src2 {
							AluSrc::Reg(r) => {
								state.regs[r as usize].bits
							}
							AluSrc::Imm(imm) => imm,
						};
						let res = match op {
							LogicOp::And => val1 & val2,
							LogicOp::Or => val1 | val2,
							LogicOp::Xor => val1 ^ val2,
						};
						r1.bits = res;
					}
				}
				CanonInsn::BitShift { op, dst, src2 } => {
					let r1 = state.regs[dst as usize];
					let val1 = r1.bits;
					let val2 = match src2 {
						ShiftSrc::Reg(r) => state.regs[r as usize].bits,
						ShiftSrc::Imm(imm) => imm,
					};
					let res = match op {
						ShiftOp::LogicalShiftLeft => val1.wrapping_shl(val2),
						ShiftOp::LogicalShiftRight => val1.wrapping_shr(val2),
						ShiftOp::ArithmeticShiftRight => (val1 as i32).wrapping_shr(val2) as u32,
					};
					let res = normalize(res, r1.datatype);
					state.regs[dst as usize].bits = res;
				}
				CanonInsn::BitExtr { dst, src, start, span } => {
					// A zero span never reaches here: decode rejects it.
					let r1 = state.regs[src as usize];
					let bits = extract_bits(r1.bits, start as usize, span as usize);
					let rv = Reg {
						bits: bits,
						datatype: DataKind::U32,
						flags: Flags { 
							overflow: false,
							flag_bit: false,
						},
					};
					state.regs[dst as usize] = rv;
				}
				CanonInsn::BitInsr { dst, src, start, span } => {
					let mask = if span >= 32 { u32::MAX } else { ((1u32 << span) - 1) << start };
					let val_to_insert = if span >= 32 { state.regs[src as usize].bits << start } else { (state.regs[src as usize].bits & ((1u32 << span) - 1)) << start };
					state.regs[dst as usize].bits = (state.regs[dst as usize].bits & !mask) | val_to_insert;
				}
				CanonInsn::Compare { op, lhs, rhs } => {
					let r1 = state.regs[lhs as usize];
					// Both operands widen to 33 bits according to their OWN tag,
					// then compare as signed. s32 spans [-2^31, 2^31-1] and u32
					// spans [0, 2^32-1]; their union needs 33 bits, so a 32-bit
					// comparator would have to misorder some mixed-tag pairs.
					// One extra bit makes every tag combination exact. See
					// docs/isa-spec.md 5.9.
					let a = r1.datatype.widen_to_i33(r1.bits);
					let b = match rhs {
						CmpSrc::Reg(r) => {
							let r2 = state.regs[r as usize];
							r2.datatype.widen_to_i33(r2.bits)
						}
						// An immediate carries no tag of its own, so it takes
						// the left operand's interpretation.
						CmpSrc::Imm(imm) => r1.datatype.widen_to_i33(imm),
					};
					let res = match op {
						ComparisonKind::Equal => a == b,
						ComparisonKind::NotEqual => a != b,
						ComparisonKind::Greater => a > b,
						ComparisonKind::GreaterOrEq => a >= b,
						ComparisonKind::Less => a < b,
						ComparisonKind::LessOrEq => a <= b,
					};
					state.regs[lhs as usize].flags.flag_bit = res;
				}
				CanonInsn::PrepareJump { target, link_reg } => {
					// Double priming is legal: the last prime wins. `nisa` is a
					// plain latch, so overwriting costs nothing, and it makes
					// the two-target idiom below well defined:
					//   XCP a, c : DISPI then
					//   XCN a, c : DISPI else
					//   TC
					//
					// Relative to `isa`, the start of the whole prefixed
					// instruction -- NOT to the already-advanced `state.ip`
					// (spec 6.2).
					let target_addr = match target {
						JumpTarget::RelImm(disp) => isa.wrapping_add(disp as u32),
						JumpTarget::RelReg(r) => isa.wrapping_add(state.regs[r as usize].bits),
						JumpTarget::AbsReg(r) => state.regs[r as usize].bits,
					};
					// An odd target is rejected HERE, by the instruction that
					// computed it, rather than later by the `TC` that would
					// have taken it (spec 6.4). The `TC` is not the instruction
					// that got it wrong, and it may be a long way away -- the
					// two-target idiom above puts a whole predicated branch
					// between them.
					//
					// Nothing is committed on the way out: the latch keeps
					// whatever it held and the link register is not written,
					// so a faulting prime leaves no trace (spec 8).
					if target_addr % 2 != 0 {
						let f = Fault::new(FaultCause::MisalignedFetch, target_addr);
						return Err(state.take_fault(isa, f));
					}
					if let Some(link) = link_reg {
						state.regs[link as usize].bits = next_ip;
						state.regs[link as usize].datatype = DataKind::U32;
					}
					state.nisa = Some(target_addr);
				}
				CanonInsn::Unary { op, target: dst, on_flags } => {
					let r1 = &mut state.regs[dst as usize];
					if on_flags {
						match op {
							// Rejected in decode; see `DIV` above.
							UnaryOp::AdditiveInverse => {
								let f = Fault::bare(FaultCause::IllegalPrefixCombo);
								return Err(state.take_fault(isa, f));
							}
							UnaryOp::BitwiseNot => {
								r1.flags.flag_bit = !r1.flags.flag_bit;
							},
						};
					} else {
						match op {
							UnaryOp::AdditiveInverse => {
								let v = (!r1.bits).wrapping_add(1);
								r1.bits = normalize(v, r1.datatype);
							},
							UnaryOp::BitwiseNot => {
								let v = !r1.bits;
								r1.bits = normalize(v, r1.datatype);
							},
						}
					}
				}
				CanonInsn::Halt => {
					state.faults.cause = FaultCause::HaltInsn.code();
					state.faults.addr = isa;
					return Ok(false);
				}
				CanonInsn::Nop => {
					// Do nothing
				},
				CanonInsn::PerformJump => {
					// An unprimed TC is a defined NOP, and must stay one: a
					// not-taken predicated branch leaves nisa unprimed, so
					// every conditional branch depends on this (spec 6.5).
					//
					// The target was validated when it was primed, so there is
					// nothing left for the transfer to reject: it either has a
					// latched address or it does not.
					if let Some(target) = state.nisa.take() {
						state.ip = target;
					}
				}
			}
		}
		Ok(true)
	}

	/// Latches fault state for the `FAULT_*` ports and returns the fault.
	fn take_fault(&mut self, isa: u32, fault: Fault) -> Fault {
		self.faults.cause = fault.cause.code();
		self.faults.addr = isa;
		self.faults.info = fault.info;
		fault
	}
}