//! The host-control wire protocol, defined once.
//!
//! A K2G board and a host talk over one 8N1 serial link. Two very different
//! kinds of traffic share it: the program's own console output, and the
//! commands that load, start, stop and inspect that program. **Every byte on
//! the wire is inside a frame**, so the two cannot be confused and a program may
//! print or read any byte value it likes -- including the framing bytes.
//!
//! The cost of that decision is that a plain terminal no longer shows the
//! console; `kctl console` does. It was taken because the alternative -- raw
//! console bytes with framed commands interleaved -- makes a program that emits
//! the magic sequence indistinguishable from a command, and "the machine is
//! wedged" is a bad thing to have to diagnose over a serial cable.
//!
//! ---- why this module exists rather than two implementations ----
//!
//! The frame codec has to exist in Rust (the `kctl` host tool) and in
//! SystemVerilog (`rtl/k2g_mon.sv`). That is exactly the shape of the drift the
//! superseded `decoder.sv` suffered from, and the answer here is the same one
//! the opcode map uses: the constants are declared once, in this file, and
//! `gen_defs` renders them into `rtl/k2g_host_pkg.sv`. The type codes cannot
//! disagree because there is only one place they are written down.
//!
//! The decoder below is a byte-at-a-time state machine rather than the more
//! natural buffer-and-slice, so that it is a readable reference for the RTL
//! that has no choice but to work that way.

use core::fmt::Write as _;

/// Frame delimiter. `ESC` `K` -- two bytes rather than one, because a single
/// byte resynchronizes far too eagerly on a noisy line.
pub const MAGIC: [u8; 2] = [0x1B, 0x4B];

/// Bumped whenever the meaning of a type code or payload layout changes.
/// `kctl` refuses to talk to a board reporting a different one.
pub const PROTO_VERSION: u16 = 1;

/// Largest payload in either direction.
///
/// This bounds the monitor's frame counter and, more importantly, bounds the
/// damage a corrupted length field can do: a `WRITE` streams into memory as it
/// arrives (see `rtl/k2g_mon.sv`), so a bad frame can scribble at most this
/// many bytes before its CRC fails and the host is told to re-send.
///
/// 128 rather than 256, and the reason is area: it puts the length in eight
/// bits rather than nine, which narrows four counters and their comparators in
/// a design that failed to place with seventy-five LUTs to spare. The link is
/// unaffected -- 11.5 KB/s means a 128-byte frame is 12 ms whatever the header
/// costs.
pub const MAX_PAYLOAD: usize = 128;

/// magic(2) + type(1) + len(2)
pub const HEADER_LEN: usize = 5;
/// crc(2)
pub const TRAILER_LEN: usize = 2;
/// Bytes on the wire beyond the payload itself.
pub const FRAME_OVERHEAD: usize = HEADER_LEN + TRAILER_LEN;

/// Path the generated SystemVerilog package is written to, relative to the
/// repository root.
pub const SV_OUTPUT_PATH: &str = "rtl/k2g_host_pkg.sv";

/// Path of the hand-written protocol document. Its coverage of the frame types
/// is checked by a test rather than generated, because the prose is the useful
/// part and generating it would produce a table nobody reads.
pub const DOC_PATH: &str = "docs/host-control.md";

// ---- frame types ----------------------------------------------------------

