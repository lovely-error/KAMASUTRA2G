//! KAMASUTRA2G (K2G) emulator.
//!
//! This crate is the **normative specification** of the K2G ISA. The RTL under
//! `rtl/` is verified against it by differential cosimulation, and the
//! SystemVerilog opcode header `rtl/k2g_defs.svh` is generated from
//! [`insns`] by [`sv_gen`] rather than maintained by hand.
//!
//! Exposed as a library so the binaries (`emu`, `gen_defs`, and later `kasm` /
//! `kdis`) share one definition of the instruction set, and so the Questa
//! testbench can link against it through DPI-C.

pub mod devices;
pub mod fault;
pub mod insns;
pub mod interp;
pub mod sv_gen;
