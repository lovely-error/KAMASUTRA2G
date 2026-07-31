// Probe: packed array of structs -- decoder.sv:1879 `CanonInsn [7:0]`.
module probe (
    input  logic [1:0]  sel,
    input  logic [31:0] flat,
    output logic [7:0]  out
);
    typedef struct packed {
        logic [3:0] op;
        logic [3:0] rd;
    } insn_t;

    insn_t [3:0] insns;
    always_comb begin
        insns = flat;
        out   = {insns[sel].op, insns[sel].rd};
    end
endmodule
