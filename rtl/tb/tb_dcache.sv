// The data cache against a memory model, directly.
//
// `tb_cosim` runs it in the real load/store path and proves it architecturally
// invisible; that cannot tell a hit from a miss, and it cannot see whether a
// dirty line ever reached memory -- a write-back cache that never wrote back
// would pass every architectural comparison right up until the line was
// evicted, and by then the program has moved on.
//
// So this is where the write-back path is actually checked, by reading memory
// behind the cache's back:
//
//   * a cold load is one read transaction of 32 words, and the other 31 words
//     of the line then hit with no bus traffic at all;
//   * a store hits, and the value comes back on a later load without any bus
//     traffic -- the store stayed in the cache, which is what write-back means;
//   * a byte store writes one byte and leaves the other three, which is the
//     part that has per-lane enables all the way down to the BSRAM;
//   * MEMORY DOES NOT SEE THE STORE until the line is evicted. That is the
//     defining property and the one a write-through cache would fail;
//   * evicting a dirty line writes exactly 32 beats, and afterwards memory
//     holds the modified words -- checked word by word, not just the first;
//   * evicting a CLEAN line writes nothing;
//   * refetching an evicted line brings the modified data back.

`include "k2g_types.svh"

module tb_dcache;

  localparam int BYTES      = 8192;
  localparam int LINE_BYTES = 128;
  localparam int WPL        = LINE_BYTES / 4;      // 32

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  k2g_membus up ();
  k2g_membus dn ();

  logic flush_req = 1'b0;
  logic flush_busy;

  k2g_dcache #(.BYTES(BYTES), .LINE_BYTES(LINE_BYTES)) dut (
      .clk(clk), .rst_n(rst_n), .up(up), .down(dn),
      .flush_req(flush_req), .flush_busy(flush_busy)
  );

  task automatic flush();
    int n;
    flush_req = 1'b1;
    n = 0;
    while (!flush_busy && n < 1000) begin @(posedge clk); n++; end
    flush_req = 1'b0;
    while (flush_busy && n < 100000) begin @(posedge clk); n++; end
    if (n >= 100000) fail("the flush never finished");
  endtask

  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic        mem_en;
  logic [3:0]  mem_we;
  int unsigned max_latency = 5;

  k2g_mem_slow u_slow (
      .clk(clk), .rst_n(rst_n), .max_latency(max_latency), .bus(dn),
      .b_addr(mem_addr), .b_en(mem_en), .b_we(mem_we),
      .b_wdata(mem_wdata), .b_rdata(mem_rdata)
  );

  k2g_mem #(.BYTES(1024 * 1024)) u_mem (
      .clk(clk), .a_addr(32'd0), .a_en(1'b0), .a_data(),
      .b_addr(mem_addr), .b_en(mem_en), .b_we(mem_we),
      .b_wdata(mem_wdata), .b_rdata(mem_rdata)
  );

  // ---- bus-side instrumentation ------------------------------------------
  // A read burst is one accepted request; a write burst is 32 accepted beats,
  // because that is where a write burst's data rides (k2g_membus.sv).
  int rd_reqs  = 0;
  int rd_words = 0;
  int wr_beats = 0;

  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (dn.req_valid && dn.req_ready) begin
        if (dn.req.we == 4'b0000) rd_reqs++;
        else                      wr_beats++;
      end
      if (dn.rsp_valid) rd_words++;
    end
  end

  int outstanding     = 0;
  int max_outstanding = 0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      outstanding <= 0;
    end else begin
      outstanding <= outstanding + ((up.req_valid && up.req_ready &&
                                     up.req.we == 4'b0000) ? 1 : 0)
                                 - (up.rsp_valid ? 1 : 0);
      if (outstanding > max_outstanding) max_outstanding <= outstanding;
    end
  end

  // ---- scoreboard ---------------------------------------------------------
  int checks = 0;
  int errors = 0;

  task automatic fail(input string msg);
    $display("TB_FAIL tb_dcache: %s", msg);
    errors++;
  endtask

  task automatic expect_eq(input string what, input logic [31:0] got,
                           input logic [31:0] want);
    checks++;
    if (got !== want)
      fail($sformatf("%s: expected %08x, got %08x", what, want, got));
  endtask

  // Straight into the memory array, behind the cache. This is what makes
  // "memory has not seen the store yet" checkable at all.
  function automatic logic [31:0] mem_word(input logic [31:0] a);
    return {u_mem.peek_byte(int'(a) + 3), u_mem.peek_byte(int'(a) + 2),
            u_mem.peek_byte(int'(a) + 1), u_mem.peek_byte(int'(a) + 0)};
  endfunction

  task automatic load_word(input logic [31:0] a, input logic [31:0] d);
    u_mem.load_byte(int'(a) + 0, d[7:0]);
    u_mem.load_byte(int'(a) + 1, d[15:8]);
    u_mem.load_byte(int'(a) + 2, d[23:16]);
    u_mem.load_byte(int'(a) + 3, d[31:24]);
  endtask

  // ---- driving the core side ---------------------------------------------
  task automatic access(input logic [31:0] a, input logic [3:0] we,
                        input logic [31:0] wd, output logic [31:0] rd);
    int n;
    up.req_valid = 1'b1;
    up.req.addr  = a;
    up.req.len   = 5'd0;
    up.req.we    = we;
    up.req.wdata = wd;
    n = 0;
    forever begin
      @(posedge clk);
      n++;
      if (up.req_ready) break;
      if (n > 100000) begin
        fail($sformatf("access to %08x was never accepted", a));
        break;
      end
    end
    up.req_valid = 1'b0;
    rd = 32'hxxxx_xxxx;
    if (we == 4'b0000) begin
      forever begin
        @(posedge clk);
        n++;
        if (up.rsp_valid) break;
        if (n > 100000) begin
          fail($sformatf("load of %08x was never answered", a));
          break;
        end
      end
      rd = up.rsp_data;
    end
  endtask

  task automatic ld(input logic [31:0] a, output logic [31:0] d);
    access(a, 4'b0000, 32'd0, d);
  endtask

  task automatic st(input logic [31:0] a, input logic [3:0] we,
                    input logic [31:0] d);
    logic [31:0] junk;
    access(a, we, d, junk);
  endtask

  function automatic logic [31:0] pattern(input logic [31:0] a);
    return {~a[15:0], a[15:0]} ^ 32'h1234_5678;
  endfunction

  // ---- the run ------------------------------------------------------------
  localparam logic [31:0] L0 = 32'h0000_2000;   // line-aligned
  localparam logic [31:0] LC = 32'h0000_4000;   // same index, different tag

  int i;
  int r0, w0, b0;
  logic [31:0] d;

  initial begin
    up.req_valid = 1'b0;
    up.req       = '0;

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    for (i = 0; i < WPL; i++) begin
      load_word(L0 + 32'(4 * i), pattern(L0 + 32'(4 * i)));
      load_word(LC + 32'(4 * i), pattern(LC + 32'(4 * i)));
    end

    // ---- a cold load is one transaction, and no writeback ----
    r0 = rd_reqs; w0 = rd_words; b0 = wr_beats;
    ld(L0, d);
    expect_eq("cold load", d, pattern(L0));
    checks++;
    if ((rd_reqs - r0) != 1)
      fail($sformatf("a fill took %0d read requests, want 1", rd_reqs - r0));
    checks++;
    if ((rd_words - w0) != WPL)
      fail($sformatf("a fill brought %0d words, want %0d", rd_words - w0, WPL));
    checks++;
    if (wr_beats != b0)
      fail("an empty line was written back");

    // ---- the rest of the line is free ----
    r0 = rd_reqs;
    for (i = 1; i < WPL; i++) begin
      ld(L0 + 32'(4 * i), d);
      expect_eq($sformatf("hit at word %0d", i), d, pattern(L0 + 32'(4 * i)));
    end
    checks++;
    if (rd_reqs != r0) fail("hits went to the bus");

    // ---- a store stays in the cache ----
    r0 = rd_reqs; b0 = wr_beats;
    st(L0 + 32'd8, 4'b1111, 32'hDEAD_BEEF);
    ld(L0 + 32'd8, d);
    expect_eq("store then load", d, 32'hDEAD_BEEF);
    checks++;
    if (rd_reqs != r0 || wr_beats != b0)
      fail("a store to a cached line went to the bus");

    // ---- and memory has NOT seen it ----
    // The defining property of write-back. A write-through cache passes every
    // other check in this file and fails this one.
    checks++;
    if (mem_word(L0 + 32'd8) !== pattern(L0 + 32'd8))
      fail($sformatf("memory already holds %08x -- the store was written through",
                     mem_word(L0 + 32'd8)));

    // ---- byte lanes ----
    st(L0 + 32'd16, 4'b1111, 32'h1122_3344);
    st(L0 + 32'd16, 4'b0010, 32'h0000_9900);
    ld(L0 + 32'd16, d);
    expect_eq("byte store leaves its neighbours", d, 32'h1122_9944);

    st(L0 + 32'd20, 4'b1111, 32'hAABB_CCDD);
    st(L0 + 32'd20, 4'b1100, 32'h5566_0000);
    ld(L0 + 32'd20, d);
    expect_eq("halfword store", d, 32'h5566_CCDD);

    // ---- evicting the dirty line writes it back, all of it ----
    b0 = wr_beats; r0 = rd_reqs;
    ld(LC, d);
    expect_eq("conflicting line loads", d, pattern(LC));

    checks++;
    if ((wr_beats - b0) != WPL)
      fail($sformatf("the writeback was %0d beats, want %0d", wr_beats - b0, WPL));
    checks++;
    if ((rd_reqs - r0) != 1)
      fail("the conflict did not fill exactly once");

    // Every word of the evicted line, in memory, including the ones that were
    // never stored to -- a writeback that only wrote the dirty words would
    // leave the rest holding whatever the array had.
    checks++;
    if (mem_word(L0 + 32'd8) !== 32'hDEAD_BEEF)
      fail($sformatf("evicted word 2 is %08x in memory", mem_word(L0 + 32'd8)));
    checks++;
    if (mem_word(L0 + 32'd16) !== 32'h1122_9944)
      fail($sformatf("evicted word 4 is %08x in memory", mem_word(L0 + 32'd16)));
    checks++;
    if (mem_word(L0 + 32'd20) !== 32'h5566_CCDD)
      fail($sformatf("evicted word 5 is %08x in memory", mem_word(L0 + 32'd20)));
    for (i = 0; i < WPL; i++) begin
      if ((i != 2) && (i != 4) && (i != 5)) begin
        checks++;
        if (mem_word(L0 + 32'(4 * i)) !== pattern(L0 + 32'(4 * i)))
          fail($sformatf("evicted word %0d changed: %08x", i,
                         mem_word(L0 + 32'(4 * i))));
      end
    end

    // ---- evicting a CLEAN line writes nothing ----
    b0 = wr_beats;
    ld(L0, d);
    expect_eq("refetched line keeps the stores", d, pattern(L0));
    checks++;
    if (wr_beats != b0)
      fail($sformatf("%0d beats written back for a clean line", wr_beats - b0));

    // ---- and the stores survived the round trip ----
    ld(L0 + 32'd8, d);
    expect_eq("stored word survived eviction", d, 32'hDEAD_BEEF);
    ld(L0 + 32'd16, d);
    expect_eq("byte-stored word survived", d, 32'h1122_9944);

    // ---- flush writes every dirty line back ----
    // The cosimulation depends on this: a write-back cache still holding dirty
    // lines when the program stops has a memory image the emulator does not.
    st(L0 + 32'd40, 4'b1111, 32'hFACE_0001);
    st(L0 + 32'd44, 4'b1111, 32'hFACE_0002);
    checks++;
    if (mem_word(L0 + 32'd40) === 32'hFACE_0001)
      fail("the store reached memory without a flush");

    b0 = wr_beats;
    flush();
    checks++;
    if ((wr_beats - b0) != WPL)
      fail($sformatf("the flush wrote %0d beats, want %0d", wr_beats - b0, WPL));
    checks++;
    if (mem_word(L0 + 32'd40) !== 32'hFACE_0001)
      fail($sformatf("after the flush memory holds %08x", mem_word(L0 + 32'd40)));
    checks++;
    if (mem_word(L0 + 32'd44) !== 32'hFACE_0002)
      fail($sformatf("after the flush memory holds %08x", mem_word(L0 + 32'd44)));

    // Flushing an already-clean cache writes nothing and still terminates.
    b0 = wr_beats;
    flush();
    checks++;
    if (wr_beats != b0)
      fail($sformatf("a second flush wrote %0d beats", wr_beats - b0));

    // And the cache is empty afterwards, so the next access refills.
    r0 = rd_reqs;
    ld(L0 + 32'd40, d);
    expect_eq("after a flush the line refills", d, 32'hFACE_0001);
    checks++;
    if ((rd_reqs - r0) != 1) fail("the flush did not invalidate");

    // ---- never two loads in flight ----
    checks++;
    if (max_outstanding > 1)
      fail($sformatf("%0d loads in flight at once -- a hit could overtake a miss",
                     max_outstanding));

    $display("  %0d fills, %0d words in, %0d beats out", rd_reqs, rd_words, wr_beats);
    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("TB_PASS tb_dcache");
    else             $display("TB_FAIL tb_dcache: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TB_FAIL tb_dcache: timeout");
    $finish;
  end

endmodule
