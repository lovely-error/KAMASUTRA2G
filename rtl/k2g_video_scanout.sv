// Framebuffer scanout: reads a 320x240 RGB565 image out of PSRAM and hands
// pixels to the TMDS encoders, doubled to fill a 640x480 display.
//
// ---- WHY 320x240 AND NOT 640x480 ----
//
// Not the pixel clock and not the PSRAM, both of which have room to spare. The
// limit is the bus in between. `clk_sys` is 13.5 MHz and `k2g_membus` returns
// one 32-bit word per cycle, so 432 Mbit/s is the ceiling on everything the
// machine can read. One display line is 800 pixel clocks at 25.2 MHz, which is
// 428 `clk_sys` cycles, and that is the budget a scanout has to live inside:
//
//   640x480 16bpp native       320 words/line     75% of the whole bus
//   640x480 8bpp palette       160 words/line     37%
//   320x240 16bpp doubled       80 words/line     19%   <- this
//
// The output signal is 640x480@60 in every case; what changes is how much of
// the memory bus the picture eats. At 75% the CPU gets a quarter of its own
// memory bandwidth and any hiccup is a visible tear. At 19% the machine is
// still a machine.
//
// H_SRC and V_SRC are parameters and the doubling follows from them -- the
// display side reads source pixel (x>>1, y>>1) -- so native 640x480 means
// setting H_SRC/V_SRC to 640/480 and dropping the shifts. Read the table
// before doing it.
//
// ---- STRUCTURE ----
//
//   clk_sys                          |  clk_pixel
//                                    |
//   membus master --> line buffers --+--> pixel mux --> rgb
//   (5 bursts of 32 words per line)  |    (x>>2 word, x>>1 half)
//
// TWO LINE BUFFERS, PING-PONGED, and the vertical doubling is the reason they
// exist. Each source line is displayed twice. Re-reading it for the second
// pass would double the bandwidth back to 38% and throw away the entire point
// of scaling; so a source line is fetched once and replayed from the buffer.
//
// The buffer a line lands in is its own parity -- source line N lives in
// buffer N&1 -- which means the display side never has to be told which buffer
// to read: it is `(y>>1)&1` and cannot disagree with the fill side.
//
// ---- THE CLOCK CROSSING ----
//
// One toggle and one stable value, which is the pattern this needs rather than
// a k2g_cdc_fifo. The pixel side raises `req_toggle` when it wants a source
// line and leaves `req_line` alone until the next request -- at least one
// display line later, 428 `clk_sys` cycles -- so the sys side syncs the toggle
// through two flops and reads the value only after seeing the edge, by which
// time it has been stable for hundreds of cycles.
//
// A FIFO would be the wrong shape here anyway: it would smooth the rate but
// still leave the vertical doubling needing a line of storage, so it would be
// a FIFO in front of a line buffer where a line buffer alone will do.
//
// ---- BSRAM ----
//
// The buffers are INFERRED as a 1-write 1-read array with two clocks, which is
// the shape Gowin maps to SDPB. That is deliberate and it is the shape that
// works: docs/bring-up.md records that inferring a TRUE dual-port array (a
// read port and a write port sharing both directions) comes out as
// WRITE_MODE = 2'b10, which DPB does not support and place-and-route rejects.
// k2g_regfile.sv infers 1R1W the same way and lands in BSRAM. VERIFY IT: the
// netlist must contain SDPB, and if this ever falls back to flip-flops it
// costs about 512 registers and the soc build has nowhere to put them.
//
//   grep -c SDPB rtl/board/out/hdmi/impl/gwsynthesis/project.vg

