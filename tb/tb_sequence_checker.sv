// Directed tests for sequence_checker. Hand-written, independent of
// generate_events.py.
//
// The cases this file exists for are the ones a generator that mirrors the RTL
// can never find:
//
//   * 16-bit sequence wraparound (a naive magnitude comparison calls every
//     wrap a 65535-event gap);
//   * the signed-comparison boundary at diff = +32767 / +32768, where "gap"
//     silently becomes "stale" -- the generator only ever injects gaps of 1..8
//     and stale of 1..8, so it cannot reach the boundary at all;
//   * the first event after reset (expecting zero would make any trace
//     starting mid-stream report a spurious gap);
//   * counter saturation, which needs 2**32 missed events to reach;
//   * backpressure, which the generator has no concept of.
module tb_sequence_checker;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  market_event_t    s_event, m_event;
  event_err_t       s_err, m_err;
  logic             s_valid, s_ready, m_valid, m_ready;
  logic [CNT_W-1:0] gap_count, stale_count, missed_total, bad_event_count;
  logic [CNT_W-1:0] resync_count;

  sequence_checker dut (.*);

  int errors = 0;
  int checks = 0;

  // Saturation-phase constants. A gap of SAT_STEP is the largest a 16-bit
  // signed modular difference can express, so it is the fastest legal way to
  // walk missed_total to its carry-out. CNT_MAX is held in a longint --
  // deliberately wider than the counter -- so the reference the RTL is
  // compared against cannot itself have wrapped.
  localparam int unsigned     SAT_STEP = 32767;
  localparam longint unsigned CNT_MAX  = (longint'(1) << CNT_W) - 1;

  task automatic check(string name, logic cond);
    checks++;
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
  int            handoffs;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      handoffs <= 0;
    end else if (m_valid && m_ready) begin
      last_event <= m_event;
      last_err   <= m_err;
      handoffs   <= handoffs + 1;
    end
  end

  // Offer an event and hold valid until it is accepted, as the handshake
  // contract requires.
  //
  // The `#1` matters. s_ready depends on m_ready, which the stall tests drive
  // at the negedge, so sampling s_ready in the negedge delta is a race against
  // whichever process happens to run first. Losing that race makes this task
  // treat the FOLLOWING posedge as the accepting one while s_valid is still
  // high -- the event is accepted twice and shows up downstream as a duplicate
  // (a spurious `stale`). That is a testbench bug that looks exactly like an
  // RTL bug, which is why the delay is here and commented rather than tuned
  // away. Settling 1 ns into a 5 ns half-period is safe.
  task automatic offer(logic [SEQ_W-1:0] sq, event_err_t err = '0);
    @(negedge clk);
    s_event       = '0;
    s_event.etype = EVT_ADD;
    s_event.side  = SIDE_BID;
    s_event.seq   = sq;
    s_err         = err;
    s_valid       = 1'b1;
    #1;
    while (!s_ready) begin
      @(posedge clk);      // stalled: valid, payload and flags all held
      @(negedge clk);
      #1;
    end
    @(posedge clk);        // accepted on this edge
    @(negedge clk);
    s_valid = 1'b0;
  endtask

  // offer() plus enough time for the output to be handed downstream and
  // captured. Only valid while m_ready is high.
  task automatic feed(logic [SEQ_W-1:0] sq, event_err_t err = '0);
    offer(sq, err);
    @(posedge clk);        // monitor captures the registered output here
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

  task automatic check_counters_clear(string tag);
    check({tag, " gap_count clear"},       gap_count       === '0);
    check({tag, " stale_count clear"},     stale_count     === '0);
    check({tag, " missed_total clear"},    missed_total    === '0);
    check({tag, " bad_event_count clear"}, bad_event_count === '0);
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

    // --- back-to-back gaps with no good event between -----------------
    //
    // Nothing above proves the resync survives being interrupted again
    // immediately. expect_seq is written on the same cycle the gap is
    // counted, so a gap that lands while the previous gap's resync is still
    // being applied is exactly the case to check.
    do_reset();
    feed(16'd1000);
    feed(16'd1010);                                  // 9 missed
    check("btb gap 1",  last_err.gap === 1'b1);
    feed(16'd1020);                                  // 9 missed
    check("btb gap 2",  last_err.gap === 1'b1);
    feed(16'd1030);                                  // 9 missed
    check("btb gap 3",  last_err.gap === 1'b1);
    check("btb gap_count 3",   gap_count    === 32'd3);
    check("btb missed 27",     missed_total === 32'd27);
    check("btb stale_count 0", stale_count  === 32'd0);
    feed(16'd1031);
    check("btb resync clean", last_err.gap === 1'b0 && last_err.stale === 1'b0);

    // --- signed-comparison boundary: +32767 is the largest real gap ---
    //
    // diff is interpreted as a signed 16-bit number, so a forward jump of
    // 32767 is the biggest one that can still be told from a backward jump.
    // The spec says "correct for any real gap below 32768"; this is that
    // sentence turned into two vectors that fail if the boundary moves.
    do_reset();
    feed(16'd0);                                     // baseline, expect = 1
    feed(16'd32768);                                 // diff = +32767
    check("gap of 32767 flagged as gap",   last_err.gap   === 1'b1);
    check("gap of 32767 not stale",        last_err.stale === 1'b0);
    check("gap of 32767 missed_total",     missed_total   === 32'd32767);
    check("gap of 32767 gap_count",        gap_count      === 32'd1);

    // --- ...and +32768 aliases to stale. Documented limitation --------
    //
    // This is not a bug being papered over: with a 16-bit sequence and a
    // signed modular comparison there is no encoding that distinguishes a
    // forward jump of 32768 from a backward jump of 32768. Pinning it means a
    // future change to the comparison shows up here instead of in production
    // telemetry.
    do_reset();
    feed(16'd0);                                     // expect = 1
    feed(16'd32769);                                 // diff = -32768
    check("gap of 32768 aliases to stale", last_err.stale === 1'b1);
    check("gap of 32768 not a gap",        last_err.gap   === 1'b0);
    check("gap of 32768 missed unchanged", missed_total   === 32'd0);
    check("gap of 32768 stale_count 1",    stale_count    === 32'd1);
    // Expectation is NOT advanced, so the feed keeps running from 1.
    feed(16'd1);
    check("after aliased gap, expect still 1",
          last_err.gap === 1'b0 && last_err.stale === 1'b0);

    // --- a stale event more than 32768 behind aliases to a gap --------
    //
    // The mirror image, and the more damaging one: it inflates missed_total
    // and drags expect_seq BACKWARDS, so the events that follow are all
    // reported stale until the feed catches up. Pinned here so the cost of
    // the 16-bit sequence field is a recorded number rather than a surprise.
    do_reset();
    feed(16'd50000);                                 // baseline, expect=50001
    feed(16'd10001);                                 // 40000 behind
    check("stale of 40000 aliases to gap", last_err.gap   === 1'b1);
    check("stale of 40000 not stale",      last_err.stale === 1'b0);
    check("stale of 40000 inflates missed", missed_total  === 32'd25536);
    feed(16'd10002);
    check("expect dragged backwards, next event in order",
          last_err.gap === 1'b0 && last_err.stale === 1'b0);

    // --- first event after reset is a baseline, not a comparison ------
    //
    // expect_seq resets to 0, so a first event at 0xF000 has diff = -4096.
    // Without the primed guard this reads as stale, and with a naive
    // magnitude comparison it reads as a 61440-event gap. Neither is right.
    do_reset();
    feed(16'hF000);
    check("first event 0xF000 no gap",   last_err.gap   === 1'b0);
    check("first event 0xF000 no stale", last_err.stale === 1'b0);
    check_counters_clear("first event 0xF000");
    feed(16'hF001);
    check("second event after high baseline in order",
          last_err.gap === 1'b0 && last_err.stale === 1'b0);

    // --- reset must clear primed, not just the counters ---------------
    do_reset();
    feed(16'd20000);
    feed(16'd20001);
    do_reset();
    check_counters_clear("post-reset");
    feed(16'd60000);                    // nowhere near the old expectation
    check("reset clears primed: no gap",   last_err.gap   === 1'b0);
    check("reset clears primed: no stale", last_err.stale === 1'b0);
    check_counters_clear("post-reset first event");

    // --- upstream error flags forwarded and counted -------------------
    do_reset();
    feed(16'd100);
    begin
      event_err_t e;
      e = '0; e.bad_type = 1'b1;
      feed(16'd101, e);
      check("bad_type forwarded", last_err.bad_type === 1'b1);
      check("bad_event_count 1",  bad_event_count === 32'd1);

      e = '0; e.bad_side = 1'b1;
      feed(16'd102, e);
      check("bad_side forwarded", last_err.bad_side === 1'b1);
      check("bad_event_count 2",  bad_event_count === 32'd2);

      e = '0; e.bad_rsv = 1'b1;
      feed(16'd103, e);
      check("bad_rsv forwarded", last_err.bad_rsv === 1'b1);
      check("bad_event_count 3", bad_event_count === 32'd3);

      // Three defects on one event is ONE bad event, not three.
      e = '0; e.bad_type = 1'b1; e.bad_side = 1'b1; e.bad_rsv = 1'b1;
      feed(16'd104, e);
      check("all three forwarded", last_err.bad_type && last_err.bad_side
                                   && last_err.bad_rsv);
      check("bad_event_count 4 (one event, not three)",
            bad_event_count === 32'd4);

      // A malformed event that is also a gap counts in both places and is
      // still forwarded rather than dropped.
      e = '0; e.bad_type = 1'b1;
      feed(16'd110, e);               // 5 missed
      // A malformed event is still CLASSIFIED against the expectation, so the
      // gap flag is informational and still set. But it must not move gap
      // telemetry: a garbage seq field could otherwise inflate missed_total
      // by up to 32767 from a single corrupt beat.
      check("bad+gap: gap flagged",       last_err.gap === 1'b1);
      check("bad+gap: bad_type kept",     last_err.bad_type === 1'b1);
      check("bad+gap: gap_count unmoved", gap_count === 32'd0);
      check("bad+gap: missed unmoved",    missed_total === 32'd0);
      check("bad+gap: bad_event_count 5", bad_event_count === 32'd5);
    end

    // --- a malformed beat must not redefine the sequence baseline -----
    // rtl-skeptic-reviewer's scenario: without the trust rule, one corrupt
    // event with a garbage seq resyncs expect_seq to that garbage, and the
    // next legitimate event reads as stale forever after.
    begin
      event_err_t bad;
      bad = '0;
      bad.bad_rsv = 1'b1;
      do_reset();
      feed(16'd100);
      check("trust: baseline established", last_err.gap === 1'b0);
      feed(16'd101);
      check("trust: in order", last_err.gap === 1'b0 && last_err.stale === 1'b0);
      // The garbage seq must land FORWARD of the expectation so it is
      // classified as a gap -- that is the path that resyncs expect_seq, and
      // therefore the path the trust rule has to gate. A backward garbage
      // value reads as stale, which never resynced in the first place and so
      // would not exercise the rule at all.
      feed(16'd20000, bad);
      check("trust: garbage flagged bad",  last_err.bad_rsv === 1'b1);
      check("trust: garbage reads as gap", last_err.gap === 1'b1);
      check("trust: gap_count unmoved",    gap_count === 32'd0);
      check("trust: missed_total unmoved", missed_total === 32'd0);
      feed(16'd102);
      check("trust: next good event is in order",
            last_err.gap === 1'b0 && last_err.stale === 1'b0);

      // And the backward-garbage case, which must also leave the baseline
      // alone: after it, 103 is still the expected number.
      feed(16'hDEAD, bad);
      check("trust: backward garbage flagged", last_err.bad_rsv === 1'b1);
      feed(16'd103);
      check("trust: baseline survived backward garbage",
            last_err.gap === 1'b0 && last_err.stale === 1'b0);
    end

    // --- a malformed FIRST event must not establish the baseline ------
    begin
      event_err_t bad;
      bad = '0;
      bad.bad_type = 1'b1;
      do_reset();
      feed(16'hBEEF, bad);
      check("trust: bad first event not a gap", last_err.gap === 1'b0);
      feed(16'd7000);
      check("trust: first trusted event sets baseline, not a gap",
            last_err.gap === 1'b0 && last_err.stale === 1'b0);
      feed(16'd7001);
      check("trust: baseline is the trusted one", last_err.gap === 1'b0);
    end

    // --- the stale watchdog bounds aliasing damage --------------------
    // A forward jump of 32768 aliases to stale (the 16-bit window cannot tell
    // the two apart). Without the watchdog the checker would report every one
    // of the next 32768 events as stale while gap_count sat still. After
    // STALE_RESYNC_LIMIT consecutive stale events it adopts the current
    // sequence number instead, and counts that it did so.
    begin
      do_reset();
      feed(16'd1000);
      check("watchdog: baseline", last_err.stale === 1'b0);
      for (int k = 0; k < 15; k++) feed(16'd500 + SEQ_W'(k));
      check("watchdog: still stale before the limit", last_err.stale === 1'b1);
      check("watchdog: no resync yet", resync_count === 32'd0);
      feed(16'd515);
      check("watchdog: resync counted", resync_count === 32'd1);
      feed(16'd516);
      check("watchdog: recovered, next event in order",
            last_err.gap === 1'b0 && last_err.stale === 1'b0);
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

    // --- a stale event straddling the wrap ----------------------------
    do_reset();
    feed(16'h0002);
    feed(16'hFFFE);   // 5 behind, across the wrap
    check("stale across wrap flagged", last_err.stale === 1'b1);
    check("stale across wrap: missed unchanged", missed_total === '0);
    feed(16'h0003);
    check("expectation survived wrapped stale", last_err.gap === 1'b0);

    // --- backpressure: a stalled event is classified and counted ONCE -
    //
    // The counters key off `accept` (s_valid && s_ready), not s_valid. If that
    // ever regresses to s_valid alone, a gap event held for four stall cycles
    // increments gap_count four times and missed_total four times over. No
    // other test in this suite can see that, because no other test deasserts
    // m_ready.
    do_reset();
    feed(16'd200);
    // Park event 201 at the output so s_ready goes low.
    m_ready = 1'b0;
    offer(16'd201);
    check("stall: s_ready low with output parked", s_ready === 1'b0);
    // Now offer a gap event into a blocked input and hold it there.
    fork
      offer(16'd210);            // expect is 202 here, so 202..209 = 8 missed
    join_none
    repeat (4) @(posedge clk);
    check("stall: gap not yet counted", gap_count === 32'd0);
    check("stall: missed not yet counted", missed_total === 32'd0);
    @(negedge clk);
    m_ready = 1'b1;
    wait fork;
    repeat (3) @(posedge clk);
    @(negedge clk);
    check("stall: gap counted exactly once",   gap_count    === 32'd1);
    check("stall: missed counted exactly once", missed_total === 32'd8);
    check("stall: stale_count still 0",        stale_count  === 32'd0);
    check("stall: gap flag survived the stall", last_err.gap === 1'b1);
    check("stall: seq survived the stall",      last_event.seq === 16'd210);

    // --- reset asserted mid-transaction -------------------------------
    //
    // rst_n is asynchronous. With an event parked at a stalled output, pulling
    // reset low between clock edges must clear the output and every counter
    // immediately, and must clear `primed` so the next event is a new
    // baseline rather than a gap against the old expectation.
    do_reset();
    feed(16'd300);
    feed(16'd310);                 // leaves gap_count = 1, missed = 9
    check("pre-reset gap_count", gap_count === 32'd1);
    m_ready = 1'b0;
    offer(16'd311);                // parked at the output
    @(posedge clk);
    #1;
    check("mid-transaction m_valid", m_valid === 1'b1);
    #1 rst_n = 1'b0;               // mid-cycle, nowhere near a clock edge
    #1;
    check("async reset clears m_valid without a clock edge", m_valid === 1'b0);
    check("async reset clears m_event", m_event === '0);
    check("async reset clears m_err",   m_err   === '0);
    check_counters_clear("async reset mid-transaction");
    @(negedge clk);
    m_ready = 1'b1;
    @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    @(negedge clk);
    check("no output after reset release with no input", m_valid === 1'b0);
    feed(16'd40000);               // far from the pre-reset expectation
    check("post-reset baseline: no gap",   last_err.gap   === 1'b0);
    check("post-reset baseline: no stale", last_err.stale === 1'b0);
    check_counters_clear("post-reset baseline");

    // --- counter saturation -------------------------------------------
    //
    // sat_add is the only arithmetic in this module and no other test in the
    // suite comes within nine orders of magnitude of its carry-out. Driving it
    // for real needs 2**32 missed events; missed_total is the one counter that
    // can get there in reasonable time, because a single gap contributes up to
    // 32767. 131074 maximal gaps is ~1.3 ms of simulated time.
    //
    // The reference is a 64-bit sum kept here, deliberately wider than the
    // counter, so "saturated" is checked against a value that cannot itself
    // have wrapped. sat_add is shared by all four counters, so proving the
    // carry path on missed_total proves it for gap_count, stale_count and
    // bad_event_count too.
    begin
      longint unsigned ref_missed;
      longint unsigned expected;
      logic [SEQ_W-1:0] nxt;
      int unsigned n_gaps, n_sat;
      bit saw_saturation;

      do_reset();
      feed(16'd0);                 // baseline: expect = 1
      ref_missed     = 0;
      n_gaps         = 0;
      nxt            = 16'd0;
      saw_saturation = 1'b0;
      n_sat          = int'(CNT_MAX / longint'(SAT_STEP)) + 8;

      // Back-to-back accepts, one per cycle: valid stays high and m_ready is
      // high, so s_ready is high on every cycle.
      @(negedge clk);
      s_event       = '0;
      s_event.etype = EVT_ADD;
      s_event.side  = SIDE_BID;
      s_valid       = 1'b1;
      for (int unsigned i = 0; i < n_sat; i++) begin
        // Each event advances seq by 32768, which makes diff exactly +32767.
        nxt         = nxt + 16'd32768;
        s_event.seq = nxt;
        @(posedge clk);            // accepted; the counter updates on this edge
        @(negedge clk);
        ref_missed = ref_missed + longint'(SAT_STEP);
        n_gaps     = n_gaps + 1;
        expected   = (ref_missed > CNT_MAX) ? CNT_MAX : ref_missed;
        if (expected == CNT_MAX) saw_saturation = 1'b1;
        // Compared every single event, not just at the end: a counter that
        // wrapped and climbed back up would pass an end-of-run check.
        if (missed_total !== expected[CNT_W-1:0]) begin
          errors++;
          $error("FAIL: missed_total %0d != reference %0d after %0d gaps",
                 missed_total, expected, n_gaps);
          break;
        end
      end
      s_valid = 1'b0;
      @(posedge clk);
      @(negedge clk);
      check("saturation was actually reached", saw_saturation === 1'b1);
      check("missed_total pegged at all ones", missed_total === {CNT_W{1'b1}});
      check("gap_count tracked every gap without saturating",
            gap_count === n_gaps);
      $display("INFO: saturation phase drove %0d maximal gaps, reference sum %0d",
               n_gaps, ref_missed);

      // One more maximal gap must leave it pegged, not roll over to a small
      // value -- the whole point of saturating telemetry.
      nxt = nxt + 16'd32768;
      feed(nxt);
      check("missed_total stays pegged after another gap",
            missed_total === {CNT_W{1'b1}});
      check("missed_total did not wrap to a small value",
            missed_total > 32'd1000);
    end

    if (errors != 0) $fatal(1, "FAIL: %0d of %0d checks failed", errors, checks);
    $display("INFO: %0d output handoffs observed", handoffs);
    $display("PASS: tb_sequence_checker (%0d checks)", checks);
    $finish;
  end

  initial begin
    #10000000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
