// config_regs.sv -- the configuration register bus.
//
// A plain write-through register file is wrong here. Weights arrive one write
// at a time over several cycles; if each landed live, an event accepted between
// two writes would be scored with w_spread from the new policy and w_momentum
// from the old one. The resulting decision belongs to no configuration that was
// ever tuned, and it is not reproducible offline.
//
// So: writes land in a SHADOW copy and change nothing. Writing 1 to CFG_COMMIT
// copies every shadow field into the active configuration on that clock edge.
// That makes a BATCH of writes atomic -- the only thing this module has to
// guarantee.
//
// It does NOT try to time the swap relative to events in flight, and does not
// need to. Per-event atomicity comes from policy_engine, which captures the
// weights, thresholds, order size and the risk limits into its stage-1
// registers on the edge it ACCEPTS an event. An event is scored and gated by
// whichever configuration was active on that edge -- not when the event entered
// the pipeline, which is several stages earlier -- so a commit changes what
// every event not yet accepted by policy_engine sees, including events already
// inside decoder..feature_engine, and nothing that has already been accepted. An earlier version
// routed a "safe to swap" handshake back from policy_engine; forcing it high
// changed no output, because the snapshot had already made it redundant, so it
// was removed. tb_policy_engine's snapshot test is what pins the property: it
// changes every configuration field one cycle after accept, during a stall, and
// between two back-to-back accepts.
//
// Reset leaves the design SAFE rather than merely defined: zero weights, zero
// order size, and the kill switch ON. A design that comes out of reset able to
// trade before anyone has configured it is a design that will, once.
module config_regs
  import market_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst_n,

  // write port
  input  logic [CFG_ADDR_W-1:0] cfg_addr,
  input  logic [CFG_DATA_W-1:0] cfg_wdata,
  input  logic                  cfg_we,

  output policy_cfg_t           policy_cfg,
  output risk_cfg_t             risk_cfg,
  output logic [CNT_W-1:0]      commit_count
);

  policy_cfg_t sh_policy;
  risk_cfg_t   sh_risk;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sh_policy      <= '0;
      sh_risk        <= '0;
      sh_risk.kill   <= 1'b1;      // safe by default
      policy_cfg     <= '0;
      risk_cfg       <= '0;
      risk_cfg.kill  <= 1'b1;
      commit_count   <= '0;
    end else begin
      if (cfg_we) begin
        unique case (cfg_addr)
          CFG_W0:            sh_policy.w0          <= W_W'(cfg_wdata);
          CFG_W_SPREAD:      sh_policy.w_spread    <= W_W'(cfg_wdata);
          CFG_W_IMBALANCE:   sh_policy.w_imbalance <= W_W'(cfg_wdata);
          CFG_W_MOMENTUM:    sh_policy.w_momentum  <= W_W'(cfg_wdata);
          CFG_THETA_BUY:     sh_policy.theta_buy   <= SCORE_W'(cfg_wdata);
          CFG_THETA_SELL:    sh_policy.theta_sell  <= SCORE_W'(cfg_wdata);
          CFG_ORDER_QTY:     sh_policy.order_qty   <= QTY_W'(cfg_wdata);
          CFG_MAX_LONG:      sh_risk.max_long      <= (POS_W-1)'(cfg_wdata);
          CFG_MAX_SHORT:     sh_risk.max_short     <= (POS_W-1)'(cfg_wdata);
          CFG_MAX_ORDER_QTY: sh_risk.max_order_qty <= QTY_W'(cfg_wdata);
          CFG_MAX_SPREAD:    sh_risk.max_spread    <= SPREAD_W'(cfg_wdata);
          CFG_KILL:          sh_risk.kill          <= cfg_wdata[0];
          // The swap. Everything at once, or nothing. The port writes one
          // register per cycle, so no shadow field can change on the commit
          // edge itself. The batch is the whole shadow copy as it stands --
          // every write since reset, not only those since the last commit.
          CFG_COMMIT: if (cfg_wdata[0]) begin
            policy_cfg   <= sh_policy;
            risk_cfg     <= sh_risk;
            commit_count <= (commit_count == {CNT_W{1'b1}})
                          ? commit_count : commit_count + 1'b1;
          end
          default:           ;    // unmapped addresses are ignored, not aliased
        endcase
      end
    end
  end

endmodule
