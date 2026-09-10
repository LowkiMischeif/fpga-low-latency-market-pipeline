// assertions.sv -- handshake, ordering and latency properties that hold
// regardless of the trace being replayed. Bound into each stage by
// tb/bind_assertions.sv.
//
// This file exists from the first branch, not added later: fixed latency is
// the headline result of this project, so it is asserted from the first stage
// that has a latency to assert.
//
// These properties are the reason a buggy generator cannot quietly certify a
// buggy DUT -- none of them reference the trace at all.
//
// Liveness note. A property that never sees its antecedent proves nothing, and
// a green run with a vacuous property is worse than no property because it
// looks like coverage. Each property below records which testbench exercises
// its antecedent. Anything marked "stimulus-only" constrains the driver, not
// the DUT, and cannot be broken by mutating rtl/ -- that is a statement about
// the property, not an excuse for it.
module handshake_checker #(
  parameter int LATENCY = 1,
  // Width of the field used as a per-transaction tag. seq_id is the tag in
  // this design: it is present on both sides of every stage and no stage
  // rewrites it.
  parameter int TAG_W   = 1,
  // Everything the stage hands downstream, concatenated. Only checked for
  // stability under stall and for X, never for value -- a stage is allowed to
  // transform its payload, it is not allowed to change it mid-offer.
  parameter int PAY_W   = 1
) (
  input logic             clk,
  input logic             rst_n,
  input logic             s_valid,
  input logic             s_ready,
  input logic             m_valid,
  input logic             m_ready,
  input logic [TAG_W-1:0] s_tag,
  input logic [TAG_W-1:0] m_tag,
  input logic [PAY_W-1:0] m_payload
);

  // -------------------------------------------------------------------
  // Bookkeeping used by the properties below.
  // -------------------------------------------------------------------

  // Conservation counters. Declared first so the properties can read them.
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

  // Counting alone cannot tell a dropped event from a duplicated one when the
  // two happen together, and it cannot see reordering at all. Model the stage
  // as the FIFO it claims to be: push the tag of every accepted input, pop on
  // every output handoff, and require the tags to match in order.
  //
  // This is the "output tag == input tag" and "no event duplicated or dropped"
  // requirement, and it holds for any trace whatsoever -- it never reads the
  // golden CSV.
  logic [TAG_W-1:0] tag_q [$];
  int unsigned      tag_errors;
  // xsim rejects tag_q.size() inside a property expression, so the depth is
  // mirrored into a plain variable for a_queue_matches_counters to sample.
  int unsigned      q_depth;

  always_ff @(posedge clk or negedge rst_n) begin
    logic [TAG_W-1:0] popped;
    if (!rst_n) begin
      tag_q.delete();
      tag_errors <= '0;
      q_depth    <= '0;
    end else begin
      // Pop before push: an event accepted on this same edge cannot be the one
      // handed off on it, because every stage registers its output.
      if (m_valid && m_ready) begin
        if (tag_q.size() == 0) begin
          tag_errors <= tag_errors + 1;
          $error("output handoff with an empty in-flight queue (tag %0h)", m_tag);
        end else begin
          popped = tag_q.pop_front();
          if (popped !== m_tag) begin
            tag_errors <= tag_errors + 1;
            $error("tag mismatch: expected %0h at the output, got %0h",
                   popped, m_tag);
          end
        end
      end
      if (s_valid && s_ready) tag_q.push_back(s_tag);
      q_depth <= tag_q.size();
    end
  end

  // -------------------------------------------------------------------
  // Handshake legality
  // -------------------------------------------------------------------

  // A producer may not retract an offer: once valid is asserted it stays
  // asserted until the cycle ready is seen high.
  //
  // Liveness: stimulus-only at the first stage (it constrains the testbench
  // driver). Live at the sequence_checker input, where the producer is
  // event_decoder's output register. Exercised by tb_decode_validate's
  // hold-valid driver and by the stall phases of the directed testbenches.
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

  // Payload stability. A stage that recomputes its output register while the
  // downstream is stalled corrupts an event it has already offered.
  // sequence_checker is specifically exposed to this: its flags are a function
  // of an expect_seq that moves, so reloading the output register during a
  // stall would silently restamp an offered event as stale.
  //
  // Liveness: needs m_ready to deassert while m_valid is high, which only
  // tb_decode_validate and the directed stall phases produce.
  property p_out_payload_stable;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> ($stable(m_tag) && $stable(m_payload));
  endproperty
  a_out_payload_stable: assert property (p_out_payload_stable)
    else $error("offered output payload changed during a stall");

  property p_in_payload_stable;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && !s_ready) |=> $stable(s_tag);
  endproperty
  a_in_payload_stable: assert property (p_in_payload_stable)
    else $error("offered input payload changed during a stall");

  // An offered output must be fully defined. Catches a reset path that leaves
  // part of the payload uninitialised and a bind that silently picked up an
  // unconnected signal.
  property p_no_x_when_valid;
    @(posedge clk) disable iff (!rst_n)
      m_valid |-> !$isunknown({m_tag, m_payload});
  endproperty
  a_no_x_when_valid: assert property (p_no_x_when_valid)
    else $error("m_valid high with X/Z in the payload");

  // -------------------------------------------------------------------
  // Latency
  // -------------------------------------------------------------------

  // The headline claim, in its honest conditional form: with the output free
  // to drain, an accepted input appears at the output exactly LATENCY cycles
  // later -- not "at least", not "on average".
  //
  // Lint note: verilator 5.032 cannot parse a parameterised cycle delay in a
  // sequence expression ("Unsupported: ## id cycle delay range expression"),
  // so this one property is hidden from it. xsim -- which is what actually
  // runs the simulation and evaluates the assertion -- sees it. Hiding the
  // single unsupported property rather than excluding the whole file keeps
  // the other twelve under `make lint-tb`.
  //
  // The consequence is explicit: verilator never checks THIS property's
  // syntax, so a typo inside it surfaces only when make sim runs. That is
  // acceptable because no CI job runs xsim anyway; make sim-all is the gate.
