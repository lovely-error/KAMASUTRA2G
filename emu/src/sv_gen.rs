//! Generates the SystemVerilog opcode package from [`crate::insns`].
//!
//! The RTL must never carry a hand-maintained copy of the opcode map. The
//! superseded `decoder.sv` did exactly that and silently diverged from the
//! emulator: it placed the opcode at `lane[5:0]` instead of `cp[15:10]`,
//! numbered `LB_ADD` as 62 against the emulator's 53, and accumulated
//! duplicate labels (`LB_GTE` at both 53 and 35, `EP2_SHRR` at both 26 and 21)
//! that no tool ever flagged.
//!
//! Everything here is driven by the `VARIANTS` tables that the `isa_enum!`
//! macro derives from the enum bodies themselves, so the generated package and
//! the Rust definition cannot disagree.

use core::fmt::Write;

use crate::insns::{
	ARG1_LSB, ARG1_WIDTH, ARG2_LSB, ARG2_WIDTH, CC, CP_WIDTH, EP1, EP2,
	IMM10_LSB, IMM10_WIDTH, LB, LB_LSB, LB_WIDTH, RDT, RDT_SIGNED_BIT,
	RDT_WIDTH_MASK,
};

/// Path the generated package is written to, relative to the repository root.
pub const OUTPUT_PATH: &str = "rtl/k2g_pkg.sv";

/// Path the generated opcode tables are written to, relative to the repo root.
///
/// `docs/isa-spec.md` carries the semantics by hand, but the *numbers* are
/// generated so documentation cannot drift from the implementation either.
pub const DOC_OUTPUT_PATH: &str = "docs/isa-opcodes.md";

/// A duplicate discriminant in an opcode enum.
#[derive(Debug, PartialEq, Eq)]
pub struct DuplicateValue {
	pub enum_name: &'static str,
	pub value: u16,
	pub first: &'static str,
	pub second: &'static str,
}

/// Reports any value claimed by more than one variant.
///
/// This is the specific defect that made `decoder.sv` unsalvageable, so it is
/// checked rather than assumed. SystemVerilog rejects duplicate enum labels but
/// happily accepts duplicate *values*, which is the dangerous direction.
pub fn find_duplicates(
	enum_name: &'static str,
	variants: &[(&'static str, u16)],
) -> Vec<DuplicateValue> {
	let mut dups = Vec::new();
	for (i, &(name_a, val_a)) in variants.iter().enumerate() {
		for &(name_b, val_b) in &variants[i + 1..] {
			if val_a == val_b {
				dups.push(DuplicateValue {
					enum_name,
					value: val_a,
					first: name_a,
					second: name_b,
				});
			}
		}
	}
	dups
}

/// Every opcode enum, as `(sv_type_name, rust_enum_name, bits, variants)`.
/// Shared with `ddl_gen`, so the DDL and SystemVerilog outputs cannot list
/// different enums.
pub fn all_enums() -> Vec<(&'static str, &'static str, u32, &'static [(&'static str, u16)])> {
	vec![
		("lb_e", "LB", LB::BITS, LB::VARIANTS),
		("ep1_e", "EP1", EP1::BITS, EP1::VARIANTS),
		("ep2_e", "EP2", EP2::BITS, EP2::VARIANTS),
		("cc_e", "CC", CC::BITS, CC::VARIANTS),
		("rdt_e", "RDT", RDT::BITS, RDT::VARIANTS),
	]
}

/// Checks every opcode enum for duplicate values.
pub fn validate() -> Result<(), Vec<DuplicateValue>> {
	let mut dups = Vec::new();
	for (_, rust_name, _, variants) in all_enums() {
		dups.extend(find_duplicates(rust_name, variants));
	}
	if dups.is_empty() { Ok(()) } else { Err(dups) }
}

