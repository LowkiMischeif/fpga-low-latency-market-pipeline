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

  // The full pipeline as built today: decode -> sequence -> book -> features
  // -> policy -> risk. Latency is measured across all six, so LATENCY_CYCLES
  // is proven end to end rather than inferred by adding up the per-stage
  // binds.
  market_event_t      d_event, q_event, b_event, m_event;
  event_err_t         d_err, q_err, b_err, m_err;
  logic               d_valid, d_ready, q_valid, q_ready;
  logic               b_valid, b_ready, m_valid, m_ready;
  book_t              b_book;
  logic               b_book_stale;
  market_event_t      f_event, p_event;
  event_err_t         f_err, p_err;
  feature_t           f_feat, p_feat, m_feat;
  logic               f_valid, f_ready, p_valid, p_ready;
  decision_e          p_decision;
  logic signed [SCORE_W-1:0] p_score;
  logic [QTY_W-1:0]          p_order_qty;
  decision_t          m_dec;
  logic               cfg_boundary;
  risk_cfg_t          p_risk_cfg;
  logic [CFG_ADDR_W-1:0] cfg_addr;
  logic [CFG_DATA_W-1:0] cfg_wdata;
  logic                  cfg_we;
  policy_cfg_t           policy_cfg;
  risk_cfg_t             risk_cfg;
  logic [CNT_W-1:0]      commit_count;

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
    .m_event(f_event), .m_err(f_err), .m_feat(f_feat),
    .m_valid(f_valid), .m_ready(f_ready)
  );

  policy_engine u_pol (
    .clk(clk), .rst_n(rst_n), .cfg(policy_cfg), .risk_cfg_in(risk_cfg),
    .s_event(f_event), .s_err(f_err), .s_feat(f_feat),
    .s_valid(f_valid), .s_ready(f_ready),
    .m_event(p_event), .m_err(p_err), .m_feat(p_feat),
    .m_decision(p_decision), .m_score(p_score), .m_order_qty(p_order_qty),
    .m_valid(p_valid), .m_ready(p_ready), .cfg_boundary(cfg_boundary),
    .m_risk_cfg(p_risk_cfg)
  );

  risk_gate u_risk (
    .clk(clk), .rst_n(rst_n), .cfg(p_risk_cfg),
    .s_event(p_event), .s_err(p_err), .s_feat(p_feat),
    .s_decision(p_decision), .s_score(p_score), .s_order_qty(p_order_qty),
    .s_valid(p_valid), .s_ready(p_ready),
    .m_event(m_event), .m_err(m_err), .m_feat(m_feat),
    .m_decision(m_dec), .m_valid(m_valid), .m_ready(m_ready)
  );

  config_regs u_cfg (
    .clk(clk), .rst_n(rst_n),
    .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_we(cfg_we),
    .boundary(cfg_boundary),
    .policy_cfg(policy_cfg), .risk_cfg(risk_cfg), .commit_count(commit_count)
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

  // Datapath coverage. Without these the run happily measured 5 cycles across
  // a feature engine that emitted zeros for every one of 2000 events.
  int cov_two_sided, cov_imb_nonzero, cov_mom_nonzero, cov_spread_nonzero;
  int cov_buy, cov_sell, cov_hold, cov_rejected;

  task automatic cfg_wr(cfg_addr_e a, int unsigned d);
    @(negedge clk);
    cfg_addr = a; cfg_wdata = CFG_DATA_W'(d); cfg_we = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cfg_we = 1'b0;
  endtask

  // Program a policy that actually trades. Leaving the reset configuration in
  // place would make every decision a kill-switch HOLD, and the run would
  // measure a fixed latency across a policy that never decided anything --
  // the same trap the feature datapath fell into before its coverage floor.
  task automatic program_live_policy();
    cfg_wr(CFG_W0,            32'h0000_0000);
    cfg_wr(CFG_W_SPREAD,      32'hFFFF_F000);   // -1.0: wide spread discourages
    cfg_wr(CFG_W_IMBALANCE,   32'h0000_2000);   //  2.0 on imbalance
    cfg_wr(CFG_W_MOMENTUM,    32'h0000_1000);   //  1.0 on momentum
    cfg_wr(CFG_THETA_BUY,     32'd2000);
    cfg_wr(CFG_THETA_SELL,    32'hFFFF_F830);   // -2000
    cfg_wr(CFG_ORDER_QTY,     32'd5);
    cfg_wr(CFG_MAX_LONG,      32'd1000000);
    cfg_wr(CFG_MAX_SHORT,     32'd1000000);
    cfg_wr(CFG_MAX_ORDER_QTY, 32'd100);
    cfg_wr(CFG_MAX_SPREAD,    32'd20000);
    cfg_wr(CFG_KILL,          32'd0);
    cfg_wr(CFG_COMMIT,        32'd1);
    repeat (4) @(posedge clk);
  endtask
  int unsigned     measured;
  int unsigned     hist [0:15];      // latency in cycles -> count
  int              errors;

  // Ingress and egress timestamps, taken on the handshake edges themselves.
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (m_valid && m_ready) begin
        if (!m_feat.book_empty)     cov_two_sided++;
        case (m_dec.decision)
          DEC_BUY:  cov_buy++;
          DEC_SELL: cov_sell++;
          default:  cov_hold++;
        endcase
        if (m_dec.reason != RSN_NONE) cov_rejected++;
        if (m_feat.imbalance != '0) cov_imb_nonzero++;
        if (m_feat.momentum  != '0) cov_mom_nonzero++;
        if (m_feat.spread    != '0) cov_spread_nonzero++;
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
    // Side must NOT be keyed on i alone. symbol is i mod 16 and 16 is even,
    // so any i-parity rule gives every symbol exactly one side forever,
    // both_sides is never true, and the whole feature datapath -- ROM,
    // multiply, clamps, spread, midpoint, momentum -- stays inert while the
    // run still reports PASS. That is exactly what this testbench did before:
    // 2000 events, book_empty on all 2000 outputs, imbalance identically zero.
    // The coverage floor at the end of the run now fails if that recurs.
    sd = (roll < 6) ? 2'b11 : ((rand_range(rng, 0, 1) == 0) ? SIDE_BID : SIDE_ASK);
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
    cov_buy = 0; cov_sell = 0; cov_hold = 0; cov_rejected = 0;
    cov_two_sided = 0; cov_imb_nonzero = 0;
    cov_mom_nonzero = 0; cov_spread_nonzero = 0;
    measured = 0;
    errors   = 0;
    foreach (hist[i]) hist[i] = 0;
    $display("INFO: seed=%0d LATENCY_CYCLES=%0d (decode %0d + seq %0d + book %0d + feat %0d + policy %0d + risk %0d)",
             seed, LATENCY_CYCLES, LAT_DECODE, LAT_SEQCHK, LAT_TOB,
             LAT_FEATURE, LAT_POLICY, LAT_RISK);

    m_ready = 1'b1;      // held high for the whole run: the stated condition
    s_valid = 1'b0;
    s_data  = '0;
    cfg_addr = '0; cfg_wdata = '0; cfg_we = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    program_live_policy();

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
    $display("INFO: %0d cycles x 10.0 ns = %0d ns core pipeline latency, on the",
             lat_max, lat_max * 10);
    $display("INFO: Basys 3's fixed 100 MHz oscillator. This is ARITHMETIC, NOT a");
    $display("INFO: synthesis result -- there is no market_pipeline_top and no");
    $display("INFO: measured WNS anywhere in this repo. Do not quote it as timing.");
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

    // A fixed latency measured across a pipeline whose last two stages never
    // loaded is not evidence of anything. Fail the run rather than report it.
    $display("INFO: datapath coverage two_sided=%0d imbalance!=0=%0d momentum!=0=%0d spread!=0=%0d",
             cov_two_sided, cov_imb_nonzero, cov_mom_nonzero, cov_spread_nonzero);
    if (cov_two_sided == 0) begin
      errors++;
      $error("FAIL: no output ever had a two-sided book -- the feature engine was inert");
    end
    if (cov_imb_nonzero == 0) begin
      errors++;
      $error("FAIL: imbalance was zero on every output -- reciprocal path never exercised");
    end
    if (cov_mom_nonzero == 0) begin
      errors++;
      $error("FAIL: momentum was zero on every output -- history path never exercised");
    end
    if (cov_spread_nonzero == 0) begin
      errors++;
      $error("FAIL: spread was zero on every output");
    end
    $display("INFO: decisions buy=%0d sell=%0d hold=%0d rejected=%0d commits=%0d",
             cov_buy, cov_sell, cov_hold, cov_rejected, commit_count);
    if (cov_buy == 0 && cov_sell == 0) begin
      errors++;
      $error("FAIL: every decision was HOLD -- the policy never traded, so a fixed latency across it proves nothing");
    end
    if (commit_count == 0) begin
      errors++;
      $error("FAIL: no configuration was ever committed");
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
