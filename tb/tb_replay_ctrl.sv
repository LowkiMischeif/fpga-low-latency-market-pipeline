// Directed tests for replay_ctrl + trace_rom.
//
// The replay must present every ROM word exactly once, in order, with no
// bubble and no duplicate, under arbitrary backpressure -- the ROM has a
// registered read, so the address has to run one word ahead of the accept.
// A press during a replay, during the lockout, or while hold_off is high must
// be ignored, and each of those three is tested with the other two out of the
// way, so a test cannot pass on the strength of a different guard.
//
// Also pinned: a button held through a whole replay and past the lockout
// starts exactly one replay (rising-edge detect), and a long stall on the last
// word keeps offering that word unchanged. Every later replay restarts from
// the idx the previous one ended on, and its word order is checked too.
// stream_source_checker (bind_assertions.sv) checks s_data stability under
// every stall here.
module tb_replay_ctrl;
  import market_pkg::*;
  localparam int N = 8;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic btn = 1'b0, hold_off = 1'b0;
  logic [$clog2(N)-1:0] rom_addr;
  logic [EVENT_W-1:0]   rom_data, s_data;
  logic s_valid, s_ready, busy, start_pulse;

  trace_rom #(.N(N), .MEM_FILE("tb/mem/tb_trace8.mem"))
    u_rom (.clk(clk), .addr(rom_addr), .data(rom_data));
  replay_ctrl #(.N_TRACE(N), .LOCKOUT_W(6)) dut (.*);

  logic [EVENT_W-1:0] expect_mem [N];
  initial $readmemh("tb/mem/tb_trace8.mem", expect_mem);

  int errors = 0, got = 0, starts = 0;
  logic [EVENT_W-1:0] got_words [64];
  task automatic check(string name, logic cond);
    if (!cond) begin errors++; $error("FAIL: %s", name); end
  endtask

  // force_stall holds s_ready low outright. With stall_at_last armed, the
  // monitor raises it as soon as word N-2 is accepted, so the stall begins on
  // the last word's first cycle of offer.
  logic force_stall = 1'b0, stall_at_last = 1'b0;
  always @(posedge clk) begin
    if (rst_n && s_valid && s_ready) begin
      if (got < 64) got_words[got] = s_data;
      got++;
      if (stall_at_last && got == N - 1) force_stall = 1'b1;
    end
    if (rst_n && start_pulse) starts++;
  end

  // Random backpressure throughout.
  int unsigned st = 32'h1234_5678;
  always @(negedge clk) begin
    st ^= st << 13; st ^= st >> 17; st ^= st << 5;
    s_ready = !force_stall && ((st % 3) != 0);
  end

  task automatic press();
    @(negedge clk); btn = 1'b1;
    repeat (4) @(negedge clk);
    btn = 1'b0;
  endtask

  task automatic wait_idle();
    int guard = 0;
    @(negedge clk);
    while (busy) begin
      @(negedge clk); guard++;
      if (guard > 2000) $fatal(1, "FAIL: replay hung");
    end
  endtask

  task automatic check_order(string tag);
    for (int i = 0; i < N; i++)
      check($sformatf("%s: word %0d in order", tag, i), got_words[i] === expect_mem[i]);
  endtask

  initial begin
    repeat (3) @(posedge clk); rst_n = 1'b1;
    repeat (80) @(negedge clk);   // outlast the post-reset lockout (2**6)

    // --- one press replays all N words in order ------------------------
    press(); wait_idle();
    check("one press -> exactly N words", got == N);
    for (int i = 0; i < N; i++)
      check($sformatf("word %0d in order", i), got_words[i] === expect_mem[i]);
    check("one start pulse", starts == 1);
    check("s_valid low after the replay", s_valid === 1'b0);

    // --- a press during a replay is ignored -----------------------------
    // An 8-word replay finishes long before the 64-cycle lockout expires, so
    // a press "mid-replay" would be refused by the lockout alone. Stall the
    // replay past the lockout so that only !busy can refuse the second press.
    repeat (80) @(negedge clk);
    got = 0; starts = 0;
    press();
    force_stall = 1'b1;
    repeat (80) @(negedge clk);
    check("premise: replay still open after the lockout expired", busy === 1'b1 && got < N);
    press();                       // mid-replay, lockout expired
    repeat (4) @(negedge clk);
    force_stall = 1'b0;
    wait_idle();
    check("press during replay does not restart it", got == N && starts == 1);

    // --- a press inside the lockout is ignored --------------------------
    repeat (80) @(negedge clk);
    got = 0; starts = 0;
    press(); wait_idle();
    press();                       // lockout (64 cycles) not yet expired
    repeat (20) @(negedge clk);
    check("press inside lockout ignored", starts == 1 && got == N);

    // --- hold_off blocks a press ----------------------------------------
    repeat (80) @(negedge clk);
    got = 0; starts = 0;
    hold_off = 1'b1;
    press();
    repeat (20) @(negedge clk);
    check("hold_off blocks a press", starts == 0 && got == 0);
    hold_off = 1'b0;

    // --- a button held past the replay and the lockout starts it once ----
    // The spec is a rising-edge detect. On the board a press easily outlasts
    // the 10 ms lockout, so a level-sensitive start would replay again for as
    // long as the button stays down.
    repeat (80) @(negedge clk);
    got = 0; starts = 0;
    @(negedge clk); btn = 1'b1;
    repeat (300) @(negedge clk);
    check("premise: replay done and lockout expired with the button still held",
          busy === 1'b0 && dut.lockout == '0);
    btn = 1'b0;
    repeat (80) @(negedge clk);
    check("held button: exactly one replay", starts == 1 && got == N);
    check_order("held-button replay");   // restarted from idx = N-1

    // --- a long stall on the last word -----------------------------------
    repeat (80) @(negedge clk);
    got = 0; starts = 0;
    stall_at_last = 1'b1;
    press();
    wait (force_stall === 1'b1);
    repeat (100) begin
      @(negedge clk);
      check("last word still offered during the stall", busy === 1'b1 && s_valid === 1'b1);
      check("last word unchanged during the stall", s_data === expect_mem[N-1]);
    end
    check("nothing accepted during the stall", got == N - 1);
    stall_at_last = 1'b0; force_stall = 1'b0;
    wait_idle();
    check("stalled replay: last word accepted exactly once", got == N && starts == 1);
    check_order("last-word stall replay");

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_replay_ctrl");
    $finish;
  end

  initial begin #2000000; $fatal(1, "FAIL: timeout"); end
endmodule
