// Direct-mapped instruction cache: 8 KB, 128-byte lines, read-only.
//
//   core ibus --> k2g_icache --> k2g_membus --> k2g_psram
//
// A line is 128 bytes because that is exactly one PSRAM command (16 user beats
// of 64 bits, 32 word addresses -- docs/bring-up.md, measured on hardware), so
// a refill is one bus transaction and one command rather than thirty-two.
// Before the bus grew a length field that would have cost about 211 core
// cycles instead of 7; see k2g_membus.sv.
//
// ---- geometry ----
//
//   8 MB space          addr[22:0]
//   offset within line  addr[6:0]     128 bytes
//   index               addr[12:7]    64 lines
//   tag                 addr[22:13]   10 bits
//
// ---- what makes it correct, and it is mostly one rule ----
//
// `k2g_membus` answers in request order, and a cache is where that is easy to
// break: answering a hit while an earlier miss is still being refilled would
// hand the core two responses in the wrong order, and the core pairs each
// answer with the oldest address it has outstanding -- so the code points and
// their addresses would swap. Every `isa` after that belongs to a different
// instruction than the code point beside it.
//
// The rule here is blunt: **while a line is being refilled, nothing is
// accepted.** `req_ready` is false, so there is no second request in flight to
// answer out of order. That costs throughput only during a miss, which is
// already forty-odd cycles of PSRAM.
//
// ---- a miss is not accepted at all ----
//
// The obvious design accepts the missing request, remembers it, and answers it
// when the refill lands. This does not: on a miss `req_ready` stays low and
// the core simply keeps offering the same address, because its `pc` does not
// advance until a request is taken. When the refill finishes, the same request
// is still there and hits.
//
// That removes the held-request register, the "answer from the refill stream"
// path and the state that goes with them, and costs one extra pass through the
// request path per miss -- one or two cycles against forty. It also means a
// redirect during a refill is handled by doing nothing: the core asks for
// somewhere else afterwards, and the line that was fetched is still cached.
//
// ---- tags are not all in flip-flops ----
//
// docs/v2-plan.md says "tags in flip-flops", and half of that is followed here.
// 64 entries of 10 bits is 640 flops, which is affordable -- but reading them
// by index is a 64-to-1 multiplexer ten bits wide, and LUTs are the binding
// constraint (76% before this module existed) while flops are at 30%.
//
// So the TAGS are an inferred distributed RAM, written synchronously and read
// combinationally, which is the shape Gowin maps to RAM16SDP4. The VALID bits
// stay flops, because they are the one thing that has to be cleared wholesale:
// reset must invalidate every line at once, and Phase 4's `ICINVR` will want
// to clear a range. A RAM cannot do either without a loop.

