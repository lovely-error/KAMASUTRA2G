// The host monitor, driven as byte streams rather than through a UART.
//
// A UART at 115200 takes 87 microseconds per byte, so a test that drove real
// serial waveforms would spend all of its time in the shift registers and none
// of it in the thing under test. `tb_uart` already proves the transmitter and
// receiver against each other; this drives their byte interfaces directly and
// runs about three orders of magnitude faster. `tb_soc` closes the loop by
// bit-banging real frames at the pins.
//
// What is checked here, and why each one is here rather than assumed:
//
//   * the testbench's own CRC matches the published CRC-16/CCITT-FALSE check
//     value. Without that, both sides could agree on the same wrong thing --
//     which is exactly how a hand-maintained opcode map once diverged;
//   * a frame with a corrupted byte produces NO reply at all, and the frame
//     behind it still works. Silence is the specified answer: replying would
//     mean trusting the type field of a frame just proved damaged;
//   * a length above MAX_PAYLOAD is refused WITHOUT consuming a payload, so
//     the frames behind a corrupt header survive;
//   * WRITE lands on the right byte lane. `we` is a shift by the address's low
//     bits, and a fixed mask would write the wrong byte of every word while
//     looking perfectly plausible in a whole-word test;
//   * READ crosses word boundaries and starts unaligned;
//   * PAUSE does not report itself done until the core says it is quiet, and
//     does not take the bus until cache maintenance has finished. Both are
//     ordering properties that a test doing them in one step cannot see;
//   * console output is coalesced -- a full buffer goes immediately, a partial
//     one after the idle timeout -- and back-pressures the core when full.
//     The transmitter here is busy between bytes for the same reason
//     `tb_core`'s is: a permanently-ready transmitter once let a flow-control
//     bug reach hardware.

