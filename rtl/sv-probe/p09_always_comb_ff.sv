// Probe: always_comb / always_ff / logic. Baseline sanity -- if this fails,
// use plain Verilog-2001 for everything.
module probe (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] d,
    output logic [7:0] q
);
    logic [7:0] nxt;
    always_comb nxt = d + 8'd1;

    always_ff @(posedge clk) begin
        if (!rst_n) q <= 8'd0;
        else        q <= nxt;
    end
endmodule
