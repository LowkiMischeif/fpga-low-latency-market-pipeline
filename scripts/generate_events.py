#!/usr/bin/env python3
"""Generate seeded synthetic market-event traces for the RTL testbenches.

Emits two files:
  <out>.hex           one 64-bit hex word per line, for $readmemh
  <out>_expected.csv  the golden decode of each word, plus the error flags
                      the RTL is expected to raise

The field layout here MUST match rtl/market_pkg.sv. It is duplicated rather
than imported because Python cannot read a SystemVerilog package;
test_field_layout_matches_market_pkg guards the duplication.

Note on trust: this generator produces both the stimulus and the expectations,
so a bug here and a matching bug in the RTL would agree with each other. That
is why tb_event_decoder.sv and tb_sequence_checker.sv also carry hand-written
directed vectors that never pass through this file, and why tb/assertions.sv
carries properties that hold for any trace at all.
"""
from __future__ import annotations

import argparse
import csv
import random
from pathlib import Path

EVENT_W = 64
SEQ_W = 16
SEQ_MOD = 1 << SEQ_W

# name -> (lsb, width), matching rtl/market_pkg.sv
FIELDS = {
    "rsv": (0, 2),
    "seq": (2, 16),
    "qty": (18, 16),
    "price": (34, 16),
    "side": (50, 2),
    "symbol": (52, 4),
    "etype": (56, 8),
}

VALID_TYPES = (1, 2, 3)   # EVT_ADD, EVT_CANCEL, EVT_TRADE
VALID_SIDES = (1, 2)      # SIDE_BID, SIDE_ASK

# Must match STALE_RESYNC_LIMIT in rtl/sequence_checker.sv.
STALE_RESYNC_LIMIT = 16

N_SYMBOLS = 1 << FIELDS["symbol"][1]
QTY_MAX = (1 << FIELDS["qty"][1]) - 1
# Price ladder the generator works on. A uniform draw over the full 16-bit
# range is what made CANCEL and TRADE useless as stimulus: the best bid
# converges on the largest price ever drawn and nothing matches it again.
PRICE_TICK = 4
PRICE_LEVELS_DEFAULT = 6


def _empty_book():
    return {"bid_valid": False, "bid_price": 0, "bid_qty": 0,
            "ask_valid": False, "ask_price": 0, "ask_qty": 0}


def apply_to_book(bk: dict, etype: int, side: int, price: int, qty: int) -> str:
    """Mirror of rtl/top_of_book.sv's update rules, trusted events only.

    The generator keeps this model so a CANCEL or TRADE can be aimed at the
    level that is actually resting. It is the same price-level-replace table
    as the RTL, including the qty == 0 rule; if one changes the other must --
    and the integrated replay in tb_book_features is what catches it when they
    do, because its coverage floors fail as soon as this model stops steering
    events onto real levels. The model shapes stimulus only; the oracle in
    that testbench is a separate reference derived from the raw 64-bit word.

    Returns the name of the rule that fired, so coverage is measured from the
    model rather than by retyping the same branch conditions elsewhere.
    """
    bid = side == 1
    vk, pk, qk = ("bid_valid", "bid_price", "bid_qty") if bid else \
                 ("ask_valid", "ask_price", "ask_qty")
    if etype == 1:                                   # ADD
        if qty == 0:
            return "add_qty0"
        better = (price > bk[pk]) if bid else (price < bk[pk])
        if not bk[vk] or better:
            bk[vk], bk[pk], bk[qk] = True, price, qty
            return "add_replace"
        if price == bk[pk]:
            before = bk[qk]
            bk[qk] = min(QTY_MAX, before + qty)
            return "add_sat" if before + qty > QTY_MAX else "add_accum"
        return "add_worse"
    if etype == 2:                                   # CANCEL
        if bk[vk] and price == bk[pk]:
            bk[vk], bk[pk], bk[qk] = False, 0, 0
            return "cancel_hit"
        return "cancel_miss"
    if etype == 3:                                   # TRADE
        if bk[vk] and price == bk[pk]:
            over = qty > bk[qk]
            bk[qk] = 0 if qty >= bk[qk] else bk[qk] - qty
            if bk[qk] == 0:
                bk[vk], bk[pk] = False, 0
                return "trade_floor" if over else "trade_to_zero"
            return "trade_hit"
        return "trade_miss"
    return "none"


