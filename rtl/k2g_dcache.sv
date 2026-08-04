// Direct-mapped data cache: 8 KB, 128-byte lines, write-back, write-allocate.
//
//   core dbus --> k2g_dcache --> k2g_membus --> k2g_psram
//
// Same geometry as `k2g_icache` and for the same reason -- a line is one PSRAM
// command -- but three things make it a different module rather than a
// parameter on that one:
//
//   * it takes writes, with per-byte enables;
//   * a line can be DIRTY, so replacing it means writing it back first, and
//     that is a 32-beat write burst driven out of the data array;
//   * a store to a line it does not have must fetch that line first
//     (write-allocate), because a partial store into a line nobody fetched
//     would leave the other 31 words holding whatever the array had.
//
// ---- geometry ----
//
//   8 MB space          addr[22:0]
//   offset within line  addr[6:0]     128 bytes
//   index               addr[12:7]    64 lines
//   tag                 addr[22:13]   10 bits
//
// ---- the ordering rule, unchanged ----
//
// `k2g_membus` answers in request order, so nothing is accepted while a miss
// is being serviced -- `req_ready` is false for the whole writeback-and-fill
// sequence. A hit answered during that would arrive before the load that
// missed, and the core pairs answers with the oldest address outstanding.
//
// A miss is not accepted at all, exactly as in the instruction cache: the core
// holds the instruction in X until the bus takes it, so the same request is
// still being offered when the line lands, and it hits.
//
// ---- what is NOT here, and matters ----
//
// **There is no coherence with the instruction cache.** A store that lands on
// a line the I$ has cached is invisible to fetch. That is what `ICINVR` is
// for, and the ISA already reserves it (spec 3.2) -- but it has to CLEAN THIS
// CACHE over the range before invalidating the I$, because the newly written
// instructions may still be sitting dirty here. Until that exists,
// self-modifying code does not work, and there is no program in
// `emu/programs/` that tries.

