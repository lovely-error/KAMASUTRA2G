//! Writes `rtl/k2g_pkg.ddl`: the same ISA enums as `rtl/k2g_pkg.sv`, in DDL.
//!
//! DDL modules cannot include the SystemVerilog package, so without this the
//! opcode encodings would have to be written down a third time. That is
//! exactly the failure this project already paid for once -- the superseded
//! `decoder.sv` kept a hand-maintained copy of the opcode map and silently
//! diverged, numbering `LB_ADD` 62 against the emulator's 53, with nothing
//! comparing the two.
//!
//! So the enum list comes from `sv_gen::all_enums()` rather than being
//! repeated here, and the output is registered in `bin/gen_defs.rs` so
//! `--check` fails on drift the same way it does for the SystemVerilog.

use std::fmt::Write;

use crate::sv_gen::{all_enums, validate};

pub const OUTPUT_PATH: &str = "rtl/k2g_pkg.ddl";

fn emit_enum(
	out: &mut String,
	ddl_type: &str,
	rust_name: &str,
	bits: u32,
	variants: &[(&'static str, u16)],
) {
	let _ = writeln!(
		out,
		"-- {} -- {} variants, {} bits. Rust: `insns::{}`.",
		rust_name,
		variants.len(),
		bits,
		rust_name
	);
	// The tag width is written explicitly rather than left to inference. DDL
	// would infer it from the largest discriminant, which for a sparse enum is
	// narrower than the field the hardware actually carries.
	let _ = writeln!(out, "enum {ddl_type}: i{bits}");

	for (i, &(name, value)) in variants.iter().enumerate() {
		let _ = writeln!(
			out,
			"  {name} = {bits}'b{value:0width$b}   -- {value}",
			name = name,
			bits = bits,
			value = value,
			width = bits as usize,
		);
		// Group in eights so the binary column stays readable.
		let last = i + 1 == variants.len();
		if !last && (i + 1) % 8 == 0 {
			let _ = writeln!(out);
		}
	}
	let _ = writeln!(out);
}

/// Renders the complete DDL enum file.
pub fn emit_ddl() -> String {
	if let Err(dups) = validate() {
		panic!("refusing to generate DDL with duplicate opcode values: {dups:?}");
	}

	let mut out = String::new();

	let _ = writeln!(out, "-- -------------------------------------------------------------------------");
	let _ = writeln!(out, "-- GENERATED FILE -- DO NOT EDIT BY HAND.");
	let _ = writeln!(out, "--");
	let _ = writeln!(out, "-- Produced by emu/src/ddl_gen.rs from the enums in emu/src/insns.rs,");
	let _ = writeln!(out, "-- which are the normative definition of the K2G instruction set.");
	let _ = writeln!(out, "--");
	let _ = writeln!(out, "-- This is the DDL counterpart of rtl/k2g_pkg.sv. Both come from the same");
	let _ = writeln!(out, "-- source, so they cannot drift apart.");
	let _ = writeln!(out, "--");
	let _ = writeln!(out, "-- Regenerate:  cd emu && cargo run --bin gen_defs");
	let _ = writeln!(out, "-- Verify:      cd emu && cargo test  (golden-file test fails on drift)");
	let _ = writeln!(out, "-- -------------------------------------------------------------------------");
	let _ = writeln!(out);

	for (ddl_type, rust_name, bits, variants) in all_enums() {
		emit_enum(&mut out, ddl_type, rust_name, bits, variants);
	}

	out
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn generated_ddl_looks_right() {
		let ddl = emit_ddl();

		assert!(ddl.contains("GENERATED FILE -- DO NOT EDIT BY HAND."));
		// Every enum carries an explicit tag width.
		assert!(ddl.contains("enum lb_e: i6"), "{ddl}");
		assert!(ddl.contains("enum rdt_e: i3"), "{ddl}");
		// The same pinned encoding the SystemVerilog test checks.
		assert!(ddl.contains("LB_ADD = 6'b110101"), "{ddl}");
		// One discriminant per code point, all 64 of them.
		assert_eq!(ddl.matches(" = 6'b").count(), 64, "{ddl}");
	}

	#[test]
	fn the_two_generators_agree_on_every_variant() {
		// The whole point of this file: if a variant or its value existed in
		// one output and not the other, the drift would be back.
		let sv = crate::sv_gen::emit_sv();
		let ddl = emit_ddl();

		for (_, _, bits, variants) in all_enums() {
			for &(name, value) in variants {
				let encoding = format!("{name} = {bits}'b{value:0width$b}", width = bits as usize);
				assert!(sv.contains(&encoding), "missing from SV: {encoding}");
				assert!(ddl.contains(&encoding), "missing from DDL: {encoding}");
			}
		}
	}

	#[test]
	fn generated_ddl_is_not_trivially_empty() {
		// So a comparison cannot pass because both sides are empty.
		let ddl = emit_ddl();
		assert!(ddl.len() > 2000, "suspiciously short: {} bytes", ddl.len());
		for ty in ["lb_e", "ep1_e", "ep2_e", "cc_e", "rdt_e"] {
			assert!(ddl.contains(&format!("enum {ty}:")), "missing {ty}");
		}
	}
}