`ifndef VERILATOR
  // The tag comparison is the whole property. Without it this reads
  //   (accept) |-> ##LATENCY m_valid
  // which on a pipeline that stays full is satisfied by whatever event happens
  // to be presenting -- m_valid is high nearly every cycle, so the property
  // passes no matter what the stage did, and it cannot see an inserted
  // register. Requiring that the event accepted at T is the one presenting at
  // T+LATENCY is what makes "exactly LATENCY" mean anything.
  //
  // The antecedent also requires m_ready to have been high for the whole
  // window, not merely at the accept: under backpressure the output waits, and
  // the fixed-latency claim is explicitly conditional on a drainable output.
  property p_fixed_latency;
    @(posedge clk) disable iff (!rst_n)
      // m_ready[*LATENCY] starting at the accept makes the antecedent span
      // cycles T .. T+LATENCY-1, and an implication counts from the END of its
      // antecedent -- so the consequent is ##1, not ##LATENCY. Getting that
      // wrong lands the check at T+2*LATENCY-1 and it fires on correct RTL.
      (s_valid && s_ready && m_ready) ##0 m_ready[*LATENCY]
        |-> ##1 (m_valid && m_tag == $past(s_tag, LATENCY));
  endproperty
  a_fixed_latency: assert property (p_fixed_latency)
    else $error("event accepted %0d cycles ago is not the one presenting (tag %0h)",
                LATENCY, m_tag);
`endif

  // The other half of "exactly": nothing may come out EARLY either, and a
  // drained pipe must be silent. Without this, a stage that asserted m_valid
  // out of reset would satisfy p_fixed_latency trivially.
  property p_no_early_output;
    @(posedge clk) disable iff (!rst_n)
      (in_count == out_count) |-> !m_valid;
  endproperty
  a_no_early_output: assert property (p_no_early_output)
    else $error("m_valid high with an empty pipe (in=%0d out=%0d)",
                in_count, out_count);

  // -------------------------------------------------------------------
  // Conservation
  // -------------------------------------------------------------------

  // A stage may never emit more events than it accepted.
  //
  // The obvious formulation -- "every handoff had an accept exactly LATENCY
  // cycles ago" -- is wrong under backpressure, and the randomized replay
  // caught it: when m_ready is low the output waits, so by the time it is
  // handed off the accept is further back than LATENCY. Counting is the
  // formulation that holds with or without stalls.
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

  // The queue model is the same invariant said a second way; if it and the
  // counters ever disagree, one of them is wrong and that is worth knowing.
  property p_queue_matches_counters;
    @(posedge clk) disable iff (!rst_n)
      (tag_errors == 0) |-> (q_depth == (in_count - out_count));
  endproperty
  a_queue_matches_counters: assert property (p_queue_matches_counters)
    else $error("in-flight queue depth %0d disagrees with counters %0d",
                q_depth, in_count - out_count);

endmodule
