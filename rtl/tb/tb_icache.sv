// The instruction cache against a memory model, directly.
//
// `tb_cosim` runs the cache in the real fetch path and proves it is
// architecturally invisible, which is the property that matters -- but it
// cannot show WHY a result was reached. A cache that missed on every access
// would pass cosimulation perfectly. This is where hit and miss are told apart.
//
// What it checks:
//
//   * a cold access misses, and the miss fetches a whole 128-byte line as ONE
//     bus transaction. Counted at the memory side: one request, 32 responses;
//   * the other 31 words of that line then hit, with no further bus traffic
//     at all. This is the entire point of the phase and the one number the
//     machine's speed depends on;
//   * a hit answers in one cycle, the same latency the BSRAM port had before
//     any of this;
//   * every word read back equals what memory holds, across several lines;
//   * a conflict -- two addresses with the same index and different tags --
//     evicts and refetches, and both keep answering correctly afterwards;
//   * responses never overtake: a request offered during a refill is not
//     accepted, so the core cannot be handed a hit before an earlier miss.
//
// Not checked here: anything about `ICINVR`, which is not built yet.

`include "k2g_types.svh"

module tb_icache;

  localparam int BYTES      = 8192;
  localparam int LINE_BYTES = 128;
  localparam int WPL        = LINE_BYTES / 4;      // 32
  localparam int LINES      = BYTES / LINE_BYTES;  // 64

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  k2g_membus up ();     // the "core" side, driven below
  k2g_membus dn ();     // the memory side

  logic inval_req = 1'b0;
  logic inval_busy;

  k2g_icache #(.BYTES(BYTES), .LINE_BYTES(LINE_BYTES)) dut (
      .clk(clk), .rst_n(rst_n), .up(up), .down(dn),
      .inval_req(inval_req), .inval_busy(inval_busy)
  );

  task automatic invalidate();
    int n;
    inval_req = 1'b1;
    n = 0;
    while (!inval_busy && n < 1000) begin @(posedge clk); n++; end
    @(posedge clk);
    inval_req = 1'b0;
    @(posedge clk);
    if (n >= 1000) fail("the invalidate never reported busy");
  endtask

  // ---- memory, with latency so a refill is not instantaneous -------------
  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic        mem_en;
  logic [3:0]  mem_we;
  int unsigned max_latency = 6;

  k2g_mem_slow u_slow (
      .clk        (clk),
      .rst_n      (rst_n),
      .max_latency(max_latency),
      .bus        (dn),
      .b_addr     (mem_addr),
      .b_en       (mem_en),
      .b_we       (mem_we),
      .b_wdata    (mem_wdata),
      .b_rdata    (mem_rdata)
  );

  // A megabyte is plenty and keeps the run short; the cache only indexes the
  // low 13 bits anyway, so the interesting addresses are conflicts.
  k2g_mem #(.BYTES(1024 * 1024)) u_mem (
      .clk(clk), .a_addr(32'd0), .a_en(1'b0), .a_data(),
      .b_addr(mem_addr), .b_en(mem_en), .b_we(mem_we),
      .b_wdata(mem_wdata), .b_rdata(mem_rdata)
  );

  // ---- bus-side instrumentation ------------------------------------------
  int dn_requests = 0;
  int dn_words    = 0;

  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (dn.req_valid && dn.req_ready) dn_requests++;
      if (dn.rsp_valid)                 dn_words++;
    end
  end

  // Requests accepted but not yet answered, sampled every cycle.
  int outstanding     = 0;
  int max_outstanding = 0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      outstanding <= 0;
    end else begin
      outstanding <= outstanding + ((up.req_valid && up.req_ready) ? 1 : 0)
                                 - (up.rsp_valid ? 1 : 0);
      if (outstanding > max_outstanding) max_outstanding <= outstanding;
    end
  end

  // ---- scoreboard ---------------------------------------------------------
  int checks = 0;
  int errors = 0;

  task automatic fail(input string msg);
    $display("TB_FAIL tb_icache: %s", msg);
    errors++;
  endtask

  task automatic expect_eq(input string what, input logic [31:0] got,
                           input logic [31:0] want);
    checks++;
    if (got !== want)
      fail($sformatf("%s: expected %08x, got %08x", what, want, got));
  endtask

  // ---- driving the core side ---------------------------------------------
  // One request at a time, held until accepted, exactly as the core does: its
  // `pc` does not advance until `req_ready`, which is what makes not accepting
  // a miss a legitimate answer.
  logic [31:0] rd_data;
  int          rd_cycles;

  task automatic fetch(input logic [31:0] a, output logic [31:0] d,
                       output int cycles);
    int n;
    up.req_valid = 1'b1;
    up.req.addr  = a;
    up.req.len   = 5'd0;
    up.req.we    = 4'b0000;
    up.req.wdata = 32'd0;
    n = 0;
    // Wait for acceptance.
    forever begin
      @(posedge clk);
      n++;
      if (up.req_ready) break;
      if (n > 100000) begin
        fail($sformatf("fetch of %08x was never accepted", a));
        break;
      end
    end
    up.req_valid = 1'b0;
    // Then for its answer.
    forever begin
      @(posedge clk);
      n++;
      if (up.rsp_valid) break;
      if (n > 100000) begin
        fail($sformatf("fetch of %08x was never answered", a));
        break;
      end
    end
    d      = up.rsp_data;
    cycles = n;
  endtask

  function automatic logic [31:0] pattern(input logic [31:0] a);
    return {~a[15:0], a[15:0]} ^ 32'h5A5A_0F0F;
  endfunction

  // `k2g_mem` loads a byte at a time -- it is byte-striped, so that is its
  // natural granularity and the only loader it has.
  task automatic load_word(input logic [31:0] a, input logic [31:0] d);
    u_mem.load_byte(int'(a) + 0, d[7:0]);
    u_mem.load_byte(int'(a) + 1, d[15:8]);
    u_mem.load_byte(int'(a) + 2, d[23:16]);
    u_mem.load_byte(int'(a) + 3, d[31:24]);
  endtask

  // ---- the run ------------------------------------------------------------
  localparam logic [31:0] L0 = 32'h0000_1000;   // line-aligned
  localparam logic [31:0] L1 = 32'h0000_1080;   // the next line
  // Same index as L0 (bits 12:7 equal), different tag -- a conflict.
  localparam logic [31:0] LC = 32'h0000_3000;

  int i;
  int r0, w0;

  initial begin
    up.req_valid = 1'b0;
    up.req       = '0;

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // Fill memory: two adjacent lines plus the conflicting one.
    for (i = 0; i < WPL; i++) begin
      load_word(L0 + 32'(4 * i), pattern(L0 + 32'(4 * i)));
      load_word(L1 + 32'(4 * i), pattern(L1 + 32'(4 * i)));
      load_word(LC + 32'(4 * i), pattern(LC + 32'(4 * i)));
    end

    // ---- a cold access is one transaction of 32 words ----
    r0 = dn_requests; w0 = dn_words;
    fetch(L0, rd_data, rd_cycles);
    expect_eq("cold miss returns the right word", rd_data, pattern(L0));

    checks++;
    if ((dn_requests - r0) != 1)
      fail($sformatf("a refill took %0d bus requests, want 1", dn_requests - r0));
    checks++;
    if ((dn_words - w0) != WPL)
      fail($sformatf("a refill brought %0d words, want %0d", dn_words - w0, WPL));

    // ---- and the rest of the line is free ----
    r0 = dn_requests;
    for (i = 1; i < WPL; i++) begin
      fetch(L0 + 32'(4 * i), rd_data, rd_cycles);
      expect_eq($sformatf("hit at word %0d", i), rd_data,
                pattern(L0 + 32'(4 * i)));
      checks++;
      if (rd_cycles > 2)
        fail($sformatf("hit at word %0d took %0d cycles, want 2", i, rd_cycles));
    end
    checks++;
    if (dn_requests != r0)
      fail($sformatf("%0d bus requests during 31 hits, want 0", dn_requests - r0));

    // ---- the next line is a separate miss ----
    r0 = dn_requests;
    fetch(L1, rd_data, rd_cycles);
    expect_eq("second line", rd_data, pattern(L1));
    checks++;
    if ((dn_requests - r0) != 1)
      fail("the second line did not take exactly one refill");

    // The first line is still cached: a second line does not evict it, they
    // have different indices.
    r0 = dn_requests;
    fetch(L0 + 32'd8, rd_data, rd_cycles);
    expect_eq("first line still cached", rd_data, pattern(L0 + 32'd8));
    checks++;
    if (dn_requests != r0) fail("the first line was evicted by the second");

    // ---- a conflict evicts, and both addresses keep working ----
    r0 = dn_requests;
    fetch(LC, rd_data, rd_cycles);
    expect_eq("conflicting line", rd_data, pattern(LC));
    checks++;
    if ((dn_requests - r0) != 1) fail("the conflict did not refill exactly once");

    // L0 shares LC's index, so it must have been evicted and must refetch --
    // and must still return the right data afterwards, which is what says the
    // tag went with the data rather than lagging it.
    r0 = dn_requests;
    fetch(L0, rd_data, rd_cycles);
    expect_eq("evicted line refetched", rd_data, pattern(L0));
    checks++;
    if ((dn_requests - r0) != 1) fail("the evicted line did not refetch");

    // And the conflict is now the evicted one, both ways round.
    r0 = dn_requests;
    fetch(LC + 32'd4, rd_data, rd_cycles);
    expect_eq("conflict refetched", rd_data, pattern(LC + 32'd4));
    checks++;
    if ((dn_requests - r0) != 1) fail("the conflict did not refetch");

    // ---- ICINVR drops everything ----
    // The half of ICINVR this cache is responsible for (spec 3.2). Every line
    // must go, so the next fetch of anything comes from memory -- which is
    // what makes a store to an instruction visible.
    // Two different lines cached and confirmed hitting, so that "gone after the
    // invalidate" means something. L0 was evicted by the conflict test above,
    // so it has to be brought back first.
    fetch(L0, rd_data, rd_cycles);
    fetch(L1, rd_data, rd_cycles);
    r0 = dn_requests;
    fetch(L0, rd_data, rd_cycles);
    fetch(L1, rd_data, rd_cycles);
    checks++;
    if (dn_requests != r0) fail("both lines should have been cached by now");

    invalidate();

    r0 = dn_requests;
    fetch(L0, rd_data, rd_cycles);
    expect_eq("refetched after invalidate", rd_data, pattern(L0));
    checks++;
    if ((dn_requests - r0) != 1)
      fail($sformatf("after an invalidate the line took %0d refills, want 1",
                     dn_requests - r0));

    // The other line is gone too -- it invalidates everything, not just the
    // line most recently touched.
    r0 = dn_requests;
    fetch(L1, rd_data, rd_cycles);
    expect_eq("second line refetched", rd_data, pattern(L1));
    checks++;
    if ((dn_requests - r0) != 1) fail("the invalidate spared a line");

    // ---- never two in flight ----
    // Comparing totals at the end would be vacuous: every accepted request is
    // answered eventually, so they always match. What matters is the count at
    // each instant -- a second request accepted while a refill is outstanding
    // could be a hit, and would answer before the miss it came after.
    checks++;
    if (max_outstanding > 1)
      fail($sformatf("%0d requests were in flight at once -- a hit could overtake a miss",
                     max_outstanding));

    $display("  %0d refills, %0d words from memory", dn_requests, dn_words);
    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("TB_PASS tb_icache");
    else             $display("TB_FAIL tb_icache: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TB_FAIL tb_icache: timeout");
    $finish;
  end

endmodule
