//! Fails if the checked-in `rtl/k2g_pkg.sv` no longer matches what
//! `emu/src/sv_gen.rs` would emit from the enums in `emu/src/insns.rs`.
//!
//! This is the guard that makes opcode drift impossible to commit. The
//! superseded `decoder.sv` diverged from the emulator precisely because
//! nothing ever compared the two: it ended up with `LB_ADD = 62` against the
//! emulator's 53, the opcode field at `lane[5:0]` instead of `cp[15:10]`, and
//! duplicate labels that no tool flagged.

use std::path::PathBuf;

fn generated_path() -> PathBuf {
	PathBuf::from(env!("CARGO_MANIFEST_DIR"))
		.parent()
		.expect("emu/ should have a parent directory")
		.join(emu::sv_gen::OUTPUT_PATH)
}

/// Line endings are normalized so a CRLF checkout does not fail spuriously.
fn norm(s: &str) -> String {
	s.replace("\r\n", "\n")
}

#[test]
fn checked_in_package_matches_generator() {
	let path = generated_path();

	let on_disk = std::fs::read_to_string(&path).unwrap_or_else(|e| {
		panic!(
			"could not read {}: {e}\n\
			 Generate it with: cd emu && cargo run --bin gen_defs",
			path.display()
		)
	});

	let expected = emu::sv_gen::emit_sv();

	if norm(&on_disk) != norm(&expected) {
		// Point at the first differing line rather than dumping 229 lines.
		let a: Vec<_> = norm(&on_disk).lines().map(str::to_owned).collect();
		let b: Vec<_> = norm(&expected).lines().map(str::to_owned).collect();
		let first_diff = a
			.iter()
			.zip(b.iter())
			.position(|(x, y)| x != y)
			.unwrap_or(a.len().min(b.len()));

		panic!(
			"{} is stale (on disk {} lines, generator produces {}).\n\
			 First difference at line {}:\n\
			   on disk:   {:?}\n\
			   generator: {:?}\n\
			 Regenerate with: cd emu && cargo run --bin gen_defs",
			path.display(),
			a.len(),
			b.len(),
			first_diff + 1,
			a.get(first_diff),
			b.get(first_diff),
		);
	}
}

/// The generated file must actually contain the opcode map, not just a header.
/// Guards against the comparison above passing because both sides are empty.
#[test]
fn generated_package_is_not_trivially_empty() {
	let sv = emu::sv_gen::emit_sv();
	assert!(sv.len() > 4000, "generated package suspiciously short: {} bytes", sv.len());
	assert!(sv.contains("package k2g_pkg;"));
	assert!(sv.contains("endpackage"));
	for needle in ["lb_e", "ep1_e", "ep2_e", "cc_e"] {
		assert!(sv.contains(needle), "missing enum type {needle}");
	}
}
