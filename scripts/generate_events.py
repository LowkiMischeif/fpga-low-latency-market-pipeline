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
             bad_rsv_rate: float = 0.0, start_seq: int = 0) -> list[dict]:
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
    expect = start_seq % SEQ_MOD
    primed = False
    stale_run = 0

    def signed_diff(rx: int, exp: int) -> int:
        """16-bit modular difference, read as signed -- mirrors the RTL."""
        d = (rx - exp) % SEQ_MOD
        return d - SEQ_MOD if d >= (SEQ_MOD // 2) else d

    for _ in range(n):
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

        symbol = rng.randrange(1 << FIELDS["symbol"][1])
        price = rng.randrange(1 << FIELDS["price"][1])
        qty = rng.randrange(1 << FIELDS["qty"][1])

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
    a = p.parse_args()

    events = generate(a.n, a.seed, a.gap_rate, a.stale_rate, a.bad_type_rate,
                      a.bad_side_rate, a.bad_rsv_rate, a.start_seq)
    write_trace(events, a.out)
    print(f"wrote {a.n} events to {a.out}.hex and {a.out}_expected.csv "
          f"(seed={a.seed})")


if __name__ == "__main__":
    main()
