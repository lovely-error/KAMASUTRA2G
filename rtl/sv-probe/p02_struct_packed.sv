// Probe: typedef struct packed -- would carry the ~210-bit uop bundle.
module probe (
    input  logic [15:0] cp,
    output logic [31:0] out
);
    typedef struct packed {
        logic [5:0] lb;
        logic [4:0] arg1;
        logic [4:0] arg2;
    } cp_t;

    cp_t d;
    always_comb begin
        d   = cp_t'(cp);
        out = {16'd0, d.arg2, d.arg1, d.lb};
    end
endmodule