/// Declares the enum and a reflected variant table from the same tokens, so the
/// generated SystemVerilog and the Rust definition cannot disagree. Same device
/// as `insns::isa_enum!`, kept separate because the payloads want documenting
/// alongside the codes.
// `literal` rather than `expr` for the codes: an `expr` fragment cannot appear
// in pattern position, and `from_u8` matches on them.
macro_rules! frame_types {
	($( $(#[$m:meta])* $name:ident = $val:literal, $payload:literal ; )*) => {
		/// What a frame is. Host-to-board codes are `0x0x`; board-to-host codes
		/// have the top bit set, so a capture is readable by direction alone.
		///
		/// The variant names are the **wire names**: `stringify!` renders them
		/// into `rtl/k2g_host_pkg.sv` as `HF_<name>`, and a test requires each
		/// to appear in `docs/host-control.md`. Camel-casing them here would
		/// mean three spellings of one thing, so the lint is off.
		#[allow(non_camel_case_types)]
		#[derive(Copy, Clone, Debug, PartialEq, Eq)]
		#[repr(u8)]
		pub enum FrameType {
			$( $(#[$m])* $name = $val, )*
		}

		impl FrameType {
			/// `(name, code, payload description)` for every variant.
			pub const VARIANTS: &'static [(&'static str, u8, &'static str)] = &[
				$( (stringify!($name), $val, $payload), )*
			];

			/// `None` for a code this build does not know, which is a `NAK`
			/// rather than a parse failure -- the frame was well formed.
			pub fn from_u8(v: u8) -> Option<Self> {
				match v {
					$( $val => Some(FrameType::$name), )*
					_ => None,
				}
			}

			pub fn name(self) -> &'static str {
				match self {
					$( FrameType::$name => stringify!($name), )*
				}
			}
		}
	};
}

frame_types! {
	/// Host asks what it is talking to. Answered even by a build with no CPU.
	PING       = 0x01, "none";
	/// Host asks what the machine is doing.
	STATUS     = 0x02, "none";
	/// Stop the core at a code-point boundary, make memory coherent, take the
	/// bus. Idempotent.
	PAUSE      = 0x03, "none";
	/// Give the bus back and let the core run on from where it stopped.
	RESUME     = 0x04, "none";
	/// Reset the core: `pc` to 0, caches invalid. Requires paused. Does **not**
	/// re-run the boot copier, so a host-loaded program survives it.
	RESET      = 0x05, "none";
	/// Write bytes into memory. Requires paused.
	WRITE      = 0x06, "addr u32 LE, then the bytes";
	/// Read bytes out of memory. Requires paused.
	READ       = 0x07, "addr u32 LE, count u16 LE";
	/// Bytes for the program's UART receive port.
	CONSOLE_IN = 0x08, "the bytes";

	/// Answer to `PING`.
	IDENT       = 0x81, "version u16, max_payload u16, core_id u32, mem_bytes u32, caps u32";
	/// Answer to `STATUS`, `PAUSE`, `RESUME` and `RESET`.
	STATE       = 0x82, "flags u8, fault_cause u8, rsvd u16, fault_addr u32, fault_info u32, cycles u64";
	/// Answer to `WRITE` and `CONSOLE_IN`: how many bytes were taken.
	ACK         = 0x83, "count u16 LE";
	/// Answer to `READ`.
	DATA        = 0x84, "the bytes";
	/// A command was not carried out.
	NAK         = 0x8E, "reason u8";
	/// Program console output. Sent unprompted, at any time, including between
	/// a command and its answer.
	CONSOLE_OUT = 0x8F, "the bytes";
}

macro_rules! nak_reasons {
	($( $(#[$m:meta])* $name:ident = $val:literal ; )*) => {
		/// Why a command was refused.
		#[derive(Copy, Clone, Debug, PartialEq, Eq)]
		#[repr(u8)]
		pub enum NakReason {
			$( $(#[$m])* $name = $val, )*
		}

		impl NakReason {
			pub const VARIANTS: &'static [(&'static str, u8)] = &[
				$( (stringify!($name), $val), )*
			];

			pub fn from_u8(v: u8) -> Option<Self> {
				match v {
					$( $val => Some(NakReason::$name), )*
					_ => None,
				}
			}

			pub fn name(self) -> &'static str {
				match self {
					$( NakReason::$name => stringify!($name), )*
				}
			}
		}
	};
}

nak_reasons! {
	/// The frame's CRC did not match. Never sent by the monitor -- a frame that
	/// fails CRC is discarded silently, because answering it would mean trusting
	/// its type field. `kctl` uses this code for its own bookkeeping.
	CRC     = 0x01;
	/// A frame type this build does not implement.
	TYPE    = 0x02;
	/// `len` outside what the command allows.
	LENGTH  = 0x03;
	/// The address, or address plus count, falls outside memory.
	ADDRESS = 0x04;
	/// The command needs the core paused and it is running.
	STATE   = 0x05;
	/// The monitor is still finishing the previous command.
	BUSY    = 0x06;
}

// ---- payload layouts ------------------------------------------------------

pub const IDENT_LEN: usize = 16;
pub const STATE_LEN: usize = 20;
pub const ACK_LEN: usize = 2;
pub const NAK_LEN: usize = 1;
pub const READ_REQ_LEN: usize = 6;
/// `WRITE`'s address prefix; the rest of the payload is data.
pub const WRITE_HDR_LEN: usize = 4;
/// Most data bytes one `WRITE` frame can carry.
pub const MAX_WRITE_DATA: usize = MAX_PAYLOAD - WRITE_HDR_LEN;
/// Most bytes one `READ` can ask for.
pub const MAX_READ_DATA: usize = MAX_PAYLOAD;

/// Bits of `STATE`'s flags byte.
pub const FLAG_PAUSED: u8 = 1 << 0;
pub const FLAG_HALTED: u8 = 1 << 1;
pub const FLAG_FAULTED: u8 = 1 << 2;
pub const FLAG_BUS_OWNED: u8 = 1 << 3;

/// Bits of `IDENT`'s capability word. The `mon` bring-up stage has no CPU in it
/// at all, so it reports memory access and console but not run control, and
/// `kctl` can say "this build cannot do that" instead of timing out.
pub const CAP_MEMORY: u32 = 1 << 0;
pub const CAP_RUN_CONTROL: u32 = 1 << 1;
/// Console **output**: the board sends `CONSOLE_OUT`.
pub const CAP_CONSOLE: u32 = 1 << 2;
/// Console **input**: the board accepts `CONSOLE_IN`.
///
/// Separate from [`CAP_CONSOLE`] because the two are separately affordable. The
/// `soc` build reports output but not input: the receive buffer and its accept
/// logic are 33 logic cells, measured, and that build places at 99% of the
/// part. Nothing in `emu/programs/` reads the UART, so no program notices, but
/// a host that wants to type at one has to know, and timing out is a poor way
/// to find out.
pub const CAP_CONSOLE_IN: u32 = 1 << 3;

/// `k2g_csp.sv`'s `CORE_ID_VALUE`, repeated here so `kctl` can recognize the
/// machine without reading RTL. A mismatch means the link is talking to
/// something else.
pub const CORE_ID: u32 = 0x4B32_4731;

// ---- CRC ------------------------------------------------------------------

/// CRC-16/CCITT-FALSE: polynomial `0x1021`, initial value `0xFFFF`, no
/// reflection, no final XOR.
///
/// Chosen because the bit-at-a-time form below is what the RTL implements
/// directly -- sixteen flip-flops and a handful of XORs, eight cycles per byte
/// against the 87 microseconds a byte takes on the wire.
pub const CRC_INIT: u16 = 0xFFFF;
pub const CRC_POLY: u16 = 0x1021;

pub fn crc16_update(crc: u16, byte: u8) -> u16 {
	let mut c = crc ^ ((byte as u16) << 8);
	for _ in 0..8 {
		c = if c & 0x8000 != 0 { (c << 1) ^ CRC_POLY } else { c << 1 };
	}
	c
}

/// CRC over `type | len_lo | len_hi | payload` -- the magic is not covered,
/// because it is a delimiter rather than data and a receiver hunting for it has
/// not started accumulating yet.
pub fn crc16(bytes: &[u8]) -> u16 {
	bytes.iter().fold(CRC_INIT, |c, &b| crc16_update(c, b))
}

// ---- encoding -------------------------------------------------------------

#[derive(Debug, PartialEq, Eq)]
pub enum ProtoError {
	/// Payload longer than [`MAX_PAYLOAD`].
	TooLong(usize),
	/// A reply's payload was not the length its type requires.
	BadPayload {
		ty: &'static str,
		got: usize,
		want: usize,
	},
}

impl core::fmt::Display for ProtoError {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			ProtoError::TooLong(n) => {
				write!(f, "payload of {n} bytes exceeds MAX_PAYLOAD ({MAX_PAYLOAD})")
			}
			ProtoError::BadPayload { ty, got, want } => {
				write!(f, "{ty} payload is {got} bytes, expected {want}")
			}
		}
	}
}

/// Renders one frame.
pub fn encode(ty: FrameType, payload: &[u8]) -> Result<Vec<u8>, ProtoError> {
	if payload.len() > MAX_PAYLOAD {
		return Err(ProtoError::TooLong(payload.len()));
	}

	let mut body = Vec::with_capacity(3 + payload.len());
	body.push(ty as u8);
	body.push((payload.len() & 0xFF) as u8);
	body.push((payload.len() >> 8) as u8);
	body.extend_from_slice(payload);

	let crc = crc16(&body);

	let mut out = Vec::with_capacity(FRAME_OVERHEAD + payload.len());
	out.extend_from_slice(&MAGIC);
	out.extend_from_slice(&body);
	out.push((crc & 0xFF) as u8);
	out.push((crc >> 8) as u8);
	Ok(out)
}

pub fn encode_write(addr: u32, data: &[u8]) -> Result<Vec<u8>, ProtoError> {
	let mut p = Vec::with_capacity(WRITE_HDR_LEN + data.len());
	p.extend_from_slice(&addr.to_le_bytes());
	p.extend_from_slice(data);
	encode(FrameType::WRITE, &p)
}

pub fn encode_read(addr: u32, count: u16) -> Result<Vec<u8>, ProtoError> {
	let mut p = Vec::with_capacity(READ_REQ_LEN);
	p.extend_from_slice(&addr.to_le_bytes());
	p.extend_from_slice(&count.to_le_bytes());
	encode(FrameType::READ, &p)
}

// ---- decoding -------------------------------------------------------------

/// A frame that arrived intact.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
	/// `None` when the code is well-formed but unknown to this build.
	pub ty: Option<FrameType>,
	pub raw_ty: u8,
	pub payload: Vec<u8>,
}

