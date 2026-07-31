//! The CSP I/O port space — `docs/isa-spec.md` §9.
//!
//! I/O is deliberately *not* memory-mapped. The `CSP` prefix redirects `LD`/`ST`
//! into this separate 32-bit port space, which keeps the memory path free of
//! device address decoding — on hardware that means the load/store unit never
//! needs a comparator against device ranges.
//!
//! Note the operand asymmetry inherited from the underlying `LD`/`ST` forms:
//! `CSP + LD` takes the port number from `arg2`, `CSP + ST` from `arg1`.

use crate::fault::{Fault, FaultCause};

pub mod port {
	pub const UART_DATA: u32 = 0x00;
	pub const UART_STATUS: u32 = 0x01;
	pub const CYCLE_COUNT_LO: u32 = 0x02;
	pub const CYCLE_COUNT_HI: u32 = 0x03;
	pub const FAULT_CAUSE: u32 = 0x04;
	pub const FAULT_ADDR: u32 = 0x05;
	pub const FAULT_INFO: u32 = 0x06;
	pub const TRAP_VECTOR: u32 = 0x07;
	pub const TRAP_ENABLE: u32 = 0x08;
	pub const GPIO_OUT: u32 = 0x09;
	pub const CORE_ID: u32 = 0x0A;
	pub const COMPAT_FLAGS: u32 = 0x0B;
	pub const STICKY_STATUS: u32 = 0x0C;
}

/// `CORE_ID` reads as ASCII "K2G1".
pub const CORE_ID_VALUE: u32 = 0x4B32_4731;

/// `UART_STATUS` bit: transmit buffer full.
pub const UART_STATUS_TX_FULL: u32 = 1 << 0;
/// `UART_STATUS` bit: receive buffer empty.
pub const UART_STATUS_RX_EMPTY: u32 = 1 << 1;

/// `COMPAT_FLAGS` bit 0: fault on a second `PrepareJump` instead of
/// last-prime-wins (spec §6.6). Off by default; used for differential testing
/// against the older behaviour.
pub const COMPAT_TRAP_ON_DOUBLE_PRIME: u32 = 1 << 0;

/// `STICKY_STATUS` bit 0: a memory-ordering prefix that v1 ignores was
/// executed. Not an error — a hint that the program expects multicore
/// semantics this implementation does not provide.
pub const STICKY_REMOVED_ORDERING_PREFIX: u32 = 1 << 0;

/// Where UART output goes and where input comes from.
///
/// Kept abstract so tests can capture output without touching stdio, and so the
/// cosimulation harness can drive both machines from one script.
pub enum UartIo {
	/// Transmit to stdout, receive from stdin.
	Stdio,
	/// Transmit into a buffer, receive from a queued script. Used by tests.
	Buffered { tx: Vec<u8>, rx: std::collections::VecDeque<u8> },
	/// Discard output, never receive.
	Null,
}

impl UartIo {
	pub fn buffered() -> Self {
		UartIo::Buffered { tx: Vec::new(), rx: std::collections::VecDeque::new() }
	}

	pub fn with_input(input: &[u8]) -> Self {
		UartIo::Buffered { tx: Vec::new(), rx: input.iter().copied().collect() }
	}

	/// Bytes transmitted so far, for `Buffered`.
	pub fn output(&self) -> &[u8] {
		match self {
			UartIo::Buffered { tx, .. } => tx,
			_ => &[],
		}
	}

	fn put(&mut self, byte: u8) {
		match self {
			UartIo::Stdio => {
				use std::io::Write;
				let mut out = std::io::stdout();
				let _ = out.write_all(&[byte]);
				// Unbuffered so output interleaves correctly with diagnostics
				// and survives a fault that stops the machine mid-line.
				let _ = out.flush();
			}
			UartIo::Buffered { tx, .. } => tx.push(byte),
			UartIo::Null => {}
		}
	}

	fn get(&mut self) -> Option<u8> {
		match self {
			UartIo::Stdio => {
				use std::io::Read;
				let mut buf = [0u8; 1];
				match std::io::stdin().read(&mut buf) {
					Ok(1) => Some(buf[0]),
					_ => None,
				}
			}
			UartIo::Buffered { rx, .. } => rx.pop_front(),
			UartIo::Null => None,
		}
	}

