//! `kgen` — generates random K2G programs for differential testing.
//!
//! Directed tests only cover what someone thought to write down. The hard part
//! of this ISA is combinatorial: prefixes times main opcodes, times register
//! tags, times condition codes. `tb_decode` hand-checks maybe twenty of those
//! combinations; this explores them.
//!
//! Programs are deliberately **straight-line**: no branches, ending in `HALT`.
//! Control flow is already covered by `hello` and `fib`, and a random branch
//! would either loop forever or need a reachability analysis to avoid it. What
//! is *not* covered by those two programs is most of the execute path, which
//! is exactly what a long straight-line program exercises.
//!
//! Every instruction is chosen so it cannot fault: no `DIV` or `LDF32`,
//! accesses are aligned and inside a reserved scratch area, and bit-field
//! extracts always have a non-zero span. A faulting program would still be a
//! valid comparison, but it would stop early and test very little.
//!
//! That leaves the fault paths unreachable from here, and for a long time it
//! left them unreachable from anything: deleting the misaligned-access check
//! from `k2g_core.sv` outright passed every testbench and the whole
//! cosimulation. `--fault` closes that. It generates the same clean program
//! and replaces the closing `HALT` with one deliberately faulting instruction,
//! so the fault is reached with several hundred instructions of randomized
//! register contents, tags and flags behind it rather than the four
//! instructions a directed program can set up.
//!
//! ```text
//! kgen --seed 7 --count 200 -o random.bin
//! kgen --seed 7 --count 200 --fault -o random_fault.bin
//! ```

use std::process::ExitCode;

use emu::insns::*;

/// xorshift64*, so runs are reproducible from a seed without a dependency.
struct Rng(u64);

impl Rng {
	fn new(seed: u64) -> Self {
		Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
	}
	fn next(&mut self) -> u64 {
		let mut x = self.0;
		x ^= x >> 12;
		x ^= x << 25;
		x ^= x >> 27;
		self.0 = x;
		x.wrapping_mul(0x2545_F491_4F6C_DD1D)
	}
	fn below(&mut self, n: u32) -> u32 {
		(self.next() % n as u64) as u32
	}
	fn chance(&mut self, percent: u32) -> bool {
		self.below(100) < percent
	}
}

/// r31 holds the scratch-area base and is never written, so generated loads
/// and stores always land somewhere safe.
const BASE_REG: u16 = 31;
/// Destinations are drawn from r0..r30.
const N_DST: u32 = 31;

const SCRATCH_OFF: usize = 0x800;
/// Load and store offsets go through an `XI` prefix, whose 10-bit field is
/// SIGN-extended (spec 4). Anything from 512 up would therefore address
/// backwards out of the scratch area, so the usable window is 0..511.
const SCRATCH_LEN: usize = 512;

fn rand_reg(rng: &mut Rng) -> u16 {
	rng.below(N_DST) as u16
}

fn rand_tag(rng: &mut Rng) -> RDT {
	// F32 and the unassigned encoding are reserved and would fault.
	match rng.below(6) {
		0 => RDT::RDT_U8,
		1 => RDT::RDT_U16,
		2 => RDT::RDT_U32,
		3 => RDT::RDT_S8,
		4 => RDT::RDT_S16,
		_ => RDT::RDT_S32,
	}
}

fn rand_cc(rng: &mut Rng) -> CC {
	match rng.below(5) {
		0 => CC::CC_OVERFLOW_SET,
		1 => CC::CC_FLAG_SET,
		2 => CC::CC_VALUE_ZERO,
		3 => CC::CC_VALUE_NEGATIVE,
		_ => CC::CC_VALUE_POSITIVE,
	}
}

/// An immediate spanning the interesting magnitudes, including negatives so
/// the sign-extension paths get used.
fn rand_imm(rng: &mut Rng) -> isize {
	match rng.below(5) {
		0 => (rng.below(32) as isize) - 16,      // fits the 5-bit form
		1 => (rng.below(2048) as isize) - 1024,  // needs XI
		2 => -(rng.below(16384) as isize),
		3 => rng.below(16383) as isize,
		_ => 0,
	}
}

