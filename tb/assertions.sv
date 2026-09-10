// assertions.sv -- handshake and latency properties that hold regardless of
// the trace being replayed. Bound into each stage by tb/bind_assertions.sv.
//
// This file exists from the first branch, not added later: fixed latency is
// the headline result of this project, so it is asserted from the first stage
// that has a latency to assert.
//
// These properties are the reason a buggy generator cannot quietly certify a
// buggy DUT -- none of them reference the trace at all.
module handshake_checker #(
  parameter int LATENCY = 1
) (
  input logic clk,
  input logic rst_n,
  input logic s_valid,
  input logic s_ready,
  input logic m_valid,
  input logic m_ready
);

  // A producer may not retract an offer: once valid is asserted it stays
  // asserted until the cycle ready is seen high.
  property p_no_valid_retraction_in;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && !s_ready) |=> s_valid;
  endproperty
  a_no_valid_retraction_in: assert property (p_no_valid_retraction_in)
    else $error("s_valid retracted before s_ready");

  property p_no_valid_retraction_out;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> m_valid;
  endproperty
  a_no_valid_retraction_out: assert property (p_no_valid_retraction_out)
    else $error("m_valid retracted before m_ready");

  // The headline claim, in its honest conditional form: with the output free
  // to drain, an accepted input appears at the output exactly LATENCY cycles
  // later -- not "at least", not "on average".
  property p_fixed_latency;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && s_ready && m_ready) |-> ##LATENCY m_valid;
  endproperty
  a_fixed_latency: assert property (p_fixed_latency)
    else $error("output did not appear exactly %0d cycles after accept", LATENCY);

  // No output may appear without an input having been accepted LATENCY cycles
  // earlier. Catches a stage inventing events out of nothing.
  property p_no_spontaneous_output;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && m_ready) |-> $past(s_valid && s_ready, LATENCY);
  endproperty
  a_no_spontaneous_output: assert property (p_no_spontaneous_output)
    else $error("output with no corresponding accepted input");

endmodule
