// Probe: module #(type T) -- pipe.sv's `Pipe #(type Item)`.
// Expected to be the least portable construct tested.
module store #(parameter type T = logic [7:0]) (
    input  logic clk,
    input  T     d,
    output T     q
);
    T r;
    always_ff @(posedge clk) r <= d;
    assign q = r;
endmodule

module probe (
    input  logic        clk,
    input  logic [15:0] d,
    output logic [15:0] q
);
    store #(.T(logic [15:0])) u_s (.clk(clk), .d(d), .q(q));
endmodule
