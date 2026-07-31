mod insns;
mod interp;

use interp::Interpreter;

fn main() {
	const MEM_SIZE: usize = 1024 * 1024;
	let mem = Box::leak(vec![0u16; MEM_SIZE].into_boxed_slice());
	
	let mut interp = Interpreter::new(mem.as_mut_ptr() as *mut ());
	interp.run();
	
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::interp::{DataKind, Flags, Reg};
	use crate::insns::*;

	fn write_code(mem: *mut u16, offset: &mut usize, code: &[u16]) {
		for &cp in code {
			unsafe { mem.byte_add(*offset).cast::<u16>().write(cp) };
			*offset += 2;
		}
	}

	#[test]
	fn test_put_constant() {
		let mut mem = vec![0u16; 1024];
		let mem_ptr = mem.as_mut_ptr() as *mut ();
		
		let mut offset = 0;
		// 1. Load small positive constant (10) to Reg 1 (B32)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(1, 10));
		
		// 2. Load small negative constant (-1, encoded as 31) to Reg 2 (B16)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b16(2, -1));
		
		// 3. Load large constant (0x12345678) to Reg 3 (B32) using LLC
		write_code(mem.as_mut_ptr(), &mut offset, &encode_llc_b32(3, 0x12345678));
		
		// 4. Halt
		write_code(mem.as_mut_ptr(), &mut offset, &encode_halt());

		let mut interp = Interpreter::new(mem_ptr);
		interp.run();

		assert_eq!(interp.regs[1], Reg { bits: 10, datatype: DataKind::B32, flags: Flags { overflow: false, flag_bit: false } });
		assert_eq!(interp.regs[2], Reg { bits: 0xffffffff, datatype: DataKind::B16, flags: Flags { overflow: false, flag_bit: false } });
		assert_eq!(interp.regs[3], Reg { bits: 0x12345678, datatype: DataKind::B32, flags: Flags { overflow: false, flag_bit: false } });
	}

	#[test]
	fn test_alu() {
		let mut mem = vec![0u16; 1024];
		let mem_ptr = mem.as_mut_ptr() as *mut ();

		let mut offset = 0;
		// Reg 1 = 10
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(1, 10));
		// Reg 2 = 5
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(2, 5));
		// Reg 1 = Reg 1 + Reg 2 (15)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_add_rr(1, 2));
		// Reg 1 = Reg 1 + (-5) (10)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_add_ri(1, -5));
		// Reg 1 = Reg 1 << 2 (40)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_shl_ri(1, 2));
		
		write_code(mem.as_mut_ptr(), &mut offset, &encode_halt());

		let mut interp = Interpreter::new(mem_ptr);
		interp.run();

		assert_eq!(interp.regs[1].bits, 40);
	}

	#[test]
	fn test_mulw() {
		let mut mem = vec![0u16; 1024];
		let mem_ptr = mem.as_mut_ptr() as *mut ();

		let mut offset = 0;
		// Reg 1 = 0x10000 (LLC B32)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_llc_b32(1, 0x10000));
		// Reg 2 = 0x20000 (LLC B32)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_llc_b32(2, 0x20000));
		// Wide multiply: Reg 1 * Reg 2 -> low 32 bits in Reg 1, high 32 bits in Reg 3
		write_code(mem.as_mut_ptr(), &mut offset, &encode_mulw_rr(1, 2, 3));

		write_code(mem.as_mut_ptr(), &mut offset, &encode_halt());

		let mut interp = Interpreter::new(mem_ptr);
		interp.run();

		assert_eq!(interp.regs[1].bits, 0); // low 32 bits
		assert_eq!(interp.regs[3].bits, 2); // high 32 bits
	}

	#[test]
	fn test_load_store() {
		let mut mem = vec![0u16; 1024];
		let mem_ptr = mem.as_mut_ptr() as *mut ();

		let mut offset = 0;
		// Reg 1 = 160 (memory address offset in bytes)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(1, 10));
		write_code(mem.as_mut_ptr(), &mut offset, &encode_shl_ri(1, 4)); // 10 << 4 = 160
		
		// Reg 2 = 0xdeadbeef
		write_code(mem.as_mut_ptr(), &mut offset, &encode_llc_b32(2, 0xdeadbeef));
		
		// Store Reg 2 to [Reg 1]
		write_code(mem.as_mut_ptr(), &mut offset, &encode_st(1, 2));

		// Load 32-bit from [Reg 1] to Reg 4
		write_code(mem.as_mut_ptr(), &mut offset, &encode_ld_b32(4, 1));

		// Load address 150 into Reg 5
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(5, 15));
		write_code(mem.as_mut_ptr(), &mut offset, &encode_shl_ri(5, 4)); // 15 << 4 = 240
		write_code(mem.as_mut_ptr(), &mut offset, &encode_add_ri(5, -90)); // 240 - 90 = 150
		
		// Load with signed offset 10: [Reg 5 + 10] -> [160] to Reg 6
		write_code(mem.as_mut_ptr(), &mut offset, &encode_ld_b32_soff(6, 5, 10));

		write_code(mem.as_mut_ptr(), &mut offset, &encode_halt());

		let mut interp = Interpreter::new(mem_ptr);
		interp.run();

		assert_eq!(interp.regs[4].bits, 0xdeadbeef);
		assert_eq!(interp.regs[6].bits, 0xdeadbeef);
	}

	#[test]
	fn test_flags() {
		let mut mem = vec![0u16; 1024];
		let mem_ptr = mem.as_mut_ptr() as *mut ();

		let mut offset = 0;
		// Reg 1 = 15
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(1, 15));
		// Reg 2 = 30
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(2, 10));
		write_code(mem.as_mut_ptr(), &mut offset, &encode_add_ri(2, 20));

		// Compare Reg 1 < Reg 2 -> flag 1
		write_code(mem.as_mut_ptr(), &mut offset, &encode_cmp_lt_rr(1, 2));
		// Compare Reg 1 == Reg 2 -> flag 2
		write_code(mem.as_mut_ptr(), &mut offset, &encode_cmp_eq(2, 1)); // sets flag 2 to false

		write_code(mem.as_mut_ptr(), &mut offset, &encode_halt());

		let mut interp = Interpreter::new(mem_ptr);
		interp.run();

		assert!(interp.regs[1].flags.flag_bit); // 15 < 30 is true
		assert!(!interp.regs[2].flags.flag_bit); // 30 == 15 is false
	}

	#[test]
	fn test_conditionals() {
		let mut mem = vec![0u16; 1024];
		let mem_ptr = mem.as_mut_ptr() as *mut ();

		let mut offset = 0;
		// Reg 1 = 1
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(1, 1));

		// Reg 2 = 1
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(2, -1));
		
		// If flag 5 is set -> load 10 to Reg 1 (skip since flag 5 is 0)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_xcp(5, CC::CC_FLAG_SET));
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(1, 10));

		// If flag 5 is NOT set -> load 12 to Reg 1 (executes since flag 5 is 0)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_xcn(5, CC::CC_FLAG_SET));
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(1, 12));

		write_code(mem.as_mut_ptr(), &mut offset, &encode_halt());

		let mut interp = Interpreter::new(mem_ptr);
		
		interp.run();

		assert_eq!(interp.regs[1].bits, 12);
	}

	#[test]
	fn test_bit_manip() {
		let mut mem = vec![0u16; 1024];
		let mem_ptr = mem.as_mut_ptr() as *mut ();

		let mut offset = 0;
		// Reg 2 = 0xabcd (43981)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_llc_b32(2, 0xabcd));
		
		// extract bits: start=4, span=8 from Reg 2 -> Reg 1
		// 0xabcd -> bin: 1010 1011 1100 1101. Bits 4..11: 1011 1100 -> 0xbc (188)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_bext(1, 2, 4, 8));

		write_code(mem.as_mut_ptr(), &mut offset, &encode_halt());

		let mut interp = Interpreter::new(mem_ptr);
		interp.run();

		assert_eq!(interp.regs[1].bits, 0xbc);
	}

	#[test]
	fn test_control_transfer() {
		let mut mem = vec![0u16; 1024];
		let mut offset = 0;
		// offset 0
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(1, 1));
		
		// offset 2
		write_code(mem.as_mut_ptr(), &mut offset, &encode_disp_imm(4));
		// offset 4
		write_code(mem.as_mut_ptr(), &mut offset, &encode_ctrl_trn());
		
		// offset 6 (Skipped)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(1, 5));
		// offset 8 (Skipped)
		write_code(mem.as_mut_ptr(), &mut offset, &encode_halt());
		
		// offset 10: Target of first jump
		write_code(mem.as_mut_ptr(), &mut offset, &encode_llc_b32(2, 20));
		
		// offset 16
		write_code(mem.as_mut_ptr(), &mut offset, &encode_disp_reg_addr(2));
		// offset 18
		write_code(mem.as_mut_ptr(), &mut offset, &encode_ctrl_trn());
		
		// offset 20: Target of second jump
		write_code(mem.as_mut_ptr(), &mut offset, &encode_lc_i5_b32(3, 10));

		// offset 22
		write_code(mem.as_mut_ptr(), &mut offset, &encode_halt());

		let mut interp = Interpreter::new(mem.as_mut_ptr() as *mut ());
		interp.run();

		assert_eq!(interp.regs[1].bits, 1);
		assert_eq!(interp.regs[2].bits, 20);
		assert_eq!(interp.regs[3].bits, 10);
	}

	#[test]
	fn test_fibonacci() {
		let mut mem = vec![0u16; 1024];
		let mut offset = 0;
		let mem_ptr = mem.as_mut_ptr();

		// a = 0 (R1)
		write_code(mem_ptr, &mut offset, &encode_lc_i5_b32(1, 0));
		// b = 1 (R2)
		write_code(mem_ptr, &mut offset, &encode_lc_i5_b32(2, 1));
		// n = 10 (R3)
		write_code(mem_ptr, &mut offset, &encode_lc_i5_b32(3, 10));
		// zero = 0 (R5)
		write_code(mem_ptr, &mut offset, &encode_lc_i5_b32(5, 0));

		// Loop Start (Offset 8)
		// If R3 is 0, jump to END (Offset 32)
		write_code(mem_ptr, &mut offset, &encode_xcp(3, CC::CC_VALUE_ZERO));
		write_code(mem_ptr, &mut offset, &encode_disp_imm(10)); // Target = 10 + (10 * 2) = 32
		write_code(mem_ptr, &mut offset, &encode_ctrl_trn());

		// temp = a + b (R4 = R1 + R2)
		write_code(mem_ptr, &mut offset, &encode_cpy(4, 1));
		write_code(mem_ptr, &mut offset, &encode_add_rr(4, 2));

		// a = b (R1 = R2)
		write_code(mem_ptr, &mut offset, &encode_cpy(1, 2));

		// b = temp (R2 = R4)
		write_code(mem_ptr, &mut offset, &encode_cpy(2, 4));

		// count = count - 1 (R3 = R3 - 1)
		write_code(mem_ptr, &mut offset, &encode_add_ri(3, -1));

		// Jump Loop
		write_code(mem_ptr, &mut offset, &encode_disp_imm(-10)); // Target = 28 - (10 * 2) = 8
		write_code(mem_ptr, &mut offset, &encode_ctrl_trn());

		// End (Offset 32)
		write_code(mem_ptr, &mut offset, &encode_halt());

		let mut interp = Interpreter::new(mem_ptr as _);
		interp.run();

		// Fib(10) is 55
		assert_eq!(interp.regs[1].bits, 55);

		// let slice = unsafe { core::slice::from_raw_parts(mem_ptr as *mut u8, mem.len() * 2) };
		// std::fs::write("test.bc", slice).unwrap();
	}
}
