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
  always_ff @(posedge clk) begin
    if (rst_n && m_valid && m_ready) begin
      last_book  <= m_book;
      last_stale <= m_book_stale;
    end
  end

  task automatic check(string name, logic cond);
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  task automatic feed(logic [TYPE_W-1:0] t, logic [SYMBOL_W-1:0] sym,
                      logic [SIDE_W-1:0] sd, logic [PRICE_W-1:0] p,
                      logic [QTY_W-1:0] q, event_err_t err = '0);
    @(negedge clk);
    while (!s_ready) @(negedge clk);
    s_event        = '0;
    s_event.etype  = t;
    s_event.symbol = sym;
    s_event.side   = sd;
    s_event.price  = p;
    s_event.qty    = q;
    s_err          = err;
    s_valid        = 1'b1;
    @(posedge clk);
    @(negedge clk);
    s_valid = 1'b0;
    @(posedge clk);
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

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_top_of_book");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
