//! A serial port, without a dependency.
//!
//! This crate has no dependencies and that is deliberate -- it is the normative
//! specification of an instruction set, it is loaded into Questa as a DPI shared
//! object, and every crate added to it is a crate that has to build in both
//! roles. Opening a COM port is about a hundred lines of platform FFI, which is
//! less than the cost of the alternative.
//!
//! Only what `kctl` needs: 8N1, no flow control, a read that can time out, and
//! a way to throw away whatever the board said before we started listening.
//!
//! **Windows is the tested path.** The Gowin and Questa toolchains are Windows
//! binaries and `docs/bring-up.md` says to drive them from Git Bash rather than
//! WSL, so that is where a board is. Linux is implemented because it costs
//! little and the emulator side of the project builds there; other targets fail
//! at `open` with a clear message rather than at compile time, so `cargo test`
//! still works everywhere.

use std::io;

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------
#[cfg(windows)]
mod imp {
	use std::ffi::c_void;
	use std::io;

	type Handle = *mut c_void;
	type Dword = u32;
	type Bool = i32;

	const INVALID_HANDLE_VALUE: Handle = -1isize as Handle;
	const GENERIC_READ: Dword = 0x8000_0000;
	const GENERIC_WRITE: Dword = 0x4000_0000;
	const OPEN_EXISTING: Dword = 3;
	const PURGE_RXCLEAR: Dword = 0x0008;
	const PURGE_TXCLEAR: Dword = 0x0004;

	const NOPARITY: u8 = 0;
	const ONESTOPBIT: u8 = 0;

	// The DCB bitfield DWORD, laid out as documented:
	//   bit 0 fBinary, bit 1 fParity, bit 2 fOutxCtsFlow, bit 3 fOutxDsrFlow,
	//   bits 4-5 fDtrControl, bit 6 fDsrSensitivity, bit 7 fTXContinueOnXoff,
	//   bit 8 fOutX, bit 9 fInX, bit 10 fErrorChar, bit 11 fNull,
	//   bits 12-13 fRtsControl, bit 14 fAbortOnError.
	//
	// fBinary (required), DTR_CONTROL_ENABLE, RTS_CONTROL_ENABLE. Everything
	// else off: the board has no flow control lines wired, and leaving XON/XOFF
	// on would let the host eat 0x11 and 0x13 out of a binary frame.
	const DCB_FLAGS_8N1_NOFLOW: Dword = 1 | (1 << 4) | (1 << 12);

	#[repr(C)]
	#[derive(Default)]
	struct Dcb {
		dcb_length: Dword,
		baud_rate: Dword,
		flags: Dword,
		w_reserved: u16,
		xon_lim: u16,
		xoff_lim: u16,
		byte_size: u8,
		parity: u8,
		stop_bits: u8,
		xon_char: i8,
		xoff_char: i8,
		error_char: i8,
		eof_char: i8,
		evt_char: i8,
		w_reserved1: u16,
	}

	#[repr(C)]
	#[derive(Default)]
	struct CommTimeouts {
		read_interval: Dword,
		read_total_multiplier: Dword,
		read_total_constant: Dword,
		write_total_multiplier: Dword,
		write_total_constant: Dword,
	}

	unsafe extern "system" {
		fn CreateFileW(
			name: *const u16,
			access: Dword,
			share: Dword,
			security: *mut c_void,
			disposition: Dword,
			flags: Dword,
			template: Handle,
		) -> Handle;
		fn CloseHandle(h: Handle) -> Bool;
		fn GetCommState(h: Handle, dcb: *mut Dcb) -> Bool;
		fn SetCommState(h: Handle, dcb: *const Dcb) -> Bool;
		fn SetCommTimeouts(h: Handle, t: *const CommTimeouts) -> Bool;
		fn PurgeComm(h: Handle, flags: Dword) -> Bool;
		fn ReadFile(
			h: Handle,
			buf: *mut u8,
			n: Dword,
			read: *mut Dword,
			overlapped: *mut c_void,
		) -> Bool;
		fn WriteFile(
			h: Handle,
			buf: *const u8,
			n: Dword,
			written: *mut Dword,
			overlapped: *mut c_void,
		) -> Bool;
	}

	pub struct Port {
		h: Handle,
	}

	// The handle is owned exclusively; nothing else in the process touches it.
	unsafe impl Send for Port {}

