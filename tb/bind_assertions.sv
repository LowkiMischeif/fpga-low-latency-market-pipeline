// bind_assertions.sv -- attach the property checkers to each pipeline stage.
//
// run_sim.tcl compiles every tb/*.sv into one library, so a bind written
// inside a testbench applies to ALL of them. Binding the same target twice
// under the same instance name is an elaboration error, so every bind in this
// project lives here, exactly once. Do not add a bind statement inside an
// individual testbench.
//
// The tag is seq_id. It is the only field present on both sides of every stage
// that no stage rewrites, which makes it the natural transaction identifier
// for the ordering / no-drop / no-duplicate properties. If a future stage does
// rewrite seq, this file is where that breaks and it should break loudly.
bind event_decoder handshake_checker #(
  .LATENCY(market_pkg::LAT_DECODE),
  .TAG_W  (market_pkg::SEQ_W),
  .PAY_W  ($bits(market_pkg::market_event_t) + $bits(market_pkg::event_err_t))
) u_chk (
  .clk(clk), .rst_n(rst_n),
  .s_valid(s_valid), .s_ready(s_ready),
  .m_valid(m_valid), .m_ready(m_ready),
  // The decoder's input is still the raw beat, so the tag is sliced out of it
  // with the same package constants the DUT uses. That is deliberate: this
  // property checks ordering, not field placement -- tb_event_decoder's
  // walking-ones vectors are what pin the layout down independently.
  .s_tag(s_data[market_pkg::SEQ_LSB +: market_pkg::SEQ_W]),
  .m_tag(m_event.seq),
  .m_payload({m_event, m_err})
);

bind sequence_checker handshake_checker #(
  .LATENCY(market_pkg::LAT_SEQCHK),
  .TAG_W  (market_pkg::SEQ_W),
  .PAY_W  ($bits(market_pkg::market_event_t) + $bits(market_pkg::event_err_t))
) u_chk (
  .clk(clk), .rst_n(rst_n),
  .s_valid(s_valid), .s_ready(s_ready),
  .m_valid(m_valid), .m_ready(m_ready),
  .s_tag(s_event.seq),
  .m_tag(m_event.seq),
  .m_payload({m_event, m_err})
);
