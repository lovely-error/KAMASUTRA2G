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
//! ```text
//! kgen --seed 7 --count 200 -o random.bin
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

fn gen_program(seed: u64, count: usize) -> Vec<u16> {
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

	out.extend_from_slice(&encode_halt());
	out
}

fn main() -> ExitCode {
	let args: Vec<String> = std::env::args().skip(1).collect();
	let mut seed: u64 = 1;
	let mut count: usize = 200;
	let mut out_path = String::from("random.bin");

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

	let words = gen_program(seed, count);
	let mut bytes = Vec::with_capacity(words.len() * 2);
	for w in &words {
		bytes.extend_from_slice(&w.to_le_bytes());
	}

	match std::fs::write(&out_path, &bytes) {
		Ok(()) => {
			println!(
				"wrote {out_path}: seed {seed}, {count} instructions, {} code points",
				words.len()
			);
			ExitCode::SUCCESS
		}
		Err(e) => {
			eprintln!("cannot write {out_path}: {e}");
			ExitCode::FAILURE
		}
	}
}