	impl Port {
		pub fn open(name: &str, baud: u32, timeout_ms: u32) -> io::Result<Port> {
			// `\\.\COM10` and beyond will not open under the bare name, and the
			// prefixed form works for COM1..COM9 too, so it is always used.
			let full = if name.starts_with(r"\\.\") {
				name.to_string()
			} else {
				format!(r"\\.\{name}")
			};
			let wide: Vec<u16> = full.encode_utf16().chain(std::iter::once(0)).collect();

			let h = unsafe {
				CreateFileW(
					wide.as_ptr(),
					GENERIC_READ | GENERIC_WRITE,
					0, // no sharing: two kctls on one port is a bug, not a feature
					std::ptr::null_mut(),
					OPEN_EXISTING,
					0,
					std::ptr::null_mut(),
				)
			};
			if h == INVALID_HANDLE_VALUE {
				return Err(io::Error::last_os_error());
			}

			let port = Port { h };
			port.configure(baud)?;
			port.set_timeout(timeout_ms)?;
			port.flush_input()?;
			Ok(port)
		}

		fn configure(&self, baud: u32) -> io::Result<()> {
			// Read the current DCB first: the fields this code does not set
			// still have to be something the driver accepts, and the documented
			// way to get that is to start from what it reported.
			let mut dcb = Dcb {
				dcb_length: std::mem::size_of::<Dcb>() as Dword,
				..Default::default()
			};
			if unsafe { GetCommState(self.h, &mut dcb) } == 0 {
				return Err(io::Error::last_os_error());
			}

			dcb.dcb_length = std::mem::size_of::<Dcb>() as Dword;
			dcb.baud_rate = baud;
			dcb.flags = DCB_FLAGS_8N1_NOFLOW;
			dcb.byte_size = 8;
			dcb.parity = NOPARITY;
			dcb.stop_bits = ONESTOPBIT;

			if unsafe { SetCommState(self.h, &dcb) } == 0 {
				return Err(io::Error::last_os_error());
			}
			Ok(())
		}

		pub fn set_timeout(&self, ms: u32) -> io::Result<()> {
			// A total constant with no interval and no multiplier means "return
			// with whatever has arrived after at most `ms`", which is what a
			// frame reader wants: it must not block forever on a board that is
			// not answering, and it must not return early on a board that is
			// answering slowly.
			let t = CommTimeouts {
				read_interval: 0,
				read_total_multiplier: 0,
				read_total_constant: ms,
				write_total_multiplier: 0,
				write_total_constant: 1000,
			};
			if unsafe { SetCommTimeouts(self.h, &t) } == 0 {
				return Err(io::Error::last_os_error());
			}
			Ok(())
		}

		pub fn flush_input(&self) -> io::Result<()> {
			if unsafe { PurgeComm(self.h, PURGE_RXCLEAR | PURGE_TXCLEAR) } == 0 {
				return Err(io::Error::last_os_error());
			}
			Ok(())
		}

		pub fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
			let mut got: Dword = 0;
			let ok = unsafe {
				ReadFile(
					self.h,
					buf.as_mut_ptr(),
					buf.len() as Dword,
					&mut got,
					std::ptr::null_mut(),
				)
			};
			if ok == 0 {
				return Err(io::Error::last_os_error());
			}
			Ok(got as usize)
		}