/// What one byte did to the decoder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
	/// Consumed; nothing to report.
	More,
	/// A complete, CRC-checked frame.
	Frame(Frame),
	/// A frame arrived with a bad CRC and was discarded. The decoder is hunting
	/// for the magic again.
	BadCrc,
	/// A length field above [`MAX_PAYLOAD`]; the frame was abandoned without
	/// consuming its payload, which is what stops a corrupt header from
	/// swallowing the frames behind it.
	BadLength(usize),
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
enum St {
	Magic0,
	Magic1,
	Ty,
	LenLo,
	LenHi,
	Payload,
	CrcLo,
	CrcHi,
}

/// Byte-at-a-time frame decoder.
///
/// Deliberately written the way the RTL has to be written: one byte in, a small
/// state machine, no lookahead and no buffering of the stream. Resynchronizing
/// is always "go back to hunting for the magic" -- there is no attempt to
/// recover the tail of a damaged frame, because a length field that cannot be
/// trusted makes every such attempt a guess.
pub struct Decoder {
	st: St,
	raw_ty: u8,
	len: usize,
	got: usize,
	payload: Vec<u8>,
	crc: u16,
	crc_rx: u16,
	/// Counted rather than reported, for `kctl --verbose` and for tests that
	/// want to prove a bad frame was actually rejected rather than never seen.
	pub bad_crc: u64,
	pub bad_length: u64,
}