fn gen_program(seed: u64, count: usize, fault: Option<usize>) -> Vec<u16> {
	let mut rng = Rng::new(seed);
	let mut out: Vec<u16> = Vec::new();

	// Prologue: r31 = scratch base. Reserved from here on.
	out.extend_from_slice(&encode_llc_b32(BASE_REG, SCRATCH_OFF));

	// Give the low registers defined, varied contents so later operations see
	// interesting operands rather than a field of zeros.
	for r in 0..8u16 {
		out.extend_from_slice(&encode_llc_b32(r, (0x1111_1111u32 as usize).wrapping_mul(r as usize + 1)));
	}

	for _ in 0..count {
		let kind = rng.below(20);
		let dst = rand_reg(&mut rng);
		let src = rand_reg(&mut rng);

		// Some forms need a setup instruction -- a store must have its source
		// tagged to pick the width, a port read must have the port number in a
		// register. That setup is emitted UNPREDICATED, because a predicate
		// prefix guards only the single instruction that follows it. Guarding
		// the setup instead would let the main instruction run against a stale
		// register, which is how the first version of this generator produced
		// a misaligned store and a read of port 0x77.
		let mut store_tag = (RDT::RDT_U32, 4u16);
		let mut mem_off = 0u16;

		match kind {
			14 | 15 => {
				store_tag = match rng.below(3) {
					0 => (RDT::RDT_U8, 1),
					1 => (RDT::RDT_U16, 2),
					_ => (RDT::RDT_U32, 4),
				};
				let slots = (SCRATCH_LEN as u16) / store_tag.1;
				mem_off = (rng.below(slots as u32) as u16) * store_tag.1;
				out.extend_from_slice(&encode_rdt(src, store_tag.0));
			}
			16 | 17 => {
				store_tag = match rng.below(3) {
					0 => (RDT::RDT_U8, 1),
					1 => (RDT::RDT_U16, 2),
					_ => (RDT::RDT_U32, 4),
				};
				let slots = (SCRATCH_LEN as u16) / store_tag.1;
				mem_off = (rng.below(slots as u32) as u16) * store_tag.1;
			}
			18 => {
				// CORE_ID. The cycle counter is deliberately excluded: the two
				// machines count differently, so it is not a fair comparison.
				out.extend_from_slice(&encode_llc_b32(dst, 0x0A));
			}
			_ => {}
		}

		// A predicate prefix on roughly a third of instructions. Both taken and
		// untaken cases matter: an untaken one must suppress every
		// architectural effect while still advancing the PC (spec 7).
		if rng.chance(30) {
			let r = rand_reg(&mut rng);
			let cc = rand_cc(&mut rng);
			if rng.chance(50) {
				out.extend_from_slice(&encode_xcp(r, cc));
			} else {
				out.extend_from_slice(&encode_xcn(r, cc));
			}
		}

		match kind {
			// ---- constants and tags ----
			0 => {
				let v = rand_imm(&mut rng);
				match rng.below(3) {
					0 => out.extend_from_slice(&encode_lc_i5_b8(dst, (v % 16).clamp(-16, 15))),
					1 => out.extend_from_slice(&encode_llc_b16(dst, (v as u32 & 0xffff) as usize)),
					_ => out.extend_from_slice(&encode_llc_b32(dst, v as u32 as usize)),
				}
			}
			1 => out.extend_from_slice(&encode_rdt(dst, rand_tag(&mut rng))),
			2 => out.extend_from_slice(&encode_cpy(dst, src)),

			// ---- arithmetic ----
			3 => {
				let op = match rng.below(3) {
					0 => LB::LB_ADD,
					1 => LB::LB_SUB,
					_ => LB::LB_MUL,
				};
				if rng.chance(50) {
					out.extend_from_slice(&encode_alu_rr(op, dst, src));
				} else {
					out.extend_from_slice(&encode_alu_ri(op, dst, rand_imm(&mut rng)));
				}
			}
			// Widening multiply, sometimes aliased so the low-half-wins rule
			// gets exercised (spec 5.5).
			4 => {
				let hi = if rng.chance(25) { dst } else { rand_reg(&mut rng) };
				out.extend_from_slice(&encode_mulw_rr(dst, src, hi));
			}

			// ---- logic ----
			5 => {
				let op = match rng.below(3) {
					0 => LB::LB_AND,
					1 => LB::LB_OR,
					_ => LB::LB_XOR,
				};
				if rng.chance(50) {
					out.extend_from_slice(&encode_alu_rr(op, dst, src));
				} else {
					out.extend_from_slice(&encode_alu_ri(op, dst, rand_imm(&mut rng)));
				}
			}
			6 => match rng.below(4) {
				0 => out.extend_from_slice(&encode_flag_and(dst, src)),
				1 => out.extend_from_slice(&encode_flag_or(dst, src)),
				2 => out.extend_from_slice(&encode_flag_xor(dst, src)),
				_ => out.extend_from_slice(&encode_flag_not(dst)),
			},
			7 => {
				if rng.chance(50) {
					out.extend_from_slice(&encode_inv(dst));
				} else {
					out.extend_from_slice(&encode_neg(dst));
				}
			}

			// ---- shifts ----
			8 | 9 => {
				let amt = rng.below(32) as u16;
				match rng.below(6) {
					0 => out.extend_from_slice(&encode_shl_ri(dst, amt)),
					1 => out.extend_from_slice(&encode_shr_ri(dst, amt)),
					2 => out.extend_from_slice(&encode_shra_ri(dst, amt)),
					3 => out.extend_from_slice(&encode_shl_rr(dst, src)),
					4 => out.extend_from_slice(&encode_shr_rr(dst, src)),
					_ => out.extend_from_slice(&encode_shra_rr(dst, src)),
				}
			}

			// ---- bit fields ----
			// A zero span faults for extract but is a defined no-op for
			// insert, so only insert may use it (spec 5.8).
			10 => {
				let start = rng.below(32) as u16;
				let span = 1 + rng.below(31) as u16;
				out.extend_from_slice(&encode_bext(dst, src, start, span));
			}
			11 => {
				let start = rng.below(32) as u16;
				let span = rng.below(32) as u16;
				out.extend_from_slice(&encode_bins(dst, src, start, span));
			}

			// ---- comparisons ----
			12 | 13 => {
				let op = match rng.below(6) {
					0 => LB::LB_TST,
					1 => LB::LB_TSTN,
					2 => LB::LB_LT,
					3 => LB::LB_GT,
					4 => LB::LB_LTE,
					_ => LB::LB_GTE,
				};
				if rng.chance(50) {
					out.extend_from_slice(&encode_alu_rr(op, dst, src));
				} else {
					out.extend_from_slice(&encode_alu_ri(op, dst, rand_imm(&mut rng)));
				}
			}

			// ---- memory ----
			14 | 15 => {
				out.push(pack_6_10(LB::LB_XI as _, mem_off & 0x1ff));
				out.push(pack_6_5_5(LB::LB_ST as _, BASE_REG, src));
			}
			16 | 17 => {
				let lb = match store_tag.1 {
					1 => LB::LB_LD8,
					2 => LB::LB_LD16,
					_ => LB::LB_LD32,
				};
				out.push(pack_6_10(LB::LB_XI as _, mem_off & 0x1ff));
				out.push(pack_6_5_5(lb as _, dst, BASE_REG));
			}

			// ---- I/O ----
			18 => out.extend_from_slice(&encode_ld_msr_32(src, dst)),

			// ---- nop ----
			_ => out.extend_from_slice(&encode_nop()),
		}
	}

	match fault {
		None => out.extend_from_slice(&encode_halt()),
		Some(f) => out.extend_from_slice(&gen_fault(f, &mut rng)),
	}
	out
}

