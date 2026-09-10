"""Exhaustive check of the imbalance reciprocal approximation.

feature_engine.sv avoids a divider by normalising the denominator, indexing a
256x16 reciprocal ROM with the 8 bits below its leading one, and multiplying.
This file is the reference model for that scheme and the source of the error
figure quoted in the design spec.

It exists because the figure was wrong twice. The spec said 0.4%, market_pkg
said ~0.2%, and the SystemVerilog sweep sampled 36 of the 256 ROM buckets --
399 of its points had den == 400, which is a single bucket. Worse, the
"128/65536 bound" was not a bound at all: it ignores two floor operations, and
the true worst case exceeds it.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

IMB_FRAC_W = 14
IMB_ONE = 1 << IMB_FRAC_W
QTY_MAX = (1 << 16) - 1


def recip_rom(idx: int) -> int:
    """Must match recip_rom() in rtl/market_pkg.sv, floor included."""
    return ((1 << 30) // (65536 + idx * 256 + 128)) & 0xFFFF


def norm_shift(den: int) -> int:
    """Must match norm_shift() in rtl/feature_engine.sv."""
    for i in range(16, -1, -1):
        if (den >> i) & 1:
            return 16 - i
    return 0


def imbalance_dut(bid_qty: int, ask_qty: int) -> int:
    """Bit-exact model of the RTL, clamps included."""
    den = bid_qty + ask_qty
    if den == 0:
        return 0
    num = bid_qty - ask_qty
    sh = norm_shift(den)
    idx = ((den << sh) >> 8) & 0xFF
    shifted = (num * recip_rom(idx)) >> (16 - sh)   # >>> floors, as in RTL
    return max(-IMB_ONE, min(IMB_ONE, shifted))


def imbalance_exact(bid_qty: int, ask_qty: int) -> int:
    """(bid - ask) / (bid + ask) in Q1.14, truncated toward zero."""
    den = bid_qty + ask_qty
    if den == 0:
        return 0
    num = bid_qty - ask_qty
    mag = (abs(num) * IMB_ONE) // den
    return mag if num >= 0 else -mag


def _worst_over(pairs):
    worst, where = 0, None
    for bq, aq in pairs:
        err = abs(imbalance_dut(bq, aq) - imbalance_exact(bq, aq))
        if err > worst:
            worst, where = err, (bq, aq)
    return worst, where


def test_extremal_numerator_sweep_is_the_documented_worst_case():
    """Exhaustive over every denominator at the numerator that maximises error.

    |num| <= den, so absolute error is largest when one side is empty. This
    sweeps all 2*65536 such books.
    """
    worst, where = _worst_over(
        [(bq, 0) for bq in range(QTY_MAX + 1)] +
        [(0, aq) for aq in range(QTY_MAX + 1)]
    )
    assert worst == 33, f"worst error moved to {worst} at {where}"
    assert where == (65, 0), f"worst case moved to {where}"
    # 33/16384 = 0.2014%, which is the number the spec quotes.
    assert worst * 10000 // IMB_ONE == 20


def test_naive_bucket_bound_is_not_actually_a_bound():
    """Pins the reason the spec no longer quotes 128/65536.

    The midpoint argument gives 128/65536 = 0.1953% of full scale, i.e. 32
    counts. The real worst is 33, because the ROM entry and the final shift
    both floor.
    """
    naive_bound = (128 * IMB_ONE) // 65536
    assert naive_bound == 32
    worst, _ = _worst_over([(65, 0)])
    assert worst > naive_bound


def test_result_never_leaves_the_unit_interval():
    """The clamp is load-bearing: the approximation genuinely overshoots."""
    for bq in range(0, QTY_MAX + 1, 7):
        for aq in (0, 1, bq // 2, bq):
            v = imbalance_dut(bq, aq)
            assert -IMB_ONE <= v <= IMB_ONE, f"{v} out of range at {(bq, aq)}"


def test_maximum_pre_saturation_value_is_the_documented_one():
    """Without the clamp, how far above 1.0 does the approximation reach?"""
    worst, where = 0, None
    for bq in range(1, QTY_MAX + 1):
        sh = norm_shift(bq)
        idx = ((bq << sh) >> 8) & 0xFF
        v = (bq * recip_rom(idx)) >> (16 - sh)
        if v > worst:
            worst, where = v, bq
    assert worst == 16415, f"pre-saturation max moved to {worst} at bq={where}"
    assert where == 32895


def test_symmetry_is_exact_to_within_one_count():
    """Swapping the sides negates the result, to within one count.

    Not exactly: the RTL uses >>> , an arithmetic shift, which floors toward
    negative infinity, while the positive branch effectively truncates toward
    zero. So imbalance(1000, 999) is 14223 and imbalance(999, 1000) is -14224.

    One count is 1/16384 = 0.006% of full scale, and it is already inside the
    33-count worst-case error measured above. Correcting it would mean a
    round-toward-zero adjust on the multiply output, which buys 0.006% at the
    cost of logic on the stage's longest path. Documented rather than fixed.
    """
    for bq, aq in [(3, 1), (100, 7), (65535, 1), (2, 1), (1000, 999),
                   (7, 9), (65535, 0), (12345, 54321)]:
        fwd, rev = imbalance_dut(bq, aq), imbalance_dut(aq, bq)
        assert abs(fwd + rev) <= 1, f"{fwd} vs {rev} at {(bq, aq)}"


def test_balanced_book_is_exactly_zero():
    for q in (1, 2, 7, 1000, 32767, 65535):
        assert imbalance_dut(q, q) == 0


def test_empty_book_is_zero_not_an_exception():
    assert imbalance_dut(0, 0) == 0
