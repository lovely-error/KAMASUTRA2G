//! DPI-C shim: drives the emulator from a SystemVerilog testbench.
//!
//! This is what makes lockstep cosimulation possible. The testbench steps the
//! RTL one instruction, steps the emulator one instruction through these
//! entry points, and compares all architectural state — 32 registers with
//! their tags and flags, the program counter, and the jump latch — before
//! moving on. A divergence is reported at the instruction that caused it
//! rather than whenever the program's output eventually looks wrong.
//!
//! Everything here is `extern "C"` and pointer-based because that is what
//! Questa's DPI expects. Arrays are written through raw pointers: the
//! SystemVerilog side must declare **fixed-size** unpacked arrays, since an
//! unsized open array passes a handle rather than a pointer and would silently
//! read back as zeros (see docs/gowin-sv-support.md).

use crate::devices::{Devices, UartIo};
use crate::fault::StopReason;
use crate::interp::Interpreter;

/// Everything the shim owns. Lives in a single static because DPI is
/// single-threaded and the simulator calls in synchronously.
struct Dpi {
	/// Backing store. Boxed so the pointer handed to `Interpreter` stays valid;
	/// it is allocated once and never resized.
	mem: Box<[u16]>,
	mem_bytes: usize,
	interp: Option<Interpreter>,
	stopped: Option<StopReason>,
	/// The image as loaded, snapshotted at reset.
	///
	/// Memory is the one piece of architectural state the cosimulation never
	/// compared, so a store the RTL made and the emulator did not was invisible
	/// -- and so was the reverse. Comparing all 8 MB per instruction is not
	/// affordable, but diffing against the image at the *stop* is: the words
	/// that differ from it are exactly the ones this run wrote, and there are
	/// never many.
	pristine: Box<[u16]>,
	/// Word addresses that differ from `pristine`, computed on demand.
	dirty: Vec<u32>,
}

static mut DPI: Option<Dpi> = None;

/// Raw-pointer access rather than a reference to a `static mut`, which the 2024
/// edition rejects.
fn dpi() -> &'static mut Dpi {
	unsafe { (*(&raw mut DPI)).as_mut().expect("k2g_dpi_init was not called") }
}

/// Allocates memory and prepares a machine. Must be called before anything else.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_init(mem_bytes: u32) {
	let bytes = mem_bytes as usize;
	let dpi = Dpi {
		mem: vec![0u16; bytes.div_ceil(2)].into_boxed_slice(),
		mem_bytes: bytes,
		interp: None,
		stopped: None,
		pristine: vec![0u16; bytes.div_ceil(2)].into_boxed_slice(),
		dirty: Vec::new(),
	};
	unsafe { *(&raw mut DPI) = Some(dpi) };
}

/// Writes one byte of the program image. Called once per byte before reset.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_load(addr: u32, data: u32) {
	let d = dpi();
	let a = addr as usize;
	if a >= d.mem_bytes {
		return;
	}
	let base = d.mem.as_mut_ptr() as *mut u8;
	unsafe { base.add(a).write(data as u8) };
}

/// Starts execution at `entry`. UART output is buffered so the testbench can
/// compare it against the RTL's.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_reset(entry: u32) {
	let d = dpi();
	let ptr = d.mem.as_mut_ptr() as *mut ();
	let mut interp = Interpreter::with_devices(ptr, d.mem_bytes, Devices::new(UartIo::buffered()));
	interp.ip = entry;
	d.interp = Some(interp);
	d.stopped = None;
	// The image is fully loaded by now, so this is the baseline every later
	// memory comparison is against.
	d.pristine.copy_from_slice(&d.mem);
	d.dirty.clear();
}

/// Recomputes which 32-bit words differ from the loaded image, and returns how
/// many. Call before `k2g_dpi_mem_dirty_addr`.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_mem_dirty_count() -> u32 {
	let d = dpi();
	d.dirty.clear();
	for w in 0..(d.mem.len() / 2) {
		let i = w * 2;
		if d.mem[i] != d.pristine[i] || d.mem[i + 1] != d.pristine[i + 1] {
			d.dirty.push((w * 4) as u32);
		}
	}
	d.dirty.len() as u32
}

