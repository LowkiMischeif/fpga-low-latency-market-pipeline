// Elaboration test for market_pkg: every exported symbol is referenced here,
// so a missing or renamed constant is a compile error rather than a silent
// problem three modules later.
module tb_market_pkg;
  import market_pkg::*;

  initial begin
    // Field layout must tile the 64-bit beat exactly, with no gap or overlap.
    if (TYPE_LSB + TYPE_W != EVENT_W)
      $fatal(1, "FAIL: fields do not tile EVENT_W: TYPE_LSB=%0d TYPE_W=%0d EVENT_W=%0d",
             TYPE_LSB, TYPE_W, EVENT_W);
    if (RSV_LSB != 0)                      $fatal(1, "FAIL: RSV_LSB must be 0");
    if (SEQ_LSB    != RSV_LSB + RSV_W)     $fatal(1, "FAIL: SEQ_LSB");
    if (QTY_LSB    != SEQ_LSB + SEQ_W)     $fatal(1, "FAIL: QTY_LSB");
    if (PRICE_LSB  != QTY_LSB + QTY_W)     $fatal(1, "FAIL: PRICE_LSB");
    if (SIDE_LSB   != PRICE_LSB + PRICE_W) $fatal(1, "FAIL: SIDE_LSB");
    if (SYMBOL_LSB != SIDE_LSB + SIDE_W)   $fatal(1, "FAIL: SYMBOL_LSB");

    if (N_SYMBOLS != (1 << SYMBOL_W)) $fatal(1, "FAIL: N_SYMBOLS");

    // The enum encodings themselves, against the literals in the design spec.
    // Comparing EVT_ADD to EVT_ADD would prove nothing; these are the numbers
    // the wire format is defined in terms of and the numbers
    // generate_events.py hardcodes.
    if (EVT_ADD    !== 8'h01) $fatal(1, "FAIL: EVT_ADD is %0h, spec says 01", EVT_ADD);
    if (EVT_CANCEL !== 8'h02) $fatal(1, "FAIL: EVT_CANCEL is %0h, spec says 02", EVT_CANCEL);
    if (EVT_TRADE  !== 8'h03) $fatal(1, "FAIL: EVT_TRADE is %0h, spec says 03", EVT_TRADE);
    if (SIDE_BID   !== 2'b01) $fatal(1, "FAIL: SIDE_BID is %0b, spec says 01", SIDE_BID);
    if (SIDE_ASK   !== 2'b10) $fatal(1, "FAIL: SIDE_ASK is %0b, spec says 10", SIDE_ASK);

    // Encoding validators must accept EXACTLY the defined encodings. Spot
    // checks at 0x00 and 0xFF miss the encoding that actually matters -- 0x04,
    // one past EVT_TRADE -- so sweep the whole field. 256 iterations at
    // elaboration time costs nothing and this is the file that is supposed to
    // pin the single source of truth down.
    for (int t = 0; t < 256; t++)
      if (is_valid_type(t[TYPE_W-1:0]) !== (t inside {1, 2, 3}))
        $fatal(1, "FAIL: is_valid_type(%0h) = %0b, spec says %0b",
               t, is_valid_type(t[TYPE_W-1:0]), t inside {1, 2, 3});
    for (int sd = 0; sd < 4; sd++)
      if (is_valid_side(sd[SIDE_W-1:0]) !== (sd inside {1, 2}))
        $fatal(1, "FAIL: is_valid_side(%0b) = %0b, spec says %0b",
               sd, is_valid_side(sd[SIDE_W-1:0]), sd inside {1, 2});

    // Structs must be packed and sized as expected.
    if ($bits(market_event_t) != TYPE_W + SYMBOL_W + SIDE_W + PRICE_W + QTY_W + SEQ_W)
      $fatal(1, "FAIL: market_event_t width %0d", $bits(market_event_t));
    if ($bits(event_err_t) != 5)
      $fatal(1, "FAIL: event_err_t must carry exactly 5 flags, got %0d", $bits(event_err_t));

    // ---- book + feature stages -------------------------------------
    if (LATENCY_CYCLES != LAT_DECODE + LAT_SEQCHK + LAT_TOB + LAT_FEATURE)
      $fatal(1, "FAIL: LATENCY_CYCLES is not the sum of its stages");
    if (LATENCY_CYCLES != 5)
      $fatal(1, "FAIL: expected 5 cycles on this branch, got %0d", LATENCY_CYCLES);
    if (LAT_TOB != 1)     $fatal(1, "FAIL: LAT_TOB");
    if (LAT_FEATURE != 2) $fatal(1, "FAIL: LAT_FEATURE");

    // A cleared book side must be a validity bit, never a sentinel price:
    // zero is a legal price in Q14.2.
    if ($bits(book_t) != 2 * (1 + PRICE_W + QTY_W))
      $fatal(1, "FAIL: book_t width %0d", $bits(book_t));

    // Imbalance is signed Q1.14, so +/-1.0 must be representable.
    if (IMB_ONE != (1 <<< IMB_FRAC_W))
      $fatal(1, "FAIL: IMB_ONE %0d != 2**IMB_FRAC_W", IMB_ONE);
    if (IMB_W <= IMB_FRAC_W)
      $fatal(1, "FAIL: IMB_W must exceed IMB_FRAC_W to hold +/-1.0");

    // The reciprocal ROM the feature engine indexes.
    if (RECIP_IDX_W != 8)    $fatal(1, "FAIL: RECIP_IDX_W");
    if (RECIP_ROM_N != 256)  $fatal(1, "FAIL: RECIP_ROM_N");
    // Every entry must be non-zero: a zero would silently produce a zero
    // imbalance for a perfectly valid book.
    begin
      logic [RECIP_W-1:0] prev, cur;
      for (int i = 0; i < RECIP_ROM_N; i++) begin
        cur = recip_rom(RECIP_IDX_W'(i));
        if (cur == '0) $fatal(1, "FAIL: recip_rom(%0d) is zero", i);
        // Monotonically decreasing: a larger denominator cannot have a larger
        // reciprocal. Catches an off-by-one in the table generator.
        if (i > 0 && cur >= prev)
          $fatal(1, "FAIL: recip_rom not decreasing at %0d (%0d >= %0d)",
                 i, cur, prev);
        prev = cur;
      end
    end

    $display("PASS: tb_market_pkg");
    $finish;
  end
endmodule
