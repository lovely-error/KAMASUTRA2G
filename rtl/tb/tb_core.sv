// Runs real assembled programs on the core and checks what they produce.
//
// Images come from `kasm`, so this exercises the same path the emulator does:
// one source, assembled once, run on both machines. The plus-arg selects an
// image so the runner can drive several without rebuilding.

`include "k2g_types.svh"

module tb_core
  import k2g_pkg::*;
  import k2g_types::*;
;

  localparam int MEM_BYTES = 8192;

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
  logic        uart_tx_ready;
  logic        uart_rx_valid = 1'b0;
  logic [7:0]  uart_rx_data = 8'd0;
  logic        halted, faulted;
  logic [4:0]  fault_cause_o;
  logic [31:0] fault_addr_o, fault_info_o;
  logic [63:0] cycle_count_o;
  logic        retire_valid;
  retire_t     retire;

  int unsigned latency  = 0;
  int unsigned ilatency = 0;

  k2g_membus dbus ();
  k2g_membus ibus ();

  k2g_core #(.MEM_BYTES(MEM_BYTES)) dut (.*);

  k2g_mem_slow u_islow (
      .clk        (clk),
      .rst_n      (rst_n),
      .max_latency(ilatency),
      .bus        (ibus),
      .b_addr     (imem_addr),
      .b_en       (imem_en),
      .b_we       (),
      .b_wdata    (),
      .b_rdata    ({16'd0, imem_data})
  );

  k2g_mem_slow u_slow (
      .clk        (clk),
      .rst_n      (rst_n),
      .max_latency(latency),
      .bus        (dbus),
      .b_addr     (dmem_addr),
      .b_en       (dmem_en),
      .b_we       (dmem_we),
      .b_wdata    (dmem_wdata),
      .b_rdata    (dmem_rdata)
  );

  k2g_mem #(.BYTES(MEM_BYTES)) mem (
      .clk    (clk),
      .a_addr (imem_addr),
      .a_en   (imem_en),
      .a_data (imem_data),
      .b_addr (dmem_addr),
      .b_en   (dmem_en),
      .b_we   (dmem_we),
      .b_wdata(dmem_wdata),
      .b_rdata(dmem_rdata)
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

  // ---- UART capture ------------------------------------------------------
  byte unsigned uart_out [$];
  always_ff @(posedge clk) begin
    if (uart_tx_valid) uart_out.push_back(uart_tx_data);
  end

  function automatic string uart_string();
    string s = "";
    foreach (uart_out[i]) s = {s, string'(uart_out[i])};
    return s;
  endfunction

  // ---- image loading -----------------------------------------------------
  string image_path;
  int    fd, n_bytes;
  byte unsigned image [$];

  task automatic load_image(input string path);
    int c;
    mem.clear_all();
    image.delete();
    fd = $fopen(path, "rb");
    if (fd == 0) begin
      $display("TB_FAIL tb_core: cannot open %s", path);
      $finish;
    end
    forever begin
      c = $fgetc(fd);
      if (c < 0) break;
      image.push_back(byte'(c));
    end
    $fclose(fd);
    foreach (image[i]) mem.load_byte(i, image[i]);
    n_bytes = image.size();
  endtask

  int checks = 0;
  int errors = 0;

  task automatic check(input string what, input logic ok);
    checks++;
    if (!ok) begin
      errors++;
      $display("TB_FAIL: %s", what);
    end
  endtask

  // Clock cycles from reset release to halt. Distinct from `cycle_count_o`,
  // which counts RETIRED INSTRUCTIONS -- the two differ by the stalls, and it
  // is the clock count that sets wall-clock time.
  int run_cycles = 0;

  // Runs to halt or a step budget.
  task automatic run_program(input int max_cycles);
    int n = 0;
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    while (!halted && n < max_cycles) begin
      @(posedge clk);
      n++;
    end
    run_cycles = n;
    if (!halted) begin
      $display("TB_FAIL: program did not halt within %0d cycles (pc=%08x)",
               max_cycles, dut.pc);
      errors++;
    end
  endtask

  string expect_out;

  initial begin
    if (!$value$plusargs("image=%s", image_path)) begin
      $display("TB_FAIL tb_core: no +image= given");
      $finish;
    end
    if (!$value$plusargs("expect=%s", expect_out)) expect_out = "";

    load_image(image_path);
    $display("loaded %0d bytes from %s", n_bytes, image_path);

    run_program(200000);

    if (faulted) begin
      $display("TB_FAIL: faulted cause=%0d addr=%08x info=%08x",
               fault_cause_o, fault_addr_o, fault_info_o);
      errors++;
    end
    check("halted cleanly", halted && !faulted);

    $display("uart output: \"%s\"", uart_string());
    $display("instructions: %0d", cycle_count_o);
    $display("clock cycles: %0d", run_cycles);
    if (cycle_count_o != 0)
      $display("cycles/instruction: %0.2f",
               real'(run_cycles) / real'(cycle_count_o));

    if (expect_out != "") begin
      // The plus-arg cannot carry a newline, so compare the printable part.
      string got = uart_string();
      string want = expect_out;
      logic  ok = 1'b1;
      if (got.len() < want.len()) ok = 1'b0;
      else for (int i = 0; i < want.len(); i++) if (got[i] != want[i]) ok = 1'b0;
      check($sformatf("uart output starts with \"%s\"", want), ok);
      if (!ok) $display("  got: \"%s\"", got);
    end

    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("TB_PASS tb_core");
    else             $display("TB_FAIL tb_core: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #5000000;
    $display("TB_FAIL tb_core: timeout");
    $finish;
  end

endmodule
