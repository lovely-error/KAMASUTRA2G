// Probe: interface + modport -- pipe.sv/forwards.sv/ifas.sv style handshake.
interface pipe_if #(parameter int W = 16);
    logic         put;
    logic         full;
    logic [W-1:0] data;

    modport src  (output put, output data, input  full);
    modport sink (input  put, input  data, output full);
endinterface

module producer (input logic clk, pipe_if.src p);
    always_ff @(posedge clk) begin
        p.put  <= ~p.full;
        p.data <= p.data + 16'd1;
    end
endmodule

module probe (
    input  logic        clk,
    output logic [15:0] out
);
    pipe_if #(.W(16)) bus ();
    producer u_p (.clk(clk), .p(bus.src));
    always_comb begin
        bus.full = 1'b0;
        out      = bus.data;
    end
endmodule