fn emit_enum(
	out: &mut String,
	sv_type: &str,
	rust_name: &str,
	bits: u32,
	variants: &[(&'static str, u16)],
) {
	let _ = writeln!(
		out,
		"  // {} -- {} variants, {} bits. Rust: `insns::{}`.",
		rust_name,
		variants.len(),
		bits,
		rust_name
	);
	let _ = writeln!(out, "  typedef enum logic [{}:0] {{", bits - 1);

	for (i, &(name, value)) in variants.iter().enumerate() {
		let last = i + 1 == variants.len();
		let _ = writeln!(
			out,
			"    {name} = {bits}'b{value:0width$b}{comma} // {value}",
			name = name,
			bits = bits,
			value = value,
			width = bits as usize,
			comma = if last { "" } else { "," },
		);
		// Group in eights so the binary column stays readable.
		if !last && (i + 1) % 8 == 0 {
			let _ = writeln!(out);
		}
	}

	let _ = writeln!(out, "  }} {sv_type};");
	let _ = writeln!(out);
}

/// Renders the complete `k2g_pkg` SystemVerilog package.
pub fn emit_sv() -> String {
	if let Err(dups) = validate() {
		panic!("refusing to generate SystemVerilog with duplicate opcode values: {dups:?}");
	}

	let mut out = String::new();

	let _ = writeln!(out, "// -------------------------------------------------------------------------");
	let _ = writeln!(out, "// GENERATED FILE -- DO NOT EDIT BY HAND.");
	let _ = writeln!(out, "//");
	let _ = writeln!(out, "// Produced by emu/src/sv_gen.rs from the enums in emu/src/insns.rs,");
	let _ = writeln!(out, "// which are the normative definition of the K2G instruction set.");
	let _ = writeln!(out, "//");
	let _ = writeln!(out, "// Regenerate:  cd emu && cargo run --bin gen_defs");
	let _ = writeln!(out, "// Verify:      cd emu && cargo test  (golden-file test fails on drift)");
	let _ = writeln!(out, "// -------------------------------------------------------------------------");
	let _ = writeln!(out);
	let _ = writeln!(out, "`ifndef K2G_PKG_SV");
	let _ = writeln!(out, "`define K2G_PKG_SV");
	let _ = writeln!(out);
	let _ = writeln!(out, "package k2g_pkg;");
	let _ = writeln!(out);

	let _ = writeln!(out, "  // ---- Code point layout -------------------------------------------------");
	let _ = writeln!(out, "  // Two formats share one 16-bit code point:");
	let _ = writeln!(out, "  //   6/5/5 : LB[15:10] | arg1[9:5] | arg2[4:0]");
	let _ = writeln!(out, "  //   6/10  : LB[15:10] | imm10[9:0]");
	let _ = writeln!(out, "  // arg1 and imm10 share a left edge, which is why the predicate register");
	let _ = writeln!(out, "  // index needs no address mux on register read port A.");
	let _ = writeln!(out, "  localparam int CP_W      = {};", CP_WIDTH);
	let _ = writeln!(out, "  localparam int LB_LSB    = {};", LB_LSB);
	let _ = writeln!(out, "  localparam int LB_W      = {};", LB_WIDTH);
	let _ = writeln!(out, "  localparam int ARG1_LSB  = {};", ARG1_LSB);
	let _ = writeln!(out, "  localparam int ARG1_W    = {};", ARG1_WIDTH);
	let _ = writeln!(out, "  localparam int ARG2_LSB  = {};", ARG2_LSB);
	let _ = writeln!(out, "  localparam int ARG2_W    = {};", ARG2_WIDTH);
	let _ = writeln!(out, "  localparam int IMM10_LSB = {};", IMM10_LSB);
	let _ = writeln!(out, "  localparam int IMM10_W   = {};", IMM10_WIDTH);
	let _ = writeln!(out);
	let _ = writeln!(out, "  localparam int REG_COUNT = 32;");
	let _ = writeln!(out, "  localparam int XLEN      = 32;");
	let _ = writeln!(out);
	let _ = writeln!(out, "  // ---- Register data type tag -------------------------------------------");
	let _ = writeln!(out, "  // rdt_e is a flat enum, but its values carry structure the datapath can");
	let _ = writeln!(out, "  // use directly: bit {} selects signed interpretation, and the low bits", RDT_SIGNED_BIT);
	let _ = writeln!(out, "  // give the width code (00=8, 01=16, 10=32, 11=reserved).");
	let _ = writeln!(out, "  localparam int RDT_W          = {};", RDT::BITS);
	let _ = writeln!(out, "  localparam int RDT_SIGNED_BIT = {};", RDT_SIGNED_BIT);
	let _ = writeln!(out, "  localparam logic [{}:0] RDT_WIDTH_MASK = {}'b{:0width$b};",
		RDT::BITS - 1, RDT::BITS, RDT_WIDTH_MASK, width = RDT::BITS as usize);
	let _ = writeln!(out);

	for (sv_type, rust_name, bits, variants) in all_enums() {
		emit_enum(&mut out, sv_type, rust_name, bits, variants);
	}

	let _ = writeln!(out, "endpackage");
	let _ = writeln!(out);
	let _ = writeln!(out, "`endif  // K2G_PKG_SV");

	out
}

/// True for the filler variants that occupy an otherwise unassigned encoding.
fn is_unclaimed(name: &str) -> bool {
	name.contains("_UNCLAIMED_")
}

/// Collapses a sorted list of values into `"3, 5-9, 12"` form.
fn summarize_ranges(mut values: Vec<u16>) -> String {
	if values.is_empty() {
		return "none".to_string();
	}
	values.sort_unstable();
	let mut parts: Vec<String> = Vec::new();
	let mut start = values[0];
	let mut prev = values[0];
	for &v in &values[1..] {
		if v == prev + 1 {
			prev = v;
			continue;
		}
		parts.push(if start == prev { format!("{start}") } else { format!("{start}-{prev}") });
		start = v;
		prev = v;
	}
	parts.push(if start == prev { format!("{start}") } else { format!("{start}-{prev}") });
	parts.join(", ")
}

/// Renders the opcode tables as Markdown, for inclusion in the ISA docs.
pub fn emit_opcode_tables_md() -> String {
	let mut out = String::new();

	let _ = writeln!(out, "<!-- GENERATED FILE -- DO NOT EDIT BY HAND. -->");
	let _ = writeln!(out, "<!-- Produced by emu/src/sv_gen.rs from emu/src/insns.rs. -->");
	let _ = writeln!(out, "<!-- Regenerate: cd emu && cargo run --bin gen_defs -->");
	let _ = writeln!(out);
	let _ = writeln!(out, "# K2G opcode tables");
	let _ = writeln!(out);
	let _ = writeln!(out, "Generated from the opcode enums in `emu/src/insns.rs`, which are the");
	let _ = writeln!(out, "normative definition. Semantics live in [isa-spec.md](isa-spec.md); this");
	let _ = writeln!(out, "file carries only the encodings, so the numbers cannot drift from the");
	let _ = writeln!(out, "implementation. The same enums generate `rtl/k2g_pkg.sv`.");
	let _ = writeln!(out);

	for (sv_type, rust_name, bits, variants) in all_enums() {
		let claimed: Vec<_> = variants.iter().filter(|(n, _)| !is_unclaimed(n)).collect();
		let unclaimed: Vec<u16> =
			variants.iter().filter(|(n, _)| is_unclaimed(n)).map(|&(_, v)| v).collect();

		let _ = writeln!(out, "## `{rust_name}` — {bits} bits");
		let _ = writeln!(out);
		let _ = writeln!(
			out,
			"Rust `insns::{rust_name}`, SystemVerilog `k2g_pkg::{sv_type}`. \
			 {} of {} encodings assigned.",
			claimed.len(),
			variants.len()
		);
		let _ = writeln!(out);
		let _ = writeln!(out, "| Dec | Bin | Name |");
		let _ = writeln!(out, "|----:|-----|------|");
		for &&(name, value) in &claimed {
			let _ = writeln!(
				out,
				"| {value} | `{value:0width$b}` | `{name}` |",
				value = value,
				width = bits as usize,
				name = name
			);
		}
		let _ = writeln!(out);
		let _ = writeln!(out, "Unassigned: {}.", summarize_ranges(unclaimed));
		let _ = writeln!(out);
	}

	out
}

#[cfg(test)]
mod tests {
	use super::*;

	/// The defect that killed `decoder.sv`.
	#[test]
	fn no_duplicate_opcode_values() {
		if let Err(dups) = validate() {
			panic!("duplicate opcode values: {dups:?}");
		}
	}

	#[test]
	fn duplicate_detector_actually_detects() {
		// Guard against the check above passing vacuously.
		let dups = find_duplicates("FAKE", &[("A", 1), ("B", 2), ("C", 1)]);
		assert_eq!(dups.len(), 1);
		assert_eq!(dups[0].value, 1);
		assert_eq!(dups[0].first, "A");
		assert_eq!(dups[0].second, "C");
	}

	/// Each enum must cover its whole encoding space, so decode has no holes.
	#[test]
	fn enums_are_dense_and_complete() {
		for (_, rust_name, bits, variants) in all_enums() {
			let expected = 1usize << bits;
			assert_eq!(
				variants.len(),
				expected,
				"{rust_name} has {} variants but {bits} bits needs exactly {expected}",
				variants.len()
			);
			for &(name, value) in variants {
				assert!(
					(value as usize) < expected,
					"{rust_name}::{name} = {value} does not fit in {bits} bits"
				);
			}
		}
	}

	/// Pins the values the RTL depends on most, so a renumbering is loud.
	#[test]
	fn key_opcode_values_are_pinned() {
		assert_eq!(LB::LB_EP1 as u16, 63);
		assert_eq!(LB::LB_ADD as u16, 53);
		assert_eq!(LB::LB_ST as u16, 54);
		assert_eq!(LB::LB_XCP as u16, 31);
		assert_eq!(LB::LB_XI as u16, 30);
		assert_eq!(EP1::EP1_EP2 as u16, 31);
		assert_eq!(EP1::EP1_UTO as u16, 30);
		assert_eq!(EP2::EP2_TC as u16, 29);
		assert_eq!(EP2::EP2_HALT as u16, 25);
		assert_eq!(CC::CC_VALUE_ZERO as u16, 29);
	}

	#[test]
	fn name_lookup_round_trips() {
		assert_eq!(LB::name_of(53), Some("LB_ADD"));
		assert_eq!(EP2::name_of(25), Some("EP2_HALT"));
	}

	#[test]
	fn generated_package_looks_right() {
		let sv = emit_sv();
		assert!(sv.contains("package k2g_pkg;"));
		assert!(sv.contains("endpackage"));
		assert!(sv.contains("LB_ADD = 6'b110101, // 53"));
		assert!(sv.contains("EP2_HALT = 5'b11001, // 25"));
		assert!(sv.contains("typedef enum logic [5:0] {"));
		assert!(sv.contains("typedef enum logic [4:0] {"));
		// 64 + 32 + 32 + 32 variants, each on its own line.
		assert_eq!(sv.matches(" = 6'b").count(), 64);
		assert_eq!(sv.matches(" = 5'b").count(), 96);
	}
}
