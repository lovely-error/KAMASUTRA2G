// Stage 4 of bring-up: the whole machine on a Tang Nano 9K.
//
//   boot ROM -> copier -> 8 MB in-package PSRAM -> K2G core -> UART
//
// The copier exists because GowinSynthesis will not initialize an inferred RAM
// from `$readmemh`. The program therefore lives in logic (see `mkrom`) and is
// copied into memory at reset, with the CPU held in reset until it finishes.
// That is also what a real system does when it copies from flash into RAM.
//
// MEMORY IS PSRAM NOW, and the BSRAM is gone from this design entirely -- the
// blocks it used are spent on Phase 4's caches instead. Three consequences
// worth having in view before reading further:
//
//   * memory has a clock domain of its own. Everything below is in `clk_sys`
//     and crosses to the controller's `clk_out` inside `k2g_psram`, through
//     `k2g_cdc_fifo` and nothing else;
//   * it must calibrate before it will answer, which takes hundreds of
//     microseconds. Nothing waits for that explicitly: requests queue and the
//     copier back-pressures until the memory is ready, so `booting` simply
//     takes longer. LED0 blinking on its own is what "still calibrating" looks
//     like, and a machine wedged there has a memory problem rather than a CPU
//     one;
//   * PSRAM does not power up as zeros. The BSRAM did, so a program that read
//     a location it had not written used to get 0 and now gets whatever was
//     there. Nothing in `emu/programs/` does, but a program that starts
//     behaving differently on the board than under cosimulation should be
//     suspected of it first.
//
// The LEDs carry machine status rather than decoration: on a halted or faulted
// machine they are the only thing that says why, since a stopped core cannot
// execute a CSP read to report its own fault cause (spec 8).

`include "k2g_types.svh"
`include "k2g_rom.svh"

module k2g_soc
  import k2g_pkg::*;
  import k2g_types::*;
