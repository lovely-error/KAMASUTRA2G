//! `kctl` — drives a K2G board over the serial link.
//!
//! Until this existed, putting a program on the board meant regenerating the
//! boot ROM and rebuilding the bitstream: `PROG=hello bash rtl/board/build.sh
//! soc`, several minutes, one program per synthesis. And a program that
//! misbehaved could only be diagnosed from six LEDs, because a halted core
//! cannot execute the CSP read that would report its own fault cause.
//!
//! ```text
//! kctl --port COM3 ping
//! kctl --port COM3 run hello.bin
//! kctl --port COM3 peek 0 64
//! kctl --port COM3 console
//! ```
//!
//! The port may also come from `K2G_PORT`, which is what makes the commands
//! above short enough to type repeatedly.
//!
//! Every byte on the wire is framed (see `emu/src/hostproto.rs`), so console
//! output arrives interleaved with command replies and is printed as it comes
//! rather than being an error. That is why every command here goes through
//! [`Link::request`] instead of reading a fixed number of bytes.

use std::collections::VecDeque;
use std::io::Write;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use emu::hostproto as hp;
use emu::hostproto::{FrameType, Step};
use emu::serial::Serial;

const DEFAULT_BAUD: u32 = 115_200;
/// One read syscall's patience. Several of these make up a command timeout.
const READ_SLICE_MS: u32 = 200;
/// How long to wait for a reply before giving up. A `PAUSE` has to flush a
/// write-back data cache -- 64 lines, each possibly a 32-beat PSRAM burst --
/// so it is the slowest command by a wide margin.
const REPLY_TIMEOUT: Duration = Duration::from_millis(3000);

// ---------------------------------------------------------------------------

/// The byte pipe, behind a trait so a test can choose where reads end.
///
/// That is the whole reason this exists. The one bug this file has had was
/// about what happens when a frame finishes part-way through a read buffer, and
/// no test that cannot control chunk boundaries could have found it. A real
/// serial port picks those boundaries by timing, which is exactly what a test
/// must not depend on.
trait Transport {
	fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize>;
	fn write_all(&mut self, buf: &[u8]) -> std::io::Result<()>;
}

impl Transport for Serial {
	fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
		Serial::read(self, buf)
	}
	fn write_all(&mut self, buf: &[u8]) -> std::io::Result<()> {
		Serial::write_all(self, buf)
	}
}

struct Link {
	port: Box<dyn Transport>,
	/// Where console output goes. `Box` rather than `stdout()` directly so a
	/// test can read back what a program "printed".
	out: Box<dyn Write>,
	dec: hp::Decoder,
	/// Bytes read from the port but not yet fed to the decoder.
	///
	/// THIS IS NOT AN OPTIMIZATION. A read returns whatever has arrived, which
	/// is frequently a reply followed by the beginning of the next frame. The
	/// first version of this returned the moment a frame completed and dropped
	/// the rest of the buffer on the floor, which lost every console frame that
	/// shared a read with a reply.
	///
	/// That is not a rare case, it is the main one: a program loaded by `run`
	/// prints its whole output in a few milliseconds immediately after `RESUME`,
	/// so its console frames land in the very same read as the `RESUME` reply.
	/// `hello` and `fib` lost their output every single time, while the boot
	/// program -- which prints one line per 0.75 s and so almost never shares a
	/// read -- appeared to work perfectly.
	spare: VecDeque<u8>,
	/// Console bytes that arrived while waiting for a reply. Printed
	/// immediately; kept only so `--quiet` can suppress them.
	quiet: bool,
}

#[derive(Debug)]
enum Fail {
	Io(std::io::Error),
	Proto(String),
	Nak(Option<hp::NakReason>),
	Timeout(&'static str),
}

impl std::fmt::Display for Fail {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Fail::Io(e) => write!(f, "{e}"),
			Fail::Proto(m) => write!(f, "{m}"),
			Fail::Nak(Some(r)) => write!(f, "board refused the command: {}", r.name()),
			Fail::Nak(None) => write!(f, "board refused the command, reason unknown"),
			Fail::Timeout(what) => write!(f, "no answer to {what} within {REPLY_TIMEOUT:?}"),
		}
	}
}

impl From<std::io::Error> for Fail {
	fn from(e: std::io::Error) -> Self {
		Fail::Io(e)
	}
}

impl From<hp::ProtoError> for Fail {
	fn from(e: hp::ProtoError) -> Self {
		Fail::Proto(e.to_string())
	}
}

type R<T> = Result<T, Fail>;

impl Link {
	fn open(port: &str, baud: u32, quiet: bool) -> R<Link> {
		let port = Serial::open(port, baud, READ_SLICE_MS)?;
		// Whatever the board printed before this session started is not an
		// answer to anything.
		port.flush_input()?;
		Ok(Link::with(Box::new(port), Box::new(std::io::stdout()), quiet))
	}

