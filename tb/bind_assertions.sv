// bind_assertions.sv -- attach the property checkers to each pipeline stage.
//
// run_sim.tcl compiles every tb/*.sv into one library, so a bind written
// inside a testbench applies to ALL of them. Binding the same target twice
// under the same instance name is an elaboration error, so every bind in this
// project lives here, exactly once. Do not add a bind statement inside an
// individual testbench.
bind event_decoder handshake_checker #(.LATENCY(market_pkg::LAT_DECODE))
  u_chk (.clk(clk), .rst_n(rst_n),
         .s_valid(s_valid), .s_ready(s_ready),
         .m_valid(m_valid), .m_ready(m_ready));
