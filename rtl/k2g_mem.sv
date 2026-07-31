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
// THE BSRAM IS INSTANTIATED, NOT INFERRED. Inference produced a true dual-port
// block with WRITE_MODE = 2'b10 (read-before-write), which the primitive does
// not support and place-and-route rejects; `syn_ramstyle="no_rw_check"` did not
// change it, and larger inferred arrays made GowinSynthesis exit with no
// diagnostic at all. Instantiating gives deterministic control of the write
// mode, and matches the project's existing rule for DSPs.
//
// 8 KB is chosen so each lane is exactly ONE DPB in x8 mode (2048 bytes),
// which removes multi-block address decoding and output muxing entirely. It is
// ample: the largest program here is 124 bytes.

`include "k2g_types.svh"

module k2g_mem #(
    parameter int BYTES = 8192           // 4 lanes x 2048 = 4 BSRAM blocks
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

  localparam int WORDS = BYTES / 4;      // entries per lane
  localparam int IDX_W = $clog2(WORDS);

  wire logic [IDX_W-1:0] a_idx = a_addr[IDX_W+1:2];
  wire logic [IDX_W-1:0] b_idx = b_addr[IDX_W+1:2];

  logic [7:0] a_q0, a_q1, a_q2, a_q3;
  logic [7:0] b_q0, b_q1, b_q2, b_q3;
  logic       a_half_q;

  // The addressed halfword of the fetched word.
  assign a_data  = a_half_q ? {a_q3, a_q2} : {a_q1, a_q0};
  assign b_rdata = {b_q3, b_q2, b_q1, b_q0};

  // Gated by `a_en` exactly like the fetched data. Updating it unconditionally
  // desynchronizes the halfword select from the word during a stall, which
  // fetches the wrong half and sends the PC into the middle of an instruction.
  always_ff @(posedge clk) begin
    if (a_en) a_half_q <= a_addr[1];
  end

`ifdef SIMULATION
  // ---- behavioural model ------------------------------------------------
  // Used by every testbench, including the lockstep cosimulation, so the
  // instantiated version below is exercised only by synthesis.
  logic [7:0] lane0 [0:WORDS-1];
  logic [7:0] lane1 [0:WORDS-1];
  logic [7:0] lane2 [0:WORDS-1];
  logic [7:0] lane3 [0:WORDS-1];

  always_ff @(posedge clk) begin
    if (a_en) begin
      a_q0 <= lane0[a_idx];
      a_q1 <= lane1[a_idx];
      a_q2 <= lane2[a_idx];
      a_q3 <= lane3[a_idx];
    end
  end

  // Read and write are mutually exclusive, matching the hardware's normal
  // write mode: the core issues a load or a store, never both in one cycle.
  wire logic b_write = b_en && (b_we != 4'b0000);

  always_ff @(posedge clk) begin
    if (b_write) begin
      if (b_we[0]) lane0[b_idx] <= b_wdata[7:0];
      if (b_we[1]) lane1[b_idx] <= b_wdata[15:8];
      if (b_we[2]) lane2[b_idx] <= b_wdata[23:16];
      if (b_we[3]) lane3[b_idx] <= b_wdata[31:24];
    end else if (b_en) begin
      b_q0 <= lane0[b_idx];
      b_q1 <= lane1[b_idx];
      b_q2 <= lane2[b_idx];
      b_q3 <= lane3[b_idx];
    end
  end

  // ---- simulation-only image loading ------------------------------------
  // Gated on SIMULATION, which the sim scripts define, rather than on
  // SYNTHESIS, which GowinSynthesis does NOT define -- so these once reached
  // the synthesizer, which exited with no diagnostic at all.
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

`else
  // ---- instantiated BSRAM ------------------------------------------------
  // One DPB per byte lane, x8 on both ports. In x8 mode the primitive takes
  // the word index in AD[13:3] and ignores AD[2:0] -- see the DPB model in
  // Gowin's prim_sim.v -- so the index is shifted up by three.
  wire logic [13:0] ada = {{(11 - IDX_W){1'b0}}, a_idx, 3'b000};
  wire logic [13:0] adb = {{(11 - IDX_W){1'b0}}, b_idx, 3'b000};

  wire logic [31:0] doa0, doa1, doa2, doa3;
  wire logic [31:0] dob0, dob1, dob2, dob3;

  assign a_q0 = doa0[7:0];
  assign a_q1 = doa1[7:0];
  assign a_q2 = doa2[7:0];
  assign a_q3 = doa3[7:0];
  assign b_q0 = dob0[7:0];
  assign b_q1 = dob1[7:0];
  assign b_q2 = dob2[7:0];
  assign b_q3 = dob3[7:0];

  `define K2G_DPB(INST, DOA_W, DOB_W, WD, WE)                       DPB #(.READ_MODE0(1'b0), .READ_MODE1(1'b0),                         .WRITE_MODE0(2'b00), .WRITE_MODE1(2'b00),                     .BIT_WIDTH_0(8), .BIT_WIDTH_1(8),                             .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),                       .RESET_MODE("SYNC"))                                    INST (.DOA(DOA_W), .DIA(32'd0), .ADA(ada), .WREA(1'b0),             .CLKA(clk), .CEA(a_en), .OCEA(1'b1),                          .RESETA(1'b0), .BLKSELA(3'b000),                              .DOB(DOB_W), .DIB({24'd0, WD}), .ADB(adb),                    .WREB(WE), .CLKB(clk), .CEB(b_en), .OCEB(1'b1),               .RESETB(1'b0), .BLKSELB(3'b000))

  `K2G_DPB(u_lane0, doa0, dob0, b_wdata[7:0],   b_we[0]);
  `K2G_DPB(u_lane1, doa1, dob1, b_wdata[15:8],  b_we[1]);
  `K2G_DPB(u_lane2, doa2, dob2, b_wdata[23:16], b_we[2]);
  `K2G_DPB(u_lane3, doa3, dob3, b_wdata[31:24], b_we[3]);

  `undef K2G_DPB
`endif

endmodule
