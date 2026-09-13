// replay_ctrl.sv -- walks trace_rom into the pipeline once per button press.
//
// The ROM read is registered, so the address runs one word AHEAD on an accept:
// the word for idx+1 is being read on the same edge idx is consumed, and it is
// on rom_data the cycle after. That is what makes the replay bubble-free under
// backpressure; addressing idx alone would present the consumed word twice.
//
// The button is asynchronous: two flops, a rising-edge detect, and a lockout
// of 2**LOCKOUT_W cycles (about 10 ms at 100 MHz with the default). The lockout
// restarts on every cycle the synchronized button reads high, so it expires
// only after the button has been released and stayed low for the whole window.
// Bounce on the press and bounce on the release both land inside it. Starting
// the lockout only at the press was not enough: a real press outlasts 10 ms,
// and the release bounce then started a second replay.
module replay_ctrl
  import market_pkg::*;
#(
  parameter int N_TRACE   = 2000,
  parameter int LOCKOUT_W = 20
) (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        btn,        // asynchronous
  input  logic                        hold_off,   // e.g. config still loading
  output logic [$clog2(N_TRACE)-1:0]  rom_addr,
  input  logic [EVENT_W-1:0]          rom_data,
  output logic [EVENT_W-1:0]          s_data,
  output logic                        s_valid,
  input  logic                        s_ready,
  output logic                        busy,
  output logic                        start_pulse
);
  localparam int AW = $clog2(N_TRACE);

  (* ASYNC_REG = "TRUE" *) logic b1;
  (* ASYNC_REG = "TRUE" *) logic b2;
  // b_prev makes the press an explicit rising-edge detect. With the lockout
  // reloading while b2 is high it is logically redundant (lockout == 0 with b2
  // high implies b2 was low a cycle ago), so no mutant is listed for it; it is
  // kept so the edge detect does not depend on reading the lockout rule.
  logic                 b_prev;
  logic [LOCKOUT_W-1:0] lockout;
  logic [AW-1:0]        idx;
  logic                 primed;   // rom_data holds the word for idx

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b1 <= 1'b0; b2 <= 1'b0; b_prev <= 1'b0;
    end else begin
      b1 <= btn; b2 <= b1; b_prev <= b2;
    end
  end

  logic press, accept, last;
  assign press  = b2 && !b_prev && (lockout == '0) && !busy && !hold_off;
  assign accept = s_valid && s_ready;
  assign last   = (idx == AW'(N_TRACE - 1));

  assign rom_addr = (accept && !last) ? (idx + 1'b1) : idx;
  assign s_data   = rom_data;
  assign s_valid  = busy && primed;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; idx <= '0; primed <= 1'b0; start_pulse <= 1'b0;
      lockout <= '1;              // ignore anything bouncing out of reset
    end else begin
      start_pulse <= 1'b0;
      if (b2)                  lockout <= '1;
      else if (lockout != '0)  lockout <= lockout - 1'b1;
      if (press) begin
        busy <= 1'b1; idx <= '0; primed <= 1'b0; start_pulse <= 1'b1;
      end else if (busy) begin
        if (!primed) begin
          primed <= 1'b1;
        end else if (accept) begin
          if (last) begin busy <= 1'b0; primed <= 1'b0; end
          else      idx <= idx + 1'b1;
        end
      end
    end
  end
endmodule