`include "k2g_types.svh"

module tb_mon;

  import k2g_host_pkg::*;

  localparam int MEM_BYTES = 65536;
  localparam int CTX_DEPTH = 32;
  localparam int CRX_DEPTH = 8;
  localparam int CIDLE     = 64;      // shortened; the real one is ~150 us
  localparam int TX_BUSY   = 6;       // cycles the transmitter is busy per byte
  localparam int RX_GAP    = 24;      // cycles between received bytes
  localparam int TIMEOUT   = 200000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---- device under test --------------------------------------------------
  logic       rx_valid = 1'b0;
  logic [7:0] rx_data  = 8'd0;
  logic       tx_valid;
  logic [7:0] tx_data;
  logic       tx_ready;

  logic        fetch_hold, core_rst, bus_own, cmaint_req;
  logic        core_idle   = 1'b1;
  logic        core_halted = 1'b0;
  logic        core_faulted = 1'b0;
  logic [4:0]  core_fault_cause = 5'd0;
  logic [31:0] core_fault_addr  = 32'd0;
  logic [31:0] core_fault_info  = 32'd0;
  logic [63:0] core_cycles      = 64'd0;
  logic        cmaint_done = 1'b0;

  logic       con_tx_valid = 1'b0;
  logic [7:0] con_tx_data  = 8'd0;
  logic       con_tx_ready;
  logic       con_rx_valid;
  logic [7:0] con_rx_data;
  logic       con_rx_take = 1'b0;

  k2g_membus bus ();

  k2g_mon #(
      .MEM_BYTES        (MEM_BYTES),
      .HAS_RUN_CONTROL  (1'b1),
      .HAS_CONSOLE      (1'b1),
      .CONSOLE_TX_DEPTH (CTX_DEPTH),
      .CONSOLE_RX_DEPTH (CRX_DEPTH),
      .CONSOLE_IDLE     (CIDLE)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .rx_valid(rx_valid), .rx_data(rx_data),
      .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
      .bus(bus),
      .fetch_hold(fetch_hold), .core_idle(core_idle),
      .core_halted(core_halted), .core_faulted(core_faulted),
      .core_fault_cause(core_fault_cause), .core_fault_addr(core_fault_addr),
      .core_fault_info(core_fault_info), .core_cycles(core_cycles),
      .core_rst(core_rst), .bus_own(bus_own),
      .cmaint_req(cmaint_req), .cmaint_done(cmaint_done),
      .con_tx_valid(con_tx_valid), .con_tx_data(con_tx_data),
      .con_tx_ready(con_tx_ready),
      .con_rx_valid(con_rx_valid), .con_rx_data(con_rx_data),
      .con_rx_take(con_rx_take)
  );

  // ---- memory behind the bus ----------------------------------------------
  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic        mem_en;
  logic [3:0]  mem_we;
  int unsigned max_latency = 5;

  k2g_mem_slow u_slow (
      .clk(clk), .rst_n(rst_n), .max_latency(max_latency), .bus(bus),
      .b_addr(mem_addr), .b_en(mem_en), .b_we(mem_we),
      .b_wdata(mem_wdata), .b_rdata(mem_rdata)
  );

  k2g_mem #(.BYTES(MEM_BYTES)) u_mem (
      .clk(clk), .a_addr(32'd0), .a_en(1'b0), .a_data(),
      .b_addr(mem_addr), .b_en(mem_en), .b_we(mem_we),
      .b_wdata(mem_wdata), .b_rdata(mem_rdata)
  );

  // ---- a transmitter that is busy between bytes ---------------------------
  // Holding `tx_ready` high forever is the blind spot that let a flow-control
  // bug reach hardware once already (docs/bring-up.md).
  int   tx_busy  = 0;
  logic tx_wedge = 1'b0;      // held by the test that fills the console buffer
  assign tx_ready = (tx_busy == 0) && !tx_wedge;

  byte unsigned txq[$];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tx_busy <= 0;
    end else begin
      if (tx_busy > 0) tx_busy <= tx_busy - 1;
      if (tx_valid && tx_ready) begin
        txq.push_back(tx_data);
        tx_busy <= TX_BUSY;
      end
    end
  end

  // The cache-maintenance block, modelled: two-phase, and slow enough that
  // "the bus was taken before the flush finished" is visible rather than a
  // one-cycle race nothing could catch.
  int cm_delay = 0;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cmaint_done <= 1'b0;
      cm_delay    <= 0;
    end else begin
      cmaint_done <= 1'b0;
      if (cmaint_req && !cmaint_done) begin
        if (cm_delay == 40) begin
          cmaint_done <= 1'b1;
          cm_delay    <= 0;
        end else begin
          cm_delay <= cm_delay + 1;
        end
      end else begin
        cm_delay <= 0;
      end
    end
  end

  // ---- the pause ordering, watched rather than sampled --------------------
  // "The bus was taken before the caches were made coherent" is a one-cycle
  // property. Polling for it in the test body races the very thing it is
  // checking -- a mutant that collapses the wait into a single cycle would slip
  // between two `@(negedge clk)`s. So it is latched here, continuously.
  logic watch_order = 1'b0;
  logic cm_answered;
  logic bus_early;

  always_ff @(posedge clk) begin
    if (!watch_order) begin
      cm_answered <= 1'b0;
      bus_early   <= 1'b0;
    end else begin
      if (cmaint_done) cm_answered <= 1'b1;
      if (bus_own && !cm_answered && !cmaint_done) bus_early <= 1'b1;
    end
  end

  // ---- scoreboard ---------------------------------------------------------
  int checks = 0;
  int errors = 0;

  task automatic fail(input string msg);
    $display("TB_FAIL tb_mon: %s", msg);
    errors++;
  endtask

  task automatic expect_eq(input string what, input logic [63:0] got,
                           input logic [63:0] want);
    checks++;
    if (got !== want)
      fail($sformatf("%s: expected %0h, got %0h", what, want, got));
  endtask

  task automatic expect_true(input string what, input logic cond);
    checks++;
    if (cond !== 1'b1) fail(what);
  endtask

  // ---- CRC, written from the published definition -------------------------
  function automatic logic [15:0] crc_upd(input logic [15:0] c,
                                          input logic [7:0] b);
    logic [15:0] t;
    begin
      t = c ^ {b, 8'h00};
      for (int i = 0; i < 8; i++) t = t[15] ? ((t << 1) ^ 16'h1021) : (t << 1);
      crc_upd = t;
    end
  endfunction

  // ---- driving the receive side -------------------------------------------
  task automatic rx_put(input logic [7:0] b);
    @(negedge clk);
    rx_data  = b;
    rx_valid = 1'b1;
    @(negedge clk);
    rx_valid = 1'b0;
    repeat (RX_GAP) @(negedge clk);
  endtask

  task automatic send_frame(input logic [7:0] ty, ref byte unsigned pay[$],
                            input int corrupt_at, input int len_override);
    logic [15:0] crc;
    int          n;
    begin
      n = (len_override >= 0) ? len_override : pay.size();
      crc = 16'hFFFF;
      crc = crc_upd(crc, ty);
      crc = crc_upd(crc, n[7:0]);
      crc = crc_upd(crc, n[15:8]);
      for (int i = 0; i < pay.size(); i++) crc = crc_upd(crc, pay[i]);

      rx_put(MAGIC0);
      rx_put(MAGIC1);
      rx_put(ty);
      rx_put(n[7:0]);
      rx_put(n[15:8]);
      for (int i = 0; i < pay.size(); i++)
        rx_put((i == corrupt_at) ? (pay[i] ^ 8'hFF) : pay[i]);
      rx_put(crc[7:0]);
      rx_put(crc[15:8]);
    end
  endtask

  task automatic send(input logic [7:0] ty, ref byte unsigned pay[$]);
    send_frame(ty, pay, -1, -1);
  endtask

  task automatic send_empty(input logic [7:0] ty);
    byte unsigned none[$];
    none.delete();
    send_frame(ty, none, -1, -1);
  endtask

  // ---- reading the transmit side ------------------------------------------
  byte unsigned con_out[$];

  task automatic get_byte(output logic [7:0] b, output logic ok);
    int n;
    begin
      n  = 0;
      ok = 1'b1;
      while (txq.size() == 0) begin
        @(negedge clk);
        n++;
        if (n > TIMEOUT) begin
          ok = 1'b0;
          return;
        end
      end
      b = txq.pop_front();
    end
  endtask

  task automatic get_frame(output logic ok, output logic [7:0] ty,
                           ref byte unsigned pay[$]);
    logic [7:0]  b;
    logic [15:0] want, got;
    int          n;
    begin
      pay.delete();
      ok = 1'b0;

      // Hunt the magic, exactly as the monitor does.
      forever begin
        get_byte(b, ok);
        if (!ok) return;
        if (b != MAGIC0) continue;
        get_byte(b, ok);
        if (!ok) return;
        if (b == MAGIC1) break;
      end

      get_byte(ty, ok);          if (!ok) return;
      want = crc_upd(16'hFFFF, ty);
      get_byte(b, ok);           if (!ok) return;
      n    = b;
      want = crc_upd(want, b);
      get_byte(b, ok);           if (!ok) return;
      n   |= int'(b) << 8;
      want = crc_upd(want, b);

      for (int i = 0; i < n; i++) begin
        get_byte(b, ok);
        if (!ok) return;
        pay.push_back(b);
        want = crc_upd(want, b);
      end

      get_byte(b, ok);           if (!ok) return;
      got = {8'd0, b};
      get_byte(b, ok);           if (!ok) return;
      got |= {b, 8'd0};

      if (got != want) begin
        fail($sformatf("the monitor sent a frame with a bad CRC (type %02h)", ty));
        ok = 1'b0;
      end
    end
  endtask

  // Console output may arrive at any time, including between a command and its
  // answer -- that is the point of framing it -- so a reply is the first frame
  // that is not console output.
  task automatic get_reply(output logic ok, output logic [7:0] ty,
                           ref byte unsigned pay[$]);
    begin
      forever begin
        get_frame(ok, ty, pay);
        if (!ok) return;
        if (ty != HF_CONSOLE_OUT) return;
        for (int i = 0; i < pay.size(); i++) con_out.push_back(pay[i]);
      end
    end
  endtask

  task automatic expect_reply(input string what, input logic [7:0] want_ty,
                              ref byte unsigned pay[$]);
    logic       ok;
    logic [7:0] ty;
    begin
      get_reply(ok, ty, pay);
      checks++;
      if (!ok) fail($sformatf("%s: no reply", what));
      else if (ty !== want_ty)
        fail($sformatf("%s: expected type %02h, got %02h", what, want_ty, ty));
    end
  endtask

  task automatic expect_silence(input string what, input int cycles);
    int was;
    begin
      was = txq.size();
      repeat (cycles) @(negedge clk);
      checks++;
      if (txq.size() != was)
        fail($sformatf("%s: the monitor answered when it should not have", what));
    end
  endtask

  // ---- command helpers ----------------------------------------------------
  task automatic do_pause();
    byte unsigned p[$];
    begin
      send_empty(HF_PAUSE);
      expect_reply("PAUSE", HF_STATE, p);
    end
  endtask

  task automatic write_range(input logic [31:0] a, ref byte unsigned data[$],
                             output int acked);
    byte unsigned p[$];
    begin
      p.delete();
      for (int i = 0; i < 4; i++) p.push_back(a[8*i +: 8]);
      for (int i = 0; i < data.size(); i++) p.push_back(data[i]);
      send(HF_WRITE, p);
      expect_reply("WRITE", HF_ACK, p);
      acked = (p.size() == 2) ? (int'(p[0]) | (int'(p[1]) << 8)) : -1;
    end
  endtask

  task automatic read_range(input logic [31:0] a, input int n,
                            ref byte unsigned data[$]);
    byte unsigned p[$];
    begin
      p.delete();
      for (int i = 0; i < 4; i++) p.push_back(a[8*i +: 8]);
      p.push_back(n[7:0]);
      p.push_back(n[15:8]);
      send(HF_READ, p);
      expect_reply("READ", HF_DATA, data);
    end
  endtask

  // =========================================================================
  initial begin
    byte unsigned p[$], q[$], data[$];
    logic         ok;
    logic [7:0]   ty;
    int           acked;
    logic [31:0]  v;

    // The testbench's own CRC, against the published check value. If this is
    // wrong every comparison below is between two things that agree and are
    // both wrong.
    begin
      logic [15:0] c;
      c = 16'hFFFF;
      c = crc_upd(c, "1"); c = crc_upd(c, "2"); c = crc_upd(c, "3");
      c = crc_upd(c, "4"); c = crc_upd(c, "5"); c = crc_upd(c, "6");
      c = crc_upd(c, "7"); c = crc_upd(c, "8"); c = crc_upd(c, "9");
      expect_eq("CRC-16/CCITT-FALSE of \"123456789\"", c, 16'h29B1);
    end

    // Unwritten memory reads X otherwise, and "the lane next door was not
    // touched" is one of the things this test is for.
    u_mem.clear_all();

    repeat (8) @(negedge clk);
    rst_n = 1'b1;
    repeat (8) @(negedge clk);

    // ---- PING ------------------------------------------------------------
    send_empty(HF_PING);
    expect_reply("PING", HF_IDENT, p);
    if (p.size() == IDENT_LEN) begin
      expect_eq("IDENT version", {p[1], p[0]}, 16'(PROTO_VERSION));
      expect_eq("IDENT max payload", {p[3], p[2]}, 16'(MAX_PAYLOAD));
      expect_eq("IDENT core id", {p[7], p[6], p[5], p[4]}, CORE_ID);
      expect_eq("IDENT mem bytes", {p[11], p[10], p[9], p[8]}, 32'(MEM_BYTES));
      expect_eq("IDENT caps", {p[15], p[14], p[13], p[12]},
                CAP_MEMORY | CAP_RUN_CONTROL | CAP_CONSOLE | CAP_CONSOLE_IN);
    end else begin
      fail($sformatf("IDENT payload is %0d bytes, expected %0d",
                     p.size(), IDENT_LEN));
    end

    // ---- STATUS before anything ------------------------------------------
    send_empty(HF_STATUS);
    expect_reply("STATUS", HF_STATE, p);
    expect_eq("STATUS says running", p[0] & FLAG_PAUSED, 8'd0);

    // ---- memory commands are refused until the core is stopped -----------
    p.delete();
    for (int i = 0; i < 4; i++) p.push_back(8'd0);
    p.push_back(8'hAA);
    send(HF_WRITE, p);
    expect_reply("WRITE while running", HF_NAK, p);
    expect_eq("NAK reason is STATE", p[0], NAK_STATE);

    // ---- PAUSE waits for the core, and for the caches --------------------
    // Driven in two steps so the ordering is visible: a monitor that replied
    // before the core went quiet, or took the bus before the flush finished,
    // would pass a single-step version of this test.
    core_idle   = 1'b0;
    watch_order = 1'b1;
    send_empty(HF_PAUSE);
    repeat (200) @(negedge clk);
    expect_true("PAUSE holds fetch immediately", fetch_hold);
    expect_silence("PAUSE with the core still busy", 200);
    expect_true("the bus is not taken while the core is busy", !bus_own);

    core_idle = 1'b1;
    expect_reply("PAUSE", HF_STATE, p);
    expect_true("cache maintenance actually ran", cm_answered);
    expect_true("the bus was not taken before maintenance finished", !bus_early);
    watch_order = 1'b0;
    expect_eq("PAUSE reports paused", p[0] & FLAG_PAUSED, FLAG_PAUSED);
    expect_eq("PAUSE reports the bus taken", p[0] & FLAG_BUS_OWNED, FLAG_BUS_OWNED);
    checks++;
    if (!bus_own) fail("the bus was never taken");

    // ---- WRITE and READ --------------------------------------------------
    data.delete();
    for (int i = 0; i < 9; i++) data.push_back(8'hA0 + 8'(i));
    write_range(32'h0000_0100, data, acked);
    expect_eq("WRITE acked every byte", acked, 9);

    // Straight into the array: this is what proves the lane decode, not the
    // read-back path agreeing with the write path about a shared mistake.
    for (int i = 0; i < 9; i++)
      expect_eq($sformatf("memory at %0h", 32'h100 + i),
                u_mem.peek_byte(32'h100 + i), 8'hA0 + 8'(i));

    // ---- an unaligned WRITE lands on the right lanes ---------------------
    data.delete();
    data.push_back(8'h11);
    data.push_back(8'h22);
    write_range(32'h0000_0201, data, acked);
    expect_eq("unaligned WRITE acked", acked, 2);
    expect_eq("byte lane 1", u_mem.peek_byte(32'h201), 8'h11);
    expect_eq("byte lane 2", u_mem.peek_byte(32'h202), 8'h22);
    expect_eq("lane 0 untouched", u_mem.peek_byte(32'h200), 8'h00);
    expect_eq("lane 3 untouched", u_mem.peek_byte(32'h203), 8'h00);

    // ---- READ, unaligned and crossing word boundaries --------------------
    // Memory is made slow for this, and that is the whole point: at five
    // cycles the answer always arrives inside the gap between two transmitted
    // bytes, so a transmitter that shipped a byte before memory replied would
    // ship the right one anyway and the test would prove nothing. It went
    // MISSED exactly that way before this line existed.
    max_latency = 60;
    read_range(32'h0000_0101, 7, data);
    max_latency = 5;
    checks++;
    if (data.size() != 7) begin
      fail($sformatf("READ returned %0d bytes, expected 7", data.size()));
    end else begin
      for (int i = 0; i < 7; i++)
        expect_eq($sformatf("READ byte %0d", i), data[i], 8'hA1 + 8'(i));
    end

    // ---- a corrupted frame is answered with silence, and does not wedge ---
    p.delete();
    for (int i = 0; i < 4; i++) p.push_back(8'd0);
    p.push_back(8'h5A);
    p.push_back(8'h5B);
    send_frame(HF_WRITE, p, 4, -1);           // flip a payload byte
    expect_silence("a frame with a bad CRC", 400);

    send_empty(HF_STATUS);
    expect_reply("STATUS after a bad CRC", HF_STATE, p);

    // ---- an impossible length does not swallow the next frame ------------
    // The header claims 0xFF00 bytes. Nothing after it is a payload.
    rx_put(MAGIC0);
    rx_put(MAGIC1);
    rx_put(HF_WRITE);
    rx_put(8'h00);
    rx_put(8'hFF);
    send_empty(HF_PING);
    expect_reply("PING behind an impossible length", HF_IDENT, p);

    // ---- unknown type, and a wrong length --------------------------------
    send_empty(8'h7F);
    expect_reply("an unimplemented type", HF_NAK, p);
    expect_eq("NAK reason is TYPE", p[0], NAK_TYPE);

    p.delete();
    p.push_back(8'd1);
    p.push_back(8'd2);
    send(HF_PING, p);                          // PING takes no payload
    expect_reply("PING with a payload", HF_NAK, p);
    expect_eq("NAK reason is LENGTH", p[0], NAK_LENGTH);

    // ---- addresses outside memory ----------------------------------------
    data.delete();
    data.push_back(8'hEE);
    write_range_expect_nak(32'(MEM_BYTES), data);

    p.delete();
    for (int i = 0; i < 4; i++) p.push_back(8'((MEM_BYTES - 4) >> (8*i)));
    p.push_back(8'd16);
    p.push_back(8'd0);
    send(HF_READ, p);
    expect_reply("READ running off the end", HF_NAK, p);
    expect_eq("NAK reason is ADDRESS", p[0], NAK_ADDRESS);

    // ---- RESET -----------------------------------------------------------
    fork
      begin : watch_reset
        int n;
        n = 0;
        while (!core_rst && n < 2000) begin @(negedge clk); n++; end
        expect_true("RESET asserts the core reset", core_rst);
        while (core_rst && n < 4000) begin @(negedge clk); n++; end
        expect_true("RESET releases the core reset", !core_rst);
      end
      begin
        send_empty(HF_RESET);
        expect_reply("RESET", HF_STATE, p);
        expect_eq("still paused after RESET", p[0] & FLAG_PAUSED, FLAG_PAUSED);
      end
    join

    // ---- RESUME ----------------------------------------------------------
    send_empty(HF_RESUME);
    expect_reply("RESUME", HF_STATE, p);
    expect_eq("RESUME reports running", p[0] & FLAG_PAUSED, 8'd0);
    expect_true("RESUME releases fetch", !fetch_hold);
    expect_true("RESUME gives the bus back", !bus_own);

    // ---- a halted core reports why ---------------------------------------
    // The whole point of STATUS: a stopped core cannot execute the CSP read
    // that would report its own fault cause, so the LEDs used to be the only
    // answer (docs/bring-up.md).
    core_halted      = 1'b1;
    core_faulted     = 1'b1;
    core_fault_cause = 5'd9;
    core_fault_addr  = 32'hDEAD_BEEF;
    core_fault_info  = 32'h1234_5678;
    core_cycles      = 64'h0102_0304_0506_0708;
    send_empty(HF_STATUS);
    expect_reply("STATUS of a faulted core", HF_STATE, p);
    expect_eq("halted flag", p[0] & FLAG_HALTED, FLAG_HALTED);
    expect_eq("faulted flag", p[0] & FLAG_FAULTED, FLAG_FAULTED);
    expect_eq("fault cause", p[1], 8'd9);
    expect_eq("fault address", {p[7], p[6], p[5], p[4]}, 32'hDEAD_BEEF);
    expect_eq("fault info", {p[11], p[10], p[9], p[8]}, 32'h1234_5678);
    expect_eq("cycle count", {p[19], p[18], p[17], p[16],
                              p[15], p[14], p[13], p[12]},
              64'h0102_0304_0506_0708);
    core_halted  = 1'b0;
    core_faulted = 1'b0;

    // ---- console output is coalesced -------------------------------------
    // A partial buffer waits for the idle timeout rather than sending one byte
    // per frame, which would cost eight times the link.
    con_out.delete();
    console_put("H");
    console_put("i");
    expect_silence("two console bytes before the idle timeout", CIDLE / 2);
    get_frame(ok, ty, p);
    expect_true("a console frame arrives after the idle timeout", ok);
    expect_eq("it is a console frame", ty, HF_CONSOLE_OUT);
    checks++;
    if (p.size() != 2 || p[0] != "H" || p[1] != "i")
      fail("console frame did not carry the two bytes");

    // A full buffer goes out without waiting.
    for (int i = 0; i < CTX_DEPTH; i++) console_put(8'h30 + 8'(i % 10));
    get_frame(ok, ty, p);
    expect_true("a full console buffer is sent", ok);
    expect_eq("a full buffer fills one frame", p.size(), CTX_DEPTH);

    // ---- the console back-pressures the core ------------------------------
    // `con_tx_ready` is k2g_csp's `uart_tx_ready`. A version that never fell
    // is the bug that printed `H` and nothing else on the first hardware run.
    tx_wedge = 1'b1;                           // the line stops accepting bytes
    repeat (10) @(negedge clk);
    for (int i = 0; i < CTX_DEPTH; i++) begin
      con_tx_data  = 8'h41;
      con_tx_valid = 1'b1;
      @(negedge clk);
    end
    con_tx_valid = 1'b0;
    expect_true("the console buffer fills and refuses more", !con_tx_ready);
    tx_wedge = 1'b0;

    // Drain whatever that produced before carrying on.
    repeat (4) @(negedge clk);
    while (txq.size() > 0 || tx_valid) begin
      get_frame(ok, ty, p);
      if (!ok) break;
      repeat (CIDLE + 8) @(negedge clk);
    end

    // ---- console input ---------------------------------------------------
    p.delete();
    p.push_back("a");
    p.push_back("b");
    p.push_back("c");
    send(HF_CONSOLE_IN, p);
    expect_reply("CONSOLE_IN", HF_ACK, p);
    expect_eq("three bytes accepted", {p[1], p[0]}, 16'd3);

    for (int i = 0; i < 3; i++) begin
      expect_true("a console byte is waiting", con_rx_valid);
      expect_eq($sformatf("console input byte %0d", i), con_rx_data,
                8'("a") + 8'(i));
      @(negedge clk);
      con_rx_take = 1'b1;
      @(posedge clk);
      @(negedge clk);
      con_rx_take = 1'b0;
    end
    expect_true("the console input buffer empties", !con_rx_valid);

    // More than the buffer holds: the ACK says how many were taken, which is
    // the only flow control this direction has.
    p.delete();
    for (int i = 0; i < CRX_DEPTH + 4; i++) p.push_back(8'h50 + 8'(i));
    send(HF_CONSOLE_IN, p);
    expect_reply("CONSOLE_IN overflowing", HF_ACK, p);
    expect_eq("only what fits is accepted", {p[1], p[0]}, 16'(CRX_DEPTH));

    // ---- verdict ---------------------------------------------------------
    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("TB_PASS tb_mon");
    else             $display("TB_FAIL tb_mon: %0d error(s)", errors);
    $finish;
  end

  task automatic write_range_expect_nak(input logic [31:0] a,
                                        ref byte unsigned data[$]);
    byte unsigned p[$];
    begin
      p.delete();
      for (int i = 0; i < 4; i++) p.push_back(a[8*i +: 8]);
      for (int i = 0; i < data.size(); i++) p.push_back(data[i]);
      send(HF_WRITE, p);
      expect_reply("WRITE outside memory", HF_NAK, p);
      expect_eq("NAK reason is ADDRESS", p[0], NAK_ADDRESS);
    end
  endtask

  task automatic console_put(input logic [7:0] b);
    begin
      @(negedge clk);
      con_tx_data  = b;
      con_tx_valid = 1'b1;
      while (!con_tx_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      con_tx_valid = 1'b0;
    end
  endtask

  initial begin
    #40000000;
    $display("TB_FAIL tb_mon: timeout");
    $finish;
  end

endmodule
