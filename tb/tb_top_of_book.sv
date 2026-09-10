// Directed tests for top_of_book. Hand-written, independent of
// scripts/generate_events.py.
//
// Covers every row of the update table in the design spec, the trust gate,
// per-symbol independence, and the one case a sentinel-price implementation
// would get wrong: a real price of zero.
module tb_top_of_book;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  market_event_t s_event, m_event;
  event_err_t    s_err, m_err;
  logic          s_valid, s_ready, m_valid, m_ready;
  book_t         m_book;
  logic          m_book_stale;

  top_of_book dut (.*);

  int errors = 0;

  // Capture at the handshake edge: the output register reloads whenever
  // s_ready is high, so reading the ports after m_valid drops shows the
  // result of whatever is still sitting on the input.
  book_t last_book;
  logic  last_stale;
  // Counting handoffs rather than counting cycles: with backpressure enabled
  // the output for an event lands an unknown number of cycles after it is
  // accepted, so feed() waits for the handoff itself.
  int    out_seen = 0;
  always_ff @(posedge clk) begin
    if (rst_n && m_valid && m_ready) begin
      last_book  <= m_book;
      last_stale <= m_book_stale;
      out_seen   <= out_seen + 1;
    end
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

  // Wait for every accepted event to hand off. A fixed cycle count is wrong
  // under backpressure: the tail of a burst can sit in the output register
  // for as long as m_ready stays low.
  int n_accepted = 0;

  task automatic check(string name, logic cond);
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  task automatic feed(logic [TYPE_W-1:0] t, logic [SYMBOL_W-1:0] sym,
                      logic [SIDE_W-1:0] sd, logic [PRICE_W-1:0] p,
                      logic [QTY_W-1:0] q, event_err_t err = '0);
    int mark;
    mark = out_seen;
    @(negedge clk);
    s_event        = '0;
    s_event.etype  = t;
    s_event.symbol = sym;
    s_event.side   = sd;
    s_event.price  = p;
    s_event.qty    = q;
    s_err          = err;
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

  // Stream an event without ever dropping s_valid, so the stage sees
  // back-to-back traffic. feed() idles a cycle between events, so nothing in
  // this file used to drive the stage at full rate.
  task automatic push(logic [TYPE_W-1:0] t, logic [SYMBOL_W-1:0] sym,
                      logic [SIDE_W-1:0] sd, logic [PRICE_W-1:0] p,
                      logic [QTY_W-1:0] q, event_err_t err = '0);
    @(negedge clk);
    s_event        = '0;
    s_event.etype  = t;
    s_event.symbol = sym;
    s_event.side   = sd;
    s_event.price  = p;
    s_event.qty    = q;
    s_err          = err;
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

  initial begin
    m_ready = 1'b1;
    s_valid = 1'b0;
    s_event = '0;
    s_err   = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // --- reset leaves both sides empty --------------------------------
    do_reset();
    feed(EVT_CANCEL, 4'h0, SIDE_BID, 16'd100, 16'd0);
    check("reset: bid empty", last_book.bid_valid === 1'b0);
    check("reset: ask empty", last_book.ask_valid === 1'b0);

    // --- ADD establishes a side ---------------------------------------
    do_reset();
    feed(EVT_ADD, 4'h1, SIDE_BID, 16'd1000, 16'd50);
    check("add bid: valid",  last_book.bid_valid === 1'b1);
    check("add bid: price",  last_book.bid_price === 16'd1000);
    check("add bid: qty",    last_book.bid_qty   === 16'd50);
    check("add bid: ask untouched", last_book.ask_valid === 1'b0);

    // --- ADD at a better bid replaces ---------------------------------
    feed(EVT_ADD, 4'h1, SIDE_BID, 16'd1010, 16'd7);
    check("better bid: price", last_book.bid_price === 16'd1010);
    check("better bid: qty replaced, not summed", last_book.bid_qty === 16'd7);

    // --- ADD at the same bid accumulates size -------------------------
    feed(EVT_ADD, 4'h1, SIDE_BID, 16'd1010, 16'd3);
    check("equal bid: price held", last_book.bid_price === 16'd1010);
    check("equal bid: qty summed", last_book.bid_qty   === 16'd10);

    // --- ADD at a worse bid has no effect -----------------------------
    feed(EVT_ADD, 4'h1, SIDE_BID, 16'd900, 16'd999);
    check("worse bid: price held", last_book.bid_price === 16'd1010);
    check("worse bid: qty held",   last_book.bid_qty   === 16'd10);

    // --- size accumulation saturates rather than wrapping -------------
    // 10 + 0xFFF0 does NOT overflow (0xFFFA); it takes a second add to cross.
    feed(EVT_ADD, 4'h1, SIDE_BID, 16'd1010, 16'hFFF0);
    check("bid qty accumulates without wrap", last_book.bid_qty === 16'hFFFA);
    feed(EVT_ADD, 4'h1, SIDE_BID, 16'd1010, 16'd100);
    check("bid qty saturates", last_book.bid_qty === 16'hFFFF);
    feed(EVT_ADD, 4'h1, SIDE_BID, 16'd1010, 16'd1);
    check("bid qty stays saturated", last_book.bid_qty === 16'hFFFF);

    // --- ask side: LOWER is better ------------------------------------
    feed(EVT_ADD, 4'h1, SIDE_ASK, 16'd2000, 16'd20);
    check("add ask: price", last_book.ask_price === 16'd2000);
    feed(EVT_ADD, 4'h1, SIDE_ASK, 16'd1990, 16'd5);
    check("better ask is lower", last_book.ask_price === 16'd1990);
    check("better ask: qty replaced", last_book.ask_qty === 16'd5);
    feed(EVT_ADD, 4'h1, SIDE_ASK, 16'd2500, 16'd77);
    check("worse ask ignored", last_book.ask_price === 16'd1990);

    // --- CANCEL at the best clears that side only ---------------------
    feed(EVT_CANCEL, 4'h1, SIDE_ASK, 16'd1990, 16'd0);
    check("cancel best ask clears", last_book.ask_valid === 1'b0);
    check("cancel ask leaves bid",  last_book.bid_valid === 1'b1);

    // --- CANCEL away from the best has no effect ----------------------
    feed(EVT_CANCEL, 4'h1, SIDE_BID, 16'd999, 16'd0);
    check("cancel off-best ignored", last_book.bid_valid === 1'b1);
    check("cancel off-best price",   last_book.bid_price === 16'd1010);

    // --- TRADE at the best decrements -------------------------------
    do_reset();
    feed(EVT_ADD,   4'h2, SIDE_BID, 16'd500, 16'd100);
    feed(EVT_TRADE, 4'h2, SIDE_BID, 16'd500, 16'd40);
    check("trade decrements", last_book.bid_qty === 16'd60);
    check("trade keeps side", last_book.bid_valid === 1'b1);

    // --- TRADE to exactly zero clears the side ------------------------
    feed(EVT_TRADE, 4'h2, SIDE_BID, 16'd500, 16'd60);
    check("trade to zero clears", last_book.bid_valid === 1'b0);

    // --- TRADE larger than the resting size floors at zero ------------
    do_reset();
    feed(EVT_ADD,   4'h2, SIDE_ASK, 16'd400, 16'd10);
    feed(EVT_TRADE, 4'h2, SIDE_ASK, 16'd400, 16'd999);
    check("oversized trade clears", last_book.ask_valid === 1'b0);
    check("oversized trade does not underflow", last_book.ask_qty === 16'd0);

    // --- TRADE away from the best has no effect -----------------------
    do_reset();
    feed(EVT_ADD,   4'h3, SIDE_BID, 16'd700, 16'd30);
    feed(EVT_TRADE, 4'h3, SIDE_BID, 16'd699, 16'd30);
    check("trade off-best ignored", last_book.bid_qty === 16'd30);

    // --- price zero is a real price, not "empty" ----------------------
    do_reset();
    feed(EVT_ADD, 4'h4, SIDE_BID, 16'd0, 16'd15);
    check("price 0 is valid", last_book.bid_valid === 1'b1);
    check("price 0 held",     last_book.bid_price === 16'd0);
    check("price 0 qty",      last_book.bid_qty   === 16'd15);

    // --- trust gate: every flag withholds the update ------------------
    do_reset();
    feed(EVT_ADD, 4'h5, SIDE_BID, 16'd800, 16'd25);
    check("trusted update applied", last_book.bid_price === 16'd800);
    begin
      event_err_t e;
      // One flag at a time, each must be enough to withhold.
      for (int f = 0; f < 5; f++) begin
        e = '0;
        case (f)
          0: e.bad_type = 1'b1;
          1: e.bad_side = 1'b1;
          2: e.bad_rsv  = 1'b1;
          3: e.gap      = 1'b1;
          4: e.stale    = 1'b1;
        endcase
        feed(EVT_ADD, 4'h5, SIDE_BID, 16'd9999, 16'd1, e);
        check($sformatf("flag %0d withholds update", f),
              last_book.bid_price === 16'd800);
        check($sformatf("flag %0d sets book_stale", f), last_stale === 1'b1);
      end
    end
    feed(EVT_ADD, 4'h5, SIDE_BID, 16'd850, 16'd5);
    check("clean event after flags applies", last_book.bid_price === 16'd850);
    check("clean event clears book_stale",   last_stale === 1'b0);

    // --- symbols are independent --------------------------------------
    do_reset();
    feed(EVT_ADD, 4'h6, SIDE_BID, 16'd111, 16'd11);
    feed(EVT_ADD, 4'h7, SIDE_BID, 16'd222, 16'd22);
    check("symbol 7 own price", last_book.bid_price === 16'd222);
    feed(EVT_CANCEL, 4'h6, SIDE_BID, 16'd111, 16'd0);
    check("symbol 6 cleared", last_book.bid_valid === 1'b0);
    feed(EVT_ADD, 4'h7, SIDE_BID, 16'd222, 16'd1);
    check("symbol 7 survived symbol 6 cancel", last_book.bid_valid === 1'b1);
    check("symbol 7 qty intact", last_book.bid_qty === 16'd23);

    // --- ADD with qty 0 -------------------------------------------------
    // Not a hypothetical: the trust gate lets any well-formed event through
    // and the wire format allows qty 0. The spec now says an ADD with no size
    // cannot establish or improve a level, because otherwise it replaces a
    // real sized best with a phantom zero-size one and feature_engine reports
    // an imbalance of exactly +/-1.0 from an event that carried no size.
    //
    // The invariant these vectors pin: a valid side always has size > 0.
    do_reset();
    feed(EVT_ADD, 4'hB, SIDE_BID, 16'd100, 16'd0);
    check("add qty0 on an empty side has no effect", last_book.bid_valid === 1'b0);
    check("add qty0 leaves price clear", last_book.bid_price === 16'd0);

    feed(EVT_ADD, 4'hB, SIDE_BID, 16'd100, 16'd5);
    check("sized add establishes the level", last_book.bid_valid === 1'b1);
    check("sized add qty", last_book.bid_qty === 16'd5);

    // The case that motivated the rule: a better price carrying no size must
    // not wipe the resting level.
    feed(EVT_ADD, 4'hB, SIDE_BID, 16'd110, 16'd0);
    check("better ADD with qty0 leaves the price alone", last_book.bid_price === 16'd100);
    check("better ADD with qty0 leaves the size alone",  last_book.bid_qty   === 16'd5);
    check("better ADD with qty0 keeps the side valid",   last_book.bid_valid === 1'b1);

    // Equal price with qty 0 is a no-op too, by the same rule.
    feed(EVT_ADD, 4'hB, SIDE_BID, 16'd100, 16'd0);
    check("equal-price qty0 does not change size", last_book.bid_qty === 16'd5);

    // Mirror on the ask.
    feed(EVT_ADD, 4'hB, SIDE_ASK, 16'd900, 16'd0);
    check("add qty0 ask has no effect", last_book.ask_valid === 1'b0);
    feed(EVT_ADD, 4'hB, SIDE_ASK, 16'd900, 16'd8);
    feed(EVT_ADD, 4'hB, SIDE_ASK, 16'd880, 16'd0);
    check("better ask with qty0 leaves the price alone", last_book.ask_price === 16'd900);
    check("better ask with qty0 leaves the size alone",  last_book.ask_qty   === 16'd8);

    // The resulting invariant, checked directly: valid implies non-zero size.
    check("invariant: valid bid has size", !last_book.bid_valid || last_book.bid_qty != '0);
    check("invariant: valid ask has size", !last_book.ask_valid || last_book.ask_qty != '0);

    // --- crossed book ---------------------------------------------------
    // A top-of-book model has no cross-detection and the spec does not ask
    // for one: bid above ask is representable and travels downstream, where
    // SPREAD_W's extra bit keeps it from wrapping.
    do_reset();
    feed(EVT_ADD, 4'hC, SIDE_ASK, 16'd1000, 16'd10);
    feed(EVT_ADD, 4'hC, SIDE_BID, 16'd2000, 16'd20);
    check("crossed: bid above ask is accepted", last_book.bid_price === 16'd2000);
    check("crossed: ask untouched",             last_book.ask_price === 16'd1000);
    check("crossed: both sides still valid",
          last_book.bid_valid === 1'b1 && last_book.ask_valid === 1'b1);
    // Read the state back with an event that cannot change it: a book that
    // "helpfully" un-crosses itself on the next update would clear a side
    // here, and checking only the crossing event itself would not see it.
    feed(EVT_CANCEL, 4'hC, SIDE_BID, 16'd7, 16'd0);
    check("crossed: survives the next event, bid", last_book.bid_price === 16'd2000);
    check("crossed: survives the next event, ask", last_book.ask_price === 16'd1000);
    check("crossed: both sides still valid after the next event",
          last_book.bid_valid === 1'b1 && last_book.ask_valid === 1'b1);
    // Full-scale cross, the widest spread the format can carry.
    do_reset();
    feed(EVT_ADD, 4'hC, SIDE_BID, 16'hFFFF, 16'd1);
    feed(EVT_ADD, 4'hC, SIDE_ASK, 16'd0,    16'd1);
    check("full-scale cross bid", last_book.bid_price === 16'hFFFF);
    check("full-scale cross ask", last_book.ask_price === 16'd0);

    // --- back-to-back traffic, valid never dropped ----------------------
    // Every other phase in this file idles a cycle between events, so the
    // stage was never driven at full rate. A book that read its own output
    // register instead of its state array would pass all of them and fail
    // here.
    do_reset();
    push(EVT_ADD,   4'hD, SIDE_BID, 16'd500, 16'd10);
    push(EVT_ADD,   4'hD, SIDE_BID, 16'd500, 16'd10);
    push(EVT_ADD,   4'hD, SIDE_BID, 16'd500, 16'd10);
    push(EVT_ADD,   4'hD, SIDE_BID, 16'd510, 16'd7);
    push(EVT_TRADE, 4'hD, SIDE_BID, 16'd510, 16'd3);
    push(EVT_ADD,   4'hD, SIDE_ASK, 16'd600, 16'd4);
    push(EVT_ADD,   4'hD, SIDE_ASK, 16'd600, 16'd6);
    drain();
    check($sformatf("back-to-back: bid price (got %0d)", last_book.bid_price),
          last_book.bid_price === 16'd510);
    check($sformatf("back-to-back: bid qty (got %0d)", last_book.bid_qty),
          last_book.bid_qty === 16'd4);
    check($sformatf("back-to-back: ask qty (got %0d)", last_book.ask_qty),
          last_book.ask_qty === 16'd10);
    // Consecutive events on DIFFERENT symbols, at full rate: the read of
    // book[symbol] and the write to it must both use the same index.
    do_reset();
    for (int sym = 0; sym < N_SYMBOLS; sym++)
      push(EVT_ADD, SYMBOL_W'(sym), SIDE_BID, PRICE_W'(1000 + sym), QTY_W'(sym + 1));
    for (int sym = 0; sym < N_SYMBOLS; sym++)
      push(EVT_ADD, SYMBOL_W'(sym), SIDE_ASK, PRICE_W'(2000 + sym), QTY_W'(sym + 1));
    drain();
    // Read every symbol back with a no-op event that cannot change it.
    for (int sym = 0; sym < N_SYMBOLS; sym++) begin
      feed(EVT_CANCEL, SYMBOL_W'(sym), SIDE_BID, 16'd7, 16'd0);
      check($sformatf("all-symbols: sym %0d bid price", sym),
            last_book.bid_price === PRICE_W'(1000 + sym));
      check($sformatf("all-symbols: sym %0d bid qty", sym),
            last_book.bid_qty === QTY_W'(sym + 1));
      check($sformatf("all-symbols: sym %0d ask price", sym),
            last_book.ask_price === PRICE_W'(2000 + sym));
      check($sformatf("all-symbols: sym %0d ask qty", sym),
            last_book.ask_qty === QTY_W'(sym + 1));
    end

    // --- the update rules again, under randomized backpressure ----------
    // m_ready was tied high for this whole testbench, which made every stall
    // property bound into top_of_book vacuous: a stage that reloaded its
    // output register during a stall, or that applied an event to the book
    // twice while waiting, would have passed everything above.
    do_reset();
    bp_enable = 1'b1;
    feed(EVT_ADD, 4'hE, SIDE_BID, 16'd300, 16'd10);
    check("stalled: add establishes", last_book.bid_qty === 16'd10);
    feed(EVT_ADD, 4'hE, SIDE_BID, 16'd300, 16'd10);
    // A book that applied the event on every stalled cycle would read 30+.
    check("stalled: accumulate applied exactly once", last_book.bid_qty === 16'd20);
    feed(EVT_TRADE, 4'hE, SIDE_BID, 16'd300, 16'd5);
    check("stalled: trade applied exactly once", last_book.bid_qty === 16'd15);
    feed(EVT_ADD, 4'hE, SIDE_ASK, 16'd400, 16'd9);
    feed(EVT_CANCEL, 4'hE, SIDE_ASK, 16'd400, 16'd0);
    check("stalled: cancel clears", last_book.ask_valid === 1'b0);
    check("stalled: cancel left the bid alone", last_book.bid_qty === 16'd15);
    begin
      event_err_t e;
      e = '0; e.gap = 1'b1;
      feed(EVT_ADD, 4'hE, SIDE_BID, 16'd9999, 16'd1, e);
      check("stalled: flagged event withheld", last_book.bid_price === 16'd300);
      check("stalled: flagged event sets book_stale", last_stale === 1'b1);
    end
    // Back-to-back traffic while the output stalls: the only configuration
    // where s_ready falls with a fresh event already offered.
    push(EVT_ADD, 4'hF, SIDE_BID, 16'd50, 16'd1);
    push(EVT_ADD, 4'hF, SIDE_BID, 16'd50, 16'd1);
    push(EVT_ADD, 4'hF, SIDE_BID, 16'd50, 16'd1);
    push(EVT_ADD, 4'hF, SIDE_BID, 16'd50, 16'd1);
    push(EVT_ADD, 4'hF, SIDE_BID, 16'd50, 16'd1);
    push(EVT_ADD, 4'hF, SIDE_BID, 16'd50, 16'd1);
    push(EVT_ADD, 4'hF, SIDE_BID, 16'd50, 16'd1);
    push(EVT_ADD, 4'hF, SIDE_BID, 16'd50, 16'd1);
    drain();
    check($sformatf("stalled back-to-back: eight adds landed once each (got %0d)",
                    last_book.bid_qty),
          last_book.bid_qty === 16'd8);
    bp_enable = 1'b0;
    @(negedge clk);
    m_ready = 1'b1;
    if (stall_cycles == 0) begin
      errors++;
      $error("FAIL: backpressure never asserted -- the stall properties were vacuous this run");
    end
    $display("INFO: backpressure phase stalled for %0d cycles", stall_cycles);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_top_of_book (%0d stall cycles)", stall_cycles);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
