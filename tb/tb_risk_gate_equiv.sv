// tb_risk_gate_equiv.sv -- the committed risk_gate against the pre-change one.
//
// Critical-path iteration 2 (commit 1dfcba9) restructured risk_gate's
// position arithmetic for timing and claims no output changed. This file makes
// that claim checkable: risk_gate_pre_iter2 below is rtl/risk_gate.sv exactly
// as it was at 57fd22d, renamed, plus one testbench-only parameter. The
// testbench drives the committed module and that copy with identical,
// protocol-legal stimulus and requires every output and the position to agree
// on every cycle:
//
//   * ramps into the long limit and past the short limit;
//   * every one of nine exact positions (including +/-(2**23-1)) x seven order
//     sizes x all four decision encodings x four limit pairs, reached by legal
//     trades rather than by forcing state;
//   * random events, configurations, faults and output backpressure.
//
// A third instance of the copy has an off-by-one planted in its long-limit
// check. It must differ from the unplanted copy at least once per run, or the
// comparison is not seeing the cases that matter and the test fails. Coverage
// floors on the near-limit cases fail the test the same way.

// ---------------------------------------------------------------------------
// rtl/risk_gate.sv at 57fd22d, renamed. Not synthesized; reference only.
// ---------------------------------------------------------------------------
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
module risk_gate_pre_iter2
  import market_pkg::*;
#(
  // Testbench-only: 1 makes the long-limit check >= instead of >, a planted
  // defect that the comparison must detect on every run.
  parameter bit PLANT_LONG_OFF_BY_ONE = 1'b0
) (
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
  //
  // Computed one bit WIDER than the position. POS_W holds the limit magnitude
  // in POS_W-1 bits, but position + order can exceed that: at max_long =
  // 2**23-1 with a 65535-lot order the sum wraps negative, `next_pos >
  // lim_long` reads false, and the limit FAILS OPEN -- the one failure mode
  // this module exists to prevent. Both the sum and the limits are compared at
  // CHK_W so the comparison cannot wrap.
  localparam int CHK_W = POS_W + 1;

  logic signed [POS_W-1:0] qty_ext;
  logic signed [CHK_W-1:0] next_pos;
  assign qty_ext  = POS_W'({1'b0, s_order_qty});
  assign next_pos = (s_decision == DEC_BUY)  ? (CHK_W'(position) + CHK_W'(qty_ext))
                  : (s_decision == DEC_SELL) ? (CHK_W'(position) - CHK_W'(qty_ext))
                  :                             CHK_W'(position);

  // The limits are held in SIGNED variables on purpose. Written inline as
  // POS_W'({1'b0, cfg.max_long}) the right-hand side is unsigned, and SV then
  // evaluates the whole comparison unsigned -- a negative next_pos reads as a
  // huge positive number and the long limit fires on a short position.
  logic signed [CHK_W-1:0] lim_long, lim_short;
  assign lim_long  =  CHK_W'($signed({1'b0, cfg.max_long}));
  assign lim_short = -CHK_W'($signed({1'b0, cfg.max_short}));

  logic over_long, over_short;
  assign over_long  = (s_decision == DEC_BUY)  &&
                      (PLANT_LONG_OFF_BY_ONE ? (next_pos >= lim_long) : (next_pos > lim_long));
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
    // A HOLD the policy chose itself suppresses nothing, so it carries no
    // reason. Without this the reason chain stamps whatever the event happens
    // to trigger onto every HOLD -- an empty book becomes RSN_BOOK_EMPTY, a
    // raised kill switch becomes RSN_KILL -- and telemetry can no longer tell
    // "the policy did not want to trade" from "the policy wanted to and was
    // refused", which is the entire distinction these codes exist for.
    if      (s_decision == DEC_HOLD) reason_c = RSN_NONE;
    else if (cfg.kill)           reason_c = RSN_KILL;
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

