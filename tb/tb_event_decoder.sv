// Directed tests for event_decoder.
//
// These vectors are written by hand and never pass through
// scripts/generate_events.py. That is the point: the generator produces both
// the stimulus and the expectations for the randomized replay, so a bug there
// and a matching bug in the RTL would agree with each other. These vectors are
// the independent ground truth.
module tb_event_decoder;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [EVENT_W-1:0] s_data;
  logic               s_valid, s_ready;
  market_event_t      m_event;
  event_err_t         m_err;
  logic               m_valid, m_ready;

  event_decoder dut (.*);

  int errors = 0;

  // Build a beat from fields, independently of generate_events.py.
  function automatic logic [EVENT_W-1:0] mk(
      logic [TYPE_W-1:0] t, logic [SYMBOL_W-1:0] sym, logic [SIDE_W-1:0] sd,
      logic [PRICE_W-1:0] p, logic [QTY_W-1:0] q, logic [SEQ_W-1:0] sq,
      logic [RSV_W-1:0] rsv);
    logic [EVENT_W-1:0] w;
    w = '0;
    w[TYPE_LSB   +: TYPE_W]   = t;
    w[SYMBOL_LSB +: SYMBOL_W] = sym;
    w[SIDE_LSB   +: SIDE_W]   = sd;
    w[PRICE_LSB  +: PRICE_W]  = p;
    w[QTY_LSB    +: QTY_W]    = q;
    w[SEQ_LSB    +: SEQ_W]    = sq;
    w[RSV_LSB    +: RSV_W]    = rsv;
    return w;
  endfunction

  task automatic check(string name, logic cond);
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  task automatic send(logic [EVENT_W-1:0] w);
    @(negedge clk);
    s_data  = w;
    s_valid = 1'b1;
    @(posedge clk);
    while (!s_ready) @(posedge clk);
    @(negedge clk);
    s_valid = 1'b0;
  endtask

  initial begin
    m_ready = 1'b1;
    s_valid = 1'b0;
    s_data  = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // --- v1: a well-formed ADD/BID ------------------------------------
    send(mk(EVT_ADD, 4'h5, SIDE_BID, 16'h1234, 16'h0063, 16'h1092, 2'b00));
    check("v1 valid",   m_valid === 1'b1);
    check("v1 etype",   m_event.etype  === EVT_ADD);
    check("v1 symbol",  m_event.symbol === 4'h5);
    check("v1 side",    m_event.side   === SIDE_BID);
    check("v1 price",   m_event.price  === 16'h1234);
    check("v1 qty",     m_event.qty    === 16'h0063);
    check("v1 seq",     m_event.seq    === 16'h1092);
    check("v1 no errs", m_err.bad_type === 1'b0 && m_err.bad_side === 1'b0
                        && m_err.bad_rsv === 1'b0);

    // --- v2: undefined type, everything else valid --------------------
    send(mk(8'hFF, 4'h0, SIDE_ASK, 16'h0001, 16'h0002, 16'h0003, 2'b00));
    check("v2 bad_type set",     m_err.bad_type === 1'b1);
    check("v2 bad_side clear",   m_err.bad_side === 1'b0);
    check("v2 forwarded anyway", m_valid === 1'b1);
    check("v2 payload intact",   m_event.price === 16'h0001);

    // --- v3: undefined side -------------------------------------------
    send(mk(EVT_TRADE, 4'hF, 2'b11, 16'hFFFF, 16'hFFFF, 16'hFFFF, 2'b00));
    check("v3 bad_side set",   m_err.bad_side === 1'b1);
    check("v3 bad_type clear", m_err.bad_type === 1'b0);
    check("v3 all-ones fields", m_event.price === 16'hFFFF
                                && m_event.qty === 16'hFFFF);

    // --- v4: reserved bits non-zero -----------------------------------
    send(mk(EVT_CANCEL, 4'h1, SIDE_BID, 16'h0000, 16'h0000, 16'h0000, 2'b10));
    check("v4 bad_rsv set",  m_err.bad_rsv  === 1'b1);
    check("v4 others clear", m_err.bad_type === 1'b0 && m_err.bad_side === 1'b0);

    // --- v5: all three defects at once --------------------------------
    send(mk(8'h00, 4'h7, 2'b00, 16'h00FF, 16'h0F00, 16'hBEEF, 2'b11));
    check("v5 bad_type", m_err.bad_type === 1'b1);
    check("v5 bad_side", m_err.bad_side === 1'b1);
    check("v5 bad_rsv",  m_err.bad_rsv  === 1'b1);
    check("v5 seq",      m_event.seq    === 16'hBEEF);

    // --- gap and stale are not this module's to set -------------------
    check("decoder leaves gap clear",   m_err.gap   === 1'b0);
    check("decoder leaves stale clear", m_err.stale === 1'b0);

    // --- reset must clear valid ---------------------------------------
    @(negedge clk);
    rst_n = 1'b0;
    @(posedge clk);
    @(negedge clk);
    check("reset clears m_valid", m_valid === 1'b0);
    rst_n = 1'b1;

    if (errors != 0) $fatal(1, "FAIL: %0d directed checks failed", errors);
    $display("PASS: tb_event_decoder (5 directed vectors)");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
