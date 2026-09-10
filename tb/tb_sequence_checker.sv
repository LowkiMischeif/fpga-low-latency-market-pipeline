// Directed tests for sequence_checker. Hand-written, independent of
// generate_events.py.
//
// The two cases this file exists for are 16-bit sequence wraparound (a naive
// magnitude comparison calls every wrap a 65535-event gap) and the first
// event after reset (expecting zero would make any trace starting mid-stream
// report a spurious gap).
module tb_sequence_checker;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  market_event_t    s_event, m_event;
  event_err_t       s_err, m_err;
  logic             s_valid, s_ready, m_valid, m_ready;
  logic [CNT_W-1:0] gap_count, stale_count, missed_total, bad_event_count;

  sequence_checker dut (.*);

  int errors = 0;

  task automatic check(string name, logic cond);
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  // Capture the output at the cycle it is actually handed downstream.
  //
  // Reading m_err after m_valid has dropped does not work: the output
  // register reloads on every cycle s_ready is high, so once the driver
  // deasserts s_valid the DUT recomputes the flags from the still-stable
  // s_event against an expect_seq that has already advanced, and the last
  // event reads back as stale. The decoder testbench gets away with sampling
  // the ports directly because that module holds no state; this one does not.
  market_event_t last_event;
  event_err_t    last_err;
  always_ff @(posedge clk) begin
    if (rst_n && m_valid && m_ready) begin
      last_event <= m_event;
      last_err   <= m_err;
    end
  end

  task automatic feed(logic [SEQ_W-1:0] sq, event_err_t err = '0);
    // s_ready is stable at the negedge, reflecting the edge just passed.
    @(negedge clk);
    while (!s_ready) @(negedge clk);
    s_event       = '0;
    s_event.etype = EVT_ADD;
    s_event.side  = SIDE_BID;
    s_event.seq   = sq;
    s_err         = err;
    s_valid       = 1'b1;
    @(posedge clk);          // transfer happens on this edge
    @(negedge clk);
    s_valid = 1'b0;
    @(posedge clk);          // monitor captures the registered output here
    @(negedge clk);
  endtask

  task automatic do_reset();
    @(negedge clk);
    rst_n = 1'b0;
    @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    @(negedge clk);
  endtask

  initial begin
    m_ready = 1'b1;
    s_valid = 1'b0;
    s_event = '0;
    s_err   = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // --- first event after reset must NOT be a gap --------------------
    feed(16'd5000);
    check("first event no gap",   last_err.gap   === 1'b0);
    check("first event no stale", last_err.stale === 1'b0);
    check("gap_count still 0",    gap_count   === '0);

    // --- in-order events ----------------------------------------------
    feed(16'd5001);
    check("in-order no gap", last_err.gap === 1'b0 && last_err.stale === 1'b0);
    feed(16'd5002);
    check("in-order no gap 2", last_err.gap === 1'b0);

    // --- forward jump is a gap; missed_total counts the hole ----------
    feed(16'd5006);
    check("gap flagged",    last_err.gap    === 1'b1);
    check("gap_count 1",    gap_count    === 32'd1);
    check("missed_total 3", missed_total === 32'd3);  // 5003, 5004, 5005
    check("stale clear",    last_err.stale  === 1'b0);

    // --- after a gap the checker resyncs to received+1 ----------------
    feed(16'd5007);
    check("resync no gap",     last_err.gap === 1'b0);
    check("gap_count still 1", gap_count === 32'd1);

    // --- backward jump is stale and must NOT advance expectation ------
    feed(16'd5003);
    check("stale flagged",    last_err.stale  === 1'b1);
    check("stale_count 1",    stale_count  === 32'd1);
    check("missed unchanged", missed_total === 32'd3);
    feed(16'd5008);
    check("expectation preserved across stale", last_err.gap === 1'b0);

    // --- duplicate of the previous event is stale ---------------------
    feed(16'd5008);
    check("duplicate is stale", last_err.stale === 1'b1);
    check("stale_count 2",      stale_count === 32'd2);

    // --- upstream error flags forwarded and counted -------------------
    begin
      event_err_t e;
      e = '0;
      e.bad_type = 1'b1;
      feed(16'd5009, e);
      check("bad_type forwarded", last_err.bad_type === 1'b1);
      check("bad_event_count 1",  bad_event_count === 32'd1);
    end

    // --- 16-bit wraparound is in order, NOT a 65535-event gap ---------
    do_reset();
    feed(16'hFFFD);
    feed(16'hFFFE);
    check("pre-wrap in order", last_err.gap === 1'b0);
    feed(16'hFFFF);
    check("last before wrap", last_err.gap === 1'b0);
    feed(16'h0000);
    check("wrap is not a gap", last_err.gap   === 1'b0);
    check("wrap is not stale", last_err.stale === 1'b0);
    check("no missed at wrap", missed_total === '0);
    feed(16'h0001);
    check("post-wrap in order", last_err.gap === 1'b0);

    // --- a real gap straddling the wrap is still a gap ----------------
    do_reset();
    feed(16'hFFFE);
    feed(16'h0002);   // skipped FFFF, 0000, 0001
    check("gap across wrap flagged", last_err.gap === 1'b1);
    check("missed across wrap == 3", missed_total === 32'd3);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_sequence_checker");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
