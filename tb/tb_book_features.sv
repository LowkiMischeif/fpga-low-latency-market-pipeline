// tb_book_features.sv -- randomized integrated replay through the whole
// pipeline as built today (decode -> sequence -> book -> features), scored
// against a reference model written from the design spec.
//
// Why this exists alongside tb_decode_validate:
//
//   * tb_decode_validate stops at sequence_checker. Nothing randomized ever
//     reached top_of_book or feature_engine; the only book and feature
//     coverage was directed, one event at a time, with m_ready nailed high.
//
//   * The stimulus is generated HERE rather than read from
//     scripts/generate_events.py, because that generator draws price from a
//     uniform 16-bit range. Under a uniform price the best bid converges to
//     the largest price drawn and no CANCEL or TRADE ever matches it again, so
//     a generated trace exercises exactly one row of the spec's update table
//     (ADD better / ADD worse) and never the other five. This file draws price
//     from a small per-symbol ladder so equal-price accumulation, cancel-at-
//     best, trade-at-best and trade-to-zero actually occur -- and then it
//     FAILS the run if they did not, rather than reporting a green replay that
//     covered one sixth of the table.
//
//   * The reference model is derived from the spec's tables (sequence
//     condition/action, the top-of-book update matrix, the feature
//     definitions), not from the RTL. Imbalance is scored against exact
//     integer division with the documented error bound, never against the
//     reciprocal ROM -- reimplementing the ROM here would only prove the ROM
//     equals itself.
//
// Backpressure is randomized throughout, so the stall properties bound into
// top_of_book and feature_engine by tb/bind_assertions.sv are live in this
// run. The coverage floor at the end fails if they were not.
module tb_book_features;
  import market_pkg::*;

  localparam int N_EVENTS = 3000;
  // Must match STALE_RESYNC_LIMIT in rtl/sequence_checker.sv.
  localparam int STALE_RESYNC_LIMIT = 16;
  // Imbalance is an approximation. The spec bounds the relative error at
  // 128/65536 of full scale (~32 counts of IMB_ONE); the arithmetic shift
  // floors where the reference truncates toward zero, worth one more count.
  localparam int IMB_TOL = 40;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [EVENT_W-1:0] s_data;
  logic               s_valid, s_ready;

  market_event_t    d_event, q_event, b_event, m_event;
  event_err_t       d_err, q_err, b_err, m_err;
  logic             d_valid, d_ready, q_valid, q_ready;
  logic             b_valid, b_ready, m_valid, m_ready;
  book_t            b_book;
  logic             b_book_stale;
  feature_t         m_feat;
  logic [CNT_W-1:0] gap_count, stale_count, missed_total, bad_event_count;
  logic [CNT_W-1:0] resync_count;

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

  // ------------------------------------------------------------------
  // Deterministic randomization. See tb_decode_validate for why the
  // simulator's own RNG is not used: xsim rejects $urandom(seed) and its
  // stream depends on process creation order, so a printed seed would not
  // reproduce the run.
  // ------------------------------------------------------------------
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

  int unsigned gen_rng, drv_rng, bp_rng;
  int seed = 1;
  int errors = 0;

  // ------------------------------------------------------------------
  // Stimulus, and the reference model for it.
  // ------------------------------------------------------------------
  logic [EVENT_W-1:0] word     [0:N_EVENTS-1];
  market_event_t      ref_event[0:N_EVENTS-1];
  event_err_t         ref_err  [0:N_EVENTS-1];
  book_t              ref_book [0:N_EVENTS-1];
  bit                 ref_bstale[0:N_EVENTS-1];
  // Features. Imbalance is kept as the EXACT value; the DUT is scored against
  // it with IMB_TOL, because the DUT deliberately approximates.
  logic signed [SPREAD_W-1:0] ref_spread[0:N_EVENTS-1];
  logic        [PRICE_W-1:0]  ref_mid   [0:N_EVENTS-1];
  logic signed [MOM_W-1:0]    ref_mom   [0:N_EVENTS-1];
  bit                         ref_empty [0:N_EVENTS-1];
  int                         ref_imb   [0:N_EVENTS-1];

  longint unsigned ref_gap_count, ref_stale_count, ref_missed_total,
                   ref_bad_count, ref_resync_count;

  // Coverage counters. Every one of these is a row of the spec that a
  // degenerate trace could silently skip, so each has a floor at the end.
  int cov_add_replace_bid, cov_add_replace_ask;
  int cov_add_accum_bid,   cov_add_accum_ask;
  int cov_add_worse;
  int cov_cancel_hit_bid,  cov_cancel_hit_ask, cov_cancel_miss;
  int cov_trade_hit_bid,   cov_trade_hit_ask,  cov_trade_miss;
  int cov_trade_to_zero,   cov_trade_floor;
  int cov_qty_sat,         cov_add_qty0,       cov_valid_side_qty0;
  int cov_crossed,         cov_den1,           cov_den2;
  int cov_empty_refill,    cov_withheld;
  int cov_spread_fullscale;
  bit cov_symbol_seen [0:N_SYMBOLS-1];

  // Per-symbol price ladder. A small ladder is the whole point: it is what
  // makes a CANCEL or a TRADE land on the current best often enough to test
  // those rows. Symbol N_SYMBOLS-1 gets an extreme ladder so full-scale
  // spreads and crossed books are reached without distorting the others.
  function automatic logic [PRICE_W-1:0] ladder(input int unsigned sym,
                                                input int unsigned k);
    if (sym == N_SYMBOLS - 1) begin
      case (k % 6)
        0: return 16'd0;
        1: return 16'd1;
        2: return 16'd32767;
        3: return 16'd32768;
        4: return 16'hFFFE;
        default: return 16'hFFFF;
      endcase
    end
    return PRICE_W'(sym * 1024 + (k % 6) * 4);
  endfunction

  // Symbol 0 is a dedicated tiny-quantity stream. den == 2 is
  // the extreme normalisation shifts (sh reaches 16, and the >>> (16 - sh)
  // term degenerates to a zero shift), and they need bid_qty + ask_qty <= 2 on
  // ONE symbol at ONE instant. Left to the general distribution that is rare
  // enough to appear on some seeds and not others -- the coverage floor below
  // caught exactly that on seed 12345. Reserving a symbol makes it reliable
  // instead of relaxing the floor.
  function automatic logic [QTY_W-1:0] pick_qty(ref int unsigned st,
                                                input int unsigned sym);
    int unsigned r;
    // Symbol 0 never draws 0: an ADD with no size is a no-op since the spec's
    // qty == 0 rule landed, so drawing zeros here made den == 2 depend on the
    // seed happening to place two sized events on opposite sides. 1..2 keeps
    // the corner reachable every run. Zero-quantity ADDs are still exercised
    // in bulk on every other symbol (cov_add_qty0).
    if (sym == 0) return QTY_W'(rand_range(st, 1, 2));
    r = rand_range(st, 0, 99);
    if (r < 15) return 16'd0;                                // ADD qty 0
    if (r < 25) return QTY_W'(rand_range(st, 1, 2));
    if (r < 35) return QTY_W'(rand_range(st, 65500, 65535)); // saturation
    return QTY_W'(rand_range(st, 1, 1000));
  endfunction

  // Exact imbalance in Q1.14 by integer division -- the definition from the
  // spec, not the reciprocal ROM the DUT uses.
  function automatic int exact_imb(input int bq, input int aq);
    if (bq + aq == 0) return 0;
    return ((bq - aq) * IMB_ONE) / (bq + aq);
  endfunction

  task automatic build_stimulus_and_reference();
    logic [SEQ_W-1:0]        rx, expect_ref;
    logic signed [SEQ_W-1:0] diff;
    bit                      primed_ref, force_resync;
    int                      stale_run;
    bit                      r_btype, r_bside, r_brsv, r_gap, r_stale;
    bit                      trusted;
    logic [TYPE_W-1:0]       t;
    logic [SIDE_W-1:0]       sd;
    logic [RSV_W-1:0]        rv;
    logic [SYMBOL_W-1:0]     sym;
    logic [PRICE_W-1:0]      px;
    logic [QTY_W-1:0]        qy;
    int unsigned             roll;
    book_t                   bk [N_SYMBOLS];
    book_t                   nb;
    logic [PRICE_W-1:0]      pm [N_SYMBOLS];
    bit                      pv [N_SYMBOLS];
    bit                      was_empty [N_SYMBOLS];
    int                      den;
    bit                      both, emp;

    expect_ref = '0; primed_ref = 1'b0; stale_run = 0;
    ref_gap_count = 0; ref_stale_count = 0; ref_missed_total = 0;
    ref_bad_count = 0; ref_resync_count = 0;
    for (int i = 0; i < N_SYMBOLS; i++) begin
      bk[i] = '0; pm[i] = '0; pv[i] = 1'b0; was_empty[i] = 1'b1;
    end

    for (int i = 0; i < N_EVENTS; i++) begin
      // --- pick the encoding defects first: whether the event is trusted
      // decides what it is allowed to do to the sequence expectation.
      roll = rand_range(gen_rng, 0, 999);
      if (roll < 20) begin
        r_btype = 1'b1;
        t = (roll[0]) ? 8'h00 : 8'hFF;
      end else begin
        r_btype = 1'b0;
        // ADD half the time; the book needs more adds than it needs removals
        // or every side spends the run empty.
        roll = rand_range(gen_rng, 0, 3);
        t = (roll < 2) ? EVT_ADD : ((roll == 2) ? EVT_CANCEL : EVT_TRADE);
      end

      roll = rand_range(gen_rng, 0, 999);
      if (roll < 20) begin r_bside = 1'b1; sd = (roll[0]) ? 2'b00 : 2'b11; end
      else begin
        r_bside = 1'b0;
        sd = (rand_range(gen_rng, 0, 1) == 0) ? SIDE_BID : SIDE_ASK;
      end

      roll = rand_range(gen_rng, 0, 999);
      r_brsv = (roll < 10);
      rv     = r_brsv ? RSV_W'(rand_range(gen_rng, 1, 3)) : '0;

      sym = SYMBOL_W'(rand_range(gen_rng, 0, N_SYMBOLS - 1));
      px  = ladder(32'(sym), rand_range(gen_rng, 0, 5));
      qy  = pick_qty(gen_rng, 32'(sym));

      // Deterministic prologue: two clean, sized events on symbol 0, one per
      // side, so bid_qty + ask_qty == 2 is reached on EVERY seed. Left to the
      // distribution it needs two qty-1 events to land on opposite sides of
      // one symbol before accumulation drifts either upward, which seed 4242
      // never did. A coverage floor that depends on the seed is not a floor.
      //
      // The draws above still execute, so the RNG stream and therefore every
      // later event are unchanged.
      if (i < 2) begin
        r_btype = 1'b0; r_bside = 1'b0; r_brsv = 1'b0; rv = '0;
        t   = EVT_ADD;
        sym = '0;
        sd  = (i == 0) ? SIDE_BID : SIDE_ASK;
        px  = (i == 0) ? PRICE_W'(16'd100) : PRICE_W'(16'd200);
        qy  = QTY_W'(1);
      end

      // --- sequence number
      roll = rand_range(gen_rng, 0, 999);
      if      (primed_ref && roll <  40) rx = expect_ref - SEQ_W'(rand_range(gen_rng, 1, 8));
      else if (primed_ref && roll < 100) rx = expect_ref + SEQ_W'(rand_range(gen_rng, 1, 8));
      else                               rx = expect_ref;

      if (i < 2) rx = expect_ref;   // the prologue must not be gapped or stale

      // --- sequence classification, straight from the spec's table
      diff    = $signed(rx - expect_ref);
      r_gap   = primed_ref && (diff > 0);
      r_stale = primed_ref && (diff < 0);
      force_resync = r_stale && (stale_run >= STALE_RESYNC_LIMIT - 1);

      if (!primed_ref) begin
        if (!(r_btype || r_bside || r_brsv)) begin
          expect_ref = rx + 1'b1; primed_ref = 1'b1;
        end
      end else if (diff == '0) begin
        expect_ref = rx + 1'b1;
      end else if (r_gap && !(r_btype || r_bside || r_brsv)) begin
        expect_ref = rx + 1'b1;
      end else if (force_resync) begin
        expect_ref = rx + 1'b1;
      end
      stale_run = (r_stale && !force_resync) ? stale_run + 1 : 0;

      if (r_gap && !(r_btype || r_bside || r_brsv)) begin
        ref_gap_count++;
        ref_missed_total += longint'(diff);
      end
      if (r_stale) ref_stale_count++;
      if (r_btype || r_bside || r_brsv) ref_bad_count++;
      if (force_resync) ref_resync_count++;

      word[i] = '0;
      word[i][TYPE_LSB   +: TYPE_W]   = t;
      word[i][SYMBOL_LSB +: SYMBOL_W] = sym;
      word[i][SIDE_LSB   +: SIDE_W]   = sd;
      word[i][PRICE_LSB  +: PRICE_W]  = px;
      word[i][QTY_LSB    +: QTY_W]    = qy;
      word[i][SEQ_LSB    +: SEQ_W]    = rx;
      word[i][RSV_LSB    +: RSV_W]    = rv;

      ref_event[i]        = '0;
      ref_event[i].etype  = t;
      ref_event[i].symbol = sym;
      ref_event[i].side   = sd;
      ref_event[i].price  = px;
      ref_event[i].qty    = qy;
      ref_event[i].seq    = rx;
      ref_err[i]          = '0;
      ref_err[i].bad_type = r_btype;
      ref_err[i].bad_side = r_bside;
      ref_err[i].bad_rsv  = r_brsv;
      ref_err[i].gap      = r_gap;
      ref_err[i].stale    = r_stale;

      // --- top-of-book update matrix, from spec 5.3 -------------------
      trusted = !(r_btype || r_bside || r_brsv || r_gap || r_stale);
      cov_symbol_seen[sym] = 1'b1;
      if (!trusted) cov_withheld++;
      nb = bk[sym];
      if (trusted) begin
        case (t)
          // An ADD with no size cannot establish or improve a level; see the
          // spec's update table. Counted, so the coverage floor still proves
          // the case was reached.
          EVT_ADD:
            if (qy == '0) cov_add_qty0++;
            else if (sd == SIDE_BID) begin
              if (!nb.bid_valid || px > nb.bid_price) begin
                if (nb.bid_valid) cov_add_replace_bid++;
                nb.bid_valid = 1'b1; nb.bid_price = px; nb.bid_qty = qy;
              end else if (px == nb.bid_price) begin
                cov_add_accum_bid++;
                if (int'(nb.bid_qty) + int'(qy) > 65535) begin
                  cov_qty_sat++; nb.bid_qty = 16'hFFFF;
                end else nb.bid_qty = nb.bid_qty + qy;
              end else cov_add_worse++;
            end else begin
              if (!nb.ask_valid || px < nb.ask_price) begin
                if (nb.ask_valid) cov_add_replace_ask++;
                nb.ask_valid = 1'b1; nb.ask_price = px; nb.ask_qty = qy;
              end else if (px == nb.ask_price) begin
                cov_add_accum_ask++;
                if (int'(nb.ask_qty) + int'(qy) > 65535) begin
                  cov_qty_sat++; nb.ask_qty = 16'hFFFF;
                end else nb.ask_qty = nb.ask_qty + qy;
              end else cov_add_worse++;
            end
          EVT_CANCEL:
            if (sd == SIDE_BID) begin
              if (nb.bid_valid && px == nb.bid_price) begin
                cov_cancel_hit_bid++;
                nb.bid_valid = 1'b0; nb.bid_price = '0; nb.bid_qty = '0;
              end else cov_cancel_miss++;
            end else begin
              if (nb.ask_valid && px == nb.ask_price) begin
                cov_cancel_hit_ask++;
                nb.ask_valid = 1'b0; nb.ask_price = '0; nb.ask_qty = '0;
              end else cov_cancel_miss++;
            end
          EVT_TRADE:
            if (sd == SIDE_BID) begin
              if (nb.bid_valid && px == nb.bid_price) begin
                cov_trade_hit_bid++;
                if (qy >= nb.bid_qty) begin
                  if (qy > nb.bid_qty) cov_trade_floor++;
                  nb.bid_qty = '0;
                end else nb.bid_qty = nb.bid_qty - qy;
                if (nb.bid_qty == '0) begin
                  cov_trade_to_zero++;
                  nb.bid_valid = 1'b0; nb.bid_price = '0;
                end
              end else cov_trade_miss++;
            end else begin
              if (nb.ask_valid && px == nb.ask_price) begin
                cov_trade_hit_ask++;
                if (qy >= nb.ask_qty) begin
                  if (qy > nb.ask_qty) cov_trade_floor++;
                  nb.ask_qty = '0;
                end else nb.ask_qty = nb.ask_qty - qy;
                if (nb.ask_qty == '0) begin
                  cov_trade_to_zero++;
                  nb.ask_valid = 1'b0; nb.ask_price = '0;
                end
              end else cov_trade_miss++;
            end
          default: ;
        endcase
      end
      bk[sym]       = nb;
      ref_book[i]   = nb;
      ref_bstale[i] = !trusted;

      // --- features, from spec 5.4 ------------------------------------
      both = nb.bid_valid && nb.ask_valid;
      den  = int'(nb.bid_qty) + int'(nb.ask_qty);
      emp  = !both || (den == 0);
      ref_spread[i] = both ? SPREAD_W'($signed({1'b0, nb.ask_price}) -
                                       $signed({1'b0, nb.bid_price})) : '0;
      ref_mid[i]    = both ? PRICE_W'(({1'b0, nb.bid_price} +
                                       {1'b0, nb.ask_price}) >> 1) : '0;
      ref_empty[i]  = emp;
      ref_imb[i]    = emp ? 0 : exact_imb(int'(nb.bid_qty), int'(nb.ask_qty));
      ref_mom[i]    = (emp || !pv[sym]) ? '0
                    : MOM_W'($signed({1'b0, ref_mid[i]}) - $signed({1'b0, pm[sym]}));

      if (both && den == 1) cov_den1++;
      if (both && den == 2) cov_den2++;
      // Invariant, not coverage: an ADD with no size cannot establish a
      // level and TRADE clears a side at zero, so a valid side always has
      // size. If this ever counts, one of those two rules has regressed.
      if ((nb.bid_valid && nb.bid_qty == '0) || (nb.ask_valid && nb.ask_qty == '0))
        cov_valid_side_qty0++;
      if (both && nb.bid_price > nb.ask_price) cov_crossed++;
      if (both && (ref_spread[i] > 17'sd32767 || ref_spread[i] < -17'sd32767))
        cov_spread_fullscale++;
      if (!emp && was_empty[sym] && pv[sym]) cov_empty_refill++;
      was_empty[sym] = emp;

      // History advances only when the book ingested the event and the
      // resulting book has a midprice.
      if (!ref_bstale[i] && !emp) begin pm[sym] = ref_mid[i]; pv[sym] = 1'b1; end
    end
  endtask

  // ------------------------------------------------------------------
  // Driver: randomized idle gaps, valid HELD until accepted.
  // ------------------------------------------------------------------
  int sent = 0, b_recvd = 0, m_recvd = 0;
  int stall_cycles = 0, idle_cycles = 0, held_valid_cycles = 0;
  bit built = 1'b0;

  initial begin
    s_valid = 1'b0;
    s_data  = '0;
    wait (built);
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    while (sent < N_EVENTS) begin
      if (rand_range(drv_rng, 0, 3) == 0) begin
        @(negedge clk);
        s_valid = 1'b0;
        repeat (rand_range(drv_rng, 1, 3)) begin
          @(posedge clk);
          idle_cycles++;
        end
      end
      @(negedge clk);
      s_data  = word[sent];
      s_valid = 1'b1;
      #1;
      while (!s_ready) begin
        @(posedge clk);
        held_valid_cycles++;
        @(negedge clk);
        #1;
      end
      @(posedge clk);
      sent++;
    end
    @(negedge clk);
    s_valid = 1'b0;
  end

  // Backpressure, driven on the negedge -- assigning m_ready at the posedge
  // races the DUT and the scoreboards that sample it on that edge.
  initial begin
    m_ready = 1'b1;
    forever begin
      @(negedge clk);
      if (rand_range(bp_rng, 0, 3) == 0) begin
        m_ready = 1'b0;
        repeat (rand_range(bp_rng, 1, 6)) begin
          @(negedge clk);
          stall_cycles++;
        end
        m_ready = 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------
  // Scoreboard 1: the book, at the top_of_book handoff.
  // ------------------------------------------------------------------
  task automatic cmp(string what, int idx, logic [31:0] got, logic [31:0] want);
    if (got !== want) begin
      errors++;
      $error("FAIL[%0d]: %s got %0d want %0d", idx, what, got, want);
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst_n && b_valid && b_ready) begin
      if (b_recvd >= N_EVENTS) begin
        errors++;
        $error("FAIL: extra book output beyond %0d events", N_EVENTS);
      end else begin
        if (b_event !== ref_event[b_recvd]) begin
          errors++;
          $error("FAIL[%0d]: book-stage event %p, reference %p",
                 b_recvd, b_event, ref_event[b_recvd]);
        end
        if (b_err !== ref_err[b_recvd]) begin
          errors++;
          $error("FAIL[%0d]: book-stage err %p, reference %p",
                 b_recvd, b_err, ref_err[b_recvd]);
        end
        if (b_book !== ref_book[b_recvd]) begin
          errors++;
          $error("FAIL[%0d]: book sym %0d got %p, reference %p (event %p)",
                 b_recvd, b_event.symbol, b_book, ref_book[b_recvd],
                 ref_event[b_recvd]);
        end
        cmp("book_stale", b_recvd, {31'd0, b_book_stale},
            {31'd0, ref_bstale[b_recvd]});
        b_recvd++;
      end
    end
  end

  // ------------------------------------------------------------------
  // Scoreboard 2: the features, at the feature_engine handoff.
  // ------------------------------------------------------------------
  int worst_imb_err = 0;

  always_ff @(posedge clk) begin
    int got_imb, err_imb;
    if (rst_n && m_valid && m_ready) begin
      if (m_recvd >= N_EVENTS) begin
        errors++;
        $error("FAIL: extra feature output beyond %0d events", N_EVENTS);
      end else begin
        if (m_event !== ref_event[m_recvd]) begin
          errors++;
          $error("FAIL[%0d]: feature-stage event %p, reference %p",
                 m_recvd, m_event, ref_event[m_recvd]);
        end
        if (m_err !== ref_err[m_recvd]) begin
          errors++;
          $error("FAIL[%0d]: feature-stage err %p, reference %p",
                 m_recvd, m_err, ref_err[m_recvd]);
        end
        cmp("spread",     m_recvd, {{15{m_feat.spread[SPREAD_W-1]}}, m_feat.spread},
                                   {{15{ref_spread[m_recvd][SPREAD_W-1]}}, ref_spread[m_recvd]});
        cmp("mid",        m_recvd, {16'd0, m_feat.mid}, {16'd0, ref_mid[m_recvd]});
        cmp("book_empty", m_recvd, {31'd0, m_feat.book_empty},
                                   {31'd0, ref_empty[m_recvd]});
        cmp("momentum",   m_recvd, {{15{m_feat.momentum[MOM_W-1]}}, m_feat.momentum},
                                   {{15{ref_mom[m_recvd][MOM_W-1]}}, ref_mom[m_recvd]});

        // Imbalance is approximate by design: score it against exact integer
        // division within the spec's error bound, and require the clamp.
        got_imb = int'(m_feat.imbalance);
        err_imb = (got_imb > ref_imb[m_recvd]) ? (got_imb - ref_imb[m_recvd])
                                               : (ref_imb[m_recvd] - got_imb);
        if (err_imb > worst_imb_err) worst_imb_err = err_imb;
        if (err_imb > IMB_TOL) begin
          errors++;
          $error("FAIL[%0d]: imbalance %0d, exact %0d, error %0d > %0d (bq=%0d aq=%0d)",
                 m_recvd, got_imb, ref_imb[m_recvd], err_imb, IMB_TOL,
                 ref_book[m_recvd].bid_qty, ref_book[m_recvd].ask_qty);
        end
        if (got_imb > IMB_ONE || got_imb < -IMB_ONE) begin
          errors++;
          $error("FAIL[%0d]: imbalance %0d escaped +/-%0d", m_recvd, got_imb, IMB_ONE);
        end
        if ($isunknown(m_feat)) begin
          errors++;
          $error("FAIL[%0d]: feature payload has X", m_recvd);
        end
        m_recvd++;
      end
    end
  end

  // ------------------------------------------------------------------
  task automatic floor_check(string what, int got, int want);
    if (got < want) begin
      errors++;
      $error("FAIL: coverage floor %s = %0d, need >= %0d -- this run did not test it",
             what, got, want);
    end
  endtask

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    gen_rng = seed ^ 32'hA5A5_1234;
    drv_rng = seed ^ 32'h9E37_79B9;
    bp_rng  = seed ^ 32'h5EED_BEEF;
    $display("INFO: seed=%0d events=%0d", seed, N_EVENTS);
    $display("INFO: reproduce with: make sim TOP=tb_book_features PLUSARGS=\"SEED=%0d\"",
             seed);
    build_stimulus_and_reference();
    $display("INFO: reference sequence totals gap=%0d stale=%0d missed=%0d bad=%0d resync=%0d",
             ref_gap_count, ref_stale_count, ref_missed_total, ref_bad_count,
             ref_resync_count);
    built = 1'b1;
  end

  initial begin
    int syms;
    wait (built);
    wait (m_recvd == N_EVENTS);
    repeat (5) @(posedge clk);

    if (b_recvd != N_EVENTS) begin
      errors++;
      $error("FAIL: book stage handed off %0d of %0d events", b_recvd, N_EVENTS);
    end
    if (gap_count !== ref_gap_count[CNT_W-1:0]) begin
      errors++; $error("FAIL: gap_count %0d, reference %0d", gap_count, ref_gap_count);
    end
    if (stale_count !== ref_stale_count[CNT_W-1:0]) begin
      errors++; $error("FAIL: stale_count %0d, reference %0d", stale_count, ref_stale_count);
    end
    if (missed_total !== ref_missed_total[CNT_W-1:0]) begin
      errors++; $error("FAIL: missed_total %0d, reference %0d", missed_total, ref_missed_total);
    end
    if (bad_event_count !== ref_bad_count[CNT_W-1:0]) begin
      errors++; $error("FAIL: bad_event_count %0d, reference %0d", bad_event_count, ref_bad_count);
    end
    if (resync_count !== ref_resync_count[CNT_W-1:0]) begin
      errors++; $error("FAIL: resync_count %0d, reference %0d", resync_count, ref_resync_count);
    end

    syms = 0;
    for (int i = 0; i < N_SYMBOLS; i++) if (cov_symbol_seen[i]) syms++;

    $display("INFO: coverage symbols=%0d/%0d withheld=%0d", syms, N_SYMBOLS, cov_withheld);
    $display("INFO: coverage add replace bid/ask=%0d/%0d accum bid/ask=%0d/%0d worse=%0d qty0=%0d sat=%0d",
             cov_add_replace_bid, cov_add_replace_ask, cov_add_accum_bid,
             cov_add_accum_ask, cov_add_worse, cov_add_qty0, cov_qty_sat);
    $display("INFO: coverage cancel hit bid/ask=%0d/%0d miss=%0d  trade hit bid/ask=%0d/%0d miss=%0d to_zero=%0d floor=%0d",
             cov_cancel_hit_bid, cov_cancel_hit_ask, cov_cancel_miss,
             cov_trade_hit_bid, cov_trade_hit_ask, cov_trade_miss,
             cov_trade_to_zero, cov_trade_floor);
    $display("INFO: coverage crossed=%0d den1=%0d den2=%0d valid_side_qty0=%0d empty_refill=%0d spread_fullscale=%0d",
             cov_crossed, cov_den1, cov_den2, cov_valid_side_qty0,
             cov_empty_refill, cov_spread_fullscale);
    $display("INFO: coverage stall_cycles=%0d idle_cycles=%0d held_valid_cycles=%0d",
             stall_cycles, idle_cycles, held_valid_cycles);
    $display("INFO: worst imbalance error %0d of %0d full scale", worst_imb_err, IMB_ONE);

    // Coverage floors. A randomized run that missed a row of the update table
    // is not the test this file claims to be and must not report as one.
    floor_check("symbols",            syms,                N_SYMBOLS);
    floor_check("add replace bid",    cov_add_replace_bid, 10);
    floor_check("add replace ask",    cov_add_replace_ask, 10);
    floor_check("add accumulate bid", cov_add_accum_bid,   10);
    floor_check("add accumulate ask", cov_add_accum_ask,   10);
    floor_check("add worse",          cov_add_worse,       10);
    floor_check("add qty 0",          cov_add_qty0,        10);
    floor_check("qty saturation",     cov_qty_sat,         1);
    floor_check("cancel at best bid", cov_cancel_hit_bid,  10);
    floor_check("cancel at best ask", cov_cancel_hit_ask,  10);
    floor_check("cancel off best",    cov_cancel_miss,     10);
    floor_check("trade at best bid",  cov_trade_hit_bid,   10);
    floor_check("trade at best ask",  cov_trade_hit_ask,   10);
    floor_check("trade off best",     cov_trade_miss,      10);
    floor_check("trade to zero",      cov_trade_to_zero,   5);
    floor_check("trade floors at 0",  cov_trade_floor,     5);
    floor_check("crossed book",       cov_crossed,         5);
    floor_check("den == 2",           cov_den2,            1);
    // Not a floor: this must be zero. See the invariant note where it is
    // counted.
    if (cov_valid_side_qty0 != 0) begin
      errors++;
      $error("FAIL: invariant broken -- %0d valid book sides with zero size",
             cov_valid_side_qty0);
    end
    floor_check("empty then refill",  cov_empty_refill,    5);
    floor_check("full-scale spread",  cov_spread_fullscale, 1);
    floor_check("withheld updates",   cov_withheld,        10);
    floor_check("gap events",         int'(ref_gap_count), 10);
    floor_check("stale events",       int'(ref_stale_count), 10);
    floor_check("malformed events",   int'(ref_bad_count), 10);
    floor_check("backpressure cycles", stall_cycles,       50);
    floor_check("valid held in stall", held_valid_cycles,  50);

    if (errors != 0)
      $fatal(1, "FAIL: %0d mismatches over %0d events (seed=%0d)",
             errors, N_EVENTS, seed);
    $display("PASS: tb_book_features -- %0d events, seed=%0d, worst imbalance error %0d/%0d",
             N_EVENTS, seed, worst_imb_err, IMB_ONE);
    $finish;
  end

  initial begin
    #40000000;
    $fatal(1, "FAIL: timeout -- sent=%0d book=%0d feat=%0d of %0d",
           sent, b_recvd, m_recvd, N_EVENTS);
  end
endmodule
