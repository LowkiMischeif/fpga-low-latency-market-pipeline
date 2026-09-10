// Directed tests for event_decoder.
//
// These vectors are written by hand and never pass through
// scripts/generate_events.py. That is the point: the generator produces both
// the stimulus and the expectations for the randomized replay, so a bug there
// and a matching bug in the RTL would agree with each other. These vectors are
// the independent ground truth.
//
// "Independent" is taken literally in two places:
//
//   * The exhaustive encoding sweep compares against the literals 1/2/3 and
//     1/2 from the design spec, NOT against market_pkg::is_valid_type or
//     is_valid_side. The DUT calls those functions; a testbench that also
//     called them would prove only that the package agrees with itself, and
//     would pass with EVT_TRADE mis-encoded.
//
//   * The walking-ones sweep pins the wire format down bit by bit without
//     using the *_LSB constants to build the stimulus. It is the only check in
//     the suite that would survive a field-placement error being made
//     identically in market_pkg.sv, generate_events.py and this file's mk().
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
  int checks = 0;

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
    checks++;
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  // Proper valid/ready driver: valid goes high and STAYS high until the cycle
  // ready is seen, which is what the handshake contract requires and what the
  // old version of this task did not do.
  //
  // The `#1` matters. s_ready depends on m_ready, which the stall test drives
  // at the negedge, so sampling s_ready in the negedge delta is a race against
  // whichever process runs first. Losing that race makes this task treat the
  // FOLLOWING posedge as the accepting one while s_valid is still high, and
  // the event is accepted twice. Settling 1 ns into a 5 ns half-period is safe.
  task automatic send(logic [EVENT_W-1:0] w);
    @(negedge clk);
    s_data  = w;
    s_valid = 1'b1;
    #1;
    while (!s_ready) begin
      @(posedge clk);        // stalled: valid and payload held
      @(negedge clk);
      #1;
    end
    @(posedge clk);          // accepted on this edge
    @(negedge clk);
    s_valid = 1'b0;
  endtask

  // ------------------------------------------------------------------
  // Reference decode, written from the design spec's field table rather
  // than from market_pkg's LSB constants.
  // ------------------------------------------------------------------
  task automatic expect_fields(string tag, logic [EVENT_W-1:0] w);
    check({tag, " etype"},  m_event.etype  === w[63:56]);
    check({tag, " symbol"}, m_event.symbol === w[55:52]);
    check({tag, " side"},   m_event.side   === w[51:50]);
    check({tag, " price"},  m_event.price  === w[49:34]);
    check({tag, " qty"},    m_event.qty    === w[33:18]);
    check({tag, " seq"},    m_event.seq    === w[17:2]);
    check({tag, " bad_type"}, m_err.bad_type === !(w[63:56] inside {8'h01, 8'h02, 8'h03}));
    check({tag, " bad_side"}, m_err.bad_side === !(w[51:50] inside {2'b01, 2'b10}));
    check({tag, " bad_rsv"},  m_err.bad_rsv  === (w[1:0] != 2'b00));
    check({tag, " gap clear"},   m_err.gap   === 1'b0);
    check({tag, " stale clear"}, m_err.stale === 1'b0);
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

    // --- exhaustive type classification -------------------------------
    //
    // The five hand-picked vectors above miss the encoding that actually
    // matters: 0x04, one past EVT_TRADE. An off-by-one in the validator
    // (t <= 3 written as t <= 4) passes every vector above and every value
    // the generator injects. 256 events is cheap; sweep the whole field.
    begin
      logic [EVENT_W-1:0] w;
      for (int t = 0; t < 256; t++) begin
        w = mk(t[TYPE_W-1:0], 4'h2, SIDE_ASK, 16'h0800, 16'h0010,
               16'(t), 2'b00);
        send(w);
        check($sformatf("type sweep %0h valid", t), m_valid === 1'b1);
        check($sformatf("type sweep %0h bad_type", t),
              m_err.bad_type === !(t inside {1, 2, 3}));
        check($sformatf("type sweep %0h forwarded verbatim", t),
              m_event.etype === t[TYPE_W-1:0]);
      end
    end

    // --- exhaustive side x rsv classification -------------------------
    begin
      logic [EVENT_W-1:0] w;
      for (int sd = 0; sd < 4; sd++) begin
        for (int r = 0; r < 4; r++) begin
          w = mk(EVT_ADD, 4'h3, sd[SIDE_W-1:0], 16'h0100, 16'h0020,
                 16'h4000, r[RSV_W-1:0]);
          send(w);
          check($sformatf("side/rsv sweep %0d/%0d bad_side", sd, r),
                m_err.bad_side === !(sd inside {1, 2}));
          check($sformatf("side/rsv sweep %0d/%0d bad_rsv", sd, r),
                m_err.bad_rsv === (r != 0));
          check($sformatf("side/rsv sweep %0d/%0d bad_type clear", sd, r),
                m_err.bad_type === 1'b0);
        end
      end
    end

    // --- walking ones: every wire bit lands in exactly one field ------
    //
    // Stimulus is a raw one-hot word, not built by mk(), and the expected
    // decode is taken from the bit ranges in the spec's field table. This is
    // the check that survives market_pkg, generate_events.py and mk() all
    // agreeing on a WRONG layout.
    begin
      logic [EVENT_W-1:0] w;
      for (int b = 0; b < EVENT_W; b++) begin
        w = '0;
        w[b] = 1'b1;
        send(w);
        expect_fields($sformatf("walk bit %0d", b), w);
      end
    end

    // --- backpressure: an offered event must survive a multi-cycle stall
    //
    // Nothing in the old version of this file ever deasserted m_ready, so
    // every stall property bound into this module was vacuous here. Hold
    // m_ready low for four cycles with an event parked at the output.
    begin
      logic [EVENT_W-1:0] w;
      w = mk(EVT_TRADE, 4'h9, SIDE_ASK, 16'h5A5A, 16'h1357, 16'h2468, 2'b00);
      send(w);
      check("stall setup m_valid", m_valid === 1'b1);
      m_ready = 1'b0;
      // Offer the next event while the output is blocked: this is the only
      // way to drive s_valid high with s_ready low, which is what makes
      // a_no_valid_retraction_in and a_in_payload_stable non-vacuous.
      fork
        send(mk(EVT_ADD, 4'h4, SIDE_BID, 16'h0F0F, 16'h2222, 16'h2469, 2'b00));
      join_none
      repeat (4) @(posedge clk);
      check("stalled m_valid held",  m_valid === 1'b1);
      check("stalled payload held",  m_event.price === 16'h5A5A
                                     && m_event.seq === 16'h2468);
      check("stalled flags held",    m_err === '0);
      check("stalled s_ready low",   s_ready === 1'b0);
      @(negedge clk);
      m_ready = 1'b1;
      // One edge, not two: with the output free again the parked event drains
      // and the event that was waiting at the input is accepted on the SAME
      // posedge, so the second event is at the output from here. Checking a
      // cycle later reads a pipe that has already drained.
      @(posedge clk);
      @(negedge clk);
      check("post-stall second event", m_event.seq === 16'h2469);
      check("post-stall m_valid",      m_valid === 1'b1);
      wait fork;
    end

    // --- reset asserted mid-transaction -------------------------------
    //
    // rst_n is asynchronous: with an event parked at a stalled output, pulling
    // reset low between clock edges must clear m_valid immediately, without
    // waiting for a posedge.
    begin
      send(mk(EVT_CANCEL, 4'h6, SIDE_BID, 16'h1111, 16'h2222, 16'h3333, 2'b00));
      // send() returns at the negedge after the accepting edge, which is the
      // last chance to park the event: leave m_ready high one more posedge and
      // the output drains before reset can be observed against it.
      m_ready = 1'b0;
      @(posedge clk);
      #1;
      check("pre-reset m_valid", m_valid === 1'b1);
      #1 rst_n = 1'b0;             // mid-cycle, nowhere near a clock edge
      #1;
      check("async reset clears m_valid without a clock edge", m_valid === 1'b0);
      check("async reset clears m_event", m_event === '0);
      check("async reset clears m_err",   m_err   === '0);
      @(negedge clk);
      m_ready = 1'b1;
      @(posedge clk);
      check("m_valid stays clear while reset held", m_valid === 1'b0);
      @(negedge clk);
      rst_n = 1'b1;
      @(posedge clk);
      @(negedge clk);
      check("m_valid still clear after release with no input", m_valid === 1'b0);
      // And the module still works afterwards.
      send(mk(EVT_ADD, 4'h1, SIDE_ASK, 16'h4444, 16'h5555, 16'h6666, 2'b00));
      check("post-reset decode", m_event.seq === 16'h6666 && m_valid === 1'b1);
    end

    if (errors != 0) $fatal(1, "FAIL: %0d of %0d directed checks failed",
                            errors, checks);
    $display("PASS: tb_event_decoder (%0d directed checks)", checks);
    $finish;
  end

  initial begin
    #500000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