impl Default for Decoder {
	fn default() -> Self {
		Self::new()
	}
}

impl Decoder {
	pub fn new() -> Self {
		Decoder {
			st: St::Magic0,
			raw_ty: 0,
			len: 0,
			got: 0,
			payload: Vec::new(),
			crc: CRC_INIT,
			crc_rx: 0,
			bad_crc: 0,
			bad_length: 0,
		}
	}

	fn restart(&mut self) {
		self.st = St::Magic0;
		self.payload.clear();
	}

	pub fn push(&mut self, b: u8) -> Step {
		match self.st {
			St::Magic0 => {
				if b == MAGIC[0] {
					self.st = St::Magic1;
				}
				Step::More
			}

			St::Magic1 => {
				if b == MAGIC[1] {
					self.st = St::Ty;
					self.crc = CRC_INIT;
					self.payload.clear();
				} else if b == MAGIC[0] {
					// `1B 1B 4B` is a valid start. Staying here rather than
					// restarting is the difference between resyncing on the
					// next frame and dropping it.
					self.st = St::Magic1;
				} else {
					self.st = St::Magic0;
				}
				Step::More
			}

			St::Ty => {
				self.raw_ty = b;
				self.crc = crc16_update(self.crc, b);
				self.st = St::LenLo;
				Step::More
			}

			St::LenLo => {
				self.len = b as usize;
				self.crc = crc16_update(self.crc, b);
				self.st = St::LenHi;
				Step::More
			}

			St::LenHi => {
				self.len |= (b as usize) << 8;
				self.crc = crc16_update(self.crc, b);
				if self.len > MAX_PAYLOAD {
					self.bad_length += 1;
					let n = self.len;
					self.restart();
					return Step::BadLength(n);
				}
				self.got = 0;
				self.st = if self.len == 0 { St::CrcLo } else { St::Payload };
				Step::More
			}

			St::Payload => {
				self.payload.push(b);
				self.crc = crc16_update(self.crc, b);
				self.got += 1;
				if self.got == self.len {
					self.st = St::CrcLo;
				}
				Step::More
			}

			St::CrcLo => {
				self.crc_rx = b as u16;
				self.st = St::CrcHi;
				Step::More
			}

			St::CrcHi => {
				self.crc_rx |= (b as u16) << 8;
				let ok = self.crc_rx == self.crc;
				let payload = core::mem::take(&mut self.payload);
				self.restart();
				if ok {
					Step::Frame(Frame {
						ty: FrameType::from_u8(self.raw_ty),
						raw_ty: self.raw_ty,
						payload,
					})
				} else {
					self.bad_crc += 1;
					Step::BadCrc
				}
			}
		}
	}
}

// ---- typed replies --------------------------------------------------------

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct Ident {
	pub version: u16,
	pub max_payload: u16,
	pub core_id: u32,
	pub mem_bytes: u32,
	pub caps: u32,
}

impl Ident {
	pub fn to_payload(self) -> Vec<u8> {
		let mut p = Vec::with_capacity(IDENT_LEN);
		p.extend_from_slice(&self.version.to_le_bytes());
		p.extend_from_slice(&self.max_payload.to_le_bytes());
		p.extend_from_slice(&self.core_id.to_le_bytes());
		p.extend_from_slice(&self.mem_bytes.to_le_bytes());
		p.extend_from_slice(&self.caps.to_le_bytes());
		p
	}

