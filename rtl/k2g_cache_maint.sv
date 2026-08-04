// ICINVR, turned into cache work and put in the right order.
//
// The core does not know what caches it has. It raises `req` meaning "make
// everything I have stored visible to my own instruction fetch" and waits for
// `done`; this module is what that costs on a machine with a write-back data
// cache in front of an instruction cache.
//
// ---- the order is the whole instruction ----
//
// Spec 3.2 calls ICINVR an "instruction-cache range invalidate", and doing
// only that is not enough to make self-modifying code work. The instructions
// that were just written are sitting DIRTY IN THE DATA CACHE. Invalidate the
// I-cache first and it refills from memory, which does not have them yet, and
// the machine executes the old bytes -- with every architectural check passing,
// because both caches did exactly what they were told.
//
// So: **clean the data cache, wait for it to finish, and only then invalidate
// the instruction cache.** Each step is a level handshake with the cache that
// performs it, and the second does not start until the first has fallen.
//
// ---- the range is ignored, deliberately ----
//
// ICINVR names a range in two registers. This acts on both caches in their
// entirety instead, which is always safe: cleaning or dropping more than was
// asked cannot lose data, it only costs time. That keeps the walk out of both
// caches, which matters on a part at 89% utilization, and ICINVR is rare --
// it appears once per run of self-modifying code, not in a loop.
//
// The cost is bounded and small: 64 lines, each at most one 32-beat writeback,
// so a few thousand cycles worst case with everything dirty, and one cycle for
// the invalidate.
//
// Narrowing to the real range later is a change here and in the two caches,
// and is invisible to software -- which is why spec 3.2 is worded to permit a
// superset rather than to require one.

module k2g_cache_maint (
    input  logic clk,
    input  logic rst_n,

    // From the core: one pulse-or-level request, held until `done`.
    input  logic req,
    output logic done,

    // To the data cache: write every dirty line back, then invalidate.
    output logic dflush_req,
    input  logic dflush_busy,

    // To the instruction cache: drop every line.
    output logic iinval_req,
    input  logic iinval_busy
);

  typedef enum logic [2:0] {
    S_IDLE,       // waiting for a request
    S_D_START,    // asking the data cache, waiting for it to admit it is busy
    S_D_WAIT,     // data cache working
    S_I_START,    // asking the instruction cache
    S_I_WAIT,     // instruction cache working
    S_DONE        // one cycle of `done`, so the core sees an edge
  } state_e;

  state_e state;

  assign dflush_req = (state == S_D_START);
  assign iinval_req = (state == S_I_START);
  assign done       = (state == S_DONE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE;
    end else begin
      unique case (state)
        S_IDLE:    if (req)            state <= S_D_START;

        // Two-phase on each cache: assert until it says busy, then release and
        // wait for busy to fall. A one-shot request would race a cache that
        // takes a cycle to notice, and a level held to completion would need
        // the cache to distinguish "still asked" from "asked again".
        S_D_START: if (dflush_busy)    state <= S_D_WAIT;
        S_D_WAIT:  if (!dflush_busy)   state <= S_I_START;

        S_I_START: if (iinval_busy)    state <= S_I_WAIT;
        S_I_WAIT:  if (!iinval_busy)   state <= S_DONE;

        S_DONE:                        state <= S_IDLE;

        default:                       state <= S_IDLE;
      endcase
    end
  end

endmodule
