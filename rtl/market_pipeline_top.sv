// market_pipeline_top.sv -- the synthesizable Basys 3 top.
//
// Stimulus is on-chip: trace_rom holds a generated trace and replay_ctrl walks
// it into the pipeline on a button press. Configuration is on-chip too:
// cfg_loader replays a committed preset into config_regs on reset release and
// whenever sw[0] changes. Decisions leave only as counters on the LEDs and the
// 7-seg. No data crosses a pin on a clock edge -- which is why the XDC
// false-paths every I/O instead of stating input and output delays.
module market_pipeline_top
  import market_pkg::*;
#(
  parameter int    N_TRACE       = 2000,
  parameter string TRACE_MEM     = "rtl/mem/rom_trace.mem",
  parameter string CFG_MEM_BASE  = "rtl/mem/rom_cfg_baseline.mem",
  parameter string CFG_MEM_TUNED = "rtl/mem/rom_cfg_tuned.mem",
  parameter int    LOCKOUT_W     = 20,
  parameter int    REFRESH_W     = 17
) (
  input  logic        clk,
  input  logic        btnU,     // reset
  input  logic        btnC,     // start replay
  input  logic [15:0] sw,       // sw[0]: 0 baseline, 1 tuned
  output logic [15:0] led,      // {SELL count, BUY count}, low bytes
  output logic [6:0]  seg,
  output logic        dp,
  output logic [3:0]  an
);
  logic rst_n;
  reset_sync u_rst (.clk(clk), .arst_in(btnU), .rst_n(rst_n));

  // ---- stimulus --------------------------------------------------------
  logic [$clog2(N_TRACE)-1:0] rom_addr;
  logic [EVENT_W-1:0] rom_data, s_data;
  logic s_valid, s_ready, replay_busy, start_pulse;

  trace_rom #(.N(N_TRACE), .MEM_FILE(TRACE_MEM))
    u_rom (.clk(clk), .addr(rom_addr), .data(rom_data));

  logic [CFG_ADDR_W-1:0] cfg_addr;
  logic [CFG_DATA_W-1:0] cfg_wdata;
  logic cfg_we, cfg_busy, preset;

  cfg_loader #(.MEM_BASE(CFG_MEM_BASE), .MEM_TUNED(CFG_MEM_TUNED))
    u_cfgl (.clk(clk), .rst_n(rst_n), .sw_preset(sw[0]),
            .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_we(cfg_we),
            .busy(cfg_busy), .preset(preset));

  replay_ctrl #(.N_TRACE(N_TRACE), .LOCKOUT_W(LOCKOUT_W))
    u_replay (.clk(clk), .rst_n(rst_n), .btn(btnC), .hold_off(cfg_busy),
              .rom_addr(rom_addr), .rom_data(rom_data),
              .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
              .busy(replay_busy), .start_pulse(start_pulse));

  // ---- pipeline --------------------------------------------------------
  market_event_t d_event, q_event, b_event, f_event, p_event, r_event;
  event_err_t    d_err, q_err, b_err, f_err, p_err, r_err;
  logic d_valid, d_ready, q_valid, q_ready, b_valid, b_ready;
  logic f_valid, f_ready, p_valid, p_ready, r_valid;
  book_t    b_book;
  logic     b_book_stale;
  feature_t f_feat, p_feat, r_feat;
  decision_e p_decision;
  logic signed [SCORE_W-1:0] p_score;
  logic [QTY_W-1:0]          p_order_qty;
  risk_cfg_t p_risk_cfg;
  policy_cfg_t policy_cfg;
  risk_cfg_t   risk_cfg;

  /* verilator lint_off UNUSEDSIGNAL */
  // Telemetry the Basys 3 has nowhere to show. Kept connected so a future
  // readout does not change the pipeline's netlist. Of r_decision only the
  // decision and reason reach a counter; order_qty and position do not.
  decision_t r_decision;
  logic [CNT_W-1:0] gap_count, stale_count, missed_total, bad_event_count,
                    resync_count, commit_count;
  logic [14:0] sw_spare;
  assign sw_spare = sw[15:1];
  /* verilator lint_on UNUSEDSIGNAL */

  event_decoder u_dec (
    .clk(clk), .rst_n(rst_n),
    .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
    .m_event(d_event), .m_err(d_err), .m_valid(d_valid), .m_ready(d_ready));

  sequence_checker u_seq (
    .clk(clk), .rst_n(rst_n),
    .s_event(d_event), .s_err(d_err), .s_valid(d_valid), .s_ready(d_ready),
    .m_event(q_event), .m_err(q_err), .m_valid(q_valid), .m_ready(q_ready),
    .gap_count(gap_count), .stale_count(stale_count),
    .missed_total(missed_total), .bad_event_count(bad_event_count),
    .resync_count(resync_count));

  top_of_book u_tob (
    .clk(clk), .rst_n(rst_n),
    .s_event(q_event), .s_err(q_err), .s_valid(q_valid), .s_ready(q_ready),
    .m_event(b_event), .m_err(b_err), .m_book(b_book),
    .m_book_stale(b_book_stale), .m_valid(b_valid), .m_ready(b_ready));

  feature_engine u_feat (
    .clk(clk), .rst_n(rst_n),
    .s_event(b_event), .s_err(b_err), .s_book(b_book),
    .s_book_stale(b_book_stale), .s_valid(b_valid), .s_ready(b_ready),
    .m_event(f_event), .m_err(f_err), .m_feat(f_feat),
    .m_valid(f_valid), .m_ready(f_ready));

  policy_engine u_pol (
    .clk(clk), .rst_n(rst_n), .cfg(policy_cfg), .risk_cfg_in(risk_cfg),
    .s_event(f_event), .s_err(f_err), .s_feat(f_feat),
    .s_valid(f_valid), .s_ready(f_ready),
    .m_event(p_event), .m_err(p_err), .m_feat(p_feat),
    .m_decision(p_decision), .m_score(p_score), .m_order_qty(p_order_qty),
    .m_risk_cfg(p_risk_cfg), .m_valid(p_valid), .m_ready(p_ready));

  /* verilator lint_off UNUSEDSIGNAL */
  market_event_t r_event_unused;
  event_err_t    r_err_unused;
  feature_t      r_feat_unused;
  assign r_event_unused = r_event;
  assign r_err_unused   = r_err;
  assign r_feat_unused  = r_feat;
  /* verilator lint_on UNUSEDSIGNAL */

  risk_gate u_risk (
    .clk(clk), .rst_n(rst_n), .cfg(p_risk_cfg),
    .s_event(p_event), .s_err(p_err), .s_feat(p_feat),
    .s_decision(p_decision), .s_score(p_score), .s_order_qty(p_order_qty),
    .s_valid(p_valid), .s_ready(p_ready),
    .m_event(r_event), .m_err(r_err), .m_feat(r_feat),
    .m_decision(r_decision), .m_valid(r_valid), .m_ready(1'b1));

  config_regs u_cfg (
    .clk(clk), .rst_n(rst_n),
    .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_we(cfg_we),
    .policy_cfg(policy_cfg), .risk_cfg(risk_cfg), .commit_count(commit_count));

  // ---- readout ---------------------------------------------------------
  logic [15:0] buy_cnt, sell_cnt, rej_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      buy_cnt <= '0; sell_cnt <= '0; rej_cnt <= '0;
    end else if (start_pulse) begin
      buy_cnt <= '0; sell_cnt <= '0; rej_cnt <= '0;
    end else if (r_valid) begin
      if (r_decision.decision == DEC_BUY)  buy_cnt  <= buy_cnt  + 1'b1;
      if (r_decision.decision == DEC_SELL) sell_cnt <= sell_cnt + 1'b1;
      if (r_decision.reason != RSN_NONE)   rej_cnt  <= rej_cnt  + 1'b1;
    end
  end

  assign led = {sell_cnt[7:0], buy_cnt[7:0]};

  seg7_display #(.REFRESH_W(REFRESH_W))
    u_seg (.clk(clk), .rst_n(rst_n), .value(rej_cnt), .seg(seg), .dp(dp), .an(an));

  /* verilator lint_off UNUSEDSIGNAL */
  logic status_unused;
  assign status_unused = replay_busy ^ preset;
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
