// Directed tests for policy_engine.
//
// The headline property this file protects is that the CONFIG changes the
// decision and never the timing. Weight values steer data only; they must not
// reach any control path. tb_policy_configs.sv proves that end to end on a
// real trace; this file pins the arithmetic and the per-event config capture.
module tb_policy_engine;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  market_event_t s_event, m_event;
  event_err_t    s_err, m_err;
  feature_t      s_feat, m_feat;
  logic          s_valid, s_ready, m_valid, m_ready;
  policy_cfg_t   cfg;
  risk_cfg_t     risk_cfg_in;
  risk_cfg_t     m_risk_cfg;
  decision_e     m_decision;
  logic signed [SCORE_W-1:0] m_score;
  logic [QTY_W-1:0]          m_order_qty;

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

  // Outputs recorded per sequence number. last_* only holds the most recent
  // handoff, which cannot check two events that were in flight together.
  decision_e                 mon_dec   [int];
  logic signed [SCORE_W-1:0] mon_score [int];
  logic [QTY_W-1:0]          mon_qty   [int];
  risk_cfg_t                 mon_risk  [int];
  // Blocking assignment on purpose: xsim does not support nonblocking
  // assignment to associative arrays ("not supported yet for simulation"), and
  // these arrays are read only from the initial block, at negedges, so there is
  // no same-edge race for a blocking write to create.
  always @(posedge clk)
    if (rst_n && m_valid && m_ready) begin
      mon_dec[int'(m_event.seq)]   = m_decision;
      mon_score[int'(m_event.seq)] = m_score;
      mon_qty[int'(m_event.seq)]   = m_order_qty;
      mon_risk[int'(m_event.seq)]  = m_risk_cfg;
    end

  task automatic wait_out(int seq);
    int guard;
    guard = 0;
    @(negedge clk);
    while (mon_dec.exists(seq) == 0) begin
      @(negedge clk);
      guard++;
      if (guard > 100) $fatal(1, "FAIL: event seq %0d never left policy_engine", seq);
    end
  endtask

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
    risk_cfg_in = '0;
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

    // --- the score cannot reach the SCORE_W rail, and that is on purpose --
    //
    // Worst case: three products of |w| <= 2**15 and |feature| <= 2**16, so
    // |acc| <= 3 * 2**31, and >>> W_FRAC_W leaves |scaled| <= 3 * 2**19, about
    // 1.6e6. Adding |w0| <= 2**15 cannot approach 2**31. The saturating
    // accumulate is therefore DEFENSIVE, not load-bearing at these widths.
    //
    // That is worth pinning rather than leaving implicit: it is the reason the
    // "saturation clamp removed" mutant cannot be killed, and it stops being
    // true the moment someone widens a weight or narrows SCORE_W. This vector
    // fails if the achievable range ever grows past a tenth of the rail.
    cfg = mk_cfg(32767, 32767, 32767, 32767, 1000000, -1000000, 7);
    feed(65535, 0, 16384, 65535);
    check("extreme positive score is well inside the rail",
          last_score > 0 && last_score < (SCORE_W'(1) <<< (SCORE_W-4)));
    cfg = mk_cfg(-32768, -32768, -32768, -32768, 1000000, -1000000, 7);
    feed(65535, 0, 16384, 65535);
    check("extreme negative score is well inside the rail",
          last_score < 0 && last_score > -(SCORE_W'(1) <<< (SCORE_W-4)));

    // --- the per-event configuration snapshot ----------------------------
    //
    // The atomicity claim for the whole config path rests here: policy_engine
    // captures EVERY config-derived value an event uses -- w0, both
    // thresholds, order_qty and the risk limits -- on the edge it accepts the
    // event, and nothing downstream reads the live config. A previous review
    // showed the end-to-end test could not see this: the two committed configs
    // share identical risk limits and order size, and its mid-stream pass
    // holds s_valid high so every edge accepts. Nine of ten "read the live
    // config in stage 2" mutants survived it.
    //
    // So change every field -- all of them different, kill switch included --
    // at the three timings that matter, and require the outputs to still
    // reflect the configuration the event was accepted under.
    begin
      policy_cfg_t cx, cy, cz;
      risk_cfg_t   rx, ry, rz;
      int          e1, e2;
      // Every decision-relevant field differs between X and Y, so reading any
      // one of them live flips an observable output.
      cx = mk_cfg( 150, 0, 0, 0,  100, -100,  7);   // score 150 -> BUY
      cy = mk_cfg(-150, 0, 0, 0,  200,  -50,  9);   // score -150 -> SELL
      cz = mk_cfg(  20, 0, 0, 0,   10,  -10, 11);   // score 20 -> BUY, qty 11
      rx = '0; rx.max_long = 123; rx.max_short = 456; rx.max_order_qty = 77;
      rx.max_spread = 321; rx.kill = 1'b0;
      ry = '0; ry.max_long = 999; ry.max_short = 888; ry.max_order_qty = 66;
      ry.max_spread = 555; ry.kill = 1'b1;
      rz = ry; rz.max_spread = 42;

      // (a) every field changes on the cycle after accept, no stall.
      @(negedge clk); while (!s_ready) @(negedge clk);
      cfg = cx; risk_cfg_in = rx;
      e1 = feed_seq; feed_seq++;
      s_event = '0; s_event.seq = SEQ_W'(e1); s_err = '0; s_feat = '0;
      s_valid = 1'b1;
      @(posedge clk);                          // accepted under X
      @(negedge clk);
      s_valid = 1'b0;
      cfg = cy; risk_cfg_in = ry;              // everything changes now
      wait_out(e1);
      check("snap(a) decision from X",  mon_dec[e1]   === DEC_BUY);
      check("snap(a) score from X",     mon_score[e1] === SCORE_W'(150));
      check("snap(a) order_qty from X", mon_qty[e1]   === QTY_W'(7));
      check("snap(a) risk limits from X", mon_risk[e1] === rx);

      // (b) a stall with the event already past the snapshot stage: config
      // changes cannot reach it any more. Kept as a regression vector; it is
      // (e) below that holds an event IN the snapshot stage.
      @(negedge clk);
      m_ready = 1'b0;
      cfg = cx; risk_cfg_in = rx;
      e1 = feed_seq; feed_seq++;
      s_event = '0; s_event.seq = SEQ_W'(e1); s_err = '0; s_feat = '0;
      s_valid = 1'b1;
      @(posedge clk);                          // accepted (pipe was empty)
      @(negedge clk);
      s_valid = 1'b0;
      cfg = cy; risk_cfg_in = ry;
      repeat (4) @(negedge clk);               // already in the OUTPUT register
      cfg = cz; risk_cfg_in = rz;
      repeat (3) @(negedge clk);
      m_ready = 1'b1;
      wait_out(e1);
      check("snap(b) decision from X after stall",  mon_dec[e1]   === DEC_BUY);
      check("snap(b) score from X after stall",     mon_score[e1] === SCORE_W'(150));
      check("snap(b) order_qty from X after stall", mon_qty[e1]   === QTY_W'(7));
      check("snap(b) risk limits from X after stall", mon_risk[e1] === rx);

      // (c) back to back: the config changes BETWEEN two accepts, so the
      // first event must come out under X and the second under Y.
      @(negedge clk);
      cfg = cx; risk_cfg_in = rx;
      e1 = feed_seq; feed_seq++;
      e2 = feed_seq; feed_seq++;
      s_event = '0; s_event.seq = SEQ_W'(e1); s_err = '0; s_feat = '0;
      s_valid = 1'b1;
      @(posedge clk);                          // e1 accepted under X
      @(negedge clk);
      cfg = cy; risk_cfg_in = ry;
      s_event.seq = SEQ_W'(e2);                // s_valid stays high
      @(posedge clk);                          // e2 accepted under Y
      @(negedge clk);
      s_valid = 1'b0;
      wait_out(e1);
      wait_out(e2);
      check("snap(c) first event decision from X",  mon_dec[e1]  === DEC_BUY);
      check("snap(c) first event qty from X",       mon_qty[e1]  === QTY_W'(7));
      check("snap(c) first event risk from X",      mon_risk[e1] === rx);
      check("snap(c) second event decision from Y", mon_dec[e2]  === DEC_SELL);
      check("snap(c) second event score from Y",    mon_score[e2] === -SCORE_W'(150));
      check("snap(c) second event qty from Y",      mon_qty[e2]  === QTY_W'(9));
      check("snap(c) second event risk from Y",     mon_risk[e2] === ry);
      // (d) theta_sell must be the DECIDING comparison. In (a)-(c) every
      // X-accepted event scores high enough that the BUY test wins first, so
      // theta_sell is never consulted when the live and captured values
      // differ -- the "theta_sell read live" mutant survived exactly that.
      // Score -150 under theta_sell = -100 is a SELL; the live value moves to
      // -200, under which the same score would be a HOLD.
      begin
        policy_cfg_t cs, cs_live;
        cs      = mk_cfg(-150, 0, 0, 0, 100, -100, 7);  // -150 < -100 -> SELL
        cs_live = mk_cfg(-150, 0, 0, 0, 100, -200, 7);  // -150 > -200 -> HOLD

        // right after accept
        @(negedge clk);
        cfg = cs;
        e1 = feed_seq; feed_seq++;
        s_event = '0; s_event.seq = SEQ_W'(e1); s_err = '0; s_feat = '0;
        s_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        s_valid = 1'b0;
        cfg = cs_live;
        wait_out(e1);
        check("snap(d) SELL decided by captured theta_sell", mon_dec[e1] === DEC_SELL);

        // and while stalled in stage 2
        @(negedge clk);
        m_ready = 1'b0;
        cfg = cs;
        e1 = feed_seq; feed_seq++;
        s_event = '0; s_event.seq = SEQ_W'(e1); s_err = '0; s_feat = '0;
        s_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        s_valid = 1'b0;
        cfg = cs_live;
        repeat (5) @(negedge clk);
        m_ready = 1'b1;
        wait_out(e1);
        check("snap(d) SELL survives a stall under a moved theta_sell",
              mon_dec[e1] === DEC_SELL);
      end

      // (e) THE stall that matters, with non-zero weights and features.
      //
      // Every earlier case used w_spread = w_imbalance = w_momentum = 0 and
      // zero features, so reading those three weights live was invisible, and
      // no case ever held an event in the snapshot stage while config changed.
      // Here m_ready is low and two events are fed: E1 moves to the output
      // register and E2 is left sitting in stage 1 with its snapshot captured.
      // Then every field changes. Both must still come out under X.
      begin
        policy_cfg_t wx, wy;
        risk_cfg_t   rwx, rwy;
        logic signed [SCORE_W-1:0] sx, sy;
        int ea, eb;
        wx = mk_cfg( 10,  4096,  2048,  1024,  100,  -100, 7);
        wy = mk_cfg(-10, -4096, -2048, -1024, 5000, -5000, 9);
        rwx = '0; rwx.max_long = 11; rwx.max_short = 22; rwx.max_order_qty = 33;
        rwx.max_spread = 44; rwx.kill = 1'b0;
        rwy = '0; rwy.max_long = 55; rwy.max_short = 66; rwy.max_order_qty = 77;
        rwy.max_spread = 88; rwy.kill = 1'b1;
        sx = ref_score(wx, 200, 800, 40);
        sy = ref_score(wy, 200, 800, 40);
        // Guard the vector itself: it must discriminate, or it proves nothing.
        if (sx === sy || !(sx > 100) || (sy > 5000) || (sy < -5000))
          $fatal(1, "FAIL: snap(e) vectors do not discriminate (sx=%0d sy=%0d)", sx, sy);

        // (e1) non-zero weights, config changes the cycle after accept.
        @(negedge clk); while (!s_ready) @(negedge clk);
        cfg = wx; risk_cfg_in = rwx;
        ea = feed_seq; feed_seq++;
        s_event = '0; s_event.seq = SEQ_W'(ea); s_err = '0;
        s_feat = '0; s_feat.spread = SPREAD_W'(200);
        s_feat.imbalance = IMB_W'(800); s_feat.momentum = MOM_W'(40);
        s_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        s_valid = 1'b0;
        cfg = wy; risk_cfg_in = rwy;
        wait_out(ea);
        check("snap(e1) score uses captured weights", mon_score[ea] === sx);
        check("snap(e1) decision from X",             mon_dec[ea]   === DEC_BUY);

        // (e2) full pipe: E1 in the output register, E2 in stage 1, stalled.
        @(negedge clk);
        m_ready = 1'b0;
        cfg = wx; risk_cfg_in = rwx;
        ea = feed_seq; feed_seq++;
        eb = feed_seq; feed_seq++;
        s_event = '0; s_event.seq = SEQ_W'(ea); s_err = '0;
        s_feat = '0; s_feat.spread = SPREAD_W'(200);
        s_feat.imbalance = IMB_W'(800); s_feat.momentum = MOM_W'(40);
        s_valid = 1'b1;
        @(posedge clk);                          // E1 accepted
        @(negedge clk);
        s_event.seq = SEQ_W'(eb);                // s_valid stays high
        @(posedge clk);                          // E1 -> output reg, E2 -> stage 1
        @(negedge clk);
        s_valid = 1'b0;
        check("snap(e2) pipe is really stalled", s_ready === 1'b0);
        cfg = wy; risk_cfg_in = rwy;             // every field changes, E2 parked
        repeat (5) @(negedge clk);
        m_ready = 1'b1;
        wait_out(ea);
        wait_out(eb);
        check("snap(e2) E1 score from X",              mon_score[ea] === sx);
        check("snap(e2) E2 held in stage 1: score from X", mon_score[eb] === sx);
        check("snap(e2) E2 decision from X",           mon_dec[eb]   === DEC_BUY);
        check("snap(e2) E2 order_qty from X",          mon_qty[eb]   === QTY_W'(7));
        check("snap(e2) E2 risk limits from X",        mon_risk[eb]  === rwx);
      end

      cfg = mk_cfg(0, 0, 0, 0, 1, -1, 10);
      risk_cfg_in = '0;
    end

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
