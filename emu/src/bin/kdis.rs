//! `kdis` — disassemble a K2G image.
//!
//! ```text
//! kdis program.bin
//! kdis test.bc --org 0
//! ```

use std::collections::HashMap;
use std::process::ExitCode;

fn main() -> ExitCode {
	let args: Vec<String> = std::env::args().skip(1).collect();
	if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
		eprintln!("usage: kdis <image.bin> [--org <addr>] [--limit <bytes>]");
		return ExitCode::from(2);
	}

	let mut path = None;
	let mut org = 0u32;
	let mut limit: Option<usize> = None;
	let mut i = 0;
	while i < args.len() {
		match args[i].as_str() {
			"--org" => {
				i += 1;
				org = args.get(i).and_then(|s| parse_num(s)).unwrap_or(0) as u32;
			}
			"--limit" => {
				i += 1;
				limit = args.get(i).and_then(|s| parse_num(s)).map(|v| v as usize);
			}
			other => path = Some(other.to_string()),
		}
		i += 1;
	}

	let Some(path) = path else { return ExitCode::from(2) };
	let mut bytes = match std::fs::read(&path) {
		Ok(b) => b,
		Err(e) => {
			eprintln!("cannot read {path}: {e}");
			return ExitCode::FAILURE;
		}
	};

	// A raw memory dump is mostly zeros; stop at the trailing run so the
	// listing is readable. test.bc is 2 KiB with 16 live code points.
	if limit.is_none() {
		let live = bytes.iter().rposition(|&b| b != 0).map(|p| p + 1).unwrap_or(0);
		limit = Some((live + 2).min(bytes.len()));
	}
	if let Some(l) = limit {
		bytes.truncate(l);
	}

	let labels = HashMap::new();
	print!("{}", emu::dis::disassemble_range(&bytes, org, org, &labels));
	ExitCode::SUCCESS
}

fn parse_num(s: &str) -> Option<i64> {
	if let Some(h) = s.strip_prefix("0x") {
		i64::from_str_radix(h, 16).ok()
	} else {
		s.parse().ok()
	}
}