	pub fn parse(p: &[u8]) -> Result<Self, ProtoError> {
		if p.len() != IDENT_LEN {
			return Err(ProtoError::BadPayload {
				ty: "IDENT",
				got: p.len(),
				want: IDENT_LEN,
			});
		}
		Ok(Ident {
			version: u16::from_le_bytes([p[0], p[1]]),
			max_payload: u16::from_le_bytes([p[2], p[3]]),
			core_id: u32::from_le_bytes([p[4], p[5], p[6], p[7]]),
			mem_bytes: u32::from_le_bytes([p[8], p[9], p[10], p[11]]),
			caps: u32::from_le_bytes([p[12], p[13], p[14], p[15]]),
		})
	}
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct State {
	pub flags: u8,
	pub fault_cause: u8,
	pub fault_addr: u32,
	pub fault_info: u32,
	pub cycles: u64,
}

impl State {
	pub fn to_payload(self) -> Vec<u8> {
		let mut p = Vec::with_capacity(STATE_LEN);
		p.push(self.flags);
		p.push(self.fault_cause);
		p.extend_from_slice(&[0, 0]); // reserved
		p.extend_from_slice(&self.fault_addr.to_le_bytes());
		p.extend_from_slice(&self.fault_info.to_le_bytes());
		p.extend_from_slice(&self.cycles.to_le_bytes());
		p
	}

	pub fn parse(p: &[u8]) -> Result<Self, ProtoError> {
		if p.len() != STATE_LEN {
			return Err(ProtoError::BadPayload {
				ty: "STATE",
				got: p.len(),
				want: STATE_LEN,
			});
		}
		Ok(State {
			flags: p[0],
			fault_cause: p[1],
			fault_addr: u32::from_le_bytes([p[4], p[5], p[6], p[7]]),
			fault_info: u32::from_le_bytes([p[8], p[9], p[10], p[11]]),
			cycles: u64::from_le_bytes([
				p[12], p[13], p[14], p[15], p[16], p[17], p[18], p[19],
			]),
		})
	}

