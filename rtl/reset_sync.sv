// reset_sync.sv -- the design's single reset synchronizer (spec 3.3).
//
// Every other module resets asynchronously and has no synchronizer of its
// own. Asynchronous RELEASE is the hazard: on 7-series it can violate
// recovery/removal and drop flops out of reset on different cycles. This
// asserts asynchronously and releases through two flops, so rst_n leaves reset
// on a clock edge, and Vivado times that release as an ordinary recovery path.
module reset_sync (
  input  logic clk,
  input  logic arst_in,   // active high, asynchronous (a board button)
  output logic rst_n
);
  (* ASYNC_REG = "TRUE" *) logic stage1;
  (* ASYNC_REG = "TRUE" *) logic stage2;

  always_ff @(posedge clk or posedge arst_in) begin
    if (arst_in) begin
      stage1 <= 1'b0;
      stage2 <= 1'b0;
    end else begin
      stage1 <= 1'b1;
      stage2 <= stage1;
    end
  end

  assign rst_n = stage2;
endmodule