`include "k2g_types.svh"

module k2g_icache #(
    parameter int BYTES      = 8192,
    parameter int LINE_BYTES = 128
) (
    input logic clk,
    input logic rst_n,

    k2g_membus.slave  up,     // from the core's fetch port
    k2g_membus.master down,   // to memory

    // Drop every line, so the next fetch of anything comes from memory.
    // Driven by `k2g_cache_maint` for ICINVR (spec 3.2), AFTER the data cache
    // has written its dirty lines back -- the order is the whole point, and it
    // is enforced there rather than here.
    //
    // One cycle: the valid bits are flops and clear together. `busy` exists
    // only so the sequencer's handshake is the same shape as the data cache's,
    // which takes hundreds.
    input  logic inval_req,
    output logic inval_busy
);

  localparam int LINES  = BYTES / LINE_BYTES;      // 64
  localparam int WPL    = LINE_BYTES / 4;          // 32 words per line
  localparam int OFF_W  = $clog2(LINE_BYTES);      // 7
  localparam int IDX_W  = $clog2(LINES);           // 6
  localparam int ADDR_W = 23;                      // 8 MB of PSRAM
  localparam int TAG_W  = ADDR_W - OFF_W - IDX_W;  // 10

  // Part-selects use these localparams rather than `$clog2(...)` written
  // inline. That expression inside a part-select made GowinSynthesis exit 1
  // with an empty log and no banner (docs/bring-up.md).
  localparam int IDX_HI = OFF_W + IDX_W - 1;       // 12
  localparam int TAG_LO = OFF_W + IDX_W;           // 13

  logic [TAG_W-1:0] tags [0:LINES-1];
  logic [LINES-1:0] valid;

  wire logic [IDX_W-1:0] req_idx = up.req.addr[IDX_HI:OFF_W];
  wire logic [TAG_W-1:0] req_tag = up.req.addr[ADDR_W-1:TAG_LO];

  // Combinational, from a distributed-RAM read and a flop. A slave's
  // `req_ready` may look at `req_valid` (k2g_membus.sv); the master's
  // `req_valid` may not look back, so this is the safe direction.
  wire logic hit = up.req_valid && valid[req_idx] && (tags[req_idx] == req_tag);

  typedef enum logic [1:0] { S_IDLE, S_REQ, S_FILL } state_e;

  state_e            state;
  logic [31:0]       fill_base;
  logic [IDX_W-1:0]  fill_idx;
  logic [TAG_W-1:0]  fill_tag;
  logic [4:0]        fill_cnt;

  assign up.req_ready = (state == S_IDLE) && !inval_req && hit;

  // Never busy for longer than the cycle it is asked, because clearing 64 flops
  // takes one. Held to the request so a sequencer that waits for a rise sees
  // one.
  assign inval_busy = inval_req;

  assign down.req_valid = (state == S_REQ);
  assign down.req.addr  = fill_base;
  assign down.req.len   = 5'(WPL - 1);
  assign down.req.we    = 4'b0000;
  assign down.req.wdata = 32'd0;

  // ---- data array ---------------------------------------------------------
  // `k2g_mem` unchanged: four byte lanes, one BSRAM block each, instantiated
  // rather than inferred. That shape exists because Gowin BSRAM has no
  // per-byte write enables, and it is exactly what a cache data array needs --
  // which is why the plan said to reuse it rather than write another one. At
  // 8 KB it is four blocks and the index it takes, `addr[12:2]`, is precisely
  // this cache's window into an address.
  //
  // Port A reads for the core, port B is written by the refill. They never
  // overlap: nothing is accepted while a line is filling.
  wire logic [31:0] fill_addr = fill_base | {25'd0, fill_cnt, 2'b00};

  wire logic        take     = up.req_valid && up.req_ready;
  wire logic        fill_we  = (state == S_FILL) && down.rsp_valid;
  wire logic [31:0] rd_word;

  k2g_mem #(.BYTES(BYTES)) u_data (
      .clk    (clk),
      .a_addr (up.req.addr),
      .a_en   (take),
      .a_data (rd_word),
      .b_addr (fill_addr),
      .b_en   (fill_we),
      .b_we   (fill_we ? 4'b1111 : 4'b0000),
      .b_wdata(down.rsp_data),
      .b_rdata()
  );

  // ---- response -----------------------------------------------------------
  // One cycle after acceptance, which is the same latency the BSRAM port had
  // before any of this. A hit costs exactly what memory used to.
  logic rsp_q;

  always_ff @(posedge clk) begin
    if (!rst_n) rsp_q <= 1'b0;
    else        rsp_q <= take;
  end

  assign up.rsp_valid = rsp_q;
  assign up.rsp_data  = rd_word;

  // ---- refill -------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      valid     <= '0;
      fill_base <= 32'd0;
      fill_idx  <= '0;
      fill_tag  <= '0;
      fill_cnt  <= 5'd0;
    end else begin
      unique case (state)
        S_IDLE: if (inval_req) begin
          valid <= '0;
        end else if (up.req_valid && !hit) begin
          // REDUNDANT, and kept deliberately. Nothing can read this line while
          // it fills -- `req_ready` is false for the whole refill, which is
          // what actually makes the window safe -- and a reset mid-refill
          // clears every valid bit anyway. So no test can distinguish this
          // line being here from it being absent, and there is no mutant for
          // it.
          //
          // It is here because "the data has been replaced and the tag has
          // not" is the state a direct-mapped cache must never be observable
          // in, and one line that costs nothing is cheaper than having to
          // re-derive that `req_ready` covers it every time this state machine
          // is edited.
          valid[req_idx] <= 1'b0;
          fill_base      <= up.req.addr & ~32'h7F;
          fill_idx       <= req_idx;
          fill_tag       <= req_tag;
          fill_cnt       <= 5'd0;
          state          <= S_REQ;
        end

        S_REQ: if (down.req_ready) state <= S_FILL;

        S_FILL: if (down.rsp_valid) begin
          fill_cnt <= fill_cnt + 5'd1;
          if (fill_cnt == 5'(WPL - 1)) begin
            tags[fill_idx]  <= fill_tag;
            valid[fill_idx] <= 1'b1;
            state           <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

`ifdef SIMULATION
  // The core does not burst; the cache does. If that ever stops being true the
  // response ordering below is wrong in a way nothing else here would catch.
  always_ff @(posedge clk) begin
    if (rst_n && up.req_valid && up.req_ready && (up.req.len != 5'd0))
      $error("k2g_icache: burst request from the core");
    if (rst_n && up.req_valid && up.req_ready && (up.req.we != 4'b0000))
      $error("k2g_icache: write on the fetch port");
    if (rst_n && down.rsp_valid && (state != S_FILL))
      $error("k2g_icache: refill data with no refill in progress");
  end
`endif

endmodule
