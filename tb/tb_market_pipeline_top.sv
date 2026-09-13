// tb_market_pipeline_top.sv -- the real top, checked against the verified chain.
//
// A reference copy of decode..risk_gate + config_regs is fed the same ROM image
// directly and configured from the committed .cfg file. The top must produce
// the same decision, reason and position for every event, in both presets and
// across a second replay that starts with a populated book and a non-zero
// position. Latency inside the top, decoder accept to risk handoff, must be
// LATENCY_CYCLES for every event. A press while a preset is loading must be
// refused.
//
// Run 3 asserts btnU halfway through a replay, with events in every stage. The
// reference chain is reset at the same instant and has been fed nothing since
// run 2, so after the reset both sit before event 0 with a clean book. The top
// must come back as it does from power-on -- counters dark, kill armed until
// the loader recommits the selected preset -- and a fresh replay must match.
module tb_market_pipeline_top;
  import market_pkg::*;
  localparam int N = 2000;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic btnU = 1'b1, btnC = 1'b0;
  logic [15:0] sw = '0;
  logic [15:0] led;
  logic [6:0]  seg; logic dp; logic [3:0] an;

  market_pipeline_top #(.N_TRACE(N), .LOCKOUT_W(4), .REFRESH_W(4)) dut (.*);

  // ---------------- reference chain ----------------
  logic rrst_n = 1'b0;
  logic [EVENT_W-1:0] r_sdata; logic r_svalid, r_sready;
  market_event_t d_ev, q_ev, b_ev, f_ev, p_ev, m_ev;
  event_err_t    d_er, q_er, b_er, f_er, p_er, m_er;
  logic d_v, d_r, q_v, q_r, b_v, b_r, f_v, f_r, p_v, p_r, m_v;
  book_t b_bk; logic b_st; feature_t f_ft, p_ft, m_ft;
  decision_e p_dec; logic signed [SCORE_W-1:0] p_sc; logic [QTY_W-1:0] p_oq;
  risk_cfg_t p_rc; decision_t m_dec;
  logic [CNT_W-1:0] c0, c1, c2, c3, c4, ccnt;
  logic [CFG_ADDR_W-1:0] ca; logic [CFG_DATA_W-1:0] cd; logic cwe = 1'b0;
  policy_cfg_t pcfg; risk_cfg_t rcfg;

  event_decoder    r_dec (.clk(clk), .rst_n(rrst_n),
                          .s_data(r_sdata), .s_valid(r_svalid), .s_ready(r_sready),
                          .m_event(d_ev), .m_err(d_er), .m_valid(d_v), .m_ready(d_r));
  sequence_checker r_seq (.clk(clk), .rst_n(rrst_n),
                          .s_event(d_ev), .s_err(d_er), .s_valid(d_v), .s_ready(d_r),
                          .m_event(q_ev), .m_err(q_er), .m_valid(q_v), .m_ready(q_r),
                          .gap_count(c0), .stale_count(c1), .missed_total(c2),
                          .bad_event_count(c3), .resync_count(c4));
  top_of_book      r_tob (.clk(clk), .rst_n(rrst_n),
                          .s_event(q_ev), .s_err(q_er), .s_valid(q_v), .s_ready(q_r),
                          .m_event(b_ev), .m_err(b_er), .m_book(b_bk), .m_book_stale(b_st),
                          .m_valid(b_v), .m_ready(b_r));
  feature_engine   r_feat(.clk(clk), .rst_n(rrst_n),
                          .s_event(b_ev), .s_err(b_er), .s_book(b_bk), .s_book_stale(b_st),
                          .s_valid(b_v), .s_ready(b_r),
                          .m_event(f_ev), .m_err(f_er), .m_feat(f_ft),
                          .m_valid(f_v), .m_ready(f_r));
  policy_engine    r_pol (.clk(clk), .rst_n(rrst_n), .cfg(pcfg), .risk_cfg_in(rcfg),
                          .s_event(f_ev), .s_err(f_er), .s_feat(f_ft),
                          .s_valid(f_v), .s_ready(f_r),
                          .m_event(p_ev), .m_err(p_er), .m_feat(p_ft), .m_decision(p_dec),
                          .m_score(p_sc), .m_order_qty(p_oq), .m_risk_cfg(p_rc),
                          .m_valid(p_v), .m_ready(p_r));
  risk_gate        r_risk(.clk(clk), .rst_n(rrst_n), .cfg(p_rc),
                          .s_event(p_ev), .s_err(p_er), .s_feat(p_ft),
                          .s_decision(p_dec), .s_score(p_sc), .s_order_qty(p_oq),
                          .s_valid(p_v), .s_ready(p_r),
                          .m_event(m_ev), .m_err(m_er), .m_feat(m_ft), .m_decision(m_dec),
                          .m_valid(m_v), .m_ready(1'b1));
  config_regs      r_cfg (.clk(clk), .rst_n(rrst_n),
                          .cfg_addr(ca), .cfg_wdata(cd), .cfg_we(cwe),
                          .policy_cfg(pcfg), .risk_cfg(rcfg), .commit_count(ccnt));

  logic [EVENT_W-1:0] trace [N];
  initial $readmemh("rtl/mem/rom_trace.mem", trace);

  task automatic ref_load(string path);
    int fd, a, d; string line;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "FAIL: cannot open %s", path);
    while ($fgets(line, fd) != 0) begin
      if (line.len() == 0 || line[0] == "#") continue;
      if ($sscanf(line, "%h %h", a, d) != 2) continue;
      @(negedge clk); ca = CFG_ADDR_W'(a); cd = CFG_DATA_W'(d); cwe = 1'b1;
      @(negedge clk); cwe = 1'b0;
    end
    $fclose(fd);
  endtask

  task automatic ref_replay();
    for (int i = 0; i < N; i++) begin
      // risk_gate's m_ready is tied high, so every stage is always ready. If
      // that ever changes, stop rather than silently drop reference events.
      @(negedge clk);
      if (r_sready !== 1'b1) $fatal(1, "FAIL: reference chain not ready");
      r_sdata = trace[i]; r_svalid = 1'b1;
      @(negedge clk); r_svalid = 1'b0;
    end
  endtask

  // ---------------- recorders ----------------
  localparam int CAP = 3 * N;
  decision_t top_d [CAP];
  decision_t ref_d [CAP];
  int n_top = 0, n_ref = 0;
  always @(posedge clk) begin
    if (dut.u_risk.m_valid && dut.u_risk.m_ready && n_top < CAP) begin
      top_d[n_top] = dut.u_risk.m_decision; n_top++;
    end
    if (rrst_n && m_v && n_ref < CAP) begin
      ref_d[n_ref] = m_dec; n_ref++;
    end
  end

  // Latency inside the top: decoder accept to risk handoff, FIFO by order.
  // A reset discards whatever was in flight, so it empties the queue too.
  int cyc = 0, lat_bad = 0, lat_n = 0, t0;
  int ing [$];
  always @(posedge clk) begin
    cyc++;
    if (!dut.rst_n) ing.delete();
    if (dut.u_dec.s_valid && dut.u_dec.s_ready) ing.push_back(cyc);
    if (dut.u_risk.m_valid && dut.u_risk.m_ready && ing.size() > 0) begin
      t0 = ing.pop_front();
      lat_n++;
      if (cyc - t0 != LATENCY_CYCLES) lat_bad++;
    end
  end

  int errors = 0;
  task automatic check(string name, logic cond);
    if (!cond) begin errors++; $error("FAIL: %s", name); end
  endtask

  task automatic top_press();
    @(negedge clk); btnC = 1'b1;
    repeat (6) @(negedge clk); btnC = 1'b0;
  endtask

  task automatic top_wait_idle();
    int guard = 0;
    repeat (8) @(negedge clk);
    while (dut.u_replay.busy || dut.u_cfgl.busy) begin
      @(negedge clk); guard++;
      if (guard > 50 * N) $fatal(1, "FAIL: top never went idle");
    end
    repeat (LATENCY_CYCLES + 8) @(negedge clk);
  endtask

  task automatic compare_run(int from, int upto, string tag);
    int buys = 0, sells = 0, rej = 0;
    for (int i = from; i < upto; i++) begin
      if (top_d[i] !== ref_d[i]) begin
        errors++;
        if (errors < 6)
          $error("FAIL: %s event %0d top=%p ref=%p", tag, i - from, top_d[i], ref_d[i]);
      end
      if (ref_d[i].decision == DEC_BUY)  buys++;
      if (ref_d[i].decision == DEC_SELL) sells++;
      if (ref_d[i].reason != RSN_NONE)   rej++;
    end
    check({tag, " BUY counter"},    dut.buy_cnt  === 16'(buys));
    check({tag, " SELL counter"},   dut.sell_cnt === 16'(sells));
    check({tag, " reject counter"}, dut.rej_cnt  === 16'(rej));
    check({tag, " LEDs show the counters"}, led === {sells[7:0], buys[7:0]});
    $display("INFO: %s buy=%0d sell=%0d rejected=%0d", tag, buys, sells, rej);
    check({tag, " policy actually traded"}, buys + sells > 0);
  endtask

  int k_partial = 0, wguard;

  initial begin
    r_svalid = 1'b0; r_sdata = '0;
    // Reset both, release together.
    repeat (4) @(negedge clk);
    btnU = 1'b0; rrst_n = 1'b1;

    // Before the loader commits, the top must be killed and idle.
    @(negedge clk);
    check("top config is killed straight out of reset", dut.u_cfg.risk_cfg.kill === 1'b1);

    // ---- run 1: baseline ------------------------------------------------
    top_wait_idle();
    check("loader committed once", dut.u_cfg.commit_count === 32'd1);
    check("loader cleared the kill switch", dut.u_cfg.risk_cfg.kill === 1'b0);
    ref_load("tb/configs/baseline.cfg");
    fork top_press(); ref_replay(); join
    top_wait_idle();
    check("run 1 top produced N decisions", n_top == N);
    check("run 1 ref produced N decisions", n_ref == N);
    compare_run(0, N, "baseline");

    // ---- a press while the tuned preset loads is refused ---------------
    sw[0] = 1'b1;
    repeat (4) @(negedge clk);
    check("premise: the tuned preset is loading", dut.u_cfgl.busy === 1'b1);
    top_press();
    check("a press during a config load does not start a replay",
          dut.u_replay.busy === 1'b0);

    // ---- run 2: tuned, same trace, book and position carried over -------
    top_wait_idle();
    check("switch change committed again", dut.u_cfg.commit_count === 32'd2);
    check("no decisions from the refused press", n_top == N);
    ref_load("tb/configs/tuned.cfg");
    fork top_press(); ref_replay(); join
    top_wait_idle();
    check("run 2 top produced N more decisions", n_top == 2 * N);
    compare_run(N, 2 * N, "tuned");

    check("latency measured for every event", lat_n == 2 * N);
    check("latency is LATENCY_CYCLES for every event", lat_bad == 0);

    // ---- run 3: btnU asserted in the middle of a replay -----------------
    check("premise: run 3 starts from a non-zero position", dut.u_risk.position !== '0);
    top_press();
    wguard = 0;
    // Wait on handed-off decisions (int vs int), not on the replay's 11-bit
    // idx: both int'(dut.u_replay.idx) and a sized constant compared wrongly
    // in xsim, one never exiting and one exiting at once.
    while (n_top < 2 * N + N / 2) begin
      @(negedge clk);
      wguard++;
      if (wguard > 4 * N) $fatal(1, "FAIL: run 3 replay never reached mid-trace");
    end
    check("premise: reset lands mid-replay with events in flight",
          dut.u_replay.busy === 1'b1 && ing.size() > 0);
    btnU = 1'b1; rrst_n = 1'b0;
    k_partial = n_top - 2 * N;
    check("premise: at least N/2 decisions handed off before the reset", k_partial >= N / 2);
    repeat (4) @(negedge clk);
    check("reset: replay stopped", dut.u_replay.busy === 1'b0 && dut.u_dec.s_valid === 1'b0);
    check("reset: nothing leaves risk_gate", dut.u_risk.m_valid === 1'b0);
    check("reset: kill switch re-armed", dut.u_cfg.risk_cfg.kill === 1'b1);
    check("reset: counters and LEDs cleared", led === 16'h0 && dut.rej_cnt === 16'h0);
    n_top = 2 * N;                  // the partial run's decisions are discarded
    btnU = 1'b0; rrst_n = 1'b1;

    top_wait_idle();
    check("after reset the loader recommitted and cleared kill",
          dut.u_cfg.commit_count >= 1 && dut.u_cfg.risk_cfg.kill === 1'b0);
    check("after reset the counters stay clear until a press",
          led === 16'h0 && dut.rej_cnt === 16'h0);
    check("no decision leaks out of the reset", n_top == 2 * N);
    ref_load("tb/configs/tuned.cfg");
    check("recommitted config is the selected (tuned) preset",
          dut.u_cfg.policy_cfg === pcfg && dut.u_cfg.risk_cfg === rcfg);
    fork top_press(); ref_replay(); join
    top_wait_idle();
    check("run 3 top produced N decisions after the reset", n_top == 3 * N);
    check("run 3 ref produced N decisions", n_ref == 3 * N);
    compare_run(2 * N, 3 * N, "after mid-replay reset");

    check("latency measured for every handed-off event", lat_n == 3 * N + k_partial);
    check("latency is LATENCY_CYCLES for every event, across the reset", lat_bad == 0);
    $display("INFO: top latency %0d events, %0d not at %0d cycles (%0d handed off before the reset)",
             lat_n, lat_bad, LATENCY_CYCLES, k_partial);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_market_pipeline_top -- %0d decisions matched the reference chain,",
             3 * N, " latency %0d cycles", LATENCY_CYCLES);
    $finish;
  end

  initial begin #200000000; $fatal(1, "FAIL: timeout"); end
endmodule
