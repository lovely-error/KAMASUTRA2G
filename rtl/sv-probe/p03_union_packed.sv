// Probe: union packed -- decoder.sv used a union for the CanonInsn payload.
module probe (
    input  logic [15:0] cp,
    input  logic        pick,
    output logic [15:0] out
);
    typedef struct packed { logic [5:0] lb;   logic [9:0] imm; } fmt_6_10_t;
    typedef struct packed { logic [5:0] lb;   logic [4:0] a1; logic [4:0] a2; } fmt_6_5_5_t;

    typedef union packed {
        fmt_6_10_t  f610;
        fmt_6_5_5_t f655;
    } cp_u;

    cp_u u;
    always_comb begin
        u   = cp_u'(cp);
        out = pick ? {6'd0, u.f610.imm} : {6'd0, u.f655.a1, u.f655.a2};
    end
endmodule
