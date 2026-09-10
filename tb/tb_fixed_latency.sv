// tb_fixed_latency.sv -- measure input-to-output latency event by event and
// require min == mean == max == LATENCY_CYCLES.
//
// Why this exists as its own top:
//
//   * scripts/analyze_latency.py is not on this branch (the delivery plan puts
//     it with feat/book-features), so there is no tool yet to turn simulation
//     telemetry into a histogram. Until there is, the histogram is computed
//     here and printed in a form that script can later be pointed at. The
//     latency claim is the headline result of the project; it should not go
//     unmeasured for a branch just because its reporting tool is scheduled
//     later.
//
//   * tb/assertions.sv already proves "an accept is followed by m_valid
//     exactly LATENCY cycles later" per stage. That is a property, not a
//     measurement -- it produces no number to put in a document, and it says
//     nothing about the two stages composed.
//
//   * The stimulus deliberately mixes in-order, gapped, stale and malformed
//     events. "Structural latency is independent of the data" is a claim this
//     project makes; measuring it on a clean stream would not test it.
//
// m_ready is held high for the entire run. That is the documented condition on
// the latency claim, not a convenience: under backpressure the number is a
// function of the stall pattern and the claim is explicitly not made.
module tb_fixed_latency;
  import market_pkg::*;

  localparam int N_EVENTS = 2000;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [EVENT_W-1:0] s_data;
  logic               s_valid, s_ready;

  // The full pipeline as built today: decode -> sequence -> book -> features.
  // Latency is measured across all four, so LATENCY_CYCLES is proven end to
  // end rather than inferred by adding up the per-stage binds.
  market_event_t      d_event, q_event, b_event, m_event;
  event_err_t         d_err, q_err, b_err, m_err;
  logic               d_valid, d_ready, q_valid, q_ready;
  logic               b_valid, b_ready, m_valid, m_ready;
  book_t              b_book;
  logic               b_book_stale;
  feature_t           m_feat;
  logic [CNT_W-1:0]   gap_count, stale_count, missed_total, bad_event_count;
  logic [CNT_W-1:0]   resync_count;

  event_decoder u_dec (
    .clk(clk), .rst_n(rst_n),
    .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
    .m_event(d_event), .m_err(d_err), .m_valid(d_valid), .m_ready(d_ready)
  );

  sequence_checker u_seq (
    .clk(clk), .rst_n(rst_n),
    .s_event(d_event), .s_err(d_err), .s_valid(d_valid), .s_ready(d_ready),
    .m_event(q_event), .m_err(q_err), .m_valid(q_valid), .m_ready(q_ready),
    .resync_count(resync_count),
    .gap_count(gap_count), .stale_count(stale_count),
    .missed_total(missed_total), .bad_event_count(bad_event_count)
  );

  top_of_book u_tob (
    .clk(clk), .rst_n(rst_n),
    .s_event(q_event), .s_err(q_err), .s_valid(q_valid), .s_ready(q_ready),
    .m_event(b_event), .m_err(b_err), .m_book(b_book),
    .m_book_stale(b_book_stale), .m_valid(b_valid), .m_ready(b_ready)
  );

  feature_engine u_feat (
    .clk(clk), .rst_n(rst_n),
    .s_event(b_event), .s_err(b_err), .s_book(b_book),
    .s_book_stale(b_book_stale), .s_valid(b_valid), .s_ready(b_ready),
    .m_event(m_event), .m_err(m_err), .m_feat(m_feat),
    .m_valid(m_valid), .m_ready(m_ready)
  );

  // Deterministic stimulus randomization; see tb_decode_validate for why the
  // simulator's RNG is not used.
  function automatic int unsigned xorshift32(ref int unsigned state);
    state = state ^ (state << 13);
    state = state ^ (state >> 17);
    state = state ^ (state << 5);
    return state;
  endfunction

  function automatic int unsigned rand_range(ref int unsigned state,
                                             input int unsigned lo,
                                             input int unsigned hi);
    return lo + (xorshift32(state) % (hi - lo + 1));
  endfunction

  int unsigned rng;
  int seed = 1;

  // Free-running cycle counter: the timebase every measurement is taken in.
  longint unsigned cycle;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle <= 0;
    else        cycle <= cycle + 1;
  end

  longint unsigned ingress_q [$];
  longint unsigned lat_min, lat_max, lat_sum;
  int unsigned     measured;
  int unsigned     hist [0:15];      // latency in cycles -> count
  int              errors;

  // Ingress and egress timestamps, taken on the handshake edges themselves.
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (m_valid && m_ready) begin
        if (ingress_q.size() == 0) begin
          errors++;
          $error("FAIL: output at cycle %0d with nothing in flight", cycle);
        end else begin
          longint unsigned t_in, lat;
          t_in = ingress_q.pop_front();
          lat  = cycle - t_in;
          measured++;
          lat_sum += lat;
          if (lat < lat_min) lat_min = lat;
          if (lat > lat_max) lat_max = lat;
          if (lat < 16) hist[lat[3:0]]++;
          else begin
            errors++;
            $error("FAIL: latency %0d cycles is off the histogram", lat);
          end
        end
      end
      if (s_valid && s_ready) ingress_q.push_back(cycle);
    end
  end

  // Stimulus: a mix of in-order, gapped, stale and malformed events, so the
  // measurement covers every classification the pipeline can produce.
  function automatic logic [EVENT_W-1:0] mk_event(int unsigned i);
    logic [EVENT_W-1:0] w;
    logic [TYPE_W-1:0]  t;
    logic [SIDE_W-1:0]  sd;
    logic [RSV_W-1:0]   rv;
    logic [SEQ_W-1:0]   sq;
    int unsigned        roll;

    roll = rand_range(rng, 0, 99);
    sq   = 16'(i);
    if      (roll < 8)  sq = 16'(i + rand_range(rng, 2, 40));   // gap
    else if (roll < 16) sq = 16'(i - rand_range(rng, 1, 20));   // stale

    roll = rand_range(rng, 0, 99);
    t  = (roll < 6) ? 8'hFF : 8'(1 + (i % 3));
    roll = rand_range(rng, 0, 99);
    sd = (roll < 6) ? 2'b11 : ((i % 2 != 0) ? SIDE_BID : SIDE_ASK);
    roll = rand_range(rng, 0, 99);
    rv = (roll < 4) ? 2'b01 : 2'b00;

    w = '0;
    w[TYPE_LSB   +: TYPE_W]   = t;
    w[SYMBOL_LSB +: SYMBOL_W] = 4'(i);
    w[SIDE_LSB   +: SIDE_W]   = sd;
    w[PRICE_LSB  +: PRICE_W]  = 16'(i * 7);
    w[QTY_LSB    +: QTY_W]    = 16'(i * 13);
    w[SEQ_LSB    +: SEQ_W]    = sq;
    w[RSV_LSB    +: RSV_W]    = rv;
    return w;
  endfunction

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    rng      = seed ^ 32'h1234_5678;
    lat_min  = 64'hFFFF_FFFF_FFFF_FFFF;
    lat_max  = 0;
    lat_sum  = 0;
    measured = 0;
    errors   = 0;
    foreach (hist[i]) hist[i] = 0;
    $display("INFO: seed=%0d LATENCY_CYCLES=%0d (LAT_DECODE=%0d + LAT_SEQCHK=%0d + LAT_TOB=%0d + LAT_FEATURE=%0d)",
             seed, LATENCY_CYCLES, LAT_DECODE, LAT_SEQCHK, LAT_TOB, LAT_FEATURE);

    m_ready = 1'b1;      // held high for the whole run: the stated condition
    s_valid = 1'b0;
    s_data  = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    for (int unsigned i = 0; i < N_EVENTS; i++) begin
      // Idle gaps on the input side are allowed and must not change latency;
      // only stalls on the OUTPUT side would, and there are none here.
      if (rand_range(rng, 0, 3) == 0) begin
        @(negedge clk);
        s_valid = 1'b0;
        repeat (rand_range(rng, 1, 4)) @(posedge clk);
      end
      @(negedge clk);
      s_data  = mk_event(i);
      s_valid = 1'b1;
      @(posedge clk);
    end
    @(negedge clk);
    s_valid = 1'b0;

    // Drain.
    repeat (LATENCY_CYCLES + 8) @(posedge clk);

    if (measured != N_EVENTS) begin
      errors++;
      $error("FAIL: measured %0d latencies for %0d events", measured, N_EVENTS);
    end
    if (ingress_q.size() != 0) begin
      errors++;
      $error("FAIL: %0d events never came out", ingress_q.size());
    end

    $display("INFO: latency histogram (cycles: count)");
    foreach (hist[i]) if (hist[i] != 0) $display("INFO:   %0d: %0d", i, hist[i]);
    $display("INFO: latency min=%0d mean=%0d max=%0d over %0d events",
             lat_min, (measured == 0) ? 64'd0 : lat_sum / longint'(measured), lat_max,
             measured);
    $display("INFO: at the Basys 3's fixed 100 MHz that is %0d ns",
             lat_max * 10);
    $display("INFO: classification mix gap=%0d stale=%0d bad=%0d (latency must be independent of these)",
             gap_count, stale_count, bad_event_count);

    // min == mean == max is the whole claim. Integer division would hide a
    // handful of slow events inside the mean, so compare min and max directly
    // and require the mean to sit on the same integer.
    if (lat_min !== lat_max) begin
      errors++;
      $error("FAIL: latency is not fixed: min=%0d max=%0d", lat_min, lat_max);
    end
    if (lat_max !== longint'(LATENCY_CYCLES)) begin
      errors++;
      $error("FAIL: measured latency %0d != LATENCY_CYCLES %0d",
             lat_max, LATENCY_CYCLES);
    end
    if (measured != 0 && (lat_sum != longint'(measured) * LATENCY_CYCLES)) begin
      errors++;
      $error("FAIL: latency sum %0d != %0d events x %0d cycles",
             lat_sum, measured, LATENCY_CYCLES);
    end

    if (errors != 0) $fatal(1, "FAIL: %0d latency errors (seed=%0d)", errors, seed);
    $display("PASS: tb_fixed_latency -- %0d events, min=mean=max=%0d cycles, seed=%0d",
             measured, lat_max, seed);
    $finish;
  end

  initial begin
    #2000000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
