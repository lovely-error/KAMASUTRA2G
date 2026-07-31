// Probe: function automatic returning a vector -- the fallback accessor style
// for flat packed uop bundles if structs turn out to be unsupported.
module probe (
    input  logic [15:0] cp,
    output logic [5:0]  lb,
    output logic [4:0]  a1
);
    function automatic logic [5:0] lb_of(input logic [15:0] c);
        lb_of = c[15:10];
    endfunction

    function automatic logic [4:0] a1_of(input logic [15:0] c);
        return c[9:5];
    endfunction

    always_comb begin
        lb = lb_of(cp);
        a1 = a1_of(cp);
    end
endmodule
