// Bring-up stage: does the host protocol work, over real memory, with no CPU?
//
//   blink -> loopback -> psram -> mon -> soc
//
// The staged structure exists so a failure says which layer is at fault, and
// the monitor earns a stage because it is the first thing that puts framing, a
// baud rate, a clock crossing and 8 MB of PSRAM in the same design. Put it
// straight into `k2g_soc` and a board that will not answer could be any of
// those, plus the core, plus the caches, plus the boot copier.
//
// THERE IS NO CORE HERE. `k2g_mon` is built with `HAS_RUN_CONTROL` clear, so it
// reports memory and console but not run control in its IDENT, and refuses
// RESET rather than making the host discover that by timing out. `kctl ping`
// prints what it can do.
//
//   kctl --port COM3 ping
//   kctl --port COM3 poke 0x1000 0xDE 0xAD 0xBE 0xEF
//   kctl --port COM3 peek 0x1000 16
//
// The console is looped back on itself, which makes this the `loopback` stage
// again with framing on: `kctl console` plus a CONSOLE_IN frame comes back as
// CONSOLE_OUT, through the monitor's own buffers and coalescing. That exercises
// the whole console path on hardware without a program to produce one.
//
// LEDs, active low at the pin, so a lit LED is a 1 here:
//
//   LED0  the PSRAM controller has calibrated   <- nothing works before this
//   LED1  the monitor owns the bus (host has sent PAUSE)
//   LED2  a byte arrived on the serial line
//   LED3  a byte went out
//   LED4  unused
//   LED5  heartbeat, proving clk_sys runs
//
// A board showing only the heartbeat has a serial problem -- baud rate, pins,
// or the cable. One showing LED2 but never LED3 is receiving and not answering,
// which points at framing rather than at the link.

