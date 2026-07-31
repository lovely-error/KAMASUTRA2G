// Probe: assignment patterns '{field: value} -- ifas.sv:79, decoder.sv:1907.
module probe (
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [31:0] out
);
    typedef struct packed {
        logic [15:0] addr;
        logic [15:0] data;
    } req_t;

    req_t r;
    always_comb begin
        r   = '{addr: a, data: b};
        out = {r.addr, r.data};
    end
endmodule
