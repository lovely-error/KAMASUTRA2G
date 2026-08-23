// Stage 7: a picture out of PSRAM. NO CPU, NO UART.
//
//   bash rtl/board/build.sh hdmifb
//
// Stage 6 (`hdmi`) proved the video path with a pattern generated from the
// beam position -- no memory in it at all. This adds the memory: a writer
// fills a 320x240 RGB565 framebuffer in PSRAM once at startup, and
// k2g_video_scanout reads it back line by line, ahead of the beam. If `hdmi`
// shows bars and this shows nothing, the fault is in the memory path and not
// in the video path, which is the whole reason the two stages are separate.
//
// BOTH rPLLs ARE IN USE HERE, which is the arrangement the full machine will
// need and the reason this stage is worth building before that one: k2g_pll
// for the 81 MHz memory clock and k2g_hdmi_pll for the 126 MHz TMDS clock.
// The device has exactly two.
//
// The scanout and the writer are separate masters, and they do not need an
// arbiter added for them -- k2g_psram already takes two, arbitrating cycle by
// cycle. The scanout sits on `ibus` (it only ever reads, like a fetch) and the
// writer on `dbus`.
//
// What a working board looks like:
//
//   LED0  crystal heartbeat
//   LED1  video PLL locked
//   LED2  pixel clock alive
//   LED3  PSRAM calibrated -- dark means the memory, and stage 3 (`psram`)
//         tests that on its own with nothing else in the design
//   LED4  the framebuffer fill has finished
//   LED5  SCANOUT UNDERRUN, sticky. Lit means the fetcher could not keep
//         ahead of the beam, which shows as a torn picture rather than a
//         blank one -- the failure this stage exists to make visible.
//
// FIVE HOLD VIOLATIONS ARE EXPECTED HERE and they are not this design's.
// Every one is inside u_psram_ctrl -- the DLL's calibration signals and the
// SERDES CALIB pins, the same paths docs/bring-up.md already records for the
// soc build, where there are fifteen of them. Verified by reading the hold
// path table rather than assuming: every From and To node is under
// u_psram_ctrl/u_psram_top. Setup is clean and nothing in the video path
// appears. If that ever stops being true, the check is
//
//   sed 's/<[^>]*>/|/g' out/hdmifb/impl/pnr/project_tr_content.html |
//       grep -A80 'Hold Paths Table'
//
// THE FIRST FRAMES ARE GARBAGE, by design. The scanout starts displaying
// immediately and the writer takes a few milliseconds to fill 76800 pixels
// through single-word writes, each of which costs a whole 128-byte PSRAM
// burst (k2g_psram.sv explains why). Waiting for LED4 before judging the
// picture is the intended procedure; making the writer fast would mean
// burst writes, which is work this stage does not need.