/// The faults a generated program can end with, and the cause each one raises.
///
/// One per cause the ISA defines and a program can reach; `DOUBLE_PRIME` is
/// gone and `HALT_INSN` is the ordinary ending. The set is walked by index so
/// a sweep covers every one rather than sampling.
const FAULT_KINDS: usize = 10;

fn fault_cause_name(kind: usize) -> &'static str {
	match kind % FAULT_KINDS {
		0 => "FAULT_DIV_UNIMPLEMENTED",
		1 => "FAULT_FP_UNIMPLEMENTED",
		2 => "FAULT_FP_UNIMPLEMENTED",
		3 => "FAULT_MISALIGNED_LOAD",
		4 => "FAULT_MISALIGNED_STORE",
		5 => "FAULT_ADDR_OUT_OF_RANGE",
		6 => "FAULT_BAD_CSP_PORT",
		7 => "FAULT_BEXT_ZERO_SPAN",
		8 => "FAULT_ILLEGAL_PREFIX_COMBO",
		_ => "FAULT_MISALIGNED_FETCH",
	}
}

/// Emits an instruction that faults with the cause `fault_cause_name` reports.
///
/// Registers are set up here rather than assumed: the generated program has
/// been writing r0..r30 for hundreds of instructions, so nothing about their
/// contents can be relied on.
fn gen_fault(kind: usize, rng: &mut Rng) -> Vec<u16> {
	let r = rand_reg(rng);
	let r2 = rand_reg(rng);
	let mut v: Vec<u16> = Vec::new();
	match kind % FAULT_KINDS {
		// Cut from v1, rejected in decode.
		0 => v.extend_from_slice(&[pack_6_5_5(LB::LB_DIV as u16, r, r2)]),
		// The two float opcodes, both rejected in decode.
		1 => v.extend_from_slice(&[pack_6_5_5(LB::LB_LDF32 as u16, r, BASE_REG)]),
		// An F32-tagged operand, which is an execute-time read-port check.
		2 => {
			v.extend_from_slice(&encode_rdt(r, RDT::RDT_F32));
			v.extend_from_slice(&[pack_6_5_5(LB::LB_ADD as u16, r, r)]);
		}
		3 => {
			v.extend_from_slice(&encode_llc_b32(r, 3));
			v.extend_from_slice(&encode_ld_b32(r2, r));
		}
		4 => {
			v.extend_from_slice(&encode_llc_b32(r, 1));
			v.extend_from_slice(&encode_llc_b32(r2, 7)); // U32 tag: a 4-byte store
			v.extend_from_slice(&encode_st(r, r2));
		}
		5 => {
			// The first address past the 8 MB of PSRAM (spec 1.3).
			v.extend_from_slice(&encode_llc_b32(r, 0x80_0000));
			v.extend_from_slice(&encode_ld_b32(r2, r));
		}
		6 => {
			v.extend_from_slice(&encode_llc_b32(r, 0x7FFF)); // not a port
			v.extend_from_slice(&encode_ld_msr_32(r2, r));
		}
		// `BMX` with a zero span, then `SHL` -- the extract form (spec 5.8).
		7 => v.extend_from_slice(&[
			pack_6_5_5(LB::LB_BMX_0_0 as u16, 0, 0),
			pack_6_5_5(LB::LB_SHL as u16, r, r2),
		]),
		// `BMX` on `SHRA`, which it does not reinterpret.
		8 => v.extend_from_slice(&[
			pack_6_5_5(LB::LB_BMX_0_0 as u16, 0, 4),
			pack_6_5_5(LB::LB_SHRA as u16, r, r2),
		]),
		// An odd jump target, rejected where it is primed (spec 6.4).
		_ => {
			v.extend_from_slice(&encode_llc_b32(r, 7));
			v.extend_from_slice(&encode_disp_reg_addr(r));
		}
	}
	// Unreached, and there to keep the image well formed if it ever is.
	v.extend_from_slice(&encode_halt());
	v
}

