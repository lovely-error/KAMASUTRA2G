// Probe: multi-dimensional packed arrays -- decoder.sv:1874 `bit [7:0][15:0]`.
// This is the natural way to express the 128-bit fetch stripe as 8 code points.
module probe (
    input  logic [127:0] stripe_flat,
    input  logic [2:0]   lane,
    output logic [15:0]  cp
);
    logic [7:0][15:0] stripe;
    always_comb begin
        stripe = stripe_flat;
        cp     = stripe[lane];
    end
endmodule
