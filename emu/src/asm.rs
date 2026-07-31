//! `kasm` — the K2G assembler.
//!
//! Before this there was no way to write a program: the only "toolchain" was
//! calling `encode_*` from Rust test code, and every displacement was computed
//! by hand. That is how the reference fibonacci program ended up with two
//! miscalculated branches.
//!
//! Structure is a straightforward two-stage assembler with one wrinkle. Because
//! an instruction's length depends on its immediate's magnitude, and a
//! displacement's magnitude depends on the layout, sizes and addresses are
//! mutually dependent. Rather than a fixed-point relaxation with the usual
//! oscillation hazards, layout is iterated to a fixed point with sizes only
//! ever growing, which is guaranteed to terminate.

use std::collections::HashMap;
use std::fmt;

use crate::insns::*;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AsmError {
	pub line: usize,
	pub message: String,
}

impl fmt::Display for AsmError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		write!(f, "line {}: {}", self.line, self.message)
	}
}

impl std::error::Error for AsmError {}

type R<T> = Result<T, AsmError>;

fn err<T>(line: usize, message: impl Into<String>) -> R<T> {
	Err(AsmError { line, message: message.into() })
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/// An assembled program.
#[derive(Debug)]
pub struct Program {
	/// Code points, indexed from `origin`.
	pub words: Vec<u16>,
	pub origin: u32,
	/// Symbols that name an address. These annotate a disassembly listing.
	pub labels: HashMap<String, u32>,
	/// Symbols from `NAME = value`. Resolvable in expressions, but not
	/// addresses -- annotating a listing with them would put `UART_DATA:` on
	/// whatever instruction happens to live at address 0.
	pub constants: HashMap<String, u32>,
}

impl Program {
	/// Flat little-endian byte image, suitable for loading at `origin`.
	pub fn to_bytes(&self) -> Vec<u8> {
		let mut out = Vec::with_capacity(self.words.len() * 2);
		for w in &self.words {
			out.extend_from_slice(&w.to_le_bytes());
		}
		out
	}
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// One source operand, before label resolution.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Operand {
	Reg(u16),
	Imm(i64),
	Label(String),
	/// `[rN]` or `[rN + off]`
	Mem { base: u16, offset: i64 },
	/// A bare identifier used as a condition code or type tag.
	Name(String),
}

#[derive(Debug, Clone)]
struct Stmt {
	line: usize,
	/// Prefix mnemonics written before a `:` on the same logical instruction.
	prefixes: Vec<(String, Vec<Operand>)>,
	mnemonic: String,
	operands: Vec<Operand>,
}

#[derive(Debug, Clone)]
enum Item {
	Label(String, usize),
	/// `NAME = value` -- a compile-time constant, e.g. a CSP port number.
	Equate(String, i64, usize),
	Stmt(Stmt),
	Directive { line: usize, name: String, args: Vec<Operand>, text: Option<String> },
}

fn parse_int(tok: &str) -> Option<i64> {
	let (neg, rest) = match tok.strip_prefix('-') {
		Some(r) => (true, r),
		None => (false, tok.strip_prefix('+').unwrap_or(tok)),
	};
	let clean = rest.replace('_', "");
	let v = if let Some(h) = clean.strip_prefix("0x").or_else(|| clean.strip_prefix("0X")) {
		i64::from_str_radix(h, 16).ok()?
	} else if let Some(b) = clean.strip_prefix("0b").or_else(|| clean.strip_prefix("0B")) {
		i64::from_str_radix(b, 2).ok()?
	} else if clean.chars().all(|c| c.is_ascii_digit()) && !clean.is_empty() {
		clean.parse::<i64>().ok()?
	} else {
		return None;
	};
	Some(if neg { -v } else { v })
}

fn parse_reg(tok: &str) -> Option<u16> {
	let t = tok.trim();
	let digits = t.strip_prefix('r').or_else(|| t.strip_prefix('R'))?;
	let n: u16 = digits.parse().ok()?;
	if n <= 31 { Some(n) } else { None }
}

/// Splits off a trailing `;` or `//` comment, respecting string literals.
fn strip_comment(s: &str) -> &str {
	let bytes = s.as_bytes();
	let mut in_str = false;
	let mut i = 0;
	while i < bytes.len() {
		match bytes[i] {
			b'"' => in_str = !in_str,
			b'\\' if in_str => i += 1,
			b';' if !in_str => return &s[..i],
			b'/' if !in_str && i + 1 < bytes.len() && bytes[i + 1] == b'/' => return &s[..i],
			_ => {}
		}
		i += 1;
	}
	s
}

fn parse_string_literal(s: &str, line: usize) -> R<String> {
	let t = s.trim();
	if !(t.starts_with('"') && t.ends_with('"') && t.len() >= 2) {
		return err(line, "expected a double-quoted string");
	}
	let inner = &t[1..t.len() - 1];
	let mut out = String::new();
	let mut chars = inner.chars();
	while let Some(c) = chars.next() {
		if c != '\\' {
			out.push(c);
			continue;
		}
		match chars.next() {
			Some('n') => out.push('\n'),
			Some('r') => out.push('\r'),
			Some('t') => out.push('\t'),
			Some('0') => out.push('\0'),
			Some('\\') => out.push('\\'),
			Some('"') => out.push('"'),
			Some(other) => return err(line, format!("unknown escape \\{other}")),
			None => return err(line, "string ends with a dangling backslash"),
		}
	}
	Ok(out)
}

fn parse_operand(tok: &str, line: usize) -> R<Operand> {
	let t = tok.trim();
	if t.is_empty() {
		return err(line, "empty operand");
	}
	if let Some(inner) = t.strip_prefix('[').and_then(|x| x.strip_suffix(']')) {
		// [rN], [rN+off], [rN-off]
		let inner = inner.trim();
		let (reg_part, off_part) = match inner.find(['+', '-']) {
			Some(i) => (&inner[..i], Some(&inner[i..])),
			None => (inner, None),
		};
		let base = match parse_reg(reg_part) {
			Some(r) => r,
			None => return err(line, format!("bad base register in `{t}`")),
		};
		let offset = match off_part {
			None => 0,
			Some(o) => match parse_int(o.trim()) {
				Some(v) => v,
				None => return err(line, format!("bad offset in `{t}`")),
			},
		};
		return Ok(Operand::Mem { base, offset });
	}
	if let Some(r) = parse_reg(t) {
		return Ok(Operand::Reg(r));
	}
	if let Some(v) = parse_int(t) {
		return Ok(Operand::Imm(v));
	}
	if t.starts_with('\'') && t.ends_with('\'') && t.len() >= 3 {
		let body = parse_string_literal(&format!("\"{}\"", &t[1..t.len() - 1]), line)?;
		let mut cs = body.chars();
		if let (Some(c), None) = (cs.next(), cs.next()) {
			return Ok(Operand::Imm(c as i64));
		}
		return err(line, "character literal must hold exactly one character");
	}
	if t.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_' || c == '.') {
		return Ok(Operand::Label(t.to_string()));
	}
	err(line, format!("cannot parse operand `{t}`"))
}

