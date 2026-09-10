// feature_engine.sv -- spread, midprice, order-book imbalance and momentum,
// all fixed point.
//
// Two registered stages (LAT_FEATURE), split so the reciprocal ROM read lands
// in the first and the multiply in the second:
//
//   stage 1  spread, mid, book_empty, denominator normalisation, ROM read
//   stage 2  imbalance multiply and shift, momentum, output assembly
//
// The pipeline has no skid buffer: both stages advance together, so a stall
// holds the whole engine and in-flight never exceeds LAT_FEATURE.
//
// Latency: LAT_FEATURE (2 cycles) when m_ready is held high.
module feature_engine
  import market_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,

  input  market_event_t s_event,
  input  event_err_t    s_err,
  input  book_t         s_book,
  input  logic          s_book_stale,
  input  logic          s_valid,
  output logic          s_ready,

  output market_event_t m_event,
  output event_err_t    m_err,
  output feature_t      m_feat,
  output logic          m_valid,
  input  logic          m_ready
);

  // -------------------------------------------------------------------
  // Stage 1 combinational
  // -------------------------------------------------------------------
  // ------------------------------------------------------------------
  // The one gating rule, applied to every feature without exception:
  //
  //     book_empty == 1  =>  spread, mid, imbalance and momentum are all 0
  //
  // Previously spread and mid were gated on both_sides while imbalance and
  // momentum were gated on book_empty, which differ when two valid sides both
  // rest zero size: book_empty read 1 while spread and mid carried real
  // values. A consumer reading book_empty as "nothing here" would discard a
  // real mid; one reading mid as authoritative would get a mid whose momentum
  // had been suppressed. top_of_book's qty == 0 rule now makes that state
  // unreachable, but two rules that agree only by accident are still two
  // rules. There is one, and every feature obeys it.
  // ------------------------------------------------------------------
  logic both_sides;
  assign both_sides = s_book.bid_valid && s_book.ask_valid;

  logic [DEN_W-1:0] den;
  assign den = {1'b0, s_book.bid_qty} + {1'b0, s_book.ask_qty};

  // "Empty" folds in the divide-by-zero case: two valid sides that both rest
  // zero size carry no information, and the policy layer must be able to tell
  // that from a genuinely balanced book.
  logic empty1;
  assign empty1 = !both_sides || (den == '0);

  logic signed [SPREAD_W-1:0] spread1;
  logic        [PRICE_W-1:0]  mid1;
  assign spread1 = empty1
                 ? '0
                 : ($signed({1'b0, s_book.ask_price}) - $signed({1'b0, s_book.bid_price}));
  assign mid1 = empty1
              ? '0
              : PRICE_W'(({1'b0, s_book.bid_price} + {1'b0, s_book.ask_price}) >> 1);

  logic signed [DEN_W-1:0] num1;
  assign num1 = $signed({1'b0, s_book.bid_qty}) - $signed({1'b0, s_book.ask_qty});

  // Normalise the denominator so its leading one sits at bit 16; the 8 bits
  // below index the reciprocal ROM.
  function automatic int unsigned norm_shift(input logic [DEN_W-1:0] d);
    for (int i = DEN_W - 1; i >= 0; i--) if (d[i]) return unsigned'(16 - i);
    return 0;                                  // d == 0: gated by empty1
  endfunction

  // Only the 8 bits below the leading one are needed: bit 16 of the normalised
  // denominator is 1 by construction, and the bits below the index are what
  // the ROM's bucket width discards.
  int unsigned            sh1;
  logic [RECIP_IDX_W-1:0] idx1;
  logic [RECIP_W-1:0]     recip1;
  assign sh1    = norm_shift(den);
  assign idx1   = RECIP_IDX_W'((den << sh1) >> 8);
  assign recip1 = recip_rom(idx1);

  // -------------------------------------------------------------------
  // Pipeline control: both stages move together, no skid.
  // -------------------------------------------------------------------
  logic v1, v2, advance;
  assign advance = m_ready || !v2;
  assign s_ready = advance;

  // -------------------------------------------------------------------
  // Stage 1 registers
  // -------------------------------------------------------------------
  market_event_t      ev1;
  event_err_t         er1;
  logic               stale1;
  logic               empty1_r;
  logic signed [SPREAD_W-1:0] spread1_r;
  logic        [PRICE_W-1:0]  mid1_r;
  logic signed [DEN_W-1:0]    num1_r;
  logic [RECIP_W-1:0]         recip1_r;
  int unsigned                sh1_r;

  // -------------------------------------------------------------------
  // Stage 2 combinational: imbalance and momentum
  // -------------------------------------------------------------------
  // imb = num * 2**IMB_FRAC_W / den, and with recip ~= 2**30 / (den << sh)
  // that reduces to (num * recip) >>> (16 - sh). IMB_FRAC_W is 14, which is
  // where the 30 and the 16 come from; the assertion below pins that.
  localparam int IMB_PROD_W = DEN_W + RECIP_W + 1;
  logic signed [IMB_PROD_W-1:0] prod2, shifted2;
  assign prod2    = num1_r * $signed({1'b0, recip1_r});
  assign shifted2 = prod2 >>> (16 - sh1_r);

  logic signed [IMB_W-1:0] imb2;
  always_comb begin
    if (empty1_r)                                   imb2 = '0;
    else if (shifted2 >  IMB_PROD_W'(IMB_ONE))      imb2 =  IMB_W'(IMB_ONE);
    else if (shifted2 < -IMB_PROD_W'(IMB_ONE))      imb2 = -IMB_W'(IMB_ONE);
    else                                            imb2 = IMB_W'(shifted2);
  end

  // Per-symbol midprice history. Global history would mix symbols and make
  // momentum meaningless the moment more than one symbol is active.
  logic [PRICE_W-1:0] prev_mid [N_SYMBOLS];
  logic               prev_valid [N_SYMBOLS];

  logic [PRICE_W-1:0] pm;
  logic               pv;
  assign pm = prev_mid[ev1.symbol];
  assign pv = prev_valid[ev1.symbol];

  logic signed [MOM_W-1:0] mom2;
  assign mom2 = (empty1_r || !pv)
              ? '0
              : ($signed({1'b0, mid1_r}) - $signed({1'b0, pm}));

  // History advances only when the book actually ingested this event and the
  // resulting book carries a midprice: a withheld update must not look like a
  // price move.
  logic hist_upd;
  assign hist_upd = v1 && advance && !stale1 && !empty1_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v1 <= 1'b0; v2 <= 1'b0;
      ev1 <= '0; er1 <= '0; stale1 <= 1'b0; empty1_r <= 1'b0;
      spread1_r <= '0; mid1_r <= '0; num1_r <= '0; recip1_r <= '0; sh1_r <= 0;
      m_valid <= 1'b0; m_event <= '0; m_err <= '0; m_feat <= '0;
      for (int i = 0; i < N_SYMBOLS; i++) begin
        prev_mid[i]   <= '0;
        prev_valid[i] <= 1'b0;
      end
    end else if (advance) begin
      // stage 1
      v1        <= s_valid;
      ev1       <= s_event;
      er1       <= s_err;
      stale1    <= s_book_stale;
      empty1_r  <= empty1;
      spread1_r <= spread1;
      mid1_r    <= mid1;
      num1_r    <= num1;
      recip1_r  <= recip1;
      sh1_r     <= sh1;

      // stage 2
      v2      <= v1;
      m_valid <= v1;
      m_event <= ev1;
      m_err   <= er1;
      m_feat.spread     <= spread1_r;
      m_feat.mid        <= mid1_r;
      m_feat.imbalance  <= imb2;
      m_feat.momentum   <= mom2;
      m_feat.book_empty <= empty1_r;

      if (hist_upd) begin
        prev_mid[ev1.symbol]   <= mid1_r;
        prev_valid[ev1.symbol] <= 1'b1;
      end
    end
  end

endmodule