	fn with(port: Box<dyn Transport>, out: Box<dyn Write>, quiet: bool) -> Link {
		Link {
			port,
			out,
			dec: hp::Decoder::new(),
			spare: VecDeque::new(),
			quiet,
		}
	}

	fn emit_console(&mut self, bytes: &[u8]) {
		if self.quiet {
			return;
		}
		let _ = self.out.write_all(bytes);
		let _ = self.out.flush();
	}

	/// Sends one frame and waits for the first reply that is not console
	/// output. Console frames are printed as they arrive, which is what keeps a
	/// program's output visible during a long `load`.
	fn request(&mut self, ty: FrameType, payload: &[u8], what: &'static str) -> R<hp::Frame> {
		self.port.write_all(&hp::encode(ty, payload)?)?;
		self.await_reply(what)
	}

	/// The next complete frame, or `None` once `deadline` has passed.
	///
	/// The single place bytes are consumed. Leftovers stay in `spare`, which is
	/// what stops a frame that shares a read with another frame from being lost
	/// -- see the field's note.
	fn next_frame(&mut self, deadline: Instant) -> R<Option<hp::Frame>> {
		let mut buf = [0u8; 512];
		loop {
			while let Some(b) = self.spare.pop_front() {
				match self.dec.push(b) {
					Step::Frame(f) => return Ok(Some(f)),
					// A damaged frame is not fatal: the board is still there
					// and the next one will arrive. Only the deadline gives up.
					Step::BadCrc | Step::BadLength(_) | Step::More => {}
				}
			}
			if Instant::now() >= deadline {
				return Ok(None);
			}
			let n = self.port.read(&mut buf)?;
			self.spare.extend(&buf[..n]);
		}
	}

	fn await_reply(&mut self, what: &'static str) -> R<hp::Frame> {
		let deadline = Instant::now() + REPLY_TIMEOUT;
		while let Some(f) = self.next_frame(deadline)? {
			if f.ty == Some(FrameType::CONSOLE_OUT) {
				self.emit_console(&f.payload);
				continue;
			}
			if f.ty == Some(FrameType::NAK) {
				return Err(Fail::Nak(hp::parse_nak(&f.payload)?));
			}
			return Ok(f);
		}
		Err(Fail::Timeout(what))
	}

	/// Prints whatever console output has arrived, then returns.
	fn drain(&mut self, for_ms: u64) -> R<()> {
		let deadline = Instant::now() + Duration::from_millis(for_ms);
		while let Some(f) = self.next_frame(deadline)? {
			if f.ty == Some(FrameType::CONSOLE_OUT) {
				self.emit_console(&f.payload);
			}
		}
		Ok(())
	}

	/// Watches a running program: prints what it prints, and returns when it
	/// stops.
	///
	/// This exists because a short program's output is otherwise unobservable.
	/// The board holds no log -- the console buffer is eight bytes and drains in
	/// microseconds -- so the bytes are on the wire almost as soon as they are
	/// printed, and if nothing is listening they are gone. `kctl run` used to
	/// exit as soon as `RESUME` was acknowledged, and the next command purged
	/// the driver buffer on open, so `fib` printing `55` was lost every time
	/// while `fibforever` looked fine. The difference was only that one of them
	/// never stops.
	///
	/// So the port stays open across the resume. Nothing is flushed in between,
	/// and the first thing the program prints arrives here.
	fn supervise(&mut self) -> R<hp::State> {
		loop {
			self.drain(250)?;

			let f = self.request(FrameType::STATUS, &[], "STATUS")?;
			self.expect(&f, FrameType::STATE)?;
			let st = hp::State::parse(&f.payload)?;

			if st.halted() || st.faulted() {
				// The last console frame may still be in flight: the program
				// stopped, the bytes did not stop travelling.
				self.drain(500)?;
				return Ok(st);
			}
		}
	}

	/// Prints console output until interrupted, forwarding nothing.
	fn pump_console(&mut self) -> R<()> {
		loop {
			// A stray reply means someone else is driving this board, or a
			// previous kctl timed out and its answer arrived late. Neither is
			// worth stopping for.
			if let Some(f) = self.next_frame(Instant::now() + Duration::from_secs(3600))?
				&& f.ty == Some(FrameType::CONSOLE_OUT)
			{
				self.emit_console(&f.payload);
			}
		}
	}

	fn expect(&mut self, f: &hp::Frame, want: FrameType) -> R<()> {
		if f.ty != Some(want) {
			return Err(Fail::Proto(format!(
				"expected {}, got {}",
				want.name(),
				f.ty.map(|t| t.name().to_string())
					.unwrap_or_else(|| format!("type {:#04x}", f.raw_ty))
			)));
		}
		let _ = self;
		Ok(())
	}

