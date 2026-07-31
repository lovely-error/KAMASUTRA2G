// Probe: typedef enum logic [N:0]  -- what emit_sv() generates. Must pass.
module probe (
    input  logic [5:0] sel,
    output logic [1:0] out
);
    typedef enum logic [5:0] {
        OP_ADD = 6'd53,
        OP_SUB = 6'd52,
        OP_MUL = 6'd51
    } op_e;

    op_e op;
    always_comb begin
        op = op_e'(sel);
        case (op)
            OP_ADD:  out = 2'd1;
            OP_SUB:  out = 2'd2;
            OP_MUL:  out = 2'd3;
            default: out = 2'd0;
        endcase
    end
endmodule
