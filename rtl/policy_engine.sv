// policy_engine.sv -- fixed-point weighted score and threshold comparison.
//
//   score = w0 + (w_spread*spread + w_imbalance*imbalance + w_momentum*momentum)
//                >>> W_FRAC_W
//   BUY  if score >  theta_buy
//   SELL if score <  theta_sell
//   HOLD otherwise
//
// Structural latency is independent of the weight values, and that is the
// whole "AI customization" claim. It holds by construction here: the config
// reaches the ADDER TREE ONLY. No weight, threshold or quantity appears in
// any valid, ready or enable expression, so no configuration can change when
// an event emerges -- only what it decides. tb_policy_configs.sv proves it on
// a real trace by running two configs and comparing latency histograms bit
// for bit.
//
// The config is captured INTO the pipeline at accept, so an event is scored
// entirely with the snapshot that was active when it entered. A commit landing
// mid-flight cannot produce a decision built from half of one weight set and
// half of another.
//
// Latency: LAT_POLICY (2 cycles) when m_ready is held high.
module policy_engine
  import market_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,

  input  policy_cfg_t   cfg,
  // Carried, not used. risk_gate must see the SAME configuration generation
  // that scored the event, or a commit landing while events are in flight
  // applies the new limits to a score computed under the old weights. Routing
  // it through here snapshots it at accept exactly as the weights are.
  input  risk_cfg_t     risk_cfg_in,

  input  market_event_t s_event,
  input  event_err_t    s_err,
  input  feature_t      s_feat,
  input  logic          s_valid,
  output logic          s_ready,

  output market_event_t m_event,
  output event_err_t    m_err,
  output feature_t      m_feat,
  output decision_e     m_decision,
  output logic signed [SCORE_W-1:0] m_score,
  output logic [QTY_W-1:0]          m_order_qty,
  output risk_cfg_t     m_risk_cfg,
  output logic          m_valid,
  input  logic          m_ready,

  // Asserted when a configuration swap cannot split an event: either an event
  // is being accepted right now, or the engine is idle.
  //
  // Defence in depth, not the mechanism. Atomicity actually comes from the
  // per-event snapshot below -- weights, thresholds, order size and the risk
  // limits are all captured into stage 1 on the accept edge, from one clock
  // edge -- so an event is scored by one configuration generation whenever the
  // shadow swaps. Forcing this signal high changes no output, which is why
  // scripts/mutants.txt lists that mutation as deliberately absent.
  output logic          cfg_boundary
);

  // ------------------------------------------------------------------
  // Stage 1: three independent multiplies.
  //
  // Widths are exact rather than padded: a signed W_W by signed N product
  // needs W_W + N bits, no more.
  // ------------------------------------------------------------------
  localparam int P_SPREAD_W = W_W + SPREAD_W;
  localparam int P_IMB_W    = W_W + IMB_W;
  localparam int P_MOM_W    = W_W + MOM_W;

  logic signed [P_SPREAD_W-1:0] p_spread;
  logic signed [P_IMB_W-1:0]    p_imb;
  logic signed [P_MOM_W-1:0]    p_mom;

  assign p_spread = cfg.w_spread    * s_feat.spread;
  assign p_imb    = cfg.w_imbalance * s_feat.imbalance;
  assign p_mom    = cfg.w_momentum  * s_feat.momentum;

  logic v1, v2, advance;
  assign advance = m_ready || !v2;
  assign s_ready = advance;

  assign cfg_boundary = s_ready && (s_valid || !(v1 || v2));

  market_event_t ev1;
  event_err_t    er1;
  feature_t      ft1;
  logic signed [P_SPREAD_W-1:0] p_spread1;
  logic signed [P_IMB_W-1:0]    p_imb1;
  logic signed [P_MOM_W-1:0]    p_mom1;
  // The config snapshot this event was accepted under.
  logic signed [W_W-1:0]     w0_1;
  logic signed [SCORE_W-1:0] tbuy_1, tsell_1;
  logic [QTY_W-1:0]          oq_1;
  risk_cfg_t                 rc_1;

  // ------------------------------------------------------------------
  // Stage 2: sum, scale, add the constant term, compare.
  //
  // The sum is taken at full product width and only then narrowed, so the
  // intermediate cannot wrap before the saturation sees it. score_sat_add
  // clamps; a weighted sum that wrapped would turn a strong sell into a
  // strong buy, which is the one arithmetic failure this design cannot be
  // allowed to have.
  // ------------------------------------------------------------------
  localparam int ACC_W = P_SPREAD_W + 2;   // three products, +2 bits of growth

  logic signed [ACC_W-1:0]   acc2, scaled2;
  logic signed [SCORE_W-1:0] scaled_sat2, score2;

  assign acc2    = ACC_W'(p_spread1) + ACC_W'(p_imb1) + ACC_W'(p_mom1);
  assign scaled2 = acc2 >>> W_FRAC_W;

  // Bounds as signed arithmetic, not as concatenated bit patterns. A size cast
  // of {1'b1, ...} ZERO-extends -- the "most negative" bound became a large
  // positive one and the low clamp fired on every input, including zero.
  localparam logic signed [ACC_W-1:0] ACC_SCORE_MAX =
      (ACC_W'(1) <<< (SCORE_W-1)) - ACC_W'(1);
  localparam logic signed [ACC_W-1:0] ACC_SCORE_MIN =
      -(ACC_W'(1) <<< (SCORE_W-1));

  always_comb begin
    // Narrow to score width with clamping before the final accumulate.
    if (scaled2 > ACC_SCORE_MAX)
      scaled_sat2 = SCORE_W'(ACC_SCORE_MAX);
    else if (scaled2 < ACC_SCORE_MIN)
      scaled_sat2 = SCORE_W'(ACC_SCORE_MIN);
    else
      scaled_sat2 = SCORE_W'(scaled2);
  end

  assign score2 = score_sat_add(scaled_sat2, SCORE_W'(w0_1));

  decision_e dec2;
  always_comb begin
    // An empty book carries no information: every feature is zero by the
    // gating rule in feature_engine, so a decision here would be driven
    // entirely by w0. Refusing to act on no book is the policy's call, not
    // the risk gate's -- the risk gate rejects, this simply does not signal.
    if (ft1.book_empty)              dec2 = DEC_HOLD;
    else if (score2 >  tbuy_1)       dec2 = DEC_BUY;
    else if (score2 <  tsell_1)      dec2 = DEC_SELL;
    else                             dec2 = DEC_HOLD;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v1 <= 1'b0; v2 <= 1'b0;
      ev1 <= '0; er1 <= '0; ft1 <= '0;
      p_spread1 <= '0; p_imb1 <= '0; p_mom1 <= '0;
      w0_1 <= '0; tbuy_1 <= '0; tsell_1 <= '0; oq_1 <= '0; rc_1 <= '0;
      m_valid <= 1'b0; m_event <= '0; m_err <= '0; m_feat <= '0;
      m_decision <= DEC_HOLD; m_score <= '0; m_order_qty <= '0;
      m_risk_cfg <= '0;
    end else if (advance) begin
      // stage 1
      v1        <= s_valid;
      ev1       <= s_event;
      er1       <= s_err;
      ft1       <= s_feat;
      p_spread1 <= p_spread;
      p_imb1    <= p_imb;
      p_mom1    <= p_mom;
      w0_1      <= cfg.w0;
      tbuy_1    <= cfg.theta_buy;
      tsell_1   <= cfg.theta_sell;
      oq_1      <= cfg.order_qty;
      rc_1      <= risk_cfg_in;

      // stage 2
      v2          <= v1;
      m_valid     <= v1;
      m_event     <= ev1;
      m_err       <= er1;
      m_feat      <= ft1;
      m_decision  <= dec2;
      m_score     <= score2;
      m_order_qty <= oq_1;
      m_risk_cfg  <= rc_1;
    end
  end

endmodule
