interface ForwardSender #(type Item);
    bit put;
    bit ok;
    Item value_in;
endinterface

interface ForwardReciever #(type Item);
    bit drop;
    bit has_value;
    Item value_out;
endinterface

module Forward #(type Item) (
    clk,
    sender_port,
    reciver_port,
    clear
);
    input bit clk;
    ForwardSender sender_port;
    ForwardReciever reciver_port;
    input bit clear;

    Item value;
    bit value_present = 0;

    always_ff @(posedge clk) begin
        if (clear) begin
            value_present <= 0;
        end else begin
            case ({sender_port.put, reciver_port.drop, value_present})
                'b111: begin 
                    // since we want to drop value this cycle, we can 
                    // replace current value with whatever sender wants to give us.
                    value <= sender_port.value_in;
                    value_present <= 1; // value remains present
                end
                'b110: begin
                    $error("attempt to consume a value from an empty slot. reciever must respect value presense")
                end
                'b101: begin 
                    // we want to put value in, but theres already an unconsumed one
                    // in sim, fatal error, in hw impl ignore the request
                    $error("attempt to push value in a nonempty slot. sender must respect value presense")
                end
                'b100: begin
                    // sender wants to put a value, and slot is empty
                    value <= sender_port.value_in;
                    value_present <= 1;
                end
                'b011: begin 
                    // nothing is being sent this cycle. reciever wants to drop the value and
                    // since it is present it is safe to do so
                    value_present <= 0;
                end
                'b010: begin 
                    // theres is no value, and reciever wants to drop it.
                    // are they okay?
                    $error("attempt to consume a value from an empty slot. reciever must respect value presense")
                end
                'b001: begin
                    // nothing changes
                end
                'b000: begin 
                    // nothing changes
                end
            endcase
        end
    end
    always_comb begin
        if (clear) begin
            reciver_port.value_out = 0;
            reciver_port.has_value = 0;
            sender_port.ok = 0;
        end else begin
            case ({sender_port.put, reciver_port.drop, value_present})
                'b111: begin 
                    reciver_port.value_out = value;
                    reciver_port.has_value = 1;
                    sender_port.ok = 1;
                end
                'b110: begin
                    // error case
                    reciver_port.value_out = 0;
                    reciver_port.has_value = 0;
                    sender_port.ok = 1;
                end
                'b101: begin
                    // error case
                    reciver_port.value_out = value;
                    reciver_port.has_value = 1;
                    sender_port.ok = 0;
                end
                'b100: begin
                    reciver_port.value_out = 0;
                    reciver_port.has_value = 0;
                    sender_port.ok = 1;
                end
                'b011: begin
                    reciver_port.value_out = value;
                    reciver_port.has_value = 1;
                    sender_port.ok = 0;
                end
                'b010: begin
                    // error case
                    reciver_port.value_out = 0;
                    reciver_port.has_value = 0;
                    sender_port.ok = 0;
                end
                'b001: begin
                    reciver_port.value_out = value;
                    reciver_port.has_value = 1;
                    sender_port.ok = 0;
                end
                'b000: begin
                    reciver_port.value_out = 0;
                    reciver_port.has_value = 0;
                    sender_port.ok = 0;
                end
            endcase
        end
    end
endmodule

