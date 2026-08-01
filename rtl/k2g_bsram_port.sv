// A k2g_membus slave over one port of k2g_mem. The synthesizable one.
//
// BSRAM always accepts and always answers the next cycle, so this is the
// degenerate case of the contract: `req_ready` is tied high and the response
// is a single delayed valid. It costs one flip-flop.
//
// It exists so that the core talks to the bus and nothing else, even while
// the thing behind the bus is still a fixed-latency BSRAM. When Phase 3 puts
// a cache here and Phase 4 puts PSRAM behind that, this module is deleted and
// nothing in the core changes -- which is the entire point of paying for a
// bus contract this early.
//
// rtl/tb/k2g_mem_slow.sv is the simulation counterpart, identical except that
// it can be told to take its time.

module k2g_bsram_port (
    input logic clk,
    input logic rst_n,

    k2g_membus.slave bus,

    // k2g_mem port B.
    output logic [31:0] b_addr,
    output logic        b_en,
    output logic [3:0]  b_we,
    output logic [31:0] b_wdata,
    input  logic [31:0] b_rdata
);

  assign bus.req_ready = 1'b1;

  assign b_addr  = bus.req.addr;
  assign b_wdata = bus.req.wdata;
  assign b_we    = bus.req.we;
  assign b_en    = bus.req_valid;

  // Only a read produces a response (k2g_membus.sv: a write produces none).
  logic read_pending;

  always_ff @(posedge clk) begin
    if (!rst_n) read_pending <= 1'b0;
    else        read_pending <= bus.req_valid && (bus.req.we == 4'b0000);
  end

  assign bus.rsp_valid = read_pending;
  assign bus.rsp_data  = b_rdata;

endmodule
