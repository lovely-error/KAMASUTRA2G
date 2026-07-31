use core::pin::Pin;
use std::{alloc::{Layout, alloc}, mem::MaybeUninit, ops::Coroutine};

use crate::chan::{Receiver, Sender, chan};

struct Proc<T> where T:Coroutine<Yield = ()> {
	stm: T
}

impl <T> Proc<T> where T:Coroutine<Yield = ()> {
	fn new(stm: T) -> Self {
		Proc { stm }
	}
	fn advance_one_tick(&mut self) {
		let stm_ptr = &mut self.stm;
		let ptr = unsafe { Pin::new_unchecked(stm_ptr) };
		let _ = Coroutine::resume(ptr, ());
	}
}

#[test] #[ignore]
fn test() {
	let mut proc = Proc::new(#[coroutine]|()|{
		let mut count = 0;
		loop {
			println!("{}", count);
			count += 1;
			yield;
		}
	});
	proc.advance_one_tick();
	proc.advance_one_tick();
	proc.advance_one_tick();
	proc.advance_one_tick();
	proc.advance_one_tick();
}

#[derive(Debug, Clone, Copy)]
struct ICacheExportItem {
	item: u32,
	addr: u32,
}

#[derive(Debug, Clone, Copy)]
struct ICacheBlock {
	items: [[u32;4];128],
	valid: bool,
	start: u32,
	end: u32
}

impl ICacheBlock {
	fn new() -> Self {
		ICacheBlock { items: [[0;_];_], valid: false, start: 0, end: 0 }
	}
}

fn decoder_impl(
	cache_rx: Receiver<ICacheExportItem>,
) -> impl Coroutine<(), Yield = (), Return = ()> {
	#[coroutine] move || {
		loop {
			if let Some(smth) = cache_rx.peek() {
				println!("{:?}", smth)
			}
			yield;
		}
	}
}

fn the_machine() {
	
	let (mem_chan_tx, mem_chan_rx) = chan::<ICacheExportItem>();
	
	let mut mem_man = Proc::new(#[coroutine] move |()|{
		const MEM_SIZE_BYTES: usize = 1024 * 8;
		const MEM_ALIGN: usize = 4096;
		let mem_ptr = unsafe { alloc(Layout::from_size_align_unchecked(MEM_SIZE_BYTES, MEM_ALIGN)) };
		let mem_ptr = mem_ptr.cast::<u32>();
		
		loop {
			if let Some(ptr) = mem_chan_rx.peek() {
				println!("{:?}", ptr);
			}
			yield;
		}
	});
	
	let (dec_1_tx, dec_1_rx) = chan::<ICacheExportItem>();
	let (dec_2_tx, dec_2_rx) = chan::<ICacheExportItem>();
	
	let mut insn_cache = Proc::new(#[coroutine] move |()|{
		
		// insn cache
		let icache : [ICacheBlock; 8] = [ICacheBlock::new();_];
		
		loop {
			
			yield;
		}
	});
	
	let mut decoder_1 = Proc::new(decoder_impl(
		dec_1_rx
	));
	
	let mut decoder_2 = Proc::new(decoder_impl(
		dec_2_rx
	));
	
	let mut selector = Proc::new(#[coroutine] move |()|{
		
		loop {
			
			yield;
		}
	});
	
	let mut backend = Proc::new(#[coroutine] move |()|{
		
		loop {
			
			yield;
		}
	});
	
	
	loop {
		mem_man.advance_one_tick();
		insn_cache.advance_one_tick();
		decoder_1.advance_one_tick();
		decoder_2.advance_one_tick();
		selector.advance_one_tick();
		backend.advance_one_tick();
	}
}


#[test]
fn test_() {
	the_machine();
}