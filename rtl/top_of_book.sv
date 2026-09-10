// top_of_book.sv -- best bid/ask per symbol, updated by the price-level
// replace rules in the design spec.
//
// This is explicitly a top-of-book model, not an order book: only the best
// level per side is tracked, so an event at any other price is not
// representable and is IGNORED rather than guessed at. A cancel at a level
// that is not tracked cannot be honoured, and pretending otherwise would
// corrupt the resting size.
//
// Trust gate: the book updates only on an event with no flag set. bad_type,
// bad_side, bad_rsv, gap and stale each withhold the update, and m_book_stale
// says so on the output. Same rule sequence_checker applies to expect_seq --
// state the pipeline acts on is never built from data it already distrusts.
// The event itself still passes through with its flags intact; risk_gate
// decides what the decision does about them.
//
// Latency: LAT_TOB (1 cycle) when m_ready is held high.
module top_of_book
  import market_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,

  input  market_event_t s_event,
  input  event_err_t    s_err,
  input  logic          s_valid,
  output logic          s_ready,

  output market_event_t m_event,
  output event_err_t    m_err,
  output book_t         m_book,        // the entry for m_event.symbol, post-update
  output logic          m_book_stale,  // this event did not reach the book
  output logic          m_valid,
  input  logic          m_ready
);

  book_t book [N_SYMBOLS];

  logic trusted;
  assign trusted = !(s_err.bad_type || s_err.bad_side || s_err.bad_rsv ||
                     s_err.gap      || s_err.stale);

  book_t cur, nxt;
  assign cur = book[s_event.symbol];

  // Resting size saturates on accumulation and floors on decrement; neither
  // may wrap, or a book that overflows once reports a tiny best size.
  function automatic logic [QTY_W-1:0] qty_add(input logic [QTY_W-1:0] a,
                                               input logic [QTY_W-1:0] b);
    logic [QTY_W:0] sum;
    sum = {1'b0, a} + {1'b0, b};
    return sum[QTY_W] ? {QTY_W{1'b1}} : sum[QTY_W-1:0];
  endfunction

  function automatic logic [QTY_W-1:0] qty_sub(input logic [QTY_W-1:0] a,
                                               input logic [QTY_W-1:0] b);
    return (b >= a) ? '0 : (a - b);
  endfunction

  always_comb begin
    nxt = cur;
    if (trusted) begin
      unique case (s_event.etype)

        EVT_ADD: begin
          if (s_event.side == SIDE_BID) begin
            if (!cur.bid_valid || (s_event.price > cur.bid_price)) begin
              nxt.bid_valid = 1'b1;
              nxt.bid_price = s_event.price;
              nxt.bid_qty   = s_event.qty;
            end else if (s_event.price == cur.bid_price) begin
              nxt.bid_qty   = qty_add(cur.bid_qty, s_event.qty);
            end
          end else begin
            // Ask side is mirrored: a LOWER price is the better offer.
            if (!cur.ask_valid || (s_event.price < cur.ask_price)) begin
              nxt.ask_valid = 1'b1;
              nxt.ask_price = s_event.price;
              nxt.ask_qty   = s_event.qty;
            end else if (s_event.price == cur.ask_price) begin
              nxt.ask_qty   = qty_add(cur.ask_qty, s_event.qty);
            end
          end
        end

        EVT_CANCEL: begin
          if (s_event.side == SIDE_BID) begin
            if (cur.bid_valid && (s_event.price == cur.bid_price)) begin
              nxt.bid_valid = 1'b0;
              nxt.bid_price = '0;
              nxt.bid_qty   = '0;
            end
          end else begin
            if (cur.ask_valid && (s_event.price == cur.ask_price)) begin
              nxt.ask_valid = 1'b0;
              nxt.ask_price = '0;
              nxt.ask_qty   = '0;
            end
          end
        end

        EVT_TRADE: begin
          if (s_event.side == SIDE_BID) begin
            if (cur.bid_valid && (s_event.price == cur.bid_price)) begin
              nxt.bid_qty = qty_sub(cur.bid_qty, s_event.qty);
              if (nxt.bid_qty == '0) begin
                nxt.bid_valid = 1'b0;
                nxt.bid_price = '0;
              end
            end
          end else begin
            if (cur.ask_valid && (s_event.price == cur.ask_price)) begin
              nxt.ask_qty = qty_sub(cur.ask_qty, s_event.qty);
              if (nxt.ask_qty == '0) begin
                nxt.ask_valid = 1'b0;
                nxt.ask_price = '0;
              end
            end
          end
        end

        default: ;   // unreachable: a bad type is not trusted
      endcase
    end
  end

  assign s_ready = m_ready || !m_valid;

  logic accept;
  assign accept = s_valid && s_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_valid      <= 1'b0;
      m_event      <= '0;
      m_err        <= '0;
      m_book       <= '0;
      m_book_stale <= 1'b0;
      for (int i = 0; i < N_SYMBOLS; i++) book[i] <= '0;
    end else begin
      if (s_ready) begin
        m_valid      <= s_valid;
        m_event      <= s_event;
        m_err        <= s_err;
        m_book       <= nxt;
        m_book_stale <= !trusted;
      end
      if (accept && trusted) book[s_event.symbol] <= nxt;
    end
  end

endmodule
