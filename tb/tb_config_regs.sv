// Directed tests for config_regs.
//
// The property that matters: a parameter change becomes visible ATOMICALLY and
// only at an event boundary. A half-applied weight set would let one decision
// be scored with two different policies, which is both wrong and unreproducible
// -- and it is exactly what a naive write-through register file does.
module tb_config_regs;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [CFG_ADDR_W-1:0] cfg_addr;
  logic [CFG_DATA_W-1:0] cfg_wdata;
  logic                  cfg_we;
  logic                  boundary;
  policy_cfg_t           policy_cfg;
  risk_cfg_t             risk_cfg;
  logic [CNT_W-1:0]      commit_count;

  config_regs dut (.*);

  int errors = 0;

  task automatic check(string name, logic cond);
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  task automatic wr(cfg_addr_e a, int unsigned d);
    @(negedge clk);
    cfg_addr  = a;
    cfg_wdata = CFG_DATA_W'(d);
    cfg_we    = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cfg_we = 1'b0;
  endtask

  task automatic pulse_boundary();
    @(negedge clk);
    boundary = 1'b1;
    @(posedge clk);
    @(negedge clk);
    boundary = 1'b0;
    @(posedge clk);
    @(negedge clk);
  endtask

  initial begin
    cfg_addr = '0; cfg_wdata = '0; cfg_we = 1'b0; boundary = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    @(negedge clk);

    // --- reset gives a defined, SAFE configuration -----------------------
    // Not merely defined: all-zero weights and a zero order size mean a
    // freshly reset design cannot emit a trade before anyone configures it.
    check("reset w0",        policy_cfg.w0          === '0);
    check("reset w_spread",  policy_cfg.w_spread    === '0);
    check("reset order_qty", policy_cfg.order_qty   === '0);
    check("reset kill is ON", risk_cfg.kill         === 1'b1);
    check("reset commit count", commit_count        === '0);

    // --- a write alone changes nothing -----------------------------------
    wr(CFG_W0, 32'd1234);
    wr(CFG_W_SPREAD, 32'd4096);
    wr(CFG_ORDER_QTY, 32'd25);
    check("write without commit leaves w0",       policy_cfg.w0        === '0);
    check("write without commit leaves w_spread", policy_cfg.w_spread  === '0);
    check("write without commit leaves qty",      policy_cfg.order_qty === '0);

    // --- an armed commit alone changes nothing until a boundary ----------
    wr(CFG_COMMIT, 32'd1);
    repeat (4) @(posedge clk);
    @(negedge clk);
    check("armed commit without a boundary does nothing",
          policy_cfg.w0 === '0);
    check("commit count still zero", commit_count === '0);

    // --- the boundary applies everything at once -------------------------
    pulse_boundary();
    check("commit applies w0",       policy_cfg.w0        === W_W'(1234));
    check("commit applies w_spread", policy_cfg.w_spread  === W_W'(4096));
    check("commit applies qty",      policy_cfg.order_qty === QTY_W'(25));
    check("commit counted",          commit_count === 32'd1);

    // --- a second boundary does not re-apply -----------------------------
    pulse_boundary();
    check("commit does not re-arm itself", commit_count === 32'd1);

    // --- partial writes stay invisible until the next commit -------------
    wr(CFG_W0, 32'd7777);
    pulse_boundary();
    check("boundary without a commit changes nothing",
          policy_cfg.w0 === W_W'(1234));
    wr(CFG_COMMIT, 32'd1);
    pulse_boundary();
    check("second commit applies", policy_cfg.w0 === W_W'(7777));
    check("commit count 2",        commit_count === 32'd2);

    // --- atomicity: many writes, one visible transition ------------------
    wr(CFG_W0,          32'd11);
    wr(CFG_W_SPREAD,    32'd22);
    wr(CFG_W_IMBALANCE, 32'd33);
    wr(CFG_W_MOMENTUM,  32'd44);
    check("none of the four are visible yet",
          policy_cfg.w0 === W_W'(7777) && policy_cfg.w_imbalance === '0);
    wr(CFG_COMMIT, 32'd1);
    pulse_boundary();
    check("all four appear together",
          policy_cfg.w0          === W_W'(11) &&
          policy_cfg.w_spread    === W_W'(22) &&
          policy_cfg.w_imbalance === W_W'(33) &&
          policy_cfg.w_momentum  === W_W'(44));

    // --- risk fields ------------------------------------------------------
    wr(CFG_MAX_LONG,      32'd500);
    wr(CFG_MAX_SHORT,     32'd600);
    wr(CFG_MAX_ORDER_QTY, 32'd70);
    wr(CFG_MAX_SPREAD,    32'd800);
    wr(CFG_KILL,          32'd0);
    wr(CFG_COMMIT,        32'd1);
    pulse_boundary();
    check("max_long",      risk_cfg.max_long      === (POS_W-1)'(500));
    check("max_short",     risk_cfg.max_short     === (POS_W-1)'(600));
    check("max_order_qty", risk_cfg.max_order_qty === QTY_W'(70));
    check("max_spread",    risk_cfg.max_spread    === SPREAD_W'(800));
    check("kill cleared",  risk_cfg.kill          === 1'b0);

    // --- signed fields survive the trip -----------------------------------
    wr(CFG_W0,         32'hFFFF_F000);          // -4096
    wr(CFG_THETA_SELL, 32'hFFFF_FF00);          // -256
    wr(CFG_COMMIT, 32'd1);
    pulse_boundary();
    check("negative w0 survives",         policy_cfg.w0 === -W_W'(4096));
    check("negative theta_sell survives", policy_cfg.theta_sell === -SCORE_W'(256));

    // --- an unmapped address is ignored, not aliased ----------------------
    wr(cfg_addr_e'(5'd31), 32'hDEAD_BEEF);
    wr(CFG_COMMIT, 32'd1);
    pulse_boundary();
    check("unmapped write did not corrupt w0", policy_cfg.w0 === -W_W'(4096));

    // --- the kill switch can be re-armed ----------------------------------
    wr(CFG_KILL, 32'd1);
    wr(CFG_COMMIT, 32'd1);
    pulse_boundary();
    check("kill re-armed", risk_cfg.kill === 1'b1);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_config_regs");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
