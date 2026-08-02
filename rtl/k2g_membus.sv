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
// ---- the fetch port is 16 bits wide ----
//
// `rsp_data` is 32 bits, but a response to the INSTRUCTION port carries a code
// point in bits [15:0] and nothing above them. That is not a property of this
// interface -- it is a property of the fetch port, and it has always been true:
// `k2g_mem` port A is a halfword port and selects by address bit 1, and
// `k2g_core` reads `ibus.rsp_data[15:0]` directly.
//
// Written down here because it stopped being free. While the only slave was a
// thin bridge over `k2g_mem` the select came for nothing; `k2g_psram` has to
// carry the request's bit 1 across a clock domain to do the same job, and the
// Phase 4 I-cache will have to do it too. The alternative -- respond with
// the word and let the core's fetch unit select, which already keeps
// `issue_addr` beside every outstanding request -- is tidier and is worth
// taking when Phase 4 touches both ends anyway.
//
// ---- a beat is not a transaction ----
//
// This bus deliberately carries ONE BEAT per request. It has no burst length,
// and a multi-beat transfer is a run of separate requests.
//
// That matters because a cache line fill is 64 bytes -- one PSRAM command
// which then streams its beats -- and as far as this bus is concerned that
// arrives as sixteen ordinary requests with nothing marking them as one
// thing. Nothing here enforces their atomicity.
//
// So the master issuing them must hold the bus for the whole run: a refill
// takes a "burst in progress" lock and no other master may interleave a
// request into the middle of it. A line half-filled from one address and half
// from another is not detectable after the fact -- it just answers wrong
// forever, from a tag that says it is valid.
//
// The alternative was a length field, making a burst one transaction. It was
// weighed and not taken: it puts beat-counting into every slave including the
// trivial BSRAM one, where a lock puts it only in the two masters that
// actually burst.

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