// ---------------------------------------------------------------------------
// The comparison.
// ---------------------------------------------------------------------------
module tb_risk_gate_equiv;
  import market_pkg::*;

  localparam int N_RANDOM = 60000;
  localparam int POS_MAX  = (1 << (POS_W - 1)) - 1;   // largest limit magnitude
  localparam int QTY_MAX  = (1 << QTY_W) - 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // Shared stimulus: all three instances see exactly the same inputs.
  risk_cfg_t     cfg;
  market_event_t s_event;
  event_err_t    s_err;
  feature_t      s_feat;
  decision_e     s_decision;
  logic signed [SCORE_W-1:0] s_score;
  logic [QTY_W-1:0]          s_order_qty;
  logic          s_valid = 1'b0, m_ready = 1'b1;

  logic          new_s_ready, old_s_ready, pl_s_ready;
  logic          new_m_valid, old_m_valid, pl_m_valid;
  market_event_t new_m_event, old_m_event, pl_m_event;
  event_err_t    new_m_err, old_m_err, pl_m_err;
  feature_t      new_m_feat, old_m_feat, pl_m_feat;
  decision_t     new_m_decision, old_m_decision, pl_m_decision;

  risk_gate dut (
    .clk(clk), .rst_n(rst_n), .cfg(cfg),
    .s_event(s_event), .s_err(s_err), .s_feat(s_feat), .s_decision(s_decision),
    .s_score(s_score), .s_order_qty(s_order_qty), .s_valid(s_valid), .s_ready(new_s_ready),
    .m_event(new_m_event), .m_err(new_m_err), .m_feat(new_m_feat),
    .m_decision(new_m_decision), .m_valid(new_m_valid), .m_ready(m_ready));

  risk_gate_pre_iter2 #(.PLANT_LONG_OFF_BY_ONE(1'b0)) u_old (
    .clk(clk), .rst_n(rst_n), .cfg(cfg),
    .s_event(s_event), .s_err(s_err), .s_feat(s_feat), .s_decision(s_decision),
    .s_score(s_score), .s_order_qty(s_order_qty), .s_valid(s_valid), .s_ready(old_s_ready),
    .m_event(old_m_event), .m_err(old_m_err), .m_feat(old_m_feat),
    .m_decision(old_m_decision), .m_valid(old_m_valid), .m_ready(m_ready));

  risk_gate_pre_iter2 #(.PLANT_LONG_OFF_BY_ONE(1'b1)) u_planted (
    .clk(clk), .rst_n(rst_n), .cfg(cfg),
    .s_event(s_event), .s_err(s_err), .s_feat(s_feat), .s_decision(s_decision),
    .s_score(s_score), .s_order_qty(s_order_qty), .s_valid(s_valid), .s_ready(pl_s_ready),
    .m_event(pl_m_event), .m_err(pl_m_err), .m_feat(pl_m_feat),
    .m_decision(pl_m_decision), .m_valid(pl_m_valid), .m_ready(m_ready));

  // -------------------------------------------------------------------------
  // Compare every cycle: handshake, registered outputs, and the position.
  // Outputs change on the rising edge, so the falling edge sees them settled.
  // -------------------------------------------------------------------------
  int unsigned cycles = 0, accepts = 0;
  int mismatches = 0, planted_diffs = 0;
  int near_long = 0, near_short = 0, rsn_long = 0, rsn_short = 0, wide_sum = 0;

  always @(negedge clk) begin
    if (rst_n) begin
      cycles++;
      if (new_s_ready !== old_s_ready || new_m_valid !== old_m_valid ||
          dut.position !== u_old.position ||
          (new_m_valid && (new_m_decision !== old_m_decision || new_m_event !== old_m_event ||
                           new_m_err !== old_m_err || new_m_feat !== old_m_feat))) begin
        mismatches++;
        if (mismatches <= 5)
          $error("FAIL: committed and pre-change risk_gate differ at cycle %0d: position %0d vs %0d, decision %p vs %p",
                 cycles, dut.position, u_old.position, new_m_decision, old_m_decision);
      end
      if (pl_m_valid !== old_m_valid || u_planted.position !== u_old.position ||
          (old_m_valid && pl_m_decision !== old_m_decision))
        planted_diffs++;
    end
  end

  // Coverage of the cases the change could plausibly break.
  always @(posedge clk) begin
    if (rst_n && s_valid && new_s_ready) begin
      accepts++;
      if (int'(dut.position) > POS_MAX - QTY_MAX)  near_long++;
      if (int'(dut.position) < -(POS_MAX - QTY_MAX)) near_short++;
      if (s_decision == DEC_BUY && int'(dut.position) + int'(s_order_qty) > POS_MAX) wide_sum++;
    end
    if (rst_n && new_m_valid && m_ready) begin
      if (new_m_decision.reason == RSN_MAX_LONG)  rsn_long++;
      if (new_m_decision.reason == RSN_MAX_SHORT) rsn_short++;
    end
  end

  // Random output backpressure.
  always @(negedge clk) m_ready = ($urandom % 4) != 0;

  // -------------------------------------------------------------------------
  // Stimulus. Every offer holds s_valid and its payload until accepted, as the
  // bound handshake_checker requires, then drops s_valid.
  // -------------------------------------------------------------------------
  function automatic risk_cfg_t mk_cfg(int mlong, int mshort, int mqty, int mspread, bit kill);
    risk_cfg_t c;
    c.max_long      = (POS_W-1)'(mlong);
    c.max_short     = (POS_W-1)'(mshort);
    c.max_order_qty = QTY_W'(mqty);
    c.max_spread    = SPREAD_W'(mspread);
    c.kill          = kill;
    return c;
  endfunction

  function automatic int pick_limit();
    case ($urandom % 9)
      0: return 0;
      1: return 1;
      2: return 2;
      3: return 100;
      4: return QTY_MAX;
      5: return POS_MAX - QTY_MAX;
      6: return POS_MAX - 1;
      7: return POS_MAX;
      default: return int'($urandom % (POS_MAX + 1));
    endcase
  endfunction

  function automatic int pick_qty();
    case ($urandom % 8)
      0: return 0;
      1: return 1;
      2: return 2;
      3: return 32767;
      4: return 32768;
      5: return QTY_MAX - 1;
      6: return QTY_MAX;
      default: return int'($urandom % (QTY_MAX + 1));
    endcase
  endfunction

  task automatic offer(decision_e d, int qty, bit clean);
    int guard = 0;
    @(negedge clk);
    s_event     = '0;
    s_event.seq = SEQ_W'($urandom);
    s_err       = '0;
    s_feat      = '0;
    s_feat.spread = clean ? '0 : SPREAD_W'($urandom);
    if (!clean) begin
      if (($urandom % 16) == 0) s_err = 5'($urandom);
      s_feat.book_empty = ($urandom % 20) == 0;
    end
    s_decision  = d;
    s_score     = SCORE_W'($urandom);
    s_order_qty = QTY_W'(qty);
    s_valid     = 1'b1;
    forever begin
      @(posedge clk);
      if (new_s_ready) break;
      guard++;
      if (guard > 1000) $fatal(1, "FAIL: offer never accepted");
    end
    @(negedge clk);
    s_valid = 1'b0;
  endtask

  // Walk the position to an exact value with legal, permissive trades.
  task automatic drive_to(int target);
    int cur, step, guard = 0;
    cfg = mk_cfg(POS_MAX, POS_MAX, QTY_MAX, (1 << (SPREAD_W - 1)) - 1, 1'b0);
    forever begin
      cur = int'(dut.position);
      if (cur == target) break;
      step = target - cur;
      if (step >  QTY_MAX) step =  QTY_MAX;
      if (step < -QTY_MAX) step = -QTY_MAX;
      offer((step > 0) ? DEC_BUY : DEC_SELL, (step > 0) ? step : -step, 1'b1);
      guard++;
      if (guard > 600) $fatal(1, "FAIL: could not drive position to %0d", target);
    end
  endtask

  int corners [9] = '{POS_MAX, POS_MAX - 1, POS_MAX - QTY_MAX, 1, 0, -1,
                      -(POS_MAX - QTY_MAX), -(POS_MAX - 1), -POS_MAX};
  int qtys [7]    = '{0, 1, 2, 32767, 32768, QTY_MAX - 1, QTY_MAX};
  int lims [4][2] = '{'{POS_MAX, POS_MAX}, '{0, 0}, '{POS_MAX - 1, 1},
                      '{100, POS_MAX - QTY_MAX}};
  int errors = 0;

  initial begin
    cfg = mk_cfg(POS_MAX, POS_MAX, QTY_MAX, 1000, 1'b0);
    s_event = '0; s_err = '0; s_feat = '0; s_decision = DEC_HOLD;
    s_score = '0; s_order_qty = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    // Phase 1: ramp into the long limit and past the short limit.
    cfg = mk_cfg(POS_MAX, POS_MAX, QTY_MAX, (1 << (SPREAD_W - 1)) - 1, 1'b0);
    repeat (200) offer(DEC_BUY,  QTY_MAX, 1'b1);
    repeat (400) offer(DEC_SELL, QTY_MAX, 1'b1);
    repeat (200) offer(DEC_BUY,  QTY_MAX, 1'b1);

    // Phase 2: every corner x order size x decision (including the unused
    // encoding) x limit pair, one event each from an exact position.
    foreach (corners[ci])
      foreach (qtys[qi])
        for (int di = 0; di < 4; di++)
          foreach (lims[li]) begin
            drive_to(corners[ci]);
            cfg = mk_cfg(lims[li][0], lims[li][1], QTY_MAX, (1 << (SPREAD_W - 1)) - 1, 1'b0);
            offer(decision_e'(di[1:0]), qtys[qi], 1'b1);
          end

    // Phase 3: random events, configurations and faults.
    for (int i = 0; i < N_RANDOM; i++) begin
      if ((i % 50) == 0)
        cfg = mk_cfg(pick_limit(), pick_limit(), pick_qty(), int'($urandom % 70000) - 35000,
                     ($urandom % 64) == 0);
      offer(decision_e'(2'($urandom)), pick_qty(), 1'b0);
    end

    repeat (LAT_RISK + 4) @(negedge clk);
    $display("INFO: %0d accepted events, %0d cycles compared, %0d mismatches",
             accepts, cycles, mismatches);
    $display("INFO: coverage -- within one max order of the long limit %0d, of the short limit %0d; buys past 2**23-1 %0d; MAX_LONG %0d; MAX_SHORT %0d",
             near_long, near_short, wide_sum, rsn_long, rsn_short);
    $display("INFO: planted off-by-one copy differed on %0d cycles", planted_diffs);

    if (mismatches != 0) begin errors++; $error("FAIL: %0d mismatching cycles", mismatches); end
    if (planted_diffs == 0) begin
      errors++; $error("FAIL: the planted defect was never detected -- the comparison is vacuous");
    end
    if (near_long < 50 || near_short < 50 || wide_sum < 20 || rsn_long < 50 || rsn_short < 50) begin
      errors++; $error("FAIL: coverage floor not met");
    end

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_risk_gate_equiv -- %0d events, 0 mismatches against the pre-change risk_gate; planted defect detected",
             accepts);
    $finish;
  end

  initial begin #200000000; $fatal(1, "FAIL: timeout"); end
endmodule
