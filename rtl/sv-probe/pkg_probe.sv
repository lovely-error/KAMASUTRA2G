// Consumer for the generated k2g_pkg, used by run_pkg_check.sh.
//
// Exercises the parts of the package the RTL will actually depend on: the
// field-position localparams, enum casts from a raw code point, equality
// against named opcodes, and a case over the enum type. If the generator ever
// emits something GowinSynthesis cannot digest, this fails.
module probe
    import k2g_pkg::*;
(
    input  logic [CP_W-1:0] cp,
    output logic            is_add,
    output logic            is_halt,
    output logic            is_prefix,
    output logic [4:0]      arg1,
    output logic [1:0]      kind
);
    lb_e  lb;
    ep1_e ep1;
    ep2_e ep2;

    always_comb begin
        lb   = lb_e'(cp[LB_LSB   +: LB_W]);
        ep1  = ep1_e'(cp[ARG2_LSB +: ARG2_W]);
        ep2  = ep2_e'(cp[ARG1_LSB +: ARG1_W]);
        arg1 = cp[ARG1_LSB +: ARG1_W];

        is_add  = (lb == LB_ADD);
        is_halt = (lb == LB_EP1) && (ep1 == EP1_EP2) && (ep2 == EP2_HALT);

        // The prefix set the decoder's accumulator FSM keys off.
        is_prefix = (lb == LB_XCP) || (lb == LB_XCN)
                 || (lb == LB_XI)  || (lb == LB_XIZEXT)
                 || (lb == LB_BMX_0_0)
                 || ((lb == LB_EP1) && (ep1 == EP1_UTO));

        case (lb)
            LB_PUC8:  kind = 2'd1;
            LB_PUC16: kind = 2'd2;
            LB_PUC32: kind = 2'd3;
            default:  kind = 2'd0;
        endcase
    end
endmodule
