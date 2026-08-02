// Asynchronous FIFO: the core's clock domain to the PSRAM controller's.
//
// The core runs on a divide-by-2 of the crystal at 13.5 MHz; the controller
// hands out its own `clk_out` at 67.5 MHz. They come from different PLL paths
// and nothing keeps them in phase, so everything crossing between them crosses
// asynchronously.
//
// THIS IS THE ONE THING COSIMULATION CANNOT CHECK. The lockstep comparison
// runs both machines in a single clock domain and will never see a
// metastability failure -- a design that samples a multi-bit value mid-flight
// passes every test in this repository and then fails on a board, sometimes
// only at temperature. So this is written to a standard rather than to a test:
//
//   * pointers are GRAY CODED, so exactly one bit changes per increment and a
//     pointer sampled mid-transition is either the old value or the new one,
//     never a mixture of both;
//   * every pointer crossing a domain passes through TWO flip-flops in the
//     receiving domain before it is used. NOT TESTABLE HERE: deleting one of
//     those flops changes only latency in a zero-delay simulator, and
//     `mutants.sh` carries no mutant for it because it would report MISSED
//     forever. It is verified by reading this file and by the constraints;
//   * the storage array itself never crosses -- it is written in one domain
//     and read combinationally in the other, at an address that has already
//     been synchronized, so the data is stable long before it is read;
//   * `.sdc` must declare the two clocks asynchronous. An unconstrained
//     crossing passes timing analysis and fails on hardware.
//
// `docs/attic/pipe.sv` has a PipeCDC that looks like this and is not: its salt
// bits cross domains with no synchronizer at all. It was kept for the idea,
// not the implementation, and this does not derive from it.
//
// DEPTH must be a power of two. The extra pointer bit above `$clog2(DEPTH)` is
// what distinguishes full from empty -- with equal pointers the FIFO is empty,
// and with pointers differing only in that top bit it is full.

