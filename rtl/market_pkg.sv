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
  //   LAT_TOB            1  top_of_book       best bid/ask update   [planned]
  //   LAT_FEATURE        2  feature_engine    spread, imbalance     [planned]
  //   LAT_POLICY         2  policy_engine     MAC tree + compare    [planned]
  //   LAT_RISK           1  risk_gate         limit checks          [planned]
  //   ------------  ------
  //   LATENCY_CYCLES     2  <- sum of stages implemented today
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
  localparam int LATENCY_CYCLES = LAT_DECODE + LAT_SEQCHK + LAT_TOB + LAT_FEATURE;

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

  // ponytail: momentum is the change in midprice since that symbol's previous
  // book update -- one step, held per symbol. Deeper history means a
  // MOMENTUM_LAG-deep shift register per symbol; add it if the policy engine
  // turns out to need a longer horizon.
  localparam int MOMENTUM_LAG = 1;

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

endpackage
/* verilator lint_on UNUSEDPARAM */

`endif