`include "k2g_types.svh"

module k2g_hdmi_fb_probe
  import k2g_types::*;
#(
    parameter int          H_SRC   = 320,
    parameter int          V_SRC   = 240,
    parameter logic [31:0] FB_BASE = 32'h0010_0000
) (
    input  logic       clk_27m,
    input  logic       rst_n,

    output logic [5:0] led,

    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n,

    output logic [1:0]  O_psram_ck,
    output logic [1:0]  O_psram_ck_n,
    inout  wire  [15:0] IO_psram_dq,
    inout  wire  [1:0]  IO_psram_rwds,
    output logic [1:0]  O_psram_cs_n,
    output logic [1:0]  O_psram_reset_n
);

  // ---- system clock: crystal / 2 = 13.5 MHz -------------------------------
  //
  // THE NET NAME `div` IS LOAD-BEARING. tangnano9k_hdmifb.sdc constrains
  // clk_sys as div[0], because `clk_sys` does not survive synthesis as a net
  // name -- the same trap tangnano9k_soc.sdc documents.

  logic [1:0] div = 2'd0;
  always_ff @(posedge clk_27m) div <= div + 2'd1;
  wire logic clk_sys = div[0];

  logic rst_meta = 1'b0, rst_syncd = 1'b0;
  always_ff @(posedge clk_sys) begin
    rst_meta  <= rst_n;
    rst_syncd <= rst_meta;
  end
  logic [3:0] rst_sync = 4'd0;
  wire  logic sys_rst_n = rst_sync[3];
  always_ff @(posedge clk_sys) rst_sync <= {rst_sync[2:0], rst_syncd};

  // ---- memory clock and the controller ------------------------------------

  logic memory_clk, mem_pll_lock;
  k2g_pll u_mem_pll (
      .clk_in    (clk_27m),
      .memory_clk(memory_clk),
      .pll_lock  (mem_pll_lock)
  );

  // The controller wants a long, clean reset after its PLL locks. Copied from
  // k2g_mon_probe, which is where it was got working.
  logic       pbtn_meta, pbtn_sync;
  logic       plock_meta, plock_sync;
  logic [8:0] prst_cnt;
  logic       psram_rst_n;
  always_ff @(posedge clk_27m) begin
    pbtn_meta  <= rst_n;
    pbtn_sync  <= pbtn_meta;
    plock_meta <= mem_pll_lock;
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
      .pll_lock       (mem_pll_lock),
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

  // ---- the two masters ----------------------------------------------------

  k2g_membus vbus ();      // scanout, reads only
  k2g_membus wbus ();      // the framebuffer writer

  logic calib;

  k2g_psram u_psram (
      .clk_sys      (clk_sys),
      .rst_n        (sys_rst_n),
      .ibus         (vbus),
      .dbus         (wbus),
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

  // ---- the framebuffer writer ---------------------------------------------
  //
  // Walks the framebuffer once and stops. Two RGB565 pixels per 32-bit word,
  // so the word index maps to source pixels 2*i and 2*i+1 of line
  // i / (H_SRC/2).
  //
  // The pattern is a gradient in two axes with a diagonal in the third, which
  // makes an addressing mistake legible: a wrong line stride shears the
  // diagonal, a wrong half-select stipples it.

  localparam int WORDS_PER_LINE = H_SRC / 2;
  localparam int FB_WORDS       = WORDS_PER_LINE * V_SRC;   // 38400

  logic [31:0] wr_index;
  logic        fill_done;

  wire logic [8:0] wr_line = 9'(wr_index / 32'(WORDS_PER_LINE));
  wire logic [8:0] wr_col  = 9'((wr_index % 32'(WORDS_PER_LINE)) * 32'd2);

  function automatic logic [15:0] pattern(input logic [8:0] px,
                                          input logic [8:0] py);
    // RGB565: red from x, green from y, blue from the diagonal.
    return {px[7:3], py[7:2], (px[7:3] ^ py[7:3])};
  endfunction

  assign wbus.req_valid = !fill_done && calib;
  assign wbus.req       = '{addr  : FB_BASE + (wr_index * 32'd4),
                            len   : 5'd0,
                            we    : 4'b1111,
                            wdata : {pattern(wr_col + 9'd1, wr_line),
                                     pattern(wr_col,        wr_line)}};

  always_ff @(posedge clk_sys) begin
    if (!sys_rst_n) begin
      wr_index  <= '0;
      fill_done <= 1'b0;
    end else if (!fill_done && calib && wbus.req_ready) begin
      if (wr_index == 32'(FB_WORDS - 1)) fill_done <= 1'b1;
      else                               wr_index  <= wr_index + 32'd1;
    end
  end

  // ---- video --------------------------------------------------------------

  logic clk_serial, clk_pixel, vid_pll_lock;

  k2g_hdmi_pll u_vid_pll (
      .clk_in    (clk_27m),
      .clk_serial(clk_serial),
      .clk_pixel (clk_pixel),
      .pll_lock  (vid_pll_lock)
  );

  logic [1:0] px_rst_sync;
  wire  logic px_rst_n = px_rst_sync[1];
  always_ff @(posedge clk_pixel or negedge vid_pll_lock) begin
    if (!vid_pll_lock) px_rst_sync <= 2'b00;
    else               px_rst_sync <= {px_rst_sync[0], rst_n};
  end

  logic       hsync, vsync, de;
  logic [9:0] x, y, next_line;
  logic       line_start, vblank_start;

  k2g_video_timing u_timing (
      .clk(clk_pixel), .rst_n(px_rst_n),
      .hsync(hsync), .vsync(vsync), .de(de), .x(x), .y(y),
      .line_start(line_start), .next_line(next_line),
      .vblank_start(vblank_start)
  );

  logic       hsync_d, vsync_d, de_d, underrun;
  logic [7:0] red, green, blue;

  k2g_video_scanout #(
      .H_SRC(H_SRC), .V_SRC(V_SRC),
      .H_ACTIVE(640), .V_ACTIVE(480),
      .FB_BASE(FB_BASE)
  ) u_scanout (
      .clk_sys(clk_sys), .sys_rst_n(sys_rst_n), .bus(vbus),
      .underrun(underrun),
      .clk_pixel(clk_pixel), .px_rst_n(px_rst_n),
      .hsync(hsync), .vsync(vsync), .de(de), .x(x), .y(y),
      .line_start(line_start), .vblank_start(vblank_start),
      .hsync_d(hsync_d), .vsync_d(vsync_d), .de_d(de_d),
      .red(red), .green(green), .blue(blue)
  );

  // The DELAYED timing goes to the encoders, because the colour is a cycle
  // behind the timing generator -- a synchronous line-buffer read.
  logic [9:0] sym_ch0, sym_ch1, sym_ch2;

  k2g_tmds_encode u_enc0 (
      .clk(clk_pixel), .rst_n(px_rst_n),
      .de(de_d), .din(blue), .c1(vsync_d), .c0(hsync_d), .dout(sym_ch0)
  );
  k2g_tmds_encode u_enc1 (
      .clk(clk_pixel), .rst_n(px_rst_n),
      .de(de_d), .din(green), .c1(1'b0), .c0(1'b0), .dout(sym_ch1)
  );
  k2g_tmds_encode u_enc2 (
      .clk(clk_pixel), .rst_n(px_rst_n),
      .de(de_d), .din(red), .c1(1'b0), .c0(1'b0), .dout(sym_ch2)
  );

  k2g_hdmi_out u_out (
      .clk_pixel (clk_pixel),
      .clk_serial(clk_serial),
      .rst_n     (px_rst_n),
      .sym_ch0   (sym_ch0),
      .sym_ch1   (sym_ch1),
      .sym_ch2   (sym_ch2),
      .tmds_clk_p(tmds_clk_p),
      .tmds_clk_n(tmds_clk_n),
      .tmds_d_p  (tmds_d_p),
      .tmds_d_n  (tmds_d_n)
  );

  // ---- status -------------------------------------------------------------

  logic [23:0] beat_xtal;
  always_ff @(posedge clk_27m) beat_xtal <= beat_xtal + 24'd1;

  logic [23:0] beat_pixel;
  always_ff @(posedge clk_pixel) begin
    if (!px_rst_n) beat_pixel <= '0;
    else           beat_pixel <= beat_pixel + 24'd1;
  end

  always_comb begin
    led    = 6'b111111;                 // active low
    led[0] = ~beat_xtal[23];
    led[1] = ~vid_pll_lock;
    led[2] = ~beat_pixel[23];
    led[3] = ~calib;
    led[4] = ~fill_done;
    led[5] = ~underrun;
  end

endmodule
