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
  localparam int LATENCY_CYCLES = LAT_DECODE + LAT_SEQCHK;

endpackage
/* verilator lint_on UNUSEDPARAM */

`endif