	// ---- commands ---------------------------------------------------------

	fn ping(&mut self) -> R<hp::Ident> {
		let f = self.request(FrameType::PING, &[], "PING")?;
		self.expect(&f, FrameType::IDENT)?;
		let id = hp::Ident::parse(&f.payload)?;
		if id.version != hp::PROTO_VERSION {
			return Err(Fail::Proto(format!(
				"board speaks protocol version {}, this kctl speaks {}",
				id.version,
				hp::PROTO_VERSION
			)));
		}
		Ok(id)
	}

	fn state(&mut self, ty: FrameType, what: &'static str) -> R<hp::State> {
		let f = self.request(ty, &[], what)?;
		self.expect(&f, FrameType::STATE)?;
		Ok(hp::State::parse(&f.payload)?)
	}

	fn write_chunk(&mut self, addr: u32, data: &[u8]) -> R<u16> {
		let mut p = Vec::with_capacity(hp::WRITE_HDR_LEN + data.len());
		p.extend_from_slice(&addr.to_le_bytes());
		p.extend_from_slice(data);
		let f = self.request(FrameType::WRITE, &p, "WRITE")?;
		self.expect(&f, FrameType::ACK)?;
		Ok(hp::parse_ack(&f.payload)?)
	}

	fn read_chunk(&mut self, addr: u32, count: u16) -> R<Vec<u8>> {
		let mut p = Vec::with_capacity(hp::READ_REQ_LEN);
		p.extend_from_slice(&addr.to_le_bytes());
		p.extend_from_slice(&count.to_le_bytes());
		let f = self.request(FrameType::READ, &p, "READ")?;
		self.expect(&f, FrameType::DATA)?;
		if f.payload.len() != count as usize {
			return Err(Fail::Proto(format!(
				"asked for {count} bytes at {addr:#x}, got {}",
				f.payload.len()
			)));
		}
		Ok(f.payload)
	}

	fn write_range(&mut self, addr: u32, data: &[u8]) -> R<()> {
		for (i, chunk) in data.chunks(hp::MAX_WRITE_DATA).enumerate() {
			let at = addr + (i * hp::MAX_WRITE_DATA) as u32;
			let n = self.write_chunk(at, chunk)?;
			if n as usize != chunk.len() {
				return Err(Fail::Proto(format!(
					"board took {n} of {} bytes at {at:#x}",
					chunk.len()
				)));
			}
		}
		Ok(())
	}

	fn read_range(&mut self, addr: u32, count: usize) -> R<Vec<u8>> {
		let mut out = Vec::with_capacity(count);
		while out.len() < count {
			let want = (count - out.len()).min(hp::MAX_READ_DATA) as u16;
			out.extend(self.read_chunk(addr + out.len() as u32, want)?);
		}
		Ok(out)
	}

	/// Writes then reads back and compares.
	///
	/// A `WRITE` streams into memory as it arrives rather than being buffered
	/// and committed, so a frame that fails CRC has already written part of its
	/// range. The board cannot undo that; the host verifying is what closes it,
	/// and it costs one extra pass over a link that is already the slow part.
	fn load_verified(&mut self, addr: u32, data: &[u8]) -> R<()> {
		self.write_range(addr, data)?;
		let back = self.read_range(addr, data.len())?;
		if back != data {
			let at = back
				.iter()
				.zip(data)
				.position(|(a, b)| a != b)
				.unwrap_or(data.len().min(back.len()));
			return Err(Fail::Proto(format!(
				"read-back differs at {:#x}: wrote {:#04x}, read {:#04x}",
				addr as usize + at,
				data.get(at).copied().unwrap_or(0),
				back.get(at).copied().unwrap_or(0),
			)));
		}
		Ok(())
	}
}

// ---------------------------------------------------------------------------

fn describe(st: &hp::State) -> String {
	let mut s = String::new();
	s.push_str(if st.paused() { "paused" } else { "running" });
	if st.halted() {
		s.push_str(", halted");
	}
	if st.faulted() {
		s.push_str(&format!(
			", FAULTED cause={} addr={:#010x} info={:#010x}",
			st.fault_cause, st.fault_addr, st.fault_info
		));
	}
	s.push_str(&format!(", {} cycles", st.cycles));
	s
}

fn hexdump(addr: u32, bytes: &[u8]) {
	for (i, row) in bytes.chunks(16).enumerate() {
		let base = addr as usize + i * 16;
		let hex: Vec<String> = row.iter().map(|b| format!("{b:02x}")).collect();
		let text: String = row
			.iter()
			.map(|&b| if (0x20..0x7f).contains(&b) { b as char } else { '.' })
			.collect();
		println!("{base:08x}  {:<47}  |{text}|", hex.join(" "));
	}
}

