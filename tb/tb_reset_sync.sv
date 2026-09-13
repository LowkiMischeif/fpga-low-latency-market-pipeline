// Directed tests for reset_sync: the single reset synchronizer spec 3.3
// promises. Assertion must be asynchronous (no clock needed); release must be
// synchronous and take exactly two rising edges; a re-assertion during release
// must restart it.
module tb_reset_sync;
  logic clk = 1'b0, arst_in = 1'b0, rst_n;
  always #5 clk = ~clk;
  reset_sync dut (.*);

  int errors = 0;
  task automatic check(string name, logic cond);
    if (!cond) begin errors++; $error("FAIL: %s", name); end
  endtask

  initial begin
    // Establish released state.
    arst_in = 1'b1; #12; arst_in = 1'b0;
    repeat (4) @(posedge clk); #1;
    check("released after reset", rst_n === 1'b1);

    // Asynchronous assert: mid-cycle, no clock edge.
    @(posedge clk); #2;
    arst_in = 1'b1; #1;
    check("assert is immediate, without a clock edge", rst_n === 1'b0);

    // Synchronous release: exactly two rising edges.
    @(negedge clk); arst_in = 1'b0;
    @(posedge clk); #1;
    check("still in reset after one edge", rst_n === 1'b0);
    @(posedge clk); #1;
    check("released on the second edge", rst_n === 1'b1);

    // Re-assert during release restarts it.
    @(negedge clk); arst_in = 1'b1;
    @(negedge clk); arst_in = 1'b0;
    @(posedge clk); #1;
    @(negedge clk); arst_in = 1'b1; #1;
    check("re-assert during release forces reset again", rst_n === 1'b0);
    @(negedge clk); arst_in = 1'b0;
    @(posedge clk); #1;
    check("restarted release: one edge is not enough", rst_n === 1'b0);
    @(posedge clk); #1;
    check("restarted release: two edges", rst_n === 1'b1);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_reset_sync");
    $finish;
  end
endmodule
