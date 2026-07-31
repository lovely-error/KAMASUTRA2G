// K2G CSP I/O port space (docs/isa-spec.md 9).
//
// I/O is deliberately not memory-mapped: the CSP prefix redirects loads and
// stores here instead, which keeps the data path free of device address
// decoding. On hardware that means the load/store unit never needs a
// comparator against device ranges.
//
// Single-cycle for every port. The UART transmit path is a simple handshake to
// whatever sits outside; nothing here can stall the core.

`include "k2g_types.svh"

module k2g_csp
  import k2g_pkg::*;
  import k2g_types::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Access from the execute stage.
    input  logic        req,
    input  logic        is_write,
    input  logic [31:0] port,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        bad_port,     // -> FAULT_BAD_CSP_PORT
    // Asserted when this access cannot complete yet. The core holds the
    // instruction rather than retiring it, so nothing architectural changes --
    // which is why a stall is invisible to the lockstep comparison.
    output logic        stall,

    // Machine state exposed through the FAULT_* and CYCLE_* ports.
    input  logic [63:0] cycle_count,
    input  logic [4:0]  fault_cause,
    input  logic [31:0] fault_addr,
    input  logic [31:0] fault_info,
    input  logic        sticky_ordering,

    // UART, driven out to the SoC.
    output logic        uart_tx_valid,
    output logic [7:0]  uart_tx_data,
    input  logic        uart_tx_ready,
    input  logic        uart_rx_valid,
    input  logic [7:0]  uart_rx_data,
    output logic        uart_rx_take,

    output logic [31:0] gpio_out,
    output logic [31:0] compat_flags
);

  localparam logic [31:0] CORE_ID_VALUE = 32'h4B32_4731;   // "K2G1"

  logic [31:0] trap_vector, trap_enable, uart_divisor;

  // ---- read --------------------------------------------------------------
  logic bad_read;
  always_comb begin
    bad_read = 1'b0;
    unique case (port)
      32'h00: rdata = {24'd0, uart_rx_data};
      // TX never blocks in this implementation; RX empties when the source
      // has nothing queued.
      32'h01: rdata = {30'd0, !uart_rx_valid, 1'b0};
      32'h02: rdata = cycle_count[31:0];
      32'h03: rdata = cycle_count[63:32];
      32'h04: rdata = {27'd0, fault_cause};
      32'h05: rdata = fault_addr;
      32'h06: rdata = fault_info;
      32'h07: rdata = trap_vector;
      32'h08: rdata = trap_enable;
      32'h09: rdata = gpio_out;
      32'h0A: rdata = CORE_ID_VALUE;
      32'h0B: rdata = compat_flags;
      32'h0C: rdata = {31'd0, sticky_ordering};
      default: begin
        rdata    = 32'd0;
        bad_read = 1'b1;
      end
    endcase
  end

  // ---- write -------------------------------------------------------------
  // Writing a read-only port faults rather than being silently dropped, so a
  // program bug surfaces where it happens.
  logic bad_write;
  always_comb begin
    unique case (port)
      32'h00, 32'h01, 32'h07, 32'h08, 32'h09, 32'h0B: bad_write = 1'b0;
      default:                                        bad_write = 1'b1;
    endcase
  end

  assign bad_port = req && (is_write ? bad_write : bad_read);

  wire logic do_write = req && is_write && !bad_write;

  // A UART write waits for the transmitter. Without this the core, which is
  // roughly fifty times faster than the serial line, overwrites the byte being
  // sent again and again: a 24-byte string came out as its first character
  // followed by its last.
  wire logic uart_write = do_write && (port == 32'h00);

  assign stall         = uart_write && !uart_tx_ready;
  assign uart_tx_valid = uart_write && uart_tx_ready;
  assign uart_tx_data  = wdata[7:0];
  assign uart_rx_take  = req && !is_write && (port == 32'h00) && uart_rx_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      trap_vector  <= 32'd0;
      trap_enable  <= 32'd0;
      uart_divisor <= 32'd0;
      gpio_out     <= 32'd0;
      compat_flags <= 32'd0;
    end else if (do_write) begin
      unique case (port)
        32'h01:  uart_divisor <= wdata;
        32'h07:  trap_vector  <= wdata;
        32'h08:  trap_enable  <= wdata;
        32'h09:  gpio_out     <= wdata;
        32'h0B:  compat_flags <= wdata;
        default: ;   // 32'h00 is the UART, handled combinationally above
      endcase
    end
  end

  // Kept so the port reads back what was written, even though the divisor is
  // consumed outside this module.
  wire logic _unused_divisor = &{1'b0, uart_divisor};

endmodule
