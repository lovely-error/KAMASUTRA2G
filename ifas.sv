
typedef bit [(16*8)-1:0] Stripe;

interface RespPort;
    bit valid;
    
endinterface

module IFAS #(int CELL_COUNT) (
    clk,
    lane1_data_out,
    lane1_req_in,
);
    input bit clk;
    PipeSendPort lane1_data_out;
    PipeRecievePort lane1_req_in;
    PipeSendPort fetch_req;

    bit [31:0] start_addr [CELL_COUNT-1:0];
    bit [32:0] end_addr [CELL_COUNT-1:0];
    bit [5:0] relevance_counter [CELL_COUNT-1:0];

    typedef Stripe [511:0] Cell;
    Cell storage [CELL_COUNT-1:0];

    Stripe storage_out_lane_1 [CELL_COUNT-1:0];
    bit [CELL_COUNT-1:0] hit_pattern;

    bit lane_1_active = 0;
    bit [31:0] lane_1_fetch_addr;

    always_comb begin
        hit_pattern = 0;
        if (lane_1_active) begin
            for (int i = 0; i < CELL_COUNT; i++) begin
                hit_pattern[i] = 
                    (start_addr[i] <= lane_1_fetch_addr) &&
                    (lane_1_fetch_addr < end_addr[i]) ;
            end
        end
    end

    typedef bit [$clog2(8)-1:0] CellIx;
    bit [31:0] lane_1_addr_offset;

    always_comb begin
        lane_1_addr_offset = 0;
        for (int i = 0; i < CELL_COUNT; i++) begin
            if (hit_pattern[i]) begin
                lane_1_addr_offset = lane_1_fetch_addr - start_addr[i] ;
            end
        end
    end

    wire bit [$clog2(512)-1:0] lane_1_row_ix = (lane_1_addr_offset >> 4);
    wire bit lane_1_any_hit = hit_pattern != 0;

    bit delayed_push_valid [0:0];
    CellIx delayed_push_cell_ix [0:0];
    wire bit lane_1_blocked = lane1_data_out.full;
    bit [31:0] lane_1_fetch_addr_delayed;

    always_ff @(posedge clk) begin
        for (int i = 0; i < CELL_COUNT; i++) begin
            storage_out_lane_1[i] <= storage[i][lane_1_row_ix];
        end
        if (lane_1_active && !lane_1_blocked && lane_1_any_hit) begin
            delayed_push_valid[0] <= 1;
            delayed_push_cell_ix[0] <= i;
            lane_1_fetch_addr <= lane_1_fetch_addr + 16;
            lane_1_fetch_addr_delayed <= lane_1_fetch_addr;
        end else begin
            delayed_push_valid[0] <= 0;
        end
    end

    always_comb begin
        lane1_data_out.put = delayed_push_valid;
        lane1_data_out.data_in = '{
            addr: lane_1_fetch_addr_delayed,
            stripe: storage_out_lane_1[delayed_push_cell_ix[0]]
        };
    end

    bit fetch_active_index;
    bit fetch_slot_valid [1:0];
    bit [31:0] fetch_slot [1:0] ;
    // if we got no hits we should prime fetch mechanism
    typedef enum { Dormant, WaitResp, Collect } FState;
    FState pf_state = Dormant;

    always_ff @(posedge clk) begin
        case (pf_state)
            Dormant: begin
                
            end
            WaitResp: begin
                
            end
            Collect: begin
                
            end
        endcase
    end
    always_comb begin
        
    end

endmodule
