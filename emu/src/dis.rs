//! `kdis` — the K2G disassembler.
//!
//! Built on [`crate::interp::decode_instruction`] rather than reimplementing
//! decode, so a disassembly can never disagree with what the emulator would
//! actually execute. That matters most in the cosimulation harness, where the
//! disassembly is what a divergence report is read against.

use std::collections::HashMap;

use crate::interp::{
	AluSrc, CanonInsn, CmpSrc, ComparisonKind, ConditionCode, DataKind, JumpTarget, LogicOp,
	ShiftOp, ShiftSrc, UnaryOp, decode_instruction,
};

fn tag_name(k: DataKind) -> &'static str {
	match k {
		DataKind::U8 => "u8",
		DataKind::U16 => "u16",
		DataKind::U32 => "u32",
		DataKind::S8 => "s8",
		DataKind::S16 => "s16",
		DataKind::S32 => "s32",
		DataKind::F32 => "f32",
	}
}

fn cc_name(c: ConditionCode) -> &'static str {
	match c {
		ConditionCode::Overflowing => "overflow",
		ConditionCode::FlagSet => "flag",
		ConditionCode::ValueIsZero => "zero",
		ConditionCode::ValueIsNegative => "neg",
		ConditionCode::ValueIsPositive => "pos",
	}
}

fn alu_src(s: AluSrc) -> String {
	match s {
		AluSrc::Reg(r) => format!("r{r}"),
		AluSrc::Imm(v) => format!("{}", v as i32),
	}
}

fn cmp_src(s: CmpSrc) -> String {
	match s {
		CmpSrc::Reg(r) => format!("r{r}"),
		CmpSrc::Imm(v) => format!("{}", v as i32),
	}
}

fn shift_src(s: ShiftSrc) -> String {
	match s {
		ShiftSrc::Reg(r) => format!("r{r}"),
		ShiftSrc::Imm(v) => format!("{v}"),
	}
}

/// Renders one decoded instruction. `isa` is needed to resolve relative
/// branch targets, and `labels` to name them when possible.
pub fn format_insn(
	insn: &CanonInsn,
	isa: u32,
	labels: &HashMap<String, u32>,
) -> String {
	let name_at = |addr: u32| -> String {
		labels
			.iter()
			.find(|(_, a)| **a == addr)
			.map(|(n, _)| n.clone())
			.unwrap_or_else(|| format!("{addr:#x}"))
	};

	match insn {
		CanonInsn::PutImmidiate { dst_reg, imm, datakind } => {
			let w = match datakind {
				DataKind::U8 => "puc8",
				DataKind::U16 => "puc16",
				_ => "puc32",
			};
			format!("{w} r{dst_reg}, {}", *imm as i32)
		}
		CanonInsn::SetDataType { dst, datakind } => {
			format!("rdt r{dst}, {}", tag_name(*datakind))
		}
		CanonInsn::Copy { src, dst } => format!("cpy r{dst}, r{src}"),
		CanonInsn::Load { addr_reg, dst_reg, offset, datakind, .. } => {
			let w = match datakind.width_bytes() {
				1 => "ld8",
				2 => "ld16",
				_ => "ld32",
			};
			if *offset == 0 {
				format!("{w} r{dst_reg}, [r{addr_reg}]")
			} else {
				format!("{w} r{dst_reg}, [r{addr_reg}{:+}]", *offset as i32)
			}
		}
		CanonInsn::Store { addr_reg, src_reg, offset, .. } => {
			if *offset == 0 {
				format!("st [r{addr_reg}], r{src_reg}")
			} else {
				format!("st [r{addr_reg}{:+}], r{src_reg}", *offset as i32)
			}
		}
		CanonInsn::LoadStatusReg { addr, dst, .. } => format!("in r{dst}, r{addr}"),
		CanonInsn::StoreStatusReg { addr, src } => format!("out r{addr}, r{src}"),
		CanonInsn::Arith { op, dst, src2, mulw_reg } => {
			let m = match op {
				crate::interp::ArithOp::Add => "add",
				crate::interp::ArithOp::Sub => "sub",
				crate::interp::ArithOp::Mul => "mul",
				crate::interp::ArithOp::Div => "div",
			};
			match mulw_reg {
				Some(hi) => format!("mulw r{dst}, {}, r{hi}", alu_src(*src2)),
				None => format!("{m} r{dst}, {}", alu_src(*src2)),
			}
		}
		CanonInsn::Logic { op, on_flags, dst, src2 } => {
			let m = match op {
				LogicOp::And => "and",
				LogicOp::Or => "or",
				LogicOp::Xor => "xor",
			};
			let p = if *on_flags { "flag: " } else { "" };
			format!("{p}{m} r{dst}, {}", alu_src(*src2))
		}
		CanonInsn::BitShift { op, dst, src2 } => {
			let m = match op {
				ShiftOp::LogicalShiftLeft => "shl",
				ShiftOp::LogicalShiftRight => "shr",
				ShiftOp::ArithmeticShiftRight => "shra",
			};
			format!("{m} r{dst}, {}", shift_src(*src2))
		}
		CanonInsn::BitExtr { dst, src, start, span } => {
			format!("bext r{dst}, r{src}, {start}, {span}")
		}
		CanonInsn::BitInsr { dst, src, start, span } => {
			format!("bins r{dst}, r{src}, {start}, {span}")
		}
		CanonInsn::Compare { op, lhs, rhs } => {
			let m = match op {
				ComparisonKind::Equal => "tst",
				ComparisonKind::NotEqual => "tstn",
				ComparisonKind::Less => "lt",
				ComparisonKind::Greater => "gt",
				ComparisonKind::LessOrEq => "lte",
				ComparisonKind::GreaterOrEq => "gte",
			};
			format!("{m} r{lhs}, {}", cmp_src(*rhs))
		}
		CanonInsn::PrepareJump { target, link_reg } => {
			let link = link_reg.map(|r| format!("uto r{r}: ")).unwrap_or_default();
			match target {
				JumpTarget::RelImm(d) => {
					let t = isa.wrapping_add(*d as u32);
					format!("{link}dispi {}", name_at(t))
				}
				JumpTarget::RelReg(r) => format!("{link}disp r{r}"),
				JumpTarget::AbsReg(r) => format!("{link}dispa r{r}"),
			}
		}
		CanonInsn::Unary { op, target, on_flags } => {
			let p = if *on_flags { "flag: " } else { "" };
			match op {
				UnaryOp::BitwiseNot => format!("{p}not r{target}"),
				UnaryOp::AdditiveInverse => format!("{p}neg r{target}"),
			}
		}
		CanonInsn::Prefetch { on_instructions, r1, r2 } => {
			let m = if *on_instructions { "pfi" } else { "pfd" };
			format!("{m} r{r1}, r{r2}")
		}
		CanonInsn::ExportMem { start, span, .. } => format!("esp r{start}, r{span}"),
		CanonInsn::DropICacheRange { start, span } => format!("icinvr r{start}, r{span}"),
		CanonInsn::Halt => "halt".to_string(),
		CanonInsn::Nop => "nop".to_string(),
		CanonInsn::PerformJump => "tc".to_string(),
	}
}