fn split_operands(s: &str) -> Vec<String> {
	let mut out = Vec::new();
	let mut depth = 0i32;
	let mut cur = String::new();
	for c in s.chars() {
		match c {
			'[' => { depth += 1; cur.push(c); }
			']' => { depth -= 1; cur.push(c); }
			',' if depth == 0 => { out.push(cur.trim().to_string()); cur = String::new(); }
			_ => cur.push(c),
		}
	}
	if !cur.trim().is_empty() {
		out.push(cur.trim().to_string());
	}
	out
}

fn parse_line(raw: &str, line: usize, items: &mut Vec<Item>) -> R<()> {
	let mut s = strip_comment(raw).trim();
	if s.is_empty() {
		return Ok(());
	}

	// Equate: `NAME = value`. Checked before labels so a name followed by `=`
	// is never mistaken for something else.
	if let Some(eq) = s.find('=') {
		let name = s[..eq].trim();
		let is_ident = !name.is_empty()
			&& !name.contains(char::is_whitespace)
			&& name.chars().all(|c| c.is_alphanumeric() || c == '_')
			&& name.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_');
		if is_ident && !name.ends_with(':') {
			let rhs = s[eq + 1..].trim();
			let Some(v) = parse_int(rhs) else {
				return err(line, format!("`{name} = {rhs}` needs an integer value"));
			};
			items.push(Item::Equate(name.to_string(), v, line));
			return Ok(());
		}
	}

	// Leading labels: `name:` possibly several, possibly followed by code.
	loop {
		let Some(colon) = s.find(':') else { break };
		let head = s[..colon].trim();
		if head.is_empty()
			|| head.contains(char::is_whitespace)
			|| !head.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '.')
		{
			break;
		}
		// A prefix mnemonic also ends in `:`; distinguish by known names.
		if is_prefix_mnemonic(head) {
			break;
		}
		items.push(Item::Label(head.to_string(), line));
		s = s[colon + 1..].trim();
		if s.is_empty() {
			return Ok(());
		}
	}

	if s.starts_with('.') {
		let (name, rest) = match s.find(char::is_whitespace) {
			Some(i) => (&s[..i], s[i..].trim()),
			None => (s, ""),
		};
		let lname = name.to_ascii_lowercase();
		let text = if rest.starts_with('"') { Some(parse_string_literal(rest, line)?) } else { None };
		let args = if text.is_some() {
			Vec::new()
		} else if rest.is_empty() {
			Vec::new()
		} else {
			split_operands(rest).iter().map(|o| parse_operand(o, line)).collect::<R<Vec<_>>>()?
		};
		items.push(Item::Directive { line, name: lname, args, text });
		return Ok(());
	}

	// Prefix chain: `xcp r3, zero : add r4, r2`
	let mut prefixes = Vec::new();
	loop {
		let Some(colon) = s.find(':') else { break };
		let head = s[..colon].trim();
		let (m, rest) = match head.find(char::is_whitespace) {
			Some(i) => (&head[..i], head[i..].trim()),
			None => (head, ""),
		};
		if !is_prefix_mnemonic(m) {
			break;
		}
		let ops = if rest.is_empty() {
			Vec::new()
		} else {
			split_operands(rest).iter().map(|o| parse_operand(o, line)).collect::<R<Vec<_>>>()?
		};
		prefixes.push((m.to_ascii_lowercase(), ops));
		s = s[colon + 1..].trim();
	}

	if s.is_empty() {
		return err(line, "prefix with no instruction after it");
	}

	let (mnemonic, rest) = match s.find(char::is_whitespace) {
		Some(i) => (&s[..i], s[i..].trim()),
		None => (s, ""),
	};
	let operands = if rest.is_empty() {
		Vec::new()
	} else {
		split_operands(rest).iter().map(|o| parse_operand(o, line)).collect::<R<Vec<_>>>()?
	};

	items.push(Item::Stmt(Stmt {
		line,
		prefixes,
		mnemonic: mnemonic.to_ascii_lowercase(),
		operands,
	}));
	Ok(())
}

