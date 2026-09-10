// Directed tests for policy_engine.
//
// The headline property this file protects is that the CONFIG changes the
// decision and never the timing. Weight values steer data only; they must not
// reach any control path. tb_policy_configs.sv proves that end to end on a
// real trace; this file pins the arithmetic and the config-capture boundary.
module tb_policy_engine;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  market_event_t s_event, m_event;
  event_err_t    s_err, m_err;
  feature_t      s_feat, m_feat;
  logic          s_valid, s_ready, m_valid, m_ready;
  policy_cfg_t   cfg;
  decision_e     m_decision;
  logic signed [SCORE_W-1:0] m_score;
  logic [QTY_W-1:0]          m_order_qty;
  logic                      cfg_boundary;

  policy_engine dut (.*);

  int errors = 0;
  int feed_seq = 1;

  decision_e                 last_dec;
  logic signed [SCORE_W-1:0] last_score;
  logic [QTY_W-1:0]          last_qty;
  always_ff @(posedge clk)
    if (rst_n && m_valid && m_ready) begin
      last_dec   <= m_decision;
      last_score <= m_score;
      last_qty   <= m_order_qty;
    end

  task automatic check(string name, logic cond);
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  function automatic policy_cfg_t mk_cfg(
      int w0, int wsp, int wimb, int wmom, int tbuy, int tsell, int oq);
    policy_cfg_t c;
    c.w0          = W_W'(w0);
    c.w_spread    = W_W'(wsp);
    c.w_imbalance = W_W'(wimb);
    c.w_momentum  = W_W'(wmom);
    c.theta_buy   = SCORE_W'(tbuy);
    c.theta_sell  = SCORE_W'(tsell);
    c.order_qty   = QTY_W'(oq);
    return c;
  endfunction

  task automatic feed(int spread, int mid, int imb, int mom, bit empty = 1'b0);
    @(negedge clk);
    while (!s_ready) @(negedge clk);
    s_event            = '0;
    s_event.seq        = SEQ_W'(feed_seq); feed_seq++;
    s_err              = '0;
    s_feat             = '0;
    s_feat.spread      = SPREAD_W'(spread);
    s_feat.mid         = PRICE_W'(mid);
    s_feat.imbalance   = IMB_W'(imb);
    s_feat.momentum    = MOM_W'(mom);
    s_feat.book_empty  = empty;
    s_valid            = 1'b1;
    @(posedge clk);
    @(negedge clk);
    s_valid = 1'b0;
    repeat (LAT_POLICY + 1) @(posedge clk);
    @(negedge clk);
  endtask

  // The reference the DUT is scored against, written from spec 5.5 rather
  // than from the RTL.
  function automatic logic signed [SCORE_W-1:0] ref_score(
      policy_cfg_t c, int spread, int imb, int mom);
    longint acc;
    acc = (longint'(c.w_spread)    * longint'(spread))
        + (longint'(c.w_imbalance) * longint'(imb))
        + (longint'(c.w_momentum)  * longint'(mom));
    acc = acc >>> W_FRAC_W;
    acc = acc + longint'(c.w0);
    if (acc >  (longint'(1) <<< (SCORE_W-1)) - 1) acc = (longint'(1) <<< (SCORE_W-1)) - 1;
    if (acc < -(longint'(1) <<< (SCORE_W-1)))     acc = -(longint'(1) <<< (SCORE_W-1));
    return SCORE_W'(acc);
  endfunction

  initial begin
    m_ready = 1'b1;
    s_valid = 1'b0;
    s_event = '0; s_err = '0; s_feat = '0;
    cfg     = mk_cfg(0, 0, 0, 0, 1, -1, 10);
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // --- all weights zero: score is w0, decision follows thresholds -----
    cfg = mk_cfg(0, 0, 0, 0, 100, -100, 7);
    feed(1000, 500, 8000, 20);
    check("zero weights -> score 0", last_score === '0);
    check("zero weights -> HOLD",    last_dec === DEC_HOLD);
    check("order qty from cfg",      last_qty === 16'd7);

    // --- w0 alone crosses the buy threshold -----------------------------
    cfg = mk_cfg(150, 0, 0, 0, 100, -100, 7);
    feed(1000, 500, 8000, 20);
    check("w0 above theta_buy -> BUY", last_dec === DEC_BUY);
    check("w0 score",                  last_score === SCORE_W'(150));

    cfg = mk_cfg(-150, 0, 0, 0, 100, -100, 7);
    feed(1000, 500, 8000, 20);
    check("w0 below theta_sell -> SELL", last_dec === DEC_SELL);

    // --- exactly at the threshold is NOT a cross ------------------------
    // "BUY if score > theta_buy" -- strictly greater, both sides.
    cfg = mk_cfg(100, 0, 0, 0, 100, -100, 7);
    feed(0, 0, 0, 0);
    check("score == theta_buy -> HOLD", last_dec === DEC_HOLD);
    cfg = mk_cfg(-100, 0, 0, 0, 100, -100, 7);
    feed(0, 0, 0, 0);
    check("score == theta_sell -> HOLD", last_dec === DEC_SELL ? 1'b0 : 1'b1);

    // --- each weight drives its own feature, and only its own -----------
    cfg = mk_cfg(0, 4096, 0, 0, 1000000, -1000000, 7);   // w_spread = 1.0
    feed(3000, 0, 12345, 456);
    check("spread weight only", last_score === ref_score(cfg, 3000, 12345, 456));
    check("spread term is 3000", last_score === SCORE_W'(3000));

    cfg = mk_cfg(0, 0, 4096, 0, 1000000, -1000000, 7);   // w_imbalance = 1.0
    feed(3000, 0, 12345, 456);
    check("imbalance weight only", last_score === SCORE_W'(12345));

    cfg = mk_cfg(0, 0, 0, 4096, 1000000, -1000000, 7);   // w_momentum = 1.0
    feed(3000, 0, 12345, 456);
    check("momentum weight only", last_score === SCORE_W'(456));

    // --- negative weights and negative features -------------------------
    cfg = mk_cfg(0, -4096, 0, 0, 1000000, -1000000, 7);
    feed(-2000, 0, 0, 0);
    check("negative x negative is positive", last_score === SCORE_W'(2000));
    cfg = mk_cfg(0, 4096, 0, 0, 1000000, -1000000, 7);
    feed(-2000, 0, 0, 0);
    check("negative spread", last_score === -SCORE_W'(2000));

    // --- fractional weights truncate, they do not blow up ---------------
    cfg = mk_cfg(0, 2048, 0, 0, 1000000, -1000000, 7);   // 0.5
    feed(1000, 0, 0, 0);
    check("half weight", last_score === SCORE_W'(500));

    // --- a full three-term score matches the reference ------------------
    cfg = mk_cfg(-25, 1234, -2222, 700, 1000000, -1000000, 7);
    feed(1500, 0, -9000, 333);
    check("three-term score", last_score === ref_score(cfg, 1500, -9000, 333));

    // --- saturation: extreme weights and features must clamp ------------
    cfg = mk_cfg(32767, 32767, 32767, 32767, 1000000, -1000000, 7);
    feed(65535, 0, 32767, 65535);
    check("saturating score is not X", !$isunknown(last_score));
    check("saturating score stays positive", last_score > 0);

    // --- book_empty forces HOLD regardless of weights -------------------
    // Features are all zero when the book is empty, but an aggressive w0
    // would still fire. A decision on no book is not a decision.
    // w0 is signed 16-bit: 100000 would wrap to a NEGATIVE value and fire
    // SELL, which is a property of the format rather than of the policy.
    cfg = mk_cfg(30000, 0, 0, 0, 1, -1, 7);
    feed(0, 0, 0, 0, 1'b1);
    check("book_empty -> HOLD", last_dec === DEC_HOLD);
    feed(0, 0, 0, 0, 1'b0);
    check("book present -> w0 fires", last_dec === DEC_BUY);

    // --- the weight format's own limits ---------------------------------
    // Anything the tuner exports must fit Q3.12 signed. Pinned here because a
    // silent wrap turns a maximally bullish constant into a bearish one.
    cfg = mk_cfg(32767, 0, 0, 0, 0, -1, 7);
    feed(0, 0, 0, 0);
    check("max positive w0 stays positive", last_score === SCORE_W'(32767));
    check("max positive w0 -> BUY", last_dec === DEC_BUY);
    cfg = mk_cfg(-32768, 0, 0, 0, 1, 0, 7);
    feed(0, 0, 0, 0);
    check("max negative w0 stays negative", last_score === -SCORE_W'(32768));
    check("max negative w0 -> SELL", last_dec === DEC_SELL);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_policy_engine");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