/// Accepts `0x1000`, `1000` and `0b...`, because an address typed from a
/// listing and one typed from a memory map are rarely in the same base.
fn parse_num(s: &str) -> Result<u64, String> {
	let t = s.replace('_', "");
	let r = if let Some(h) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
		u64::from_str_radix(h, 16)
	} else if let Some(b) = t.strip_prefix("0b") {
		u64::from_str_radix(b, 2)
	} else {
		t.parse()
	};
	r.map_err(|e| format!("cannot read '{s}' as a number: {e}"))
}

const USAGE: &str = "\
usage: kctl [--port <name>] [--baud <n>] [--quiet] [--detach] <command>

  ping                       identify the board
  status                     what the machine is doing
  pause                      stop the core and make memory readable
  resume                     let the core run on from where it stopped
  reset                      reset the core (pc to 0); requires paused
  load <file> [--addr <a>]   pause, write, verify. Leaves the core paused
  run [file] [--addr <a>]    load if given, then reset, resume and watch it
  peek <addr> <count>        hex dump a memory range; requires paused
  poke <addr> <byte>...      write bytes; requires paused
  console                    print program output until interrupted

The port defaults to $K2G_PORT. Baud defaults to 115200.

`run` stays attached after resuming and prints what the program prints, until it
halts or faults. The board keeps no log -- console output exists only in flight --
so detaching loses everything a short program says. --detach does that anyway.";

fn main() -> ExitCode {
	let args: Vec<String> = std::env::args().skip(1).collect();

	let mut port = std::env::var("K2G_PORT").unwrap_or_default();
	let mut baud = DEFAULT_BAUD;
	let mut quiet = false;
	let mut detach = false;
	let mut addr_opt: Option<u64> = None;
	let mut rest: Vec<String> = Vec::new();

	let mut i = 0;
	while i < args.len() {
		match args[i].as_str() {
			"--port" | "-p" => {
				i += 1;
				match args.get(i) {
					Some(v) => port = v.clone(),
					None => return usage_error("--port needs a value"),
				}
			}
			"--baud" => {
				i += 1;
				match args.get(i).map(|v| parse_num(v)) {
					Some(Ok(v)) => baud = v as u32,
					Some(Err(e)) => return usage_error(&e),
					None => return usage_error("--baud needs a value"),
				}
			}
			"--addr" | "-a" => {
				i += 1;
				match args.get(i).map(|v| parse_num(v)) {
					Some(Ok(v)) => addr_opt = Some(v),
					Some(Err(e)) => return usage_error(&e),
					None => return usage_error("--addr needs a value"),
				}
			}
			"--quiet" | "-q" => quiet = true,
			"--detach" => detach = true,
			"--help" | "-h" => {
				println!("{USAGE}");
				return ExitCode::SUCCESS;
			}
			other => rest.push(other.to_string()),
		}
		i += 1;
	}

	if rest.is_empty() {
		return usage_error("no command given");
	}
	if port.is_empty() {
		return usage_error("no serial port: pass --port or set K2G_PORT");
	}

	match run(&port, baud, quiet, detach, addr_opt, &rest) {
		Ok(()) => ExitCode::SUCCESS,
		Err(e) => {
			eprintln!("kctl: {e}");
			ExitCode::FAILURE
		}
	}
}

fn usage_error(msg: &str) -> ExitCode {
	eprintln!("kctl: {msg}\n\n{USAGE}");
	ExitCode::from(2)
}

