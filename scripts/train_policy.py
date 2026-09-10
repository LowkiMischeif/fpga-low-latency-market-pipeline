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


W_FRAC_W = 12


def quantise_weights(w: dict) -> dict:
    """Round a candidate to the formats export_config.py will emit.

    The search scores QUANTISED candidates, not the floats it drew. Searching
    in float and quantising afterwards would let the tuner pick a policy whose
    hardware twin behaves differently -- which is exactly the failure the
    phrase "offline-tuned weights deployed as fixed-point RTL" is supposed to
    rule out.
    """
    def q(v, frac, width):
        lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
        return max(lo, min(hi, round(v * (1 << frac))))
    return {
        "w0":          q(w["w0"], 0, 16),
        "w_spread":    q(w["w_spread"], W_FRAC_W, 16),
        "w_imbalance": q(w["w_imbalance"], W_FRAC_W, 16),
        "w_momentum":  q(w["w_momentum"], W_FRAC_W, 16),
        "theta_buy":   q(w["theta_buy"], 0, 32),
        "theta_sell":  q(w["theta_sell"], 0, 32),
    }


def rtl_score(qw: dict, r: dict) -> int:
    """Bit-exact mirror of policy_engine.sv's score, integers throughout."""
    acc = (qw["w_spread"] * r["spread"]
           + qw["w_imbalance"] * r["imbalance"]
           + qw["w_momentum"] * r["momentum"])
    return (acc >> W_FRAC_W) + qw["w0"]      # >> floors, as >>> does in the RTL


def decide(qw: dict, r: dict) -> int:
    """Mirror of the decision rule: +1 buy, -1 sell, 0 hold."""
    if r["empty"]:
        return 0
    s = rtl_score(qw, r)
    if s > qw["theta_buy"]:
        return 1
    if s < qw["theta_sell"]:
        return -1
    return 0


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
    qw = quantise_weights(w)
    total, trades = 0.0, 0
    for r, fwd in zip(rows, future):
        if r["empty"] or r["withheld"]:
            continue
        d = decide(qw, r)
        if d != 0:
            total += d * fwd
            trades += 1
    # A policy that never trades scores zero and would beat a losing one, so
    # refuse it outright: an off switch is not a policy.
    if trades == 0:
        return float("-inf")
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
    if best is None:
        raise RuntimeError("no candidate traded at all; widen the search")
    best["objective"] = best_s
    return best


def as_policy(w: dict, name: str, command: str, order_qty: int,
              max_long: int, max_short: int, max_order_qty: int,
              max_spread: int) -> dict:
    """Wrap a searched weight set into a policy export_config.py can consume.

    The risk limits are NOT searched -- they are hard limits, not preferences,
    and a tuner that could relax its own position cap to score better would be
    the opposite of a risk gate.
    """
    return {
        "name": name,
        "note": f"Generated by: {command}",
        "w0": w["w0"], "w_spread": w["w_spread"],
        "w_imbalance": w["w_imbalance"], "w_momentum": w["w_momentum"],
        "theta_buy": w["theta_buy"], "theta_sell": w["theta_sell"],
        "order_qty": order_qty, "max_long": max_long, "max_short": max_short,
        "max_order_qty": max_order_qty, "max_spread": max_spread,
        "kill": False,
        "objective": w["objective"],
    }


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--events", type=int, default=4000)
    p.add_argument("--iters", type=int, default=400)
    p.add_argument("--out", type=Path)
    p.add_argument("--name", default="tuned")
    p.add_argument("--order-qty", type=int, default=5)
    p.add_argument("--max-long", type=int, default=1000000)
    p.add_argument("--max-short", type=int, default=1000000)
    p.add_argument("--max-order-qty", type=int, default=100)
    p.add_argument("--max-spread", type=int, default=20000)
    a = p.parse_args()

    events = generate(n=a.events, seed=a.seed, gap_rate=0.05, stale_rate=0.03,
                      bad_type_rate=0.02, bad_side_rate=0.02, bad_rsv_rate=0.01)
    rows = replay_features(events)
    best = search(rows, a.seed, a.iters)
    cmd = (f"scripts/train_policy.py --seed {a.seed} --events {a.events} "
           f"--iters {a.iters} --name {a.name}")
    policy = as_policy(best, a.name, cmd, a.order_qty, a.max_long,
                       a.max_short, a.max_order_qty, a.max_spread)
    print(json.dumps(policy, indent=2))
    if a.out:
        a.out.write_text(json.dumps(policy, indent=2) + "\n")


if __name__ == "__main__":
    main()
