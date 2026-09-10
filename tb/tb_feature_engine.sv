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
  int feed_seq = 1;
  int n_accepted = 0;
  int worst_imb_err = 0;

  feature_t last_feat;
  // Counting handoffs rather than counting cycles: with backpressure enabled
  // the output for an event lands an unknown number of cycles after it is
  // accepted, so feed() waits for the handoff itself.
  int out_seen = 0;
  always_ff @(posedge clk)
    if (rst_n && m_valid && m_ready) begin
      last_feat <= m_feat;
      out_seen  <= out_seen + 1;
    end

  // Randomized backpressure, enabled only for the stall phase. Driven on the
  // negedge: assigning m_ready at the posedge races the DUT and the monitor,
  // which both sample it on that edge.
  bit          bp_enable = 1'b0;
  int          stall_cycles = 0;
  int unsigned bp_rng = 32'h5EED_BEEF;
  function automatic int unsigned xorshift32(ref int unsigned state);
    state = state ^ (state << 13);
    state = state ^ (state >> 17);
    state = state ^ (state << 5);
    return state;
  endfunction
  initial begin
    forever begin
      @(negedge clk);
      if (bp_enable && (xorshift32(bp_rng) % 3 == 0)) begin
        m_ready = 1'b0;
        repeat (1 + xorshift32(bp_rng) % 5) begin
          @(negedge clk);
          stall_cycles++;
        end
        m_ready = 1'b1;
      end
    end
  end

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
    int mark;
    mark = out_seen;
    @(negedge clk);
    s_event        = '0;
    s_event.symbol = sym;
    // Distinct per event: seq is the transaction tag the bound
    // handshake_checker compares. Leaving it at zero made every tag identical
    // and a_fixed_latency's tag comparison vacuous here -- an inserted
    // payload register went undetected in this testbench while
    // tb_book_features caught it immediately.
    s_event.seq    = SEQ_W'(feed_seq);
    feed_seq++;
    s_err          = '0;
    s_book         = '0;
    s_book.bid_valid = bv; s_book.bid_price = bp; s_book.bid_qty = bq;
    s_book.ask_valid = av; s_book.ask_price = ap; s_book.ask_qty = aq;
    s_book_stale   = stale;
    s_valid        = 1'b1;
    #1;
    while (!s_ready) begin @(posedge clk); @(negedge clk); #1; end
    @(posedge clk);                 // accepted on this edge
    n_accepted++;
    @(negedge clk);
    s_valid = 1'b0;
    wait (out_seen == mark + 1);    // this event's output has been handed off
    @(negedge clk);
  endtask

  // Stream a book without dropping s_valid. feed() keeps at most one event in
  // the engine at a time, so v1 and v2 were never both set when m_ready fell
  // -- which is the only configuration in which the two-stage `advance`
  // control does anything. push() is what puts an event in stage 1 while
  // stage 2 is stalled.
  task automatic push(logic [SYMBOL_W-1:0] sym,
                      logic bv, logic [PRICE_W-1:0] bp, logic [QTY_W-1:0] bq,
                      logic av, logic [PRICE_W-1:0] ap, logic [QTY_W-1:0] aq,
                      logic stale = 1'b0);
    @(negedge clk);
    s_event        = '0;
    s_event.symbol = sym;
    // Distinct per event: seq is the transaction tag the bound
    // handshake_checker compares. Leaving it at zero made every tag identical
    // and a_fixed_latency's tag comparison vacuous here -- an inserted
    // payload register went undetected in this testbench while
    // tb_book_features caught it immediately.
    s_event.seq    = SEQ_W'(feed_seq);
    feed_seq++;
    s_err          = '0;
    s_book         = '0;
    s_book.bid_valid = bv; s_book.bid_price = bp; s_book.bid_qty = bq;
    s_book.ask_valid = av; s_book.ask_price = ap; s_book.ask_qty = aq;
    s_book_stale   = stale;
    s_valid        = 1'b1;
    #1;
    while (!s_ready) begin @(posedge clk); @(negedge clk); #1; end
    @(posedge clk);                 // accepted, valid stays high
    n_accepted++;
  endtask

  task automatic drain();
    @(negedge clk);
    s_valid = 1'b0;
    wait (out_seen == n_accepted);
    @(negedge clk);
  endtask

  task automatic do_reset();
    @(negedge clk); rst_n = 1'b0;
    @(posedge clk); @(negedge clk); rst_n = 1'b1;
    @(posedge clk); @(negedge clk);
    n_accepted = out_seen;          // reset discards anything in flight
  endtask

  // Exact imbalance in Q1.14, by integer division. The DUT approximates this.
  function automatic int exact_imb(input int bq, input int aq);
    int num, den;
    num = bq - aq;
    den = bq + aq;
    if (den == 0) return 0;
    return (num * IMB_ONE) / den;
  endfunction

  // Streaming scoreboard for the back-to-back stall phase: momentum is checked
  // on EVERY handoff, not just on the last one, because the failure mode being
  // hunted (a history write that repeats while the pipe is stalled) shows up
  // on the event that was sitting in stage 1 when m_ready fell.
  bit                      stream_check = 1'b0;
  logic signed [MOM_W-1:0] exp_mom [$];
  int                      stream_seen = 0;
  always_ff @(posedge clk) begin
    logic signed [MOM_W-1:0] want;
    if (rst_n && stream_check && m_valid && m_ready) begin
      if (exp_mom.size() == 0) begin
        errors++;
        $error("FAIL: streamed output with no expectation left");
      end else begin
        want = exp_mom.pop_front();
        stream_seen++;
        if (m_feat.momentum !== want) begin
          errors++;
          $error("FAIL: streamed momentum #%0d got %0d want %0d",
                 stream_seen, m_feat.momentum, want);
        end
      end
    end
  end

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

    // --- momentum history must clear on reset, for a symbol that HAS one -
    // Every reset in this file used to be followed by a fresh symbol, so a
    // reset that left prev_mid/prev_valid alone would have gone unnoticed.
    do_reset();
    feed(4'h7, 1'b1, 16'd400, 16'd10, 1'b1, 16'd500, 16'd10);   // mid 450
    feed(4'h7, 1'b1, 16'd600, 16'd10, 1'b1, 16'd700, 16'd10);   // mid 650
    check("pre-reset momentum +200", last_feat.momentum === 17'sd200);
    do_reset();
    feed(4'h7, 1'b1, 16'd600, 16'd10, 1'b1, 16'd700, 16'd10);   // same mid 650
    check("reset clears momentum history for symbol 7",
          last_feat.momentum === '0);
    feed(4'h7, 1'b1, 16'd610, 16'd10, 1'b1, 16'd710, 16'd10);   // mid 660
    check("history rebuilt after reset -> +10", last_feat.momentum === 17'sd10);

    // --- momentum across an empty book ---------------------------------
    // An empty book carries no midprice, so it neither reports momentum nor
    // advances the history: the next real book is measured against the last
    // real book, not against the hole. Pinning that so it is a decision, not
    // an accident.
    do_reset();
    feed(4'h8, 1'b1, 16'd1000, 16'd10, 1'b1, 16'd1100, 16'd10);  // mid 1050
    feed(4'h8, 1'b0, 16'd0,    16'd0,  1'b1, 16'd1100, 16'd10);  // ask only
    check("empty book -> momentum 0",  last_feat.momentum === '0);
    check("empty book -> mid 0",       last_feat.mid === '0);
    feed(4'h8, 1'b1, 16'd1200, 16'd10, 1'b1, 16'd1300, 16'd10);  // mid 1250
    check("refill measures against the last real mid (+200)",
          last_feat.momentum === 17'sd200);
    // The same across a both-sides-valid-but-zero-size book, which is the
    // other way book_empty gets set.
    feed(4'h8, 1'b1, 16'd9000, 16'd0, 1'b1, 16'd9100, 16'd0);
    check("zero-size book -> empty",      last_feat.book_empty === 1'b1);
    check("zero-size book -> momentum 0", last_feat.momentum === '0);
    feed(4'h8, 1'b1, 16'd1200, 16'd10, 1'b1, 16'd1300, 16'd10);  // mid 1250
    check("zero-size book did not advance history",
          last_feat.momentum === '0);

    // --- extreme normalisation shifts: den 1 and den 2 ------------------
    // den == 1 needs a valid side resting zero size, which top_of_book
    // produces from an ADD with qty 0. sh reaches its maximum of 16 here and
    // the shift-back becomes zero, which is the one point where the
    // >>> (16 - sh) term degenerates.
    do_reset();
    check_imb(1, 0, "den1-bid");
    check("den 1 all bid -> not empty", last_feat.book_empty === 1'b0);
    check_imb(0, 1, "den1-ask");
    check_imb(2, 0, "den2-bid");
    check_imb(1, 1, "den2-balanced");
    check("den 2 balanced -> imb 0", last_feat.imbalance === '0);
    check_imb(0, 2, "den2-ask");
    check_imb(2, 1, "den3-skew");
    check_imb(1, 2, "den3-skew-neg");

    // --- spread and midprice at full scale ------------------------------
    // SPREAD_W carries one bit more than PRICE_W precisely so these do not
    // wrap; a 16-bit spread would report +1 and -1 here.
    do_reset();
    feed(4'h9, 1'b1, 16'd0, 16'd10, 1'b1, 16'hFFFF, 16'd10);
    check("full-scale spread +65535", last_feat.spread === 17'sd65535);
    check("full-scale mid 32767",     last_feat.mid === 16'd32767);
    feed(4'h9, 1'b1, 16'hFFFF, 16'd10, 1'b1, 16'd0, 16'd10);
    check("full-scale crossed spread -65535", last_feat.spread === -17'sd65535);
    check("full-scale crossed mid 32767",     last_feat.mid === 16'd32767);
    check("full-scale momentum 0 (mid unchanged)", last_feat.momentum === '0);
    feed(4'h9, 1'b1, 16'd0, 16'd10, 1'b1, 16'd2, 16'd10);   // mid 1
    check("momentum spans full scale (-32766)", last_feat.momentum === -17'sd32766);
    feed(4'h9, 1'b1, 16'hFFFE, 16'd10, 1'b1, 16'hFFFF, 16'd10);  // mid 65534
    check("momentum spans full scale (+65533)", last_feat.momentum === 17'sd65533);

    // --- the same vectors again, under randomized backpressure ----------
    // Until this phase m_ready was tied high for the whole run, which made
    // every stall property bound into feature_engine vacuous and meant the
    // two-register `advance` control was never exercised at a stall boundary.
    do_reset();
    bp_enable = 1'b1;
    feed(4'hA, 1'b1, 16'd1000, 16'd10, 1'b1, 16'd1010, 16'd30);
    check("stalled: spread", last_feat.spread === 17'sd10);
    check("stalled: mid",    last_feat.mid === 16'd1005);
    check("stalled: first momentum 0", last_feat.momentum === '0);
    feed(4'hA, 1'b1, 16'd1020, 16'd10, 1'b1, 16'd1030, 16'd30);
    // A history that advanced twice for one event would read +20 here.
    check("stalled: momentum +20 exactly once", last_feat.momentum === 17'sd20);
    feed(4'hA, 1'b1, 16'd1020, 16'd10, 1'b1, 16'd1030, 16'd30);
    check("stalled: repeat of the same book -> momentum 0",
          last_feat.momentum === '0);
    feed(4'hA, 1'b1, 16'd1040, 16'd10, 1'b1, 16'd1050, 16'd30);
    check("stalled: momentum +20 again", last_feat.momentum === 17'sd20);
    // A stale book under stall must still not advance the history.
    feed(4'hA, 1'b1, 16'd2000, 16'd10, 1'b1, 16'd2010, 16'd30, 1'b1);
    feed(4'hA, 1'b1, 16'd1060, 16'd10, 1'b1, 16'd1070, 16'd30);
    check("stalled: stale book left history at 1045 -> +20",
          last_feat.momentum === 17'sd20);
    for (int i = 0; i < 24; i++)
      check_imb((i * 7) + 1, (i * 13) % 97, "stalled-sweep");
    // --- back-to-back traffic while the output stalls -------------------
    // The one configuration the rest of this file cannot reach: an event in
    // stage 1 while stage 2 is held. A history write that is not gated by
    // `advance` repeats every stalled cycle, and because it writes the same
    // midprice the corruption is invisible in prev_mid -- it shows up as the
    // stage-2 momentum reading zero, because the history has already caught
    // up with the event still being measured.
    do_reset();
    exp_mom.delete();
    stream_seen  = 0;
    stream_check = 1'b1;
    bp_enable    = 1'b1;
    // Two symbols interleaved, so the symbol in stage 1 is never the symbol on
    // the input port. A history lookup indexed off the wrong pipeline stage
    // reads the other symbol's midprice and only shows up here.
    begin
      logic [PRICE_W-1:0] bidp;
      for (int i = 0; i < 40; i++) begin
        if (i < 2)             exp_mom.push_back('0);           // first of each
        else if (i[0] == 1'b0) exp_mom.push_back(17'sd50);      // symbol B step
        else                   exp_mom.push_back(17'sd14);      // symbol C step
      end
      for (int i = 0; i < 40; i++) begin
        if (i[0] == 1'b0) begin
          bidp = PRICE_W'(1000 + (i / 2) * 50);
          push(4'hB, 1'b1, bidp, 16'd10, 1'b1, bidp + 16'd10, 16'd30);
        end else begin
          bidp = PRICE_W'(20000 + (i / 2) * 14);
          push(4'hC, 1'b1, bidp, 16'd40, 1'b1, bidp + 16'd20, 16'd5);
        end
      end
      drain();
    end
    if (stream_seen != 40) begin
      errors++;
      $error("FAIL: streamed phase scored %0d of 40 handoffs", stream_seen);
    end
    if (exp_mom.size() != 0) begin
      errors++;
      $error("FAIL: %0d streamed expectations never matched an output",
             exp_mom.size());
    end
    stream_check = 1'b0;

    bp_enable = 1'b0;
    @(negedge clk);
    m_ready = 1'b1;
    if (stall_cycles == 0) begin
      errors++;
      $error("FAIL: backpressure never asserted -- the stall properties were vacuous this run");
    end
    $display("INFO: backpressure phase stalled for %0d cycles", stall_cycles);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_feature_engine (worst imbalance error %0d/%0d, %0d stall cycles)",
             worst_imb_err, IMB_ONE, stall_cycles);
    $finish;
  end

  initial begin
    #2000000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