def encode_event(etype: int, symbol: int, side: int, price: int,
                 qty: int, seq: int, rsv: int = 0) -> int:
    """Pack fields into one 64-bit beat. Each field is masked to its width."""
    vals = {"etype": etype, "symbol": symbol, "side": side,
            "price": price, "qty": qty, "seq": seq, "rsv": rsv}
    word = 0
    for name, (lsb, width) in FIELDS.items():
        word |= (vals[name] & ((1 << width) - 1)) << lsb
    return word


def decode_event(word: int) -> dict:
    """Unpack a 64-bit beat back into fields."""
    return {
        name: (word >> lsb) & ((1 << width) - 1)
        for name, (lsb, width) in FIELDS.items()
    }


def generate(n: int, seed: int, gap_rate: float = 0.0, stale_rate: float = 0.0,
             bad_type_rate: float = 0.0, bad_side_rate: float = 0.0,
             bad_rsv_rate: float = 0.0, start_seq: int = 0,
             price_levels: int = PRICE_LEVELS_DEFAULT, hit_rate: float = 0.6,
             zero_qty_rate: float = 0.05,
             big_qty_rate: float = 0.10,
             uniform_prices: bool = False) -> list[dict]:
    """Build n events with the requested defect rates.

    Returns one dict per event carrying the encoded word, the decoded fields,
    and the error flags the RTL must raise for it.

    Sequence model: `expect` is what an in-order feed would send next. A gap
    skips forward and resyncs the expectation past the hole; a stale event
    replays an older number without advancing the expectation.

    Crucially, only a TRUSTED event -- one with no encoding defect -- may
    resync the baseline or establish it after reset. A malformed beat has
    already failed its field checks, so its seq is not trustworthy either; it
    may ride the ordinary +1 when it lands exactly in order, but it may not
    redefine where the feed is. A long run of stale events forces a resync
    after STALE_RESYNC_LIMIT, which bounds the damage from sequence aliasing.

    This mirrors sequence_checker.sv exactly -- if one changes, so must the
    other. That is a real coupling and it is the point: the golden model has
    to be a model OF the RTL, not an independent guess at what it should do.
    """
    rng = random.Random(seed)
    events: list[dict] = []
    books = [_empty_book() for _ in range(N_SYMBOLS)]
    expect = start_seq % SEQ_MOD
    primed = False
    stale_run = 0

    def signed_diff(rx: int, exp: int) -> int:
        """16-bit modular difference, read as signed -- mirrors the RTL."""
        d = (rx - exp) % SEQ_MOD
        return d - SEQ_MOD if d >= (SEQ_MOD // 2) else d

    for i in range(n):
        # Encoding defects are decided FIRST, because whether the event is
        # trustworthy determines what it is allowed to do to the expectation.
        if rng.random() < bad_type_rate:
            etype, bad_type = rng.choice([0, 4, 5, 0x7F, 0xFF]), True
        else:
            etype, bad_type = rng.choice(VALID_TYPES), False

        if rng.random() < bad_side_rate:
            side, bad_side = rng.choice([0, 3]), True
        else:
            side, bad_side = rng.choice(VALID_SIDES), False

        if rng.random() < bad_rsv_rate:
            rsv, bad_rsv = rng.randint(1, 3), True
        else:
            rsv, bad_rsv = 0, False

        trusted = not (bad_type or bad_side or bad_rsv)

        # Choose the sequence number this event will carry.
        if primed and rng.random() < stale_rate:
            seq = (expect - rng.randint(1, 8)) % SEQ_MOD
        elif primed and rng.random() < gap_rate:
            seq = (expect + rng.randint(1, 8)) % SEQ_MOD
        else:
            seq = expect

        # Classify, then update state exactly as sequence_checker.sv does.
        diff = signed_diff(seq, expect)
        gap = primed and diff > 0
        stale = primed and diff < 0
        force_resync = stale and stale_run >= STALE_RESYNC_LIMIT - 1

        if not primed:
            if trusted:
                expect = (seq + 1) % SEQ_MOD
                primed = True
        elif diff == 0:
            expect = (seq + 1) % SEQ_MOD
        elif gap and trusted:
            expect = (seq + 1) % SEQ_MOD
        elif force_resync:
            expect = (seq + 1) % SEQ_MOD

        stale_run = stale_run + 1 if (stale and not force_resync) else 0

        symbol = rng.randrange(N_SYMBOLS)
        bk = books[symbol]
        bid = side == 1
        vk, pk = ("bid_valid", "bid_price") if bid else ("ask_valid", "ask_price")

        # Two symbols are reserved so the arithmetic corners are reachable from
        # a generated trace, not only from the hand-built ladder in
        # tb_book_features. Without them the integrated replay of this trace
        # cannot satisfy that testbench's saturation, den == 2 and full-scale
        # spread floors, and those floors would have to be scoped away.
        #
        #   symbol 0            tiny sizes, so bid_qty + ask_qty == 2 occurs
        #   symbol 1            one price level and huge sizes, so the 16-bit
        #                       resting size saturates -- two big adds have to
        #                       land on the SAME surviving level, which at a
        #                       random ladder price is down to luck (seed 31337
        #                       reached it zero times in 2000 events)
        #   symbol N_SYMBOLS-2  bids drawn ABOVE asks, so two-sided books on
        #                       this symbol are crossed by construction
        #   symbol N_SYMBOLS-1  prices at the top of the range, for a
        #                       full-scale spread
        #
        # Bid and ask draw from ladders offset from each other, so a two-sided
        # book is normally ordered rather than crossed. Sharing one ladder made
        # 83% of two-sided books crossed, which is worth testing but is not
        # what "two-sided coverage" should mostly mean.
        tiny_sym  = symbol == 0
        sat_sym   = symbol == 1                 # one price level, huge sizes
        wide_sym  = symbol == N_SYMBOLS - 1     # full-scale spread
        cross_sym = symbol == N_SYMBOLS - 2     # bid and ask share a ladder
        if wide_sym:
            # Bids at the bottom of the range, asks at the top, so ask - bid
            # is close to full scale.
            base = 0 if bid else (1 << FIELDS["price"][1]) - 1 - price_levels * PRICE_TICK
        elif cross_sym:
            # Deliberately INVERTED: bids drawn above asks, so a two-sided book
            # on this symbol is crossed by construction rather than whenever
            # the draw happens to overlap. Sharing one ladder left it to chance
            # and seed 42 produced 3 crossed books against a floor of 5.
            base = symbol * (price_levels * PRICE_TICK * 2)
            if bid:
                base += price_levels * PRICE_TICK
        else:
            base = symbol * (price_levels * PRICE_TICK * 2)
            if not bid:
                base += price_levels * PRICE_TICK    # asks sit above bids

        # Aim CANCEL and TRADE at the resting level most of the time. Left to a
        # uniform draw they never match it, and cancel-at-best, trade-at-best
        # and trade-to-zero are unreachable no matter how long the trace runs.
        # A big ADD only saturates if it lands ON the resting level -- at a
        # random ladder price it just replaces. Aim it, or 65535 is
        # unreachable however long the trace runs.
        big_add = etype == 1 and (sat_sym or rng.random() < big_qty_rate)
        if uniform_prices:
            # The pre-ladder behaviour, kept only so a test can demonstrate why
            # it was replaced. Not reachable from the CLI: nothing aims at the
            # resting level, so CANCEL and TRADE essentially never match it.
            price = rng.randrange(1 << FIELDS["price"][1])
        elif etype in (2, 3) and bk[vk] and rng.random() < hit_rate:
            price = bk[pk]
        elif big_add and bk[vk]:
            price = bk[pk]
        elif sat_sym:
            price = base            # a single level, so adds always accumulate
        else:
            price = base + rng.randrange(price_levels) * PRICE_TICK
        price &= (1 << FIELDS["price"][1]) - 1

        if etype == 3 and price == bk[pk] and bk[vk]:
            # Half the trades that hit should clear the level outright.
            resting = bk["bid_qty"] if bid else bk["ask_qty"]
            qty = resting + rng.randrange(4) if rng.random() < 0.5 \
                else rng.randint(1, max(1, resting))
        elif etype == 1 and rng.random() < zero_qty_rate:
            qty = 0
        elif tiny_sym:
            qty = rng.randint(1, 2)
        elif etype == 1 and big_add:
            qty = rng.randint(QTY_MAX // 2, QTY_MAX)
        else:
            qty = rng.randint(1, 64)
        qty = min(qty, QTY_MAX)

        # Deterministic prologue: two clean, sized events on symbol 0, one per
        # side, so bid_qty + ask_qty == 2 is reached on every seed. Left to the
        # draw it needs two qty-1 events on opposite sides of symbol 0 before
        # either accumulates, and seed 4242 never managed it. A coverage floor
        # that depends on the seed is not a floor.
        if i < 2:
            etype, side = 1, (1 if i == 0 else 2)
            symbol, qty = 0, 1
            price = 0 if i == 0 else PRICE_TICK * 4
            rsv = 0
            bad_type = bad_side = bad_rsv = False
            trusted = True
            bk = books[0]

        # Only a trusted event reaches the book, exactly as top_of_book gates
        # it. A gapped or stale event is withheld there too.
        if trusted and not gap and not stale:
            apply_to_book(bk, etype, side, price, qty)

        events.append({
            "word": encode_event(etype, symbol, side, price, qty, seq, rsv),
            "etype": etype, "symbol": symbol, "side": side,
            "price": price, "qty": qty, "seq": seq,
            "bad_type": bad_type, "bad_side": bad_side, "bad_rsv": bad_rsv,
            "gap": gap, "stale": stale,
        })
    return events


CSV_COLUMNS = ["word", "etype", "symbol", "side", "price", "qty", "seq",
               "bad_type", "bad_side", "bad_rsv", "gap", "stale"]


def write_trace(events: list[dict], out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    nibbles = EVENT_W // 4
    with open(out.parent / f"{out.name}.hex", "w") as fh:
        for e in events:
            fh.write(f"{e['word']:0{nibbles}x}\n")
    with open(out.parent / f"{out.name}_expected.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(CSV_COLUMNS)
        for e in events:
            w.writerow([f"{e['word']:0{nibbles}x}"] +
                       [int(e[c]) for c in CSV_COLUMNS[1:]])


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--n", type=int, default=1000)
    p.add_argument("--seed", type=int, required=True)
    p.add_argument("--out", type=Path, default=Path("tb/traces/random"))
    p.add_argument("--gap-rate", type=float, default=0.05)
    p.add_argument("--stale-rate", type=float, default=0.03)
    p.add_argument("--bad-type-rate", type=float, default=0.02)
    p.add_argument("--bad-side-rate", type=float, default=0.02)
    p.add_argument("--bad-rsv-rate", type=float, default=0.01)
    p.add_argument("--start-seq", type=int, default=0)
    p.add_argument("--price-levels", type=int, default=PRICE_LEVELS_DEFAULT,
                   help="distinct price levels per symbol per side")
    p.add_argument("--hit-rate", type=float, default=0.6,
                   help="fraction of CANCEL/TRADE aimed at the resting level")
    p.add_argument("--zero-qty-rate", type=float, default=0.05)
    p.add_argument("--big-qty-rate", type=float, default=0.10)
    a = p.parse_args()
    if not 1 <= a.price_levels <= 1024:
        p.error("--price-levels must be 1..1024; larger values alias one symbol's"
                " ladder onto another and destroy the per-symbol separation")
    for name in ("hit_rate", "zero_qty_rate", "big_qty_rate"):
        v = getattr(a, name)
        if not 0.0 <= v <= 1.0:
            p.error(f"--{name.replace('_','-')} must be between 0 and 1")

    events = generate(a.n, a.seed, a.gap_rate, a.stale_rate, a.bad_type_rate,
                      a.bad_side_rate, a.bad_rsv_rate, a.start_seq,
                      a.price_levels, a.hit_rate, a.zero_qty_rate,
                      a.big_qty_rate)
    write_trace(events, a.out)
    print(f"wrote {a.n} events to {a.out}.hex and {a.out}_expected.csv "
          f"(seed={a.seed})")


if __name__ == "__main__":
    main()
