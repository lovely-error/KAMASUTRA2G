// A k2g_membus slave over k2g_mem's data port, with injectable latency.
//
// SIMULATION ONLY, and it lives in rtl/tb/ rather than rtl/ so that it is not
// picked up by the `k2g_*.sv` glob that feeds the board build. That is a
// stronger guarantee than `ifdef SIMULATION`: GowinSynthesis does not define
// SYNTHESIS, so a guard written the other way round once left simulation-only
// tasks visible to the synthesizer, which exited with no diagnostic at all
// (docs/bring-up.md).
//
// WHY LATENCY IS INJECTED AT ALL. A memory model that always answers in one
// cycle cannot tell a design that tolerates variable latency from one that
// merely happens to work at one cycle. That is the same blind spot as the
// testbench which held `uart_tx_ready` high forever and let a flow-control bug
// reach hardware -- the core is roughly fifty times faster than the serial
// line, and nothing in simulation said so.
//
// Phase 3 puts caches here and Phase 4 puts PSRAM behind them, at which point
// a load takes tens of cycles and its latency depends on the access pattern.
// This proves the core survives that before any of it exists, so that when
// the caches do arrive a failure is about caches.
//
// The delay is drawn from an LFSR, so a run is reproducible from SEED.

module k2g_mem_slow #(
    parameter int SEED = 32'h1357_9BDF
) (
    input logic clk,
    input logic rst_n,

    // Extra cycles on top of the memory's own, drawn uniformly from
    // [0, max_latency]. A port rather than a parameter so a testbench can set
    // it from a plusarg, which a parameter on a non-top module cannot be.
    input int unsigned max_latency,

    k2g_membus.slave bus,

    // k2g_mem port B.
    output logic [31:0] b_addr,
    output logic        b_en,
    output logic [3:0]  b_we,
    output logic [31:0] b_wdata,
    input  logic [31:0] b_rdata
);

  import k2g_types::*;

  // S_ACCESS does beat 0 of anything; the two burst states carry the rest.
  // Reads stream from the array a word per cycle, writes take a word per
  // accepted request beat -- which is where a burst's data comes from
  // (k2g_membus.sv: a write burst occupies the request channel).
  typedef enum logic [2:0] {
    S_IDLE, S_WAIT, S_ACCESS, S_RBURST, S_WBURST
  } state_e;

  state_e      state;
  mem_req_t    held;
  int          countdown;
  logic [4:0]  beats;      // still to do AFTER the one in progress
  logic [31:0] baddr;      // address of the beat in progress

  int unsigned lfsr;

  // Drawn combinationally so a zero-delay request can be issued in the same
  // cycle it is accepted. Without that, MAX_LATENCY=0 would still be one cycle
  // slower than the fixed-latency port it replaces, and every program would
  // quietly get longer.
  wire logic [31:0] draw = (max_latency == 0) ? 32'd0
                                              : (lfsr >> 8) % (max_latency + 1);

  wire logic is_burst   = (bus.req.len != 5'd0);
  wire logic accept_now = (state == S_IDLE) && bus.req_valid;
  // Bursts do not take the fast path. It exists so a zero-latency single
  // access costs exactly one cycle, and a burst costs at least one per beat
  // whatever happens.
  wire logic fast_path  = accept_now && (draw == 32'd0) && !is_burst;
  wire logic is_write   = (bus.req.we != 4'b0000);
  wire logic held_write = (held.we != 4'b0000);

  // `req_ready` may look at `req_valid`; the master's `req_valid` may not look
  // back (k2g_chan.sv rule 3). Only this direction is safe.
  //
  // High in S_WBURST too, because that is where the remaining beats of a write
  // burst arrive.
  assign bus.req_ready = (state == S_IDLE) || (state == S_WBURST);

  always_comb begin
    b_addr  = held.addr;
    b_wdata = held.wdata;
    b_we    = 4'b0000;
    b_en    = 1'b0;

    if (fast_path) begin
      b_addr  = bus.req.addr;
      b_wdata = bus.req.wdata;
      b_we    = bus.req.we;
      b_en    = 1'b1;
    end else if (state == S_ACCESS) begin
      b_we = held.we;
      b_en = 1'b1;
    end else if (state == S_RBURST) begin
      b_addr = baddr;
      b_en   = 1'b1;
    end else if ((state == S_WBURST) && bus.req_valid) begin
      b_addr  = baddr;
      b_wdata = bus.req.wdata;      // only `wdata` is carried by a later beat
      b_we    = held.we;
      b_en    = 1'b1;
    end
  end

  // The read data arrives from the BSRAM the cycle after the access, so the
  // response is one cycle behind whichever path issued it -- a register, not a
  // state, so that a zero-latency access does NOT occupy the model for a
  // second cycle.
  //
  // It used to be a state, which made `req_ready` false every other cycle and
  // capped the bus at half a request per cycle. That is strictly worse than
  // the synthesizable bridge it stood in for, which tied `req_ready` high and
  // was fully pipelined -- so simulation was starving the core in a way
  // hardware does not, and every cycles-per-instruction figure measured from
  // here was measuring this model.
  logic rsp_q;

  always_ff @(posedge clk) begin
    if (!rst_n) rsp_q <= 1'b0;
    else        rsp_q <= (fast_path  && !is_write) ||
                         ((state == S_ACCESS) && !held_write) ||
                         (state == S_RBURST);
  end

  assign bus.rsp_valid = rsp_q;
  assign bus.rsp_data  = b_rdata;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      held      <= '0;
      countdown <= 0;
      beats     <= 5'd0;
      baddr     <= 32'd0;
      lfsr      <= SEED;
    end else begin
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

      unique case (state)
        S_IDLE: begin
          if (bus.req_valid) begin
            held  <= bus.req;
            baddr <= bus.req.addr;
            beats <= bus.req.len;
            if (fast_path) begin
              // Issued this cycle by the combinational path above, and the
              // model stays idle so the next request can be accepted at once.
              state <= S_IDLE;
            end else if (draw != 32'd0) begin
              countdown <= draw;
              state     <= S_WAIT;
            end else begin
              state <= S_ACCESS;
            end
          end
        end

        S_WAIT: begin
          if (countdown <= 1) state <= S_ACCESS;
          countdown <= countdown - 1;
        end

        // Beat 0 of whatever was accepted, then the rest if there is a rest.
        S_ACCESS: begin
          if (beats == 5'd0) begin
            state <= S_IDLE;
          end else begin
            baddr <= held.addr + 32'd4;
            beats <= beats - 5'd1;
            state <= held_write ? S_WBURST : S_RBURST;
          end
        end

        S_RBURST: begin
          baddr <= baddr + 32'd4;
          if (beats == 5'd0) state <= S_IDLE;
          else               beats <= beats - 5'd1;
        end

        S_WBURST: if (bus.req_valid) begin
          baddr <= baddr + 32'd4;
          if (beats == 5'd0) state <= S_IDLE;
          else               beats <= beats - 5'd1;
        end

        default:  state <= S_IDLE;
      endcase
    end
  end

`ifdef SIMULATION
  // The master promises at most one outstanding request. If that ever stops
  // being true the response stream silently belongs to the wrong instruction,
  // so it is checked rather than assumed.
  always_ff @(posedge clk) begin
    if (rst_n && bus.req_valid && !bus.req_ready) begin
      assert ((state != S_IDLE) && (state != S_WBURST))
        else $error("k2g_mem_slow: request offered while idle but not ready");
    end
  end

  // Burst support is written but NOT YET EXERCISED: nothing sends `len != 0`
  // until the instruction cache does. Left in rather than stubbed so that when
  // the cache arrives a failure points at the cache, which is the whole reason
  // for building things in this order -- but it is reasoning, not measurement,
  // until then.
  always_ff @(posedge clk) begin
    if (rst_n && bus.req_valid && bus.req_ready && (bus.req.len != 5'd0) &&
        (state == S_IDLE))
      $display("k2g_mem_slow: first burst seen, len=%0d", bus.req.len + 1);
  end
`endif

endmodule
