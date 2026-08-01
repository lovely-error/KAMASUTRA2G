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
