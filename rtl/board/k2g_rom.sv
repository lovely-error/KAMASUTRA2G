// GENERATED FILE -- DO NOT EDIT BY HAND.
// Produced by `mkrom` from E:/Code/KAMASUTRA2G/rtl/board/hello.bin.
//
// A case statement rather than an initialized RAM: GowinSynthesis does not
// honour $readmemh for inferred memory, so the program is held in logic and
// copied into RAM at reset by k2g_soc.

module k2g_rom (
    input  logic [5:0] addr,
    output logic [7:0]  data
);

  localparam int SIZE_BYTES = 54;

  always_comb begin
    unique case (addr)
      6'd0: data = 8'h00;
      6'd1: data = 8'h78;
      6'd2: data = 8'h3C;
      6'd3: data = 8'hF0;
      6'd4: data = 8'h40;
      6'd5: data = 8'hF0;
      6'd6: data = 8'h61;
      6'd7: data = 8'hE8;
      6'd8: data = 8'h7D;
      6'd9: data = 8'h7C;
      6'd10: data = 8'h09;
      6'd11: data = 8'h84;
      6'd12: data = 8'hBF;
      6'd13: data = 8'hFF;
      6'd14: data = 8'hDF;
      6'd15: data = 8'hFF;
      6'd16: data = 8'h43;
      6'd17: data = 8'hD8;
      6'd18: data = 8'h00;
      6'd19: data = 8'h78;
      6'd20: data = 8'h21;
      6'd21: data = 8'hD4;
      6'd22: data = 8'hF8;
      6'd23: data = 8'h87;
      6'd24: data = 8'hBF;
      6'd25: data = 8'hFF;
      6'd26: data = 8'h3F;
      6'd27: data = 8'hFF;
      6'd28: data = 8'h48;
      6'd29: data = 8'h65;
      6'd30: data = 8'h6C;
      6'd31: data = 8'h6C;
      6'd32: data = 8'h6F;
      6'd33: data = 8'h20;
      6'd34: data = 8'h66;
      6'd35: data = 8'h72;
      6'd36: data = 8'h6F;
      6'd37: data = 8'h6D;
      6'd38: data = 8'h20;
      6'd39: data = 8'h4B;
      6'd40: data = 8'h41;
      6'd41: data = 8'h4D;
      6'd42: data = 8'h41;
      6'd43: data = 8'h53;
      6'd44: data = 8'h55;
      6'd45: data = 8'h54;
      6'd46: data = 8'h52;
      6'd47: data = 8'h41;
      6'd48: data = 8'h32;
      6'd49: data = 8'h47;
      6'd50: data = 8'h21;
      6'd51: data = 8'h0D;
      6'd52: data = 8'h0A;
      6'd53: data = 8'h00;
      default: data = 8'h00;
    endcase
  end

endmodule
