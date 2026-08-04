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

  // The debounce interval is the only thing shortened. Ten milliseconds of a
  // button nobody is pressing is thirty times the length of everything this
  // testbench is actually about.
  k2g_soc #(.DEBOUNCE(4)) dut (
      .clk_27m        (clk_27m),
      .rst_n          (rst_n),
      .led            (led),
      .uart_tx        (uart_tx),
      .uart_rx        (1'b1),
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

  k2g_rom u_ref (.addr(ref_addr), .data(ref_data));

  // ---- scoreboard ---------------------------------------------------------
  int checks = 0;
  int errors = 0;

  task automatic fail(input string msg);
    $display("TB_FAIL tb_soc: %s", msg);
    errors++;
  endtask

  // Bytes handed to the transmitter, counted where the core offers them rather
  // than by decoding the serial line: one byte at 115200 baud is 87 us, and
  // waiting for a few of them would dominate the run.
  int uart_bytes = 0;

  always @(posedge dut.clk_sys) begin
    if (dut.core_tx_valid && dut.tx_ready) uart_bytes++;
  end

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
      #1;                                  // combinational ROM
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

    // The tracked ROM is a program that prints; if a future one does not, this
    // is the check to drop rather than the one to chase.
    guard = 0;
    while (uart_bytes < 1 && guard < 20000) begin
      @(posedge dut.clk_sys);
      guard++;
    end
    checks++;
    if (uart_bytes < 1) fail("nothing reached the transmitter");

    $display("  %0d instructions retired, %0d byte(s) to the UART",
             retired, uart_bytes);
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
    #5000000;
    $display("TB_FAIL tb_soc: timeout");
    $finish;
  end

endmodule