	fn rx_empty(&self) -> bool {
		match self {
			// Genuinely unknown without blocking; report "has data" and let the
			// read return 0 at EOF.
			UartIo::Stdio => false,
			UartIo::Buffered { rx, .. } => rx.is_empty(),
			UartIo::Null => true,
		}
	}
}

/// State behind the CSP port space.
pub struct Devices {
	pub uart: UartIo,
	pub uart_divisor: u32,
	pub gpio_out: u32,
	pub compat_flags: u32,
	pub sticky_status: u32,
	pub trap_vector: u32,
	pub trap_enable: u32,
}

impl Default for Devices {
	fn default() -> Self {
		Devices {
			uart: UartIo::Null,
			uart_divisor: 0,
			gpio_out: 0,
			compat_flags: 0,
			sticky_status: 0,
			trap_vector: 0,
			trap_enable: 0,
		}
	}
}

/// Fault state, exposed through the `FAULT_*` ports.
///
/// On real hardware a halted core cannot execute a `CSP` read to report its own
/// cause, which is why the spec also requires these on LEDs and a halt-time
/// UART dump. In the emulator they are readable by a program that faults only
/// if a trap handler is ever implemented (spec §8.1).
#[derive(Default, Clone, Copy)]
pub struct FaultRegs {
	pub cause: u32,
	pub addr: u32,
	pub info: u32,
}

impl Devices {
	pub fn new(uart: UartIo) -> Self {
		Devices { uart, ..Default::default() }
	}

	/// Reads a port. `cycles` and `faults` come from the interpreter.
	pub fn read(&mut self, port: u32, cycles: u64, faults: FaultRegs) -> Result<u32, Fault> {
		Ok(match port {
			port::UART_DATA => self.uart.get().unwrap_or(0) as u32,
			port::UART_STATUS => {
				// TX never blocks in the emulator.
				if self.uart.rx_empty() { UART_STATUS_RX_EMPTY } else { 0 }
			}
			port::CYCLE_COUNT_LO => cycles as u32,
			port::CYCLE_COUNT_HI => (cycles >> 32) as u32,
			port::FAULT_CAUSE => faults.cause,
			port::FAULT_ADDR => faults.addr,
			port::FAULT_INFO => faults.info,
			port::TRAP_VECTOR => self.trap_vector,
			port::TRAP_ENABLE => self.trap_enable,
			port::GPIO_OUT => self.gpio_out,
			port::CORE_ID => CORE_ID_VALUE,
			port::COMPAT_FLAGS => self.compat_flags,
			port::STICKY_STATUS => self.sticky_status,
			_ => return Err(Fault::new(FaultCause::BadCspPort, port)),
		})
	}

	/// Writes a port. Read-only ports fault rather than silently ignoring the
	/// write, so a program bug surfaces immediately.
	pub fn write(&mut self, port: u32, value: u32) -> Result<(), Fault> {
		match port {
			port::UART_DATA => self.uart.put(value as u8),
			port::UART_STATUS => self.uart_divisor = value,
			port::TRAP_VECTOR => self.trap_vector = value,
			port::TRAP_ENABLE => self.trap_enable = value,
			port::GPIO_OUT => self.gpio_out = value,
			port::COMPAT_FLAGS => self.compat_flags = value,
			port::CYCLE_COUNT_LO
			| port::CYCLE_COUNT_HI
			| port::FAULT_CAUSE
			| port::FAULT_ADDR
			| port::FAULT_INFO
			| port::CORE_ID
			| port::STICKY_STATUS => {
				return Err(Fault::new(FaultCause::BadCspPort, port));
			}
			_ => return Err(Fault::new(FaultCause::BadCspPort, port)),
		}
		Ok(())
	}

	pub fn note_removed_ordering_prefix(&mut self) {
		self.sticky_status |= STICKY_REMOVED_ORDERING_PREFIX;
	}

	pub fn traps_on_double_prime(&self) -> bool {
		self.compat_flags & COMPAT_TRAP_ON_DOUBLE_PRIME != 0
	}
}
