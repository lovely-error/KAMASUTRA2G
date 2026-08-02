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
    // Still 8 KB, while `k2g_core`'s default and the cosimulation have moved
    // to the 8 MB of PSRAM that v2 targets. This is the one place the number
    // describes a board rather than an architecture: MEM_BYTES is where
    // ADDR_OUT_OF_RANGE begins, and until the PSRAM adapter is wired in below
    // there is nothing behind an address above 8192 to fault about. It moves
    // when `k2g_mem` here is replaced by `k2g_psram`.
    parameter int MEM_BYTES = 8192,
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
  logic rst_meta, rst_syncd;
  always_ff @(posedge clk_sys) begin
    rst_meta  <= rst_n;
    rst_syncd <= rst_meta;
  end

  // There is no hardware debounce on this board, so one press of the button
  // produces a burst of edges and the machine runs its program once per edge.
  // The level must hold for 10 ms before it is believed.
  localparam int DEBOUNCE = CLK_HZ / 100;
  localparam int DB_W     = $clog2(DEBOUNCE + 1);

  logic [DB_W-1:0] db_count;
  logic            rst_stable;

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
  logic [3:0] rst_sync;
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

  // The core reaches the memory through the bus contract, not directly. The
  // bridge is the degenerate slave -- always ready, answers next cycle -- and
  // is what a cache replaces in Phase 3 without the core noticing.
  k2g_membus dbus ();
  k2g_membus ibus ();

  // The same bridge serves the fetch port: it is a read-only 16-bit port, so
  // `we` and `wdata` go nowhere and the code point rides the low half of the
  // response. k2g_mem keeps its own halfword select, which is gated by `a_en`
  // and so stays in step with a request-driven enable.
  k2g_bsram_port u_iport (
      .clk    (clk_sys),
      .rst_n  (cpu_rst_n),
      .bus    (ibus),
      .b_addr (imem_addr),
      .b_en   (imem_en),
      .b_we   (),
      .b_wdata(),
      .b_rdata({16'd0, imem_data})
  );

  k2g_bsram_port u_dport (
      .clk    (clk_sys),
      .rst_n  (cpu_rst_n),
      .bus    (dbus),
      .b_addr (core_dmem_addr),
      .b_en   (core_dmem_en),
      .b_we   (core_dmem_we),
      .b_wdata(core_dmem_wdata),
      .b_rdata(dmem_rdata)
  );

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
      .cycle_count_o(cycle_count_o)
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
