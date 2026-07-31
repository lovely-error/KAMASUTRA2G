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

fn main() -> ExitCode {
	let check_only = std::env::args().any(|a| a == "--check");

	let generated = emu::sv_gen::emit_sv();
	let out_path = repo_root().join(emu::sv_gen::OUTPUT_PATH);

	let existing = std::fs::read_to_string(&out_path).ok();
	// Compare ignoring line-ending style; .gitattributes normalizes to LF but a
	// fresh checkout on Windows can still land CRLF on disk.
	let differs = match &existing {
		Some(cur) => cur.replace("\r\n", "\n") != generated.replace("\r\n", "\n"),
		None => true,
	};

	if check_only {
		return if differs {
			eprintln!("{} is out of date.", out_path.display());
			eprintln!("Regenerate with: cd emu && cargo run --bin gen_defs");
			ExitCode::FAILURE
		} else {
			println!("{} is up to date.", out_path.display());
			ExitCode::SUCCESS
		};
	}

	if !differs {
		println!("{} already up to date.", out_path.display());
		return ExitCode::SUCCESS;
	}

	if let Some(dir) = out_path.parent() {
		if let Err(e) = std::fs::create_dir_all(dir) {
			eprintln!("could not create {}: {e}", dir.display());
			return ExitCode::FAILURE;
		}
	}

	match std::fs::write(&out_path, &generated) {
		Ok(()) => {
			println!(
				"wrote {} ({} bytes, {} lines)",
				out_path.display(),
				generated.len(),
				generated.lines().count()
			);
			ExitCode::SUCCESS
		}
		Err(e) => {
			eprintln!("could not write {}: {e}", out_path.display());
			ExitCode::FAILURE
		}
	}
}
