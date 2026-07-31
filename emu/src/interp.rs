use core::mem::transmute;

use crate::insns::{
	LB, EP1, EP2, CC, unpack_6_10, unpack_6_5_5, extract_bits
};

pub struct Interpreter {
	pub ip: u32,
	pub mem_ptr: *mut (),
	pub regs: [Reg; 32],
}

impl Interpreter {
	pub fn new(mem_ptr: *mut ()) -> Self {
		Interpreter {
			ip: 0,
			mem_ptr,
			regs: [Reg {
				bits: 0,
				datatype: DataKind::U32,
				flags: Flags { overflow: false, flag_bit: false }
			}; 32],
		}
	}
	pub fn run(&mut self) {
		interpret_ucode(self);
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

fn try_decode_xc(code_point: u16) -> Option<Conditional> {
	let (lbs, arg1, arg2) = unpack_6_5_5(code_point);
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
		return None;
	};
	if lbs == LB::LB_XCP as _ {
		return Some(Conditional { is_inverted: false, rix: arg1 as _, cc })
	}
	if lbs == LB::LB_XCN as _ {
		return Some(Conditional { is_inverted: true, rix: arg1 as _, cc })
	}
	return None
}

#[derive(Debug, Clone, Copy)]
pub struct DecodedInsn {
	pub insn: CanonInsn,
	pub cond: Option<Conditional>,
	pub size_bytes: u32,
}

pub fn decode_instruction(mem_ptr: *const (), ip: u32) -> DecodedInsn {
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
	loop {
		let cp = unsafe { mem_ptr.byte_add(ip as usize + offset).cast::<u16>().read() };
		
		if let Some((imm, was_zext)) = try_decode_xim(cp) {
			extended_imm = Some(imm);
			imm_was_zext = was_zext;
			offset += 2;
			continue;
		}
		
		if let Some(cond) = try_decode_xc(cp) {
			conditional = Some(cond);
			offset += 2;
			continue;
		}
		
		let (lbs, arg1, arg2) = unpack_6_5_5(cp);
		if lbs == LB::LB_BMX_0_0 as _ {
			bit_manip = Some((arg1 as u8, arg2 as u8));
			offset += 2;
			continue;
		}
		
		if lbs == LB::LB_EP1 as _ {
			let ep1_op = arg2;
			if ep1_op == EP1::EP1_EP2 as _ {
				let ep2_op = arg1;
				if ep2_op == EP2::EP2_FLAG as _ {
					flag_op = true;
					offset += 2;
					continue;
				}
				if ep2_op == EP2::EP2_ICINVR as _ {
					drop_icache = true;
					offset += 2;
					continue;
				}
				if ep2_op == EP2::EP2_CSP as _ {
					csp = true;
					offset += 2;
					continue;
				}
				if ep2_op == EP2::EP2_MPD as _ {
					prefetch_data = true;
					offset += 2;
					continue;
				}
				if ep2_op == EP2::EP2_MPI as _ {
					prefetch_insn = true;
					offset += 2;
					continue;
				}
				break;
			} else {
				if ep1_op == EP1::EP1_UTO as _ {
					uto_reg = Some(arg1 as u8);
					offset += 2;
					continue;
				}
				if ep1_op == EP1::EP1_SS as _ {
					store_type = StoreOrdering::StoreSeq;
					gix = arg1 as u8;
					offset += 2;
					continue;
				}
				if ep1_op == EP1::EP1_SR as _ {
					store_type = StoreOrdering::StoreUnLock;
					gix = arg1 as u8;
					offset += 2;
					continue;
				}
				if ep1_op == EP1::EP1_ESP as _ {
					export_mem = true;
					gix = arg1 as u8;
					offset += 2;
					continue;
				}
				if ep1_op == EP1::EP1_SL as _ {
					load_type = LoadOrdering::LoadSeq;
					gix = arg1 as u8;
					offset += 2;
					continue;
				}
				if ep1_op == EP1::EP1_LTL as _ {
					load_type = LoadOrdering::LoadLock;
					gix = arg1 as u8;
					offset += 2;
					continue;
				}
				break;
			}
		}
		break;
	}

	let main_cp = unsafe { mem_ptr.byte_add(ip as usize + offset).cast::<u16>().read() };
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
				panic!("ILLEGAL_OPCODE: RDT with unassigned data type {arg2}")
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
			let datatype = match op {
				LB::LB_LD8 => DataKind::U8,
				LB::LB_LD16 => DataKind::U16,
				LB::LB_LD32 => DataKind::U32,
				LB::LB_LDF32 => DataKind::F32,
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
					_ => unreachable!(),
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
				unreachable!()
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
					unimplemented!("Unknown EP2 main instruction: {}", ep2_op);
				}
			} else if ep1_op == EP1::EP1_NEG as _ || ep1_op == EP1::EP1_NOT as _ {
				let kind = if ep1_op == EP1::EP1_NEG as _ {
					UnaryOp::AdditiveInverse
				} else if ep1_op == EP1::EP1_NOT as _ {
					UnaryOp::BitwiseNot
				} else {
					unimplemented!("Unknown EP1 main instruction: {}", ep1_op);
				};
				CanonInsn::Unary {
					op: kind,
					target: arg1 as u8,
					on_flags: flag_op
				}
			} else if ep1_op == EP1::EP1_LLC_B8 as _ || ep1_op == EP1::EP1_LLC_B16 as _ {
				let imm = unsafe { mem_ptr.byte_add(ip as usize + offset).cast::<u16>().read() };
				offset += 2;
				let datatype = if ep1_op == EP1::EP1_LLC_B8 as _ { DataKind::U8 } else { DataKind::U16 };
				CanonInsn::PutImmidiate {
					dst_reg: arg1 as u8,
					imm: imm as u32,
					datakind: datatype,
				}
			} else if ep1_op == EP1::EP1_LLC_B32 as _ || ep1_op == EP1::EP1_LLC_F32 as _ {
				let high = unsafe { mem_ptr.byte_add(ip as usize + offset).cast::<u16>().read() };
				offset += 2;
				let low = unsafe { mem_ptr.byte_add(ip as usize + offset).cast::<u16>().read() };
				offset += 2;
				let imm = ((high as u32) << 16) | (low as u32);
				CanonInsn::PutImmidiate {
					dst_reg: arg1 as u8,
					imm,
					datakind: DataKind::U32,
				}
			} else {
				panic!("Unknown EP1 main instruction: {}", ep1_op);
			}
		}
		_ => panic!("Unknown main opcode: {:?}", op),
	};

	DecodedInsn {
		insn,
		cond: conditional,
		size_bytes: offset as u32,
	}
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

