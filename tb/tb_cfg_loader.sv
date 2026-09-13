// Directed tests for cfg_loader driving config_regs.
//
// The ground truth is the committed .cfg file, read independently of the .mem
// image the loader uses: after a load, every active field must equal what
// writing that .cfg by hand would have produced.
//
// Also pinned: every commit, whenever it lands, applies one whole preset --
// never a mix; a switch change during a load finishes and commits the load in
// progress, then loads the new preset with busy high throughout; and a reset
// released with the switch already on tuned ends on tuned.
module tb_cfg_loader;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic sw_preset = 1'b0, hold_off = 1'b0;
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

  // Whole-image monitor: every time commit_count moves, the active config must
  // be exactly one of the two presets.
  policy_cfg_t base_p, tuned_p;
  risk_cfg_t   base_r, tuned_r;
  logic [CNT_W-1:0] seen_commits = '0;
  int whole_commits = 0;
  always @(negedge clk) begin
    if (!rst_n || commit_count === '0) seen_commits = '0;
    else if (commit_count !== seen_commits) begin
      seen_commits = commit_count;
      whole_commits++;
      check($sformatf("commit %0d applies one whole preset", commit_count),
            (policy_cfg === base_p  && risk_cfg === base_r) ||
            (policy_cfg === tuned_p && risk_cfg === tuned_r));
    end
  end

  logic [CNT_W-1:0] c0;
  int  wguard;
  bit  saw_tuned;

  initial begin
    expect_from_cfg("tb/configs/baseline.cfg"); base_p  = exp_p; base_r  = exp_r;
    expect_from_cfg("tb/configs/tuned.cfg");    tuned_p = exp_p; tuned_r = exp_r;
    // The mid-load test below relies on the presets differing both before and
    // after the write at which the switch changes.
    check("premise: presets differ early and late in the image",
          base_p.w0 !== tuned_p.w0 && base_p.theta_sell !== tuned_p.theta_sell);

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

    // --- hold_off defers a due load, and busy reports it ----------------
    hold_off = 1'b1;
    sw_preset = 1'b1;
    repeat (40) @(negedge clk);
    check("hold_off defers the load", commit_count === 32'd3);
    check("busy reports the deferred load", busy === 1'b1);
    check("configuration untouched while deferred", policy_cfg === base_p && risk_cfg === base_r);
    hold_off = 1'b0;
    wait_loaded();
    check("deferred load lands once hold_off falls",
          policy_cfg === tuned_p && risk_cfg === tuned_r && commit_count === 32'd4);
    sw_preset = 1'b0;                    // back to baseline for the next test
    repeat (4) @(negedge clk);
    wait_loaded();
    check("fifth commit is baseline", policy_cfg === base_p && commit_count === 32'd5);

    // --- a switch change DURING a load -----------------------------------
    // Start a tuned load, flip the switch back at write 2. The load in
    // progress must commit whole, then baseline must load, and busy must not
    // fall between the two: an idle cycle there would let a replay start on
    // the intermediate configuration.
    c0 = commit_count;
    sw_preset = 1'b1;
    wguard = 0;
    while (!(busy === 1'b1 && u_load.idx == 2)) begin
      @(negedge clk);
      wguard++;
      if (wguard > 50) $fatal(1, "FAIL: tuned load never reached write 2");
    end
    sw_preset = 1'b0;
    saw_tuned = 1'b0; wguard = 0;
    while (commit_count !== c0 + 2) begin
      check("busy stays high across back-to-back loads", busy === 1'b1);
      if (commit_count === c0 + 1 && !saw_tuned) begin
        saw_tuned = 1'b1;
        check("interrupted load finished: tuned committed whole",
              policy_cfg === tuned_p && risk_cfg === tuned_r);
      end
      @(negedge clk);
      wguard++;
      if (wguard > 200) $fatal(1, "FAIL: back-to-back loads never committed twice");
    end
    check("the load in progress committed before the reload", saw_tuned);
    check("reload committed baseline as busy fell",
          busy === 1'b0 && policy_cfg === base_p && risk_cfg === base_r && preset === 1'b0);

    // --- reset mid-load, released with the switch on tuned ---------------
    sw_preset = 1'b1;
    repeat (4) @(negedge clk);
    check("premise: reset lands during a load", busy === 1'b1);
    rst_n = 1'b0;
    repeat (3) @(negedge clk);
    // busy includes a load that is due, and out of reset one always is.
    check("reset: kill armed, no commits, a load due",
          risk_cfg.kill === 1'b1 && commit_count === '0 && busy === 1'b1);
    rst_n = 1'b1;
    wait_loaded();
    check("reset with the switch on tuned ends on tuned",
          policy_cfg === tuned_p && risk_cfg === tuned_r && preset === 1'b1);
    check("reset: at least one commit", commit_count >= 1);
    $display("INFO: reset released with the switch on tuned: %0d commit(s) before busy fell",
             commit_count);

    // The monitor and wait_loaded wake on the same negedge; give it one more
    // so the last commit is counted. 3 + 2 (deferred tuned, then baseline) +
    // 2 (mid-load) + 2 (baseline, then tuned: the synchronizer resets to 0, so
    // the first load after a reset is always baseline).
    @(negedge clk);
    check("whole-image monitor saw every commit", whole_commits == 9);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_cfg_loader -- %0d commits, each one whole preset", whole_commits);
    $finish;
  end

  initial begin #200000; $fatal(1, "FAIL: timeout"); end
endmodule