fn is_prefix_mnemonic(m: &str) -> bool {
	matches!(
		m.to_ascii_lowercase().as_str(),
		"xcp" | "xcn" | "uto" | "flag"
	)
}

// ---------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------

fn cond_code(name: &str, line: usize) -> R<CC> {
	Ok(match name.to_ascii_lowercase().as_str() {
		"overflow" | "ov" | "overflow_set" => CC::CC_OVERFLOW_SET,
		"flag" | "flag_set" => CC::CC_FLAG_SET,
		"zero" | "z" | "value_zero" => CC::CC_VALUE_ZERO,
		"neg" | "negative" | "value_negative" => CC::CC_VALUE_NEGATIVE,
		"pos" | "positive" | "value_positive" => CC::CC_VALUE_POSITIVE,
		other => return err(line, format!("unknown condition code `{other}`")),
	})
}

fn type_tag(name: &str, line: usize) -> R<RDT> {
	Ok(match name.to_ascii_lowercase().as_str() {
		"u8" => RDT::RDT_U8,
		"u16" => RDT::RDT_U16,
		"u32" => RDT::RDT_U32,
		"s8" => RDT::RDT_S8,
		"s16" => RDT::RDT_S16,
		"s32" => RDT::RDT_S32,
		"f32" => RDT::RDT_F32,
		other => return err(line, format!("unknown data type `{other}`")),
	})
}