module k2g_video_scanout #(
    parameter int          H_SRC    = 320,   // source pixels per line
    parameter int          V_SRC    = 240,   // source lines
    parameter int          H_ACTIVE = 640,   // display pixels per line
    parameter int          V_ACTIVE = 480,   // display lines
    parameter logic [31:0] FB_BASE  = 32'h0010_0000
) (
    // ---- clk_sys side: the bus master --------------------------------------
    input  logic clk_sys,
    input  logic sys_rst_n,
    k2g_membus.master bus,

    // Sticky, and read from the sys domain. Set when a source line is asked
    // for before the previous fetch finished -- the one failure mode that
    // looks like a picture rather than an error.
    output logic underrun,

    // ---- clk_pixel side: timing in, pixels out -----------------------------
    input  logic       clk_pixel,
    input  logic       px_rst_n,
    input  logic       hsync,
    input  logic       vsync,
    input  logic       de,
    input  logic [9:0] x,
    input  logic [9:0] y,
    input  logic       line_start,
    input  logic       vblank_start,

    // Timing delayed to match the buffer's read latency, so the caller wires
    // THESE to the encoders and not the ones it passed in. A synchronous BSRAM
    // read costs a cycle; moving the syncs by the same cycle keeps the picture
    // aligned without a pre-skewed address that wraps at the end of a line.
    output logic       hsync_d,
    output logic       vsync_d,
    output logic       de_d,
    output logic [7:0] red,
    output logic [7:0] green,
    output logic [7:0] blue
);

  // Two 32-bit words hold two RGB565 pixels, so a source line is H_SRC/2
  // words and the buffer pair is twice that.
  localparam int WORDS_PER_LINE = H_SRC / 2;                 // 160
  // THE STRIDE BETWEEN THE TWO BUFFERS IS A POWER OF TWO, and it is not the
  // line length. Addressing is `{buffer, word}` concatenated, which costs
  // nothing, but that only works if the buffer index shifts by a power of two
  // -- and 160 is not one. Sizing the array at 2 x 160 while addressing it at
  // a stride of 256 put buffer 1 at words 256..415 of a 320-word array: the
  // top of every odd line fell off the end and the display read whatever was
  // left. Caught by tb_scanout, which reads a manufactured framebuffer and so
  // reported the line it actually landed on.
  localparam int BUF_STRIDE     = 2 ** $clog2(WORDS_PER_LINE);   // 256
  localparam int BUF_WORDS      = BUF_STRIDE * 2;                // 512
  localparam int BUF_AW         = $clog2(BUF_WORDS);             // 10
  localparam int LINE_AW        = $clog2(V_SRC);             // 8
  // One PSRAM burst is 32 words (k2g_psram.sv: the controller's smallest
  // transfer is 128 bytes and k2g_membus len is beats minus one).
  localparam int BURST_WORDS    = 32;
  localparam int BURSTS_PER_LINE = WORDS_PER_LINE / BURST_WORDS;   // 5
  localparam int LINE_BYTES     = H_SRC * 2;                 // 640

  // ---- the line buffers ---------------------------------------------------

  (* syn_ramstyle = "block_ram" *)
  logic [31:0] linebuf [0:BUF_WORDS-1];

  logic [BUF_AW-1:0] buf_waddr, buf_raddr;
  logic [31:0]       buf_wdata, buf_rdata;
  logic              buf_we;

  always_ff @(posedge clk_sys) begin
    if (buf_we) linebuf[buf_waddr] <= buf_wdata;
  end

  always_ff @(posedge clk_pixel) begin
    buf_rdata <= linebuf[buf_raddr];
  end

  // ---- pixel side: request the next source line ---------------------------
  //
  // `req_line` is the line being asked for and `req_toggle` says a new request
  // exists. Both live in clk_pixel; only the toggle is synchronized.

  logic [LINE_AW-1:0] req_line;
  logic               req_toggle;

  // How far ahead the fetcher should be. During vertical blanking the answer
  // is 2 -- lines 0 and 1, so both buffers are primed before the beam reaches
  // the top of the picture, which the 45 blanked lines leave ample room for.
  // During the active area it is two source lines past the one on screen.
  // THE GUARD TESTS THE LINE ABOUT TO BE SENT, not the one already sent, and
  // the difference is a corrupted picture. `req_line` is post-increment: the
  // sys side reads it after the toggle has crossed, by which time it holds the
  // NEW value. Testing the old one let the vertical blanking interval issue
  // one request too many -- lines 0 and 1 primed correctly, then a third
  // request for line 2, which lands in buffer 0 and overwrites line 0 before
  // the beam has drawn it. The top of every frame came from two lines down.
  wire logic [LINE_AW+1:0] next_req = (LINE_AW+2)'(req_line) + (LINE_AW+2)'(1);

  logic [LINE_AW+1:0] target;
  always_comb begin
    if (y >= 10'(V_ACTIVE)) target = (LINE_AW+2)'(2);
    else                    target = (LINE_AW+2)'({1'b0, y[9:1]}) + (LINE_AW+2)'(2);
  end

  always_ff @(posedge clk_pixel) begin
    if (!px_rst_n) begin
      req_line   <= '0;
      req_toggle <= 1'b0;
    end else if (vblank_start) begin
      // Start the frame over. Nothing in flight matters: the fetcher is at
      // most one line behind and the blanking interval is 45 lines long.
      req_line   <= '0;
      req_toggle <= ~req_toggle;
    end else if (line_start && (next_req < target)
                            && (next_req < (LINE_AW+2)'(V_SRC))) begin
      req_line   <= req_line + LINE_AW'(1);
      req_toggle <= ~req_toggle;
    end
  end

  // ---- pixel side: read the buffer ----------------------------------------
  //
  // Each 32-bit word is two source pixels and each source pixel is two display
  // pixels, so the word index is x>>2 and the half is x[1]. The buffer half is
  // the source line's parity, y[1] -- source line y>>1, buffer (y>>1)&1.

  // Buffer (y>>1)&1 = y[1], word x>>2, at the power-of-two stride above.
  assign buf_raddr = BUF_AW'(y[1] ? (BUF_STRIDE + int'(x[9:2])) : int'(x[9:2]));

  logic sel_half;
  always_ff @(posedge clk_pixel) begin
    hsync_d  <= hsync;
    vsync_d  <= vsync;
    de_d     <= de;
    sel_half <= x[1];
  end

  // RGB565 out of the selected half, expanded to eight bits per channel by
  // replicating the high bits into the low ones -- so full scale stays full
  // scale and 0 stays 0, which a left shift would not do.
  wire logic [15:0] px = sel_half ? buf_rdata[31:16] : buf_rdata[15:0];

  always_comb begin
    red   = {px[15:11], px[15:13]};
    green = {px[10:5],  px[10:9]};
    blue  = {px[4:0],   px[4:2]};
  end

  // ---- sys side: see the request ------------------------------------------

  logic req_meta /* synthesis syn_preserve = 1 */;
  logic req_sync /* synthesis syn_preserve = 1 */;
  logic req_seen;

  always_ff @(posedge clk_sys) begin
    if (!sys_rst_n) begin
      req_meta <= 1'b0;
      req_sync <= 1'b0;
      req_seen <= 1'b0;
    end else begin
      req_meta <= req_toggle;
      req_sync <= req_meta;
      req_seen <= req_sync;
    end
  end

  wire logic req_edge = (req_sync != req_seen);

  // ---- sys side: fetch ----------------------------------------------------

  typedef enum logic [1:0] { S_IDLE, S_REQ, S_DATA } state_e;
  state_e state;

  logic [LINE_AW-1:0]  fetch_line;
  logic [2:0]          burst_num;     // 0..BURSTS_PER_LINE-1
  logic [5:0]          beats_left;    // counts a 32-beat response down
  logic [BUF_AW-1:0]   fill_addr;

  // Byte address of the burst about to be issued.
  wire logic [31:0] burst_addr =
      FB_BASE + (32'(fetch_line) * 32'(LINE_BYTES))
              + (32'(burst_num)  * 32'(BURST_WORDS * 4));

  assign bus.req_valid = (state == S_REQ);
  assign bus.req       = '{addr  : burst_addr,
                           len   : 5'(BURST_WORDS - 1),
                           we    : 4'b0000,          // read
                           wdata : 32'd0};

  // Responses land straight in the buffer. They cannot be stalled -- the bus
  // has no ready on the response channel -- which is exactly why a fetch is
  // only started when the whole target buffer is free.
  assign buf_we    = bus.rsp_valid && (state == S_DATA);
  assign buf_wdata = bus.rsp_data;
  assign buf_waddr = fill_addr;

  always_ff @(posedge clk_sys) begin
    if (!sys_rst_n) begin
      state      <= S_IDLE;
      fetch_line <= '0;
      burst_num  <= '0;
      beats_left <= '0;
      fill_addr  <= '0;
      underrun   <= 1'b0;
    end else begin
      // A request arriving while a fetch is still running means the beam has
      // caught up with the fetcher. Sticky, because it is the symptom that
      // explains a torn picture and a single frame of it is enough to know.
      if (req_edge && (state != S_IDLE)) underrun <= 1'b1;

      unique case (state)
        S_IDLE: begin
          if (req_edge) begin
            fetch_line <= req_line;
            burst_num  <= '0;
            // Source line N fills buffer N&1, which is what the display side
            // assumes -- it reads buffer (y>>1)&1 and is never told.
            fill_addr  <= req_line[0] ? BUF_AW'(BUF_STRIDE) : BUF_AW'(0);
            state      <= S_REQ;
          end
        end

        S_REQ: begin
          if (bus.req_ready) begin
            beats_left <= 6'(BURST_WORDS);
            state      <= S_DATA;
          end
        end

        S_DATA: begin
          if (bus.rsp_valid) begin
            fill_addr  <= fill_addr + BUF_AW'(1);
            beats_left <= beats_left - 6'd1;
            if (beats_left == 6'd1) begin
              if (burst_num == 3'(BURSTS_PER_LINE - 1)) begin
                state <= S_IDLE;
              end else begin
                burst_num <= burst_num + 3'd1;
                state     <= S_REQ;
              end
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
