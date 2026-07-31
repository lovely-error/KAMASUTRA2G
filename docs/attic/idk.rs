use crate::chan::{Sender, Receiver};

struct MemReqv {
	start: u32,
	span: u32
}

struct CellMsg {
	addr: u32,
	val: u32,
	cell_ix: usize
}

struct AddrOverride {
	addr: u32
}

struct IPack {
	data: [u16;8],
	addr: u32,
}

union CastI {
	v1: [u32;4],
	v2: [u16;8]
}

#[derive(Debug, Clone, Copy)]
struct MemColumn {
	data: [u32; 512],
}

struct LdReq {
	addr: u32,
}

fn icache_cell(
	_cell_ix: usize,
	value_in: Receiver<CellMsg>,
	_ld_req: Receiver<LdReq>,
	insn_pack_out: Sender<IPack>,
) {
	let mut mem: [MemColumn; 4] = [MemColumn { data: [0;512] }; 4];
	let mut read_row_ix = 0;
	let mut write_row_ix = 0;
	let mut write_column_ix = 0;
	loop {
		if let Some(_ld_req) = _ld_req.peek() {
			
		}
		let p0 = mem[0].data[read_row_ix];
		let p1 = mem[1].data[read_row_ix];
		let p2 = mem[2].data[read_row_ix];
		let p3 = mem[3].data[read_row_ix];
		let pack = unsafe { CastI { v1: [p0, p1, p2, p3] }.v2 };
		let ok = insn_pack_out.try_send(IPack { data: pack, addr: read_row_ix as _ });
		if !ok { continue }
		read_row_ix += 1;
		if let Some(resp) = value_in.peek() {
			mem[write_column_ix].data[write_row_ix] = resp.val;
			let next_write_column_ix = (write_column_ix + 1) % 4;
			write_column_ix = next_write_column_ix;
			let next_write_row_ix = if next_write_column_ix == 0 { write_row_ix + 1 } else { write_row_ix };
			write_row_ix = next_write_row_ix;
			value_in.drop();
		}
	}
}
#[derive(Debug, Clone, Copy)]
struct CellMtd {
	addr: u32,
	valid: bool
}
fn icahce_proc(
	_mem_req: Sender<()>,
	_mem_resp: Receiver<()>,
	_override_1: Receiver<AddrOverride>,
) {
	let _mtd: [CellMtd;8] = [CellMtd { addr: 0, valid: false  }; 8];
	let _fetch_lane_1_addr = Option::<u32>::None;
	loop {
		if let Some(_fetch_lane_1_addr) = _fetch_lane_1_addr {
			// fetch_lane_1_addr
		}
	}
}