fn run(port: &str, baud: u32, quiet: bool, detach: bool, addr_opt: Option<u64>,
       cmd: &[String]) -> R<()> {
	let mut link = Link::open(port, baud, quiet)?;

	match cmd[0].as_str() {
		"ping" => {
			let id = link.ping()?;
			println!(
				"protocol {}  core_id {:#010x}  memory {} bytes  max payload {}",
				id.version, id.core_id, id.mem_bytes, id.max_payload
			);
			println!("capabilities: {}", caps(id.caps));
			if id.core_id != hp::CORE_ID {
				println!("note: core_id is not the expected {:#010x}", hp::CORE_ID);
			}
		}

		"status" => {
			let st = link.state(FrameType::STATUS, "STATUS")?;
			println!("{}", describe(&st));
		}

		"pause" => {
			let st = link.state(FrameType::PAUSE, "PAUSE")?;
			println!("{}", describe(&st));
		}

		"resume" => {
			let st = link.state(FrameType::RESUME, "RESUME")?;
			println!("{}", describe(&st));
		}

		"reset" => {
			link.state(FrameType::PAUSE, "PAUSE")?;
			let st = link.state(FrameType::RESET, "RESET")?;
			println!("{}", describe(&st));
		}

		"load" | "run" => {
			let file = cmd.get(1);
			if cmd[0] == "load" && file.is_none() {
				return Err(Fail::Proto("load needs a file".into()));
			}

			if let Some(path) = file {
				let image = std::fs::read(path).map_err(|e| {
					Fail::Proto(format!("cannot read {path}: {e}"))
				})?;
				if image.is_empty() {
					return Err(Fail::Proto(format!("{path} is empty")));
				}
				let at = addr_opt.unwrap_or(0) as u32;

				link.state(FrameType::PAUSE, "PAUSE")?;
				link.load_verified(at, &image)?;
				println!("loaded {} bytes at {at:#x} from {path}", image.len());
			} else {
				link.state(FrameType::PAUSE, "PAUSE")?;
			}

			if cmd[0] == "run" {
				link.state(FrameType::RESET, "RESET")?;
				let st = link.state(FrameType::RESUME, "RESUME")?;

				// Both paths report the same way, on stdout, like every other
				// command here. The supervised one used to write its final line
				// to stderr, so redirecting a program's output separated it
				// from the state that explains why the output stopped.
				if detach {
					println!("{}", describe(&st));
				} else {
					// Stay attached across the resume. See `supervise`: the
					// board keeps no log, so leaving now loses everything a
					// short program prints.
					let fin = link.supervise()?;
					println!("{}", describe(&fin));
				}
			}
		}

		"peek" => {
			let (Some(a), Some(n)) = (cmd.get(1), cmd.get(2)) else {
				return Err(Fail::Proto("peek needs an address and a count".into()));
			};
			let a = parse_num(a).map_err(Fail::Proto)? as u32;
			let n = parse_num(n).map_err(Fail::Proto)? as usize;
			link.state(FrameType::PAUSE, "PAUSE")?;
			let bytes = link.read_range(a, n)?;
			hexdump(a, &bytes);
		}

		"poke" => {
			let Some(a) = cmd.get(1) else {
				return Err(Fail::Proto("poke needs an address".into()));
			};
			let a = parse_num(a).map_err(Fail::Proto)? as u32;
			let mut data = Vec::new();
			for tok in &cmd[2..] {
				let v = parse_num(tok).map_err(Fail::Proto)?;
				if v > 0xFF {
					return Err(Fail::Proto(format!("{tok} is not a byte")));
				}
				data.push(v as u8);
			}
			if data.is_empty() {
				return Err(Fail::Proto("poke needs at least one byte".into()));
			}
			link.state(FrameType::PAUSE, "PAUSE")?;
			link.load_verified(a, &data)?;
			println!("wrote {} bytes at {a:#x}", data.len());
		}

		"console" => {
			// Confirm there is a board before sitting silently on a dead port.
			link.ping()?;
			eprintln!("kctl: console attached; Ctrl-C to stop");
			link.pump_console()?;
		}

		other => {
			return Err(Fail::Proto(format!("unknown command '{other}'")));
		}
	}

	Ok(())
}

