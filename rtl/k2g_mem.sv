// K2G unified memory: byte-striped, dual-ported.
//
// Four independent byte lanes rather than one 32-bit array. Gowin's BSRAM is
// capped at x16 per port and has no per-byte write enables, so striping is
// forced -- and it happens to give exactly the per-byte store granularity the
// tag-driven store width needs (spec 5.3).
//
//   port A: instruction fetch, 16-bit read, read-only
//   port B: data access, 8/16/32-bit read and write
//
// A 16-bit fetch at halfword `h` needs bytes 2h and 2h+1, which always sit in
// the same 32-bit word, so one word index drives all four lanes.
//
// Written in an inferrable form rather than instantiating DPB directly, on the
// same reasoning as the register file: the shape that infers was measured, and
// keeping it inferrable means one source simulates and synthesizes.

`include "k2g_types.svh"

module k2g_mem #(
    parameter int BYTES = 16384          // 16 KB = 8 BSRAM blocks
) (
    input  logic        clk,

    // Port A -- instruction fetch.
    input  logic [31:0] a_addr,          // byte address, halfword aligned
    input  logic        a_en,
    output logic [15:0] a_data,

    // Port B -- data.
    input  logic [31:0] b_addr,          // byte address
    input  logic        b_en,
    input  logic [3:0]  b_we,            // per-lane write enable
    input  logic [31:0] b_wdata,
    output logic [31:0] b_rdata
);

  localparam int WORDS   = BYTES / 4;
  localparam int IDX_W   = $clog2(WORDS);

  // One array per byte lane. Lane `k` holds the byte at address (index*4 + k).
  logic [7:0] lane0 [0:WORDS-1];
  logic [7:0] lane1 [0:WORDS-1];
  logic [7:0] lane2 [0:WORDS-1];
  logic [7:0] lane3 [0:WORDS-1];

  wire logic [IDX_W-1:0] a_idx = a_addr[IDX_W+1:2];
  wire logic [IDX_W-1:0] b_idx = b_addr[IDX_W+1:2];

  // Port A: registered read, matching BSRAM's synchronous behaviour.
  logic [7:0] a_q0, a_q1, a_q2, a_q3;
  logic       a_half_q;

  always_ff @(posedge clk) begin
    if (a_en) begin
      a_q0     <= lane0[a_idx];
      a_q1     <= lane1[a_idx];
      a_q2     <= lane2[a_idx];
      a_q3     <= lane3[a_idx];
      a_half_q <= a_addr[1];
    end
  end

  // Select the addressed halfword from the fetched word.
  assign a_data = a_half_q ? {a_q3, a_q2} : {a_q1, a_q0};

  // Port B: registered read and byte-enabled write.
  logic [7:0] b_q0, b_q1, b_q2, b_q3;

  always_ff @(posedge clk) begin
    if (b_en) begin
      if (b_we[0]) lane0[b_idx] <= b_wdata[7:0];
      if (b_we[1]) lane1[b_idx] <= b_wdata[15:8];
      if (b_we[2]) lane2[b_idx] <= b_wdata[23:16];
      if (b_we[3]) lane3[b_idx] <= b_wdata[31:24];
      b_q0 <= lane0[b_idx];
      b_q1 <= lane1[b_idx];
      b_q2 <= lane2[b_idx];
      b_q3 <= lane3[b_idx];
    end
  end

  assign b_rdata = {b_q3, b_q2, b_q1, b_q0};

  // ---- simulation-only image loading ------------------------------------
  // The synthesis flow initializes lanes through INIT_RAM parameters instead;
  // a de-interleaving step in the build produces those from a flat image.
`ifndef SYNTHESIS
  // verilog_format: off
  task automatic load_byte(input int addr, input logic [7:0] data);
    case (addr[1:0])
      2'd0: lane0[addr >> 2] = data;
      2'd1: lane1[addr >> 2] = data;
      2'd2: lane2[addr >> 2] = data;
      default: lane3[addr >> 2] = data;
    endcase
  endtask

  task automatic clear_all();
    for (int i = 0; i < WORDS; i++) begin
      lane0[i] = 8'd0; lane1[i] = 8'd0; lane2[i] = 8'd0; lane3[i] = 8'd0;
    end
  endtask

  function automatic logic [7:0] peek_byte(input int addr);
    case (addr[1:0])
      2'd0: return lane0[addr >> 2];
      2'd1: return lane1[addr >> 2];
      2'd2: return lane2[addr >> 2];
      default: return lane3[addr >> 2];
    endcase
  endfunction
  // verilog_format: on
`endif

endmodule
