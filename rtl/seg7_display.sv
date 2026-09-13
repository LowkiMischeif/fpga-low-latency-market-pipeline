// seg7_display.sv -- four-digit multiplexed hex display for the Basys 3.
// Segments and anodes are active low; seg = {g,f,e,d,c,b,a}.
module seg7_display #(
  parameter int REFRESH_W = 17   // 2**17 cycles at 100 MHz ~ 1.3 ms per digit
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] value,
  output logic [6:0]  seg,
  output logic        dp,
  output logic [3:0]  an
);
  logic [REFRESH_W-1:0] ctr;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ctr <= '0; else ctr <= ctr + 1'b1;

  logic [1:0] digit;
  logic [3:0] nib;
  assign digit = ctr[REFRESH_W-1 -: 2];
  assign dp    = 1'b1;

  always_comb begin
    unique case (digit)
      2'd0: begin an = 4'b1110; nib = value[3:0];   end
      2'd1: begin an = 4'b1101; nib = value[7:4];   end
      2'd2: begin an = 4'b1011; nib = value[11:8];  end
      default: begin an = 4'b0111; nib = value[15:12]; end
    endcase
    unique case (nib)
      4'h0: seg = 7'b1000000;  4'h1: seg = 7'b1111001;
      4'h2: seg = 7'b0100100;  4'h3: seg = 7'b0110000;
      4'h4: seg = 7'b0011001;  4'h5: seg = 7'b0010010;
      4'h6: seg = 7'b0000010;  4'h7: seg = 7'b1111000;
      4'h8: seg = 7'b0000000;  4'h9: seg = 7'b0010000;
      4'hA: seg = 7'b0001000;  4'hB: seg = 7'b0000011;
      4'hC: seg = 7'b1000110;  4'hD: seg = 7'b0100001;
      4'hE: seg = 7'b0000110;  default: seg = 7'b0001110;
    endcase
  end
endmodule