/// Chooses the shortest encoding for a constant load.
///
/// Three tiers, which is precisely the selection that kept tripping up
/// hand-written tests: `encode_lc_i5_*` asserts a 5-bit signed range, so a
/// value as ordinary as an ASCII letter needs a wider form.
fn encode_put_constant(width: u8, reg: u16, value: i64) -> Vec<u16> {
	let fits_i5 = (-16..=15).contains(&value);
	let fits_i15 = (-16384..=16383).contains(&value);
	if fits_i5 {
		return match width {
			8 => encode_lc_i5_b8(reg, value as isize).to_vec(),
			16 => encode_lc_i5_b16(reg, value as isize).to_vec(),
			_ => encode_lc_i5_b32(reg, value as isize).to_vec(),
		};
	}
	if fits_i15 {
		let bits = value as u32;
		let lb = match width {
			8 => LB::LB_PUC8,
			16 => LB::LB_PUC16,
			_ => LB::LB_PUC32,
		};
		return vec![
			pack_6_10(LB::LB_XI as _, ((bits >> 5) & 0x3ff) as u16),
			pack_6_5_5(lb as _, reg, (bits & 0x1f) as u16),
		];
	}
	let v = value as u32 as usize;
	match width {
		8 => encode_llc_b8(reg, v & 0xff).to_vec(),
		16 => encode_llc_b16(reg, v & 0xffff).to_vec(),
		_ => encode_llc_b32(reg, v).to_vec(),
	}
}

struct Ctx<'a> {
	labels: &'a HashMap<String, u32>,
	/// Address of the instruction being encoded, for relative displacements.
	isa: u32,
	/// During layout passes labels may be unknown; assume the widest form so
	/// sizes only ever shrink toward the fixed point, never oscillate.
	resolve_ok: bool,
}

impl Ctx<'_> {
	fn value_of(&self, op: &Operand, line: usize) -> R<i64> {
		match op {
			Operand::Imm(v) => Ok(*v),
			Operand::Label(name) => match self.labels.get(name) {
				Some(a) => Ok(*a as i64),
				None if !self.resolve_ok => Ok(0x4000), // wide placeholder
				None => err(line, format!("undefined label `{name}`")),
			},
			_ => err(line, "expected an immediate or label"),
		}
	}
}

fn reg_of(op: &Operand, line: usize) -> R<u16> {
	match op {
		Operand::Reg(r) => Ok(*r),
		_ => err(line, "expected a register"),
	}
}

fn name_of(op: &Operand, line: usize) -> R<String> {
	match op {
		Operand::Label(n) | Operand::Name(n) => Ok(n.clone()),
		_ => err(line, "expected a name"),
	}
}

