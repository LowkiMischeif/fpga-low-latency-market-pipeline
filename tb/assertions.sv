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

  // Conservation: a stage may never emit more events than it accepted, and may
  // never hold more than LATENCY of them in flight.
  //
  // The obvious formulation -- "every handoff had an accept exactly LATENCY
  // cycles ago" -- is wrong under backpressure, and the randomized replay
  // caught it: when m_ready is low the output waits, so by the time it is
  // handed off the accept is further back than LATENCY. Counting is the
  // formulation that holds with or without stalls.
  int unsigned in_count, out_count;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_count  <= '0;
      out_count <= '0;
    end else begin
      if (s_valid && s_ready) in_count  <= in_count  + 1;
      if (m_valid && m_ready) out_count <= out_count + 1;
    end
  end

  property p_no_spontaneous_output;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && m_ready) |-> (out_count < in_count);
  endproperty
  a_no_spontaneous_output: assert property (p_no_spontaneous_output)
    else $error("output handed off with no unconsumed input (in=%0d out=%0d)",
                in_count, out_count);

  // Structural depth: a pipeline with LATENCY registers cannot be holding more
  // than LATENCY events. Catches a stage that silently buffers.
  property p_bounded_in_flight;
    @(posedge clk) disable iff (!rst_n)
      (in_count - out_count) <= LATENCY;
  endproperty
  a_bounded_in_flight: assert property (p_bounded_in_flight)
    else $error("%0d events in flight, exceeds LATENCY=%0d",
                in_count - out_count, LATENCY);

endmodule
