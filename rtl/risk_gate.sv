// risk_gate.sv -- hard limits between the policy's opinion and the emitted
// decision.
//
// Every rejection carries a reason code, and a genuine HOLD is distinguished
// from a suppressed BUY: telemetry that cannot tell "the policy did not want
// to trade" from "the policy wanted to and was refused" cannot be used to
// judge either the policy or the limits.
//
// The spread guard is qualified by !book_empty, and that qualification is the
// single most important line in this file. Under feature_engine's gating rule
// an empty book reports spread == 0 -- the TIGHTEST spread representable --
// so an unqualified "reject if spread > max_spread" passes exactly when there
// is no book to trade against. See design spec section 5.6.
//
// Latency: LAT_RISK (1 cycle) when m_ready is held high. No configuration
// value appears in any valid, ready or enable expression: limits change what
// is decided, never when.
module risk_gate
  import market_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,

  input  risk_cfg_t     cfg,

  input  market_event_t s_event,
  input  event_err_t    s_err,
  input  feature_t      s_feat,
  input  decision_e     s_decision,
  input  logic signed [SCORE_W-1:0] s_score,
  input  logic [QTY_W-1:0]          s_order_qty,
  input  logic          s_valid,
  output logic          s_ready,

  output market_event_t m_event,
  output event_err_t    m_err,
  output feature_t      m_feat,
  output decision_t     m_decision,
  output logic          m_valid,
  input  logic          m_ready
);

  logic signed [POS_W-1:0] position;

  logic malformed, seq_bad;
  assign malformed = s_err.bad_type || s_err.bad_side || s_err.bad_rsv;
  assign seq_bad   = s_err.gap || s_err.stale;

  // Prospective position if this decision were allowed through.
  logic signed [POS_W-1:0] qty_ext, next_pos;
  assign qty_ext  = POS_W'({1'b0, s_order_qty});
  assign next_pos = (s_decision == DEC_BUY)  ? (position + qty_ext)
                  : (s_decision == DEC_SELL) ? (position - qty_ext)
                  :                             position;

  // The limits are held in SIGNED variables on purpose. Written inline as
  // POS_W'({1'b0, cfg.max_long}) the right-hand side is unsigned, and SV then
  // evaluates the whole comparison unsigned -- a negative next_pos reads as a
  // huge positive number and the long limit fires on a short position.
  logic signed [POS_W-1:0] lim_long, lim_short;
  assign lim_long  =  $signed({1'b0, cfg.max_long});
  assign lim_short = -$signed({1'b0, cfg.max_short});

  logic over_long, over_short;
  assign over_long  = (s_decision == DEC_BUY)  && (next_pos > lim_long);
  assign over_short = (s_decision == DEC_SELL) && (next_pos < lim_short);

  // Only a real book can be too wide. A negative spread is a crossed book,
  // which is tighter than any positive limit, not wider.
  logic spread_bad;
  assign spread_bad = !s_feat.book_empty && (s_feat.spread > cfg.max_spread);

  // Reason precedence, most fundamental first: a kill switch is not a
  // position problem, and neither is a corrupt event.
  reason_e   reason_c;
  decision_e decision_c;
  always_comb begin
    if      (cfg.kill)           reason_c = RSN_KILL;
    else if (malformed)          reason_c = RSN_MALFORMED;
    else if (seq_bad)            reason_c = RSN_SEQUENCE;
    else if (s_feat.book_empty)  reason_c = RSN_BOOK_EMPTY;
    else if (spread_bad)         reason_c = RSN_SPREAD;
    else if (s_order_qty > cfg.max_order_qty) reason_c = RSN_MAX_QTY;
    else if (over_long)          reason_c = RSN_MAX_LONG;
    else if (over_short)         reason_c = RSN_MAX_SHORT;
    else                         reason_c = RSN_NONE;

    // A reason suppresses the trade. A HOLD the policy chose itself is
    // RSN_NONE and stays a HOLD -- same outward decision, different meaning.
    decision_c = (reason_c == RSN_NONE) ? s_decision : DEC_HOLD;
  end

  // The position only moves on a decision that actually got out.
  logic signed [POS_W-1:0] pos_c;
  assign pos_c = (decision_c == DEC_BUY)  ? (position + qty_ext)
               : (decision_c == DEC_SELL) ? (position - qty_ext)
               :                             position;

  assign s_ready = m_ready || !m_valid;

  logic accept;
  assign accept = s_valid && s_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_valid    <= 1'b0;
      m_event    <= '0;
      m_err      <= '0;
      m_feat     <= '0;
      m_decision <= '0;
      position   <= '0;
    end else begin
      if (s_ready) begin
        m_valid             <= s_valid;
        m_event             <= s_event;
        m_err               <= s_err;
        m_feat              <= s_feat;
        m_decision.decision <= decision_c;
        m_decision.reason   <= reason_c;
        m_decision.order_qty<= (decision_c == DEC_HOLD) ? '0 : s_order_qty;
        m_decision.score    <= s_score;
        m_decision.position <= pos_c;
      end
      if (accept) position <= pos_c;
    end
  end

endmodule