fn encode_stmt(st: &Stmt, ctx: &Ctx) -> R<Vec<u16>> {
	let line = st.line;
	let ops = &st.operands;
	let n = ops.len();

	let need = |k: usize| -> R<()> {
		if n != k {
			return err(line, format!("`{}` takes {k} operand(s), got {n}", st.mnemonic));
		}
		Ok(())
	};

	// Prefixes are emitted ahead of the main code point.
	let mut out: Vec<u16> = Vec::new();
	let mut uto_reg: Option<u16> = None;
	let mut flag_prefix = false;
	for (pm, pops) in &st.prefixes {
		match pm.as_str() {
			"xcp" | "xcn" => {
				if pops.len() != 2 {
					return err(line, "xcp/xcn take a register and a condition code");
				}
				let r = reg_of(&pops[0], line)?;
				let cc = cond_code(&name_of(&pops[1], line)?, line)?;
				out.extend_from_slice(&if pm == "xcp" {
					encode_xcp(r, cc)
				} else {
					encode_xcn(r, cc)
				});
			}
			"uto" => {
				if pops.len() != 1 {
					return err(line, "uto takes one register");
				}
				uto_reg = Some(reg_of(&pops[0], line)?);
			}
			"flag" => flag_prefix = true,
			other => return err(line, format!("unknown prefix `{other}`")),
		}
	}

	let alu = |lb: LB, out: &mut Vec<u16>| -> R<()> {
		need(2)?;
		let d = reg_of(&ops[0], line)?;
		match &ops[1] {
			Operand::Reg(s) => out.extend_from_slice(&encode_alu_rr(lb, d, *s)),
			other => {
				let v = ctx.value_of(other, line)?;
				if !(-16384..=16383).contains(&v) {
					return err(line, format!("immediate {v} does not fit 15 bits signed"));
				}
				out.extend_from_slice(&encode_alu_ri(lb, d, v as isize));
			}
		}
		Ok(())
	};

	match st.mnemonic.as_str() {
		// ---- constants ----
		"puc8" | "puc16" | "puc32" => {
			need(2)?;
			let d = reg_of(&ops[0], line)?;
			let v = ctx.value_of(&ops[1], line)?;
			let w = match st.mnemonic.as_str() {
				"puc8" => 8,
				"puc16" => 16,
				_ => 32,
			};
			out.extend(encode_put_constant(w, d, v));
		}
		"rdt" => {
			need(2)?;
			let d = reg_of(&ops[0], line)?;
			let k = type_tag(&name_of(&ops[1], line)?, line)?;
			out.extend_from_slice(&encode_rdt(d, k));
		}
		"cpy" | "mov" => {
			need(2)?;
			out.extend_from_slice(&encode_cpy(reg_of(&ops[0], line)?, reg_of(&ops[1], line)?));
		}

		// ---- memory ----
		"ld8" | "ld16" | "ld32" => {
			need(2)?;
			let d = reg_of(&ops[0], line)?;
			let Operand::Mem { base, offset } = &ops[1] else {
				return err(line, "expected [rN] or [rN+off]");
			};
			let off = *offset;
			if off == 0 {
				out.extend_from_slice(&match st.mnemonic.as_str() {
					"ld8" => encode_ld_b8(d, *base),
					"ld16" => encode_ld_b16(d, *base),
					_ => encode_ld_b32(d, *base),
				});
			} else {
				if !(-512..=511).contains(&off) {
					return err(line, format!("load offset {off} does not fit 10 bits signed"));
				}
				let lb = match st.mnemonic.as_str() {
					"ld8" => LB::LB_LD8,
					"ld16" => LB::LB_LD16,
					_ => LB::LB_LD32,
				};
				out.push(pack_6_10(LB::LB_XI as _, (off as u32 & 0x3ff) as u16));
				out.push(pack_6_5_5(lb as _, d, *base));
			}
		}
		"st" => {
			need(2)?;
			let Operand::Mem { base, offset } = &ops[0] else {
				return err(line, "expected [rN] or [rN+off] as the destination");
			};
			let s = reg_of(&ops[1], line)?;
			if *offset == 0 {
				out.extend_from_slice(&encode_st(*base, s));
			} else {
				if !(-512..=511).contains(offset) {
					return err(line, format!("store offset {offset} does not fit 10 bits signed"));
				}
				out.push(pack_6_10(LB::LB_XI as _, (*offset as u32 & 0x3ff) as u16));
				out.push(pack_6_5_5(LB::LB_ST as _, *base, s));
			}
		}

		// ---- I/O (CSP port space) ----
		// Operand order matches the assembly reading, not the encoding: the
		// encoding takes the port from different fields in each direction.
		"in" => {
			need(2)?;
			out.extend_from_slice(&encode_ld_msr_32(reg_of(&ops[0], line)?, reg_of(&ops[1], line)?));
		}
		"out" => {
			need(2)?;
			out.extend_from_slice(&encode_st_mcr(reg_of(&ops[0], line)?, reg_of(&ops[1], line)?));
		}

		// ---- arithmetic and logic ----
		"add" => alu(LB::LB_ADD, &mut out)?,
		"sub" => alu(LB::LB_SUB, &mut out)?,
		"mul" => {
			if let (3, Ok(a), Ok(b), Ok(c)) = (
				n,
				reg_of(&ops[0], line),
				ops.get(1).map_or(err(line, "x"), |o| reg_of(o, line)),
				ops.get(2).map_or(err(line, "x"), |o| reg_of(o, line)),
			) {
				// Three-operand form is the widening multiply.
				out.extend_from_slice(&encode_mulw_rr(a, b, c));
			} else {
				alu(LB::LB_MUL, &mut out)?;
			}
		}
		"mulw" => {
			need(3)?;
			out.extend_from_slice(&encode_mulw_rr(
				reg_of(&ops[0], line)?,
				reg_of(&ops[1], line)?,
				reg_of(&ops[2], line)?,
			));
		}
		"div" => alu(LB::LB_DIV, &mut out)?,
		"and" | "or" | "xor" => {
			let lb = match st.mnemonic.as_str() {
				"and" => LB::LB_AND,
				"or" => LB::LB_OR,
				_ => LB::LB_XOR,
			};
			if flag_prefix {
				need(2)?;
				let d = reg_of(&ops[0], line)?;
				let s = reg_of(&ops[1], line)?;
				out.extend_from_slice(&match st.mnemonic.as_str() {
					"and" => encode_flag_and(d, s),
					"or" => encode_flag_or(d, s),
					_ => encode_flag_xor(d, s),
				});
			} else {
				alu(lb, &mut out)?;
			}
		}
		"not" => {
			need(1)?;
			let d = reg_of(&ops[0], line)?;
			// flag_not is a two-code-point form (EP2_FLAG prefix + NOT); inv is one.
			if flag_prefix {
				out.extend_from_slice(&encode_flag_not(d));
			} else {
				out.extend_from_slice(&encode_inv(d));
			}
		}
		"neg" => {
			need(1)?;
			out.extend_from_slice(&encode_neg(reg_of(&ops[0], line)?));
		}

		// ---- shifts ----
		"shl" | "shr" | "shra" => {
			need(2)?;
			let d = reg_of(&ops[0], line)?;
			match &ops[1] {
				Operand::Reg(s) => out.extend_from_slice(&match st.mnemonic.as_str() {
					"shl" => encode_shl_rr(d, *s),
					"shr" => encode_shr_rr(d, *s),
					_ => encode_shra_rr(d, *s),
				}),
				other => {
					let v = ctx.value_of(other, line)?;
					if !(0..=31).contains(&v) {
						return err(line, format!("shift amount {v} must be 0..31"));
					}
					let v = v as u16;
					out.extend_from_slice(&match st.mnemonic.as_str() {
						"shl" => encode_shl_ri(d, v),
						"shr" => encode_shr_ri(d, v),
						_ => encode_shra_ri(d, v),
					});
				}
			}
		}

		// ---- bit fields ----
		"bext" | "bins" => {
			need(4)?;
			let d = reg_of(&ops[0], line)?;
			let s = reg_of(&ops[1], line)?;
			let start = ctx.value_of(&ops[2], line)?;
			let span = ctx.value_of(&ops[3], line)?;
			if !(0..=31).contains(&start) || !(0..=31).contains(&span) {
				return err(line, "bit-field start and span must be 0..31");
			}
			out.extend_from_slice(&if st.mnemonic == "bext" {
				encode_bext(d, s, start as u16, span as u16)
			} else {
				encode_bins(d, s, start as u16, span as u16)
			});
		}

		// ---- comparisons ----
		"tst" | "tstn" | "lt" | "gt" | "lte" | "gte" => {
			let lb = match st.mnemonic.as_str() {
				"tst" => LB::LB_TST,
				"tstn" => LB::LB_TSTN,
				"lt" => LB::LB_LT,
				"gt" => LB::LB_GT,
				"lte" => LB::LB_LTE,
				_ => LB::LB_GTE,
			};
			alu(lb, &mut out)?;
		}

		// ---- control transfer ----
		"dispi" => {
			need(1)?;
			let target = ctx.value_of(&ops[0], line)?;
			// Relative to the start of the whole prefixed instruction, and
			// scaled by 2 (spec 6.2). `out.len()` already holds the prefixes.
			let disp_bytes = target - ctx.isa as i64;
			if disp_bytes % 2 != 0 {
				return err(line, "branch target must be halfword aligned");
			}
			let disp = disp_bytes / 2;
			match uto_reg {
				Some(link) => {
					if !(-524288..=524287).contains(&disp) {
						return err(line, format!("branch displacement {disp} does not fit"));
					}
					out.extend_from_slice(&encode_disp_imm_xim_link(link, disp as isize));
				}
				None if (-512..=511).contains(&disp) => {
					out.extend_from_slice(&encode_disp_imm(disp as isize));
				}
				None => {
					if !(-524288..=524287).contains(&disp) {
						return err(line, format!("branch displacement {disp} does not fit"));
					}
					out.extend_from_slice(&encode_disp_imm_xim(disp as isize));
				}
			}
		}
		"disp" => {
			need(1)?;
			let r = reg_of(&ops[0], line)?;
			out.extend_from_slice(&match uto_reg {
				Some(link) => encode_disp_reg_off_link(link, r).to_vec(),
				None => encode_disp_reg_off(r).to_vec(),
			});
		}
		"dispa" => {
			need(1)?;
			let r = reg_of(&ops[0], line)?;
			out.extend_from_slice(&match uto_reg {
				Some(link) => encode_disp_reg_addr_link(link, r).to_vec(),
				None => encode_disp_reg_addr(r).to_vec(),
			});
		}
		"tc" => {
			need(0)?;
			out.extend_from_slice(&encode_ctrl_trn());
		}
		"halt" => {
			need(0)?;
			out.extend_from_slice(&encode_halt());
		}
		"nop" => {
			need(0)?;
			out.extend_from_slice(&encode_nop());
		}

		other => return err(line, format!("unknown mnemonic `{other}`")),
	}

	if uto_reg.is_some()
		&& !matches!(st.mnemonic.as_str(), "dispi" | "disp" | "dispa" | "mul" | "mulw")
	{
		return err(line, "the `uto` prefix only applies to jumps and multiply");
	}
	Ok(out)
}

