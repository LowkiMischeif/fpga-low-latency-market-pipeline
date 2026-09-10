#!/usr/bin/env python3
"""Quantise a floating-point policy to the RTL's fixed-point formats.

This is the boundary where floats become fixed point, so it is the boundary
where the "AI customization" claim either survives or quietly stops being
true. Two rules:

  * Every constant comes from rtl/market_pkg.sv, parsed at run time. Nothing
    here restates a width, so the two cannot drift.
  * A weight that does not fit is an ERROR, never a silent wrap. A maximally
    bullish constant that wraps to a bearish one is the worst possible failure
    mode for this file, and it is invisible unless someone checks.

Output is one `<addr> <data>` hex pair per line, in the register order the
hardware expects, ending with a commit. tb_policy_configs.sv replays these
files directly, so what is tested is the file that ships, not a
re-derivation of it.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

PKG = Path(__file__).resolve().parent.parent / "rtl" / "market_pkg.sv"


def pkg_constants() -> dict[str, int]:
    """Parse localparam ints out of market_pkg.sv."""
    text = PKG.read_text()
    out: dict[str, int] = {}
    for m in re.finditer(r"localparam\s+int\s+(\w+)\s*=\s*([^;]+);", text):
        name, expr = m.group(1), m.group(2).strip()
        try:
            out[name] = int(eval(expr, {"__builtins__": {}}, dict(out)))  # noqa: S307
        except Exception:
            continue
    return out


def cfg_addresses() -> dict[str, int]:
    """Parse the cfg_addr_e enum so the address map is not restated here."""
    text = PKG.read_text()
    body = text[text.index("} cfg_addr_e") - 2000:text.index("} cfg_addr_e")]
    return {m.group(1): int(m.group(2))
            for m in re.finditer(r"(CFG_\w+)\s*=\s*\d+'d(\d+)", body)}


C = pkg_constants()
A = cfg_addresses()


def quantise(value: float, frac_bits: int, width: int, name: str) -> int:
    """Round to a fixed-point integer, refusing anything that will not fit."""
    scaled = round(value * (1 << frac_bits))
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    if not lo <= scaled <= hi:
        raise ValueError(
            f"{name}={value} quantises to {scaled}, outside the signed "
            f"{width}-bit range [{lo}, {hi}]. Widen the format or retune -- "
            f"do not let it wrap.")
    return scaled & ((1 << width) - 1)


def unsigned(value: int, width: int, name: str) -> int:
    if not 0 <= value < (1 << width):
        raise ValueError(f"{name}={value} does not fit {width} unsigned bits")
    return value


def build_writes(policy: dict) -> list[tuple[str, int]]:
    w, wf, sw = C["W_W"], C["W_FRAC_W"], C["SCORE_W"]
    qw, posw, spw = C["QTY_W"], C["POS_W"], C["SPREAD_W"]
    writes = [
        ("CFG_W0",            quantise(policy["w0"], 0, w, "w0")),
        ("CFG_W_SPREAD",      quantise(policy["w_spread"], wf, w, "w_spread")),
        ("CFG_W_IMBALANCE",   quantise(policy["w_imbalance"], wf, w, "w_imbalance")),
        ("CFG_W_MOMENTUM",    quantise(policy["w_momentum"], wf, w, "w_momentum")),
        ("CFG_THETA_BUY",     quantise(policy["theta_buy"], 0, sw, "theta_buy")),
        ("CFG_THETA_SELL",    quantise(policy["theta_sell"], 0, sw, "theta_sell")),
        ("CFG_ORDER_QTY",     unsigned(policy["order_qty"], qw, "order_qty")),
        ("CFG_MAX_LONG",      unsigned(policy["max_long"], posw - 1, "max_long")),
        ("CFG_MAX_SHORT",     unsigned(policy["max_short"], posw - 1, "max_short")),
        ("CFG_MAX_ORDER_QTY", unsigned(policy["max_order_qty"], qw, "max_order_qty")),
        ("CFG_MAX_SPREAD",    quantise(policy["max_spread"], 0, spw, "max_spread")),
        ("CFG_KILL",          1 if policy.get("kill", False) else 0),
        ("CFG_COMMIT",        1),
    ]
    return writes


def write_cfg(policy: dict, out: Path) -> list[tuple[str, int]]:
    writes = build_writes(policy)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w") as fh:
        fh.write(f"# {policy.get('name', out.stem)}\n")
        if policy.get("note"):
            fh.write(f"# {policy['note']}\n")
        fh.write("# addr data  (both hex; CFG_COMMIT last)\n")
        for name, data in writes:
            fh.write(f"{A[name]:02x} {data:08x}   # {name}\n")
    return writes


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("policy", type=Path, help="JSON policy description")
    p.add_argument("--out", type=Path, required=True)
    a = p.parse_args()
    policy = json.loads(a.policy.read_text())
    writes = write_cfg(policy, a.out)
    print(f"wrote {len(writes)} register writes to {a.out}")


if __name__ == "__main__":
    main()