/// One disassembled instruction.
pub struct Line {
	pub addr: u32,
	pub words: Vec<u16>,
	pub text: String,
}

/// Disassembles `bytes` (loaded at `load_addr`) starting from `start`.
///
/// Undecodable code points are reported inline rather than aborting, so a
/// partially-valid image still yields a useful listing.
pub fn disassemble(
	bytes: &[u8],
	load_addr: u32,
	start: u32,
	labels: &HashMap<String, u32>,
) -> Vec<Line> {
	let mut out = Vec::new();
	let base = bytes.as_ptr() as *const ();
	let mut addr = start;
	let end = load_addr + bytes.len() as u32;

	while addr < end {
		let rel = (addr - load_addr) as usize;
		match decode_instruction(base, bytes.len(), (addr - load_addr) as u32) {
			Ok(d) => {
				let size = d.size_bytes.max(2) as usize;
				let words: Vec<u16> = bytes[rel..(rel + size).min(bytes.len())]
					.chunks(2)
					.map(|c| u16::from_le_bytes([c[0], *c.get(1).unwrap_or(&0)]))
					.collect();
				let cond = d
					.cond
					.map(|c| {
						format!(
							"{} r{}, {}: ",
							if c.is_inverted { "xcn" } else { "xcp" },
							c.rix,
							cc_name(c.cc)
						)
					})
					.unwrap_or_default();
				out.push(Line {
					addr,
					words,
					text: format!("{cond}{}", format_insn(&d.insn, addr, labels)),
				});
				addr += size as u32;
			}
			Err(f) => {
				let w = u16::from_le_bytes([bytes[rel], *bytes.get(rel + 1).unwrap_or(&0)]);
				out.push(Line {
					addr,
					words: vec![w],
					text: format!(".word {w:#06x}   ; undecodable: {}", f.cause.name()),
				});
				addr += 2;
			}
		}
	}
	out
}

/// Renders a disassembly as text, with labels shown where they land.
pub fn disassemble_range(
	bytes: &[u8],
	load_addr: u32,
	start: u32,
	labels: &HashMap<String, u32>,
) -> String {
	use std::fmt::Write;
	let mut s = String::new();
	for line in disassemble(bytes, load_addr, start, labels) {
		if let Some((name, _)) = labels.iter().find(|(_, a)| **a == line.addr) {
			let _ = writeln!(s, "{name}:");
		}
		let enc: Vec<String> = line.words.iter().map(|w| format!("{w:04x}")).collect();
		let _ = writeln!(s, "  {:#06x}:  {:<20}  {}", line.addr, enc.join(" "), line.text);
	}
	s
}
