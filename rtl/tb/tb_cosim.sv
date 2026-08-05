// Lockstep cosimulation: the RTL core against the Rust emulator.
//
// Both machines execute the same image. After every instruction the RTL
// retires, the emulator is stepped once and ALL architectural state is
// compared -- 32 register values, 32 tags, 32 flag pairs, the program counter
// and the jump latch. That is roughly 1200 bits per instruction, against the
// couple of dozen output bytes a program's UART traffic would check.
//
// The point is not only breadth but localization: a divergence is reported at
// the instruction that caused it, with both machines' state, rather than
// whenever the program's output eventually looks wrong.
//
// SYNCHRONIZATION IS BY CONTRACT, NOT BY INTERNALS. The core raises
// `retire_valid` in the cycle after every architectural write of an
// instruction has committed, and `retire` names that instruction. This
// testbench used to reach in for `take_uop`, `mem_pending` and `mulw_pending`
// and open-code the wait for a load's second cycle, which pinned it to a
// two-stage machine -- the one shape the core is about to stop having.
//
// The register arrays are still read hierarchically (`dut.u_rf.*`), and that
// is deliberate: they *are* the architectural state, and `k2g_regfile` stays a
// module across the rewrite. The jump latch is read the same way for the same
// reason.

`include "k2g_types.svh"

module tb_cosim
  import k2g_pkg::*;
  import k2g_types::*;
;

  // ---- emulator, through DPI --------------------------------------------
  // Fixed-size unpacked arrays: an unsized open array passes a handle rather
  // than a pointer and reads back as zeros.
  import "DPI-C" function void k2g_dpi_init(input int unsigned mem_bytes);
  import "DPI-C" function void k2g_dpi_load(input int unsigned addr,
                                            input int unsigned data);
  import "DPI-C" function void k2g_dpi_reset(input int unsigned entry);
  import "DPI-C" function int  k2g_dpi_step();
  import "DPI-C" function void k2g_dpi_get_regs (output int unsigned r [32]);
  import "DPI-C" function void k2g_dpi_get_tags (output int unsigned r [32]);
  import "DPI-C" function void k2g_dpi_get_flags(output int unsigned r [32]);
  import "DPI-C" function int unsigned k2g_dpi_get_pc();
  import "DPI-C" function int unsigned k2g_dpi_get_nisa();
  import "DPI-C" function int unsigned k2g_dpi_get_nisa_valid();
  import "DPI-C" function int unsigned k2g_dpi_get_fault_cause();
  import "DPI-C" function int unsigned k2g_dpi_get_fault_addr();
  import "DPI-C" function int unsigned k2g_dpi_get_fault_info();
  import "DPI-C" function int unsigned k2g_dpi_mem_dirty_count();
  import "DPI-C" function int unsigned k2g_dpi_mem_dirty_addr(input int unsigned i);
  import "DPI-C" function int unsigned k2g_dpi_mem_read32(input int unsigned addr);
  import "DPI-C" function int unsigned k2g_dpi_uart_len();
  import "DPI-C" function int unsigned k2g_dpi_uart_at(input int unsigned i);

  // The v2 address space: 8 MB of PSRAM, flat at 0. It is the fault boundary,
  // so the emulator is initialized from this same number (k2g_dpi_init below)
  // and the two cannot drift.
  //
  // The behavioural `k2g_mem` behind the bus really is eight megabytes here,
  // rather than a small array with the boundary set high. Measured: the full
  // sweep goes from 63 to 76 seconds, which is worth it -- a short array with
  // a distant boundary aliases in the RTL and reads zero in the emulator, so
  // any access above the array is a divergence with no cause visible in either
  // machine.
  localparam int MEM_BYTES = 8 * 1024 * 1024;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic [31:0] imem_addr, dmem_addr, dmem_wdata, gpio_out;
  logic [31:0] imem_data;
  logic [31:0] dmem_rdata;
  logic        imem_en, dmem_en;
  logic [3:0]  dmem_we;

  // Extra memory latency, from +latency=N and +ilatency=N. Defaults to 0 so
  // the normal run reproduces the fixed one-cycle ports exactly; cosim.sh
  // sweeps them. The instruction side is swept separately because a slow
  // fetch and a slow load exercise entirely different machinery -- credit and
  // stream abandonment on one side, the pending-load path on the other.
  int unsigned latency  = 0;
  int unsigned ilatency = 0;
  logic        uart_tx_valid, uart_rx_take;
  logic [7:0]  uart_tx_data;
  logic        uart_tx_ready;
  logic        uart_rx_valid = 1'b0;
  logic [7:0]  uart_rx_data = 8'd0;
  logic        halted, faulted;
  logic [4:0]  fault_cause_o;
  logic [31:0] fault_addr_o, fault_info_o;
  logic [63:0] cycle_count_o;
  logic        retire_valid;
  retire_t     retire;
  logic        cmaint_req, cmaint_done;
  logic        iinval_req, iinval_busy;
  logic        cm_dflush_req;

  // ---- random pause injection, from +pause=N -----------------------------
  //
  // THIS IS THE TEST THAT MATTERS FOR HOST CONTROL, and it is the same
  // argument as `+latency`: nothing commits during a pause, so a paused run
  // and an unpaused one must produce BYTE-IDENTICAL results. Any divergence
  // means the core is reading state it does not own.
  //
  // `fetch_hold` stops the front end and the pipeline drains on its own, so
  // holding it for a random stretch at a random moment lands the stop in every
  // part of every instruction -- mid prefix chain, with a load outstanding,
  // between a widening multiply's two cycles. None of those may be visible.
  //
  // N is the rate: roughly one pause every 512/N cycles, held for up to 63.
  // Drawn from an LFSR so a failure is reproducible from the seed.
  int unsigned pause_rate = 0;

  logic        fetch_hold;
  logic        idle;
  logic [15:0] pause_lfsr = 16'hACE1;
  logic [5:0]  pause_left = 6'd0;
  int          pause_count = 0;

  assign fetch_hold = (pause_left != 6'd0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pause_left <= 6'd0;
    end else begin
      pause_lfsr <= {pause_lfsr[14:0],
                     pause_lfsr[15] ^ pause_lfsr[13] ^ pause_lfsr[12] ^
                     pause_lfsr[10]};
      if (pause_left != 6'd0) begin
        pause_left <= pause_left - 6'd1;
      end else if (pause_rate != 0 &&
                   (pause_lfsr[8:0] < 9'(pause_rate))) begin
        pause_left  <= pause_lfsr[13:8] | 6'd1;
        pause_count <= pause_count + 1;
      end
    end
  end

  k2g_membus dbus ();
  k2g_membus ibus ();

  k2g_core #(.MEM_BYTES(MEM_BYTES)) dut (.*);

  // THE INSTRUCTION CACHE IS IN THE PATH HERE, not bypassed. A cache is
  // supposed to be architecturally invisible, and this is the only test that
  // can say so: every register, tag and flag is compared after every
  // instruction, so a cache that ever answered with a stale line would show up
  // as a decoded instruction that does not match the emulator's.
  //
  // It is also where `k2g_mem_slow`'s burst support is first exercised --
  // nothing else sends `len != 0` at all.
  //
  // `K2G_COSIM_NOCACHE` takes both caches out and wires the core straight to
  // memory. That configuration is not decoration: the caches never accept a
  // request they cannot answer next cycle, so with them in place the core
  // never sees a slow response and its variable-latency machinery -- the whole
  // point of Phase 1's `LATENCY=40` gate -- stops being exercised. Two mutants
  // reported MISSED the moment the data cache landed, which is how this was
  // found. `rtl/sim/cosim.sh` sets it from `NOCACHE=1`.
  k2g_membus ibus_mem ();

`ifdef K2G_COSIM_NOCACHE
  assign ibus_mem.req_valid = ibus.req_valid;
  assign ibus_mem.req       = ibus.req;
  assign ibus.req_ready     = ibus_mem.req_ready;
  assign ibus.rsp_valid     = ibus_mem.rsp_valid;
  assign ibus.rsp_data      = ibus_mem.rsp_data;
  assign iinval_busy        = 1'b0;