	pub fn paused(self) -> bool {
		self.flags & FLAG_PAUSED != 0
	}
	pub fn halted(self) -> bool {
		self.flags & FLAG_HALTED != 0
	}
	pub fn faulted(self) -> bool {
		self.flags & FLAG_FAULTED != 0
	}
}

pub fn parse_ack(p: &[u8]) -> Result<u16, ProtoError> {
	if p.len() != ACK_LEN {
		return Err(ProtoError::BadPayload {
			ty: "ACK",
			got: p.len(),
			want: ACK_LEN,
		});
	}
	Ok(u16::from_le_bytes([p[0], p[1]]))
}

pub fn parse_nak(p: &[u8]) -> Result<Option<NakReason>, ProtoError> {
	if p.len() != NAK_LEN {
		return Err(ProtoError::BadPayload {
			ty: "NAK",
			got: p.len(),
			want: NAK_LEN,
		});
	}
	Ok(NakReason::from_u8(p[0]))
}

// ---- generated SystemVerilog ----------------------------------------------

/// Renders `rtl/k2g_host_pkg.sv`.
///
/// Only the constants cross into the RTL. The frame *layout* is expressed in
/// `k2g_mon.sv`'s state machine, which is the thing the testbench checks against
/// frames this module built -- so the two agree by test rather than by
/// generation, which is the right split: generating a state machine would be
/// worse than writing one.
pub fn emit_host_pkg_sv() -> String {
	let mut out = String::new();

	let _ = writeln!(out, "// -------------------------------------------------------------------------");
	let _ = writeln!(out, "// GENERATED FILE -- DO NOT EDIT BY HAND.");
	let _ = writeln!(out, "//");
	let _ = writeln!(out, "// Produced by emu/src/hostproto.rs, which is the single definition of the");
	let _ = writeln!(out, "// host-control wire protocol. The `kctl` host tool and rtl/k2g_mon.sv both");
	let _ = writeln!(out, "// take their type codes from it, so they cannot disagree about what a");
	let _ = writeln!(out, "// frame means.");
	let _ = writeln!(out, "//");
	let _ = writeln!(out, "// Regenerate:  cd emu && cargo run --bin gen_defs");
	let _ = writeln!(out, "// Verify:      cd emu && cargo test  (golden-file test fails on drift)");
	let _ = writeln!(out, "// -------------------------------------------------------------------------");
	let _ = writeln!(out);
	let _ = writeln!(out, "`ifndef K2G_HOST_PKG_SV");
	let _ = writeln!(out, "`define K2G_HOST_PKG_SV");
	let _ = writeln!(out);
	let _ = writeln!(out, "package k2g_host_pkg;");
	let _ = writeln!(out);

	let _ = writeln!(out, "  // ---- framing -----------------------------------------------------------");
	let _ = writeln!(out, "  // magic(2) | type(1) | len(2, LE) | payload | crc16(2, LE)");
	let _ = writeln!(out, "  // The CRC covers type, len and payload -- not the magic, which is a");
	let _ = writeln!(out, "  // delimiter rather than data.");
	let _ = writeln!(out, "  localparam logic [7:0] MAGIC0 = 8'h{:02X};", MAGIC[0]);
	let _ = writeln!(out, "  localparam logic [7:0] MAGIC1 = 8'h{:02X};", MAGIC[1]);
	let _ = writeln!(out, "  localparam int PROTO_VERSION = {PROTO_VERSION};");
	let _ = writeln!(out, "  localparam int MAX_PAYLOAD   = {MAX_PAYLOAD};");
	let _ = writeln!(out, "  localparam int LEN_W         = {};", len_bits(MAX_PAYLOAD));
	let _ = writeln!(out);
	let _ = writeln!(out, "  localparam logic [15:0] CRC_INIT = 16'h{CRC_INIT:04X};");
	let _ = writeln!(out, "  localparam logic [15:0] CRC_POLY = 16'h{CRC_POLY:04X};");
	let _ = writeln!(out);

	let _ = writeln!(out, "  // ---- frame types -------------------------------------------------------");
	let _ = writeln!(out, "  // Host-to-board codes are 0x0x; board-to-host codes have the top bit set.");
	let _ = writeln!(out, "  typedef enum logic [7:0] {{");
	let fw = FrameType::VARIANTS.iter().map(|(n, _, _)| n.len()).max().unwrap_or(0);
	for (i, (name, code, payload)) in FrameType::VARIANTS.iter().enumerate() {
		let last = i + 1 == FrameType::VARIANTS.len();
		let _ = writeln!(
			out,
			"    HF_{name:<fw$} = 8'h{code:02X}{comma}  // {payload}",
			name = name,
			fw = fw,
			code = code,
			comma = if last { " " } else { "," },
			payload = payload,
		);
	}
	let _ = writeln!(out, "  }} host_frame_e;");
	let _ = writeln!(out);

	let _ = writeln!(out, "  // ---- NAK reasons -------------------------------------------------------");
	let _ = writeln!(out, "  typedef enum logic [7:0] {{");
	let nw = NakReason::VARIANTS.iter().map(|(n, _)| n.len()).max().unwrap_or(0);
	for (i, (name, code)) in NakReason::VARIANTS.iter().enumerate() {
		let last = i + 1 == NakReason::VARIANTS.len();
		let _ = writeln!(
			out,
			"    NAK_{name:<nw$} = 8'h{code:02X}{comma}",
			name = name,
			nw = nw,
			code = code,
			comma = if last { "" } else { "," },
		);
	}
	let _ = writeln!(out, "  }} nak_reason_e;");
	let _ = writeln!(out);

	let _ = writeln!(out, "  // ---- payload layouts ---------------------------------------------------");
	let _ = writeln!(out, "  localparam int IDENT_LEN     = {IDENT_LEN};");
	let _ = writeln!(out, "  localparam int STATE_LEN     = {STATE_LEN};");
	let _ = writeln!(out, "  localparam int ACK_LEN       = {ACK_LEN};");
	let _ = writeln!(out, "  localparam int NAK_LEN       = {NAK_LEN};");
	let _ = writeln!(out, "  localparam int READ_REQ_LEN  = {READ_REQ_LEN};");
	let _ = writeln!(out, "  localparam int WRITE_HDR_LEN = {WRITE_HDR_LEN};");
	let _ = writeln!(out);
	let _ = writeln!(out, "  localparam logic [7:0] FLAG_PAUSED    = 8'h{FLAG_PAUSED:02X};");
	let _ = writeln!(out, "  localparam logic [7:0] FLAG_HALTED    = 8'h{FLAG_HALTED:02X};");
	let _ = writeln!(out, "  localparam logic [7:0] FLAG_FAULTED   = 8'h{FLAG_FAULTED:02X};");
	let _ = writeln!(out, "  localparam logic [7:0] FLAG_BUS_OWNED = 8'h{FLAG_BUS_OWNED:02X};");
	let _ = writeln!(out);
	let _ = writeln!(out, "  localparam logic [31:0] CAP_MEMORY      = 32'h{CAP_MEMORY:08X};");
	let _ = writeln!(out, "  localparam logic [31:0] CAP_RUN_CONTROL = 32'h{CAP_RUN_CONTROL:08X};");
	let _ = writeln!(out, "  localparam logic [31:0] CAP_CONSOLE     = 32'h{CAP_CONSOLE:08X};");
	let _ = writeln!(out, "  localparam logic [31:0] CAP_CONSOLE_IN  = 32'h{CAP_CONSOLE_IN:08X};");
	let _ = writeln!(out);
	let _ = writeln!(out, "  localparam logic [31:0] CORE_ID = 32'h{CORE_ID:08X};");
	let _ = writeln!(out);
	let _ = writeln!(out, "endpackage");
	let _ = writeln!(out);
	let _ = writeln!(out, "`endif  // K2G_HOST_PKG_SV");

	out
}

/// Bits needed to hold a payload length of 0..=`max`.
///
/// A free function rather than `$clog2` in the generated source: an inline
/// `$clog2` in a part-select is one of the constructs GowinSynthesis rejects
/// with an empty log (docs/bring-up.md).
fn len_bits(max: usize) -> u32 {
	let mut n = 1;
	while (1usize << n) <= max {
		n += 1;
	}
	n
}

#[cfg(test)]
mod tests {
	use super::*;

