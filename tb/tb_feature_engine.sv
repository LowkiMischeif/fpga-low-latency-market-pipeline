// Directed tests for feature_engine.
//
// Book states are driven directly rather than through top_of_book: this stage
// is a pure function of the book plus per-symbol midprice history, and driving
// the book lets the corner cases (crossed, empty, zero-size) be reached
// without constructing an event sequence that produces them.
//
// The imbalance accuracy check sweeps the approximation against exact integer
// division, so the error bound quoted in the spec is measured here rather than
// asserted.
module tb_feature_engine;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  market_event_t s_event, m_event;
  event_err_t    s_err, m_err;
  book_t         s_book;
  logic          s_book_stale;
  logic          s_valid, s_ready, m_valid, m_ready;
  feature_t      m_feat;

  feature_engine dut (.*);

  int errors = 0;
  int worst_imb_err = 0;

  feature_t last_feat;
  always_ff @(posedge clk)
    if (rst_n && m_valid && m_ready) last_feat <= m_feat;

  task automatic check(string name, logic cond);
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  task automatic feed(logic [SYMBOL_W-1:0] sym,
                      logic bv, logic [PRICE_W-1:0] bp, logic [QTY_W-1:0] bq,
                      logic av, logic [PRICE_W-1:0] ap, logic [QTY_W-1:0] aq,
                      logic stale = 1'b0);
    @(negedge clk);
    while (!s_ready) @(negedge clk);
    s_event        = '0;
    s_event.symbol = sym;
    s_err          = '0;
    s_book         = '0;
    s_book.bid_valid = bv; s_book.bid_price = bp; s_book.bid_qty = bq;
    s_book.ask_valid = av; s_book.ask_price = ap; s_book.ask_qty = aq;
    s_book_stale   = stale;
    s_valid        = 1'b1;
    @(posedge clk);
    @(negedge clk);
    s_valid = 1'b0;
    // LAT_FEATURE registers plus one for the capture monitor.
    repeat (LAT_FEATURE + 1) @(posedge clk);
    @(negedge clk);
  endtask

  task automatic do_reset();
    @(negedge clk); rst_n = 1'b0;
    @(posedge clk); @(negedge clk); rst_n = 1'b1;
    @(posedge clk); @(negedge clk);
  endtask

  // Exact imbalance in Q1.14, by integer division. The DUT approximates this.
  function automatic int exact_imb(input int bq, input int aq);
    int num, den;
    num = bq - aq;
    den = bq + aq;
    if (den == 0) return 0;
    return (num * IMB_ONE) / den;
  endfunction

  task automatic check_imb(int bq, int aq, string tag);
    int want, got, err;
    feed(4'h0, 1'b1, 16'd100, PRICE_W'(bq), 1'b1, 16'd200, PRICE_W'(aq));
    want = exact_imb(bq, aq);
    got  = int'(last_feat.imbalance);
    err  = (got > want) ? (got - want) : (want - got);
    if (err > worst_imb_err) worst_imb_err = err;
    if (err > 40) begin
      errors++;
      $error("FAIL: %s imbalance bq=%0d aq=%0d want %0d got %0d (err %0d)",
             tag, bq, aq, want, got, err);
    end
    // Imbalance is mathematically bounded to [-1, +1]. The reciprocal
    // approximation can overshoot: rounding to a bucket midpoint makes recip
    // too large whenever the low index bits exceed 128, and at bq=65535 aq=0
    // the raw product reaches 16397. The clamp is what keeps a value greater
    // than 1.0 out of the policy layer, so every sweep point asserts it.
    if (got > IMB_ONE || got < -IMB_ONE) begin
      errors++;
      $error("FAIL: %s imbalance %0d outside +/-%0d (bq=%0d aq=%0d)",
             tag, got, IMB_ONE, bq, aq);
    end
  endtask

  initial begin
    m_ready      = 1'b1;
    s_valid      = 1'b0;
    s_event      = '0;
    s_err        = '0;
    s_book       = '0;
    s_book_stale = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // --- spread and midprice, both sides present ----------------------
    do_reset();
    feed(4'h0, 1'b1, 16'd1000, 16'd10, 1'b1, 16'd1010, 16'd10);
    check("spread = ask - bid", last_feat.spread === 17'sd10);
    check("mid = (bid+ask)/2",  last_feat.mid    === 16'd1005);
    check("book not empty",     last_feat.book_empty === 1'b0);

    // --- a crossed book gives a NEGATIVE spread, not a wrap ------------
    feed(4'h0, 1'b1, 16'd1020, 16'd10, 1'b1, 16'd1000, 16'd10);
    check("crossed book spread negative", last_feat.spread === -17'sd20);
    check("crossed book still not empty", last_feat.book_empty === 1'b0);

    // --- a missing side is empty, and yields neutral zeros -------------
    feed(4'h0, 1'b1, 16'd1000, 16'd10, 1'b0, 16'd0, 16'd0);
    check("no ask -> empty",     last_feat.book_empty === 1'b1);
    check("no ask -> spread 0",  last_feat.spread    === '0);
    check("no ask -> imb 0",     last_feat.imbalance === '0);
    feed(4'h0, 1'b0, 16'd0, 16'd0, 1'b1, 16'd1000, 16'd10);
    check("no bid -> empty", last_feat.book_empty === 1'b1);

    // --- both sides valid but zero size: divide-by-zero must not X -----
    feed(4'h0, 1'b1, 16'd1000, 16'd0, 1'b1, 16'd1010, 16'd0);
    check("zero total size -> empty", last_feat.book_empty === 1'b1);
    check("zero total size -> imb 0", last_feat.imbalance === '0);
    check("zero total size -> imb not X", !$isunknown(last_feat.imbalance));

    // --- imbalance endpoints and symmetry ------------------------------
    do_reset();
    feed(4'h0, 1'b1, 16'd100, 16'd50, 1'b1, 16'd200, 16'd50);
    check("balanced book -> imb 0", last_feat.imbalance === '0);

    feed(4'h0, 1'b1, 16'd100, 16'd50, 1'b1, 16'd200, 16'd0);
    check("all bid -> imb near +1",
          last_feat.imbalance > IMB_W'(IMB_ONE - 40) &&
          last_feat.imbalance <= IMB_W'(IMB_ONE));
    feed(4'h0, 1'b1, 16'd100, 16'd0, 1'b1, 16'd200, 16'd50);
    check("all ask -> imb near -1",
          last_feat.imbalance < -IMB_W'(IMB_ONE - 40) &&
          last_feat.imbalance >= -IMB_W'(IMB_ONE));

    // --- saturation: the approximation overshoots +/-1.0 here ----------
    // bq=65535 aq=0 normalises to a bucket whose low bits are 254, so the
    // reciprocal is rounded up and the raw product is 16397. Without the
    // clamp the policy layer would see an imbalance above 1.0.
    feed(4'h0, 1'b1, 16'd100, 16'hFFFF, 1'b1, 16'd200, 16'd0);
    check("saturating high clamps to +1", last_feat.imbalance === IMB_W'(IMB_ONE));
    feed(4'h0, 1'b1, 16'd100, 16'd0, 1'b1, 16'd200, 16'hFFFF);
    check("saturating low clamps to -1", last_feat.imbalance === -IMB_W'(IMB_ONE));

    // --- imbalance accuracy against exact integer division -------------
    check_imb(65535, 0, "sat-bid");
    check_imb(0, 65535, "sat-ask");
    check_imb(3, 1, "small");
    check_imb(1, 3, "small-neg");
    check_imb(1, 1, "unit");
    check_imb(65535, 1, "max-bid");
    check_imb(1, 65535, "max-ask");
    check_imb(65535, 65535, "max-both");
    check_imb(32768, 32767, "near-half");
    check_imb(1000, 3, "skewed");
    check_imb(7, 9, "odd");
    for (int i = 1; i < 400; i++) begin
      check_imb(i, 400 - i, "sweep-400");
    end
    for (int k = 0; k < 64; k++) begin
      check_imb((k * 1031) % 65535 + 1, (k * 617) % 65535 + 1, "sweep-scatter");
    end
    $display("INFO: worst imbalance error %0d of %0d full scale (%0d.%02d%%)",
             worst_imb_err, IMB_ONE,
             (worst_imb_err * 100) / IMB_ONE,
             ((worst_imb_err * 10000) / IMB_ONE) % 100);

    // --- momentum ------------------------------------------------------
    do_reset();
    // First observation of a symbol has no history, so momentum is 0.
    feed(4'h3, 1'b1, 16'd1000, 16'd10, 1'b1, 16'd1010, 16'd10);
    check("first mid -> momentum 0", last_feat.momentum === '0);
    // mid moves 1005 -> 1015
    feed(4'h3, 1'b1, 16'd1010, 16'd10, 1'b1, 16'd1020, 16'd10);
    check("momentum = +10", last_feat.momentum === 17'sd10);
    // and back down
    feed(4'h3, 1'b1, 16'd1000, 16'd10, 1'b1, 16'd1010, 16'd10);
    check("momentum = -10", last_feat.momentum === -17'sd10);

    // --- momentum history is per symbol --------------------------------
    do_reset();
    feed(4'h4, 1'b1, 16'd100, 16'd10, 1'b1, 16'd200, 16'd10);   // mid 150
    feed(4'h5, 1'b1, 16'd900, 16'd10, 1'b1, 16'd1000, 16'd10);  // mid 950
    check("symbol 5 first -> momentum 0", last_feat.momentum === '0);
    feed(4'h4, 1'b1, 16'd120, 16'd10, 1'b1, 16'd220, 16'd10);   // mid 170
    check("symbol 4 momentum unaffected by symbol 5",
          last_feat.momentum === 17'sd20);

    // --- a stale book does not advance momentum history ----------------
    do_reset();
    feed(4'h6, 1'b1, 16'd500, 16'd10, 1'b1, 16'd600, 16'd10);   // mid 550
    feed(4'h6, 1'b1, 16'd700, 16'd10, 1'b1, 16'd800, 16'd10, 1'b1); // stale
    feed(4'h6, 1'b1, 16'd520, 16'd10, 1'b1, 16'd620, 16'd10);   // mid 570
    check("stale book left history at 550 -> momentum +20",
          last_feat.momentum === 17'sd20);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_feature_engine (worst imbalance error %0d/%0d)",
             worst_imb_err, IMB_ONE);
    $finish;
  end

  initial begin
    #2000000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