fn main() -> ExitCode {
	let args: Vec<String> = std::env::args().skip(1).collect();
	let mut seed: u64 = 1;
	let mut count: usize = 200;
	let mut out_path = String::from("random.bin");
	let mut fault: Option<usize> = None;

	let mut i = 0;
	while i < args.len() {
		match args[i].as_str() {
			"--seed" => {
				i += 1;
				seed = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(1);
			}
			"--count" => {
				i += 1;
				count = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(200);
			}
			"--fault" => {
				// The kind defaults to the seed, so a sweep of seeds is also a
				// sweep of causes rather than the same one every time.
				i += 1;
				match args.get(i).and_then(|s| s.parse::<usize>().ok()) {
					Some(k) => fault = Some(k),
					None => {
						fault = Some(seed as usize);
						if args.get(i).is_some_and(|s| !s.starts_with("--")) {
							eprintln!("--fault takes a number or nothing");
							return ExitCode::from(2);
						}
						i -= 1;
					}
				}
			}
			"--fault-cause" => {
				// Prints the cause the image will stop with, for the harness.
				i += 1;
				let k = args.get(i).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
				println!("{}", fault_cause_name(k));
				return ExitCode::SUCCESS;
			}
			"-o" => {
				i += 1;
				out_path = args.get(i).cloned().unwrap_or(out_path);
			}
			other => {
				eprintln!("unknown argument {other}");
				return ExitCode::from(2);
			}
		}
		i += 1;
	}

	let words = gen_program(seed, count, fault);
	let mut bytes = Vec::with_capacity(words.len() * 2);
	for w in &words {
		bytes.extend_from_slice(&w.to_le_bytes());
	}

	match std::fs::write(&out_path, &bytes) {
		Ok(()) => {
			match fault {
				None => println!(
					"wrote {out_path}: seed {seed}, {count} instructions, {} code points",
					words.len()
				),
				Some(k) => println!(
					"wrote {out_path}: seed {seed}, {count} instructions, {} code points, ending in {}",
					words.len(),
					fault_cause_name(k)
				),
			}
			ExitCode::SUCCESS
		}
		Err(e) => {
			eprintln!("cannot write {out_path}: {e}");
			ExitCode::FAILURE
		}
	}
}
