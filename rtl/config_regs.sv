// config_regs.sv -- the configuration register bus, with safe-boundary
// parameter updates.
//
// A plain write-through register file is wrong here. Weights arrive one write
// at a time over several cycles; if each landed live, an event in flight could
// be scored with w_spread from the new policy and w_momentum from the old one.
// The resulting decision belongs to no configuration that was ever tuned, and
// it is not reproducible offline.
//
// So: writes land in a SHADOW copy and change nothing. Writing CFG_COMMIT arms
// a pending swap. The swap happens on the next asserted `boundary` -- driven by
// policy_engine, which asserts it only when a swap cannot split an event -- and
// applies every shadow field in one cycle. An event is therefore always scored
// by exactly one configuration, and which one is a property of where it sits in
// the stream rather than of when a Python script happened to finish writing.
//
// That covers the RISK limits as well as the weights, but only because
// policy_engine carries risk_cfg through its own pipeline registers. Feeding
// risk_gate straight from this module would apply new limits to a score
// computed under the old weights -- atomic for half a configuration is not
// atomic.
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

  // asserted when it is safe to swap configurations
  input  logic                  boundary,

  output policy_cfg_t           policy_cfg,
  output risk_cfg_t             risk_cfg,
  output logic [CNT_W-1:0]      commit_count
);

  policy_cfg_t sh_policy;
  risk_cfg_t   sh_risk;
  logic        commit_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sh_policy      <= '0;
      sh_risk        <= '0;
      sh_risk.kill   <= 1'b1;      // safe by default
      policy_cfg     <= '0;
      risk_cfg       <= '0;
      risk_cfg.kill  <= 1'b1;
      commit_pending <= 1'b0;
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
          CFG_COMMIT:        commit_pending        <= cfg_wdata[0];
          default:           ;    // unmapped addresses are ignored, not aliased
        endcase
      end

      // The swap. Everything at once, or nothing.
      if (commit_pending && boundary) begin
        policy_cfg     <= sh_policy;
        risk_cfg       <= sh_risk;
        commit_pending <= 1'b0;
        commit_count   <= (commit_count == {CNT_W{1'b1}})
                        ? commit_count : commit_count + 1'b1;
      end
    end
  end

endmodule
