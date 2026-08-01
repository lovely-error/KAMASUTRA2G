
interface PipeSendPort #(type Item);
    bit put;
    bit full;
    Item data_in;
endinterface

interface PipeRecievePort #(type Item);
    bit drop;
    bit valid;
    Item item;
endinterface

module Pipe #(type Item) (
    clk,
    sender,
    reciever
);
    input bit clk;
    PipeSendPort sender;
    PipeRecievePort reciever;

    Item storage [1:0];
    bit write_index = 0;
    bit read_index = 0;
    bit is_full = 0;

    wire bit full = is_full;
    wire bit empty = (write_index == read_index) && !is_full;

    always_ff @(posedge clk) begin
        if (sender.put && !full) begin
            storage[write_index] <= sender.data_in;
            write_index <= ~write_index;
            if (write_index != read_index) is_full <= 1;
        end
        if (reciever.drop && !empty) begin
            read_index <= ~read_index;
            is_full <= 0;
        end
    end
    always_comb begin
        reciever.item = storage[read_index];
        sender.full = full;
        reciever.valid = !empty;
    end

endmodule

module PipeCDC #(type Item) (
    sender,
    reciever,
    sender_clk,
    reciever_clk
);
    PipeSendPort sender;
    PipeRecievePort reciever;
    input bit sender_clk;
    input bit reciever_clk;

    Item storage [1:0];
    bit write_index = 0;
    bit read_index = 0;
    bit [1:0] read_salt = 0;
    bit [1:0] write_salt = 0;

    wire bit full = write_salt[write_index] != read_salt[write_index];
    wire bit empty = read_salt[read_index] == write_salt[read_index];

    always_ff @(posedge sender_clk) begin
        if (sender.put && !full) begin
            storage[write_index] <= sender.data_in;
            write_salt[write_index] <= ~write_salt[write_index];
            write_index <= ~write_index;
        end
    end

    always_ff @(posedge reciever_clk) begin
        if (reciever.drop && !empty) begin
            read_salt[read_index] <= ~read_salt[read_index];
            read_index <= ~read_index;
        end
    end

    always_comb begin
        reciever.item = storage[read_index];
        reciever.valid = !empty;
        sender.full = full;
    end

endmodule
