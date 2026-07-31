//! `kasm` — assemble K2G source into a flat memory image.
//!
//! ```text
//! kasm program.kasm -o program.bin
//! kasm program.kasm --listing
//! ```

use std::process::ExitCode;

fn usage() -> ExitCode {
	eprintln!(
		"usage: kasm <source.kasm> [-o <out.bin>] [--listing]\n\
		 \n\
		 	-o <file>   write the flat little-endian image (default: <source>.bin)\n\
		 	--listing   print address/encoding/source instead of writing a file\n\
		 	--labels    print the symbol table"
	);
	ExitCode::from(2)
}

fn main() -> ExitCode {
	let args: Vec<String> = std::env::args().skip(1).collect();
	if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
		return usage();
	}

	let mut source_path: Option<String> = None;
	let mut out_path: Option<String> = None;
	let mut listing = false;
	let mut show_labels = false;

	let mut i = 0;
	while i < args.len() {
		match args[i].as_str() {
			"-o" => {
				i += 1;
				match args.get(i) {
					Some(p) => out_path = Some(p.clone()),
					None => return usage(),
				}
			}
			"--listing" => listing = true,
			"--labels" => show_labels = true,
			other if other.starts_with('-') => {
				eprintln!("unknown option {other}");
				return usage();
			}
			other => source_path = Some(other.to_string()),
		}
		i += 1;
	}

	let Some(src_path) = source_path else { return usage() };
	let source = match std::fs::read_to_string(&src_path) {
		Ok(s) => s,
		Err(e) => {
			eprintln!("cannot read {src_path}: {e}");
			return ExitCode::FAILURE;
		}
	};

	let program = match emu::asm::assemble(&source) {
		Ok(p) => p,
		Err(errors) => {
			for e in &errors {
				eprintln!("{src_path}:{}", e);
			}
			eprintln!("{} error(s)", errors.len());
			return ExitCode::FAILURE;
		}
	};

	if show_labels {
		let mut names: Vec<_> = program.labels.iter().collect();
		names.sort_by_key(|(_, a)| **a);
		for (name, addr) in names {
			println!("{addr:#06x}  {name}");
		}
	}

	if listing {
		// Disassemble what was produced, so the listing reflects the actual
		// encoding rather than the source's intent.
		let bytes = program.to_bytes();
		let text = emu::dis::disassemble_range(&bytes, program.origin, program.origin, &program.labels);
		print!("{text}");
		return ExitCode::SUCCESS;
	}

	let out = out_path.unwrap_or_else(|| {
		let stem = src_path.rsplit_once('.').map(|(a, _)| a).unwrap_or(&src_path);
		format!("{stem}.bin")
	});

	match std::fs::write(&out, program.to_bytes()) {
		Ok(()) => {
			println!(
				"wrote {out}: {} code points ({} bytes) at {:#x}",
				program.words.len(),
				program.words.len() * 2,
				program.origin
			);
			ExitCode::SUCCESS
		}
		Err(e) => {
			eprintln!("cannot write {out}: {e}");
			ExitCode::FAILURE
		}
	}
}
