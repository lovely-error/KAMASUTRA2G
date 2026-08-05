// ICINVR, turned into cache work and put in the right order.
//
// The core does not know what caches it has. It raises a request meaning "make
// everything I have stored visible to my own instruction fetch" and waits for
// `done`; this module is what that costs on a machine with a write-back data
// cache in front of an instruction cache.
//
// The host monitor raises the same request for a different reason -- a
// write-back cache holding dirty lines has a memory image the host would not
// see -- so there are two request ports. See the port list.
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

    // TWO REQUESTERS, and they are mutually exclusive by construction rather
    // than by arbitration.
    //
    // `a` is the core running ICINVR. `b` is the host monitor entering a pause,
    // which wants the same thing for a different reason: a write-back data
    // cache holding dirty lines has a memory image the host would not see.
    //
    // The monitor only asks once the core is quiet -- it holds fetch and waits
    // for `idle`, and a core with an ICINVR still outstanding is not idle -- so
    // the two can never overlap. The owner is latched anyway, because "cannot
    // happen" and "is not handled" are different claims and only one of them
    // survives someone changing the pause sequence.
    input  logic req_a,
    output logic done_a,
    input  logic req_b,
    output logic done_b,

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
  logic   owner;      // 0 = the core's ICINVR, 1 = the host monitor

  assign dflush_req = (state == S_D_START);
  assign iinval_req = (state == S_I_START);

  wire logic done = (state == S_DONE);
  assign done_a = done && !owner;
  assign done_b = done &&  owner;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE;
      owner <= 1'b0;
    end else begin
      unique case (state)
        // The core wins a simultaneous request, which cannot arise -- see the
        // port list -- and is the right way round if it ever did: the monitor
        // is waiting on a level it will re-offer, and an instruction is not.
        S_IDLE:    if (req_a || req_b) begin
          owner <= !req_a;
          state <= S_D_START;
        end

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