	/// Published check values for CRC-16/CCITT-FALSE. Without these the codec
	/// is only self-consistent, which would let both sides of the link agree on
	/// the same wrong thing.
	#[test]
	fn crc_matches_published_vectors() {
		assert_eq!(crc16(b"123456789"), 0x29B1);
		assert_eq!(crc16(b""), 0xFFFF);
		assert_eq!(crc16(&[0x00]), 0xE1F0);
		assert_eq!(crc16(&[0xFF]), 0xFF00);
	}

	#[test]
	fn frame_round_trips() {
		let mut d = Decoder::new();
		let wire = encode(FrameType::DATA, &[1, 2, 3, 4]).unwrap();
		assert_eq!(wire.len(), FRAME_OVERHEAD + 4);

		let mut got = None;
		for b in wire {
			if let Step::Frame(f) = d.push(b) {
				got = Some(f);
			}
		}
		let f = got.expect("frame should decode");
		assert_eq!(f.ty, Some(FrameType::DATA));
		assert_eq!(f.payload, vec![1, 2, 3, 4]);
	}

	#[test]
	fn empty_payload_round_trips() {
		let mut d = Decoder::new();
		let mut got = None;
		for b in encode(FrameType::PING, &[]).unwrap() {
			if let Step::Frame(f) = d.push(b) {
				got = Some(f);
			}
		}
		assert_eq!(got.unwrap().ty, Some(FrameType::PING));
	}

	#[test]
	fn max_payload_round_trips() {
		let payload: Vec<u8> = (0..MAX_PAYLOAD).map(|i| i as u8).collect();
		let mut d = Decoder::new();
		let mut got = None;
		for b in encode(FrameType::CONSOLE_OUT, &payload).unwrap() {
			if let Step::Frame(f) = d.push(b) {
				got = Some(f);
			}
		}
		assert_eq!(got.unwrap().payload, payload);
	}

	#[test]
	fn oversize_payload_is_refused_at_the_encoder() {
		let too_big = vec![0u8; MAX_PAYLOAD + 1];
		assert_eq!(
			encode(FrameType::WRITE, &too_big),
			Err(ProtoError::TooLong(MAX_PAYLOAD + 1))
		);
	}

	#[test]
	fn a_corrupted_byte_fails_the_crc() {
		let mut wire = encode(FrameType::WRITE, &[9, 9, 9, 9, 42]).unwrap();
		let last = wire.len() - 3;
		wire[last] ^= 0x01;

		let mut d = Decoder::new();
		let mut steps = Vec::new();
		for b in wire {
			steps.push(d.push(b));
		}
		assert!(steps.contains(&Step::BadCrc), "corruption should be caught");
		assert!(!steps.iter().any(|s| matches!(s, Step::Frame(_))));
		assert_eq!(d.bad_crc, 1);
	}

	/// The frame after a damaged one must still arrive. This is the property
	/// that keeps a noisy link usable rather than requiring a power cycle.
	#[test]
	fn decoder_resyncs_after_a_bad_frame() {
		let mut wire = encode(FrameType::DATA, &[0xAA; 8]).unwrap();
		wire[6] ^= 0xFF; // corrupt a payload byte
		wire.extend(encode(FrameType::ACK, &[7, 0]).unwrap());

		let mut d = Decoder::new();
		let mut good = Vec::new();
		for b in wire {
			if let Step::Frame(f) = d.push(b) {
				good.push(f);
			}
		}
		assert_eq!(good.len(), 1);
		assert_eq!(good[0].ty, Some(FrameType::ACK));
		assert_eq!(parse_ack(&good[0].payload).unwrap(), 7);
	}

	/// Garbage ahead of a frame, including near-misses of the magic, must not
	/// eat it.
	#[test]
	fn leading_garbage_is_skipped() {
		let mut wire = vec![0x00, 0xFF, 0x1B, 0x00, 0x1B, 0x1B];
		wire.extend(encode(FrameType::PING, &[]).unwrap());

		let mut d = Decoder::new();
		let mut n = 0;
		for b in wire {
			if let Step::Frame(_) = d.push(b) {
				n += 1;
			}
		}
		assert_eq!(n, 1, "a doubled magic byte must not swallow the frame");
	}