		pub fn write_all(&self, mut buf: &[u8]) -> io::Result<()> {
			while !buf.is_empty() {
				let mut put: Dword = 0;
				let ok = unsafe {
					WriteFile(
						self.h,
						buf.as_ptr(),
						buf.len() as Dword,
						&mut put,
						std::ptr::null_mut(),
					)
				};
				if ok == 0 {
					return Err(io::Error::last_os_error());
				}
				if put == 0 {
					return Err(io::Error::new(
						io::ErrorKind::WriteZero,
						"serial write made no progress",
					));
				}
				buf = &buf[put as usize..];
			}
			Ok(())
		}
	}

	impl Drop for Port {
		fn drop(&mut self) {
			unsafe {
				CloseHandle(self.h);
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Linux
// ---------------------------------------------------------------------------
#[cfg(target_os = "linux")]
mod imp {
	use std::io;

	const O_RDWR: i32 = 0o2;
	const O_NOCTTY: i32 = 0o400;
	const O_NONBLOCK: i32 = 0o4000;
	const F_SETFL: i32 = 4;

	const TCSANOW: i32 = 0;
	const TCIOFLUSH: i32 = 2;

	const IGNBRK: u32 = 0x0001;
	const BRKINT: u32 = 0x0002;
	const PARMRK: u32 = 0x0008;
	const ISTRIP: u32 = 0x0020;
	const INLCR: u32 = 0x0040;
	const IGNCR: u32 = 0x0080;
	const ICRNL: u32 = 0x0100;
	const IXON: u32 = 0x0400;

	const OPOST: u32 = 0x0001;

	const ISIG: u32 = 0x0001;
	const ICANON: u32 = 0x0002;
	const ECHO: u32 = 0x0008;
	const ECHONL: u32 = 0x0040;
	const IEXTEN: u32 = 0x8000;

	const CSIZE: u32 = 0x0030;
	const CS8: u32 = 0x0030;
	const CSTOPB: u32 = 0x0040;
	const CREAD: u32 = 0x0080;
	const PARENB: u32 = 0x0100;
	const CLOCAL: u32 = 0x0800;

	const VTIME: usize = 5;
	const VMIN: usize = 6;

	#[repr(C)]
	#[derive(Default, Clone, Copy)]
	struct Termios {
		c_iflag: u32,
		c_oflag: u32,
		c_cflag: u32,
		c_lflag: u32,
		c_line: u8,
		c_cc: [u8; 32],
		c_ispeed: u32,
		c_ospeed: u32,
	}

	unsafe extern "C" {
		fn open(path: *const u8, flags: i32) -> i32;
		fn close(fd: i32) -> i32;
		fn read(fd: i32, buf: *mut u8, n: usize) -> isize;
		fn write(fd: i32, buf: *const u8, n: usize) -> isize;
		fn fcntl(fd: i32, cmd: i32, arg: i32) -> i32;
		fn tcgetattr(fd: i32, t: *mut Termios) -> i32;
		fn tcsetattr(fd: i32, action: i32, t: *const Termios) -> i32;
		fn tcflush(fd: i32, queue: i32) -> i32;
		fn cfsetispeed(t: *mut Termios, speed: u32) -> i32;
		fn cfsetospeed(t: *mut Termios, speed: u32) -> i32;
	}

	/// The B* constants are an index, not the rate. Only the rates this project
	/// uses are listed; anything else is rejected rather than silently run at
	/// the wrong speed, which is the failure mode that produces "the UART works
	/// but every byte is garbage".
	fn speed_code(baud: u32) -> io::Result<u32> {
		Ok(match baud {
			9600 => 0o000015,
			19200 => 0o000016,
			38400 => 0o000017,
			57600 => 0o010001,
			115_200 => 0o010002,
			230_400 => 0o010003,
			460_800 => 0o010004,
			921_600 => 0o010007,
			other => {
				return Err(io::Error::new(
					io::ErrorKind::InvalidInput,
					format!("unsupported baud rate {other}"),
				));
			}
		})
	}

	pub struct Port {
		fd: i32,
	}

	impl Port {
		pub fn open(name: &str, baud: u32, timeout_ms: u32) -> io::Result<Port> {
			let path: Vec<u8> = name.bytes().chain(std::iter::once(0)).collect();
			// O_NONBLOCK so the open itself does not wait for carrier detect on
			// a line with no modem behind it; cleared immediately afterwards so
			// reads honour VTIME.
			let fd = unsafe { open(path.as_ptr(), O_RDWR | O_NOCTTY | O_NONBLOCK) };
			if fd < 0 {
				return Err(io::Error::last_os_error());
			}
			if unsafe { fcntl(fd, F_SETFL, 0) } < 0 {
				let e = io::Error::last_os_error();
				unsafe { close(fd) };
				return Err(e);
			}

			let port = Port { fd };
			port.configure(baud, timeout_ms)?;
			port.flush_input()?;
			Ok(port)
		}

		fn configure(&self, baud: u32, timeout_ms: u32) -> io::Result<()> {
			let mut t = Termios::default();
			if unsafe { tcgetattr(self.fd, &mut t) } < 0 {
				return Err(io::Error::last_os_error());
			}

			// Raw: no canonical mode, no echo, no signal characters, no
			// translation of any byte in either direction. A framed binary
			// protocol cannot survive CR/LF mapping or XON/XOFF.
			t.c_iflag &= !(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
			t.c_oflag &= !OPOST;
			t.c_lflag &= !(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
			t.c_cflag &= !(CSIZE | PARENB | CSTOPB);
			t.c_cflag |= CS8 | CREAD | CLOCAL;

			let code = speed_code(baud)?;
			if unsafe { cfsetispeed(&mut t, code) } < 0 || unsafe { cfsetospeed(&mut t, code) } < 0
			{
				return Err(io::Error::last_os_error());
			}

			// VMIN 0 with VTIME set is "return whatever arrived, waiting at most
			// VTIME tenths of a second". The resolution is deciseconds, so a
			// sub-100 ms request becomes 100 ms rather than becoming zero --
			// zero would be a busy poll that never waits for the board.
			t.c_cc[VMIN] = 0;
			t.c_cc[VTIME] = timeout_ms.div_ceil(100).clamp(1, 255) as u8;

			if unsafe { tcsetattr(self.fd, TCSANOW, &t) } < 0 {
				return Err(io::Error::last_os_error());
			}
			Ok(())
		}

		pub fn set_timeout(&self, ms: u32) -> io::Result<()> {
			let mut t = Termios::default();
			if unsafe { tcgetattr(self.fd, &mut t) } < 0 {
				return Err(io::Error::last_os_error());
			}
			t.c_cc[VMIN] = 0;
			t.c_cc[VTIME] = ms.div_ceil(100).clamp(1, 255) as u8;
			if unsafe { tcsetattr(self.fd, TCSANOW, &t) } < 0 {
				return Err(io::Error::last_os_error());
			}
			Ok(())
		}

		pub fn flush_input(&self) -> io::Result<()> {
			if unsafe { tcflush(self.fd, TCIOFLUSH) } < 0 {
				return Err(io::Error::last_os_error());
			}
			Ok(())
		}

		pub fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
			let n = unsafe { read(self.fd, buf.as_mut_ptr(), buf.len()) };
			if n < 0 {
				return Err(io::Error::last_os_error());
			}
			Ok(n as usize)
		}

		pub fn write_all(&self, mut buf: &[u8]) -> io::Result<()> {
			while !buf.is_empty() {
				let n = unsafe { write(self.fd, buf.as_ptr(), buf.len()) };
				if n < 0 {
					return Err(io::Error::last_os_error());
				}
				if n == 0 {
					return Err(io::Error::new(
						io::ErrorKind::WriteZero,
						"serial write made no progress",
					));
				}
				buf = &buf[n as usize..];
			}
			Ok(())
		}
	}

	impl Drop for Port {
		fn drop(&mut self) {
			unsafe {
				close(self.fd);
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Everywhere else
// ---------------------------------------------------------------------------
#[cfg(not(any(windows, target_os = "linux")))]
mod imp {
	use std::io;

	/// Fails at `open` rather than at compile time, so the rest of the crate --
	/// the emulator, the assembler, the DPI library -- still builds on a
	/// platform nobody has attached a board to.
	pub struct Port {
		_never: (),
	}

	impl Port {
		pub fn open(_name: &str, _baud: u32, _timeout_ms: u32) -> io::Result<Port> {
			Err(io::Error::new(
				io::ErrorKind::Unsupported,
				"serial ports are implemented for Windows and Linux only",
			))
		}
		pub fn set_timeout(&self, _ms: u32) -> io::Result<()> {
			unreachable!()
		}
		pub fn flush_input(&self) -> io::Result<()> {
			unreachable!()
		}
		pub fn read(&self, _buf: &mut [u8]) -> io::Result<usize> {
			unreachable!()
		}
		pub fn write_all(&self, _buf: &[u8]) -> io::Result<()> {
			unreachable!()
		}
	}
}

/// An open serial port: 8N1, no flow control, reads bounded by a timeout.
pub struct Serial {
	port: imp::Port,
}

impl Serial {
	/// `name` is `COM3` (or `\\.\COM12`) on Windows, `/dev/ttyUSB0` on Linux.
	pub fn open(name: &str, baud: u32, timeout_ms: u32) -> io::Result<Serial> {
		Ok(Serial {
			port: imp::Port::open(name, baud, timeout_ms)?,
		})
	}

	/// Bounds how long [`Serial::read`] waits. On Linux the hardware resolution
	/// is 100 ms and the value is rounded up to it.
	pub fn set_timeout(&self, ms: u32) -> io::Result<()> {
		self.port.set_timeout(ms)
	}

	/// Throws away anything already buffered in either direction.
	///
	/// `kctl` calls this at startup: a board that has been printing console
	/// output since it was powered on has a driver buffer full of frames that
	/// predate this session, and reading them as answers to commands nobody
	/// sent produces confusing failures.
	pub fn flush_input(&self) -> io::Result<()> {
		self.port.flush_input()
	}

	/// Returns 0 on timeout rather than an error -- a quiet line is the normal
	/// state of this link, not a fault.
	pub fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
		self.port.read(buf)
	}

	pub fn write_all(&self, buf: &[u8]) -> io::Result<()> {
		self.port.write_all(buf)
	}
}