fn caps(c: u32) -> String {
	let mut v = Vec::new();
	if c & hp::CAP_MEMORY != 0 {
		v.push("memory");
	}
	if c & hp::CAP_RUN_CONTROL != 0 {
		v.push("run-control");
	}
	if c & hp::CAP_CONSOLE != 0 {
		v.push("console-out");
	}
	if c & hp::CAP_CONSOLE_IN != 0 {
		v.push("console-in");
	}
	if v.is_empty() {
		"none".to_string()
	} else {
		v.join(", ")
	}
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
	use super::*;
	use std::cell::RefCell;
	use std::rc::Rc;

	/// A transport whose reads end exactly where the test says they do.
	struct Scripted {
		chunks: VecDeque<Vec<u8>>,
	}

	impl Transport for Scripted {
		fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
			match self.chunks.pop_front() {
				Some(c) => {
					let n = c.len().min(buf.len());
					buf[..n].copy_from_slice(&c[..n]);
					Ok(n)
				}
				// A quiet line, which is the normal state of this link.
				None => Ok(0),
			}
		}
		fn write_all(&mut self, _: &[u8]) -> std::io::Result<()> {
			Ok(())
		}
	}

	#[derive(Clone)]
	struct Sink(Rc<RefCell<Vec<u8>>>);

	impl Write for Sink {
		fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
			self.0.borrow_mut().extend_from_slice(b);
			Ok(b.len())
		}
		fn flush(&mut self) -> std::io::Result<()> {
			Ok(())
		}
	}

	fn link_with(chunks: Vec<Vec<u8>>) -> (Link, Sink) {
		let sink = Sink(Rc::new(RefCell::new(Vec::new())));
		let port = Scripted {
			chunks: chunks.into(),
		};
		(
			Link::with(Box::new(port), Box::new(sink.clone()), false),
			sink,
		)
	}

	fn state_frame() -> Vec<u8> {
		let st = hp::State {
			flags: hp::FLAG_HALTED,
			fault_cause: 0,
			fault_addr: 0,
			fault_info: 0,
			cycles: 175,
		};
		hp::encode(FrameType::STATE, &st.to_payload()).unwrap()
	}

	/// THE BUG THIS FILE HAD, and the reason the trait above exists.
	///
	/// A reply and a console frame arriving in one read. The first version
	/// returned the moment the reply parsed and discarded the rest of the
	/// buffer, so the console frame vanished. On hardware that lost the entire
	/// output of every program short enough to finish before the next read --
	/// which is every program that is not an infinite loop.
	#[test]
	fn a_reply_sharing_a_read_with_console_output_loses_neither() {
		let mut wire = state_frame();
		wire.extend(hp::encode(FrameType::CONSOLE_OUT, b"55\r\n").unwrap());

		let (mut link, sink) = link_with(vec![wire]);
		let f = link.await_reply("STATUS").unwrap();
		assert_eq!(f.ty, Some(FrameType::STATE));

		link.drain(0).unwrap();
		assert_eq!(&*sink.0.borrow(), b"55\r\n");
	}

	/// The same property at every possible boundary, because the one that
	/// breaks is never the one you would have picked by hand.
	#[test]
	fn every_split_point_delivers_both_frames() {
		let mut wire = state_frame();
		wire.extend(hp::encode(FrameType::CONSOLE_OUT, b"hi").unwrap());

		for split in 0..=wire.len() {
			let (mut link, sink) =
				link_with(vec![wire[..split].to_vec(), wire[split..].to_vec()]);
			let f = link.await_reply("STATUS").unwrap();
			assert_eq!(f.ty, Some(FrameType::STATE), "reply lost, split at {split}");
			// Non-zero, because past split 27 the reply fills the first chunk
			// and the console frame has not been read yet: `drain(0)` processes
			// what is already buffered, it does not go and fetch more.
			link.drain(20).unwrap();
			assert_eq!(&*sink.0.borrow(), b"hi", "console lost, split at {split}");
		}
	}

	/// Console output arriving before the reply is printed rather than mistaken
	/// for it. This is the case the framing exists for.
	#[test]
	fn console_before_a_reply_is_printed_not_returned() {
		let mut wire = hp::encode(FrameType::CONSOLE_OUT, b"Hello").unwrap();
		wire.extend(state_frame());

		let (mut link, sink) = link_with(vec![wire]);
		let f = link.await_reply("STATUS").unwrap();
		assert_eq!(f.ty, Some(FrameType::STATE));
		assert_eq!(&*sink.0.borrow(), b"Hello");
	}

	#[test]
	fn a_nak_becomes_an_error() {
		let wire = hp::encode(FrameType::NAK, &[hp::NakReason::STATE as u8]).unwrap();
		let (mut link, _) = link_with(vec![wire]);
		match link.await_reply("WRITE") {
			Err(Fail::Nak(Some(hp::NakReason::STATE))) => {}
			other => panic!("expected a STATE nak, got {other:?}"),
		}
	}

	/// A damaged frame must not end the wait: the board is still there and the
	/// next frame is still coming.
	#[test]
	fn a_corrupt_frame_does_not_abort_the_wait() {
		let mut bad = hp::encode(FrameType::CONSOLE_OUT, b"junk").unwrap();
		let n = bad.len();
		bad[n - 3] ^= 0xFF; // corrupt a payload byte

		let mut wire = bad;
		wire.extend(state_frame());

		let (mut link, sink) = link_with(vec![wire]);
		let f = link.await_reply("STATUS").unwrap();
		assert_eq!(f.ty, Some(FrameType::STATE));
		assert!(sink.0.borrow().is_empty(), "a corrupt frame was printed");
	}

	/// A quiet line gives up rather than blocking for ever.
	#[test]
	fn a_quiet_line_times_out() {
		let (mut link, _) = link_with(vec![]);
		let deadline = Instant::now() + Duration::from_millis(20);
		assert!(link.next_frame(deadline).unwrap().is_none());
	}

	// ---- a board, mocked ---------------------------------------------------
	//
	// Everything above tests the byte pump. This answers frames, which is what
	// the command layer talks to: chunking a load across several WRITEs,
	// reading it back to verify it, and watching a program until it halts.
	//
	// It can also misbehave on purpose, and that matters more than it looks. A
	// WRITE streams into memory as it arrives, so a frame that fails its CRC
	// has already written part of its range and the board cannot undo it. The
	// read-back in `load_verified` is the only thing between that and a
	// silently corrupt program, and a mock that always wrote correctly could
	// never show it working.

	struct Board {
		dec: hp::Decoder,
		out: VecDeque<u8>,
		mem: Vec<u8>,
		paused: bool,
		halted: bool,
		cycles: u64,
		/// (address, length) of every WRITE accepted, for assertions.
		writes: Vec<(u32, usize)>,
		/// Offset within the written stream to corrupt, if any.
		corrupt_at: Option<usize>,
		seen: usize,
		/// Acknowledge one byte fewer than was sent.
		short_ack: bool,
		/// Emitted as CONSOLE_OUT the moment the core is resumed.
		prints: Vec<u8>,
		/// STATUS polls answered "running" before reporting a halt.
		polls_before_halt: u32,
	}

	impl Board {
		fn new() -> Board {
			Board {
				dec: hp::Decoder::new(),
				out: VecDeque::new(),
				mem: vec![0u8; 4096],
				paused: false,
				halted: false,
				cycles: 0,
				writes: Vec::new(),
				corrupt_at: None,
				seen: 0,
				short_ack: false,
				prints: Vec::new(),
				polls_before_halt: 0,
			}
		}

		fn state(&self) -> Vec<u8> {
			let mut flags = 0u8;
			if self.paused {
				flags |= hp::FLAG_PAUSED | hp::FLAG_BUS_OWNED;
			}
			if self.halted {
				flags |= hp::FLAG_HALTED;
			}
			hp::State {
				flags,
				fault_cause: 0,
				fault_addr: 0,
				fault_info: 0,
				cycles: self.cycles,
			}
			.to_payload()
		}

		fn reply(&mut self, ty: FrameType, payload: &[u8]) {
			self.out.extend(hp::encode(ty, payload).unwrap());
		}

		fn handle(&mut self, f: hp::Frame) {
			match f.ty {
				Some(FrameType::PING) => {
					let id = hp::Ident {
						version: hp::PROTO_VERSION,
						max_payload: hp::MAX_PAYLOAD as u16,
						core_id: hp::CORE_ID,
						mem_bytes: self.mem.len() as u32,
						caps: hp::CAP_MEMORY | hp::CAP_RUN_CONTROL | hp::CAP_CONSOLE,
					};
					self.reply(FrameType::IDENT, &id.to_payload());
				}
				Some(FrameType::STATUS) => {
					if self.polls_before_halt > 0 {
						self.polls_before_halt -= 1;
						self.cycles += 100;
					} else if !self.paused {
						self.halted = true;
					}
					let p = self.state();
					self.reply(FrameType::STATE, &p);
				}
				Some(FrameType::PAUSE) => {
					self.paused = true;
					let p = self.state();
					self.reply(FrameType::STATE, &p);
				}
				Some(FrameType::RESUME) => {
					self.paused = false;
					// The program starts printing at once, which is exactly the
					// case that lost output on hardware.
					let prints = std::mem::take(&mut self.prints);
					if !prints.is_empty() {
						self.out
							.extend(hp::encode(FrameType::CONSOLE_OUT, &prints).unwrap());
					}
					let p = self.state();
					self.reply(FrameType::STATE, &p);
				}
				Some(FrameType::RESET) => {
					self.cycles = 0;
					self.halted = false;
					let p = self.state();
					self.reply(FrameType::STATE, &p);
				}
				Some(FrameType::WRITE) => {
					let a = u32::from_le_bytes([
						f.payload[0],
						f.payload[1],
						f.payload[2],
						f.payload[3],
					]);
					let data = f.payload[4..].to_vec();
					self.writes.push((a, data.len()));
					for (i, &b) in data.iter().enumerate() {
						let corrupt = self.corrupt_at == Some(self.seen + i);
						self.mem[a as usize + i] = if corrupt { b ^ 0xFF } else { b };
					}
					self.seen += data.len();
					let n = if self.short_ack {
						data.len() as u16 - 1
					} else {
						data.len() as u16
					};
					self.reply(FrameType::ACK, &n.to_le_bytes());
				}
				Some(FrameType::READ) => {
					let a = u32::from_le_bytes([
						f.payload[0],
						f.payload[1],
						f.payload[2],
						f.payload[3],
					]) as usize;
					let n = u16::from_le_bytes([f.payload[4], f.payload[5]]) as usize;
					let d = self.mem[a..a + n].to_vec();
					self.reply(FrameType::DATA, &d);
				}
				_ => {
					let r = [hp::NakReason::TYPE as u8];
					self.reply(FrameType::NAK, &r);
				}
			}
		}
	}

	#[derive(Clone)]
	struct Mock(Rc<RefCell<Board>>);

	impl Transport for Mock {
		fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
			let mut b = self.0.borrow_mut();
			let n = b.out.len().min(buf.len());
			for slot in buf.iter_mut().take(n) {
				*slot = b.out.pop_front().unwrap();
			}
			Ok(n)
		}
		fn write_all(&mut self, bytes: &[u8]) -> std::io::Result<()> {
			let mut b = self.0.borrow_mut();
			for &byte in bytes {
				if let Step::Frame(f) = b.dec.push(byte) {
					b.handle(f);
				}
			}
			Ok(())
		}
	}

	fn linked(board: Board) -> (Link, Mock, Sink) {
		let m = Mock(Rc::new(RefCell::new(board)));
		let sink = Sink(Rc::new(RefCell::new(Vec::new())));
		(
			Link::with(Box::new(m.clone()), Box::new(sink.clone()), false),
			m,
			sink,
		)
	}

	#[test]
	fn a_load_is_chunked_and_lands_contiguously() {
		let image: Vec<u8> = (0..300u32).map(|i| (i * 7 + 3) as u8).collect();
		let (mut link, mock, _) = linked(Board::new());

		link.load_verified(0x100, &image).unwrap();

		let b = mock.0.borrow();
		assert!(b.writes.len() > 1, "300 bytes should not fit in one frame");
		let mut want = 0x100u32;
		for &(a, n) in &b.writes {
			assert_eq!(a, want, "a chunk started at the wrong address");
			assert!(n <= hp::MAX_WRITE_DATA, "a chunk exceeded MAX_WRITE_DATA");
			want += n as u32;
		}
		assert_eq!(want as usize, 0x100 + image.len());
		assert_eq!(&b.mem[0x100..0x100 + image.len()], &image[..]);
	}

	/// THE GUARD THAT MATTERS. A WRITE cannot be undone once it has streamed
	/// into memory, so the read-back is the only thing that catches a load that
	/// landed wrong.
	#[test]
	fn a_load_that_lands_wrong_is_caught() {
		let image: Vec<u8> = (0..200u32).map(|i| i as u8).collect();
		let mut board = Board::new();
		board.corrupt_at = Some(150);
		let (mut link, _, _) = linked(board);

		match link.load_verified(0, &image) {
			Err(Fail::Proto(m)) => {
				assert!(m.contains("read-back differs"), "wrong complaint: {m}")
			}
			other => panic!("a corrupted load was not caught: {other:?}"),
		}
	}

	#[test]
	fn a_short_ack_is_caught() {
		let mut board = Board::new();
		board.short_ack = true;
		let (mut link, _, _) = linked(board);

		match link.load_verified(0, &[1, 2, 3, 4]) {
			Err(Fail::Proto(m)) => assert!(m.contains("took"), "wrong complaint: {m}"),
			other => panic!("a short ack was not caught: {other:?}"),
		}
	}

	#[test]
	fn a_read_longer_than_one_frame_reassembles_in_order() {
		let image: Vec<u8> = (0..400u32).map(|i| (i % 251) as u8).collect();
		let mut board = Board::new();
		board.mem[..image.len()].copy_from_slice(&image);
		let (mut link, _, _) = linked(board);

		let got = link.read_range(0, image.len()).unwrap();
		assert_eq!(got, image);
	}

	/// `run` without `--detach`: the program prints the moment it is resumed,
	/// and the tool has to catch that and then notice it stopped.
	#[test]
	fn supervise_prints_the_output_and_returns_the_halt() {
		let mut board = Board::new();
		board.prints = b"Hello from KAMASUTRA2G!".to_vec();
		board.polls_before_halt = 1;
		let (mut link, _, sink) = linked(board);

		link.state(FrameType::RESUME, "RESUME").unwrap();
		let fin = link.supervise().unwrap();

		assert!(fin.halted(), "supervise returned before the program stopped");
		assert_eq!(&*sink.0.borrow(), b"Hello from KAMASUTRA2G!");
	}

	/// Leftovers survive across separate calls, which is what `run` depends on:
	/// `await_reply` for the RESUME, then `supervise` reading what the program
	/// printed straight afterwards.
	#[test]
	fn leftovers_survive_between_calls() {
		let mut wire = state_frame();
		wire.extend(hp::encode(FrameType::CONSOLE_OUT, b"a").unwrap());
		wire.extend(hp::encode(FrameType::CONSOLE_OUT, b"b").unwrap());

		let (mut link, sink) = link_with(vec![wire]);
		link.await_reply("RESUME").unwrap();
		link.drain(0).unwrap();
		assert_eq!(&*sink.0.borrow(), b"ab");
	}
}