fn interpret_ucode(
	state: &mut Interpreter,
) {
	let mut nisa = Option::<u32>::None;
	let mut ctrl_trn = false;
	loop {
		let ip = if ctrl_trn {
			ctrl_trn = false;
			let target = nisa.unwrap();
			nisa = None;
			target
		} else {
			state.ip
		};

		let decoded = decode_instruction(state.mem_ptr, ip);
		let next_ip = ip + decoded.size_bytes;

		let cond_met = if let Some(cond) = &decoded.cond {
			eval_condition(state, cond.cc, cond.rix) == !cond.is_inverted
		} else {
			true
		};

		if cond_met {
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
					let ptr = unsafe { state.mem_ptr.byte_add(addr as usize) };
					let raw = match datatype.width_bytes() {
						1 => unsafe { ptr.cast::<u8>().read() as u32 },
						2 => unsafe { ptr.cast::<u16>().read() as u32 },
						_ => unsafe { ptr.cast::<u32>().read() },
					};
					// LD8/LD16/LD32 always yield unsigned tags, so this is a
					// zero-extension today; going through `normalize` keeps the
					// bits-match-tag invariant if signed loads are ever added.
					let val = normalize(raw, datatype);
					state.regs[dst_reg as usize].bits = val;
					state.regs[dst_reg as usize].datatype = datatype;

					if let LoadOrdering::LoadSeq = type_ {
						core::sync::atomic::compiler_fence(core::sync::atomic::Ordering::SeqCst);
					}
				}
				CanonInsn::Copy { src, dst } => {
					state.regs[dst as usize] = state.regs[src as usize];
				}
				CanonInsn::Store { addr_reg, src_reg, offset, gix: _, ordering: type_ } => {
					let addr = state.regs[addr_reg as usize].bits.wrapping_add(offset);
					let src_val = state.regs[src_reg as usize].bits;
					let datatype = state.regs[src_reg as usize].datatype;
					match type_ {
						StoreOrdering::StoreSeq => {
							// core::sync::atomic::compiler_fence(core::sync::atomic::Ordering::Relaxed);
						}
						StoreOrdering::StoreUnLock => {
							core::sync::atomic::compiler_fence(core::sync::atomic::Ordering::Release);
						}
						StoreOrdering::Plain => {}
					}
					let ptr = unsafe { state.mem_ptr.byte_add(addr as usize) };
					// Width comes from the SOURCE register's tag, signed or not.
					// F32 stores raw bits rather than the old `src_val as f32`,
					// which was a numeric conversion and part of the float
					// support the spec now reserves (spec 11).
					match datatype.width_bytes() {
						1 => unsafe { ptr.cast::<u8>().write(src_val as u8) },
						2 => unsafe { ptr.cast::<u16>().write(src_val as u16) },
						_ => unsafe { ptr.cast::<u32>().write(src_val) },
					}
				}
				CanonInsn::ExportMem { .. } | CanonInsn::DropICacheRange { .. } | CanonInsn::Prefetch { .. } => {
					// No-op or diagnostic log in simulation
				}
				CanonInsn::LoadStatusReg { addr, dst, datakind } => {
					// Virtual status register load
					unimplemented!()
				}
				CanonInsn::StoreStatusReg { .. } => {
					// Virtual control register store
					unimplemented!()
				}
				CanonInsn::Arith { op, dst, src2, mulw_reg } => {
					let mut r1 = state.regs[dst as usize];
					let mut both_fp = false;
					let val1 = r1.bits;
					let val2 = match src2 {
						AluSrc::Reg(r) => {
							let r2 = state.regs[r as usize];
							if matches!((r1.datatype,r2.datatype), (DataKind::F32, DataKind::F32)) {
								both_fp = true;
							}
							r2.bits
						}
						AluSrc::Imm(imm) => imm,
					};
					match op {
						ArithOp::Add => {
							if both_fp {
								let res = ((val1 as f32) + (val2 as f32)) as u32;
								r1.bits = res;	
							} else {
								let (res, ov) = u32::overflowing_add(val1, val2);
								r1.bits = res;
								r1.flags.overflow = ov;
							}
						},
						ArithOp::Sub => {
							if both_fp {
								let res = ((val1 as f32) - (val2 as f32)) as u32;
								r1.bits = res;
							} else {
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
							}
						},
						ArithOp::Mul => {
							if both_fp {
								let res = ((val1 as f32) * (val2 as f32)) as u32;
								r1.bits = res;
							} else {
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
							}
						},
						ArithOp::Div => {
							if both_fp {
								let res = ((val1 as f32) / (val2 as f32)) as u32;
								r1.bits = res;
							} else {
								let res = val1 / val2;
								r1.bits = res;
							}
						},
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
							AluSrc::Imm(_) => panic!("invalid insn"),
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
					let target_addr = match target {
						JumpTarget::RelImm(disp) => state.ip.wrapping_add(disp as u32),
						JumpTarget::RelReg(r) => state.ip.wrapping_add(state.regs[r as usize].bits),
						JumpTarget::AbsReg(r) => state.regs[r as usize].bits,
					};
					if let Some(link) = link_reg {
						state.regs[link as usize].bits = next_ip;
						state.regs[link as usize].datatype = DataKind::U32;
					}
					nisa = Some(target_addr);
				}
				CanonInsn::Unary { op, target: dst, on_flags } => {
					let r1 = &mut state.regs[dst as usize];
					if on_flags {
						match op {
							UnaryOp::AdditiveInverse => {
								panic!("invalid insn")
							},
							UnaryOp::BitwiseNot => {
								r1.flags.flag_bit = !r1.flags.flag_bit;
							},
						};
					} else {
						match op {
							UnaryOp::AdditiveInverse => {
								if matches!(r1.datatype, DataKind::F32) {
									let v = -(r1.bits as f32);
									r1.bits = v as u32;
								} else {
									let v = (!r1.bits).wrapping_add(1);
									r1.bits = normalize(v, r1.datatype);
								}
							},
							UnaryOp::BitwiseNot => {
								let v = !r1.bits;
								r1.bits = normalize(v, r1.datatype);
							},
						}
					}
				}
				CanonInsn::Halt => {
					break;
				}
				CanonInsn::Nop => {
					// Do nothing
				},
				CanonInsn::PerformJump => {
					if let Some(next_ip) = nisa {
						state.ip = next_ip;
						ctrl_trn = true;
					}
				}
			}
		}
		if !ctrl_trn {
			state.ip = next_ip;
		}
	}
}