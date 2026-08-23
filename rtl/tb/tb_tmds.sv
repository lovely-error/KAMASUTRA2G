// TMDS encoder and video timing, checked against an independent decoder.
//
// The encoder is the one part of the video path where a bug is invisible on
// hardware: a monitor shows no picture, and "no picture" is equally consistent
// with a wrong pin, a dead PLL, a serializer clocked backwards, and a subtly
// wrong disparity rule. So this checks the property that actually matters --
// that a DVI receiver can recover the byte -- by writing the receiver.
//
// The decoder here is DVI 1.0 section 3.2.3 written straight from the
// specification, NOT by inverting the encoder's source. A matched pair of
// mistakes is the failure mode a self-inverse test cannot catch, and it is a
// realistic one, because both halves of this algorithm are transcriptions of
// the same table.
//
// Three properties are checked, and they fail differently on real hardware:
//
//   round trip     every byte decodes to itself      -> wrong colours
//   disparity      running sum stays bounded         -> AC-coupled link drifts
//                                                       and the picture fades
//                                                       or drops out
//   control words  exactly the four legal symbols,   -> receiver never finds
//                  and disparity resets on blanking     symbol lock, monitor
//                                                       reports no signal

module tb_tmds;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  int checks = 0;
  int errors = 0;

  task automatic check(input string what, input logic ok);
    checks++;
    if (!ok) begin
      errors++;
      if (errors <= 20) $display("TB_FAIL: %s", what);
    end
  endtask

  // ---- device under test --------------------------------------------------

  logic       de = 0;
  logic [7:0] din = 0;
  logic       c1 = 0, c0 = 0;
  logic [9:0] dout;

  k2g_tmds_encode u_enc (
      .clk(clk), .rst_n(rst_n),
      .de(de), .din(din), .c1(c1), .c0(c0),
      .dout(dout)
  );

  // ---- independent decoder, DVI 1.0 3.2.3 ---------------------------------
  //
  // Bit 9 says the eight data bits were inverted; bit 8 says the recode chain
  // was XOR rather than XNOR. Undo in that order.

  function automatic logic [7:0] tmds_decode(input logic [9:0] sym);
    logic [7:0] q;
    logic [7:0] d;
    begin
      q = sym[9] ? ~sym[7:0] : sym[7:0];
      d[0] = q[0];
      for (int i = 1; i < 8; i++) begin
        d[i] = sym[8] ? (q[i] ^ q[i-1]) : ~(q[i] ^ q[i-1]);
      end
      return d;
    end
  endfunction

  function automatic bit is_control(input logic [9:0] sym);
    return (sym == 10'b1101010100) || (sym == 10'b0010101011) ||
           (sym == 10'b0101010100) || (sym == 10'b1010101011);
  endfunction

  // Transitions WITHIN a symbol -- the nine boundaries between its own bits,
  // not the tenth against whatever was sent before it. The specification's
  // bounds (at most 5 for data, 7 or more for control) are stated on the
  // symbol alone, and the inter-symbol boundary is not the encoder's to
  // control: it depends on the previous pixel.
  function automatic int transitions(input logic [9:0] sym);
    int n;
    begin
      n = 0;
      for (int i = 1; i < 10; i++) begin
        if (sym[i] != sym[i-1]) n++;
      end
      return n;
    end
  endfunction

  // ---- running disparity of the encoded stream, measured on the wire ------

  int  running = 0;
  int  worst   = 0;

  task automatic account(input logic [9:0] sym);
    int ones;
    begin
      ones = 0;
      for (int i = 0; i < 10; i++) if (sym[i]) ones++;
      running += (ones - (10 - ones));
      if (running > worst) worst = running;
      if (-running > worst) worst = -running;
    end
  endtask

  // ---- video timing under test --------------------------------------------

  logic       hsync, vsync, t_de;
  logic [9:0] tx, ty, next_line;
  logic       line_start, vblank_start;

  k2g_video_timing u_vt (
      .clk(clk), .rst_n(rst_n),
      .hsync(hsync), .vsync(vsync), .de(t_de), .x(tx), .y(ty),
      .line_start(line_start), .next_line(next_line),
      .vblank_start(vblank_start)
  );

  // ---- stimulus -----------------------------------------------------------

  logic [7:0] sent[$];
  logic [9:0] last_sym;

  int de_pixels, line_pixels, lines, hsync_low, vsync_low, line_starts;
  int max_x, max_y;

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ---- 1. every byte, twice, so each is encoded from both a positive and
    // a negative running disparity. Encoding depends on `cnt`, so one pass
    // over 256 values exercises only half the algorithm.
    de = 1;
    last_sym = 10'b0;
    for (int pass = 0; pass < 2; pass++) begin
      for (int b = 0; b < 256; b++) begin
        din = 8'(b);
        sent.push_back(8'(b));
        @(posedge clk);
        // `dout` is registered, so it now holds the symbol for the byte
        // presented one cycle ago -- the first of these is the reset value
        // and is dropped below.
        if (sent.size() > 1) begin
          automatic logic [7:0] want = sent[sent.size()-2];
          check($sformatf("round trip %02x -> %010b -> %02x",
                          want, dout, tmds_decode(dout)),
                tmds_decode(dout) == want);
          // A data symbol must never collide with a control symbol: the
          // receiver uses those to find symbol boundaries and would resync
          // mid-picture.
          check($sformatf("data %02x is not a control word", want),
                !is_control(dout));
          // Transition minimization is the encoder's whole first stage. Five
          // is the bound the specification guarantees for data.
          check($sformatf("data %02x has <= 5 transitions", want),
                transitions(dout) <= 5);
          account(dout);
          last_sym = dout;
        end
      end
    end

    // The specification bounds the running disparity of the link. Anything
    // that grows without limit here is an AC-coupled link that drifts until
    // the receiver loses the eye.
    check($sformatf("running disparity bounded (worst %0d, end %0d)",
                    worst, running), worst <= 16);

    // ---- 2. blanking emits exactly the four control symbols, and each
    // carries the sync bits it was given.
    de = 0;
    for (int cc = 0; cc < 4; cc++) begin
      {c1, c0} = 2'(cc);
      @(posedge clk);
      @(posedge clk);   // through the output register
      check($sformatf("control {c1,c0}=%02b is a control word", 2'(cc)),
            is_control(dout));
      check($sformatf("control {c1,c0}=%02b has >= 7 transitions", 2'(cc)),
            transitions(dout) >= 7);
    end

    // ---- 3. DC balance WITHIN an active region.
    //
    // This is the property the algorithm actually guarantees, and arriving at
    // it took two wrong turns worth recording, because both looked like
    // encoder bugs and neither was.
    //
    // The first version measured the running disparity of the wire across many
    // active regions separated by blanking. The CLEAN design scored 52. The
    // encoder zeroes its counter at every blanking interval, by specification,
    // so whatever charge an active region ends with is forgotten rather than
    // corrected.
    //
    // The second version measured from a zeroed running total at each region
    // start but kept accounting the blanking symbols. That scored 46, and the
    // reason is a fact about TMDS worth stating plainly: THE FOUR CONTROL
    // SYMBOLS ARE NOT DC BALANCED. Two are (1101010100 and 0010101011, five
    // ones each) and two are not -- 0101010100 has four ones and 1010101011
    // has six. Twenty-four identical control symbols in a row therefore walk
    // the disparity by up to 48, and a real link does exactly this: hsync
    // holds one value for 96 pixels. The control symbols were chosen for
    // transition density, because that is what gives the receiver symbol lock;
    // DC balance during blanking was not on offer and is not required.
    //
    // So the bound that means something is the excursion across the ACTIVE
    // pixels of one region, which is where the receiver's eye has to stay
    // open. Instrumenting the encoder directly showed that returning to zero
    // every second symbol, within +/-8, is what it actually does.
    worst = 0;
    for (int burst = 0; burst < 40; burst++) begin
      running = 0;                    // the encoder zeroes its counter here too
      de = 1;
      for (int i = 0; i < 64; i++) begin
        // Ones-heavy and varying, so the encoder cannot settle into a
        // self-cancelling pair of symbols.
        din = 8'hF0 | 8'(i & 8'h0F);
        @(posedge clk);
        account(dout);
      end
      // Blanking is clocked through but deliberately NOT accounted: see above.
      de = 0; c1 = 1'(burst & 1); c0 = 1'(burst[1]);
      repeat (24) @(posedge clk);
    end
    $display("NOTE: worst in-region disparity excursion = %0d", worst);
    check($sformatf("in-region DC balance bounded (worst %0d)", worst),
          worst <= 10);

    // ---- 4. video timing: measure one whole frame rather than trusting the
    // parameters. A porch off by one is invisible in the RTL and shifts the
    // picture on the glass.
    de = 0;
    de_pixels = 0; line_pixels = 0; lines = 0;
    hsync_low = 0; vsync_low = 0; line_starts = 0;
    max_x = 0; max_y = 0;

    // Align to the top of a frame first.
    while (!(vblank_start === 1'b1)) @(posedge clk);
    while (!(line_start === 1'b1 && ty == 10'd0)) @(posedge clk);

    forever begin
      if (line_start) begin
        line_starts++;
        if (line_starts > 1) begin
          check($sformatf("line %0d is 800 pixels (%0d)", lines, line_pixels),
                line_pixels == 800);
        end
        line_pixels = 0;
        // The 526th line_start is the top of the NEXT frame. It closed the
        // frame being measured, so stop here rather than one pixel later --
        // counting its first pixel is what made this read 307201.
        if (line_starts > 525) break;
        lines++;
      end
      if (t_de) begin
        de_pixels++;
        if (int'(tx) > max_x) max_x = int'(tx);
        if (int'(ty) > max_y) max_y = int'(ty);
      end
      if (!hsync) hsync_low++;
      if (!vsync) vsync_low++;
      line_pixels++;
      @(posedge clk);
    end

    check($sformatf("525 lines per frame (%0d)", lines), lines == 525);
    check($sformatf("640x480 = 307200 active pixels (%0d)", de_pixels),
          de_pixels == 307200);
    check($sformatf("x reaches 639 (%0d)", max_x), max_x == 639);
    check($sformatf("y reaches 479 (%0d)", max_y), max_y == 479);
    // 96 pixels of hsync on each of 525 lines.
    check($sformatf("hsync low for 96*525 = 50400 (%0d)", hsync_low),
          hsync_low == 50400);
    // 2 lines of vsync, 800 pixels each.
    check($sformatf("vsync low for 2*800 = 1600 (%0d)", vsync_low),
          vsync_low == 1600);

    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("TB_PASS tb_tmds");
    else             $display("TB_FAIL tb_tmds: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TB_FAIL tb_tmds: timeout");
    $finish;
  end

endmodule