#(
    // The in-package PSRAM, flat at address 0 and all of memory. This is where
    // ADDR_OUT_OF_RANGE begins (spec 8), so it is architecture rather than
    // configuration and the emulator carries the same number.
    parameter int MEM_BYTES = 8 * 1024 * 1024,
    parameter int XTAL_HZ   = 27_000_000,
    // The core runs on a divided crystal because its execute path has never
    // met 27 MHz. v1 was 28 logic levels deep and placed at 10.0 MHz, so it
    // ran at 27/4 = 6.75 MHz.
    //
    // Giving decode its own stage (docs/v2-plan.md, Phase 2b) took that to
    // 14.53 MHz, which clears 13.5 with about 7% to spare, so this is now 2.
    // Going to 1 needs 27 MHz and is what splitting execute from writeback is
    // for.
    //
    // MUST be a power of two, and the .sdc constraint names the divider bit
    // directly -- change one and the other has to follow, or the tool
    // cheerfully reports timing against a clock the design does not have.
    parameter int CLK_DIV   = 2,
    parameter int BAUD      = 115_200,

    // How long the reset button must read steady before it is believed, in
    // clk_sys cycles -- 10 ms, since this board has no hardware debounce and
    // one press otherwise produces a burst of edges.
    //
    // A parameter rather than a localparam only so `tb_soc` can shorten it. At
    // 13.5 MHz this is 135000 cycles, and simulating ten milliseconds of a
    // button nobody is pressing costs more than the whole rest of the run --
    // calibration, the boot copy and the program together are about 150 us.
    parameter int DEBOUNCE  = XTAL_HZ / CLK_DIV / 100
) (
    input  logic       clk_27m,
    input  logic       rst_n,
    output logic [5:0] led,
    output logic       uart_tx,
    input  logic       uart_rx,

    // In-package PSRAM. No IO_LOC in the .cst -- these are dedicated pins the
    // IP places itself, which is why the psram bring-up stage builds against
    // the same constraints file as everything else.
    output logic [1:0]  O_psram_ck,
    output logic [1:0]  O_psram_ck_n,
    inout  wire  [15:0] IO_psram_dq,
    inout  wire  [1:0]  IO_psram_rwds,
    output logic [1:0]  O_psram_cs_n,
    output logic [1:0]  O_psram_reset_n
);

  localparam int CLK_HZ  = XTAL_HZ / CLK_DIV;      // 6.75 MHz
  localparam int DIVISOR = CLK_HZ / BAUD;          // 58 -> 116379 baud, 1.0%

  // ---- clock division ----------------------------------------------------
  //
  // POWER-UP VALUES ARE WRITTEN DOWN, here and in the debouncer below. This
  // design has always depended on them -- the divider has no reset, and the
  // debouncer cannot have one because it *is* the reset generator -- and Gowin
  // flip-flops come up at 0, so on hardware it has always worked. In
  // simulation an uninitialized counter is X, `X + 1` is X, and `clk_sys`
  // never toggles: the machine simply does not start, and the first run of
  // `tb_soc` sat at time zero until its timeout with nothing to say why.
  //
  // Stating the value is not a simulation hack. It says in the source what the
  // hardware already does, which is the only reason the comment at
  // `rst_stable` below could claim it.
  logic [1:0] div = 2'd0;
  always_ff @(posedge clk_27m) div <= div + 2'd1;

  // A divided clock rather than a clock enable: an enable would still require
  // the combinational path to settle inside one 27 MHz period unless the
  // timing constraints declared a multicycle path, and getting that wrong
  // fails silently on hardware rather than loudly in the report.
  //
  // Derived from CLK_DIV rather than hardcoded. It used to be `div[1]` with
  // CLK_DIV only feeding the baud divisor, so changing the parameter moved the
  // baud rate and left the clock alone -- a trap with no symptom until the
  // serial output is garbage.
  // The index is a localparam, not `$clog2(CLK_DIV)-1` inline. That expression
  // in a part-select made GowinSynthesis exit 1 with an empty log and no
  // banner -- the silent failure mode docs/bring-up.md warns about, found by
  // bisecting because there is nothing to read.
  localparam int CLK_SEL = (CLK_DIV == 2) ? 0 : 1;

  wire logic clk_sys = div[CLK_SEL];

  // ---- reset: synchronize, then debounce ---------------------------------
  // The button is asynchronous, so it is synchronized first; releasing reset
  // out of sync with the clock is a reliable way to start in an undefined
  // state.
  logic rst_meta = 1'b0, rst_syncd = 1'b0;
  always_ff @(posedge clk_sys) begin
    rst_meta  <= rst_n;
    rst_syncd <= rst_meta;
  end

  // There is no hardware debounce on this board, so one press of the button
  // produces a burst of edges and the machine runs its program once per edge.
  // The level must hold for DEBOUNCE cycles before it is believed.
  localparam int DB_W = $clog2(DEBOUNCE + 1);

  logic [DB_W-1:0] db_count   = '0;
  logic            rst_stable = 1'b0;

  always_ff @(posedge clk_sys) begin
    if (rst_syncd == rst_stable) begin
      db_count <= '0;
    end else if (db_count == DB_W'(DEBOUNCE)) begin
      rst_stable <= rst_syncd;
      db_count   <= '0;
    end else begin
      db_count <= db_count + DB_W'(1);
    end
  end

  // `rst_stable` powers up at 0, which also gives a clean power-on reset: the
  // machine is held until the button has read released for a full debounce
  // interval.
  logic [3:0] rst_sync = 4'd0;
  wire  logic sys_rst_n = rst_sync[3];

  always_ff @(posedge clk_sys) begin
    rst_sync <= {rst_sync[2:0], rst_stable};
  end

  // ---- boot ROM and copier ----------------------------------------------
  logic [15:0] boot_addr;
  logic [7:0]  boot_data;

  // Sizes come from the ROM's companion header. A parameter inside the ROM
  // module is unreachable (no hierarchical references), and a `define in the
  // ROM source is not visible here (macros do not cross source files).
  localparam int ROM_BYTES     = `K2G_ROM_BYTES;
  localparam int ROM_ADDR_BITS = `K2G_ROM_ADDR_BITS;

  k2g_rom u_rom (
      .addr(boot_addr[ROM_ADDR_BITS-1:0]),
      .data(boot_data)
  );

  // The copier is now a bus master like any other, so it advances on
  // `req_ready` rather than once per cycle. Behind PSRAM a byte write is a
  // whole 128-byte burst, so the copy takes roughly half a microsecond per
  // byte instead of one cycle -- about 80 us for a 168-byte program, on top of
  // however long calibration takes. Both are invisible to a human and neither
  // needs its own wait state: the requests simply queue.
  //
  // `req_valid` is `booting`, which is a register. It does not look at
  // `req_ready` (k2g_chan.sv rule 3).
  logic        booting;
  logic [15:0] boot_ix;

  k2g_membus cbus ();     // the copier
  k2g_membus dbus ();     // the core's data port
  k2g_membus mbus ();     // whichever of the two owns memory right now
  k2g_membus ibus ();     // the core's fetch port

  assign cbus.req_valid = booting;
  assign cbus.req.addr  = {16'd0, boot_ix};
  assign cbus.req.we    = 4'b0001 << boot_ix[1:0];
  assign cbus.req.wdata = {4{boot_data}};
  // One byte at a time, so one beat. Bursting the copy would be four times
  // faster and is not worth the adder: the whole thing is about 100 us either
  // way, and it happens once.
  assign cbus.req.len   = 5'd0;

  always_ff @(posedge clk_sys) begin
    if (!sys_rst_n) begin
      booting <= 1'b1;
      boot_ix <= 16'd0;
    end else if (booting && cbus.req_ready) begin
      if (boot_ix == 16'(ROM_BYTES - 1)) booting <= 1'b0;
      boot_ix <= boot_ix + 16'd1;
    end
  end

  assign boot_addr = boot_ix;

  // The CPU stays in reset for the whole copy, so it never sees a partly
  // written program -- and the last write does not have to have completed
  // before it starts, because the adapter's sequencer is in order: a fetch
  // issued after the write was accepted cannot overtake it.
  wire logic cpu_rst_n = sys_rst_n && !booting;

  // ---- memory ------------------------------------------------------------
  logic cmaint_req, cmaint_done;
  logic dflush_req, dflush_busy;
  logic iinval_req, iinval_busy;

  // ---- data cache ---------------------------------------------------------
  // Between the core and the mux, so the boot copier writes straight past it.
  // That is what it has to do: the copier is laying down the program while the
  // cache is held in reset, and a cache that saw those writes would have to be
  // flushed before the core could fetch through the instruction cache.
  //
  // `flush_req` is tied off. `ICINVR` is what will drive it -- clean this
  // cache over a range, then invalidate the I$ over the same range -- and
  // until that exists self-modifying code does not work. Nothing in
  // `emu/programs/` tries.
  k2g_membus dbus_mem ();

  k2g_dcache u_dcache (
      .clk       (clk_sys),
      .rst_n     (cpu_rst_n),
      .up        (dbus),
      .down      (dbus_mem),
      .flush_req (dflush_req),
      .flush_busy(dflush_busy)
  );

  k2g_membus_mux u_dmux (
      .sel (!booting),
      .up_a(cbus),
      .up_b(dbus_mem),
      .down(mbus)
  );

  // Memory clock for the controller. The core stays on the divided crystal;
  // this is a separate PLL path and the two are treated as unrelated.
  logic memory_clk, pll_lock;

  k2g_pll u_pll (
      .clk_in    (clk_27m),
      .memory_clk(memory_clk),
      .pll_lock  (pll_lock)
  );

  // Reset for the controller, lifted from k2g_psram_probe where it was found
  // the hard way. The button is pulled up, so it reads released from the
  // instant power is applied -- hand it to the controller raw and the
  // controller leaves reset before the PLL has locked, with `memory_clk` still
  // garbage, and never gets another reset to recover with. Held low until lock
  // has been continuously true for ~10 us, and re-asserted if lock is lost.
  //
  // In clk_27m rather than clk_sys because that is the domain the PLL's
  // reference is in and the one the probe proved this in. The button is
  // synchronized rather than used raw for the usual reason.
  logic       pbtn_meta, pbtn_sync;
  logic       plock_meta, plock_sync;
  logic [8:0] prst_cnt;
  logic       psram_rst_n;

  always_ff @(posedge clk_27m) begin
    pbtn_meta  <= rst_n;
    pbtn_sync  <= pbtn_meta;
    plock_meta <= pll_lock;
    plock_sync <= plock_meta;

    if (!pbtn_sync || !plock_sync) begin
      prst_cnt    <= 9'd0;
      psram_rst_n <= 1'b0;
    end else if (prst_cnt != 9'h1FF) begin
      prst_cnt    <= prst_cnt + 9'd1;
      psram_rst_n <= 1'b0;
    end else begin
      psram_rst_n <= 1'b1;
    end
  end

  logic [63:0] psram_wr_data, psram_rd_data;
  logic [20:0] psram_addr;
  logic [7:0]  psram_data_mask;
  logic        psram_cmd, psram_cmd_en, psram_cmd_rdy;
  logic        psram_rd_valid, psram_calib, psram_clk_out;

  PSRAM_Memory_Interface_HS_Top u_psram_ctrl (
      .clk            (clk_27m),
      .memory_clk     (memory_clk),
      .pll_lock       (pll_lock),
      .rst_n          (psram_rst_n),
      .O_psram_ck     (O_psram_ck),
      .O_psram_ck_n   (O_psram_ck_n),
      .IO_psram_dq    (IO_psram_dq),
      .IO_psram_rwds  (IO_psram_rwds),
      .O_psram_cs_n   (O_psram_cs_n),
      .O_psram_reset_n(O_psram_reset_n),
      .wr_data        (psram_wr_data),
      .rd_data        (psram_rd_data),
      .rd_data_valid  (psram_rd_valid),
      .addr           (psram_addr),
      .cmd            (psram_cmd),
      .cmd_en         (psram_cmd_en),
      .cmd_rdy        (psram_cmd_rdy),
      .init_calib     (psram_calib),
      .clk_out        (psram_clk_out),
      .data_mask      (psram_data_mask)
  );

  // Calibration finished, crossed into clk_sys by the adapter. Nothing in the
  // machine waits for it -- it is for LED0.
  logic calib;

  // ---- instruction cache --------------------------------------------------
  // Held in reset with the CPU rather than with the system, which is what
  // makes the boot copy safe: the copier writes the program through the data
  // port while the cache is invalid, and the cache is released with the core
  // that will first ask it for anything. A cache that came out of reset early
  // could hold a line fetched from memory the copier had not written yet.
  k2g_membus ibus_mem ();

  k2g_icache u_icache (
      .clk       (clk_sys),
      .rst_n     (cpu_rst_n),
      .up        (ibus),
      .down      (ibus_mem),
      .inval_req (iinval_req),
      .inval_busy(iinval_busy)
  );

  k2g_psram u_psram (
      .clk_sys      (clk_sys),
      .rst_n        (sys_rst_n),
      .ibus         (ibus_mem),
      .dbus         (mbus),
      .calib        (calib),
      .clk_out      (psram_clk_out),
      .init_calib   (psram_calib),
      .cmd_rdy      (psram_cmd_rdy),
      .cmd          (psram_cmd),
      .cmd_en       (psram_cmd_en),
      .addr         (psram_addr),
      .wr_data      (psram_wr_data),
      .data_mask    (psram_data_mask),
      .rd_data      (psram_rd_data),
      .rd_data_valid(psram_rd_valid)
  );

  // ---- core --------------------------------------------------------------
  logic        core_tx_valid, core_rx_take;
  logic [7:0]  core_tx_data;
  logic [31:0] gpio_out;
  logic        halted, faulted;
  logic [4:0]  fault_cause_o;
  logic [31:0] fault_addr_o, fault_info_o;
  logic [63:0] cycle_count_o;

  logic       rx_valid, rx_have;
  logic [7:0] rx_data, rx_byte;
  logic       tx_ready;

  k2g_core #(.MEM_BYTES(MEM_BYTES)) u_core (
      .clk          (clk_sys),
      .rst_n        (cpu_rst_n),
      .ibus         (ibus),
      .dbus         (dbus),
      .uart_tx_valid(core_tx_valid),
      .uart_tx_data (core_tx_data),
      .uart_tx_ready(tx_ready),
      .uart_rx_valid(rx_have),
      .uart_rx_data (rx_byte),
      .uart_rx_take (core_rx_take),
      .gpio_out     (gpio_out),
      // Retirement is for the cosimulation, not for the board. Left dangling;
      // measured to cost nothing (4695 -> 4670 LUTs).
      .retire_valid (),
      .retire       (),
      .halted       (halted),
      .faulted      (faulted),
      .fault_cause_o(fault_cause_o),
      .fault_addr_o (fault_addr_o),
      .fault_info_o (fault_info_o),
      .cycle_count_o(cycle_count_o),
      .cmaint_req   (cmaint_req),
      .cmaint_done  (cmaint_done)
  );

  // ---- ICINVR ------------------------------------------------------------
  // The core asks for its stores to become visible to its own fetch; this is
  // what that costs here. Order matters and is enforced inside: clean the data
  // cache first, because the instructions just written are sitting dirty in
  // it, and only then drop the instruction cache.
  k2g_cache_maint u_cmaint (
      .clk        (clk_sys),
      .rst_n      (cpu_rst_n),
      .req        (cmaint_req),
      .done       (cmaint_done),
      .dflush_req (dflush_req),
      .dflush_busy(dflush_busy),
      .iinval_req (iinval_req),
      .iinval_busy(iinval_busy)
  );

  // ---- UART --------------------------------------------------------------
  // Straight ready/valid to the transmitter. The one-byte holding register
  // that used to sit here was the bug: the core does not wait, so each new
  // byte overwrote the one being shifted out. The core now stalls instead,
  // which costs nothing architecturally.
  k2g_uart_tx #(.DIVISOR(DIVISOR)) u_tx (
      .clk  (clk_sys),
      .rst_n(sys_rst_n),
      .valid(core_tx_valid),
      .data (core_tx_data),
      .ready(tx_ready),
      .tx   (uart_tx)
  );

  k2g_uart_rx #(.DIVISOR(DIVISOR)) u_rx (
      .clk  (clk_sys),
      .rst_n(sys_rst_n),
      .rx   (uart_rx),
      .valid(rx_valid),
      .data (rx_data)
  );

  // One byte of receive buffering, consumed when the core reads the port.
  always_ff @(posedge clk_sys) begin
    if (!sys_rst_n) begin
      rx_have <= 1'b0;
      rx_byte <= 8'd0;
    end else if (rx_valid) begin
      rx_byte <= rx_data;
      rx_have <= 1'b1;
    end else if (core_rx_take) begin
      rx_have <= 1'b0;
    end
  end

  // ---- status ------------------------------------------------------------
  // While running: a heartbeat plus whatever the program put in GPIO.
  // Once stopped: the fault cause, which is otherwise unreadable because a
  // halted core cannot execute the CSP read that would report it.
  logic [23:0] heartbeat;
  always_ff @(posedge clk_sys) begin
    if (!sys_rst_n) heartbeat <= '0;
    else            heartbeat <= heartbeat + 24'd1;
  end

  logic [5:0] status;
  always_comb begin
    if (!calib) begin
      // The memory has not finished calibrating, so nothing can make progress.
      // A lone blinking LED0 is deliberately unlike every other display here:
      // it is the one failure that is about the board rather than the program,
      // and the whole point of the staged bring-up is that a display says
      // which layer is at fault. The psram stage is where to go next.
      status = {heartbeat[23], 5'b00001};
    end else if (booting) begin
      status = 6'b111111;                     // all lit during the copy
    end else if (faulted) begin
      status = {1'b1, fault_cause_o};         // top bit marks a fault
    end else if (halted) begin
      status = {1'b0, 5'b10000};              // clean halt
    end else begin
      status = {heartbeat[23], gpio_out[4:0]};
    end
  end

  assign led = ~status;                       // active low

  wire logic _unused = &{1'b0, fault_addr_o, fault_info_o, cycle_count_o,
                         gpio_out[31:5], boot_addr[15:ROM_ADDR_BITS]};

endmodule
