// The whole machine, booting out of PSRAM.
//
// This is the first testbench that runs `k2g_soc` rather than a piece of it,
// and it exists because the alternative is a flash. Three things meet here for
// the first time and none of them can be checked anywhere else:
//
//   * the boot copier as a BUS MASTER. It used to write a byte per cycle
//     straight into k2g_mem's port B, unconditionally. Now it advances on
//     `req_ready` behind a memory whose smallest write is a 128-byte burst;
//   * `k2g_membus_mux` handing the data port from the copier to the core;
//   * the core coming out of reset behind memory that came out of reset
//     ~80 us earlier -- which is what made `ibus.req_valid` need `rst_n`. A
//     core held in reset used to offer a fetch every cycle while counting
//     none of them, harmless only because every slave so far shared its reset
//     and dropped everything. Nothing shares its reset here.
//
// WHAT IT CHECKS, and the first one is the substantive one: every byte of the
// boot ROM arrives in PSRAM. The comparison is against a SECOND INSTANCE of
// `k2g_rom` rather than against a table written here, so the test does not
// care which program the ROM currently holds -- and `k2g_rom.sv` is generated,
// so a test that cared would go stale the first time someone rebuilt for a
// different program.
//
// That single check covers a surprising amount: a per-byte write to PSRAM is a
// masked write into one beat of a burst, so 168 of them landing in the right
// places means the burst geometry, the mask lanes and the beat phase are all
// right, in the real SoC rather than in a directed test.
//
// Then the machine runs, and the weaker end-to-end properties: the core
// retires, it does not fault, and bytes reach the transmitter.
//
// NOT CHECKED HERE. Anything about the clock crossing, for the reasons in
// k2g_cdc_fifo.sv; and anything about whether the real controller is
// configured correctly, since it is the behavioural model that answers. The
// psram bring-up stage is what says that, on hardware.

`include "k2g_rom.svh"
`timescale 1ns/1ps

