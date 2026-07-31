// Probe: package / endpackage / import. If this passes, k2g_defs can be a
// package rather than an `include`d header.
package k2g_pkg;
    typedef enum logic [5:0] {
        LB_ADD = 6'd53,
        LB_SUB = 6'd52
    } lb_e;

    localparam int XLEN = 32;

    function automatic logic [4:0] arg1_of(input logic [15:0] cp);
        return cp[9:5];
    endfunction
endpackage

module probe
    import k2g_pkg::*;
(
    input  logic [15:0]      cp,
    output logic [4:0]       a1,
    output logic [XLEN-1:0]  wide,
    output logic             is_add
);
    always_comb begin
        a1     = arg1_of(cp);
        wide   = {27'd0, a1};
        is_add = (cp[15:10] == LB_ADD);
    end
endmodule
