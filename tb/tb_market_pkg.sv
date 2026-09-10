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
    if (LATENCY_CYCLES != LAT_DECODE + LAT_SEQCHK)
      $fatal(1, "FAIL: LATENCY_CYCLES is not the sum of its stages");
    if (LATENCY_CYCLES != 2)
      $fatal(1, "FAIL: expected 2 cycles on this branch, got %0d", LATENCY_CYCLES);

    // Encoding validators must accept exactly the defined encodings.
    if (!is_valid_type(EVT_ADD) || !is_valid_type(EVT_CANCEL) || !is_valid_type(EVT_TRADE))
      $fatal(1, "FAIL: is_valid_type rejects a defined encoding");
    if (is_valid_type(8'hFF)) $fatal(1, "FAIL: is_valid_type accepts 0xFF");
    if (is_valid_type(8'h00)) $fatal(1, "FAIL: is_valid_type accepts 0x00");
    if (!is_valid_side(SIDE_BID) || !is_valid_side(SIDE_ASK))
      $fatal(1, "FAIL: is_valid_side rejects a defined encoding");
    if (is_valid_side(2'b00) || is_valid_side(2'b11))
      $fatal(1, "FAIL: is_valid_side accepts an undefined encoding");

    // Structs must be packed and sized as expected.
    if ($bits(market_event_t) != TYPE_W + SYMBOL_W + SIDE_W + PRICE_W + QTY_W + SEQ_W)
      $fatal(1, "FAIL: market_event_t width %0d", $bits(market_event_t));
    if ($bits(event_err_t) != 5)
      $fatal(1, "FAIL: event_err_t must carry exactly 5 flags, got %0d", $bits(event_err_t));

    $display("PASS: tb_market_pkg");
    $finish;
  end
endmodule