module tb_soc;

  import k2g_host_pkg::*;

  localparam int ROM_BYTES     = `K2G_ROM_BYTES;
  localparam int ROM_ADDR_BITS = `K2G_ROM_ADDR_BITS;

  // 27 MHz crystal. Everything else in the design derives from it: clk_sys is
  // this halved, and the PLL multiplies it by five for the memory clock.
  localparam real XTAL_HALF = 18.518;   // ns

  logic clk_27m = 1'b0;
  logic rst_n   = 1'b1;      // pulled up on the board; released is 1

  always #XTAL_HALF clk_27m = ~clk_27m;

  wire [5:0]  led;
  wire        uart_tx;
  wire [1:0]  psram_ck, psram_ck_n, psram_cs_n, psram_reset_n;
  wire [15:0] psram_dq;
  wire [1:0]  psram_rwds;

  // The serial line, driven and decoded for real. This is the only place the
  // host protocol is tested through the pins rather than through the monitor's
  // byte interface -- `tb_mon` does the latter, three orders of magnitude
  // faster, and cannot see the UART, the muxes, the caches or the core.
  logic uart_rx_line = 1'b1;

  // Two things are shortened, and neither changes what is being tested.
  //
  // DEBOUNCE: ten milliseconds of a button nobody is pressing is thirty times
  // the length of everything this testbench is about.
  //
  // BAUD: 115200 is 87 microseconds a byte, and this test sends and receives a
  // few hundred. The divisor is what the UART actually runs on, so raising the
  // baud lowers it to 8 and a byte becomes 5.9 us. `tb_uart` is where the real
  // divisor is checked.
  localparam int TB_BAUD    = 1_687_500;          // 13.5 MHz / 8
  localparam int SOC_DIV    = 13_500_000 / TB_BAUD;

  k2g_soc #(.DEBOUNCE(4), .BAUD(TB_BAUD)) dut (
      .clk_27m        (clk_27m),
      .rst_n          (rst_n),
      .led            (led),
      .uart_tx        (uart_tx),
      .uart_rx        (uart_rx_line),
      .O_psram_ck     (psram_ck),
      .O_psram_ck_n   (psram_ck_n),
      .IO_psram_dq    (psram_dq),
      .IO_psram_rwds  (psram_rwds),
      .O_psram_cs_n   (psram_cs_n),
      .O_psram_reset_n(psram_reset_n)
  );

  // A second copy of the boot ROM, to compare against. Same generated module,
  // so it cannot disagree with the one inside the SoC about what the program
  // is.
  logic [ROM_ADDR_BITS-1:0] ref_addr;
  logic [7:0]               ref_data;

  // Clocked, like the one inside the SoC. Its read takes a cycle now, so the
  // comparison below waits an edge rather than a delta.
  k2g_rom u_ref (.clk(clk_27m), .addr(ref_addr), .data(ref_data));


  // ---- scoreboard ---------------------------------------------------------
  int checks = 0;
  int errors = 0;

  task automatic fail(input string msg);
    $display("TB_FAIL tb_soc: %s", msg);
    errors++;
  endtask

  // Bytes the PROGRAM printed, recovered from the wire by decoding
  // CONSOLE_OUT frames.
  //
  // This used to count `dut.core_tx_valid && dut.tx_ready`, which stopped
  // meaning anything the moment the monitor came between them: those are two
  // unrelated signals now, and the count would have stayed plausible while
  // testing nothing. Decoding the line is what makes a framing bug visible,
  // and a framing bug looks exactly like a CPU that has stopped.
  int    uart_bytes = 0;
  string console;

  // ---- the serial line ----------------------------------------------------
  // Bit-banged at the pin, at the divisor the SoC was built with. The receiver
  // samples mid-bit, which is what the real one does and what makes a divisor
  // that is off by one show up as garbage rather than as nothing.
  byte unsigned txq[$];

  // Bytes the board's receiver actually accepted, so "no reply" can be told
  // apart from "the board never heard us".
  int rx_seen = 0;
  always @(posedge dut.clk_sys) if (dut.rx_valid) rx_seen++;

  task automatic ser_bit(input logic b);
    uart_rx_line = b;
    repeat (SOC_DIV) @(posedge dut.clk_sys);
  endtask

  task automatic ser_byte(input logic [7:0] b);
    ser_bit(1'b0);                       // start
    for (int i = 0; i < 8; i++) ser_bit(b[i]);
    ser_bit(1'b1);                       // stop
    ser_bit(1'b1);                       // a little idle between bytes
  endtask

  initial begin : rx_decoder
    logic [7:0] b;
    forever begin
      @(negedge uart_tx);
      repeat (SOC_DIV / 2) @(posedge dut.clk_sys);
      for (int i = 0; i < 8; i++) begin
        repeat (SOC_DIV) @(posedge dut.clk_sys);
        b[i] = uart_tx;
      end
      repeat (SOC_DIV) @(posedge dut.clk_sys);
      txq.push_back(b);
    end
  end

  function automatic logic [15:0] crc_upd(input logic [15:0] c,
                                          input logic [7:0] b);
    logic [15:0] t;
    begin
      t = c ^ {b, 8'h00};
      for (int i = 0; i < 8; i++) t = t[15] ? ((t << 1) ^ 16'h1021) : (t << 1);
      crc_upd = t;
    end
  endfunction

  task automatic send_frame(input logic [7:0] ty, ref byte unsigned pay[$]);
    logic [15:0] crc;
    int          n;
    begin
      n   = pay.size();
      crc = crc_upd(crc_upd(crc_upd(16'hFFFF, ty), n[7:0]), n[15:8]);
      for (int i = 0; i < n; i++) crc = crc_upd(crc, pay[i]);
      ser_byte(MAGIC0);
      ser_byte(MAGIC1);
      ser_byte(ty);
      ser_byte(n[7:0]);
      ser_byte(n[15:8]);
      for (int i = 0; i < n; i++) ser_byte(pay[i]);
      ser_byte(crc[7:0]);
      ser_byte(crc[15:8]);
    end
  endtask

  task automatic get_byte(output logic [7:0] b, output logic ok);
    int n;
    begin
      n  = 0;
      ok = 1'b1;
      while (txq.size() == 0) begin
        @(posedge dut.clk_sys);
        n++;
        if (n > 100000) begin ok = 1'b0; return; end
      end
      b = txq.pop_front();
    end
  endtask

  // One frame, whatever it is. Console payloads are accumulated as they pass,
  // because they arrive unprompted and may land between a command and its
  // answer -- which is the point of framing them.
  task automatic get_frame_any(output logic ok, output logic [7:0] ty,
                               ref byte unsigned pay[$]);
    logic [7:0]  b;
    logic [15:0] want, got;
    int          n;
    begin
      pay.delete();
      forever begin
        get_byte(b, ok);   if (!ok) return;
        if (b != MAGIC0) continue;
        get_byte(b, ok);   if (!ok) return;
        if (b == MAGIC1) break;
      end
      get_byte(ty, ok);    if (!ok) return;
      want = crc_upd(16'hFFFF, ty);
      get_byte(b, ok);     if (!ok) return;
      n    = b;  want = crc_upd(want, b);
      get_byte(b, ok);     if (!ok) return;
      n   |= int'(b) << 8;  want = crc_upd(want, b);
      for (int i = 0; i < n; i++) begin
        get_byte(b, ok);   if (!ok) return;
        pay.push_back(b);  want = crc_upd(want, b);
      end
      get_byte(b, ok);     if (!ok) return;
      got = {8'd0, b};
      get_byte(b, ok);     if (!ok) return;
      got |= {b, 8'd0};
      if (got != want) begin
        fail($sformatf("the board sent a frame with a bad CRC (type %02h)", ty));
        ok = 1'b0;
        return;
      end
      if (ty == HF_CONSOLE_OUT)
        for (int i = 0; i < n; i++) begin
          console = {console, string'(pay[i])};
          uart_bytes++;
        end
    end
  endtask

  // A reply is the first frame that is not console output.
  task automatic get_reply(output logic ok, output logic [7:0] ty,
                           ref byte unsigned pay[$]);
    begin
      forever begin
        get_frame_any(ok, ty, pay);
        if (!ok || ty != HF_CONSOLE_OUT) return;
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

  function automatic logic console_has(input string want);
    begin
      console_has = 1'b0;
      if (console.len() >= want.len())
        for (int i = 0; i + want.len() <= console.len(); i++)
          if (console.substr(i, i + want.len() - 1) == want) console_has = 1'b1;
    end
  endfunction

  // Waits for console output to contain `want`, one frame at a time. It has to
  // check after EVERY frame rather than between replies: nothing else is being
  // asked of the board here, so `get_reply` would sit waiting for an answer
  // that is never coming while the text it wants goes past.
  // Any console output at all, CRC-checked. Used for the boot ROM, whose text
  // this testbench does not get to choose.
  task automatic await_console_any(input string what);
    logic         ok;
    logic [7:0]   ty;
    byte unsigned pay[$];
    begin
      checks++;
      for (int tries = 0; tries < 200; tries++) begin
        if (uart_bytes > 0) return;
        get_frame_any(ok, ty, pay);
        if (!ok) break;
      end
      if (uart_bytes > 0) return;
      fail($sformatf("%s: no console frame ever arrived", what));
    end
  endtask

  task automatic await_console(input string what, input string want);
    logic         ok;
    logic [7:0]   ty;
    byte unsigned pay[$];
    begin
      checks++;
      for (int tries = 0; tries < 200; tries++) begin
        if (console_has(want)) return;
        get_frame_any(ok, ty, pay);
        if (!ok) break;
      end
      if (console_has(want)) return;
      fail($sformatf("%s: console never said \"%s\" (it said \"%s\")",
                     what, want, console));
    end
  endtask


  // A CORE IN RESET MUST NOT ASK THE BUS FOR ANYTHING.
  //
  // CURRENTLY UNREACHABLE, and kept anyway. `k2g_icache` sits between the core
  // and the bus now, is reset with the core, and refuses a miss -- so a core
  // in reset asking an empty cache is refused every time and this counter
  // cannot rise however the core behaves. The mutant that used to prove this
  // check works has been removed rather than left reporting MISSED.
  //
  // It stays because the masking depends on the cache being held by
  // `cpu_rst_n`; if that ever becomes the system reset, a cache holding valid
  // lines would start accepting during reset and this is what would say so.
  //
  // Stated directly, because every indirect version of it measured here was
  // blind:
  //
  //   * "answered more often than it asked" is false at the end of any run --
  //     the core legitimately has up to four requests in flight, which is
  //     larger than the surplus;
  //   * comparing the testbench's issue/answer difference against the core's
  //     own `outstanding` is tautological, since both count the same two wires
  //     from the same instant;
  //   * a per-cycle "answered with nothing outstanding" assertion inside the
  //     core never fires, because the core has always just issued something.
  //
  // What actually happens without the guard, measured on the mutant: the core
  // issues 167 fetches while held for the boot copy and counts none of them,
  // two are still in flight when it is released, and from then on every answer
  // is paired with the wrong entry of `issue_addr`. The code points are a
  // valid sequential stream, so the machine runs; it is `isa` that is wrong,
  // which means fault addresses and branch targets. It also stole half the
  // bus from the copier, which is why the copy took 186 us instead of 104.
  int reset_iss = 0;

  always @(posedge dut.clk_sys) begin
    if (dut.cpu_rst_n !== 1'b1 &&
        dut.ibus.req_valid === 1'b1 && dut.ibus.req_ready === 1'b1)
      reset_iss++;
  end

  // Bytes the PROGRAM has written, so the boot-image check below can skip
  // them. The core is released the moment `booting` falls, while the last
  // copier write is still crossing to PSRAM -- so there is an unavoidable
  // window in which the program is running and the image is not yet all
  // there, and `fibforever` spends it writing digits into the `buf` that is
  // part of its own image.
  //
  // This was latent until the instruction cache landed. At 20 cycles per
  // instruction the core could not reach its first store inside the settle
  // window; at 3 it reaches it easily. The test was wrong before and passing.
  bit core_wrote [int];

  always @(posedge dut.clk_sys) begin
    if (dut.cpu_rst_n === 1'b1 && dut.dbus.req_valid === 1'b1 &&
        dut.dbus.req_ready === 1'b1 && dut.dbus.req.we != 4'b0000) begin
      for (int b = 0; b < 4; b++)
        if (dut.dbus.req.we[b]) core_wrote[int'(dut.dbus.req.addr) + b] = 1'b1;
    end
  end

  int retired  = 0;
  int bad_isa  = 0;
  int wild_isa = 0;

  // `retire.isa` is the address the instruction came from, and it is the thing
  // a stale fetch response corrupts rather than the code point: the core pairs
  // each answer with the oldest entry of its `issue_addr` queue, so an answer
  // to a request the core did not count comes back paired with an entry it
  // never wrote. The instruction still decodes and still executes -- it is the
  // address that is wrong -- so nothing else here would notice. Two ways to
  // see it:
  //
  //   * X. An `issue_addr` entry that was never written is X in simulation,
  //     and X arriving in an architectural field is never legitimate;
  //   * out of range. Every program in emu/programs/ stays inside its own
  //     image, so an `isa` past the end of what was copied is a machine that
  //     has left the program.
  always @(posedge dut.clk_sys) begin
    if (dut.cpu_rst_n && dut.u_core.retire_valid) begin
      retired++;
      if ((^dut.u_core.retire.isa) === 1'bx)          bad_isa++;
      else if (dut.u_core.retire.isa >= 32'(ROM_BYTES)) wild_isa++;
    end
  end

  // ---- the run ------------------------------------------------------------
  int  i;
  int  guard;
  logic [20:0] w;
  logic [31:0] got_word;
  logic [7:0]  got;
  int  skipped;

  byte unsigned hp[$];
  byte unsigned image[$];
  string        image_path;
  string        expect_text = "55";

  // Same shape as tb_core's loader, and for the same reason: the image is
  // assembled from source by run.sh, so the RTL and the emulator always run
  // identical bits.
  task automatic load_image(input string path);
    int fd, c;
    begin
      image.delete();
      fd = $fopen(path, "rb");
      if (fd == 0) begin
        fail($sformatf("cannot open %s", path));
        return;
      end
      c = $fgetc(fd);
      while (c >= 0) begin
        image.push_back(8'(c));
        c = $fgetc(fd);
      end
      $fclose(fd);
    end
  endtask

  initial begin
    // The button is pulled up, so the machine's power-on reset is the debounce
    // counter rather than an asserted button. Pressing it here as well would
    // only test the debouncer.
    rst_n = 1'b1;

    // Calibration, then the copy. Both are long by simulation standards: the
    // model calibrates in 200 clk_out cycles and the copier writes one byte
    // per burst.
    // `!==` rather than `!`, throughout. Every one of these signals is X until
    // its first clock edge, `!X` is X, and a `while` on X does not run -- so
    // the first version of this fell through all three waits at time zero and
    // reported the boot copy finished before the crystal had ticked.
    guard = 0;
    while (dut.calib !== 1'b1 && guard < 20000) begin
      @(posedge dut.clk_sys);
      guard++;
    end
    if (dut.calib !== 1'b1) begin
      fail("calibration never reported into the core's domain");
      $display("checks=%0d errors=%0d", checks, errors);
      $display("TB_FAIL tb_soc: %0d error(s)", errors);
      $finish;
    end
    checks++;

    guard = 0;
    while (dut.booting !== 1'b0 && guard < 50000) begin
      @(posedge dut.clk_sys);
      guard++;
    end
    if (dut.booting !== 1'b0) begin
      fail("the boot copy never finished");
      $display("checks=%0d errors=%0d", checks, errors);
      $display("TB_FAIL tb_soc: %0d error(s)", errors);
      $finish;
    end
    checks++;
    $display("  boot copy finished at %0t, %0d bytes", $time, ROM_BYTES);

    // The last write may still be streaming; the core does not have to wait
    // for it, but this comparison reads the model's array directly and does.
    repeat (200) @(posedge dut.clk_sys);

    // ---- every byte of the program is in memory ----
    skipped = 0;
    for (i = 0; i < ROM_BYTES; i++) begin
      if (core_wrote.exists(i)) begin
        skipped++;                         // the program got there first
        continue;
      end
      ref_addr = ROM_ADDR_BITS'(i);
      @(posedge clk_27m);                  // the ROM read is registered
      #1;
      w = 21'(i >> 2);
      if (!dut.u_psram_ctrl.store.exists(w)) begin
        fail($sformatf("byte %0d: word %0h was never written", i, w));
      end else begin
        got_word = dut.u_psram_ctrl.store[w];
        got      = got_word[(i % 4) * 8 +: 8];
        checks++;
        if (got !== ref_data)
          fail($sformatf("byte %0d: expected %02h, memory holds %02h",
                         i, ref_data, got));
      end
    end

    // Skipping is only legitimate for a handful of bytes at the end of the
    // image. If the program has overwritten most of itself, something else is
    // wrong and this check has stopped meaning anything.
    checks++;
    if (skipped > ROM_BYTES / 4)
      fail($sformatf("the program overwrote %0d of %0d image bytes before they could be checked",
                     skipped, ROM_BYTES));
    if (skipped > 0)
      $display("  %0d image byte(s) skipped: written by the program before the check",
               skipped);

    // ---- and then it runs ----
    guard = 0;
    while (retired < 20 && dut.faulted !== 1'b1 && guard < 20000) begin
      @(posedge dut.clk_sys);
      guard++;
    end

    checks++;
    if (dut.faulted === 1'b1)
      fail($sformatf("the core faulted, cause %0h at %0h",
                     dut.fault_cause_o, dut.fault_addr_o));

    checks++;
    if (retired < 20)
      fail($sformatf("only %0d instructions retired in %0d cycles", retired, guard));

    checks++;
    if (bad_isa > 0)
      fail($sformatf("%0d of %0d retirements had an unknown isa -- a fetch was answered that the core never counted",
                     bad_isa, retired));

    checks++;
    if (reset_iss > 0)
      fail($sformatf("the core issued %0d fetch requests while held in reset; their answers arrive after it starts, paired with issue_addr entries it never wrote",
                     reset_iss));

    checks++;
    if (wild_isa > 0)
      fail($sformatf("%0d of %0d retirements came from outside the %0d bytes that were copied",
                     wild_isa, retired, ROM_BYTES));

    // ---- the program's output, off the wire ------------------------------
    // The boot ROM prints; this is the whole console path end to end -- the
    // core's CSP write, the monitor's buffer, coalescing into a CONSOLE_OUT
    // frame, the UART, and a decoder that checks the CRC. A frame arriving at
    // all is the proof: `get_frame_any` refuses one whose CRC does not match.
    //
    // WHAT IT DOES NOT CHECK is which text, because the boot ROM is whatever
    // `PROG=` last generated and a test that named its output would break the
    // next time somebody built the SoC with a different program. The text check
    // is on the LOADED program below, which this testbench chooses itself.
    await_console_any("the boot program");

    // ---- host control ----------------------------------------------------
    // Everything from here is the host driving the machine through the pins.
    $display("  console after boot: \"%s\"", console);

    hp.delete();
    send_frame(HF_PAUSE, hp);
    expect_reply("PAUSE", HF_STATE, hp);
    checks++;
    if ((hp[0] & FLAG_PAUSED) == 8'd0) fail("PAUSE did not report paused");
    checks++;
    if ((hp[0] & FLAG_BUS_OWNED) == 8'd0) fail("PAUSE did not take the bus");
    checks++;
    if (dut.core_idle !== 1'b1) begin
      fail("the core is not idle after PAUSE");
      $display("    outstanding=%0d f2d.valid=%b halted=%b uop_valid=%b m_valid=%b",
               dut.u_core.outstanding, dut.u_core.f2d.valid, dut.u_core.halted_r,
               dut.u_core.uop_valid, dut.u_core.m_valid);
      $display("    mulw=%b csp_stall=%b cmaint_pending=%b w_active=%b retire_valid=%b rx_seen=%0d",
               dut.u_core.mulw_pending, dut.u_core.csp_stall,
               dut.u_core.cmaint_pending, dut.u_core.w_active,
               dut.u_core.retire_valid, rx_seen);
    end
    $display("  paused at %0t after %0d instructions", $time, retired);

    // ---- write a program over the wire, and read it back -----------------
    // The image is the same file `tb_core` runs, assembled by run.sh, so this
    // cannot drift from what the rest of the suite executes.
    if (!$value$plusargs("image=%s", image_path)) begin
      fail("no +image= given, so load-and-run was not tested");
    end else begin
      load_image(image_path);
      checks++;
      if (image.size() == 0) begin
        fail($sformatf("%s is empty", image_path));
      end else begin
        // Chunked to MAX_PAYLOAD, exactly as `kctl load` does it.
        for (int base = 0; base < image.size(); base += MAX_PAYLOAD - 4) begin
          hp.delete();
          for (int k = 0; k < 4; k++) hp.push_back(8'((base >> (8*k)) & 8'hFF));
          for (int k = 0; k < MAX_PAYLOAD - 4 && base + k < image.size(); k++)
            hp.push_back(image[base + k]);
          send_frame(HF_WRITE, hp);
          expect_reply("WRITE", HF_ACK, hp);
          checks++;
          if ({hp[1], hp[0]} == 16'd0) fail("WRITE accepted nothing");
        end

        // READ IT BACK. This is what proves the write reached memory rather
        // than the data cache, and that the read sees memory rather than a
        // stale line -- the pause flushed one and invalidated the other.
        for (int base = 0; base < image.size(); base += MAX_PAYLOAD) begin
          int want_n;
          want_n = image.size() - base;
          if (want_n > MAX_PAYLOAD) want_n = MAX_PAYLOAD;
          hp.delete();
          for (int k = 0; k < 4; k++) hp.push_back(8'((base >> (8*k)) & 8'hFF));
          hp.push_back(8'(want_n));
          hp.push_back(8'd0);
          send_frame(HF_READ, hp);
          expect_reply("READ", HF_DATA, hp);
          checks++;
          if (hp.size() != want_n) begin
            fail($sformatf("READ at %0d returned %0d bytes, wanted %0d",
                           base, hp.size(), want_n));
          end else begin
            for (int k = 0; k < want_n; k++)
              if (hp[k] !== image[base + k]) begin
                fail($sformatf("memory at %0d reads %02h, wrote %02h",
                               base + k, hp[k], image[base + k]));
                break;
              end
          end
        end
        $display("  loaded and verified %0d bytes over the wire", image.size());

        // ---- run it ------------------------------------------------------
        // RESET puts `pc` back to 0 and invalidates both caches; RESUME lets
        // go. If the instruction cache still held the boot program, this is
        // where it would run the old bytes with every check passing.
        console = "";
        hp.delete();
        send_frame(HF_RESET, hp);
        expect_reply("RESET", HF_STATE, hp);

        hp.delete();
        send_frame(HF_RESUME, hp);
        expect_reply("RESUME", HF_STATE, hp);
        checks++;
        if ((hp[0] & FLAG_PAUSED) != 8'd0) fail("RESUME still reports paused");

        await_console("the loaded program", expect_text);
        $display("  loaded program printed \"%s\"", console);
      end
    end

    $display("  %0d instructions retired, %0d console byte(s) decoded, %0d received",
             retired, uart_bytes, rx_seen);
    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("TB_PASS tb_soc");
    else             $display("TB_FAIL tb_soc: %0d error(s)", errors);
    $finish;
  end

  initial begin
    // Sized to the design rather than picked large: calibration and the copy
    // together are about 130 us, and everything after that is the core running
    // at 13.5 MHz. Five milliseconds is forty times the whole run, and small
    // enough that a hang is a minute rather than an afternoon.
    // Was five milliseconds, which was forty times the boot-and-run this used
    // to be. It now sends and receives a few hundred bytes over a real serial
    // line as well; at 1.6875 Mbaud that is about a millisecond of traffic on
    // top, and the margin is kept generous because a hang here is a minute.
    #40000000;
    $display("TB_FAIL tb_soc: timeout");
    $finish;
  end

endmodule