`include "k2g_types.svh"

module k2g_dcache #(
    parameter int BYTES      = 8192,
    parameter int LINE_BYTES = 128
) (
    input logic clk,
    input logic rst_n,

    k2g_membus.slave  up,     // from the core's data port
    k2g_membus.master down,   // to memory

    // Write every dirty line back and invalidate the cache. Held high until
    // `flush_busy` rises, then released; the flush is over when it falls.
    //
    // This exists before `ICINVR` needs it because the lockstep cosimulation
    // needs it first: a write-back cache that still holds dirty lines when the
    // program stops has a memory image the emulator does not, and the memory
    // comparison at the end of `tb_cosim` would report a divergence that is
    // not one. `ICINVR` wants the same walk restricted to a range.
    input  logic flush_req,
    output logic flush_busy
);

  localparam int LINES  = BYTES / LINE_BYTES;      // 64
  localparam int WPL    = LINE_BYTES / 4;          // 32 words per line
  localparam int OFF_W  = $clog2(LINE_BYTES);      // 7
  localparam int IDX_W  = $clog2(LINES);           // 6
  localparam int ADDR_W = 23;                      // 8 MB of PSRAM
  localparam int TAG_W  = ADDR_W - OFF_W - IDX_W;  // 10

  // Named rather than written as `$clog2(...)` inside a part-select, which
  // makes GowinSynthesis exit 1 with an empty log (docs/bring-up.md).
  localparam int IDX_HI = OFF_W + IDX_W - 1;       // 12
  localparam int TAG_LO = OFF_W + IDX_W;           // 13

  logic [TAG_W-1:0] tags [0:LINES-1];
  logic [LINES-1:0] valid;
  logic [LINES-1:0] dirty;

  wire logic [IDX_W-1:0] req_idx = up.req.addr[IDX_HI:OFF_W];
  wire logic [TAG_W-1:0] req_tag = up.req.addr[ADDR_W-1:TAG_LO];

  wire logic is_store = (up.req.we != 4'b0000);
  wire logic hit      = up.req_valid && valid[req_idx] &&
                        (tags[req_idx] == req_tag);

  typedef enum logic [2:0] {
    S_IDLE, S_WB0, S_WB, S_FILL_REQ, S_FILL, S_FLUSH
  } state_e;

  state_e            state;
  logic [31:0]       wb_base;     // the OLD line's address, from the old tag
  logic [31:0]       fill_base;   // the new line's address
  logic [IDX_W-1:0]  fill_idx;
  logic [TAG_W-1:0]  fill_tag;
  logic [4:0]        pos;         // word within the line, both directions

  // A flush borrows the writeback path, so S_WB needs to know where to go
  // when it finishes: on to the fill for an ordinary miss, back to the scan
  // for a flush.
  logic              in_flush;
  logic [IDX_W-1:0]  fl_idx;

  assign flush_busy = in_flush;

  assign up.req_ready = (state == S_IDLE) && !flush_req && hit;

  wire logic take = up.req_valid && up.req_ready;

  // ---- data array ---------------------------------------------------------
  // Port A reads -- for a load hit, and for the writeback stream. Port B
  // writes -- for a store hit, with the core's own byte lanes, and for the
  // refill, with all four. Only one of the four ever happens at a time.
  logic [31:0] a_addr;
  logic        a_en;
  logic [31:0] a_data;
  logic [31:0] b_addr, b_wdata;
  logic [3:0]  b_we;
  logic        b_en;

  wire logic wb_beat   = (state == S_WB) && down.req_ready;
  wire logic fill_word = (state == S_FILL) && down.rsp_valid;

  always_comb begin
    // Reads: the core's address on a hit, otherwise the victim being streamed.
    // In S_WB the read only advances when the beat is taken, so `a_data` holds
    // the word still being offered -- `k2g_mem` port A latches only when
    // enabled, which is what makes that work.
    if (state == S_IDLE) begin
      a_addr = up.req.addr;
      a_en   = take && !is_store;
    end else if (state == S_WB0) begin
      a_addr = wb_base;
      a_en   = 1'b1;
    end else begin
      a_addr = wb_base | {25'd0, (pos + 5'd1), 2'b00};
      a_en   = wb_beat;
    end

    // Writes: a store hit, or a word of the refill.
    if (state == S_FILL) begin
      b_addr  = fill_base | {25'd0, pos, 2'b00};
      b_wdata = down.rsp_data;
      b_we    = fill_word ? 4'b1111 : 4'b0000;
      b_en    = fill_word;
    end else begin
      b_addr  = up.req.addr;
      b_wdata = up.req.wdata;
      b_we    = (take && is_store) ? up.req.we : 4'b0000;
      b_en    = take && is_store;
    end
  end

  k2g_mem #(.BYTES(BYTES)) u_data (
      .clk    (clk),
      .a_addr (a_addr),
      .a_en   (a_en),
      .a_data (a_data),
      .b_addr (b_addr),
      .b_en   (b_en),
      .b_we   (b_we),
      .b_wdata(b_wdata),
      .b_rdata()
  );

  // ---- the memory side ----------------------------------------------------
  // A writeback is one 32-beat write burst; the first beat carries the address
  // and the length and the rest carry only data (k2g_membus.sv). A fill is one
  // 32-word read burst.
  always_comb begin
    down.req_valid = (state == S_WB) || (state == S_FILL_REQ);
    if (state == S_WB) begin
      down.req.addr  = wb_base;
      down.req.we    = 4'b1111;
      down.req.wdata = a_data;
    end else begin
      down.req.addr  = fill_base;
      down.req.we    = 4'b0000;
      down.req.wdata = 32'd0;
    end
    down.req.len = 5'(WPL - 1);
  end

  // ---- response -----------------------------------------------------------
  // Loads only. A store produces none (k2g_membus.sv), and the core does not
  // wait for one.
  logic rsp_q;

  always_ff @(posedge clk) begin
    if (!rst_n) rsp_q <= 1'b0;
    else        rsp_q <= take && !is_store;
  end

  assign up.rsp_valid = rsp_q;
  assign up.rsp_data  = a_data;

  // ---- state --------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      valid     <= '0;
      dirty     <= '0;
      wb_base   <= 32'd0;
      fill_base <= 32'd0;
      in_flush  <= 1'b0;
      fl_idx    <= '0;
      fill_idx  <= '0;
      fill_tag  <= '0;
      pos       <= 5'd0;
    end else begin
      // A store that hits dirties its line, in the same cycle it is taken.
      if (take && is_store) dirty[req_idx] <= 1'b1;

      unique case (state)
        S_IDLE: if (flush_req) begin
          in_flush <= 1'b1;
          fl_idx   <= '0;
          state    <= S_FLUSH;
        end else if (up.req_valid && !hit) begin
          fill_base <= up.req.addr & ~32'h7F;
          fill_idx  <= req_idx;
          fill_tag  <= req_tag;
          pos       <= 5'd0;

          // THE VICTIM'S ADDRESS COMES FROM THE OLD TAG, not from the address
          // that missed. They share an index and nothing else, and writing a
          // dirty line back to the new address would destroy both lines.
          wb_base <= {{(32 - ADDR_W){1'b0}}, tags[req_idx], req_idx,
                      {OFF_W{1'b0}}};

          if (valid[req_idx] && dirty[req_idx]) begin
            state <= S_WB0;
          end else begin
            state <= S_FILL_REQ;
          end
          valid[req_idx] <= 1'b0;
        end

        // Every line in turn: write it back if it is dirty, then drop it.
        S_FLUSH: begin
          if (valid[fl_idx] && dirty[fl_idx]) begin
            wb_base  <= {{(32 - ADDR_W){1'b0}}, tags[fl_idx], fl_idx,
                         {OFF_W{1'b0}}};
            fill_idx <= fl_idx;
            pos      <= 5'd0;
            state    <= S_WB0;
          end else begin
            valid[fl_idx] <= 1'b0;
            if (fl_idx == IDX_W'(LINES - 1)) begin
              in_flush <= 1'b0;
              state    <= S_IDLE;
            end else begin
              fl_idx <= fl_idx + IDX_W'(1);
            end
          end
        end

        // One cycle to get word 0 of the victim out of the array before the
        // first beat has to present it.
        S_WB0: state <= S_WB;

        S_WB: if (down.req_ready) begin
          pos <= pos + 5'd1;
          if (pos == 5'(WPL - 1)) begin
            dirty[fill_idx] <= 1'b0;
            pos             <= 5'd0;
            if (in_flush) begin
              valid[fill_idx] <= 1'b0;
              if (fl_idx == IDX_W'(LINES - 1)) begin
                in_flush <= 1'b0;
                state    <= S_IDLE;
              end else begin
                fl_idx <= fl_idx + IDX_W'(1);
                state  <= S_FLUSH;
              end
            end else begin
              state <= S_FILL_REQ;
            end
          end
        end

        S_FILL_REQ: if (down.req_ready) state <= S_FILL;

        S_FILL: if (down.rsp_valid) begin
          pos <= pos + 5'd1;
          if (pos == 5'(WPL - 1)) begin
            tags[fill_idx]  <= fill_tag;
            valid[fill_idx] <= 1'b1;
            dirty[fill_idx] <= 1'b0;
            state           <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

`ifdef SIMULATION
  always_ff @(posedge clk) begin
    if (rst_n && up.req_valid && up.req_ready && (up.req.len != 5'd0))
      $error("k2g_dcache: burst request from the core");
    if (rst_n && down.rsp_valid && (state != S_FILL))
      $error("k2g_dcache: refill data with no refill in progress");
  end
`endif

endmodule
