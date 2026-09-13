// Directed tests for cfg_loader driving config_regs.
//
// The ground truth is the committed .cfg file, read independently of the .mem
// image the loader uses: after a load, every active field must equal what
// writing that .cfg by hand would have produced.
module tb_cfg_loader;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic sw_preset = 1'b0;
  logic [CFG_ADDR_W-1:0] cfg_addr;
  logic [CFG_DATA_W-1:0] cfg_wdata;
  logic cfg_we, busy, preset;
  policy_cfg_t policy_cfg;
  risk_cfg_t   risk_cfg;
  logic [CNT_W-1:0] commit_count;

  cfg_loader  u_load (.*);
  config_regs u_regs (.*);

  int errors = 0;
  task automatic check(string name, logic cond);
    if (!cond) begin errors++; $error("FAIL: %s", name); end
  endtask

  // Expected active config, built by applying the .cfg file's writes in a
  // software model of the shadow/commit semantics.
  policy_cfg_t exp_p;
  risk_cfg_t   exp_r;
  task automatic expect_from_cfg(string path);
    int fd, a, d;
    string line;
    exp_p = '0; exp_r = '0;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "FAIL: cannot open %s", path);
    while ($fgets(line, fd) != 0) begin
      if (line.len() == 0 || line[0] == "#") continue;
      if ($sscanf(line, "%h %h", a, d) != 2) continue;
      case (CFG_ADDR_W'(a))
        CFG_W0:            exp_p.w0            = W_W'(d);
        CFG_W_SPREAD:      exp_p.w_spread      = W_W'(d);
        CFG_W_IMBALANCE:   exp_p.w_imbalance   = W_W'(d);
        CFG_W_MOMENTUM:    exp_p.w_momentum    = W_W'(d);
        CFG_THETA_BUY:     exp_p.theta_buy     = SCORE_W'(d);
        CFG_THETA_SELL:    exp_p.theta_sell    = SCORE_W'(d);
        CFG_ORDER_QTY:     exp_p.order_qty     = QTY_W'(d);
        CFG_MAX_LONG:      exp_r.max_long      = (POS_W-1)'(d);
        CFG_MAX_SHORT:     exp_r.max_short     = (POS_W-1)'(d);
        CFG_MAX_ORDER_QTY: exp_r.max_order_qty = QTY_W'(d);
        CFG_MAX_SPREAD:    exp_r.max_spread    = SPREAD_W'(d);
        CFG_KILL:          exp_r.kill          = d[0];
        default: ;
      endcase
    end
    $fclose(fd);
  endtask

  task automatic wait_loaded();
    int guard = 0;
    @(negedge clk);
    while (busy) begin @(negedge clk); guard++; if (guard > 200) $fatal(1, "FAIL: load hung"); end
  endtask

  initial begin
    repeat (3) @(posedge clk);
    check("reset config is killed", risk_cfg.kill === 1'b1);
    rst_n = 1'b1;

    // --- reset release loads the baseline preset ------------------------
    // Sampled on the first negedge busy is low, with no settle cycle: busy is
    // a promise that the configuration is active the moment it falls.
    wait_loaded();
    expect_from_cfg("tb/configs/baseline.cfg");
    check("baseline policy loaded", policy_cfg === exp_p);
    check("baseline risk loaded",   risk_cfg === exp_r);
    check("one commit",             commit_count === 32'd1);
    check("preset reports baseline", preset === 1'b0);

    // --- flipping the switch loads tuned ---------------------------------
    sw_preset = 1'b1;
    repeat (4) @(negedge clk);
    check("switch change starts a load", busy === 1'b1);
    wait_loaded();
    expect_from_cfg("tb/configs/tuned.cfg");
    check("tuned policy loaded", policy_cfg === exp_p);
    check("tuned risk loaded",   risk_cfg === exp_r);
    check("second commit",       commit_count === 32'd2);
    check("preset reports tuned", preset === 1'b1);

    // --- no switch change, no reload -------------------------------------
    repeat (50) @(negedge clk);
    check("steady switch does not reload", commit_count === 32'd2 && busy === 1'b0);

    // --- and back -------------------------------------------------------
    sw_preset = 1'b0;
    repeat (4) @(negedge clk);
    wait_loaded();
    expect_from_cfg("tb/configs/baseline.cfg");
    check("back to baseline", policy_cfg === exp_p && risk_cfg === exp_r);
    check("third commit", commit_count === 32'd3);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_cfg_loader");
    $finish;
  end

  initial begin #200000; $fatal(1, "FAIL: timeout"); end
endmodule
