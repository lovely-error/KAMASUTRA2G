// K2G channels: the handshake every major section of v2 connects through.
//
// v2 structures the core as sequential processes joined only by typed,
// back-pressured channels. That is the Communicating Sequential Processes
// idea, and it is why docs/attic/pipe.sv was kept when the rest of the
// superseded HDL was deleted.
//
// IT IS SPELLED "CHANNEL", NOT "CSP". `CSP` already means the EP2_CSP prefix
// and the I/O port space of spec 9 -- see k2g_csp.sv. One project cannot
// afford two meanings for one three-letter word, so the structuring idea gets
// the longer name and the instruction keeps the short one.
//
// An interface rather than flattened valid/ready/data port triples because
// docs/gowin-sv-support.md measured `interface` + `modport` synthesizing
// correctly (probe 04: DFF:16 ALU:15, a counter driven across the interface).
// That measurement was taken specifically to find out whether this was
// allowed.
//
// ---- the rules, which are the whole value of the abstraction ----
//
//   1. A transfer happens on a rising edge where `valid && ready`.
//
//   2. Once `valid` is raised it stays raised, with `data` unchanged, until a
//      transfer happens. A producer may not withdraw an offer.
//
//   3. `valid` MUST NOT depend combinationally on `ready`. `ready` may depend
//      on `valid`.
//
// Rule 3 is not style. The single-cycle core already hit exactly this: routing
// the pipeline stall back into the decoder's `cp_valid` closed a loop through
// stall -> decode -> CSP request -> stall, and the fix was a separate `hold`
// input that freezes the accumulator without touching the combinational
// output (see k2g_core.sv and docs/bring-up.md). A channel whose `valid`
// watches `ready` rebuilds that loop across every boundary at once.
//
// `k2g_skid` exists to satisfy rule 3 where a consumer's `ready` would
// otherwise have to reach back to the producer combinationally. Where
// backpressure cannot occur, connect the channel directly and pay nothing --
// the module boundary is channel-shaped either way, which is the point.

interface k2g_chan #(
    parameter int WIDTH = 32
) ();

  logic             valid;
  logic             ready;
  logic [WIDTH-1:0] data;

  modport src (output valid, output data, input  ready);
  modport dst (input  valid, input  data, output ready);
  // For assertions and testbenches that watch a channel without taking part.
  modport mon (input  valid, input  data, input  ready);

endinterface


// Two-entry skid buffer: full throughput, and `up.ready` is a flip-flop
// output, so no combinational path runs from `down.ready` back to the
// producer.
//
// Two entries rather than one because a single registered stage that drops
// `ready` on a stall loses the item already in flight; the second entry is
// where that item skids to. One entry costs half the throughput instead, and
// the fetch path cannot afford that.
module k2g_skid #(
    parameter int WIDTH = 32
) (
    input logic  clk,
    input logic  rst_n,
    k2g_chan.dst up,
    k2g_chan.src down
);

  logic [WIDTH-1:0] out_data, skid_data;
  logic             out_valid, skid_full;

  // Accept whenever the skid entry is free. This is a register, never a
  // function of `down.ready` -- rule 3.
  assign up.ready   = !skid_full;
  assign down.valid = out_valid;
  assign down.data  = out_data;

  wire logic up_xfer   = up.valid   && up.ready;
  wire logic down_xfer = down.valid && down.ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      skid_full <= 1'b0;
      out_data  <= '0;
      skid_data <= '0;
    end else begin
      // Output register: take from upstream when there is room for it now,
      // otherwise from the skid entry, otherwise empty out.
      if (up_xfer && !skid_full && (!out_valid || down_xfer)) begin
        out_data  <= up.data;
        out_valid <= 1'b1;
      end else if (down_xfer && skid_full) begin
        out_data  <= skid_data;
        out_valid <= 1'b1;
      end else if (down_xfer) begin
        out_valid <= 1'b0;
      end

      // Skid entry: catches the item that arrives in the cycle the output
      // register is occupied and downstream is not taking it.
      if (up_xfer && out_valid && !down_xfer && !skid_full) begin
        skid_data <= up.data;
        skid_full <= 1'b1;
      end else if (down_xfer && skid_full) begin
        skid_full <= 1'b0;
      end
    end
  end

`ifdef SIMULATION
  // Rule 2, checked rather than trusted. A producer that withdraws an offer
  // produces a missing item, which downstream reports as a divergence a long
  // way from the cause.
  logic             held_valid;
  logic [WIDTH-1:0] held_data;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      held_valid <= 1'b0;
      held_data  <= '0;
    end else begin
      held_valid <= up.valid && !up_xfer;
      held_data  <= up.data;
      if (held_valid) begin
        assert (up.valid)
          else $error("k2g_skid: producer withdrew `valid` before a transfer");
        assert (up.data === held_data)
          else $error("k2g_skid: producer changed `data` while `valid` was held");
      end
    end
  end
`endif

endmodule
