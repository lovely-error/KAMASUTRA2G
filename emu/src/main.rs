//! `emu` — run a K2G image.
//!
//! ```text
//! emu program.bin
//! emu program.bin --trace
//! emu program.bin --mem 65536 --max-steps 1000000
//! ```
//!
//! This previously took no arguments and ran on a zeroed buffer, which decodes
//! as an unassigned opcode and panicked on the very first code point.

use std::process::ExitCode;

use emu::devices::{Devices, UartIo};
use emu::fault::StopReason;
use emu::interp::Interpreter;

const DEFAULT_MEM: usize = 64 * 1024;
const DEFAULT_STEPS: u64 = 100_000_000;

fn usage() -> ExitCode {
	eprintln!(
		"usage: emu <image.bin> [options]\
		 \n\
		 \n    --mem <bytes>        memory size (default {DEFAULT_MEM})\
		 \n    --max-steps <n>      step budget (default {DEFAULT_STEPS})\
		 \n    --org <addr>         load address (default 0)\
		 \n    --trace              print architectural state after each instruction\
		 \n    --regs               dump registers on exit\
		 \n    --dump <file>        write the final memory image\
		 \n    --quiet              suppress the exit summary"
	);
	ExitCode::from(2)
}

fn parse_num(s: &str) -> Option<u64> {
	let t = s.replace('_', "");
	match t.strip_prefix("0x") {
		Some(h) => u64::from_str_radix(h, 16).ok(),
		None => t.parse().ok(),
	}
}

fn main() -> ExitCode {
	let args: Vec<String> = std::env::args().skip(1).collect();
	if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
		return usage();
	}

	let mut image_path: Option<String> = None;
	let mut mem_bytes = DEFAULT_MEM;
	let mut max_steps = DEFAULT_STEPS;
	let mut org = 0usize;
	let mut trace = false;
	let mut show_regs = false;
	let mut dump: Option<String> = None;
	let mut quiet = false;

	let mut i = 0;
	while i < args.len() {
		match args[i].as_str() {
			"--mem" => {
				i += 1;
				mem_bytes =
					args.get(i).and_then(|s| parse_num(s)).unwrap_or(DEFAULT_MEM as u64) as usize;
			}
			"--max-steps" => {
				i += 1;
				max_steps = args.get(i).and_then(|s| parse_num(s)).unwrap_or(DEFAULT_STEPS);
			}
			"--org" => {
				i += 1;
				org = args.get(i).and_then(|s| parse_num(s)).unwrap_or(0) as usize;
			}
			"--trace" => trace = true,
			"--regs" => show_regs = true,
			"--quiet" => quiet = true,
			"--dump" => {
				i += 1;
				dump = args.get(i).cloned();
			}
			other if other.starts_with("--") => {
				eprintln!("unknown option {other}");
				return usage();
			}
			other => image_path = Some(other.to_string()),
		}
		i += 1;
	}

	let Some(path) = image_path else { return usage() };
	let image = match std::fs::read(&path) {
		Ok(b) => b,
		Err(e) => {
			eprintln!("cannot read {path}: {e}");
			return ExitCode::FAILURE;
		}
	};

	if org + image.len() > mem_bytes {
		eprintln!(
			"image is {} bytes at {org:#x}, which does not fit in {mem_bytes} bytes of memory",
			image.len()
		);
		return ExitCode::FAILURE;
	}

	// u16-backed so code point access stays naturally aligned.
	let mut mem = vec![0u16; mem_bytes.div_ceil(2)];
	{
		let dst = unsafe { std::slice::from_raw_parts_mut(mem.as_mut_ptr() as *mut u8, mem_bytes) };
		dst[org..org + image.len()].copy_from_slice(&image);
	}

	let mut interp = Interpreter::with_devices(
		mem.as_mut_ptr() as *mut (),
		mem_bytes,
		Devices::new(UartIo::Stdio),
	);
	interp.ip = org as u32;

	let stop = if trace {
		run_traced(&mut interp, max_steps)
	} else {
		interp.run_bounded(max_steps)
	};

	if show_regs {
		print_regs(&interp);
	}

	if let Some(out) = dump {
		let bytes = unsafe { std::slice::from_raw_parts(mem.as_ptr() as *const u8, mem_bytes) };
		if let Err(e) = std::fs::write(&out, bytes) {
			eprintln!("cannot write {out}: {e}");
			return ExitCode::FAILURE;
		}
	}

	if !quiet {
		match stop {
			StopReason::Halted => eprintln!("halted after {} instructions", interp.cycles),
			StopReason::Faulted(f) => eprintln!(
				"FAULT {} ({:#04x}) at {:#x}, info {:#x}, after {} instructions",
				f.cause.name(),
				f.cause.code(),
				interp.faults.addr,
				f.info,
				interp.cycles
			),
			StopReason::StepLimit => {
				eprintln!("step limit ({max_steps}) reached; still at {:#x}", interp.ip)
			}
		}
	}

	match stop {
		StopReason::Halted => ExitCode::SUCCESS,
		_ => ExitCode::FAILURE,
	}
}

/// Emits one line of architectural state per retired instruction.
///
/// This is the reference stream the RTL cosimulation diffs against, so it
/// carries everything architecturally visible: the instruction's address, all
/// 32 registers with tags and flags, and the jump latch.
fn run_traced(interp: &mut Interpreter, max_steps: u64) -> StopReason {
	use std::io::Write;
	let stdout = std::io::stdout();
	let mut out = std::io::BufWriter::new(stdout.lock());

	for _ in 0..max_steps {
		let isa = interp.ip;
		match interp.step() {
			Ok(cont) => {
				let _ = write!(out, "{isa:08x}");
				for r in &interp.regs {
					let _ = write!(
						out,
						" {:08x}:{}{}{}",
						r.bits,
						r.datatype as u8,
						u8::from(r.flags.overflow),
						u8::from(r.flags.flag_bit)
					);
				}
				let _ = writeln!(
					out,
					" nisa={}",
					match interp.nisa {
						Some(v) => format!("{v:08x}"),
						None => "--------".to_string(),
					}
				);
				if !cont {
					let _ = out.flush();
					return StopReason::Halted;
				}
			}
			Err(f) => {
				let _ = out.flush();
				return StopReason::Faulted(f);
			}
		}
	}
	let _ = out.flush();
	StopReason::StepLimit
}

fn print_regs(interp: &Interpreter) {
	eprintln!("ip = {:#010x}   instructions = {}", interp.ip, interp.cycles);
	for (i, r) in interp.regs.iter().enumerate() {
		if r.bits == 0 && !r.flags.overflow && !r.flags.flag_bit {
			continue;
		}
		eprintln!(
			"  r{i:<2} = {:#010x} ({:>11})  {:?}{}{}",
			r.bits,
			r.bits as i32,
			r.datatype,
			if r.flags.overflow { " OV" } else { "" },
			if r.flags.flag_bit { " F" } else { "" },
		);
	}
}
