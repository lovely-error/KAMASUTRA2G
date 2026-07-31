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
  // Write-first bypass: a read in the same cycle as a write to the same
  // register sees the new value. Without it every two-address ALU op would
  // need an interlock, since the destination is also a source -- and in this
  // ISA that is the common case, not the exception.
  wire logic [31:0] ra_raw = values[ra_addr];
  wire logic [31:0] rb_raw = values[rb_addr];

  assign ra_value = (we_value && (w_addr == ra_addr)) ? w_value : ra_raw;
  assign rb_value = (we_value && (w_addr == rb_addr)) ? w_value : rb_raw;

  assign ra_tag      = (we_tag      && (w_addr == ra_addr)) ? w_tag      : tags[ra_addr];
  assign rb_tag      = (we_tag      && (w_addr == rb_addr)) ? w_tag      : tags[rb_addr];
  assign ra_overflow = (we_overflow && (w_addr == ra_addr)) ? w_overflow : overflow[ra_addr];
  assign rb_overflow = (we_overflow && (w_addr == rb_addr)) ? w_overflow : overflow[rb_addr];
  assign ra_flag     = (we_flag     && (w_addr == ra_addr)) ? w_flag     : flagbit[ra_addr];
  assign rb_flag     = (we_flag     && (w_addr == rb_addr)) ? w_flag     : flagbit[rb_addr];

endmodule