/// Emits a directive's data. Returns `None` for directives that only move the
/// location counter, which the caller handles.
fn encode_directive(
	name: &str,
	args: &[Operand],
	text: &Option<String>,
	ctx: &Ctx,
	line: usize,
) -> R<Vec<u16>> {
	match name {
		".word" | ".half" => {
			let mut out = Vec::new();
			for a in args {
				out.push(ctx.value_of(a, line)? as u16);
			}
			Ok(out)
		}
		".long" | ".dword" => {
			let mut out = Vec::new();
			for a in args {
				let v = ctx.value_of(a, line)? as u32;
				// Little-endian in memory, so low halfword first.
				out.push(v as u16);
				out.push((v >> 16) as u16);
			}
			Ok(out)
		}
		".byte" => {
			let mut bytes = Vec::new();
			for a in args {
				bytes.push(ctx.value_of(a, line)? as u8);
			}
			Ok(pack_bytes(&bytes))
		}
		".ascii" | ".asciz" => {
			let Some(t) = text else {
				return err(line, "expected a quoted string");
			};
			let mut bytes = t.clone().into_bytes();
			if name == ".asciz" {
				bytes.push(0);
			}
			Ok(pack_bytes(&bytes))
		}
		other => err(line, format!("unknown directive `{other}`")),
	}
}

