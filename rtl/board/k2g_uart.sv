// 8N1 UART transmitter and receiver.
//
// Sized by parameter rather than hard-coded so the same source serves the
// board (27 MHz) and simulation (where a tiny divisor keeps testbenches fast).
//
// The receiver samples in the middle of each bit rather than at its edge, and
// re-synchronizes on every start bit, so it tolerates the clock mismatch
// between the FPGA and whatever is on the other end of the cable.

module k2g_uart_tx #(
    parameter int DIVISOR = 234        // 27_000_000 / 115200
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       valid,          // pulse to send `data`
    input  logic [7:0] data,
    output logic       ready,          // idle and able to accept
    output logic       tx
);

  localparam int CW = $clog2(DIVISOR);

  // start + 8 data + stop, shifted out low bit first.
  logic [9:0]    shifter;
  logic [3:0]    bits_left;
  logic [CW-1:0] tick;

  assign ready = (bits_left == 4'd0);
  assign tx    = shifter[0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      shifter   <= 10'h3FF;            // idle high
      bits_left <= 4'd0;
      tick      <= '0;
    end else if (bits_left == 4'd0) begin
      tick <= '0;
      if (valid) begin
        shifter   <= {1'b1, data, 1'b0};   // stop, data, start
        bits_left <= 4'd10;
      end else begin
        shifter <= 10'h3FF;
      end
    end else if (tick == CW'(DIVISOR - 1)) begin
      tick      <= '0;
      shifter   <= {1'b1, shifter[9:1]};
      bits_left <= bits_left - 4'd1;
    end else begin
      tick <= tick + CW'(1);
    end
  end

endmodule


module k2g_uart_rx #(
    parameter int DIVISOR = 234
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic       valid,          // one-cycle pulse when `data` is new
    output logic [7:0] data
);

  localparam int CW = $clog2(DIVISOR);

  // Two flops against metastability on an asynchronous input.
  logic rx_meta, rx_sync;
  always_ff @(posedge clk) begin
    rx_meta <= rx;
    rx_sync <= rx_meta;
  end

  typedef enum logic [1:0] { IDLE, START, DATA, STOP } state_e;
  state_e state;

  logic [CW-1:0] tick;
  logic [2:0]    bit_idx;
  logic [7:0]    shifter;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state   <= IDLE;
      tick    <= '0;
      bit_idx <= 3'd0;
      shifter <= 8'd0;
      valid   <= 1'b0;
      data    <= 8'd0;
    end else begin
      valid <= 1'b0;
      unique case (state)
        IDLE: begin
          tick <= '0;
          if (!rx_sync) state <= START;   // falling edge: start bit
        end

        // Wait half a bit and confirm the line is still low, which rejects a
        // glitch rather than mis-framing the whole byte.
        START: begin
          if (tick == CW'(DIVISOR / 2)) begin
            tick <= '0;
            if (!rx_sync) begin
              state   <= DATA;
              bit_idx <= 3'd0;
            end else begin
              state <= IDLE;
            end
          end else begin
            tick <= tick + CW'(1);
          end
        end

        // Sampling now lands mid-bit for every subsequent bit.
        DATA: begin
          if (tick == CW'(DIVISOR - 1)) begin
            tick    <= '0;
            shifter <= {rx_sync, shifter[7:1]};
            if (bit_idx == 3'd7) state <= STOP;
            else                 bit_idx <= bit_idx + 3'd1;
          end else begin
            tick <= tick + CW'(1);
          end
        end

        STOP: begin
          if (tick == CW'(DIVISOR - 1)) begin
            tick  <= '0;
            state <= IDLE;
            // Accept the byte only with a good stop bit; a framing error means
            // the baud rate is wrong and the data would be garbage anyway.
            if (rx_sync) begin
              data  <= shifter;
              valid <= 1'b1;
            end
          end else begin
            tick <= tick + CW'(1);
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
