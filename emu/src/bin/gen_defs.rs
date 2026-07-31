//! Writes `rtl/k2g_pkg.sv` from the opcode enums in `emu/src/insns.rs`.
//!
//! Usage (from the `emu/` directory):
//!
//! ```text
//! cargo run --bin gen_defs           # write the package
//! cargo run --bin gen_defs -- --check  # exit 1 if it would change
//! ```
//!
//! `--check` is what CI should run: it fails loudly if someone edits the
//! generated file by hand or renumbers an opcode without regenerating.

use std::path::PathBuf;
use std::process::ExitCode;

fn repo_root() -> PathBuf {
	// CARGO_MANIFEST_DIR is <repo>/emu; the RTL lives one level up.
	PathBuf::from(env!("CARGO_MANIFEST_DIR"))
		.parent()
		.expect("emu/ should have a parent directory")
		.to_path_buf()
}

/// Compare ignoring line-ending style; .gitattributes normalizes to LF but a
/// fresh checkout on Windows can still land CRLF on disk.
fn differs_from_disk(path: &PathBuf, generated: &str) -> bool {
	match std::fs::read_to_string(path) {
		Ok(cur) => cur.replace("\r\n", "\n") != generated.replace("\r\n", "\n"),
		Err(_) => true,
	}
}

fn write_out(path: &PathBuf, generated: &str) -> Result<(), String> {
	if let Some(dir) = path.parent() {
		std::fs::create_dir_all(dir)
			.map_err(|e| format!("could not create {}: {e}", dir.display()))?;
	}
	std::fs::write(path, generated)
		.map_err(|e| format!("could not write {}: {e}", path.display()))?;
	println!(
		"wrote {} ({} bytes, {} lines)",
		path.display(),
		generated.len(),
		generated.lines().count()
	);
	Ok(())
}

fn main() -> ExitCode {
	let check_only = std::env::args().any(|a| a == "--check");
	let root = repo_root();

	let outputs = [
		(root.join(emu::sv_gen::OUTPUT_PATH), emu::sv_gen::emit_sv()),
		(root.join(emu::sv_gen::DOC_OUTPUT_PATH), emu::sv_gen::emit_opcode_tables_md()),
	];

	if check_only {
		let stale: Vec<_> = outputs
			.iter()
			.filter(|(p, g)| differs_from_disk(p, g))
			.map(|(p, _)| p.display().to_string())
			.collect();

		if stale.is_empty() {
			for (p, _) in &outputs {
				println!("{} is up to date.", p.display());
			}
			return ExitCode::SUCCESS;
		}
		for p in &stale {
			eprintln!("{p} is out of date.");
		}
		eprintln!("Regenerate with: cd emu && cargo run --bin gen_defs");
		return ExitCode::FAILURE;
	}

	let mut wrote_any = false;
	for (path, generated) in &outputs {
		if !differs_from_disk(path, generated) {
			println!("{} already up to date.", path.display());
			continue;
		}
		if let Err(e) = write_out(path, generated) {
			eprintln!("{e}");
			return ExitCode::FAILURE;
		}
		wrote_any = true;
	}

	if !wrote_any {
		println!("nothing to do.");
	}
	ExitCode::SUCCESS
}
