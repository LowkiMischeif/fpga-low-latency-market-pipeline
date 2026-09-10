// Directed tests for risk_gate.
//
// One case matters more than the rest: spec 5.6 requires the spread guard to
// be qualified by !book_empty. An empty book reports spread == 0 under the
// feature gating rule, which is the TIGHTEST spread representable, so an
// unqualified "reject if spread > max" test passes exactly when there is no
// book to trade against. That vector is at "spread guard".
module tb_risk_gate;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  market_event_t s_event, m_event;
  event_err_t    s_err, m_err;
  feature_t      s_feat, m_feat;
  decision_e     s_decision;
  logic signed [SCORE_W-1:0] s_score;
  logic [QTY_W-1:0]          s_order_qty;
  logic          s_valid, s_ready, m_valid, m_ready;
  risk_cfg_t     cfg;
  decision_t     m_decision;

  risk_gate dut (.*);

  int errors = 0;
  int feed_seq = 1;

  decision_t last_d;
  always_ff @(posedge clk)
    if (rst_n && m_valid && m_ready) last_d <= m_decision;

  task automatic check(string name, logic cond);
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  function automatic risk_cfg_t mk_cfg(int mlong, int mshort, int mqty,
                                       int mspread, bit kill);
    risk_cfg_t c;
    c.max_long      = (POS_W-1)'(mlong);
    c.max_short     = (POS_W-1)'(mshort);
    c.max_order_qty = QTY_W'(mqty);
    c.max_spread    = SPREAD_W'(mspread);
    c.kill          = kill;
    return c;
  endfunction

  task automatic feed(decision_e d, int qty, int spread, bit empty = 1'b0,
                      event_err_t err = '0);
    @(negedge clk);
    while (!s_ready) @(negedge clk);
    s_event           = '0;
    s_event.seq       = SEQ_W'(feed_seq); feed_seq++;
    s_err             = err;
    s_feat            = '0;
    s_feat.spread     = SPREAD_W'(spread);
    s_feat.book_empty = empty;
    s_decision        = d;
    s_score           = '0;
    s_order_qty       = QTY_W'(qty);
    s_valid           = 1'b1;
    @(posedge clk);
    @(negedge clk);
    s_valid = 1'b0;
    repeat (LAT_RISK + 1) @(posedge clk);
    @(negedge clk);
  endtask

  task automatic do_reset();
    @(negedge clk); rst_n = 1'b0;
    @(posedge clk); @(negedge clk); rst_n = 1'b1;
    @(posedge clk); @(negedge clk);
  endtask

  initial begin
    m_ready = 1'b1;
    s_valid = 1'b0;
    s_event = '0; s_err = '0; s_feat = '0;
    s_decision = DEC_HOLD; s_score = '0; s_order_qty = '0;
    cfg = mk_cfg(1000, 1000, 100, 500, 1'b0);
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // --- a clean BUY passes and moves the position ----------------------
    do_reset();
    feed(DEC_BUY, 10, 100);
    check("clean BUY passes",     last_d.decision === DEC_BUY);
    check("clean BUY no reason",  last_d.reason   === RSN_NONE);
    check("position after BUY",   last_d.position === POS_W'(10));
    feed(DEC_BUY, 15, 100);
    check("position accumulates", last_d.position === POS_W'(25));

    // --- a SELL moves it back, and through zero -------------------------
    feed(DEC_SELL, 40, 100);
    check("clean SELL passes",  last_d.decision === DEC_SELL);
    check("position goes short", last_d.position === -POS_W'(15));

    // --- HOLD never moves the position ----------------------------------
    feed(DEC_HOLD, 99, 100);
    check("HOLD passes",           last_d.decision === DEC_HOLD);
    check("HOLD leaves position",  last_d.position === -POS_W'(15));
    check("genuine HOLD has no reason", last_d.reason === RSN_NONE);

    // --- max long ---------------------------------------------------------
    do_reset();
    cfg = mk_cfg(50, 50, 100, 500, 1'b0);
    feed(DEC_BUY, 50, 100);
    check("BUY to exactly the limit passes", last_d.decision === DEC_BUY);
    check("at limit position", last_d.position === POS_W'(50));
    feed(DEC_BUY, 1, 100);
    check("BUY past max long rejected", last_d.decision === DEC_HOLD);
    check("max long reason",            last_d.reason === RSN_MAX_LONG);
    check("rejected BUY does not move position", last_d.position === POS_W'(50));
    // A SELL is still allowed when long at the limit.
    feed(DEC_SELL, 10, 100);
    check("SELL allowed while at max long", last_d.decision === DEC_SELL);

    // --- max short --------------------------------------------------------
    do_reset();
    cfg = mk_cfg(50, 50, 100, 500, 1'b0);
    feed(DEC_SELL, 50, 100);
    check("SELL to exactly the limit passes", last_d.decision === DEC_SELL);
    feed(DEC_SELL, 1, 100);
    check("SELL past max short rejected", last_d.decision === DEC_HOLD);
    check("max short reason",             last_d.reason === RSN_MAX_SHORT);

    // --- signed limit comparisons -----------------------------------------
    // The bug this pins: written with an inline unsigned right-hand side, SV
    // evaluates the WHOLE comparison unsigned. Comparing a positive prospective
    // position against a negative short limit then reads 10 < 2**24-50 as true
    // and rejects a perfectly legal SELL. Two negatives compare correctly even
    // unsigned, which is why the ordinary vectors above do not catch it -- it
    // takes a position on the opposite side of zero from the limit.
    do_reset();
    cfg = mk_cfg(1000, 50, 1000, 500, 1'b0);
    feed(DEC_BUY, 60, 100);
    check("long 60 established", last_d.position === POS_W'(60));
    feed(DEC_SELL, 50, 100);
    check("SELL leaving a POSITIVE position is not a short breach",
          last_d.decision === DEC_SELL);
    check("no spurious MAX_SHORT", last_d.reason === RSN_NONE);
    check("position now +10", last_d.position === POS_W'(10));

    // Mirror: a BUY that leaves the position NEGATIVE is not a long breach.
    do_reset();
    cfg = mk_cfg(50, 1000, 1000, 500, 1'b0);
    feed(DEC_SELL, 60, 100);
    check("short 60 established", last_d.position === -POS_W'(60));
    feed(DEC_BUY, 50, 100);
    check("BUY leaving a NEGATIVE position is not a long breach",
          last_d.decision === DEC_BUY);
    check("no spurious MAX_LONG", last_d.reason === RSN_NONE);
    check("position now -10", last_d.position === -POS_W'(10));

    // --- max order quantity ----------------------------------------------
    do_reset();
    cfg = mk_cfg(100000, 100000, 20, 500, 1'b0);
    feed(DEC_BUY, 20, 100);
    check("qty at the limit passes", last_d.decision === DEC_BUY);
    feed(DEC_BUY, 21, 100);
    check("qty past the limit rejected", last_d.decision === DEC_HOLD);
    check("max qty reason",              last_d.reason === RSN_MAX_QTY);

    // --- spread guard, and the empty-book qualification -------------------
    do_reset();
    cfg = mk_cfg(100000, 100000, 100, 500, 1'b0);
    feed(DEC_BUY, 10, 500);
    check("spread at the limit passes", last_d.decision === DEC_BUY);
    feed(DEC_BUY, 10, 501);
    check("spread past the limit rejected", last_d.decision === DEC_HOLD);
    check("spread reason", last_d.reason === RSN_SPREAD);

    // THE case. An empty book reports spread == 0, the tightest spread
    // representable, so an unqualified guard waves it straight through.
    feed(DEC_BUY, 10, 0, 1'b1);
    check("empty book is rejected, not passed", last_d.decision === DEC_HOLD);
    check("empty book reason is BOOK_EMPTY, not NONE",
          last_d.reason === RSN_BOOK_EMPTY);
    check("empty book does not move position", last_d.position === POS_W'(10));

    // A crossed book has a NEGATIVE spread. It is tighter than any positive
    // limit, so the guard must not reject it on width -- but it is real.
    feed(DEC_BUY, 10, -50);
    check("crossed book is not a spread rejection", last_d.decision === DEC_BUY);

    // --- upstream flags ----------------------------------------------------
    do_reset();
    cfg = mk_cfg(100000, 100000, 100, 500, 1'b0);
    begin
      event_err_t e;
      e = '0; e.gap = 1'b1;
      feed(DEC_BUY, 10, 100, 1'b0, e);
      check("gap rejected",        last_d.decision === DEC_HOLD);
      check("gap reason",          last_d.reason === RSN_SEQUENCE);
      e = '0; e.stale = 1'b1;
      feed(DEC_BUY, 10, 100, 1'b0, e);
      check("stale rejected",      last_d.decision === DEC_HOLD);
      check("stale reason",        last_d.reason === RSN_SEQUENCE);
      e = '0; e.bad_type = 1'b1;
      feed(DEC_BUY, 10, 100, 1'b0, e);
      check("malformed rejected",  last_d.decision === DEC_HOLD);
      check("malformed reason",    last_d.reason === RSN_MALFORMED);
      e = '0; e.bad_side = 1'b1;
      feed(DEC_BUY, 10, 100, 1'b0, e);
      check("bad_side rejected",   last_d.reason === RSN_MALFORMED);
      e = '0; e.bad_rsv = 1'b1;
      feed(DEC_BUY, 10, 100, 1'b0, e);
      check("bad_rsv rejected",    last_d.reason === RSN_MALFORMED);
    end

    // --- kill switch beats everything --------------------------------------
    do_reset();
    cfg = mk_cfg(100000, 100000, 100, 500, 1'b1);
    feed(DEC_BUY, 10, 100);
    check("kill rejects a clean BUY", last_d.decision === DEC_HOLD);
    check("kill reason",              last_d.reason === RSN_KILL);
    check("kill freezes position",    last_d.position === POS_W'(0));
    cfg = mk_cfg(100000, 100000, 100, 500, 1'b0);
    feed(DEC_BUY, 10, 100);
    check("clearing kill resumes trading", last_d.decision === DEC_BUY);

    // --- reason precedence: kill outranks a limit breach -------------------
    do_reset();
    cfg = mk_cfg(0, 0, 1, 0, 1'b1);
    feed(DEC_BUY, 9999, 9999, 1'b1);
    check("kill outranks every other reason", last_d.reason === RSN_KILL);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_risk_gate");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
