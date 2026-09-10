#!/usr/bin/env python3
"""Search policy weights offline against a replayed synthetic trace.

This is the entire "AI customization" of the project, and it is deliberately
unglamorous: a seeded random search over four weights and two thresholds,
scored on a replay of generated events. No neural network, no inference on the
FPGA. What lands in hardware is six fixed-point numbers.

The objective is a synthetic score, not money. It rewards decisions that agree
with the next midprice move on the same symbol and penalises churn, which is
enough to make different weights produce visibly different behaviour -- the
property the hardware test then checks. It is NOT a claim that this policy is
profitable, and nothing downstream may present it as one.

The feature model here mirrors rtl/feature_engine.sv exactly, including the
reciprocal LUT, so a weight that looks good offline sees the same numbers in
hardware.
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from generate_events import (  # noqa: E402
    N_SYMBOLS, _empty_book, apply_to_book, generate,
)
from test_imbalance_model import imbalance_dut  # noqa: E402

IMB_ONE = 1 << 14


def replay_features(events: list[dict]) -> list[dict]:
    """Run a trace through the book and feature models from the spec.

    Returns one row per event with the features the RTL would compute.
    """
    books = [_empty_book() for _ in range(N_SYMBOLS)]
    prev_mid = [0] * N_SYMBOLS
    prev_valid = [False] * N_SYMBOLS
    rows = []
    for e in events:
        withheld = (e["bad_type"] or e["bad_side"] or e["bad_rsv"]
                    or e["gap"] or e["stale"])
        bk = books[e["symbol"]]
        if not withheld:
            apply_to_book(bk, e["etype"], e["side"], e["price"], e["qty"])

        both = bk["bid_valid"] and bk["ask_valid"]
        den = bk["bid_qty"] + bk["ask_qty"]
        empty = (not both) or den == 0
        if empty:
            spread = mid = imb = mom = 0
        else:
            spread = bk["ask_price"] - bk["bid_price"]
            mid = (bk["bid_price"] + bk["ask_price"]) >> 1
            imb = imbalance_dut(bk["bid_qty"], bk["ask_qty"])
            sym = e["symbol"]
            mom = (mid - prev_mid[sym]) if prev_valid[sym] else 0
        if not empty and not withheld:
            prev_mid[e["symbol"]] = mid
            prev_valid[e["symbol"]] = True

        rows.append({"symbol": e["symbol"], "spread": spread, "mid": mid,
                     "imbalance": imb, "momentum": mom, "empty": empty,
                     "withheld": withheld})
    return rows


def score_policy(rows: list[dict], w: dict) -> float:
    """Synthetic objective: agreement with the NEXT midprice move, minus churn.

    Explicitly not P&L. It exists to separate policies, not to value them.
    """
    next_mid = {}
    future = [0] * len(rows)
    for i in range(len(rows) - 1, -1, -1):
        r = rows[i]
        if not r["empty"]:
            future[i] = next_mid.get(r["symbol"], r["mid"]) - r["mid"]
            next_mid[r["symbol"]] = r["mid"]
    total, trades = 0.0, 0
    for r, fwd in zip(rows, future):
        if r["empty"] or r["withheld"]:
            continue
        s = (w["w_spread"] * r["spread"] + w["w_imbalance"] * r["imbalance"]
             + w["w_momentum"] * r["momentum"]) + w["w0"]
        if s > w["theta_buy"]:
            total += fwd
            trades += 1
        elif s < w["theta_sell"]:
            total -= fwd
            trades += 1
    return total - 0.05 * trades


def search(rows: list[dict], seed: int, iters: int) -> dict:
    rng = random.Random(seed)
    best, best_s = None, float("-inf")
    for _ in range(iters):
        w = {
            "w0":          rng.uniform(-200, 200),
            "w_spread":    rng.uniform(-2.0, 2.0),
            "w_imbalance": rng.uniform(-2.0, 2.0),
            "w_momentum":  rng.uniform(-2.0, 2.0),
            "theta_buy":   rng.uniform(50, 4000),
            "theta_sell":  -rng.uniform(50, 4000),
        }
        s = score_policy(rows, w)
        if s > best_s:
            best, best_s = w, s
    best["objective"] = best_s
    return best


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--events", type=int, default=4000)
    p.add_argument("--iters", type=int, default=400)
    p.add_argument("--out", type=Path)
    a = p.parse_args()

    events = generate(n=a.events, seed=a.seed, gap_rate=0.05, stale_rate=0.03,
                      bad_type_rate=0.02, bad_side_rate=0.02, bad_rsv_rate=0.01)
    rows = replay_features(events)
    best = search(rows, a.seed, a.iters)
    print(json.dumps(best, indent=2))
    if a.out:
        a.out.write_text(json.dumps(best, indent=2) + "\n")


if __name__ == "__main__":
    main()
