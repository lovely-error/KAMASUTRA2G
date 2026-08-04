// K2G memory bus: a request channel out, a response stream back.
//
// Everything that answers a memory access speaks this, so the core can be
// written once and then have an instruction cache, a data cache and 8 MB of
// PSRAM slid in behind it without being touched again. That is the whole
// reason it exists before any of those do.
//
// ---- responses are unconditional and in order ----
//
// There is no `rsp_ready`. A master must be able to accept every response it
// asked for, and it controls that by limiting how many requests it leaves
// outstanding -- credit, rather than backpressure.
//
// The alternative puts a buffer inside every slave so it can hold a response
// the master is not ready for. The slaves here are caches whose entire job is
// to be small on a part that is already at 55% of its LUTs, and a response
// buffer in each of them is the wrong place to spend that. Making the master
// count instead costs one small counter in one place.
//
// A write produces no response. Nothing in this ISA reads the result of a
// store, and a write acknowledgement would only exist to be counted.
//
// ---- ordering ----
//
// Responses come back in request order. A cache that could answer a hit while
// an earlier miss is still outstanding would break that, so it must not --
// which is a real constraint on the Phase 3 design and is written here rather
// than discovered there.
//
// ---- every response is a 32-bit word ----
//
// Both ports get words. The fetch port used to get a code point in
// `rsp_data[15:0]` and nothing above it, because `k2g_mem` port A was a
// halfword port that selected by address bit 1 -- so whatever answered fetch
// had to keep doing that, and `k2g_psram` was carrying the request's bit 1
// across a clock domain for no other reason.
//
// The select now lives in the core's fetch unit, which already keeps
// `issue_addr` beside every outstanding request and so has the bit for free.
// That makes the two ports identical, which is what lets an instruction cache
// be an ordinary master here: a refill wants words, not halfwords.
//
// ---- a burst is one transaction ----
//
// `len` is beats minus one. A single-word access is `len == 0`; a 128-byte
// cache line is `len == 31`, and that is exactly one PSRAM command.
//
// THIS REPLACED A BUS LOCK, and the reversal is worth recording because the
// original reasoning was sound when it was written. This bus used to carry one
// beat per request with no length at all, and a line fill was a run of
// separate requests held together by a "burst in progress" lock -- a length
// field was weighed and rejected because it "puts beat-counting into every
// slave including the trivial BSRAM one".
//
// Two things then happened. The trivial BSRAM slave was deleted, so the only
// slave left is `k2g_psram`, which already counts sixteen beats internally.
// And that slave turned out to cost 6.6 core cycles per request -- every
// request becomes its own PSRAM command with a 32-cycle minimum interval --
// so a 32-request line fill would have cost about 211 cycles against the 7 of
// the single burst the line was sized to match. The rejected option became
// free at the same time the accepted one became thirty times too slow.
//
// The lock is gone rather than replaced: a burst is one transaction again, so
// its atomicity is a property of the request instead of a convention. A slave
// knows how many beats to expect and can check, where before a miscount was
// undetectable -- a line half-filled from two addresses answers wrong forever,
// from a tag that says it is valid.
//
// Rules:
//
//   * a burst must not cross a 128-byte boundary. One request, one PSRAM
//     command; the slave asserts on this rather than silently wrapping.
//   * a READ burst is one request and `len+1` responses, in order, for
//     `addr`, `addr+4`, ... The master's credit must cover all of them.
//   * a WRITE burst occupies the request channel for `len+1` accepted beats.
//     The first carries `addr`, `we`, `len` and the first word; the rest carry
//     only `wdata` and the other fields are ignored. An arbiter must hold the
//     grant for the whole run -- which is what the lock used to be for, except
//     that now the length says how long the run is.
//   * `we` applies to every beat of a write burst. A line writeback opens all
//     four lanes; there is no per-beat mask.

interface k2g_membus;

  import k2g_types::*;

  // Request channel. `valid`/`ready` per the rules in k2g_chan.sv -- in
  // particular, a slave's `req_ready` may look at `req_valid`, but a master's
  // `req_valid` must not look at `req_ready`.
  logic     req_valid;
  logic     req_ready;
  mem_req_t req;

  // Response stream. `rsp_valid` for one cycle per outstanding read, in order.
  logic        rsp_valid;
  logic [31:0] rsp_data;

  modport master (
      output req_valid, output req, input req_ready,
      input  rsp_valid, input  rsp_data
  );

  modport slave (
      input  req_valid, input  req, output req_ready,
      output rsp_valid, output rsp_data
  );

  // For assertions and testbenches watching without taking part.
  modport mon (
      input req_valid, input req, input req_ready,
      input rsp_valid, input rsp_data
  );

endinterface
