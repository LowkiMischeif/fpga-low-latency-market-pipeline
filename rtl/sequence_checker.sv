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
  output logic [CNT_W-1:0] bad_event_count,
  output logic [CNT_W-1:0] resync_count
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
  // Gated on is_gap so the signal is never carrying a sign-extended negative
  // value that a later reader might pick up by mistake.
  logic [CNT_W-1:0] missed_ext;
  assign missed_ext = is_gap ? {{(CNT_W-SEQ_W){1'b0}}, diff} : '0;

  // ---------------------------------------------------------------------
  // Aliasing beyond the +/-32767 window, and how the damage is bounded.
  //
  // A 16-bit modular comparison cannot distinguish a forward jump of 32768+
  // from a backward jump, or vice versa -- the information is simply not on
  // the wire. Both directions alias:
  //
  //   forward jump of 32768   -> reads as stale (diff = -32768)
  //   backward jump of 40000  -> reads as a gap of 25536
  //
  // Without a bound, the first case is unrecoverable: a stale event does not
  // advance expect_seq, so the checker stays frozen and reports every one of
  // the next 32768 events as stale while gap_count and missed_total sit still,
  // i.e. telemetry insists the feed is clean.
  //
  // The window itself cannot be widened without a wider seq_id on the wire or
  // an epoch counter, neither of which this format has. What is fixed here is
  // the unbounded consequence: after STALE_RESYNC_LIMIT consecutive stale
  // events the checker gives up on its baseline and adopts the current
  // sequence number, so any aliasing costs at most that many events instead of
  // 32768. Each forced resync is counted, so the condition is visible rather
  // than silent.
  // ---------------------------------------------------------------------
  localparam int STALE_RESYNC_LIMIT = 16;
  localparam int STALE_RUN_W        = $clog2(STALE_RESYNC_LIMIT + 1);

  logic [STALE_RUN_W-1:0] stale_run;
  logic                   force_resync;
  assign force_resync = is_stale && (stale_run >= STALE_RUN_W'(STALE_RESYNC_LIMIT - 1));

  // A malformed beat has already failed its encoding checks, so no field in it
  // is trustworthy -- including seq. It may advance the expectation by the
  // ordinary +1 when it lands exactly in order, but it may never RESYNC the
  // baseline to an arbitrary value, and it may never move the gap counters.
  // Otherwise one corrupt beat redefines the feed's sequence origin and every
  // legitimate event after it reads as stale.
  logic trusted;
  assign trusted = !upstream_bad;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_valid         <= 1'b0;
      m_event         <= '0;
      m_err           <= '0;
      expect_seq      <= '0;
      primed          <= 1'b0;
      stale_run       <= '0;
      resync_count    <= '0;
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
        // Only a trusted event may establish the baseline. A malformed first
        // event must not define where the feed starts.
        if (trusted) primed <= 1'b1;

        // Expectation update, in priority order:
        //   - unprimed: a trusted event adopts its own seq as the baseline, so
        //     a trace starting mid-stream is not one enormous gap
        //   - exactly in order: advance, trusted or not (diff == 0 is not a
        //     claim about an untrusted field, it agrees with what we expected)
        //   - a gap: resync past the hole, but only on a trusted event
        //   - stale: hold, unless the run is long enough that the baseline is
        //     probably the thing that is wrong
        if (!primed) begin
          if (trusted) expect_seq <= s_event.seq + 1'b1;
        end else if (diff == '0) begin
          expect_seq <= s_event.seq + 1'b1;
        end else if (is_gap && trusted) begin
          expect_seq <= s_event.seq + 1'b1;
        end else if (force_resync) begin
          expect_seq <= s_event.seq + 1'b1;
        end

        // Consecutive-stale run, used only by the watchdog above.
        if (is_stale && !force_resync) stale_run <= stale_run + 1'b1;
        else                           stale_run <= '0;

        if (force_resync) resync_count <= sat_add(resync_count, 32'd1);

        // Gap telemetry comes only from trusted events: a garbage seq must not
        // be able to inflate missed_total by up to 32767 in one beat.
        if (is_gap && trusted) begin
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
