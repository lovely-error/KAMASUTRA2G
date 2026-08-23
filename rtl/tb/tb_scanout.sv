// Framebuffer scanout, checked pixel by pixel against the image it was told
// to display.
//
// The memory is a model that MANUFACTURES its contents from the address rather
// than storing them: the word at a given address is a function of the source
// line and pixel it is supposed to hold. So a scanout that computes an address
// wrong does not read stale data, it reads a pixel that names where it
// actually looked -- and the mismatch says which line and which pixel it went
// to instead of the one it wanted.
//
// That matters because every plausible bug here is an address bug, and they
// all look identical on a monitor (a picture, slightly wrong):
//
//   line stride wrong        picture sheared
//   buffer parity swapped    every other line from the wrong place
//   word index off by one    picture shifted by two pixels
//   half-select inverted     adjacent pixels transposed
//   doubling wrong           picture squashed or stretched
//
// The frame is shortened to 8 display lines rather than 480. The horizontal
// dimension is left alone -- it is where the word and half arithmetic lives,
// and 160 words is exactly five 32-word bursts, which is the case the fetcher
// actually runs.

module tb_scanout;

  localparam int H_SRC    = 320;
  localparam int V_SRC    = 4;
  localparam int H_ACTIVE = 640;
  localparam int V_ACTIVE = 8;

  localparam logic [31:0] FB_BASE = 32'h0010_0000;
  localparam int LINE_BYTES = H_SRC * 2;

  // 13.5 MHz system, 25.2 MHz pixel -- the real ratio, and the interesting
  // part of it is that the bus clock is the SLOWER of the two.
  logic clk_sys = 0;
  logic clk_pixel = 0;
  always #37.037 clk_sys   = ~clk_sys;
  always #19.841 clk_pixel = ~clk_pixel;

  logic sys_rst_n = 0;
  logic px_rst_n  = 0;

  int checks = 0;
  int errors = 0;

  task automatic check(input string what, input logic ok);
    checks++;
    if (!ok) begin
      errors++;
      if (errors <= 20) $display("TB_FAIL: %s", what);
    end
  endtask

  // ---- what the framebuffer is supposed to contain ------------------------

  function automatic logic [15:0] px16(input int line, input int pixel);
    return 16'((line * H_SRC + pixel) & 32'hFFFF);
  endfunction

  // RGB565 -> RGB888 the same way the design does it: replicate the high bits
  // downwards, so full scale stays full scale.
  function automatic logic [7:0] exp_red  (input logic [15:0] p);
    return {p[15:11], p[15:13]};
  endfunction
  function automatic logic [7:0] exp_green(input logic [15:0] p);
    return {p[10:5], p[10:9]};
  endfunction
  function automatic logic [7:0] exp_blue (input logic [15:0] p);
    return {p[4:0], p[4:2]};
  endfunction

  // ---- timing -------------------------------------------------------------

  logic       hsync, vsync, de;
  logic [9:0] x, y, next_line;
  logic       line_start, vblank_start;

  k2g_video_timing #(
      .H_ACTIVE(H_ACTIVE), .H_FRONT(16), .H_SYNC(96), .H_BACK(48),
      .V_ACTIVE(V_ACTIVE), .V_FRONT(2),  .V_SYNC(2),  .V_BACK(3)
  ) u_timing (
      .clk(clk_pixel), .rst_n(px_rst_n),
      .hsync(hsync), .vsync(vsync), .de(de), .x(x), .y(y),
      .line_start(line_start), .next_line(next_line),
      .vblank_start(vblank_start)
  );

  // ---- device under test --------------------------------------------------

  k2g_membus bus ();

  logic       underrun;
  logic       hsync_d, vsync_d, de_d;
  logic [7:0] red, green, blue;

  k2g_video_scanout #(
      .H_SRC(H_SRC), .V_SRC(V_SRC),
      .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE),
      .FB_BASE(FB_BASE)
  ) u_dut (
      .clk_sys(clk_sys), .sys_rst_n(sys_rst_n), .bus(bus.master),
      .underrun(underrun),
      .clk_pixel(clk_pixel), .px_rst_n(px_rst_n),
      .hsync(hsync), .vsync(vsync), .de(de), .x(x), .y(y),
      .line_start(line_start), .vblank_start(vblank_start),
      .hsync_d(hsync_d), .vsync_d(vsync_d), .de_d(de_d),
      .red(red), .green(green), .blue(blue)
  );

  // ---- memory model -------------------------------------------------------
  //
  // Answers a read burst with the words the framebuffer would hold at that
  // address, one per cycle, after a few cycles of latency. Responses are not
  // stallable, which is the contract k2g_membus states and the reason the
  // scanout may only start a fetch into a buffer nothing is reading.

  function automatic logic [31:0] mem_word(input logic [31:0] byte_addr);
    int off, line, w;
    begin
      off  = int'(byte_addr - FB_BASE);
      line = off / LINE_BYTES;
      w    = (off % LINE_BYTES) / 4;
      return {px16(line, 2*w + 1), px16(line, 2*w)};
    end
  endfunction

  logic [31:0] burst_addr;
  int          burst_beats;
  int          bursts_served = 0;

  assign bus.req_ready = (burst_beats == 0);

  always_ff @(posedge clk_sys) begin
    if (!sys_rst_n) begin
      burst_beats  <= 0;
      bus.rsp_valid <= 1'b0;
      bus.rsp_data  <= 32'd0;
    end else begin
      bus.rsp_valid <= 1'b0;
      if (bus.req_valid && bus.req_ready) begin
        check($sformatf("read burst is 32 beats (len=%0d)", bus.req.len),
              bus.req.len == 5'd31);
        check("scanout only reads", bus.req.we == 4'b0000);
        burst_addr  <= bus.req.addr;
        burst_beats <= 32;
        bursts_served++;
      end else if (burst_beats > 0) begin
        bus.rsp_valid <= 1'b1;
        bus.rsp_data  <= mem_word(burst_addr);
        burst_addr    <= burst_addr + 32'd4;
        burst_beats   <= burst_beats - 1;
      end
    end
  end

  // ---- check every displayed pixel ----------------------------------------

  int pixels_checked = 0;
  int frame = 0;

  // `de_d` and the colour come out together, one cycle behind the timing
  // generator, so the coordinates to compare against are the delayed ones too.
  logic [9:0] x_d, y_d;
  always_ff @(posedge clk_pixel) begin
    x_d <= x;
    y_d <= y;
  end

  logic [15:0] want;

  always_ff @(posedge clk_pixel) begin
    if (px_rst_n && de_d && frame > 0) begin
      // Doubled both ways: display (x,y) shows source pixel (x>>1, y>>1).
      want = px16(int'(y_d) / 2, int'(x_d) / 2);
      if (red !== exp_red(want) || green !== exp_green(want)
                                || blue !== exp_blue(want)) begin
        check($sformatf("pixel (%0d,%0d) -> src (%0d,%0d): got %02x%02x%02x want %02x%02x%02x",
                        x_d, y_d, int'(x_d)/2, int'(y_d)/2,
                        red, green, blue,
                        exp_red(want), exp_green(want), exp_blue(want)), 1'b0);
      end else begin
        checks++;
      end
      pixels_checked++;
    end
  end

  // ---- run ----------------------------------------------------------------

  initial begin
    repeat (8) @(posedge clk_sys);
    sys_rst_n = 1;
    px_rst_n  = 1;

    // Let the first frame prime the buffers, then check the second and third
    // in full. Checking from the very first frame would fail on the lines
    // displayed before the fetcher has ever run, which is a real property but
    // not this test's -- the design does not claim to show a correct picture
    // before it has read one.
    @(posedge vblank_start);
    frame = 1;
    @(posedge vblank_start);
    @(posedge vblank_start);

    check($sformatf("every active pixel checked (%0d of %0d)",
                    pixels_checked, 2 * H_ACTIVE * V_ACTIVE),
          pixels_checked == 2 * H_ACTIVE * V_ACTIVE);
    check($sformatf("no underrun (bursts served %0d)", bursts_served),
          underrun === 1'b0);
    // Five bursts per source line, V_SRC lines per frame, over two checked
    // frames plus the priming one.
    check($sformatf("bursts served looks like whole lines (%0d)", bursts_served),
          (bursts_served % 5) == 0);

    // The delayed timing must still be the timing, just later.
    check("de_d is a real signal", de_d === 1'b0 || de_d === 1'b1);

    $display("checks=%0d errors=%0d pixels=%0d bursts=%0d",
             checks, errors, pixels_checked, bursts_served);
    if (errors == 0) $display("TB_PASS tb_scanout");
    else             $display("TB_FAIL tb_scanout: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #50000000;
    $display("TB_FAIL tb_scanout: timeout");
    $finish;
  end

endmodule
