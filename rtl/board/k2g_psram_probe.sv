// Bring-up stage: does the in-package PSRAM work at all?
//
//   blink -> loopback -> PSRAM -> soc
//
// The staged structure exists so a failure says which layer is at fault. PSRAM
// earns a stage of its own because it brings three things nothing else in this
// design has: a PLL, a controller that must calibrate before it will answer,
// and a clock domain that is not the core's.
//
// NO UART AND NO CROSSING. The result is on the LEDs. A UART here would need
// either its own divisor against a clock whose frequency is an output of an
// encrypted IP, or a clock-domain crossing -- and a crossing is precisely what
// this stage exists to avoid having in the picture while PSRAM itself is
// unproven. Everything below runs in the controller's own `clk_out` domain.
//
// LEDs, active low at the pin, so a lit LED is a 1 here:
//
//   LED0  PLL locked
//   LED1  controller finished calibrating
//   LED2  writes done
//   LED3  reads done
//   LED4  every readback matched          <- the one that matters
//   LED5  heartbeat, proving clk_out runs
//
// A board that shows 0 and 1 lit but never 2 has a controller that calibrated
// and then would not accept a command. One that reaches 3 without 4 is wired
// and running but returning wrong data, which points at the memory clock
// rather than at the logic.

module k2g_psram_probe (
    input  logic       clk_27m,
    input  logic       rst_n,
    output logic [5:0] led,
    // Declared so the constraints file matches the port list; held idle, the
    // same convention k2g_blink uses.
    output logic       uart_tx,
    input  logic       uart_rx,

    // In-package PSRAM.
    output logic [1:0]  O_psram_ck,
    output logic [1:0]  O_psram_ck_n,
    inout  wire  [15:0] IO_psram_dq,
    inout  wire  [1:0]  IO_psram_rwds,
    output logic [1:0]  O_psram_cs_n,
    output logic [1:0]  O_psram_reset_n
);

  // ---- clocks ------------------------------------------------------------
  logic memory_clk, pll_lock;

  k2g_pll u_pll (
      .clk_in    (clk_27m),
      .memory_clk(memory_clk),
      .pll_lock  (pll_lock)
  );

  // ---- controller --------------------------------------------------------
  logic [63:0] wr_data, rd_data;
  logic        rd_data_valid;
  logic [20:0] addr;
  logic        cmd, cmd_en, cmd_rdy, init_calib, clk_out;
  logic [7:0]  data_mask;

  PSRAM_Memory_Interface_HS_Top u_psram (
      .clk            (clk_27m),
      .memory_clk     (memory_clk),
      .pll_lock       (pll_lock),
      .rst_n          (rst_n),
      .O_psram_ck     (O_psram_ck),
      .O_psram_ck_n   (O_psram_ck_n),
      .IO_psram_dq    (IO_psram_dq),
      .IO_psram_rwds  (IO_psram_rwds),
      .O_psram_cs_n   (O_psram_cs_n),
      .O_psram_reset_n(O_psram_reset_n),
      .wr_data        (wr_data),
      .rd_data        (rd_data),
      .rd_data_valid  (rd_data_valid),
      .addr           (addr),
      .cmd            (cmd),
      .cmd_en         (cmd_en),
      .cmd_rdy        (cmd_rdy),
      .init_calib     (init_calib),
      .clk_out        (clk_out),
      .data_mask      (data_mask)
  );

  // ---- reset into the controller's domain --------------------------------
  logic [3:0] rsync;
  wire  logic srst_n = rsync[3];

  always_ff @(posedge clk_out or negedge rst_n) begin
    if (!rst_n) rsync <= 4'd0;
    else        rsync <= {rsync[2:0], 1'b1};
  end

  // ---- the test ----------------------------------------------------------
  // A handful of 64-bit words, written then read back. The pattern is derived
  // from the address rather than constant, so a controller that returns the
  // same stale word for every read fails instead of passing.
  localparam int N_WORDS = 16;

  function automatic logic [63:0] pattern(input logic [20:0] a);
    return {~a, 11'h5A5, a, 11'h3C3};
  endfunction

  typedef enum logic [2:0] {
    P_WAIT, P_WRITE, P_WRITE_WAIT, P_READ, P_READ_WAIT, P_DONE
  } phase_e;

  phase_e      phase;
  logic [20:0] idx;
  logic        wr_done, rd_done;

  // The readback comparison is registered rather than done on the
  // `rd_data_valid` path. A 64-bit equality straight off that signal placed at
  // 74.9 MHz against clk_out's 81 -- measured, not guessed -- so the captured
  // word and its expected value are latched and compared the cycle after.
  //
  // And split in half: 64 bits at once placed at 81.123 MHz against an 81.000
  // requirement, which is 0.15% margin and not a margin at all. Each half is
  // checked on its own cycle -- the captured words are held, so there is no
  // rush -- and the two verdicts are combined only where an LED reads them.
  logic [63:0] cap, cap_exp;
  logic        cap_valid, cap_valid2;
  logic        bad_lo, bad_hi;

  // The burst is 64 bytes, so consecutive commands step the address by the
  // burst rather than by one word.
  localparam logic [20:0] STEP = 21'd16;
  localparam logic [20:0] LAST = 21'd240;   // STEP * (N_WORDS-1)

  assign wr_data   = pattern(idx);
  assign addr      = idx;
  assign data_mask = 8'h00;             // write every byte

  always_ff @(posedge clk_out) begin
    if (!srst_n) begin
      phase   <= P_WAIT;
      idx     <= 21'd0;
      cmd     <= 1'b0;
      cmd_en  <= 1'b0;
      wr_done <= 1'b0;
      rd_done <= 1'b0;
      cap        <= 64'd0;
      cap_exp    <= 64'd0;
      cap_valid  <= 1'b0;
      cap_valid2 <= 1'b0;
      bad_lo     <= 1'b0;
      bad_hi     <= 1'b0;
    end else begin
      cmd_en     <= 1'b0;
      cap_valid  <= 1'b0;
      cap_valid2 <= cap_valid;
      if (cap_valid)  bad_lo <= bad_lo | (cap[31:0]  != cap_exp[31:0]);
      if (cap_valid2) bad_hi <= bad_hi | (cap[63:32] != cap_exp[63:32]);

      unique case (phase)
        P_WAIT: if (init_calib) phase <= P_WRITE;

        P_WRITE: if (cmd_rdy) begin
          cmd    <= 1'b1;               // write
          cmd_en <= 1'b1;
          phase  <= P_WRITE_WAIT;
        end

        P_WRITE_WAIT: begin
          if (idx == LAST) begin
            idx     <= 21'd0;
            wr_done <= 1'b1;
            phase   <= P_READ;
          end else begin
            idx   <= idx + STEP;
            phase <= P_WRITE;
          end
        end

        P_READ: if (cmd_rdy) begin
          cmd    <= 1'b0;               // read
          cmd_en <= 1'b1;
          phase  <= P_READ_WAIT;
        end

        P_READ_WAIT: if (rd_data_valid) begin
          // Only the first beat of each burst is checked; that is enough to
          // tell a working path from a broken one, and this stage is about
          // whether the memory answers at all.
          cap       <= rd_data;
          cap_exp   <= pattern(idx);
          cap_valid <= 1'b1;
          if (idx == LAST) begin
            rd_done <= 1'b1;
            phase   <= P_DONE;
          end else begin
            idx   <= idx + STEP;
            phase <= P_READ;
          end
        end

        default: ;                      // P_DONE: stay
      endcase
    end
  end

  // ---- status ------------------------------------------------------------
  logic [23:0] beat;
  always_ff @(posedge clk_out) beat <= beat + 24'd1;

  wire logic [5:0] status = {beat[23], (phase == P_DONE) && !bad_lo && !bad_hi,
                             rd_done, wr_done, init_calib, pll_lock};

  assign led = ~status;                 // active low

  assign uart_tx = 1'b1;                // idle high
  wire logic _unused = &{1'b0, uart_rx};

endmodule