`include "k2g_types.svh"

module k2g_mon_probe
  import k2g_types::*;
#(
    parameter int MEM_BYTES = 8 * 1024 * 1024,
    parameter int XTAL_HZ   = 27_000_000,
    // The same divider the SoC uses, so the baud divisor below is the number
    // that will be built into the real machine. MUST match the net named in
    // tangnano9k_mon.sdc.
    parameter int CLK_DIV   = 2,
    parameter int BAUD      = 115_200
) (
    input  logic       clk_27m,
    input  logic       rst_n,
    output logic [5:0] led,
    output logic       uart_tx,
    input  logic       uart_rx,

    // In-package PSRAM. Dedicated pins the IP places itself, so no IO_LOC.
    output logic [1:0]  O_psram_ck,
    output logic [1:0]  O_psram_ck_n,
    inout  wire  [15:0] IO_psram_dq,
    inout  wire  [1:0]  IO_psram_rwds,
    output logic [1:0]  O_psram_cs_n,
    output logic [1:0]  O_psram_reset_n
);

  localparam int CLK_HZ  = XTAL_HZ / CLK_DIV;      // 13.5 MHz
  localparam int DIVISOR = CLK_HZ / BAUD;          // 117 -> 115385, 0.16%

  // ---- clock division -----------------------------------------------------
  // Power-up values are written down for the same reason as in k2g_soc: the
  // divider has no reset, Gowin flip-flops come up at 0, and an uninitialized
  // counter in simulation is X -- `X + 1` is X and the clock never toggles.
  logic [1:0] div = 2'd0;
  always_ff @(posedge clk_27m) div <= div + 2'd1;

  localparam int CLK_SEL = (CLK_DIV == 2) ? 0 : 1;
  wire logic clk_sys = div[CLK_SEL];

  // ---- reset --------------------------------------------------------------
  logic rst_meta = 1'b0, rst_syncd = 1'b0;
  always_ff @(posedge clk_sys) begin
    rst_meta  <= rst_n;
    rst_syncd <= rst_meta;
  end

  logic [3:0] rst_sync = 4'd0;
  wire  logic sys_rst_n = rst_sync[3];

  always_ff @(posedge clk_sys) rst_sync <= {rst_sync[2:0], rst_syncd};

  // ---- memory clock and the controller's reset ----------------------------
  // Lifted from k2g_soc, which lifted it from k2g_psram_probe where it was
  // found the hard way: the button is pulled up, so handed the raw signal the
  // controller leaves reset before the PLL has locked, with `memory_clk` still
  // garbage, and never gets another reset to recover with.
  logic memory_clk, pll_lock;

  k2g_pll u_pll (
      .clk_in    (clk_27m),
      .memory_clk(memory_clk),
      .pll_lock  (pll_lock)
  );

  logic       pbtn_meta, pbtn_sync;
  logic       plock_meta, plock_sync;
  logic [8:0] prst_cnt;
  logic       psram_rst_n;

  always_ff @(posedge clk_27m) begin
    pbtn_meta  <= rst_n;
    pbtn_sync  <= pbtn_meta;
    plock_meta <= pll_lock;
    plock_sync <= plock_meta;

    if (!pbtn_sync || !plock_sync) begin
      prst_cnt    <= 9'd0;
      psram_rst_n <= 1'b0;
    end else if (prst_cnt != 9'h1FF) begin
      prst_cnt    <= prst_cnt + 9'd1;
      psram_rst_n <= 1'b0;
    end else begin
      psram_rst_n <= 1'b1;
    end
  end

  logic [63:0] psram_wr_data, psram_rd_data;
  logic [20:0] psram_addr;
  logic [7:0]  psram_data_mask;
  logic        psram_cmd, psram_cmd_en, psram_cmd_rdy;
  logic        psram_rd_valid, psram_calib, psram_clk_out;

  PSRAM_Memory_Interface_HS_Top u_psram_ctrl (
      .clk            (clk_27m),
      .memory_clk     (memory_clk),
      .pll_lock       (pll_lock),
      .rst_n          (psram_rst_n),
      .O_psram_ck     (O_psram_ck),
      .O_psram_ck_n   (O_psram_ck_n),
      .IO_psram_dq    (IO_psram_dq),
      .IO_psram_rwds  (IO_psram_rwds),
      .O_psram_cs_n   (O_psram_cs_n),
      .O_psram_reset_n(O_psram_reset_n),
      .wr_data        (psram_wr_data),
      .rd_data        (psram_rd_data),
      .rd_data_valid  (psram_rd_valid),
      .addr           (psram_addr),
      .cmd            (psram_cmd),
      .cmd_en         (psram_cmd_en),
      .cmd_rdy        (psram_cmd_rdy),
      .init_calib     (psram_calib),
      .clk_out        (psram_clk_out),
      .data_mask      (psram_data_mask)
  );

  // ---- the bus ------------------------------------------------------------
  // The adapter arbitrates a fetch port against a data port. There is no fetch
  // port here, so it is tied idle rather than left undriven -- an unconnected
  // `req_valid` is X in simulation, and on hardware it is whatever the
  // synthesizer decides an undriven net should be.
  k2g_membus mbus ();
  k2g_membus ibus_idle ();

  assign ibus_idle.req_valid = 1'b0;
  assign ibus_idle.req       = '0;

  logic calib;

  k2g_psram u_psram (
      .clk_sys      (clk_sys),
      .rst_n        (sys_rst_n),
      .ibus         (ibus_idle),
      .dbus         (mbus),
      .calib        (calib),
      .clk_out      (psram_clk_out),
      .init_calib   (psram_calib),
      .cmd_rdy      (psram_cmd_rdy),
      .cmd          (psram_cmd),
      .cmd_en       (psram_cmd_en),
      .addr         (psram_addr),
      .wr_data      (psram_wr_data),
      .data_mask    (psram_data_mask),
      .rd_data      (psram_rd_data),
      .rd_data_valid(psram_rd_valid)
  );

  // ---- the serial link ----------------------------------------------------
  logic       rx_valid, tx_valid, tx_ready;
  logic [7:0] rx_data, tx_data;

  k2g_uart_rx #(.DIVISOR(DIVISOR)) u_rx (
      .clk(clk_sys), .rst_n(sys_rst_n), .rx(uart_rx),
      .valid(rx_valid), .data(rx_data)
  );

  k2g_uart_tx #(.DIVISOR(DIVISOR)) u_tx (
      .clk(clk_sys), .rst_n(sys_rst_n),
      .valid(tx_valid), .data(tx_data), .ready(tx_ready), .tx(uart_tx)
  );

  // ---- the monitor --------------------------------------------------------
  logic       fetch_hold, core_rst, bus_own, cmaint_req;
  logic       con_tx_ready, con_rx_valid;
  logic [7:0] con_rx_data;

  k2g_mon #(
      .MEM_BYTES       (MEM_BYTES),
      .HAS_RUN_CONTROL (1'b0),
      .HAS_CONSOLE     (1'b1)
  ) u_mon (
      .clk   (clk_sys),
      .rst_n (sys_rst_n),

      .rx_valid(rx_valid), .rx_data(rx_data),
      .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),

      .bus(mbus),

      // No core. Idle is permanently true, which is what makes PAUSE return at
      // once; the rest is tied off and reported as absent in IDENT.
      .fetch_hold      (fetch_hold),
      .core_idle       (1'b1),
      .core_halted     (1'b0),
      .core_faulted    (1'b0),
      .core_fault_cause(5'd0),
      .core_fault_addr (32'd0),
      .core_fault_info (32'd0),
      .core_cycles     (64'd0),
      .core_rst        (core_rst),
      .bus_own         (bus_own),

      // No caches either: the adapter is the only thing behind the bus.
      .cmaint_req (cmaint_req),
      .cmaint_done(1'b1),

      // The console, looped back through the monitor's own buffers. This is
      // the `loopback` stage with framing on, and it is what lets the whole
      // console path be tested on hardware with no program to produce output.
      .con_tx_valid(con_rx_valid),
      .con_tx_data (con_rx_data),
      .con_tx_ready(con_tx_ready),
      .con_rx_valid(con_rx_valid),
      .con_rx_data (con_rx_data),
      .con_rx_take (con_rx_valid && con_tx_ready)
  );

  // ---- status -------------------------------------------------------------
  // Serial activity is stretched: a byte is ten bit times and an eye cannot see
  // 87 microseconds.
  logic [21:0] rx_blip, tx_blip;
  logic [23:0] heartbeat;

  always_ff @(posedge clk_sys) begin
    if (!sys_rst_n) begin
      rx_blip   <= '0;
      tx_blip   <= '0;
      heartbeat <= '0;
    end else begin
      heartbeat <= heartbeat + 24'd1;
      if (rx_valid)             rx_blip <= '1;
      else if (rx_blip != '0)   rx_blip <= rx_blip - 22'd1;
      if (tx_valid && tx_ready) tx_blip <= '1;
      else if (tx_blip != '0)   tx_blip <= tx_blip - 22'd1;
    end
  end

  wire logic [5:0] status = {heartbeat[23], 1'b0, tx_blip != '0, rx_blip != '0,
                             bus_own, calib};

  assign led = ~status;                       // active low

  wire logic _unused = &{1'b0, fetch_hold, core_rst, cmaint_req};

endmodule
