// market_pkg.sv -- single source of truth for the pipeline's widths, enums,
// structs and latency accounting. Every module imports this; no module
// declares a width or an encoding of its own.
`ifndef MARKET_PKG_SV
`define MARKET_PKG_SV

// Lint waiver. UNUSEDPARAM fires on every constant this package exports that
// no module in rtl/ happens to reference yet -- PRICE_FRAC_W until
// feature_engine lands, N_SYMBOLS until top_of_book, LATENCY_CYCLES because
// only the testbench assertions consume it. A package is an exported
// interface, so "unused by the RTL that exists today" is not a defect the way
// it would be for a module-local parameter.
//
// Scoped to this file deliberately: -Wno-UNUSEDPARAM in the Makefile would
// disable the check for every module too, where it is worth having. The cost
// of this waiver is that a genuinely dead constant here will not be flagged;
// the periodic review for that is to grep for each name across rtl/ and tb/.
/* verilator lint_off UNUSEDPARAM */
package market_pkg;

  // ---------------------------------------------------------------------
  // Event wire format: one 64-bit beat.
  //
  //  63    56 55  52 51 50 49    34 33   18 17        2 1  0
  //  +-------+------+----+--------+-------+----------+-----+
  //  | type  |symbol|side| price  |  qty  | seq_id   | rsv |
  //  |  8b   |  4b  | 2b |  16b   |  16b  |   16b    | 2b  |
  //  +-------+------+----+--------+-------+----------+-----+
  // ---------------------------------------------------------------------
  localparam int EVENT_W  = 64;
  localparam int TYPE_W   = 8;
  localparam int SYMBOL_W = 4;
  localparam int SIDE_W   = 2;
  localparam int PRICE_W  = 16;
  localparam int QTY_W    = 16;
  localparam int SEQ_W    = 16;
  localparam int RSV_W    = 2;

  // Field LSBs are derived, not written out, so the layout cannot drift from
  // the widths above. tb_market_pkg asserts they tile EVENT_W exactly.
  localparam int RSV_LSB    = 0;
  localparam int SEQ_LSB    = RSV_LSB    + RSV_W;
  localparam int QTY_LSB    = SEQ_LSB    + SEQ_W;
  localparam int PRICE_LSB  = QTY_LSB    + QTY_W;
  localparam int SIDE_LSB   = PRICE_LSB  + PRICE_W;
  localparam int SYMBOL_LSB = SIDE_LSB   + SIDE_W;
  localparam int TYPE_LSB   = SYMBOL_LSB + SYMBOL_W;

  // Price is unsigned Q14.2 -- quarter-tick resolution. Fixed point, never
  // float, per the project's non-negotiables.
  localparam int PRICE_FRAC_W = 2;

  localparam int N_SYMBOLS = 1 << SYMBOL_W;

  // Telemetry counter width. Counters saturate rather than wrap, so a long
  // run cannot silently roll a count back to zero.
  localparam int CNT_W = 32;

  // ---------------------------------------------------------------------
  // Encodings.
  //
  // These enums are deliberately NOT exhaustive over their bit widths. The
  // decoder's job includes classifying arbitrary garbage, so an out-of-range
  // encoding is a defined input, not an impossible one. Modules compare
  // against these constants via the validator functions below and never cast
  // a raw field to an enum type.
  // ---------------------------------------------------------------------
  typedef enum logic [TYPE_W-1:0] {
    EVT_ADD    = 8'h01,
    EVT_CANCEL = 8'h02,
    EVT_TRADE  = 8'h03
  } event_type_e;

  typedef enum logic [SIDE_W-1:0] {
    SIDE_BID = 2'b01,
    SIDE_ASK = 2'b10
  } side_e;

  function automatic logic is_valid_type(input logic [TYPE_W-1:0] t);
    return (t == EVT_ADD) || (t == EVT_CANCEL) || (t == EVT_TRADE);
  endfunction

  function automatic logic is_valid_side(input logic [SIDE_W-1:0] s);
    return (s == SIDE_BID) || (s == SIDE_ASK);
  endfunction

  // ---------------------------------------------------------------------
  // Payloads.
  //
  // Error flags travel ALONGSIDE the event rather than inside it: risk_gate
  // rejects on these and they must survive to the end of the pipeline.
  // ---------------------------------------------------------------------
  typedef struct packed {
    logic [TYPE_W-1:0]   etype;
    logic [SYMBOL_W-1:0] symbol;
    logic [SIDE_W-1:0]   side;
    logic [PRICE_W-1:0]  price;
    logic [QTY_W-1:0]    qty;
    logic [SEQ_W-1:0]    seq;
  } market_event_t;

  typedef struct packed {
    logic bad_type;   // type field outside {ADD, CANCEL, TRADE}
    logic bad_side;   // side field outside {BID, ASK}
    logic bad_rsv;    // reserved bits non-zero
    logic gap;        // sequence jumped forward
    logic stale;      // sequence went backward (duplicate or reorder)
  } event_err_t;

  // ---------------------------------------------------------------------
  // Input-to-decision latency in clock cycles, for non-stalled traffic
  // (m_ready held high). Every stage registers its output exactly once.
  //
  //   constant      cycles  stage             contribution
  //   ------------  ------  ----------------  ------------------------------
  //   LAT_DECODE         1  event_decoder     field slice + encoding checks
  //   LAT_SEQCHK         1  sequence_checker  gap / stale classification
  //   LAT_TOB            1  top_of_book       best bid/ask update
  //   LAT_FEATURE        2  feature_engine    spread, imbalance
  //   LAT_POLICY         2  policy_engine     MAC tree + compare
  //   LAT_RISK           1  risk_gate         limit checks
  //   ------------  ------
  //   LATENCY_CYCLES     8  <- sum of stages implemented today, all of them
  //
  // Stages marked [planned] are not yet in rtl/ and contribute nothing. When
  // a stage lands, its constant and its row here are added in the same commit
  // as the module, and tb/assertions.sv proves the new total. The design
  // target is 8; that number does not appear here until the RTL achieves it.
  // ---------------------------------------------------------------------
  localparam int LAT_DECODE     = 1;
  localparam int LAT_SEQCHK     = 1;
  localparam int LAT_TOB        = 1;
  localparam int LAT_FEATURE    = 2;
  localparam int LAT_POLICY     = 2;
  localparam int LAT_RISK       = 1;
  localparam int LATENCY_CYCLES = LAT_DECODE + LAT_SEQCHK + LAT_TOB
                                + LAT_FEATURE + LAT_POLICY + LAT_RISK;


  // ---------------------------------------------------------------------
  // Top of book.
  //
  // Only the best level per side is tracked. A cleared side is marked by its
  // valid bit, never by a sentinel price -- zero is a legal price in Q14.2,
  // so "no bid" and "a bid at 0.00" must stay distinguishable.
  // ---------------------------------------------------------------------
  typedef struct packed {
    logic               bid_valid;
    logic [PRICE_W-1:0] bid_price;
    logic [QTY_W-1:0]   bid_qty;
    logic               ask_valid;
    logic [PRICE_W-1:0] ask_price;
    logic [QTY_W-1:0]   ask_qty;
  } book_t;

  // ---------------------------------------------------------------------
  // Features.
  //
  // spread is signed: a crossed book (bid above ask) is representable rather
  // than wrapping to a huge positive number.
  // imbalance is signed Q1.14 -- (Q_bid - Q_ask) / (Q_bid + Q_ask), so it is
  // mathematically bounded to [-1, +1] and IMB_W carries one integer bit so
  // both endpoints are representable.
  // ---------------------------------------------------------------------
  localparam int SPREAD_W   = PRICE_W + 1;
  localparam int MOM_W      = PRICE_W + 1;
  localparam int IMB_FRAC_W = 14;
  localparam int IMB_W      = IMB_FRAC_W + 2;
  localparam int IMB_ONE    = 1 <<< IMB_FRAC_W;

  // Momentum is the change in midprice since that symbol's previous book
  // update: one step, one register per symbol.
  //
  // There was a MOMENTUM_LAG constant here. It was referenced nowhere in rtl/
  // or tb/, so changing it silently did nothing -- a knob that is not wired to
  // anything is worse than no knob, because the next person will turn it. If
  // the policy engine turns out to need a longer horizon, that is a
  // MOMENTUM_LAG-deep shift register per symbol and it can be added then, with
  // a test that proves the depth matters.

  typedef struct packed {
    logic signed [SPREAD_W-1:0] spread;
    logic        [PRICE_W-1:0]  mid;
    logic signed [IMB_W-1:0]    imbalance;
    logic signed [MOM_W-1:0]    momentum;
    logic                       book_empty;   // one or both sides absent
  } feature_t;

  // ---------------------------------------------------------------------
  // Reciprocal ROM for the imbalance divide.
  //
  // A divider is the one piece of real arithmetic this design cannot avoid,
  // and a restoring divider either costs a cycle per quotient bit or becomes
  // the critical path. Instead the denominator is normalised to [2**16,
  // 2**17), the 8 bits below its leading one index this table, and the result
  // is one multiply and a shift:
  //
  //   den   = Q_bid + Q_ask                       (DEN_W bits)
  //   sh    = 16 - floor(log2(den))
  //   dn    = den << sh                           in [2**16, 2**17)
  //   idx   = dn[15:8]
  //   recip = ROM[idx] ~= 2**30 / (2**16 + idx*256 + 128)
  //   imb   = (Q_bid - Q_ask) * recip >>> (16 - sh)
  //
  // Indexing the bucket midpoint bounds the relative error at 128/65536, so
  // ~0.2% of full scale -- below what the downstream fixed-point policy can
  // resolve. Values land in [8200, 16352], hence RECIP_W = 16.
  // ---------------------------------------------------------------------
  localparam int DEN_W       = QTY_W + 1;
  localparam int RECIP_IDX_W = 8;
  localparam int RECIP_ROM_N = 1 << RECIP_IDX_W;
  localparam int RECIP_W     = 16;

  // Built by a constant function rather than a generated file: the table is
  // one expression, and a checked-in .mem would be a second source of truth
  // for it. tb_market_pkg asserts it is non-zero and monotonically decreasing.
  function automatic logic [RECIP_W-1:0] recip_rom(input logic [RECIP_IDX_W-1:0] idx);
    int unsigned den_mid;
    den_mid = 65536 + (int'(idx) * 256) + 128;
    return RECIP_W'((1 << 30) / den_mid);
  endfunction

  // ---------------------------------------------------------------------
  // Policy configuration.
  //
  // Weights are signed Q3.12: range about +/-8, resolution 1/4096. That is
  // the ONLY place scaling lives -- the features keep their natural units
  // (spread and momentum in Q14.2 ticks, imbalance in Q1.14) and each weight
  // absorbs the conversion. Normalising the features first would cost a
  // divide or a shift per feature on the pipeline's widest path and buy
  // nothing the offline tuner cannot do for free.
  //
  // The tuner in scripts/train_policy.py searches in floating point and
  // scripts/export_config.py quantises to exactly these formats; the same
  // constants are parsed out of this file by the Python side, so the two
  // cannot drift silently.
  // ---------------------------------------------------------------------
  localparam int W_W       = 16;
  localparam int W_FRAC_W  = 12;
  localparam int SCORE_W   = 32;

  typedef struct packed {
    logic signed [W_W-1:0]     w0;          // constant term, score units
    logic signed [W_W-1:0]     w_spread;
    logic signed [W_W-1:0]     w_imbalance;
    logic signed [W_W-1:0]     w_momentum;
    logic signed [SCORE_W-1:0] theta_buy;
    logic signed [SCORE_W-1:0] theta_sell;
    logic        [QTY_W-1:0]   order_qty;   // size this policy would send
  } policy_cfg_t;

  // ---------------------------------------------------------------------
  // Risk configuration and outcomes.
  // ---------------------------------------------------------------------
  localparam int POS_W = 24;   // signed net position, wider than any limit

  typedef struct packed {
    logic        [POS_W-2:0]   max_long;      // magnitude, so unsigned
    logic        [POS_W-2:0]   max_short;
    logic        [QTY_W-1:0]   max_order_qty;
    logic signed [SPREAD_W-1:0] max_spread;   // widest tradeable spread
    logic                      kill;          // 1 = reject everything
  } risk_cfg_t;

  typedef enum logic [1:0] {
    DEC_HOLD = 2'd0,
    DEC_BUY  = 2'd1,
    DEC_SELL = 2'd2
  } decision_e;

  // Why a decision was suppressed. RSN_NONE means it was not: a HOLD that the
  // policy genuinely chose is RSN_NONE, a BUY the risk gate refused is not.
  // Telemetry needs to tell those apart.
  typedef enum logic [3:0] {
    RSN_NONE       = 4'd0,
    RSN_KILL       = 4'd1,
    RSN_MALFORMED  = 4'd2,   // bad_type / bad_side / bad_rsv from the decoder
    RSN_SEQUENCE   = 4'd3,   // gap or stale
    RSN_BOOK_EMPTY = 4'd4,
    RSN_SPREAD     = 4'd5,   // wider than max_spread, and the book is real
    RSN_MAX_QTY    = 4'd6,
    RSN_MAX_LONG   = 4'd7,
    RSN_MAX_SHORT  = 4'd8
  } reason_e;

  typedef struct packed {
    decision_e                 decision;
    reason_e                   reason;
    logic        [QTY_W-1:0]   order_qty;
    logic signed [SCORE_W-1:0] score;
    logic signed [POS_W-1:0]   position;   // net position AFTER this decision
  } decision_t;

  // Saturating signed accumulate in score units. Every accumulation in the
  // policy path uses this: a weighted sum that wraps would turn a strong sell
  // signal into a strong buy.
  function automatic logic signed [SCORE_W-1:0] score_sat_add(
      input logic signed [SCORE_W-1:0] a, input logic signed [SCORE_W-1:0] b);
    logic signed [SCORE_W:0] sum;
    sum = {a[SCORE_W-1], a} + {b[SCORE_W-1], b};
    if (sum[SCORE_W] != sum[SCORE_W-1])
      return sum[SCORE_W] ? {1'b1, {(SCORE_W-1){1'b0}}}    // most negative
                          : {1'b0, {(SCORE_W-1){1'b1}}};   // most positive
    return sum[SCORE_W-1:0];
  endfunction

  // ---------------------------------------------------------------------
  // Configuration register map.
  //
  // A plain synchronous write port -- not PCIe, not AXI. Writes land in a
  // SHADOW copy and only become active when a commit is taken at an event
  // boundary, so a decision is never built from half of one weight set and
  // half of another. See config_regs.sv.
  // ---------------------------------------------------------------------
  localparam int CFG_ADDR_W = 5;
  localparam int CFG_DATA_W = 32;

  typedef enum logic [CFG_ADDR_W-1:0] {
    CFG_W0            = 5'd0,
    CFG_W_SPREAD      = 5'd1,
    CFG_W_IMBALANCE   = 5'd2,
    CFG_W_MOMENTUM    = 5'd3,
    CFG_THETA_BUY     = 5'd4,
    CFG_THETA_SELL    = 5'd5,
    CFG_ORDER_QTY     = 5'd6,
    CFG_MAX_LONG      = 5'd7,
    CFG_MAX_SHORT     = 5'd8,
    CFG_MAX_ORDER_QTY = 5'd9,
    CFG_MAX_SPREAD    = 5'd10,
    CFG_KILL          = 5'd11,
    CFG_COMMIT        = 5'd12   // write 1 to arm; takes effect at a boundary
  } cfg_addr_e;

endpackage
/* verilator lint_on UNUSEDPARAM */

`endif
