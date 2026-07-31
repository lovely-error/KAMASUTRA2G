interface PaddingBufferIn #(type Item);
    bit put;
    bit full;
    Item data_in;
endinterface

interface PaddingBufferOut #(type Item);
    bit drop;
    bit valid;
    Item last;
endinterface

module PaddingBuffer #(type Item, int ITEM_COUNT) (
    clk,
    in,
    out,
    clear
);
    input bit clk;
    PaddingBufferIn in;
    PaddingBufferOut out;
    input bit clear;

    Item storage [ITEM_COUNT-1:0];
    typedef bit [$clog2(ITEM_COUNT):0] Ix;
    Ix read_index = 0;
    Ix write_index = 0;

    bit full = 0;
    wire bit empty = (read_index == write_index) && !full;

    wire bit next_read_index = (read_index+1)==ITEM_COUNT?0:read_index+1;
    wire bit next_write_index = (write_index+1)==ITEM_COUNT?0:write_index+1;

    wire bit next_full = next_write_index == read_index;

    always_ff @(posedge clk) begin
        if (clear) begin
            read_index <= 0;
            write_index <= 0;
            full <= 0;
        end else begin
            case ({in.put && !full, out.drop && !empty})
                2'b10: begin // Write only
                    storage[write_index] <= in.data_in;
                    write_index <= next_write_index;
                    if (next_full) is_full <= 1'b1;
                end
                2'b01: begin // Read only
                    read_index <= next_read_index;
                    is_full <= 1'b0;
                end
                2'b11: begin // Simultaneous Read/Write
                    storage[write_index] <= in.data_in;
                    write_index <= next_write_index;
                    read_index  <= next_read_index;
                    is_full <= is_full;
                end
            endcase
        end
    end

    always_comb begin
        in.full = full;
        out.last = storage[read_index];
        out.valid = !empty;
    end

endmodule