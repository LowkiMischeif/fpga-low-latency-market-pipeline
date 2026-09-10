// Randomized replay of a generated trace through event_decoder ->
// sequence_checker, with randomized valid gaps and randomized backpressure.
// Every output is scoreboarded against the golden expectations from
// scripts/generate_events.py.
//
// The golden CSV and the RTL could in principle be wrong in the same way,
// which is why tb_event_decoder.sv and tb_sequence_checker.sv carry
// hand-written vectors and tb/assertions.sv carries trace-independent
// properties.
//
// This file adds a third guard against that failure mode: before a single
// event is driven, every row of the golden CSV is re-derived HERE from the raw
// hex word -- field slices taken from the spec's bit table, and a sequence
// model written from the spec's condition/action table -- and any disagreement
// is fatal. So the run compares three independent things:
//
//     hex word --(this file's reference)--> flags
//              --(generate_events.py)-----> flags      (must agree, checked at load)
//              --(the RTL)----------------> flags      (must agree, checked per event)
//
// A generator bug now has to be reproduced identically in Python, in this
// testbench and in the RTL to go unnoticed.
module tb_decode_validate;
  import market_pkg::*;

  localparam int MAX_EVENTS = 8192;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [EVENT_W-1:0] s_data;
  logic               s_valid, s_ready;

  market_event_t      d_event, m_event;
  event_err_t         d_err, m_err;
  logic               d_valid, d_ready, m_valid, m_ready;
  logic [CNT_W-1:0]   gap_count, stale_count, missed_total, bad_event_count;

  event_decoder u_dec (
    .clk(clk), .rst_n(rst_n),
    .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
    .m_event(d_event), .m_err(d_err), .m_valid(d_valid), .m_ready(d_ready)
  );

  sequence_checker u_seq (
    .clk(clk), .rst_n(rst_n),
    .s_event(d_event), .s_err(d_err), .s_valid(d_valid), .s_ready(d_ready),
    .m_event(m_event), .m_err(m_err), .m_valid(m_valid), .m_ready(m_ready),
    .gap_count(gap_count), .stale_count(stale_count),
    .missed_total(missed_total), .bad_event_count(bad_event_count)
  );

  // No bind statements here: tb/bind_assertions.sv binds the checker to both
  // stages for the whole compiled library.

  logic [EVENT_W-1:0] trace_words [0:MAX_EVENTS-1];
  int exp_etype  [0:MAX_EVENTS-1];
  int exp_symbol [0:MAX_EVENTS-1];
  int exp_side   [0:MAX_EVENTS-1];
  int exp_price  [0:MAX_EVENTS-1];
  int exp_qty    [0:MAX_EVENTS-1];
  int exp_seq    [0:MAX_EVENTS-1];
  int exp_btype  [0:MAX_EVENTS-1];
  int exp_bside  [0:MAX_EVENTS-1];
  int exp_brsv   [0:MAX_EVENTS-1];
  int exp_gap    [0:MAX_EVENTS-1];
  int exp_stale  [0:MAX_EVENTS-1];

  // Reference model results, derived here from trace_words alone.
  bit ref_gap   [0:MAX_EVENTS-1];
  bit ref_stale [0:MAX_EVENTS-1];
  longint unsigned ref_gap_count, ref_stale_count, ref_missed_total,
                   ref_bad_count;

  // ------------------------------------------------------------------
  // Deterministic stimulus randomization.
  //
  // The simulator's own RNG is not used. xsim rejects the seeding form
  // $urandom(seed) outright, and even where it is accepted the $urandom
  // stream depends on process creation order, so "seed=N" printed in the log
  // would not reliably reproduce a failure -- which is the entire reason the
  // seed is printed. A 32-bit xorshift written here does reproduce, in any
  // simulator, from the seed alone.
  // ------------------------------------------------------------------
  function automatic int unsigned xorshift32(ref int unsigned state);
    state = state ^ (state << 13);
    state = state ^ (state >> 17);
    state = state ^ (state << 5);
    return state;
  endfunction

  // `input` is explicit on lo/hi: without it they inherit the preceding
  // argument's `ref` direction and the call sites become illegal.
  function automatic int unsigned rand_range(ref int unsigned state,
                                             input int unsigned lo,
                                             input int unsigned hi);
    return lo + (xorshift32(state) % (hi - lo + 1));
  endfunction

  int unsigned drv_rng, bp_rng;

  int n_events = 0;
  int seed = 1;
  int errors = 0;
  int sent = 0, recvd = 0;
  int stall_cycles = 0, idle_cycles = 0, held_valid_cycles = 0;
  bit loaded = 1'b0;

  // Read the golden CSV. Column order must match CSV_COLUMNS in
  // generate_events.py.
  task automatic load_expected(string path);
    int fd, r, w;
    string line;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "FAIL: cannot open %s", path);
    r = $fgets(line, fd);              // header
    n_events = 0;
    while ($fgets(line, fd) != 0) begin
      r = $sscanf(line, "%h,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
                  w,
                  exp_etype[n_events], exp_symbol[n_events], exp_side[n_events],
                  exp_price[n_events], exp_qty[n_events], exp_seq[n_events],
                  exp_btype[n_events], exp_bside[n_events], exp_brsv[n_events],
                  exp_gap[n_events], exp_stale[n_events]);
      if (r != 12)
        $fatal(1, "FAIL: malformed CSV row %0d (parsed %0d of 12 fields)",
               n_events, r);
      n_events++;
      if (n_events >= MAX_EVENTS) $fatal(1, "FAIL: trace exceeds MAX_EVENTS");
    end
    $fclose(fd);
  endtask

  // ------------------------------------------------------------------
  // Independent reference model.
  //
  // Field slices come from the design spec's bit table, not from
  // market_pkg's *_LSB constants. The sequence rules come from the spec's
  // condition/action table:
  //
  //     rx == expect : in order, expect := rx + 1
  //     rx >  expect : gap,      missed += rx - expect, expect := rx + 1
  //     rx <  expect : stale,    expect unchanged
  //
  // with ">" and "<" evaluated on the 16-bit modular difference read as
  // signed, and with the first event after reset adopted as the baseline.
  // ------------------------------------------------------------------
  // One disagreement between the golden CSV and the reference model, reported
  // with enough context to find the row in the CSV by eye.
  task automatic audit(int idx, string field, logic [15:0] golden,
                       logic [15:0] reference, ref int nerr);
    if (golden !== reference) begin
      nerr++;
      $error("GOLDEN[%0d]: %s = %0h, testbench reference says %0h",
             idx, field, golden, reference);
    end
  endtask

  task automatic build_reference_and_audit_golden();
    logic [EVENT_W-1:0]      w;
    logic [SEQ_W-1:0]        rx, expect_ref;
    logic signed [SEQ_W-1:0] diff;
    bit                      primed_ref;
    bit                      r_btype, r_bside, r_brsv;
    int                      audit_errs;

    expect_ref       = '0;
    primed_ref       = 1'b0;
    ref_gap_count    = 0;
    ref_stale_count  = 0;
    ref_missed_total = 0;
    ref_bad_count    = 0;
    audit_errs       = 0;

    for (int i = 0; i < n_events; i++) begin
      w  = trace_words[i];
      rx = w[17:2];

      r_btype = !(w[63:56] inside {8'h01, 8'h02, 8'h03});
      r_bside = !(w[51:50] inside {2'b01, 2'b10});
      r_brsv  = (w[1:0] != 2'b00);

      diff = $signed(rx - expect_ref);
      ref_gap[i]   = primed_ref && (diff > 0);
      ref_stale[i] = primed_ref && (diff < 0);
      if (!primed_ref || (diff >= 0)) expect_ref = rx + 1'b1;
      primed_ref = 1'b1;

      if (ref_gap[i]) begin
        ref_gap_count++;
        ref_missed_total += longint'(diff);
      end
      if (ref_stale[i]) ref_stale_count++;
      if (r_btype || r_bside || r_brsv) ref_bad_count++;

      // --- audit the golden CSV against the reference ---------------
      audit(i, "etype",    exp_etype[i][TYPE_W-1:0],   w[63:56], audit_errs);
      audit(i, "symbol",   exp_symbol[i][SYMBOL_W-1:0],w[55:52], audit_errs);
      audit(i, "side",     exp_side[i][SIDE_W-1:0],    w[51:50], audit_errs);
      audit(i, "price",    exp_price[i][PRICE_W-1:0],  w[49:34], audit_errs);
      audit(i, "qty",      exp_qty[i][QTY_W-1:0],      w[33:18], audit_errs);
      audit(i, "seq",      exp_seq[i][SEQ_W-1:0],      rx,       audit_errs);
      audit(i, "bad_type", {15'd0, exp_btype[i][0]},   {15'd0, r_btype},     audit_errs);
      audit(i, "bad_side", {15'd0, exp_bside[i][0]},   {15'd0, r_bside},     audit_errs);
      audit(i, "bad_rsv",  {15'd0, exp_brsv[i][0]},    {15'd0, r_brsv},      audit_errs);
      audit(i, "gap",      {15'd0, exp_gap[i][0]},     {15'd0, ref_gap[i]},  audit_errs);
      audit(i, "stale",    {15'd0, exp_stale[i][0]},   {15'd0, ref_stale[i]},audit_errs);
    end

    if (audit_errs != 0)
      $fatal(1, "FAIL: %0d disagreements between the golden CSV and the testbench reference model -- the generator and the RTL are no longer describing the same protocol", audit_errs);

    $display("INFO: golden CSV audited against the testbench reference model: %0d events agree",
             n_events);
    $display("INFO: reference totals gap=%0d stale=%0d missed=%0d bad=%0d",
             ref_gap_count, ref_stale_count, ref_missed_total, ref_bad_count);
  endtask

  initial begin
    string hex_path, csv_path;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    if (!$value$plusargs("HEX=%s", hex_path)) hex_path = "tb/traces/random.hex";
    if (!$value$plusargs("CSV=%s", csv_path))
      csv_path = "tb/traces/random_expected.csv";
    // xorshift32 degenerates from a zero state, so fold in a nonzero constant.
    drv_rng = seed ^ 32'h9E37_79B9;
    bp_rng  = seed ^ 32'h5EED_BEEF;
    $display("INFO: seed=%0d hex=%s csv=%s", seed, hex_path, csv_path);
    $display("INFO: reproduce with: make trace SEED=<trace seed> && make sim TOP=tb_decode_validate PLUSARGS=\"SEED=%0d\"",
             seed);
    for (int i = 0; i < MAX_EVENTS; i++) trace_words[i] = 'x;
    $readmemh(hex_path, trace_words);
    load_expected(csv_path);
    // A hex file longer than the CSV would silently drop events off the end of
    // the scoreboard, and the run would still be green.
    if (n_events < MAX_EVENTS && !$isunknown(trace_words[n_events]))
      $fatal(1, "FAIL: %s has more events than %s has rows (%0d)",
             hex_path, csv_path, n_events);
    if ($isunknown(trace_words[n_events - 1]))
      $fatal(1, "FAIL: %s has fewer events than %s has rows (%0d)",
             hex_path, csv_path, n_events);
    $display("INFO: loaded %0d events", n_events);
    build_reference_and_audit_golden();
    loaded = 1'b1;
  end

  // ------------------------------------------------------------------
  // Driver: randomized valid gaps, valid HELD across stalls.
  //
  // The previous version asserted s_valid for exactly one cycle after seeing
  // s_ready high, so s_valid was never high while s_ready was low. That made
  // a_no_valid_retraction_in and a_in_payload_stable vacuous at the decoder
  // input and meant no event ever had to survive a stall at the top of the
  // pipe. Holding valid until accepted is both the legal handshake and the
  // stimulus those properties need.
  // ------------------------------------------------------------------
  initial begin
    s_valid = 1'b0;
    s_data  = '0;
    wait (loaded);
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    while (sent < n_events) begin
      if (rand_range(drv_rng, 0, 3) == 0) begin
        @(negedge clk);
        s_valid = 1'b0;
        repeat (rand_range(drv_rng, 1, 3)) begin
          @(posedge clk);
          idle_cycles++;
        end
      end
      @(negedge clk);
      s_data  = trace_words[sent];
      s_valid = 1'b1;
      #1;                             // let the negedge-driven m_ready settle
      while (!s_ready) begin
        @(posedge clk);               // stalled: valid and payload held
        held_valid_cycles++;
        @(negedge clk);
        #1;
      end
      @(posedge clk);                 // accepted on this edge
      sent++;
    end
    @(negedge clk);
    s_valid = 1'b0;
  end

  // Backpressure: randomly deassert m_ready to prove the pipe stalls as a
  // unit without losing or reordering events.
  //
  // Driven on the NEGEDGE. Assigning m_ready at the posedge races both the
  // DUT and the scoreboard, which sample it on that same edge -- the symptom
  // is outputs that appear to duplicate and a scoreboard that drifts behind
  // the trace.
  initial begin
    m_ready = 1'b1;
    forever begin
      @(negedge clk);
      if (rand_range(bp_rng, 0, 4) == 0) begin
        m_ready = 1'b0;
        repeat (rand_range(bp_rng, 1, 6)) begin
          @(negedge clk);
          stall_cycles++;
        end
        m_ready = 1'b1;
      end
    end
  end

  // Scoreboard: every handed-off output must match the golden row, in order.
  always_ff @(posedge clk) begin
    if (rst_n && m_valid && m_ready) begin
      if (recvd >= n_events) begin
        errors++;
        $error("FAIL: extra output beyond %0d events", n_events);
      end else begin
        if (m_event.etype  !== exp_etype[recvd][TYPE_W-1:0])    begin errors++; $error("FAIL[%0d]: etype exp %0h got %0h",    recvd, exp_etype[recvd],  m_event.etype);  end
        if (m_event.symbol !== exp_symbol[recvd][SYMBOL_W-1:0]) begin errors++; $error("FAIL[%0d]: symbol exp %0h got %0h",   recvd, exp_symbol[recvd], m_event.symbol); end
        if (m_event.side   !== exp_side[recvd][SIDE_W-1:0])     begin errors++; $error("FAIL[%0d]: side exp %0h got %0h",     recvd, exp_side[recvd],   m_event.side);   end
        if (m_event.price  !== exp_price[recvd][PRICE_W-1:0])   begin errors++; $error("FAIL[%0d]: price exp %0h got %0h",    recvd, exp_price[recvd],  m_event.price);  end
        if (m_event.qty    !== exp_qty[recvd][QTY_W-1:0])       begin errors++; $error("FAIL[%0d]: qty exp %0h got %0h",      recvd, exp_qty[recvd],    m_event.qty);    end
        if (m_event.seq    !== exp_seq[recvd][SEQ_W-1:0])       begin errors++; $error("FAIL[%0d]: seq exp %0h got %0h",      recvd, exp_seq[recvd],    m_event.seq);    end
        if (m_err.bad_type !== exp_btype[recvd][0])             begin errors++; $error("FAIL[%0d]: bad_type exp %0d got %0b", recvd, exp_btype[recvd],  m_err.bad_type); end
        if (m_err.bad_side !== exp_bside[recvd][0])             begin errors++; $error("FAIL[%0d]: bad_side exp %0d got %0b", recvd, exp_bside[recvd],  m_err.bad_side); end
        if (m_err.bad_rsv  !== exp_brsv[recvd][0])              begin errors++; $error("FAIL[%0d]: bad_rsv exp %0d got %0b",  recvd, exp_brsv[recvd],   m_err.bad_rsv);  end
        if (m_err.gap      !== exp_gap[recvd][0])               begin errors++; $error("FAIL[%0d]: gap exp %0d got %0b",      recvd, exp_gap[recvd],    m_err.gap);      end
        if (m_err.stale    !== exp_stale[recvd][0])             begin errors++; $error("FAIL[%0d]: stale exp %0d got %0b",    recvd, exp_stale[recvd],  m_err.stale);    end
        recvd++;
      end
    end
  end

  initial begin
    wait (loaded);
    wait (recvd == n_events);
    repeat (5) @(posedge clk);

    // Telemetry: the counters are output ports that nothing else in this
    // testbench checks, and the directed testbench only ever drives them to
    // single digits. Compare them against the reference totals.
    if (gap_count !== ref_gap_count[CNT_W-1:0]) begin
      errors++;
      $error("FAIL: gap_count %0d, reference %0d", gap_count, ref_gap_count);
    end
    if (stale_count !== ref_stale_count[CNT_W-1:0]) begin
      errors++;
      $error("FAIL: stale_count %0d, reference %0d", stale_count, ref_stale_count);
    end
    if (missed_total !== ref_missed_total[CNT_W-1:0]) begin
      errors++;
      $error("FAIL: missed_total %0d, reference %0d", missed_total, ref_missed_total);
    end
    if (bad_event_count !== ref_bad_count[CNT_W-1:0]) begin
      errors++;
      $error("FAIL: bad_event_count %0d, reference %0d", bad_event_count, ref_bad_count);
    end

    // Coverage floor. A "randomized" run that happened to stall zero times,
    // or that saw no gap and no stale event, is not the test this file claims
    // to be, and it must not be reported as one.
    if (stall_cycles == 0) begin
      errors++;
      $error("FAIL: backpressure never asserted -- the stall properties were vacuous this run");
    end
    if (held_valid_cycles == 0) begin
      errors++;
      $error("FAIL: s_valid was never held across a stall -- the input-side handshake properties were vacuous this run");
    end
    if (ref_gap_count == 0 || ref_stale_count == 0 || ref_bad_count == 0) begin
      errors++;
      $error("FAIL: trace lacks gap/stale/malformed events (gap=%0d stale=%0d bad=%0d)",
             ref_gap_count, ref_stale_count, ref_bad_count);
    end

    if (errors != 0)
      $fatal(1, "FAIL: %0d mismatches over %0d events (seed=%0d)",
             errors, n_events, seed);
    $display("INFO: gap_count=%0d stale_count=%0d missed_total=%0d bad_event_count=%0d",
             gap_count, stale_count, missed_total, bad_event_count);
    $display("INFO: coverage stall_cycles=%0d idle_cycles=%0d held_valid_cycles=%0d",
             stall_cycles, idle_cycles, held_valid_cycles);
    $display("PASS: tb_decode_validate -- %0d events, seed=%0d", n_events, seed);
    $finish;
  end

  initial begin
    #20000000;
    $fatal(1, "FAIL: timeout -- sent=%0d recvd=%0d of %0d", sent, recvd, n_events);
  end
endmodule
