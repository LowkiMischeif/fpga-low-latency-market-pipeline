#!/usr/bin/env python3
"""Turn a simulation log into a latency histogram, and fail if it is not fixed.

The project's headline claim is a FIXED input-to-decision latency, so this
tool's job is to refuse to report a mean. A mean over a spread of latencies is
exactly the number that would let a variable-latency pipeline look acceptable;
min == mean == max is the claim, and anything else is a failure with the
distribution printed.

Reads the INFO lines that tb_fixed_latency and tb_policy_configs emit, so it
consumes the same artefact a reviewer would read by eye.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HIST_LINE = re.compile(r"^INFO:\s+(\d+):\s+(\d+)\s*$")
HIST_PAIR = re.compile(r"^INFO:\s+(\d+):\s+(\d+)\s*/\s*(\d+)\s*$")


def parse_histogram(text: str) -> dict[int, int]:
    """Collect `INFO:   <cycles>: <count>` lines into a histogram."""
    hist: dict[int, int] = {}
    for line in text.splitlines():
        m = HIST_PAIR.match(line)
        if m:
            cyc = int(m.group(1))
            hist[cyc] = hist.get(cyc, 0) + int(m.group(2)) + int(m.group(3))
            continue
        m = HIST_LINE.match(line)
        if m:
            cyc = int(m.group(1))
            hist[cyc] = hist.get(cyc, 0) + int(m.group(2))
    return hist


def parse_paired_histograms(text: str) -> tuple[dict[int, int], dict[int, int]]:
    """Split a `cycles: a / b` histogram into its two columns."""
    a: dict[int, int] = {}
    b: dict[int, int] = {}
    for line in text.splitlines():
        m = HIST_PAIR.match(line)
        if m:
            cyc = int(m.group(1))
            a[cyc] = a.get(cyc, 0) + int(m.group(2))
            b[cyc] = b.get(cyc, 0) + int(m.group(3))
    return a, b


def summarise(hist: dict[int, int]) -> dict:
    live = {c: n for c, n in hist.items() if n > 0}
    if not live:
        return {"events": 0, "min": None, "max": None, "mean": None, "fixed": False}
    total = sum(live.values())
    lo, hi = min(live), max(live)
    mean = sum(c * n for c, n in live.items()) / total
    return {"events": total, "min": lo, "max": hi, "mean": mean,
            "fixed": lo == hi, "buckets": dict(sorted(live.items()))}


def report(hist: dict[int, int], expect: int | None) -> int:
    s = summarise(hist)
    if s["events"] == 0:
        print("FAIL: no latency samples found in the log", file=sys.stderr)
        return 1
    print(f"events        {s['events']}")
    print(f"distribution  {s['buckets']}")
    print(f"min/mean/max  {s['min']} / {s['mean']:g} / {s['max']} cycles")
    if not s["fixed"]:
        print(f"FAIL: latency is NOT fixed -- it spans {s['min']}..{s['max']} cycles",
              file=sys.stderr)
        return 1
    print(f"latency is fixed at {s['min']} cycles")
    if expect is not None and s["min"] != expect:
        print(f"FAIL: expected {expect} cycles, measured {s['min']}", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("log", type=Path, help="simulation log to read")
    p.add_argument("--expect", type=int, help="required fixed latency in cycles")
    p.add_argument("--compare-configs", action="store_true",
                   help="log holds a two-column histogram; require the columns identical")
    a = p.parse_args()
    text = a.log.read_text()

    if a.compare_configs:
        ha, hb = parse_paired_histograms(text)
        if not ha and not hb:
            print("FAIL: no two-column histogram found", file=sys.stderr)
            return 1
        if ha != hb:
            print(f"FAIL: the two configurations have different latency "
                  f"distributions:\n  {ha}\n  {hb}", file=sys.stderr)
            return 1
        print("both configurations share one latency distribution")
        return report({c: ha[c] + hb[c] for c in ha}, a.expect)

    return report(parse_histogram(text), a.expect)


if __name__ == "__main__":
    raise SystemExit(main())
