// tb_policy_configs.sv -- the headline claim of the policy branch.
//
// TWO COMMITTED CONFIGURATIONS, THE SAME TRACE, DIFFERENT DECISIONS,
// IDENTICAL LATENCY HISTOGRAMS.
//
// That is what makes "AI-customized policy deployed as deterministic
// fixed-point RTL" a statement about this design rather than a slogan. A
// configuration that changed the timing would mean the weights had reached a
// control path, and the fixed-latency claim would hold only for whatever
// weights happened to be loaded when it was measured.
//
// The configs are read from tb/configs/*.cfg -- the SAME files
// scripts/export_config.py writes and the repo commits. Nothing here
// re-derives them, so what is proven is the artefact that ships.
//
// Both passes drive byte-identical stimulus from the same seed. The run fails
// if the decisions are the same (the configs would not be demonstrating
// anything) or if the histograms differ by a single event.
module tb_policy_configs;
  import market_pkg::*;

  localparam int N_EVENTS  = 2000;
  localparam int MAX_HIST  = 64;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [EVENT_W-1:0] s_data;
  logic               s_valid, s_ready;

  market_event_t      d_event, q_event, b_event, f_event, p_event, m_event;
  event_err_t         d_err, q_err, b_err, f_err, p_err, m_err;
  logic               d_valid, d_ready, q_valid, q_ready, b_valid, b_ready;
  logic               f_valid, f_ready, p_valid, p_ready, m_valid, m_ready;
  book_t              b_book;
  logic               b_book_stale;
  feature_t           f_feat, p_feat, m_feat;
  decision_e          p_decision;
  logic signed [SCORE_W-1:0] p_score;
  logic [QTY_W-1:0]          p_order_qty;
  decision_t          m_dec;
  logic [CNT_W-1:0]   gap_count, stale_count, missed_total, bad_event_count;
  logic [CNT_W-1:0]   resync_count, commit_count;

  logic                  cfg_boundary;
  risk_cfg_t             p_risk_cfg;
  logic [CFG_ADDR_W-1:0] cfg_addr;
  logic [CFG_DATA_W-1:0] cfg_wdata;
  logic                  cfg_we;
  policy_cfg_t           policy_cfg;
  risk_cfg_t             risk_cfg;

  event_decoder u_dec (
    .clk(clk), .rst_n(rst_n),
    .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
    .m_event(d_event), .m_err(d_err), .m_valid(d_valid), .m_ready(d_ready));

  sequence_checker u_seq (
    .clk(clk), .rst_n(rst_n),
    .s_event(d_event), .s_err(d_err), .s_valid(d_valid), .s_ready(d_ready),
    .m_event(q_event), .m_err(q_err), .m_valid(q_valid), .m_ready(q_ready),
    .gap_count(gap_count), .stale_count(stale_count),
    .missed_total(missed_total), .bad_event_count(bad_event_count),
    .resync_count(resync_count));

  top_of_book u_tob (
    .clk(clk), .rst_n(rst_n),
    .s_event(q_event), .s_err(q_err), .s_valid(q_valid), .s_ready(q_ready),
    .m_event(b_event), .m_err(b_err), .m_book(b_book),
    .m_book_stale(b_book_stale), .m_valid(b_valid), .m_ready(b_ready));

  feature_engine u_feat (
    .clk(clk), .rst_n(rst_n),
    .s_event(b_event), .s_err(b_err), .s_book(b_book),
    .s_book_stale(b_book_stale), .s_valid(b_valid), .s_ready(b_ready),
    .m_event(f_event), .m_err(f_err), .m_feat(f_feat),
    .m_valid(f_valid), .m_ready(f_ready));

  policy_engine u_pol (
    .clk(clk), .rst_n(rst_n), .cfg(policy_cfg), .risk_cfg_in(risk_cfg),
    .s_event(f_event), .s_err(f_err), .s_feat(f_feat),
    .s_valid(f_valid), .s_ready(f_ready),
    .m_event(p_event), .m_err(p_err), .m_feat(p_feat),
    .m_decision(p_decision), .m_score(p_score), .m_order_qty(p_order_qty),
    .m_valid(p_valid), .m_ready(p_ready), .cfg_boundary(cfg_boundary),
    .m_risk_cfg(p_risk_cfg));

  risk_gate u_risk (
    .clk(clk), .rst_n(rst_n), .cfg(p_risk_cfg),
    .s_event(p_event), .s_err(p_err), .s_feat(p_feat),
    .s_decision(p_decision), .s_score(p_score), .s_order_qty(p_order_qty),
    .s_valid(p_valid), .s_ready(p_ready),
    .m_event(m_event), .m_err(m_err), .m_feat(m_feat),
    .m_decision(m_dec), .m_valid(m_valid), .m_ready(m_ready));

  config_regs u_cfg (
    .clk(clk), .rst_n(rst_n),
    .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_we(cfg_we),
    .boundary(cfg_boundary),
    .policy_cfg(policy_cfg), .risk_cfg(risk_cfg), .commit_count(commit_count));

  // ------------------------------------------------------------------
  // Stimulus: identical in both passes.
  // ------------------------------------------------------------------
  logic [EVENT_W-1:0] word [0:N_EVENTS-1];
  int unsigned rng;

  function automatic int unsigned xorshift32(ref int unsigned st);
    st ^= st << 13; st ^= st >> 17; st ^= st << 5;
    return st;
  endfunction

  function automatic int unsigned rand_range(ref int unsigned st,
                                             input int unsigned lo,
                                             input int unsigned hi);
    return lo + (xorshift32(st) % (hi - lo + 1));
  endfunction

  task automatic build_stimulus(input int unsigned seed);
    logic [EVENT_W-1:0] w;
    int unsigned st, roll;
    logic [SYMBOL_W-1:0] sym;
    logic [SIDE_W-1:0]   sd;
    logic [PRICE_W-1:0]  px;
    logic [QTY_W-1:0]    qy;
    st = (seed == 0) ? 32'hDEAD_BEEF : seed;
    for (int unsigned i = 0; i < N_EVENTS; i++) begin
      sym = SYMBOL_W'(rand_range(st, 0, N_SYMBOLS - 1));
      sd  = (rand_range(st, 0, 1) == 0) ? SIDE_BID : SIDE_ASK;
      // A small per-symbol ladder, so CANCEL and TRADE hit and the book is
      // genuinely two-sided; otherwise every feature is zero and neither
      // config can decide anything.
      px  = PRICE_W'(sym * 256 + rand_range(st, 0, 5) * 4
                     + ((sd == SIDE_ASK) ? 32 : 0));
      qy  = QTY_W'(rand_range(st, 1, 60));
      roll = rand_range(st, 0, 9);
      w = '0;
      w[TYPE_LSB   +: TYPE_W]   = (roll < 6) ? EVT_ADD
                                : (roll < 8) ? EVT_CANCEL : EVT_TRADE;
      w[SYMBOL_LSB +: SYMBOL_W] = sym;
      w[SIDE_LSB   +: SIDE_W]   = sd;
      w[PRICE_LSB  +: PRICE_W]  = px;
      w[QTY_LSB    +: QTY_W]    = qy;
      w[SEQ_LSB    +: SEQ_W]    = SEQ_W'(i);
      word[i] = w;
    end
  endtask

  // ------------------------------------------------------------------
  // Config loading, straight from the committed .cfg files.
  // ------------------------------------------------------------------
  task automatic load_config(string path);
    int fd, r, a, d;
    string line;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "FAIL: cannot open config %s", path);
    while ($fgets(line, fd) != 0) begin
      if (line.len() == 0 || line[0] == "#") continue;
      r = $sscanf(line, "%h %h", a, d);
      if (r != 2) continue;
      @(negedge clk);
      cfg_addr  = CFG_ADDR_W'(a);
      cfg_wdata = CFG_DATA_W'(d);
      cfg_we    = 1'b1;
      @(posedge clk);
      @(negedge clk);
      cfg_we = 1'b0;
    end
    $fclose(fd);
    // The commit is armed by the file's last line; give it a boundary.
    repeat (8) @(posedge clk);
  endtask

  // ------------------------------------------------------------------
  // Per-pass results.
  // ------------------------------------------------------------------
  decision_e dec_a  [0:N_EVENTS-1];
  decision_e dec_b  [0:N_EVENTS-1];
  decision_e dec_c  [0:N_EVENTS-1];
  int        switch_at;
  reason_e   rsn_a  [0:N_EVENTS-1];
  reason_e   rsn_b  [0:N_EVENTS-1];
  int        hist_a [0:MAX_HIST-1];
  int        hist_b [0:MAX_HIST-1];

  int  ing_time [0:N_EVENTS-1];
  int  cycle;
  int  sent, recvd, errors;
  bit  collecting;

  always_ff @(posedge clk) if (rst_n) cycle <= cycle + 1;

  task automatic run_pass(input string cfg_path, input bit second);
    // Full reset between passes: the book, the sequence baseline, the
    // position and the config must all start from the same place, or the
    // second pass is not the same experiment.
    @(negedge clk);
    rst_n = 1'b0; s_valid = 1'b0; cfg_we = 1'b0;
    sent = 0; recvd = 0; cycle = 0; collecting = 1'b0;
    for (int i = 0; i < MAX_HIST; i++) if (second) hist_b[i] = 0; else hist_a[i] = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_config(cfg_path);
    collecting = 1'b1;

    fork
      begin : driver
        for (int unsigned i = 0; i < N_EVENTS; i++) begin
          @(negedge clk);
          while (!s_ready) @(negedge clk);
          s_data  = word[i];
          s_valid = 1'b1;
          ing_time[i] = cycle;
          @(posedge clk);
          @(negedge clk);
          s_valid = 1'b0;
          sent++;
        end
      end
      begin : collector
        while (recvd < N_EVENTS) @(posedge clk);
      end
    join
    repeat (LATENCY_CYCLES + 8) @(posedge clk);
    collecting = 1'b0;
  endtask

  // Scoreboard: record the decision and the measured latency for each event.
  bit second_pass, third_pass;
  always_ff @(posedge clk) begin
    if (rst_n && collecting && m_valid && m_ready) begin
      int lat;
      lat = cycle - ing_time[recvd];
      if (lat < 0 || lat >= MAX_HIST) begin
        errors++;
        $error("FAIL: latency %0d out of range at event %0d", lat, recvd);
      end else begin
        if (second_pass) hist_b[lat]++; else hist_a[lat]++;
      end
      if (third_pass) begin
        dec_c[recvd] <= m_dec.decision;
      end else if (second_pass) begin
        dec_b[recvd] <= m_dec.decision;
        rsn_b[recvd] <= m_dec.reason;
      end else begin
        dec_a[recvd] <= m_dec.decision;
        rsn_a[recvd] <= m_dec.reason;
      end
      recvd++;
    end
  end

  // ------------------------------------------------------------------
  // Pass C: commit a second configuration WHILE events are in flight.
  //
  // Spec 5.5 claims a commit landing mid-flight cannot produce a decision
  // assembled from two configurations. Passes A and B both load into a drained
  // pipeline, so neither exercises that claim at all -- it was asserted in
  // three comment blocks and tested nowhere.
  //
  // Here the driver never stops, and the config is committed partway through.
  // Every decision must then match what pass A or pass B produced for that
  // event: A before the switch, B after, and nothing in between. A decision
  // matching NEITHER is a split configuration.
  // ------------------------------------------------------------------
  task automatic run_mixed_pass();
    @(negedge clk);
    rst_n = 1'b0; s_valid = 1'b0; cfg_we = 1'b0;
    sent = 0; recvd = 0; cycle = 0; collecting = 1'b0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    load_config("tb/configs/baseline.cfg");
    collecting = 1'b1;

    fork
      begin : mixed_driver
        for (int unsigned i = 0; i < N_EVENTS; i++) begin
          @(negedge clk);
          while (!s_ready) @(negedge clk);
          s_data  = word[i];
          s_valid = 1'b1;
          ing_time[i] = cycle;
          @(posedge clk);
          sent++;
          // Deliberately hold valid high: the pipeline stays full across the
          // commit, which is the whole point of this pass.
        end
        @(negedge clk);
        s_valid = 1'b0;
      end
      begin : committer
        // Wait until the pipe is genuinely full, then swap without pausing.
        wait (sent > switch_at);
        load_config("tb/configs/tuned.cfg");
      end
      begin : mixed_collector
        while (recvd < N_EVENTS) @(posedge clk);
      end
    join
    repeat (LATENCY_CYCLES + 8) @(posedge clk);
    collecting = 1'b0;
  endtask

  initial begin
    int differing, a_trades, b_trades, hist_mismatch;
    int split, matched_a, matched_b, differing_rsn;
    m_ready = 1'b1;
    s_valid = 1'b0; s_data = '0;
    cfg_addr = '0; cfg_wdata = '0; cfg_we = 1'b0;
    errors = 0; cycle = 0; second_pass = 1'b0; third_pass = 1'b0;
    switch_at = N_EVENTS / 2;

    build_stimulus(32'd1);

    // ---- pass A: baseline -------------------------------------------
    second_pass = 1'b0;
    run_pass("tb/configs/baseline.cfg", 1'b0);
    if (recvd != N_EVENTS)
      $fatal(1, "FAIL: pass A produced %0d of %0d events", recvd, N_EVENTS);

    // ---- pass B: tuned, identical stimulus --------------------------
    second_pass = 1'b1;
    run_pass("tb/configs/tuned.cfg", 1'b1);
    if (recvd != N_EVENTS)
      $fatal(1, "FAIL: pass B produced %0d of %0d events", recvd, N_EVENTS);

    // ---- the two claims ---------------------------------------------
    differing = 0; a_trades = 0; b_trades = 0;
    for (int i = 0; i < N_EVENTS; i++) begin
      if (dec_a[i] !== dec_b[i]) differing++;
      if (dec_a[i] != DEC_HOLD) a_trades++;
      if (dec_b[i] != DEC_HOLD) b_trades++;
    end

    differing_rsn = 0;
    for (int i = 0; i < N_EVENTS; i++)
      if (rsn_a[i] !== rsn_b[i]) differing_rsn++;
    $display("INFO: baseline trades=%0d  tuned trades=%0d  differing decisions=%0d reasons=%0d of %0d",
             a_trades, b_trades, differing, differing_rsn, N_EVENTS);
    $display("INFO: latency histogram (cycles: baseline / tuned)");
    hist_mismatch = 0;
    for (int i = 0; i < MAX_HIST; i++) begin
      if (hist_a[i] != 0 || hist_b[i] != 0)
        $display("INFO:   %0d: %0d / %0d", i, hist_a[i], hist_b[i]);
      if (hist_a[i] != hist_b[i]) hist_mismatch++;
    end

    // 1. The configurations must actually differ in behaviour.
    if (differing == 0) begin
      errors++;
      $error("FAIL: the two configs produced identical decisions -- they demonstrate nothing");
    end
    // BOTH must trade. A config that never trades is not a different policy,
    // it is an off switch, and "these two behave differently" would be a much
    // weaker claim than it sounds.
    if (a_trades == 0) begin
      errors++;
      $error("FAIL: the baseline config never traded -- that is an off switch, not a policy");
    end
    if (b_trades == 0) begin
      errors++;
      $error("FAIL: the tuned config never traded");
    end
    // And they must disagree on a meaningful fraction of events, not one.
    if (differing * 100 < N_EVENTS) begin
      errors++;
      $error("FAIL: only %0d of %0d decisions differ (<1%%) -- too close to demonstrate anything",
             differing, N_EVENTS);
    end

    // 2. And they must NOT differ in timing, at all.
    if (hist_mismatch != 0) begin
      errors++;
      $error("FAIL: latency histograms differ in %0d buckets -- configuration reached a control path",
             hist_mismatch);
    end
    if (hist_a[LATENCY_CYCLES] != N_EVENTS) begin
      errors++;
      $error("FAIL: baseline latency is not %0d for all %0d events (bucket holds %0d)",
             LATENCY_CYCLES, N_EVENTS, hist_a[LATENCY_CYCLES]);
    end
    if (hist_b[LATENCY_CYCLES] != N_EVENTS) begin
      errors++;
      $error("FAIL: tuned latency is not %0d for all %0d events (bucket holds %0d)",
             LATENCY_CYCLES, N_EVENTS, hist_b[LATENCY_CYCLES]);
    end

    // ---- pass C: commit mid-stream, pipeline never drained ----------
    third_pass = 1'b1;
    run_mixed_pass();
    if (recvd != N_EVENTS)
      $fatal(1, "FAIL: pass C produced %0d of %0d events", recvd, N_EVENTS);

    split = 0; matched_a = 0; matched_b = 0;
    for (int i = 0; i < N_EVENTS; i++) begin
      if      (dec_c[i] === dec_a[i] && dec_c[i] === dec_b[i]) begin
        matched_a++; matched_b++;      // the configs agree on this event
      end else if (dec_c[i] === dec_a[i]) matched_a++;
      else if (dec_c[i] === dec_b[i]) matched_b++;
      else begin
        split++;
        if (split <= 5)
          $error("FAIL: event %0d decided %0d, which is neither config A (%0d) nor B (%0d)",
                 i, dec_c[i], dec_a[i], dec_b[i]);
      end
    end
    $display("INFO: mid-stream commit -- %0d events match A, %0d match B, %0d match neither",
             matched_a, matched_b, split);
    if (split != 0) begin
      errors++;
      $error("FAIL: %0d decisions matched neither configuration -- a commit split an event",
             split);
    end
    // The commit must actually have taken effect, or this pass proves nothing.
    if (matched_b == 0) begin
      errors++;
      $error("FAIL: no event was decided under config B -- the mid-stream commit never landed");
    end

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_policy_configs -- %0d decisions differ, latency identical at %0d cycles, mid-stream commit clean",
             differing, LATENCY_CYCLES);
    $finish;
  end

  initial begin
    #5000000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
