// Directed tests for seg7_display: every hex digit decodes to the Basys 3
// common-anode pattern, exactly one anode is driven at a time, each nibble
// of the value lands on its own anode, and the scan visits an0..an3 in order
// holding each for 2**(REFRESH_W-2) cycles.
module tb_seg7_display;
  localparam int RW    = 4;
  localparam int DWELL = 1 << (RW - 2);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic [15:0] value;
  logic [6:0] seg; logic dp; logic [3:0] an;
  seg7_display #(.REFRESH_W(RW)) dut (.*);

  // {g,f,e,d,c,b,a}, active low -- the Basys 3 common-anode wiring.
  localparam logic [6:0] HEX [16] = '{
    7'b1000000, 7'b1111001, 7'b0100100, 7'b0110000,
    7'b0011001, 7'b0010010, 7'b0000010, 7'b1111000,
    7'b0000000, 7'b0010000, 7'b0001000, 7'b0000011,
    7'b1000110, 7'b0100001, 7'b0000110, 7'b0001110 };

  int errors = 0;
  logic [3:0] cur_an;
  int run = 0, runs = 0;
  initial begin
    value = '0;
    repeat (2) @(posedge clk); rst_n = 1'b1;
    for (int v = 0; v < 16; v++) begin
      value = {4'(v), 4'(v), 4'(v), 4'(v)};
      // Visit every anode at least once.
      repeat (4 * 16) begin
        @(negedge clk);
        if (dp !== 1'b1) begin errors++; $error("FAIL: dp lit"); end
        if (!(an inside {4'b1110, 4'b1101, 4'b1011, 4'b0111})) begin
          errors++; $error("FAIL: not exactly one anode low: %b", an);
        end
        if (seg !== HEX[v]) begin
          errors++; $error("FAIL: digit %0h shows %b, want %b", v, seg, HEX[v]);
        end
      end
    end
    // Digits land on the right anodes.
    value = 16'h1234;
    repeat (4 * 16) begin
      @(negedge clk);
      case (an)
        4'b1110: if (seg !== HEX[4]) begin errors++; $error("FAIL: an0"); end
        4'b1101: if (seg !== HEX[3]) begin errors++; $error("FAIL: an1"); end
        4'b1011: if (seg !== HEX[2]) begin errors++; $error("FAIL: an2"); end
        4'b0111: if (seg !== HEX[1]) begin errors++; $error("FAIL: an3"); end
        default: ;
      endcase
    end
    // Scan order and dwell. Nothing above notices a scan running at the clock
    // rate, which on the board is a display switching far too fast to drive.
    @(negedge clk); cur_an = an;
    repeat (8 * DWELL) begin
      @(negedge clk);
      if (an === cur_an) run++;
      else begin
        if (runs > 0 && run + 1 != DWELL) begin   // the first run may be partial
          errors++; $error("FAIL: anode %b held %0d cycles, want %0d", cur_an, run + 1, DWELL);
        end
        if (an !== {cur_an[2:0], cur_an[3]}) begin
          errors++; $error("FAIL: anode %b followed by %b", cur_an, an);
        end
        runs++; run = 0; cur_an = an;
      end
    end
    if (runs < 6) begin errors++; $error("FAIL: only %0d anode changes seen", runs); end
    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_seg7_display");
    $finish;
  end
endmodule
