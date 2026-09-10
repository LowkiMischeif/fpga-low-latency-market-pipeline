// sequence_checker.sv -- classify each event against the expected feed
// sequence number and count what was missed.
//
// Policy is FLAG, FORWARD, RESYNC. Gapped and stale events are marked and
// passed downstream; risk_gate decides what to do about them, because that is
// where the decision is visible to the policy layer and counted in telemetry.
//
// Latency: LAT_SEQCHK (1 cycle) when m_ready is held high.
module sequence_checker
  import market_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,

  input  market_event_t    s_event,
  input  event_err_t       s_err,
  input  logic             s_valid,
  output logic             s_ready,

  output market_event_t    m_event,
  output event_err_t       m_err,
  output logic             m_valid,
  input  logic             m_ready,

  output logic [CNT_W-1:0] gap_count,
  output logic [CNT_W-1:0] stale_count,
  output logic [CNT_W-1:0] missed_total,
  output logic [CNT_W-1:0] bad_event_count
);

  logic [SEQ_W-1:0] expect_seq;
  logic             primed;      // have we seen any event since reset?

  // Sequence numbers are 16 bits and wrap. A magnitude comparison would call
  // every wrap a ~65000-event gap, so compare the MODULAR DIFFERENCE and
  // interpret it as signed: positive is a gap, negative is stale, zero is in
  // order. Correct for any real gap below 2**(SEQ_W-1).
  logic signed [SEQ_W-1:0] diff;
  assign diff = $signed(s_event.seq - expect_seq);

  logic is_gap, is_stale;
  assign is_gap   = primed && (diff > 0);
  assign is_stale = primed && (diff < 0);

  assign s_ready = m_ready || !m_valid;

  logic accept;
  assign accept = s_valid && s_ready;

  event_err_t d_err;
  always_comb begin
    d_err       = s_err;      // preserve the decoder's flags
    d_err.gap   = is_gap;
    d_err.stale = is_stale;
  end

  logic upstream_bad;
  assign upstream_bad = s_err.bad_type || s_err.bad_side || s_err.bad_rsv;

  // Counters saturate rather than wrap: telemetry that silently rolls over is
  // worse than telemetry that pegs at its maximum.
  function automatic logic [CNT_W-1:0] sat_add(input logic [CNT_W-1:0] a,
                                               input logic [CNT_W-1:0] b);
    logic [CNT_W:0] sum;
    sum = {1'b0, a} + {1'b0, b};
    return sum[CNT_W] ? {CNT_W{1'b1}} : sum[CNT_W-1:0];
  endfunction

  // diff is positive whenever is_gap holds, so a zero-extend is correct here.
  logic [CNT_W-1:0] missed_ext;
  assign missed_ext = {{(CNT_W-SEQ_W){1'b0}}, diff};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_valid         <= 1'b0;
      m_event         <= '0;
      m_err           <= '0;
      expect_seq      <= '0;
      primed          <= 1'b0;
      gap_count       <= '0;
      stale_count     <= '0;
      missed_total    <= '0;
      bad_event_count <= '0;
    end else begin
      if (s_ready) begin
        m_valid <= s_valid;
        m_event <= s_event;
        m_err   <= d_err;
      end

      if (accept) begin
        primed <= 1'b1;

        // The first event after reset defines the baseline rather than being
        // measured against zero, so a trace starting mid-stream is not a gap.
        // A stale event does NOT advance the expectation.
        if (!primed || (diff >= 0)) begin
          expect_seq <= s_event.seq + 1'b1;
        end

        if (is_gap) begin
          gap_count    <= sat_add(gap_count, 32'd1);
          missed_total <= sat_add(missed_total, missed_ext);
        end
        if (is_stale) begin
          stale_count <= sat_add(stale_count, 32'd1);
        end
        if (upstream_bad) begin
          bad_event_count <= sat_add(bad_event_count, 32'd1);
        end
      end
    end
  end

endmodule
