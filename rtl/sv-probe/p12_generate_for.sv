// Probe: generate/genvar + unpacked array -- needed for the 4-lane byte-striped
// BSRAM array and the 32-entry register file.
module probe (
    input  logic        clk,
    input  logic [31:0] d,
    input  logic [3:0]  we,
    output logic [31:0] q
);
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_lane
            logic [7:0] r;
            always_ff @(posedge clk) begin
                if (we[i]) r <= d[i*8 +: 8];
            end
            assign q[i*8 +: 8] = r;
        end
    endgenerate
endmodule
