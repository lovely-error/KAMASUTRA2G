// TMDS 8b/10b encoder -- DVI 1.0 specification, section 3.2.2.
//
// One instance per colour channel. Eight bits of pixel in, ten bits of serial
// symbol out, chosen to do two things at once:
//
//   1. MINIMIZE TRANSITIONS. The first stage recodes the byte as a running
//      XOR or XNOR chain, whichever produces fewer edges. Nine bits come out:
//      eight recoded plus one saying which operation was used.
//   2. BALANCE DC. The second stage may invert those eight bits, and tracks
//      the running excess of ones over zeros in `cnt`. Over any window the
//      link stays near neutral, which is what lets the receiver run AC-coupled.
//
// During blanking the encoder ignores the pixel entirely and emits one of four
// fixed control symbols carrying `c1`/`c0` -- hsync and vsync on channel 0,
// and constant zero on the other two. Those four symbols carry seven or more
// transitions, where no data symbol can exceed five, and that gap is exactly
// how the receiver finds symbol boundaries: it hunts for them during blanking
// and locks. A data symbol that collided with a control word would break that
// lock and the monitor would report no signal rather than a corrupt picture,
// which is why tb_tmds checks the separation on all 256 bytes.
//
// The control symbols are NOT DC balanced -- two of the four are 4/6 -- and
// they are not meant to be. They were chosen for transition density, and
// rtl/sim/mutants.sh records what follows from that.
//
// WHY THE BIT COUNTS ARE WRITTEN OUT LONGHAND. `$countones` is not in the
// measured support table (docs/gowin-sv-support.md) and this is not the place
// to find out; an explicit adder tree is unambiguous to every tool and the
// synthesis result is the same.
//
// One pixel clock of latency. Every channel has the same latency and the
// timing signals are passed alongside, so nothing downstream needs to align
// them.

module k2g_tmds_encode (
    input  logic       clk,          // pixel clock
    input  logic       rst_n,

    input  logic       de,           // high: encode `din`; low: encode {c1,c0}
    input  logic [7:0] din,          // one colour channel
    input  logic       c1,
    input  logic       c0,

    output logic [9:0] dout
);

  // ---- stage 1: transition minimization -----------------------------------

  // Ones in the input byte, longhand (see header).
  wire logic [3:0] n1_din = 4'(din[0]) + 4'(din[1]) + 4'(din[2]) + 4'(din[3])
                          + 4'(din[4]) + 4'(din[5]) + 4'(din[6]) + 4'(din[7]);

  // XNOR when the byte is already ones-heavy, XOR otherwise. The tie at
  // exactly four ones is broken on bit 0, per the specification -- both
  // choices minimize transitions equally and the rule only exists so encoder
  // and decoder agree.
  wire logic use_xnor = (n1_din > 4'd4) || ((n1_din == 4'd4) && (din[0] == 1'b0));

  logic [8:0] q_m;
  always_comb begin
    q_m[0] = din[0];
    for (int i = 1; i < 8; i++) begin
      q_m[i] = use_xnor ? ~(q_m[i-1] ^ din[i]) : (q_m[i-1] ^ din[i]);
    end
    q_m[8] = ~use_xnor;               // 1 = the chain was XOR
  end

  // ---- stage 2: DC balance ------------------------------------------------

  wire logic [3:0] n1_qm = 4'(q_m[0]) + 4'(q_m[1]) + 4'(q_m[2]) + 4'(q_m[3])
                         + 4'(q_m[4]) + 4'(q_m[5]) + 4'(q_m[6]) + 4'(q_m[7]);

  // Excess of ones over zeros in q_m[7:0]: 2*n1 - 8, always even, -8..+8.
  wire logic signed [5:0] diff = signed'({2'b00, n1_qm}) - 6'sd8
                               + signed'({2'b00, n1_qm});

  // Running disparity of the link. Bounded well inside this width by the
  // algorithm itself; six bits is slack, not a requirement.
  logic signed [5:0] cnt;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cnt  <= '0;
      dout <= 10'b1101010100;         // the {c1,c0} = 00 control symbol
    end else if (!de) begin
      // Blanking. The disparity counter returns to zero here because the
      // specification says so, and NOT because decoding depends on it -- a
      // receiver recovers the byte from bits 9 and 8 alone, so a stale count
      // still decodes correctly. Verified: the mutant that removes this reset
      // is `tmds-disparity-survives-blanking` in rtl/sim/mutants.sh, recorded
      // as `survive` because no measurable property distinguishes it.
      cnt <= '0;
      unique case ({c1, c0})
        2'b00: dout <= 10'b1101010100;
        2'b01: dout <= 10'b0010101011;
        2'b10: dout <= 10'b0101010100;
        2'b11: dout <= 10'b1010101011;
      endcase
    end else if ((cnt == 6'sd0) || (n1_qm == 4'd4)) begin
      // Nothing to correct: either the link is neutral or this symbol is.
      // Send it in whichever polarity keeps the recode flag readable.
      dout <= {~q_m[8], q_m[8], (q_m[8] ? q_m[7:0] : ~q_m[7:0])};
      cnt  <= q_m[8] ? (cnt + diff) : (cnt - diff);
    end else if (((cnt > 6'sd0) && (n1_qm > 4'd4)) ||
                 ((cnt < 6'sd0) && (n1_qm < 4'd4))) begin
      // Symbol would push the disparity further the way it already leans.
      // Invert it.
      dout <= {1'b1, q_m[8], ~q_m[7:0]};
      cnt  <= cnt + signed'({4'b0000, q_m[8], 1'b0}) - diff;
    end else begin
      // Symbol already corrects the lean. Send it as-is.
      dout <= {1'b0, q_m[8], q_m[7:0]};
      cnt  <= cnt - signed'({4'b0000, ~q_m[8], 1'b0}) + diff;
    end
  end

endmodule
