// event_decoder.sv -- slice one 64-bit market-event beat into its fields and
// classify malformed encodings.
//
// Malformed events are FLAGGED AND FORWARDED, never dropped: discarding
// market data is risk_gate's decision, where it is visible to the policy
// layer and counted in telemetry.
//
// Latency: LAT_DECODE (1 cycle) when m_ready is held high.
module event_decoder
  import market_pkg::*;
(
  input  logic               clk,
  input  logic               rst_n,

  // upstream
  input  logic [EVENT_W-1:0] s_data,
  input  logic               s_valid,
  output logic               s_ready,

  // downstream
  output market_event_t      m_event,
  output event_err_t         m_err,
  output logic               m_valid,
  input  logic               m_ready
);

  market_event_t d_event;
  event_err_t    d_err;

  always_comb begin
    d_event.etype  = s_data[TYPE_LSB   +: TYPE_W];
    d_event.symbol = s_data[SYMBOL_LSB +: SYMBOL_W];
    d_event.side   = s_data[SIDE_LSB   +: SIDE_W];
    d_event.price  = s_data[PRICE_LSB  +: PRICE_W];
    d_event.qty    = s_data[QTY_LSB    +: QTY_W];
    d_event.seq    = s_data[SEQ_LSB    +: SEQ_W];

    d_err          = '0;
    d_err.bad_type = ~is_valid_type(d_event.etype);
    d_err.bad_side = ~is_valid_side(d_event.side);
    d_err.bad_rsv  = |s_data[RSV_LSB +: RSV_W];
    // gap and stale belong to sequence_checker; leave them clear here.
  end

  // No-skid handshake: accept whenever the output register is free or is
  // being drained this cycle. ready propagates combinationally upstream, so
  // the pipeline stalls as a unit with no bubble and no reordering.
  assign s_ready = m_ready || !m_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_valid <= 1'b0;
      m_event <= '0;
      m_err   <= '0;
    end else if (s_ready) begin
      m_valid <= s_valid;
      m_event <= d_event;
      m_err   <= d_err;
    end
  end

endmodule
