use std::fmt::Write;

fn mk_iter(ulim:u32) -> impl Iterator<Item=u32> {
    (0 .. ulim).map(move |i| ulim - 1 - i)
}
fn zpad(n:u32, bw:u32) -> u32 {
    bw - (32 - n.leading_zeros())
}
fn mk_lines(out:&mut String, max_bits:u32, enum_name:&str, entry_pad:&str, entries:&[&str]) {
    let max_entries = 2u32.pow(max_bits);
    let mut ix_iter = mk_iter(max_entries);
    let mut ent_iter = entries.iter();
    loop {
        let i = (ix_iter.next(), ent_iter.next());
        match i {
            (Some(ix), ent) => {
                let _ = write!(out, "{}", entry_pad);
                match ent {
                    Some(nm) => {
                        let _ = write!(out, "{}_{} = 'b", enum_name, nm);
                    },
                    None => {
                        let _ = write!(out, "{}_UNCLAIMED_{} = 'b", enum_name, ix);
                    }
                }
                for _ in 0 .. zpad(ix, max_bits) {
                    let _ = write!(out, "0");
                }
                if ix != 0 {
                    let _ = write!(out, "{:0b}, // {}\n", ix, ix);        
                } else {
                    let _ = write!(out, " // {}\n", ix);
                }
                if ix % 8 == 0 {
                    let _ = write!(out, "\n");
                }
            },
            (None, Some(_)) => {
                panic!("ERROR: you gave more entries than there are repr bits");
            }
            _ => break
        }
    }
}
fn mk_enum(out:&mut String, name:&str, bw:u32, entries:&[&str]) {
    let e_pad = "  ";
    let _ = write!(out, "typedef enum bit [{}:0] {{\n\n", bw-1);
    mk_lines(out, bw, name, e_pad, entries);
    let _ = write!(out, "}} {} ;", name);
}
fn mk_enum_2(out:&mut String, name:&str, entries:&[&str]) {
    let e_pad = "  ";
    let bw = (entries.len() as f32).log2().ceil() as u32;
    let bw = bw.max(1);
    let _ = write!(out, "typedef enum bit [{}:0] {{\n\n", bw-1);
    mk_lines(out, bw, name, e_pad, entries);
    let _ = write!(out, "}} {} ;", name);
}
fn main() {
    let mut out = String::new();
    // mk_enum(&mut out, "LB", 6, &[
    //     "EP1",
    //     "PUC8",
    //     "PUC16",
    //     "PUC32",
    //     "CPY",
    //     "LD8",
    //     "LD16",
    //     "LD32",
    //     "LDF32",
    //     "ST",
    //     "ADD",
    //     "SUB",
    //     "MUL",
    //     "DIV",
    //     "AND",
    //     "OR",
    //     "XOR",
    //     "SHL",
    //     "SHR",
    //     "SHRA",
    //     "SHLI",
    //     "SHRI",
    //     "SHRAI",
    //     "TST",
    //     "TSTN",
    //     "LT",
    //     "GT",
    //     "LTE",
    //     "GTE",
    //     "DISP",
    //     "DISPI",
    //     "XCN",
    //     "XCP",
    //     "XI",
    //     "XIZEXT",
    //     "BMX_0_0",
    // ]);
    mk_enum(&mut out, "EP1", 5, &[
        "EP2",
        "UTO",
        "SS",
        "NOT",
        "NEG",
        "DISP_OFF",
        "DISP_ABS",
        "SR",
        "ESP",
        "LTL",
        "SL",
        "LLC_B8",
        "LLC_B16",
        "LLC_B32",
        "LLC_F32",
    ]);
    // mk_enum(&mut out, "XTR", 5, &[
    //     "EXTR_1_B8",
    //     "EXTR_0_B8",
    //     "EXTR_3_B8",
    //     "EXTR_2_B8",
    //     "EXTR_0_B16",
    //     "EXTR_1_B16",
    //     "INSR_0_B8",
    //     "INSR_1_B8",
    //     "INSR_2_B8",
    //     "INSR_3_B8",
    //     "INSR_0_B16",
    //     "INSR_1_B16",
    // ]);
    // mk_enum(&mut out, "CC", 5, &[
    //     "OVERFLOW_SET",
    //     "VALUE_NEGATIVE",
    //     "VALUE_ZERO",
    //     "VALUE_ONE",
    //     "FLAG_SET",
    // ]);
    // mk_enum(&mut out, "EP2", 5, &[
    //     "FLAG",
    //     "CSP",
    //     "TC",
    //     "DNO",
    //     "MPI",
    //     "MPD",
    //     "HALT",
    //     "ICINVR",
    // ]);
    // mk_enum_2(&mut out, "ID", &[
    //     "LC_S5",
    //     "LC_S15",
    //     "LD_B8",
    //     "LD_B16",
    //     "LD_B32",
    //     "LD_F32",
    //     "LD_B8_OFF",
    //     "LD_B16_OFF",
    //     "LD_B32_OFF",
    //     "LD_F32_OFF",
    //     "LD_B8_LOCK",
    //     "LD_B16_LOCK",
    //     "LD_B32_LOCK",
    //     "LD_F32_LOCK",
    //     "CPY",
    //     "ST",
    //     "ST_SEQ",
    //     "ST_SEQ_REL",
    //     "EXPORT_SPAN",
    //     "ST_INSN",
    //     "LD_B8_MSR",
    //     "LD_B16_MSR",
    //     "LD_B32_MSR",
    //     "ST_MCR",
    //     "NEG",
    //     "ADD_RR",
    //     "ADD_RI",
    //     "SUB_RR",
    //     "SUB_RI",
    //     "MUL_RR",
    //     "MUL_RI",
    //     "MULW_RR",
    //     "MULW_RI",
    //     "DIV_RR",
    //     "DIV_RI",
    //     "SHL_RR",
    //     "SHR_RR",
    //     "SHRA_RR",
    //     "SHL_RI",
    //     "SHR_RI",
    //     "SHRA_RI",
    //     "INV",
    //     "FLAG_AND",
    //     "FLAG_OR",
    //     "FLAG_NOT",
    //     "CHECK_OVERFLOW",
    //     "CHECK_CARRY",
    //     "CMP_EQ",
    //     "CMP_NEQ",
    //     "CMP_GT_RR",
    //     "CMP_GTE_RR",
    //     "CMP_LT_RR",
    //     "CMP_LTE_RR",
    //     "CMP_GT_RI",
    //     "CMP_GTE_RI",
    //     "CMP_LT_RI",
    //     "CMP_LTE_RI",
    //     "DISP_IMM10",
    //     "DISP_IMM20",
    //     "DISP_IMM20_LINK",
    //     "DISP_REG_OFF",
    //     "DISP_REG_OFF_LINK",
    //     "DISP_REG_ADDR",
    //     "DISP_REG_ADDR_WIC",
    //     "DISP_REG_ADDR_LINK",
    //     "DISP_REG_ADDR_LINK_WIC",
    //     "CTRLTRN",
    //     "HALT",
    //     "NOP",
    //     "PFD",
    //     "PFI"
    // ]);
    // mk_enum_2(&mut out, "RDT", &[
    //     "B8",
    //     "B16",
    //     "B32",
    //     "F32"
    // ]);
    // mk_enum_2(&mut out, "StoreAug", &[
    //     "None",
    //     "Sequenced",
    //     "SpanExport",
    //     "InsnStore",
    //     "Release"
    // ]);
    // mk_enum_2(&mut out, "ArithV", &[
    //     "Add",
    //     "Sub",
    //     "Mul",
    //     "Div",
    //     "Shl",
    //     "Shr",
    //     "ShrA",
    //     "And",
    //     "Or",
    //     "Not",
    //     "Neg",
    //     "Xor"
    // ]);
    // mk_enum_2(&mut out, "DispV", &[
    //     "Off_Imm",
    //     "Off_Reg",
    //     "Addr_Reg",
    // ]);
    // mk_enum_2(&mut out, "CanonInsnV", &[
    //     "ArithLogic",
    //     "MemLoad",
    //     "MemStore",
    //     "Disp",
    //     "Fetch",
    //     "Copy",
    //     "ExportSpan",
    //     "PCtrl",
    //     "FlagOp",
    //     "CmpOp",
    // ]);
    // mk_enum_2(&mut out, "PCtrlV", &[
    //     "Get",
    //     "Set"
    // ]);
    // mk_enum_2(&mut out, "FlagOpV", &[
    //     "And",
    //     "Or",
    //     "Not",
    // ]);
    // mk_enum_2(&mut out, "CmpOpV", &[
    //     "LT",
    //     "LTE",
    //     "GT",
    //     "GTE",
    //     "Eq",
    //     "NEq"
    // ]);
    // mk_enum(&mut out, "TestV", 5, &[
    //     "FlagSet",
    //     "RegOverflow",
    //     "RegCarry",
    //     "RegZero",
    //     "RegOne",
    //     "RegMinusOne"
    // ]);
    println!("{}", out);
}

