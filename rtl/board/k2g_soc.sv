// Stage 3 of bring-up: the whole machine on a Tang Nano 9K.
//
//   boot ROM -> copier -> 16 KB unified memory -> K2G core -> UART
//
// The copier exists because GowinSynthesis will not initialize an inferred RAM
// from `$readmemh`. The program therefore lives in logic (see `mkrom`) and is
// copied into memory at reset, with the CPU held in reset until it finishes.
// That is also what a real system does when it copies from flash into RAM.
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
    parameter int MEM_BYTES = 8192,
    parameter int XTAL_HZ   = 27_000_000,
    // The core's single-cycle execute path runs 27 logic levels deep and
    // places at an Fmax of about 11.4 MHz, well under the 27 MHz crystal, so
    // the whole machine runs on a divided clock. Dividing by 4 gives 6.75 MHz
    // with comfortable margin. Raising this is the reward for pipelining the
    // core (see the note in k2g_core.sv).
    parameter int CLK_DIV   = 4,
    parameter int BAUD      = 115_200
) (
    input  logic       clk_27m,
    input  logic       rst_n,
    output logic [5:0] led,
    output logic       uart_tx,
    input  logic       uart_rx
);

  localparam int CLK_HZ  = XTAL_HZ / CLK_DIV;      // 6.75 MHz
  localparam int DIVISOR = CLK_HZ / BAUD;          // 58 -> 116379 baud, 1.0%

  // ---- clock division ----------------------------------------------------
  logic [1:0] div;
  always_ff @(posedge clk_27m) div <= div + 2'd1;

  // A divided clock rather than a clock enable: an enable would still require
  // the combinational path to settle inside one 27 MHz period unless the
  // timing constraints declared a multicycle path, and getting that wrong
  // fails silently on hardware rather than loudly in the report.
  wire logic clk_sys = div[1];

  // ---- reset synchronization --------------------------------------------
  // The button is asynchronous; releasing reset out of sync with the clock is
  // a reliable way to start in an undefined state.
  logic [3:0] rst_sync;
  wire  logic sys_rst_n = rst_sync[3];

  always_ff @(posedge clk_sys) begin
    rst_sync <= {rst_sync[2:0], rst_n};
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

  logic        booting;
  logic [15:0] boot_ix;

  always_ff @(posedge clk_sys) begin
    if (!sys_rst_n) begin
      booting <= 1'b1;
      boot_ix <= 16'd0;
    end else if (booting) begin
      if (boot_ix == 16'(ROM_BYTES - 1)) booting <= 1'b0;
      boot_ix <= boot_ix + 16'd1;
    end
  end

  assign boot_addr = boot_ix;

  // The CPU stays in reset for the whole copy, so it never sees a partly
  // written program.
  wire logic cpu_rst_n = sys_rst_n && !booting;

  // ---- memory ------------------------------------------------------------
  logic [31:0] imem_addr, dmem_addr, dmem_wdata, core_dmem_addr, core_dmem_wdata;
  logic [15:0] imem_data;
  logic [31:0] dmem_rdata;
  logic        imem_en, dmem_en, core_dmem_en;
  logic [3:0]  dmem_we, core_dmem_we;

  // During boot the copier owns the data port; afterwards the core does.
  // One byte per cycle, placed by the memory's own byte-lane enables.
  assign dmem_addr  = booting ? {16'd0, boot_ix} : core_dmem_addr;
  assign dmem_en    = booting ? 1'b1 : core_dmem_en;
  assign dmem_we    = booting ? (4'b0001 << boot_ix[1:0]) : core_dmem_we;
  assign dmem_wdata = booting ? {4{boot_data}} : core_dmem_wdata;

  k2g_mem #(.BYTES(MEM_BYTES)) u_mem (
      .clk    (clk_sys),
      .a_addr (imem_addr),
      .a_en   (imem_en),
      .a_data (imem_data),
      .b_addr (dmem_addr),
      .b_en   (dmem_en),
      .b_we   (dmem_we),
      .b_wdata(dmem_wdata),
      .b_rdata(dmem_rdata)
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
      .imem_addr    (imem_addr),
      .imem_en      (imem_en),
      .imem_data    (imem_data),
      .dmem_addr    (core_dmem_addr),
      .dmem_en      (core_dmem_en),
      .dmem_we      (core_dmem_we),
      .dmem_wdata   (core_dmem_wdata),
      .dmem_rdata   (dmem_rdata),
      .uart_tx_valid(core_tx_valid),
      .uart_tx_data (core_tx_data),
      .uart_tx_ready(tx_ready),
      .uart_rx_valid(rx_have),
      .uart_rx_data (rx_byte),
      .uart_rx_take (core_rx_take),
      .gpio_out     (gpio_out),
      .halted       (halted),
      .faulted      (faulted),
      .fault_cause_o(fault_cause_o),
      .fault_addr_o (fault_addr_o),
      .fault_info_o (fault_info_o),
      .cycle_count_o(cycle_count_o)
  );

  // ---- UART --------------------------------------------------------------
  // The core writes a byte in a single cycle and does not wait, so a one-byte
  // holding register absorbs it while the transmitter shifts.
  logic       tx_pending;
  logic [7:0] tx_hold;
  wire  logic tx_go = tx_pending && tx_ready;

  always_ff @(posedge clk_sys) begin
    if (!sys_rst_n) begin
      tx_pending <= 1'b0;
      tx_hold    <= 8'd0;
    end else if (core_tx_valid) begin
      tx_hold    <= core_tx_data;
      tx_pending <= 1'b1;
    end else if (tx_go) begin
      tx_pending <= 1'b0;
    end
  end

  k2g_uart_tx #(.DIVISOR(DIVISOR)) u_tx (
      .clk  (clk_sys),
      .rst_n(sys_rst_n),
      .valid(tx_go),
      .data (tx_hold),
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
    if (booting) begin
      status = 6'b111111;                     // all lit briefly during the copy
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
                         gpio_out[31:5], dmem_rdata};

endmodule
