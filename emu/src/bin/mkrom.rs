//! `mkrom` — turns a program image into a synthesizable SystemVerilog ROM.
//!
//! On hardware the program has to get into the CPU's memory somehow. The
//! obvious route is initializing the BSRAM directly, but GowinSynthesis does
//! not honour `$readmemh` for inferred RAM (it produced no `INIT_RAM` data,
//! and with a synchronous read it exited with no diagnostic at all).
//!
//! So the program lives in a `case`-statement ROM — plain combinational logic
//! that any synthesizer handles — and a small copier in `k2g_soc` moves it
//! into RAM at reset before releasing the CPU. That also mirrors what a real
//! system does when it copies from flash into RAM.
//!
//! ```text
//! mkrom hello.bin -o rtl/board/k2g_rom.sv
//! ```

use std::process::ExitCode;

fn main() -> ExitCode {
	let args: Vec<String> = std::env::args().skip(1).collect();
	if args.is_empty() {
		eprintln!("usage: mkrom <image.bin> [-o <rom.sv>] [--module <name>]");
		return ExitCode::from(2);
	}

	let mut image_path: Option<String> = None;
	let mut out_path = String::from("k2g_rom.sv");
	let mut module = String::from("k2g_rom");

	let mut i = 0;
	while i < args.len() {
		match args[i].as_str() {
			"-o" => {
				i += 1;
				out_path = args.get(i).cloned().unwrap_or(out_path);
			}
			"--module" => {
				i += 1;
				module = args.get(i).cloned().unwrap_or(module);
			}
			other => image_path = Some(other.to_string()),
		}
		i += 1;
	}

	let Some(path) = image_path else {
		eprintln!("no image given");
		return ExitCode::from(2);
	};
	let image = match std::fs::read(&path) {
		Ok(b) => b,
		Err(e) => {
			eprintln!("cannot read {path}: {e}");
			return ExitCode::FAILURE;
		}
	};

	if image.is_empty() {
		eprintln!("{path} is empty");
		return ExitCode::FAILURE;
	}

	// Addressed by byte so the copier stays trivial; the memory's byte lanes
	// are handled by its own write-enable decode.
	let addr_bits = (usize::BITS - (image.len() - 1).leading_zeros()).max(1) as usize;

	let mut sv = String::new();
	sv.push_str("// GENERATED FILE -- DO NOT EDIT BY HAND.\n");
	sv.push_str(&format!("// Produced by `mkrom` from {path}.\n"));
	sv.push_str("//\n");
	sv.push_str("// A case statement rather than an initialized RAM: GowinSynthesis does not\n");
	sv.push_str("// honour $readmemh for inferred memory, so the program is held in logic and\n");
	sv.push_str("// copied into RAM at reset by k2g_soc.\n\n");
	sv.push_str(&format!("module {module} (\n"));
	sv.push_str(&format!("    input  logic [{}:0] addr,\n", addr_bits - 1));
	sv.push_str("    output logic [7:0]  data\n");
	sv.push_str(");\n\n");
	sv.push_str(&format!("  localparam int SIZE_BYTES = {};\n\n", image.len()));
	sv.push_str("  always_comb begin\n");
	sv.push_str("    unique case (addr)\n");

	for (a, b) in image.iter().enumerate() {
		sv.push_str(&format!(
			"      {}'d{}: data = 8'h{:02X};\n",
			addr_bits, a, b
		));
	}

	sv.push_str("      default: data = 8'h00;\n");
	sv.push_str("    endcase\n");
	sv.push_str("  end\n\n");
	sv.push_str("endmodule\n");

	if let Err(e) = std::fs::write(&out_path, &sv) {
		eprintln!("cannot write {out_path}: {e}");
		return ExitCode::FAILURE;
	}

	// Sizes go in a companion header rather than in the module.
	//
	// They cannot be a parameter inside the ROM: GowinSynthesis rejects a
	// hierarchical reference like `u_rom.SIZE_BYTES`. They cannot be a
	// `define in the ROM file either, because macros defined in one source
	// file are not visible in the next. An include is textual, so it works.
	let hdr_path = out_path
		.rsplit_once('.')
		.map(|(stem, _)| format!("{stem}.svh"))
		.unwrap_or_else(|| format!("{out_path}.svh"));

	let mut hdr = String::new();
	hdr.push_str("// GENERATED FILE -- DO NOT EDIT BY HAND.
");
	hdr.push_str(&format!("// Companion to {module}, produced by `mkrom`.

"));
	hdr.push_str("`ifndef K2G_ROM_SVH
`define K2G_ROM_SVH
");
	hdr.push_str(&format!("`define K2G_ROM_BYTES {}
", image.len()));
	hdr.push_str(&format!("`define K2G_ROM_ADDR_BITS {addr_bits}
"));
	hdr.push_str("`endif
");

	if let Err(e) = std::fs::write(&hdr_path, &hdr) {
		eprintln!("cannot write {hdr_path}: {e}");
		return ExitCode::FAILURE;
	}

	println!(
		"wrote {out_path} and {hdr_path}: {} bytes of program, {}-bit address",
		image.len(),
		addr_bits
	);
	ExitCode::SUCCESS
}
