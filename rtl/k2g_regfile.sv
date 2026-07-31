// K2G register file.
//
// Split into two arrays, which is the single most consequential
// microarchitectural decision in the core:
//
//   * 32 x 32 VALUE array, 2R1W, asynchronous read. Maps to SSRAM
//     (RAM16SDP4 x32, measured). The async read is what allows one D-stage
//     cycle to do read -> forward -> add -> memory address; a BSRAM version
//     reads synchronously and would insert a whole pipeline stage.
//
//   * 32 x 5 TAG+FLAGS array in flip-flops. Justified by the write patterns
//     rather than by size: a comparison writes ONLY `flag_bit`, an arithmetic
//     op writes ONLY `overflow`, and a copy writes everything. Per-field write
//     enables are free in flops and a read-modify-write in RAM. It also puts
//     the tag where the store path needs it early, since store width comes
//     from the source register's tag.
//
// THE VALUE ARRAY HAS EXACTLY ONE WRITE PORT, and that is load-bearing. An
// earlier version added a second port for the widening multiply's high half
// and the jump link register; a RAM cannot have two write ports, so the array
// collapsed to 1120 flip-flops and ~3700 LUTs of read muxing instead of 32
// SSRAM primitives and ~100 LUTs. Both of those writes are already specified
// as separate cycles (spec 5.5, 6.3), so the core serializes them.

`include "k2g_types.svh"

module k2g_regfile
  import k2g_pkg::*;
  import k2g_types::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Two read ports. Port A doubles as the predicate read during a prefix
    // cycle, which costs no address mux because the predicate register index
    // sits at cp[9:5] -- the same field position as arg1 (spec 2).
    input  logic [4:0]  ra_addr,
    input  logic [4:0]  rb_addr,
    output logic [31:0] ra_value,
    output logic [31:0] rb_value,
    output logic [2:0]  ra_tag,
    output logic [2:0]  rb_tag,
    output logic        ra_overflow,
    output logic        rb_overflow,
    output logic        ra_flag,
    output logic        rb_flag,

    // Third read port, for the predicate register named by an XCP/XCN prefix.
    // The value is needed because VALUE_ZERO / VALUE_NEGATIVE / VALUE_POSITIVE
    // test the register's value rather than a flag (spec 7).
    //
    // The plan avoids this port by evaluating the predicate during the
    // prefix's own decode cycle, when port A is idle. That is the better
    // design and remains the intent; a third port is taken here because it
    // costs one more copy of the value array (+16 RAM16SDP4) and keeps the
    // first working core simple. Revisit once cosimulation is green.
    input  logic [4:0]  rc_addr,
    output logic [31:0] rc_value,
    output logic        rc_overflow,
    output logic        rc_flag,

    // Single write port, with independent enables per field.
    input  logic        we_value,
    input  logic        we_tag,
    input  logic        we_overflow,
    input  logic        we_flag,
    input  logic [4:0]  w_addr,
    input  logic [31:0] w_value,
    input  logic [2:0]  w_tag,
    input  logic        w_overflow,
    input  logic        w_flag
);

  // ---- value array -------------------------------------------------------
  // Written in the exact shape GowinSynthesis infers SSRAM from: one
  // synchronous write, asynchronous reads, no reset loop over the array. A
  // reset still infers RAM but drags in extra primitives; architectural reset
  // of the values is not needed, since a program cannot observe a register
  // before writing it and the cosimulation harness zeroes both machines.
  logic [31:0] values [0:31];

  always_ff @(posedge clk) begin
    if (we_value) values[w_addr] <= w_value;
  end

  // ---- tag and flag array ------------------------------------------------
  // Small enough to reset cheaply, and the reset matters here: the tag decides
  // store width and comparison signedness, so an undefined tag is observable.
  logic [2:0] tags     [0:31];
  logic       overflow [0:31];
  logic       flagbit  [0:31];

  integer i;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (i = 0; i < 32; i = i + 1) begin
        tags[i]     <= RDT_U32;   // matches the emulator's reset tag
        overflow[i] <= 1'b0;
        flagbit[i]  <= 1'b0;
      end
    end else begin
      if (we_tag)      tags[w_addr]     <= w_tag;
      if (we_overflow) overflow[w_addr] <= w_overflow;
      if (we_flag)     flagbit[w_addr]  <= w_flag;
    end
  end

  // ---- reads -------------------------------------------------------------
  // READ-BEFORE-WRITE, deliberately. Reads see the value as of the start of
  // the cycle; the write lands at the clock edge.
  //
  // A write-first bypass belongs in a pipelined core, where the in-flight
  // write comes from an *earlier* instruction. Here execute is a single cycle,
  // so the write being presented is this instruction's own result -- and
  // because that result is computed from these very reads, bypassing closes a
  // combinational loop through the register file. It hung simulation with an
  // iteration-limit error rather than producing a wrong answer, which at least
  // fails loudly.
  //
  // This also matches the SSRAM primitive's natural behaviour, so nothing has
  // to be built to get it.
  assign ra_value    = values[ra_addr];
  assign rb_value    = values[rb_addr];
  assign rc_value    = values[rc_addr];

  assign ra_tag      = tags[ra_addr];
  assign rb_tag      = tags[rb_addr];
  assign ra_overflow = overflow[ra_addr];
  assign rb_overflow = overflow[rb_addr];
  assign ra_flag     = flagbit[ra_addr];
  assign rb_flag     = flagbit[rb_addr];

  assign rc_overflow = overflow[rc_addr];
  assign rc_flag     = flagbit[rc_addr];

endmodule