/// Byte address of the `i`-th word that differs from the loaded image.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_mem_dirty_addr(i: u32) -> u32 {
	let d = dpi();
	d.dirty.get(i as usize).copied().unwrap_or(0)
}

/// Reads one aligned 32-bit word of the emulator's memory.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_mem_read32(addr: u32) -> u32 {
	let d = dpi();
	let a = addr as usize;
	if a + 4 > d.mem_bytes {
		return 0;
	}
	let lo = d.mem[a / 2] as u32;
	let hi = d.mem[a / 2 + 1] as u32;
	(hi << 16) | lo
}

/// Executes one instruction.
///
/// Returns 0 while running, 1 on `HALT`, 2 on a fault. Once stopped, further
/// calls are no-ops returning the same status, so the testbench can keep
/// stepping without special-casing the end.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_step() -> i32 {
	let d = dpi();
	if let Some(reason) = d.stopped {
		return match reason {
			StopReason::Halted => 1,
			_ => 2,
		};
	}
	let interp = d.interp.as_mut().expect("k2g_dpi_reset was not called");
	match interp.step() {
		Ok(true) => 0,
		Ok(false) => {
			d.stopped = Some(StopReason::Halted);
			1
		}
		Err(fault) => {
			d.stopped = Some(StopReason::Faulted(fault));
			2
		}
	}
}

fn with_interp<T>(f: impl FnOnce(&Interpreter) -> T, default: T) -> T {
	match dpi().interp.as_ref() {
		Some(i) => f(i),
		None => default,
	}
}

/// Writes all 32 register values. `out` must point at 32 words.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_get_regs(out: *mut u32) {
	with_interp(
		|i| {
			for (n, r) in i.regs.iter().enumerate() {
				unsafe { out.add(n).write(r.bits) };
			}
		},
		(),
	);
}

/// Writes all 32 tags as `rdt_e` values.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_get_tags(out: *mut u32) {
	with_interp(
		|i| {
			for (n, r) in i.regs.iter().enumerate() {
				unsafe { out.add(n).write(r.datatype as u32) };
			}
		},
		(),
	);
}

/// Writes all 32 flag pairs, packed as `{overflow, flag_bit}`.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_get_flags(out: *mut u32) {
	with_interp(
		|i| {
			for (n, r) in i.regs.iter().enumerate() {
				let v = (u32::from(r.flags.overflow) << 1) | u32::from(r.flags.flag_bit);
				unsafe { out.add(n).write(v) };
			}
		},
		(),
	);
}

#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_get_pc() -> u32 {
	with_interp(|i| i.ip, 0)
}

/// The jump latch: bit 32 would be the valid bit, so it is reported separately.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_get_nisa() -> u32 {
	with_interp(|i| i.nisa.unwrap_or(0), 0)
}

#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_get_nisa_valid() -> u32 {
	with_interp(|i| u32::from(i.nisa.is_some()), 0)
}

#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_get_fault_cause() -> u32 {
	with_interp(|i| i.faults.cause, 0)
}

#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_get_fault_addr() -> u32 {
	with_interp(|i| i.faults.addr, 0)
}

#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_get_fault_info() -> u32 {
	with_interp(|i| i.faults.info, 0)
}

#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_uart_len() -> u32 {
	with_interp(|i| i.dev.uart.output().len() as u32, 0)
}

#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_uart_at(index: u32) -> u32 {
	with_interp(
		|i| i.dev.uart.output().get(index as usize).copied().unwrap_or(0) as u32,
		0,
	)
}

/// Retired instruction count, for cross-checking the testbench's own tally.
#[unsafe(no_mangle)]
pub extern "C" fn k2g_dpi_get_cycles() -> u32 {
	with_interp(|i| i.cycles as u32, 0)
}
