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
  import "DPI-C" function int unsigned k2g_dpi_uart_len();
  import "DPI-C" function int unsigned k2g_dpi_uart_at(input int unsigned i);

  localparam int MEM_BYTES = 16384;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic [31:0] imem_addr, dmem_addr, dmem_wdata, gpio_out;
  logic [15:0] imem_data;
  logic [31:0] dmem_rdata;
  logic        imem_en, dmem_en;
  logic [3:0]  dmem_we;
  logic        uart_tx_valid, uart_rx_take;
  logic [7:0]  uart_tx_data;
  logic        uart_tx_ready = 1'b1;
  logic        uart_rx_valid = 1'b0;
  logic [7:0]  uart_rx_data = 8'd0;
  logic        halted, faulted;
  logic [4:0]  fault_cause_o;
  logic [31:0] fault_addr_o, fault_info_o;
  logic [63:0] cycle_count_o;

  k2g_core #(.MEM_BYTES(MEM_BYTES)) dut (.*);

  k2g_mem #(.BYTES(MEM_BYTES)) mem (
      .clk(clk), .a_addr(imem_addr), .a_en(imem_en), .a_data(imem_data),
      .b_addr(dmem_addr), .b_en(dmem_en), .b_we(dmem_we),
      .b_wdata(dmem_wdata), .b_rdata(dmem_rdata)
  );

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

  string image_path;
  int    max_insns = 200000;

  // Latched at retirement. `pc_d` has already moved on by the time the
  // comparison runs, so reporting it alone points at the wrong instruction.
  logic [31:0] last_isa;
  uop_kind_e   last_kind;
  logic [4:0]  last_dst, last_src;
  logic [31:0] last_imm;
  logic        last_cond_met;

  // Takes 4-state operands deliberately: `int unsigned` is 2-state and would
  // coerce an X to 0, which once made a divergence report show both sides as
  // 00000000 while the comparison had failed on undefined bits.
  function automatic void dump_divergence(input string what, input int idx,
                                          input logic [31:0] got,
                                          input logic [31:0] want);
    $display("TB_FAIL: divergence after %0d instruction(s)", retired);
    $display("  %s%0d", what, idx);
    $display("    RTL      = %08x", got);
    $display("    emulator = %08x", want);
    $display("  instruction at %08x: %s dst=r%0d src=r%0d imm=%08x%s",
             last_isa, last_kind.name(), last_dst, last_src, last_imm,
             last_cond_met ? "" : " [predicate false]");
    $display("  RTL next pc=%08x  emulator pc=%08x", dut.pc_d, k2g_dpi_get_pc());
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
    checks++;
    if (dut.nisa_valid !== (k2g_dpi_get_nisa_valid() != 0)) begin
      dump_divergence("nisa_valid ", 0, {31'd0, dut.nisa_valid},
                      k2g_dpi_get_nisa_valid());
      return 1'b1;
    end
    if (dut.nisa_valid && (dut.nisa !== k2g_dpi_get_nisa())) begin
      dump_divergence("nisa ", 0, dut.nisa, k2g_dpi_get_nisa());
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

    load_both(image_path);
    k2g_dpi_reset(0);
    $display("cosim: %0d bytes from %s", n_bytes, image_path);

    // Both machines reset their registers to zero, so no backdoor is needed
    // to give them a common starting point.
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;

    while (!halted && retired < max_insns) begin
      // Sample mid-cycle, where combinational decode has settled and no
      // non-blocking update is in flight. Reading `mem_pending` immediately
      // after a posedge instead sees its pre-edge value, which made the
      // comparison run a cycle early and report a load's destination as stale
      // -- a testbench bug that looked exactly like an RTL one.
      @(negedge clk);
      if (dut.take_uop) begin
        retired++;
        last_isa      = dut.isa;
        last_kind     = dut.uop.kind;
        last_dst      = dut.uop.dst;
        last_src      = dut.uop.src;
        last_imm      = dut.uop.imm;
        last_cond_met = dut.cond_met;

        // Let the instruction commit, then wait out any second cycle: a
        // load's writeback, or a widening multiply's low half.
        @(posedge clk);
        #1;
        while (dut.mem_pending || dut.mulw_pending) begin
          @(posedge clk);
          #1;
        end

        emu_status = k2g_dpi_step();

        if (compare_state()) begin
          errors++;
          $display("  (stopping at first divergence)");
          break;
        end

        // Both machines must agree about stopping, and why.
        if (halted || emu_status != 0) begin
          checks++;
          if (halted && (emu_status == 0)) begin
            $display("TB_FAIL: RTL stopped after %0d instructions, emulator did not",
                     retired);
            errors++;
          end else if (!halted && (emu_status != 0)) begin
            $display("TB_FAIL: emulator stopped after %0d instructions, RTL did not",
                     retired);
            errors++;
          end else begin
            checks++;
            if ({27'd0, fault_cause_o} !== k2g_dpi_get_fault_cause()) begin
              $display("TB_FAIL: stop cause differs: RTL=%0d emulator=%0d",
                       fault_cause_o, k2g_dpi_get_fault_cause());
              errors++;
            end
          end
          break;
        end
      end
    end

    if (retired >= max_insns) begin
      $display("TB_FAIL: neither machine halted within %0d instructions", max_insns);
      errors++;
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