`else
  k2g_icache u_icache (
      .clk       (clk),
      .rst_n     (rst_n),
      .up        (ibus),
      .down      (ibus_mem),
      .inval_req (iinval_req),
      .inval_busy(iinval_busy)
  );
`endif


  // The fetch port is read-only, so the same model serves it: `we` is always
  // zero. Responses are whole words on both ports now -- the core picks the
  // code point out of one (k2g_membus.sv).
  k2g_mem_slow u_islow (
      .clk        (clk),
      .rst_n      (rst_n),
      .max_latency(ilatency),
      .bus        (ibus_mem),
      .b_addr     (imem_addr),
      .b_en       (imem_en),
      .b_we       (),
      .b_wdata    (),
      .b_rdata    (imem_data)
  );

  // THE DATA CACHE IS IN THE PATH HERE TOO, and it is write-back, which the
  // memory comparison at the end has to account for: dirty lines that never
  // got evicted are in the cache and not in memory, and the emulator has no
  // cache. `dflush` below empties it before anything is compared.
  k2g_membus dbus_mem ();

  logic dflush_req = 1'b0;
  logic dflush_busy;

`ifdef K2G_COSIM_NOCACHE
  assign dbus_mem.req_valid = dbus.req_valid;
  assign dbus_mem.req       = dbus.req;
  assign dbus.req_ready     = dbus_mem.req_ready;
  assign dbus.rsp_valid     = dbus_mem.rsp_valid;
  assign dbus.rsp_data      = dbus_mem.rsp_data;
  assign dflush_busy        = 1'b0;
  // No caches, so ICINVR has nothing to do and completes the cycle it is
  // asked. The instruction is still decoded and still stalls for a cycle,
  // which is what makes the two configurations comparable.
  assign cmaint_done        = cmaint_req;
`else
  k2g_dcache u_dcache (
      .clk       (clk),
      .rst_n     (rst_n),
      .up        (dbus),
      .down      (dbus_mem),
      .flush_req (dflush_req || cm_dflush_req),
      .flush_busy(dflush_busy)
  );

  // ICINVR, sequenced exactly as the SoC does it: clean the data cache, then
  // drop the instruction cache. `dflush_req` above is the testbench's own
  // end-of-run flush, which shares the same port.
  // The monitor's request port is unused here -- there is no monitor in this
  // testbench, only the core -- so it is tied off rather than left floating.
  k2g_cache_maint u_cmaint (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_a      (cmaint_req),
      .done_a     (cmaint_done),
      .req_b      (1'b0),
      .done_b     (),
      .dflush_req (cm_dflush_req),
      .dflush_busy(dflush_busy),
      .iinval_req (iinval_req),
      .iinval_busy(iinval_busy)
  );
`endif


  k2g_mem_slow u_slow (
      .clk        (clk),
      .rst_n      (rst_n),
      .max_latency(latency),
      .bus        (dbus_mem),
      .b_addr     (dmem_addr),
      .b_en       (dmem_en),
      .b_we       (dmem_we),
      .b_wdata    (dmem_wdata),
      .b_rdata    (dmem_rdata)
  );

  // Every word the data port writes, so the memory comparison at the end has a
  // set to walk rather than 2M words to scan. The emulator's side of that set
  // comes from diffing its memory against the image it was handed, so the two
  // together cover a store either machine made and the other did not.
  bit rtl_written [int];
  always_ff @(posedge clk) begin
    if (rst_n && dmem_en && (dmem_we != 4'b0000)) begin
      rtl_written[int'(dmem_addr) >> 2] = 1'b1;
    end
  end

  k2g_mem #(.BYTES(MEM_BYTES)) mem (
      .clk(clk), .a_addr(imem_addr), .a_en(imem_en), .a_data(imem_data),
      .b_addr(dmem_addr), .b_en(dmem_en), .b_we(dmem_we),
      .b_wdata(dmem_wdata), .b_rdata(dmem_rdata)
  );

  // A REALISTIC transmitter: busy for a while after each accepted byte.
  //
  // Holding `ready` high forever is what let a flow-control bug reach
  // hardware. The core is roughly fifty times faster than a 115200 baud line,
  // so a testbench that always accepts instantly cannot see the difference
  // between a design with backpressure and one without.
  localparam int TX_BUSY_CYCLES = 40;
  int tx_busy = 0;
  always_ff @(posedge clk) begin
    if (uart_tx_valid && uart_tx_ready) tx_busy <= TX_BUSY_CYCLES;
    else if (tx_busy > 0)               tx_busy <= tx_busy - 1;
  end
  assign uart_tx_ready = (tx_busy == 0);

  byte unsigned rtl_uart [$];
  always_ff @(posedge clk) begin
    if (uart_tx_valid) rtl_uart.push_back(uart_tx_data);
  end

  // ---- state comparison --------------------------------------------------
  int unsigned emu_regs [32];
  int unsigned emu_tags [32];
  int unsigned emu_flags[32];

  int retired = 0;
  int errors  = 0;
  int checks  = 0;

  task automatic dflush();
    int n;
    dflush_req = 1'b1;
    n = 0;
    while (!dflush_busy && n < 1000)   begin @(posedge clk); n++; end
    dflush_req = 1'b0;
    while (dflush_busy && n < 200000)  begin @(posedge clk); n++; end
    if (n >= 200000) begin
      $display("TB_FAIL: the data cache flush never finished");
      errors++;
    end
  endtask


  string image_path;
  int    max_insns = 200000;
  // The cause a generated faulting image is supposed to stop with, supplied by
  // the generator that built it (`kgen --fault-cause`). Empty means no
  // expectation, which is every other image.
  //
  // Agreement between the two machines is not the same as either being right:
  // a program written to test a fault passes the comparison just as well by
  // not faulting at all, in both machines. For the shipped programs that is
  // settled in emu/tests/programs.rs, where the expected cause is a FaultCause
  // rather than a string and a wrong one will not compile. A generated image
  // has no source file to hang a table off, and what needs checking is
  // precisely that kgen's chosen instruction and its reported cause still
  // agree -- so for those it is checked here.
  string expect_cause = "";
  // A program that never halts is a legitimate thing to compare: run it to the
  // instruction budget and pass if the two machines agreed the whole way.
  logic  forever_ok = 1'b0;

  // Cycles seen with no retirement. A pipelined core can legitimately go
  // quiet for a long time on a slow bus, so this only catches a genuine
  // deadlock -- the loop no longer has `halted` to tell it when to stop.
  int    stuck = 0;
  localparam int STUCK_LIMIT = 100000;
  logic  stopped;

  // Takes 4-state operands deliberately: `int unsigned` is 2-state and would
  // coerce an X to 0, which once made a divergence report show both sides as
  // 00000000 while the comparison had failed on undefined bits.
  //
  // The instruction context comes from `retire`, which the core latched when
  // the instruction was taken. Recomputing it here from the fetch state would
  // name the wrong instruction: by the time a load retires, the front end has
  // moved on.
  function automatic void dump_divergence(input string what, input int idx,
                                          input logic [31:0] got,
                                          input logic [31:0] want);
    $display("TB_FAIL: divergence after %0d instruction(s)", retired);
    $display("  %s%0d", what, idx);
    $display("    RTL      = %08x", got);
    $display("    emulator = %08x", want);
    $display("  instruction at %08x: %s dst=r%0d src=r%0d imm=%08x%s",
             retire.isa, retire.kind.name(), retire.dst, retire.src, retire.imm,
             retire.cond_met ? "" : " [predicate false]");
    $display("  emulator pc=%08x", k2g_dpi_get_pc());
  endfunction

  // Compares everything architecturally visible. Returns 1 on a mismatch.
  function automatic logic compare_state();
    logic bad = 1'b0;
    k2g_dpi_get_regs(emu_regs);
    k2g_dpi_get_tags(emu_tags);
    k2g_dpi_get_flags(emu_flags);

    for (int i = 0; i < 32; i++) begin
      checks++;
      if (dut.u_rf.values[i] !== emu_regs[i]) begin
        dump_divergence("register value r", i, dut.u_rf.values[i], emu_regs[i]);
        bad = 1'b1;
      end
      if ({29'd0, dut.u_rf.tags[i]} !== emu_tags[i]) begin
        dump_divergence("register tag r", i, {29'd0, dut.u_rf.tags[i]}, emu_tags[i]);
        bad = 1'b1;
      end
      if ({30'd0, dut.u_rf.overflow[i], dut.u_rf.flagbit[i]} !== emu_flags[i]) begin
        dump_divergence("register flags r", i,
                        {30'd0, dut.u_rf.overflow[i], dut.u_rf.flagbit[i]},
                        emu_flags[i]);
        bad = 1'b1;
      end
      if (bad) return 1'b1;   // stop at the first divergence
    end

    // The jump latch is architectural even though no instruction reads it
    // directly: a mismatch here means a branch is about to go wrong.
    //
    // Taken from the retirement packet, not from the live latch. Execute runs
    // ahead of retirement, so `dut.nisa` at this moment belongs to an
    // instruction two further on -- which showed up as a phantom divergence
    // the moment writeback got its own stage.
    checks++;
    if (retire.nisa_valid !== (k2g_dpi_get_nisa_valid() != 0)) begin
      dump_divergence("nisa_valid ", 0, {31'd0, retire.nisa_valid},
                      k2g_dpi_get_nisa_valid());
      return 1'b1;
    end
    if (retire.nisa_valid && (retire.nisa !== k2g_dpi_get_nisa())) begin
      dump_divergence("nisa ", 0, retire.nisa, k2g_dpi_get_nisa());
      return 1'b1;
    end
    return 1'b0;
  endfunction

  // ---- image loading -----------------------------------------------------
  int fd, n_bytes;

  task automatic load_both(input string path);
    int c;
    int addr = 0;
    mem.clear_all();
    k2g_dpi_init(MEM_BYTES);
    fd = $fopen(path, "rb");
    if (fd == 0) begin
      $display("TB_FAIL tb_cosim: cannot open %s", path);
      $finish;
    end
    forever begin
      c = $fgetc(fd);
      if (c < 0) break;
      mem.load_byte(addr, byte'(c));
      k2g_dpi_load(addr, c);
      addr++;
    end
    $fclose(fd);
    n_bytes = addr;
  endtask

  // ---- run ---------------------------------------------------------------
  int emu_status;

  initial begin
    if (!$value$plusargs("image=%s", image_path)) begin
      $display("TB_FAIL tb_cosim: no +image= given");
      $finish;
    end
    void'($value$plusargs("max=%d", max_insns));
    void'($value$plusargs("expect_cause=%s", expect_cause));
    void'($value$plusargs("latency=%d", latency));
    void'($value$plusargs("ilatency=%d", ilatency));
    void'($value$plusargs("pause=%d", pause_rate));
    forever_ok = $test$plusargs("forever");

    load_both(image_path);
    k2g_dpi_reset(0);
    $display("cosim: %0d bytes from %s", n_bytes, image_path);

    // Both machines reset their registers to zero, so no backdoor is needed
    // to give them a common starting point.
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;

    // Driven by the retirement contract alone, never by `halted`.
    //
    // `halted` rises when the stopping instruction executes, but its
    // retirement follows once every write it owns has committed -- two cycles
    // later now that writeback has its own stage, and further still as more
    // stages appear. A loop that exits on `halted` drops the last instruction
    // on the floor and reports "RTL stopped, emulator did not", which reads
    // exactly like a core bug and is not one.
    //
    // `retire.cause` says whether the instruction that just retired stopped
    // the machine, so nothing here has to know how deep the pipeline is.
    while (retired < max_insns && stuck < STUCK_LIMIT) begin
      // Sample mid-cycle, away from the clock edge, so the retirement flops
      // have settled and no non-blocking update is in flight.
      //
      // No second cycle is waited out here any more. `retire_valid` already
      // means every architectural write of that instruction has committed, so
      // the register file is comparable right now. The old version reproduced
      // the core's own multi-cycle sequencing in the testbench, and getting it
      // subtly wrong looked exactly like an RTL bug.
      @(negedge clk);
      if (!retire_valid) begin
        stuck++;
        continue;
      end
      begin
        stuck = 0;
        retired++;

        emu_status = k2g_dpi_step();

        if (compare_state()) begin
          errors++;
          $display("  (stopping at first divergence)");
          break;
        end

        // Both machines must agree about stopping, and why. Asked of the
        // retired instruction rather than of the machine, so the answer does
        // not depend on how many cycles `halted` leads retirement by.
        stopped = (retire.cause != FAULT_NONE);
        if (stopped && (expect_cause != "")) begin
          // Compared by name so the expectation in the .kasm reads as the
          // cause does everywhere else, and so no numeric table has to be
          // kept in step in the shell script.
          checks++;
          if (retire.cause.name() != expect_cause) begin
            $display("TB_FAIL: expected to stop with %s, stopped with %s",
                     expect_cause, retire.cause.name());
            errors++;
          end
        end
        if (stopped || emu_status != 0) begin
          checks++;
          if (stopped && (emu_status == 0)) begin
            $display("TB_FAIL: RTL stopped after %0d instructions, emulator did not",
                     retired);
            errors++;
          end else if (!stopped && (emu_status != 0)) begin
            $display("TB_FAIL: emulator stopped after %0d instructions, RTL did not",
                     retired);
            errors++;
          end else begin
            // `retire.cause` rather than `fault_cause_o`: it says this
            // *instruction* stopped the machine and why, which is what the
            // emulator's step just reported. The sticky fault register only
            // says the machine is stopped.
            checks++;
            if ({27'd0, retire.cause} !== k2g_dpi_get_fault_cause()) begin
              $display("TB_FAIL: stop cause differs: RTL=%s(%0d) emulator=%0d",
                       retire.cause.name(), retire.cause, k2g_dpi_get_fault_cause());
              errors++;
            end
            // `fault_addr` and `fault_info` are latched by the same fault, and
            // the sticky registers are the only place they exist -- unlike the
            // cause, they are not in the retirement packet.
            //
            // They went unchecked until now, and drifted: every decode fault
            // reported its code point in the emulator and 0 in the RTL, which
            // is what a halted machine's monitor prints and a debugger reads
            // (spec 8). Nothing else can catch that -- a program cannot read
            // its own fault registers, because it is no longer running.
            checks++;
            if (fault_addr_o !== k2g_dpi_get_fault_addr()) begin
              $display("TB_FAIL: fault_addr differs: RTL=%08x emulator=%08x",
                       fault_addr_o, k2g_dpi_get_fault_addr());
              errors++;
            end
            checks++;
            if (fault_info_o !== k2g_dpi_get_fault_info()) begin
              $display("TB_FAIL: fault_info differs: RTL=%08x emulator=%08x",
                       fault_info_o, k2g_dpi_get_fault_info());
              errors++;
            end
          end
          break;
        end
      end
    end

    // THE LOOP CAN ALSO EXIT BECAUSE THE CORE STOPPED RETIRING, and until this
    // check existed that was silent: the loop fell out, the emulator had not
    // been stepped either -- it only steps on a retirement -- so both machines
    // agreed about everything, the UART comparison found two empty streams,
    // and the run passed. A deadlocked machine was indistinguishable from a
    // correct one.
    //
    // Found by a mutant, not by reasoning: inverting the instruction cache's
    // tag comparison makes every line miss forever, so the core never receives
    // a code point. That reported MISSED, which is what a vacuous pass looks
    // like from the outside.
    checks++;
    if (stuck >= STUCK_LIMIT) begin
      $display("TB_FAIL: the core stopped retiring -- %0d cycles with no instruction, after %0d retired",
               STUCK_LIMIT, retired);
      errors++;
    end

    if (retired >= max_insns) begin
      if (forever_ok) begin
        $display("ran %0d instructions in lockstep without divergence", retired);
      end else begin
        $display("TB_FAIL: neither machine halted within %0d instructions", max_insns);
        errors++;
      end
    end

    // UART traffic must match too -- it is the one piece of state the
    // register comparison cannot see.
    checks++;
    if (rtl_uart.size() != k2g_dpi_uart_len()) begin
      $display("TB_FAIL: UART length differs: RTL=%0d emulator=%0d",
               rtl_uart.size(), k2g_dpi_uart_len());
      errors++;
    end else begin
      for (int i = 0; i < rtl_uart.size(); i++) begin
        if ({24'd0, rtl_uart[i]} !== k2g_dpi_uart_at(i)) begin
          $display("TB_FAIL: UART byte %0d differs: RTL=%02x emulator=%02x",
                   i, rtl_uart[i], k2g_dpi_uart_at(i));
          errors++;
          break;
        end
      end
    end

    // Memory, which nothing compared until now. A store is not visible in any
    // register, so a core that faults AND stores -- or that suppresses a store
    // it should have made -- passed every other check here. Removing the
    // reserved-tag gate from `mem_access` in k2g_core.sv left f32_store green,
    // which is what this closes.
    //
    // Compared once, at the stop, over the union of the two write sets rather
    // than per instruction over the whole 8 MB. Memory divergence persists --
    // unlike a register, nothing overwrites it back into agreement -- so
    // checking at the end loses nothing but the instruction number.
    begin
      int unsigned n_dirty;
      int unsigned addr;
      bit          seen [int];
      int unsigned rtl_word;

      // Empty the write-back cache first. Without this every store still
      // sitting in a dirty line reads as a divergence -- the RTL's memory
      // genuinely does not have it yet, and the emulator's does.
      dflush();

      n_dirty = k2g_dpi_mem_dirty_count();
      for (int unsigned i = 0; i < n_dirty; i++) begin
        seen[int'(k2g_dpi_mem_dirty_addr(i)) >> 2] = 1'b1;
      end
      foreach (rtl_written[idx]) seen[idx] = 1'b1;

      foreach (seen[idx]) begin
        addr     = int'(unsigned'(idx)) << 2;
        rtl_word = {mem.lane3[idx], mem.lane2[idx], mem.lane1[idx], mem.lane0[idx]};
        checks++;
        if (rtl_word !== k2g_dpi_mem_read32(addr)) begin
          $display("TB_FAIL: memory at %08x differs: RTL=%08x emulator=%08x",
                   addr, rtl_word, k2g_dpi_mem_read32(addr));
          errors++;
        end
      end
    end

    // Reported so a run with `+pause=` cannot pass by never having paused --
    // which is what a rate the LFSR's low bits happen never to reach would
    // look like, and it would look exactly like success.
    if (pause_rate != 0)
      $display("pauses=%0d", pause_count);

    $display("retired=%0d checks=%0d errors=%0d", retired, checks, errors);
    if (errors == 0) $display("TB_PASS tb_cosim");
    else             $display("TB_FAIL tb_cosim: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #200000000;
    $display("TB_FAIL tb_cosim: timeout");
    $finish;
  end

endmodule
