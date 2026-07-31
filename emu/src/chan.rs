use core::mem::MaybeUninit;
use core::sync::atomic::{AtomicUsize, Ordering};
use std::alloc::Layout;

#[repr(align(64))]
struct AlignAtomic<T>(T);

struct Chan<T> {
	items: MaybeUninit<[T;2]>,
	sender_ix: AlignAtomic<AtomicUsize>,
	reciever_ix: AlignAtomic<AtomicUsize>,
}

impl <T> Chan<T> {
	fn init() -> Self {
		Chan { 
			items: MaybeUninit::uninit(), 
			sender_ix: AlignAtomic(AtomicUsize::new(0)), 
			reciever_ix: AlignAtomic(AtomicUsize::new(0))
		}
	}
}

pub struct Sender<T> {
	ptr: *mut Chan<T>,
}
impl <T> Sender<T> {
	pub fn try_send(&self, item:T) -> bool {
		let inner = unsafe { &mut *self.ptr };
		let rix = inner.reciever_ix.0.load(Ordering::Acquire);
		let six = inner.sender_ix.0.load(Ordering::Relaxed);
		let has_space = six == rix;
		if !has_space { return false }
		let next = (six + 1) % 2;
		unsafe{ inner.items.assume_init_mut().as_mut_ptr().add(six).write(item) };
		inner.sender_ix.0.store(next, Ordering::Release);
		return true
	}
}
pub struct Receiver<T> {
	ptr: *mut Chan<T>
}
impl <T> Receiver<T> {
	pub fn peek(&self) -> Option<T> {
		let inner = unsafe { &mut *self.ptr };
		let six = inner.sender_ix.0.load(Ordering::Acquire);
		let rix = inner.reciever_ix.0.load(Ordering::Relaxed);
		let has_item = six != rix;
		if !has_item { return None }
		let item = unsafe { inner.items.assume_init_mut().as_ptr().add(rix).read() };
		return Some(item)
	}
	pub fn drop(&self) {
		let inner = unsafe { &mut *self.ptr };
		let six = inner.sender_ix.0.load(Ordering::Relaxed);
		let rix = inner.reciever_ix.0.load(Ordering::Relaxed);
		let has_item = six != rix;
		if !has_item { return }
		let next = (six + 1) % 2;
		inner.reciever_ix.0.store(next, Ordering::Release);
	}
}

pub fn chan<T>() -> (Sender<T>, Receiver<T>) {
	let chan = unsafe { std::alloc::alloc(Layout::new::<Chan<T>>()) };
	let chan = chan.cast::<Chan<T>>();
	unsafe { chan.write(Chan::init()) };
	let snd = Sender {
		ptr: chan
	};
	let rcv = Receiver {
		ptr: chan
	};
	(snd, rcv)
}