	/// A corrupt length is caught before its payload is consumed, so the frames
	/// behind it are not swallowed.
	#[test]
	fn oversize_length_is_rejected_without_consuming_a_payload() {
		let mut wire = vec![MAGIC[0], MAGIC[1], FrameType::WRITE as u8, 0x00, 0xFF];
		wire.extend(encode(FrameType::PING, &[]).unwrap());

		let mut d = Decoder::new();
		let mut frames = 0;
		let mut rejected = false;
		for b in wire {
			match d.push(b) {
				Step::Frame(_) => frames += 1,
				Step::BadLength(n) => {
					rejected = true;
					assert_eq!(n, 0xFF00);
				}
				_ => {}
			}
		}
		assert!(rejected);
		assert_eq!(frames, 1, "the frame behind the bad header must survive");
		assert_eq!(d.bad_length, 1);
	}

	#[test]
	fn unknown_type_still_decodes_as_a_frame() {
		let mut d = Decoder::new();
		let mut body = vec![0x7Fu8, 0, 0];
		let crc = crc16(&body);
		body.push((crc & 0xFF) as u8);
		body.push((crc >> 8) as u8);

		let mut wire = MAGIC.to_vec();
		wire.extend(body);

		let mut got = None;
		for b in wire {
			if let Step::Frame(f) = d.push(b) {
				got = Some(f);
			}
		}
		let f = got.unwrap();
		assert_eq!(f.ty, None);
		assert_eq!(f.raw_ty, 0x7F);
	}

	#[test]
	fn ident_and_state_round_trip() {
		let id = Ident {
			version: PROTO_VERSION,
			max_payload: MAX_PAYLOAD as u16,
			core_id: CORE_ID,
			mem_bytes: 8 * 1024 * 1024,
			caps: CAP_MEMORY | CAP_RUN_CONTROL | CAP_CONSOLE,
		};
		assert_eq!(id.to_payload().len(), IDENT_LEN);
		assert_eq!(Ident::parse(&id.to_payload()).unwrap(), id);

		let st = State {
			flags: FLAG_PAUSED | FLAG_FAULTED,
			fault_cause: 9,
			fault_addr: 0xDEAD_BEEF,
			fault_info: 0x1234_5678,
			cycles: 0x0102_0304_0506_0708,
		};
		assert_eq!(st.to_payload().len(), STATE_LEN);
		assert_eq!(State::parse(&st.to_payload()).unwrap(), st);
		assert!(st.paused() && st.faulted() && !st.halted());
	}

	#[test]
	fn write_and_read_requests_have_the_documented_shape() {
		let w = encode_write(0x0000_1234, &[0xAB, 0xCD]).unwrap();
		assert_eq!(w[2], FrameType::WRITE as u8);
		assert_eq!(&w[5..9], &[0x34, 0x12, 0x00, 0x00]);
		assert_eq!(&w[9..11], &[0xAB, 0xCD]);

		let r = encode_read(0x0080_0000, 64).unwrap();
		assert_eq!(u16::from_le_bytes([r[3], r[4]]), READ_REQ_LEN as u16);
		assert_eq!(&r[9..11], &[64, 0]);
	}

	#[test]
	fn type_codes_are_unique() {
		for (i, (na, va, _)) in FrameType::VARIANTS.iter().enumerate() {
			for (nb, vb, _) in &FrameType::VARIANTS[i + 1..] {
				assert_ne!(va, vb, "{na} and {nb} share code {va:#04x}");
			}
		}
		for (i, (na, va)) in NakReason::VARIANTS.iter().enumerate() {
			for (nb, vb) in &NakReason::VARIANTS[i + 1..] {
				assert_ne!(va, vb, "{na} and {nb} share reason {va:#04x}");
			}
		}
	}

	/// The direction convention is load-bearing: `kctl` and a packet capture
	/// both read it, and the monitor uses it to reject a reply code arriving as
	/// a command.
	#[test]
	fn direction_is_encoded_in_the_top_bit() {
		for (name, code, _) in FrameType::VARIANTS {
			let reply = matches!(
				*name,
				"IDENT" | "STATE" | "ACK" | "DATA" | "NAK" | "CONSOLE_OUT"
			);
			assert_eq!(*code & 0x80 != 0, reply, "{name} is on the wrong side");
		}
	}

	#[test]
	fn len_bits_covers_max_payload() {
		assert_eq!(len_bits(256), 9);
		assert_eq!(len_bits(255), 8);
		assert_eq!(len_bits(64), 7);
	}
}