module k2g_cdc_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 8
) (
    // Write side.
    input  logic             wclk,
    input  logic             wrst_n,
    input  logic             wpush,
    input  logic [WIDTH-1:0] wdata,
    output logic             wfull,

    // Read side.
    input  logic             rclk,
    input  logic             rrst_n,
    input  logic             rpop,
    output logic [WIDTH-1:0] rdata,
    output logic             rempty
);

  localparam int AW = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [0:DEPTH-1];

  // Binary and gray forms of each pointer, one bit wider than the address.
  logic [AW:0] wbin, wgray, wbin_next, wgray_next;
  logic [AW:0] rbin, rgray, rbin_next, rgray_next;

  // Each pointer after two flops in the other domain.
  //
  // `syn_preserve` stops GowinSynthesis optimizing these (SUG550 5.13:
  // "preserves register without optimization"). Without it the tool is free to
  // retime logic into the chain or duplicate a stage to ease fan-out -- and a
  // duplicated synchronizer flop is two flops that can resolve to different
  // values from the same metastable input, which is the failure the chain
  // exists to prevent. It is the local equivalent of ASYNC_REG.
  //
  // It does not force the pair to be placed close together, which is the other
  // half of what ASYNC_REG buys; Gowin exposes no attribute for that here. The
  // resolution time is therefore whatever placement gives, and the .sdc
  // declaring the domains asynchronous is what stops the tool trying to close
  // timing across them at all.
  logic [AW:0] wgray_meta /* synthesis syn_preserve = 1 */;
  logic [AW:0] wgray_sync /* synthesis syn_preserve = 1 */;
  logic [AW:0] rgray_meta /* synthesis syn_preserve = 1 */;
  logic [AW:0] rgray_sync /* synthesis syn_preserve = 1 */;

  function automatic logic [AW:0] to_gray(input logic [AW:0] b);
    return b ^ (b >> 1);
  endfunction

  // ---- write side --------------------------------------------------------
  // Zero-extended concatenation rather than a width cast. `(AW+1)'(...)` makes
  // GowinSynthesis exit 1 with an empty log -- the same silent failure as
  // $clog2 in a part-select, and the third construct in this family to do it.
  wire logic wdo = wpush && !wfull;
  assign wbin_next  = wbin + {{AW{1'b0}}, wdo};
  assign wgray_next = to_gray(wbin_next);

  always_ff @(posedge wclk) begin
    if (!wrst_n) begin
      wbin  <= '0;
      wgray <= '0;
    end else begin
      wbin  <= wbin_next;
      wgray <= wgray_next;
    end
  end

  always_ff @(posedge wclk) begin
    if (wdo) mem[wbin[AW-1:0]] <= wdata;
  end

  // The read pointer, brought across.
  always_ff @(posedge wclk) begin
    if (!wrst_n) begin
      rgray_meta <= '0;
      rgray_sync <= '0;
    end else begin
      rgray_meta <= rgray;
      rgray_sync <= rgray_meta;
    end
  end

  // Full: pointers equal except for the top two bits inverted, which is what
  // "one lap ahead" looks like in gray code.
  //
  // REGISTERED, not combinational. `wfull` gates `wpush`, which feeds
  // `wbin_next` and so `wgray_next` -- computing full from that combinationally
  // closes the loop, and the FIFO simply never accepts anything. The flop
  // breaks it, and costs nothing: a full FIFO stays full until the reader
  // moves, which takes more than a cycle to observe across the crossing
  // anyway.
  wire logic wfull_next =
      (wgray_next == {~rgray_sync[AW:AW-1], rgray_sync[AW-2:0]});

  always_ff @(posedge wclk) begin
    if (!wrst_n) wfull <= 1'b0;
    else         wfull <= wfull_next;
  end

  // ---- read side ---------------------------------------------------------
  wire logic rdo = rpop && !rempty;
  assign rbin_next  = rbin + {{AW{1'b0}}, rdo};
  assign rgray_next = to_gray(rbin_next);

  always_ff @(posedge rclk) begin
    if (!rrst_n) begin
      rbin  <= '0;
      rgray <= '0;
    end else begin
      rbin  <= rbin_next;
      rgray <= rgray_next;
    end
  end

  always_ff @(posedge rclk) begin
    if (!rrst_n) begin
      wgray_meta <= '0;
      wgray_sync <= '0;
    end else begin
      wgray_meta <= wgray;
      wgray_sync <= wgray_meta;
    end
  end

  // Registered for symmetry with `wfull`, and for the same reason: `rempty`
  // gates `rpop`, which feeds `rbin_next` and `rgray_next`.
  wire logic rempty_next = (rgray_next == wgray_sync);

  always_ff @(posedge rclk) begin
    if (!rrst_n) rempty <= 1'b1;
    else         rempty <= rempty_next;
  end

  // Read combinationally at an address that crossed as a synchronized pointer,
  // so the entry has been stable for at least two receiving-domain edges.
  assign rdata = mem[rbin[AW-1:0]];

`ifdef SIMULATION
  initial begin
    assert (DEPTH == (1 << AW))
      else $fatal(1, "k2g_cdc_fifo: DEPTH must be a power of two");
    // The full test compares the top TWO pointer bits, so there has to be an
    // address bit under them. At DEPTH 2 the expression's `[AW-2:0]` is a
    // reversed part-select and elaboration fails -- loudly, but a long way
    // from the instantiation that caused it.
    assert (DEPTH >= 4)
      else $fatal(1, "k2g_cdc_fifo: DEPTH must be at least 4");
  end

  // Overflow and underflow are silent corruption otherwise: a dropped request
  // becomes a response that never arrives, and the core waits forever.
  always_ff @(posedge wclk) begin
    if (wrst_n && wpush && wfull)
      $error("k2g_cdc_fifo: push while full");
  end
  always_ff @(posedge rclk) begin
    if (rrst_n && rpop && rempty)
      $error("k2g_cdc_fifo: pop while empty");
  end
`endif

endmodule