fn pack_bytes(bytes: &[u8]) -> Vec<u16> {
	let mut out = Vec::with_capacity(bytes.len().div_ceil(2));
	for pair in bytes.chunks(2) {
		let lo = pair[0] as u16;
		let hi = *pair.get(1).unwrap_or(&0) as u16;
		out.push(lo | (hi << 8));
	}
	out
}

/// Assembles source text into a program image.
pub fn assemble(source: &str) -> Result<Program, Vec<AsmError>> {
	let mut items = Vec::new();
	let mut errors = Vec::new();
	for (i, raw) in source.lines().enumerate() {
		if let Err(e) = parse_line(raw, i + 1, &mut items) {
			errors.push(e);
		}
	}
	if !errors.is_empty() {
		return Err(errors);
	}

	// Layout is iterated because an instruction's size depends on immediate
	// magnitudes, which for label references depend on the layout. Sizes only
	// shrink between passes (the first pass assumes the widest form), so this
	// converges rather than oscillating.
	let mut labels: HashMap<String, u32> = HashMap::new();
	let mut constants: HashMap<String, u32> = HashMap::new();
	let mut origin = 0u32;
	let words: Vec<u16>;
	let mut layout_words: Vec<u16>;

	for pass in 0..8 {
		let final_pass = pass == 7;
		let mut next_labels = HashMap::new();
		layout_words = Vec::new();
		origin = 0;
		let mut org_set = false;
		let mut addr = 0u32;
		errors.clear();

		for item in &items {
			match item {
				Item::Label(name, line) => {
					if next_labels.insert(name.clone(), addr).is_some() {
						errors.push(AsmError {
							line: *line,
							message: format!("duplicate label `{name}`"),
						});
					}
				}
				Item::Equate(name, value, line) => {
					constants.insert(name.clone(), *value as u32);
					if next_labels.insert(name.clone(), *value as u32).is_some() {
						errors.push(AsmError {
							line: *line,
							message: format!("duplicate symbol `{name}`"),
						});
					}
				}
				Item::Directive { line, name, args, text } => {
					let ctx = Ctx { labels: &labels, isa: addr, resolve_ok: final_pass };
					match name.as_str() {
						".org" => {
							let v = match args.first() {
								Some(a) => match ctx.value_of(a, *line) {
									Ok(v) => v as u32,
									Err(e) => { errors.push(e); continue; }
								},
								None => { errors.push(AsmError { line: *line, message: ".org needs an address".into() }); continue; }
							};
							if !org_set && layout_words.is_empty() {
								origin = v;
								org_set = true;
								addr = v;
							} else if v < addr {
								errors.push(AsmError { line: *line, message: format!(".org {v:#x} moves backwards") });
							} else {
								let pad = ((v - addr) / 2) as usize;
								layout_words.extend(std::iter::repeat_n(0u16, pad));
								addr = v;
							}
						}
						".align" => {
							let v = args.first().and_then(|a| ctx.value_of(a, *line).ok()).unwrap_or(2) as u32;
							if v == 0 || v % 2 != 0 {
								errors.push(AsmError { line: *line, message: ".align needs an even, non-zero value".into() });
								continue;
							}
							while addr % v != 0 {
								layout_words.push(0);
								addr += 2;
							}
						}
						".space" => {
							let v = args.first().and_then(|a| ctx.value_of(a, *line).ok()).unwrap_or(0) as u32;
							let pad = v.div_ceil(2) as usize;
							layout_words.extend(std::iter::repeat_n(0u16, pad));
							addr += (pad * 2) as u32;
						}
						_ => match encode_directive(name, args, text, &ctx, *line) {
							Ok(w) => { addr += (w.len() * 2) as u32; layout_words.extend(w); }
							Err(e) => errors.push(e),
						},
					}
				}
				Item::Stmt(st) => {
					let ctx = Ctx { labels: &labels, isa: addr, resolve_ok: final_pass };
					match encode_stmt(st, &ctx) {
						Ok(w) => { addr += (w.len() * 2) as u32; layout_words.extend(w); }
						Err(e) => errors.push(e),
					}
				}
			}
		}

		let _ = &layout_words;
		let converged = next_labels == labels;
		labels = next_labels;
		if converged && pass > 0 {
			// Re-run once with resolution enforced so undefined labels report.
			if !errors.is_empty() {
				return Err(errors);
			}
			break;
		}
		if final_pass && !errors.is_empty() {
			return Err(errors);
		}
	}

	// Final pass with label resolution mandatory, to surface undefined names.
	{
		let mut addr = origin;
		let mut final_words = Vec::new();
		errors.clear();
		for item in &items {
			match item {
				Item::Label(..) | Item::Equate(..) => {}
				Item::Directive { line, name, args, text } => {
					let ctx = Ctx { labels: &labels, isa: addr, resolve_ok: true };
					match name.as_str() {
						".org" => {
							let v = args.first().and_then(|a| ctx.value_of(a, *line).ok()).unwrap_or(addr as i64) as u32;
							if v > addr {
								let pad = ((v - addr) / 2) as usize;
								final_words.extend(std::iter::repeat_n(0u16, pad));
								addr = v;
							}
						}
						".align" => {
							let v = args.first().and_then(|a| ctx.value_of(a, *line).ok()).unwrap_or(2) as u32;
							while v != 0 && addr % v != 0 {
								final_words.push(0);
								addr += 2;
							}
						}
						".space" => {
							let v = args.first().and_then(|a| ctx.value_of(a, *line).ok()).unwrap_or(0) as u32;
							let pad = v.div_ceil(2) as usize;
							final_words.extend(std::iter::repeat_n(0u16, pad));
							addr += (pad * 2) as u32;
						}
						_ => match encode_directive(name, args, text, &ctx, *line) {
							Ok(w) => { addr += (w.len() * 2) as u32; final_words.extend(w); }
							Err(e) => errors.push(e),
						},
					}
				}
				Item::Stmt(st) => {
					let ctx = Ctx { labels: &labels, isa: addr, resolve_ok: true };
					match encode_stmt(st, &ctx) {
						Ok(w) => { addr += (w.len() * 2) as u32; final_words.extend(w); }
						Err(e) => errors.push(e),
					}
				}
			}
		}
		if !errors.is_empty() {
			return Err(errors);
		}
		words = final_words;
	}

	// Only address-valued symbols go in `labels`.
	let address_labels: HashMap<String, u32> =
		labels.iter().filter(|(n, _)| !constants.contains_key(*n)).map(|(n, a)| (n.clone(), *a)).collect();
	Ok(Program { words, origin, labels: address_labels, constants })
}
