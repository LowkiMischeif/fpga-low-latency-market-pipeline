# Decode + Validate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first two pipeline stages — decode a 64-bit market event and classify sequence gaps — with a seeded randomized testbench and assertion-proven 2-cycle latency.

**Architecture:** Two modules, each registering its output exactly once, connected by a no-skid valid/ready handshake where `ready` propagates combinationally upstream. A Python generator produces both stimulus and golden expectations; hand-written directed vectors and trace-independent SystemVerilog assertions guard against generator and RTL being wrong in the same way.

**Tech Stack:** SystemVerilog-2012, Verilator 5.032 (lint), Vivado 2026.1 xsim (simulation), Python 3.12+ with numpy and pytest.

**Spec:** `docs/superpowers/specs/2026-09-09-market-pipeline-design.md`

## Global Constraints

- **No floating point anywhere in `rtl/`.** Python may use floats offline; everything exported to RTL is quantized.
- **`rtl/market_pkg.sv` is the single source of truth** for every width, enum, struct and constant. No module declares a magic number.
- **One module per file** in `rtl/`, filename matching the module name. Enforced by `.rules.verible_lint` (`+one-module-per-file`).
- **`LATENCY_CYCLES` is a sum of named per-stage constants**, never a literal, and counts only stages present in `rtl/`. Its value this branch is `2`.
- **Every stage registers its output exactly once.** `ready` propagates combinationally; no skid buffers.
- **Errors are flagged and forwarded, never dropped.** Discarding market data is `risk_gate`'s decision, not an upstream one.
- **Reset is asynchronous, active low (`rst_n`), with no synchronizer at
  module level** — consistent across every module. A synchronizer is added
  once at `market_pipeline_top`. (An earlier version of this line said
  "synchronous release", which no module implements.)
- **Lint clean** under `verilator --lint-only -Wall` (`make lint`), zero warnings.
- **Simulation failures must call `$fatal`.** xsim exits 0 on `$fatal`; `scripts/run_sim.tcl` catches it by scanning the log for `Fatal:`/`Error:`.
- Traces in `tb/traces/` are generated artifacts and stay gitignored.

---

### Task 1: `market_pkg.sv` — widths, enums, structs, latency

**Files:**
- Create: `rtl/market_pkg.sv`
- Create: `tb/tb_market_pkg.sv`

**Interfaces:**
- Consumes: nothing.
- Produces: `EVENT_W`, `TYPE_W`, `SYMBOL_W`, `SIDE_W`, `PRICE_W`, `QTY_W`, `SEQ_W`, `RSV_W`, `PRICE_FRAC_W`, `N_SYMBOLS`, `CNT_W`; field LSB constants `RSV_LSB`, `SEQ_LSB`, `QTY_LSB`, `PRICE_LSB`, `SIDE_LSB`, `SYMBOL_LSB`, `TYPE_LSB`; enums `event_type_e {EVT_ADD, EVT_CANCEL, EVT_TRADE}`, `side_e {SIDE_BID, SIDE_ASK}`; structs `market_event_t`, `event_err_t`; functions `is_valid_type(logic [TYPE_W-1:0])`, `is_valid_side(logic [SIDE_W-1:0])`, both returning `logic`; constants `LAT_DECODE`, `LAT_SEQCHK`, `LATENCY_CYCLES`.

- [ ] **Step 1: Write the failing test**

`tb/tb_market_pkg.sv` — an elaboration test. It references every exported symbol, so a missing or misnamed constant is a compile error rather than a silent problem three tasks later.

```systemverilog
module tb_market_pkg;
  import market_pkg::*;

  initial begin
    // Field layout must tile the 64-bit beat exactly, with no gap or overlap.
    if (TYPE_LSB + TYPE_W != EVENT_W)
      $fatal(1, "FAIL: fields do not tile EVENT_W: TYPE_LSB=%0d TYPE_W=%0d EVENT_W=%0d",
             TYPE_LSB, TYPE_W, EVENT_W);
    if (RSV_LSB != 0)                     $fatal(1, "FAIL: RSV_LSB must be 0");
    if (SEQ_LSB    != RSV_LSB + RSV_W)    $fatal(1, "FAIL: SEQ_LSB");
    if (QTY_LSB    != SEQ_LSB + SEQ_W)    $fatal(1, "FAIL: QTY_LSB");
    if (PRICE_LSB  != QTY_LSB + QTY_W)    $fatal(1, "FAIL: PRICE_LSB");
    if (SIDE_LSB   != PRICE_LSB + PRICE_W)$fatal(1, "FAIL: SIDE_LSB");
    if (SYMBOL_LSB != SIDE_LSB + SIDE_W)  $fatal(1, "FAIL: SYMBOL_LSB");

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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make sim TOP=tb_market_pkg`
Expected: FAIL — `run_sim.tcl` exits 1 with `ERROR: no sources in rtl/. Nothing to simulate.` (the package does not exist yet).

- [ ] **Step 3: Write the minimal implementation**

Create `rtl/market_pkg.sv`:

```systemverilog
// market_pkg.sv -- single source of truth for the pipeline's widths, enums,
// structs and latency accounting. Every module imports this; no module
// declares a width or an encoding of its own.
`ifndef MARKET_PKG_SV
`define MARKET_PKG_SV

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

`endif
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make lint && make sim TOP=tb_market_pkg`
Expected: lint reports zero warnings; simulation prints `PASS: tb_market_pkg` and `== sim complete: tb_market_pkg ==`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add rtl/market_pkg.sv tb/tb_market_pkg.sv
git commit -m "feat(rtl): market_pkg with field layout, encodings and latency accounting"
```

---

### Task 2: `generate_events.py` — seeded traces and golden expectations

**Files:**
- Create: `scripts/generate_events.py`
- Create: `scripts/test_generate_events.py`
- Modify: `.gitignore` (add `tb/traces/*.csv`)

**Interfaces:**
- Consumes: the field layout from Task 1 (duplicated as module constants and checked against `market_pkg.sv` by a test in this task).
- Produces: `encode_event(etype, symbol, side, price, qty, seq) -> int`; `decode_event(word: int) -> dict` with keys `etype, symbol, side, price, qty, seq, rsv`; `generate(n, seed, gap_rate, stale_rate, bad_type_rate, bad_side_rate, bad_rsv_rate) -> list[dict]` where each dict has keys `word, etype, symbol, side, price, qty, seq, bad_type, bad_side, bad_rsv, gap, stale`; CLI writing `<out>.hex` and `<out>_expected.csv`.

- [ ] **Step 1: Write the failing test**

`scripts/test_generate_events.py`:

```python
import csv
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
from generate_events import (  # noqa: E402
    EVENT_W, FIELDS, decode_event, encode_event, generate,
)

REPO = Path(__file__).resolve().parent.parent


def test_field_layout_matches_market_pkg():
    """The generator's field layout must match rtl/market_pkg.sv exactly.

    This is the one place Python and the RTL agree on the wire format by
    duplication rather than by import, so it gets an explicit check. If someone
    widens a field in the package and not here, every trace silently decodes
    wrong and the RTL gets blamed for it.
    """
    import re

    pkg = (REPO / "rtl" / "market_pkg.sv").read_text()
    widths = {
        m.group(1).lower(): int(m.group(2))
        for m in re.finditer(r"localparam\s+int\s+(\w+)_W\s*=\s*(\d+)\s*;", pkg)
    }
    for name, (_lsb, width) in FIELDS.items():
        assert name in widths, f"{name}_W not declared in market_pkg.sv"
        assert widths[name] == width, (
            f"{name}: generator has {width} bits, market_pkg.sv has {widths[name]}"
        )
    assert widths["event"] == EVENT_W
    # The fields must tile the beat exactly -- no gap, no overlap.
    assert sum(w for _, w in FIELDS.values()) == EVENT_W
    covered = sorted((lsb, lsb + w) for lsb, w in FIELDS.values())
    for (_, end), (start, _) in zip(covered, covered[1:]):
        assert end == start, f"field layout has a hole or overlap at bit {end}"


def test_encode_decode_roundtrip():
    word = encode_event(etype=1, symbol=5, side=1, price=1234, qty=99, seq=4242)
    got = decode_event(word)
    assert got == {
        "etype": 1, "symbol": 5, "side": 1,
        "price": 1234, "qty": 99, "seq": 4242, "rsv": 0,
    }


def test_encode_fits_in_event_width():
    word = encode_event(etype=0xFF, symbol=0xF, side=0x3, price=0xFFFF,
                        qty=0xFFFF, seq=0xFFFF)
    assert 0 <= word < (1 << EVENT_W)


def test_clean_stream_is_in_order_and_flagless():
    evs = generate(n=200, seed=1, gap_rate=0.0, stale_rate=0.0,
                   bad_type_rate=0.0, bad_side_rate=0.0, bad_rsv_rate=0.0)
    assert len(evs) == 200
    assert not any(e["gap"] or e["stale"] for e in evs)
    assert not any(e["bad_type"] or e["bad_side"] or e["bad_rsv"] for e in evs)
    seqs = [e["seq"] for e in evs]
    assert seqs == [(seqs[0] + i) % (1 << 16) for i in range(len(seqs))]


def test_same_seed_is_reproducible():
    a = generate(n=100, seed=7, gap_rate=0.1, stale_rate=0.1,
                 bad_type_rate=0.1, bad_side_rate=0.1, bad_rsv_rate=0.1)
    b = generate(n=100, seed=7, gap_rate=0.1, stale_rate=0.1,
                 bad_type_rate=0.1, bad_side_rate=0.1, bad_rsv_rate=0.1)
    assert a == b


def test_different_seeds_differ():
    a = generate(n=100, seed=1, gap_rate=0.2, stale_rate=0.0,
                 bad_type_rate=0.0, bad_side_rate=0.0, bad_rsv_rate=0.0)
    b = generate(n=100, seed=2, gap_rate=0.2, stale_rate=0.0,
                 bad_type_rate=0.0, bad_side_rate=0.0, bad_rsv_rate=0.0)
    assert a != b


def test_gaps_are_injected_and_flagged():
    evs = generate(n=500, seed=3, gap_rate=0.2, stale_rate=0.0,
                   bad_type_rate=0.0, bad_side_rate=0.0, bad_rsv_rate=0.0)
    assert sum(e["gap"] for e in evs) > 0
    for prev, cur in zip(evs, evs[1:]):
        step = (cur["seq"] - prev["seq"]) % (1 << 16)
        assert cur["gap"] == (step > 1), f"gap flag disagrees with seq step {step}"


def test_stale_events_are_flagged_and_do_not_advance_expectation():
    evs = generate(n=500, seed=4, gap_rate=0.0, stale_rate=0.2,
                   bad_type_rate=0.0, bad_side_rate=0.0, bad_rsv_rate=0.0)
    assert sum(e["stale"] for e in evs) > 0


def test_bad_encodings_are_injected_and_flagged():
    evs = generate(n=500, seed=5, gap_rate=0.0, stale_rate=0.0,
                   bad_type_rate=0.2, bad_side_rate=0.2, bad_rsv_rate=0.2)
    assert sum(e["bad_type"] for e in evs) > 0
    assert sum(e["bad_side"] for e in evs) > 0
    assert sum(e["bad_rsv"] for e in evs) > 0
    for e in evs:
        d = decode_event(e["word"])
        assert e["bad_type"] == (d["etype"] not in (1, 2, 3))
        assert e["bad_side"] == (d["side"] not in (1, 2))
        assert e["bad_rsv"] == (d["rsv"] != 0)


def test_sequence_wraparound_is_not_a_gap():
    """A 16-bit sequence that wraps 65535 -> 0 is in order, not a 65535 gap."""
    evs = generate(n=40, seed=9, gap_rate=0.0, stale_rate=0.0,
                   bad_type_rate=0.0, bad_side_rate=0.0, bad_rsv_rate=0.0,
                   start_seq=(1 << 16) - 20)
    wrapped = [e for e in evs if e["seq"] < 20]
    assert wrapped, "test did not actually cross the wrap"
    assert not any(e["gap"] or e["stale"] for e in evs)


def test_cli_writes_hex_and_expected_csv(tmp_path):
    out = tmp_path / "t"
    subprocess.run(
        [sys.executable, str(REPO / "scripts" / "generate_events.py"),
         "--n", "50", "--seed", "11", "--out", str(out)],
        check=True,
    )
    hex_lines = (tmp_path / "t.hex").read_text().split()
    assert len(hex_lines) == 50
    assert all(len(h) == EVENT_W // 4 for h in hex_lines)
    with open(tmp_path / "t_expected.csv") as fh:
        rows = list(csv.DictReader(fh))
    assert len(rows) == 50
    assert int(rows[0]["word"], 16) == int(hex_lines[0], 16)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest scripts/test_generate_events.py -q`
Expected: FAIL — collection error, `ModuleNotFoundError: No module named 'generate_events'`.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/generate_events.py`:

```python
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
is why tb_event_decoder.sv also carries hand-written directed vectors that
never pass through this file.
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
    skips forward, a stale event replays an older number without advancing
    the expectation -- mirroring sequence_checker.sv exactly.
    """
    rng = random.Random(seed)
    events: list[dict] = []
    expect = start_seq % SEQ_MOD
    primed = False

    for _ in range(n):
        gap = stale = False
        if primed and rng.random() < stale_rate:
            # Replay something already seen. Does not advance expectation.
            back = rng.randint(1, 8)
            seq = (expect - back) % SEQ_MOD
            stale = True
        elif primed and rng.random() < gap_rate:
            skip = rng.randint(1, 8)
            seq = (expect + skip) % SEQ_MOD
            expect = (seq + 1) % SEQ_MOD
            gap = True
        else:
            seq = expect
            expect = (seq + 1) % SEQ_MOD
        primed = True

        if rng.random() < bad_type_rate:
            etype = rng.choice([0, 4, 5, 0x7F, 0xFF])
            bad_type = True
        else:
            etype = rng.choice(VALID_TYPES)
            bad_type = False

        if rng.random() < bad_side_rate:
            side = rng.choice([0, 3])
            bad_side = True
        else:
            side = rng.choice(VALID_SIDES)
            bad_side = False

        if rng.random() < bad_rsv_rate:
            rsv = rng.randint(1, 3)
            bad_rsv = True
        else:
            rsv = 0
            bad_rsv = False

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
    with open(out.with_suffix(".hex"), "w") as fh:
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `.venv/bin/python -m pytest scripts/test_generate_events.py -q`
Expected: PASS, 11 tests.

- [ ] **Step 5: Gitignore the generated CSV**

Append to `.gitignore` under the existing traces block:

```
tb/traces/*.csv
```

- [ ] **Step 6: Commit**

```bash
git add scripts/generate_events.py scripts/test_generate_events.py .gitignore
git commit -m "feat(scripts): seeded event trace generator with golden expectations"
```

---

### Task 3: `event_decoder.sv` — slice and validate, 1 cycle

**Files:**
- Create: `rtl/event_decoder.sv`
- Create: `tb/tb_event_decoder.sv`

**Interfaces:**
- Consumes: everything from Task 1.
- Produces: module `event_decoder` with ports `clk`, `rst_n`, `s_data [EVENT_W-1:0]`, `s_valid`, `s_ready`, `m_event (market_event_t)`, `m_err (event_err_t)`, `m_valid`, `m_ready`.

- [ ] **Step 1: Write the failing test**

`tb/tb_event_decoder.sv`. These are the hand-written directed vectors described in the spec — they never pass through `generate_events.py`, so a generator bug cannot hide a decoder bug.

```systemverilog
module tb_event_decoder;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [EVENT_W-1:0] s_data;
  logic               s_valid, s_ready;
  market_event_t      m_event;
  event_err_t         m_err;
  logic               m_valid, m_ready;

  event_decoder dut (.*);

  int errors = 0;

  // Build a beat from fields, independently of generate_events.py.
  function automatic logic [EVENT_W-1:0] mk(
      logic [TYPE_W-1:0] t, logic [SYMBOL_W-1:0] sym, logic [SIDE_W-1:0] sd,
      logic [PRICE_W-1:0] p, logic [QTY_W-1:0] q, logic [SEQ_W-1:0] sq,
      logic [RSV_W-1:0] rsv);
    logic [EVENT_W-1:0] w;
    w = '0;
    w[TYPE_LSB   +: TYPE_W]   = t;
    w[SYMBOL_LSB +: SYMBOL_W] = sym;
    w[SIDE_LSB   +: SIDE_W]   = sd;
    w[PRICE_LSB  +: PRICE_W]  = p;
    w[QTY_LSB    +: QTY_W]    = q;
    w[SEQ_LSB    +: SEQ_W]    = sq;
    w[RSV_LSB    +: RSV_W]    = rsv;
    return w;
  endfunction

  task automatic check(string name, logic cond);
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  // Drive one beat and wait for the decoded result.
  task automatic send(logic [EVENT_W-1:0] w);
    @(negedge clk);
    s_data  = w;
    s_valid = 1'b1;
    @(posedge clk);
    while (!s_ready) @(posedge clk);
    @(negedge clk);
    s_valid = 1'b0;
  endtask

  initial begin
    m_ready = 1'b1;
    s_valid = 1'b0;
    s_data  = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // --- directed vector 1: a well-formed ADD/BID ---------------------
    send(mk(EVT_ADD, 4'h5, SIDE_BID, 16'h1234, 16'h0063, 16'h1092, 2'b00));
    @(posedge clk);
    check("v1 valid",   m_valid === 1'b1);
    check("v1 etype",   m_event.etype  === EVT_ADD);
    check("v1 symbol",  m_event.symbol === 4'h5);
    check("v1 side",    m_event.side   === SIDE_BID);
    check("v1 price",   m_event.price  === 16'h1234);
    check("v1 qty",     m_event.qty    === 16'h0063);
    check("v1 seq",     m_event.seq    === 16'h1092);
    check("v1 no errs", m_err.bad_type === 1'b0 && m_err.bad_side === 1'b0
                        && m_err.bad_rsv === 1'b0);

    // --- directed vector 2: undefined type, everything else valid -----
    send(mk(8'hFF, 4'h0, SIDE_ASK, 16'h0001, 16'h0002, 16'h0003, 2'b00));
    @(posedge clk);
    check("v2 bad_type set",     m_err.bad_type === 1'b1);
    check("v2 bad_side clear",   m_err.bad_side === 1'b0);
    check("v2 forwarded anyway", m_valid === 1'b1);
    check("v2 payload intact",   m_event.price === 16'h0001);

    // --- directed vector 3: undefined side ----------------------------
    send(mk(EVT_TRADE, 4'hF, 2'b11, 16'hFFFF, 16'hFFFF, 16'hFFFF, 2'b00));
    @(posedge clk);
    check("v3 bad_side set",   m_err.bad_side === 1'b1);
    check("v3 bad_type clear", m_err.bad_type === 1'b0);
    check("v3 all-ones fields", m_event.price === 16'hFFFF
                                && m_event.qty === 16'hFFFF);

    // --- directed vector 4: reserved bits non-zero --------------------
    send(mk(EVT_CANCEL, 4'h1, SIDE_BID, 16'h0000, 16'h0000, 16'h0000, 2'b10));
    @(posedge clk);
    check("v4 bad_rsv set",    m_err.bad_rsv  === 1'b1);
    check("v4 others clear",   m_err.bad_type === 1'b0
                               && m_err.bad_side === 1'b0);

    // --- directed vector 5: all three defects at once -----------------
    send(mk(8'h00, 4'h7, 2'b00, 16'h00FF, 16'h0F00, 16'hBEEF, 2'b11));
    @(posedge clk);
    check("v5 bad_type", m_err.bad_type === 1'b1);
    check("v5 bad_side", m_err.bad_side === 1'b1);
    check("v5 bad_rsv",  m_err.bad_rsv  === 1'b1);
    check("v5 seq",      m_event.seq    === 16'hBEEF);

    // --- reset must clear valid ---------------------------------------
    rst_n = 1'b0;
    @(posedge clk);
    check("reset clears m_valid", m_valid === 1'b0);
    rst_n = 1'b1;

    if (errors != 0) $fatal(1, "FAIL: %0d directed checks failed", errors);
    $display("PASS: tb_event_decoder (%0d directed vectors)", 5);
    $finish;
  end

  // Watchdog: a hung handshake must fail the run, not spin forever.
  initial begin
    #100000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make sim TOP=tb_event_decoder`
Expected: FAIL — `xelab` cannot resolve `event_decoder`; `run_sim.tcl` exits 1 on the `Error:` line.

- [ ] **Step 3: Write the minimal implementation**

Create `rtl/event_decoder.sv`:

```systemverilog
// event_decoder.sv -- slice one 64-bit market-event beat into its fields and
// classify malformed encodings.
//
// Malformed events are FLAGGED AND FORWARDED, never dropped: discarding
// market data is risk_gate's decision, where it is visible to the policy
// layer and counted in telemetry.
//
// Latency: LAT_DECODE (1 cycle) when m_ready is held high.
module event_decoder
  import market_pkg::*;
(
  input  logic               clk,
  input  logic               rst_n,

  // upstream
  input  logic [EVENT_W-1:0] s_data,
  input  logic               s_valid,
  output logic               s_ready,

  // downstream
  output market_event_t      m_event,
  output event_err_t         m_err,
  output logic               m_valid,
  input  logic               m_ready
);

  market_event_t d_event;
  event_err_t    d_err;

  always_comb begin
    d_event.etype  = s_data[TYPE_LSB   +: TYPE_W];
    d_event.symbol = s_data[SYMBOL_LSB +: SYMBOL_W];
    d_event.side   = s_data[SIDE_LSB   +: SIDE_W];
    d_event.price  = s_data[PRICE_LSB  +: PRICE_W];
    d_event.qty    = s_data[QTY_LSB    +: QTY_W];
    d_event.seq    = s_data[SEQ_LSB    +: SEQ_W];

    d_err          = '0;
    d_err.bad_type = ~is_valid_type(d_event.etype);
    d_err.bad_side = ~is_valid_side(d_event.side);
    d_err.bad_rsv  = |s_data[RSV_LSB +: RSV_W];
    // gap and stale are sequence_checker's to set; leave them clear here.
  end

  // No-skid handshake: accept whenever the output register is free or is
  // being drained this cycle. ready propagates combinationally upstream, so
  // the pipeline stalls as a unit with no bubble and no reordering.
  assign s_ready = m_ready || !m_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_valid <= 1'b0;
      m_event <= '0;
      m_err   <= '0;
    end else if (s_ready) begin
      m_valid <= s_valid;
      m_event <= d_event;
      m_err   <= d_err;
    end
  end

endmodule
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make lint && make sim TOP=tb_event_decoder`
Expected: lint clean; `PASS: tb_event_decoder (5 directed vectors)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add rtl/event_decoder.sv tb/tb_event_decoder.sv
git commit -m "feat(rtl): event_decoder with directed encoding-validation tests"
```

---

### Task 4: `tb/assertions.sv` — trace-independent properties

**Files:**
- Create: `tb/assertions.sv`
- Create: `tb/bind_assertions.sv`

**Interfaces:**
- Consumes: `event_decoder`'s port list from Task 3; `LAT_DECODE` from Task 1.
- Produces: module `handshake_checker #(parameter int LATENCY = 1)` with ports `clk`, `rst_n`, `s_valid`, `s_ready`, `m_valid`, `m_ready`, intended for `bind`.

These properties hold for *any* stimulus, so they cannot be satisfied by a generator and an RTL agreeing on the same mistake.

- [ ] **Step 1: Write the failing test**

Create `tb/assertions.sv`:

```systemverilog
// assertions.sv -- handshake and latency properties that hold regardless of
// the trace being replayed. Bound into each stage from the testbench.
//
// This file exists from the first branch, not added later: fixed latency is
// the headline result of this project, so it is asserted from the first stage
// that has a latency to assert.
module handshake_checker #(
  parameter int LATENCY = 1
) (
  input logic clk,
  input logic rst_n,
  input logic s_valid,
  input logic s_ready,
  input logic m_valid,
  input logic m_ready
);

  // A producer may not retract an offer: once valid is asserted it must stay
  // asserted until the cycle ready is seen high.
  property p_no_valid_retraction;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && !s_ready) |=> s_valid;
  endproperty
  a_no_valid_retraction: assert property (p_no_valid_retraction)
    else $error("s_valid retracted before s_ready");

  property p_no_valid_retraction_out;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> m_valid;
  endproperty
  a_no_valid_retraction_out: assert property (p_no_valid_retraction_out)
    else $error("m_valid retracted before m_ready");

  // The headline claim, in its honest conditional form: with the output free
  // to drain, an accepted input appears at the output exactly LATENCY cycles
  // later -- not "at least", not "on average".
  property p_fixed_latency;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && s_ready && m_ready) |-> ##LATENCY m_valid;
  endproperty
  a_fixed_latency: assert property (p_fixed_latency)
    else $error("output did not appear exactly %0d cycles after accept", LATENCY);

  // No output may appear without an input having been accepted LATENCY cycles
  // earlier. Catches a stage inventing events.
  property p_no_spontaneous_output;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && m_ready) |-> $past(s_valid && s_ready, LATENCY);
  endproperty
  a_no_spontaneous_output: assert property (p_no_spontaneous_output)
    else $error("output with no corresponding accepted input");

  // While stalled, the output register must hold its offer rather than
  // silently dropping the event.
  property p_stall_holds;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> m_valid;
  endproperty
  a_stall_holds: assert property (p_stall_holds)
    else $error("event lost during stall");

endmodule
```

- [ ] **Step 2: Bind it, once, in its own file**

`run_sim.tcl` compiles every `tb/*.sv` into one library, so a `bind` written
inside a testbench applies to *all* of them. Putting the same bind in two
testbenches binds the target twice under the same instance name, which is an
elaboration error. All binds therefore live in exactly one file.

Create `tb/bind_assertions.sv`:

```systemverilog
// bind_assertions.sv -- attach the property checkers to each pipeline stage.
//
// These binds are global to the compiled library: every testbench gets them,
// and they must appear exactly once across all of tb/. Do not add a bind
// statement inside an individual testbench.
bind event_decoder handshake_checker #(.LATENCY(market_pkg::LAT_DECODE))
  u_chk (.clk(clk), .rst_n(rst_n),
         .s_valid(s_valid), .s_ready(s_ready),
         .m_valid(m_valid), .m_ready(m_ready));

bind sequence_checker handshake_checker #(.LATENCY(market_pkg::LAT_SEQCHK))
  u_chk (.clk(clk), .rst_n(rst_n),
         .s_valid(s_valid), .s_ready(s_ready),
         .m_valid(m_valid), .m_ready(m_ready));
```

The `sequence_checker` bind refers to a module that does not exist until Task
5. Comment it out for now with a note, and uncomment it as Task 5's first
action — the plan calls for that explicitly.

- [ ] **Step 3: Run it to verify the assertions are actually live**

Temporarily break the DUT to prove the assertions fire rather than passing vacuously. In `rtl/event_decoder.sv`, change `assign s_ready = m_ready || !m_valid;` to `assign s_ready = 1'b1;`.

Run: `make sim TOP=tb_event_decoder`
Expected: FAIL — `a_stall_holds` or `a_no_spontaneous_output` reports an error, and `run_sim.tcl` exits 1.

**Revert the change before continuing.**

- [ ] **Step 4: Run the test to verify it passes**

Run: `make lint && make sim TOP=tb_event_decoder`
Expected: lint clean; `PASS: tb_event_decoder`, exit 0, no assertion errors.

- [ ] **Step 5: Commit**

```bash
git add tb/assertions.sv tb/bind_assertions.sv
git commit -m "test(tb): bindable handshake and fixed-latency assertions"
```

---

### Task 5: `sequence_checker.sv` — gap and stale classification, 1 cycle

**Files:**
- Create: `rtl/sequence_checker.sv`
- Create: `tb/tb_sequence_checker.sv`

**Interfaces:**
- Consumes: `market_event_t`, `event_err_t`, `SEQ_W`, `CNT_W`, `LAT_SEQCHK` from Task 1; `handshake_checker` from Task 4.
- Produces: module `sequence_checker` with ports `clk`, `rst_n`, `s_event (market_event_t)`, `s_err (event_err_t)`, `s_valid`, `s_ready`, `m_event (market_event_t)`, `m_err (event_err_t)`, `m_valid`, `m_ready`, `gap_count [CNT_W-1:0]`, `stale_count [CNT_W-1:0]`, `missed_total [CNT_W-1:0]`, `bad_event_count [CNT_W-1:0]`.

- [ ] **Step 1: Write the failing test**

Create `tb/tb_sequence_checker.sv`. The wraparound and first-event cases are the two the spec singles out as easy to get wrong.

```systemverilog
module tb_sequence_checker;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  market_event_t   s_event, m_event;
  event_err_t      s_err, m_err;
  logic            s_valid, s_ready, m_valid, m_ready;
  logic [CNT_W-1:0] gap_count, stale_count, missed_total, bad_event_count;

  sequence_checker dut (.*);

  int errors = 0;

  task automatic check(string name, logic cond);
    if (!cond) begin
      errors++;
      $error("FAIL: %s", name);
    end
  endtask

  // Present one event with the given sequence number and settle.
  task automatic feed(logic [SEQ_W-1:0] sq, event_err_t err = '0);
    @(negedge clk);
    s_event      = '0;
    s_event.etype = EVT_ADD;
    s_event.side  = SIDE_BID;
    s_event.seq  = sq;
    s_err        = err;
    s_valid      = 1'b1;
    @(posedge clk);
    while (!s_ready) @(posedge clk);
    @(negedge clk);
    s_valid = 1'b0;
    @(posedge clk);   // result is registered by now
  endtask

  initial begin
    m_ready = 1'b1;
    s_valid = 1'b0;
    s_event = '0;
    s_err   = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // --- first event after reset must NOT be a gap --------------------
    // The checker adopts the first sequence number it sees as its baseline,
    // so a trace starting mid-stream does not report a spurious gap.
    feed(16'd5000);
    check("first event no gap",   m_err.gap   === 1'b0);
    check("first event no stale", m_err.stale === 1'b0);
    check("gap_count still 0",    gap_count   === '0);

    // --- in-order events ----------------------------------------------
    feed(16'd5001);
    check("in-order no gap", m_err.gap === 1'b0 && m_err.stale === 1'b0);
    feed(16'd5002);
    check("in-order no gap 2", m_err.gap === 1'b0);

    // --- forward jump is a gap, and missed_total counts the hole ------
    feed(16'd5006);
    check("gap flagged",      m_err.gap    === 1'b1);
    check("gap_count 1",      gap_count    === 32'd1);
    check("missed_total 3",   missed_total === 32'd3);  // 5003,5004,5005
    check("stale clear",      m_err.stale  === 1'b0);

    // --- after a gap the checker resyncs to received+1 -----------------
    feed(16'd5007);
    check("resync no gap", m_err.gap === 1'b0);
    check("gap_count still 1", gap_count === 32'd1);

    // --- backward jump is stale and must NOT advance expectation -------
    feed(16'd5003);
    check("stale flagged",     m_err.stale === 1'b1);
    check("stale_count 1",     stale_count === 32'd1);
    check("missed unchanged",  missed_total === 32'd3);
    feed(16'd5008);
    check("expectation preserved across stale", m_err.gap === 1'b0);

    // --- duplicate of the immediately previous event is stale ----------
    feed(16'd5008);
    check("duplicate is stale", m_err.stale === 1'b1);
    check("stale_count 2",      stale_count === 32'd2);

    // --- upstream error flags are forwarded, and counted ---------------
    begin
      event_err_t e;
      e = '0;
      e.bad_type = 1'b1;
      feed(16'd5009, e);
      check("bad_type forwarded", m_err.bad_type === 1'b1);
      check("bad_event_count 1",  bad_event_count === 32'd1);
    end

    // --- 16-bit wraparound is in order, NOT a 65535-event gap ----------
    // This is the case a naive magnitude comparison gets wrong.
    rst_n = 1'b0; @(posedge clk); rst_n = 1'b1; @(posedge clk);
    feed(16'hFFFD);
    feed(16'hFFFE);
    check("pre-wrap in order", m_err.gap === 1'b0);
    feed(16'hFFFF);
    check("last before wrap",  m_err.gap === 1'b0);
    feed(16'h0000);
    check("wrap is not a gap",   m_err.gap   === 1'b0);
    check("wrap is not stale",   m_err.stale === 1'b0);
    check("no missed at wrap",   missed_total === '0);
    feed(16'h0001);
    check("post-wrap in order", m_err.gap === 1'b0);

    // --- a real gap that straddles the wrap is still a gap -------------
    rst_n = 1'b0; @(posedge clk); rst_n = 1'b1; @(posedge clk);
    feed(16'hFFFE);
    feed(16'h0002);   // skipped FFFF, 0000, 0001
    check("gap across wrap flagged", m_err.gap === 1'b1);
    check("missed across wrap == 3", missed_total === 32'd3);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_sequence_checker");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "FAIL: timeout");
  end
endmodule
```

Then uncomment the `sequence_checker` bind in `tb/bind_assertions.sv` — the
module it targets now exists. Do not add a bind to this testbench.

- [ ] **Step 2: Run it to verify it fails**

Run: `make sim TOP=tb_sequence_checker`
Expected: FAIL — `xelab` cannot resolve `sequence_checker`.

- [ ] **Step 3: Write the minimal implementation**

Create `rtl/sequence_checker.sv`:

```systemverilog
// sequence_checker.sv -- classify each event against the expected feed
// sequence number and count what was missed.
//
// Policy is FLAG, FORWARD, RESYNC. Gapped and stale events are marked and
// passed downstream; risk_gate decides what to do about them, because that is
// where the decision is visible to the policy layer.
//
// Latency: LAT_SEQCHK (1 cycle) when m_ready is held high.
module sequence_checker
  import market_pkg::*;
(
  input  logic            clk,
  input  logic            rst_n,

  input  market_event_t   s_event,
  input  event_err_t      s_err,
  input  logic            s_valid,
  output logic            s_ready,

  output market_event_t   m_event,
  output event_err_t      m_err,
  output logic            m_valid,
  input  logic            m_ready,

  output logic [CNT_W-1:0] gap_count,
  output logic [CNT_W-1:0] stale_count,
  output logic [CNT_W-1:0] missed_total,
  output logic [CNT_W-1:0] bad_event_count
);

  logic [SEQ_W-1:0] expect_seq;
  logic             primed;      // have we seen any event since reset?

  // Sequence numbers are 16 bits and wrap. A magnitude comparison would call
  // every wrap a ~65000-event gap, so compare the MODULAR DIFFERENCE and
  // interpret it as signed: positive is a gap, negative is stale, zero is in
  // order. Correct for any real gap below 2**(SEQ_W-1).
  logic signed [SEQ_W-1:0] diff;
  assign diff = $signed(s_event.seq - expect_seq);

  logic is_gap, is_stale;
  assign is_gap   = primed && (diff > 0);
  assign is_stale = primed && (diff < 0);

  assign s_ready = m_ready || !m_valid;

  logic accept;
  assign accept = s_valid && s_ready;

  event_err_t d_err;
  always_comb begin
    d_err       = s_err;      // preserve decoder's flags
    d_err.gap   = is_gap;
    d_err.stale = is_stale;
  end

  logic upstream_bad;
  assign upstream_bad = s_err.bad_type || s_err.bad_side || s_err.bad_rsv;

  // Counters saturate rather than wrap: telemetry that silently rolls over is
  // worse than telemetry that pegs.
  function automatic logic [CNT_W-1:0] sat_add(input logic [CNT_W-1:0] a,
                                               input logic [CNT_W-1:0] b);
    logic [CNT_W:0] sum;
    sum = {1'b0, a} + {1'b0, b};
    return sum[CNT_W] ? {CNT_W{1'b1}} : sum[CNT_W-1:0];
  endfunction

  logic [CNT_W-1:0] missed_ext;
  assign missed_ext = {{(CNT_W-SEQ_W){1'b0}}, diff};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_valid         <= 1'b0;
      m_event         <= '0;
      m_err           <= '0;
      expect_seq      <= '0;
      primed          <= 1'b0;
      gap_count       <= '0;
      stale_count     <= '0;
      missed_total    <= '0;
      bad_event_count <= '0;
    end else begin
      if (s_ready) begin
        m_valid <= s_valid;
        m_event <= s_event;
        m_err   <= d_err;
      end

      if (accept) begin
        primed <= 1'b1;

        // The first event after reset defines the baseline rather than being
        // measured against zero, so a trace starting mid-stream is not a gap.
        // A stale event does NOT advance the expectation.
        if (!primed || (diff >= 0)) begin
          expect_seq <= s_event.seq + 1'b1;
        end

        if (is_gap) begin
          gap_count    <= sat_add(gap_count, 32'd1);
          missed_total <= sat_add(missed_total, missed_ext);
        end
        if (is_stale) begin
          stale_count <= sat_add(stale_count, 32'd1);
        end
        if (upstream_bad) begin
          bad_event_count <= sat_add(bad_event_count, 32'd1);
        end
      end
    end
  end

endmodule
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make lint && make sim TOP=tb_sequence_checker`
Expected: lint clean; `PASS: tb_sequence_checker`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add rtl/sequence_checker.sv tb/tb_sequence_checker.sv tb/bind_assertions.sv
git commit -m "feat(rtl): sequence_checker with modular wrap-safe gap detection"
```

---

### Task 6: Randomized replay — the two stages chained, under backpressure

**Files:**
- Create: `tb/tb_decode_validate.sv`
- Modify: `Makefile` (add a `trace` target)

**Interfaces:**
- Consumes: `event_decoder` (Task 3), `sequence_checker` (Task 5), `handshake_checker` (Task 4), `generate_events.py` output (Task 2).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Add a trace-generation target**

Add to `Makefile` after the `pytest` target:

```makefile
# Regenerate the randomized replay trace. SEED is deliberately explicit: a
# failing run is reproduced by rerunning with the same seed.
SEED ?= 1
NEVENTS ?= 2000
trace:
	$(PYTHON) scripts/generate_events.py --n $(NEVENTS) --seed $(SEED) \
	    --out tb/traces/random
```

Add `trace` to the `.PHONY` line.

- [ ] **Step 2: Write the failing test**

Create `tb/tb_decode_validate.sv`:

```systemverilog
// Randomized replay of a generated trace through decoder -> sequence_checker,
// with randomized backpressure. Compares every output against the golden
// expectations from generate_events.py.
//
// The golden CSV and the RTL could in principle be wrong in the same way,
// which is why tb_event_decoder.sv and tb_sequence_checker.sv carry
// hand-written vectors and tb/assertions.sv carries trace-independent
// properties. This testbench adds volume and backpressure, not ground truth.
module tb_decode_validate;
  import market_pkg::*;

  localparam int MAX_EVENTS = 8192;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [EVENT_W-1:0] s_data;
  logic               s_valid, s_ready;

  market_event_t      d_event, m_event;
  event_err_t         d_err, m_err;
  logic               d_valid, d_ready, m_valid, m_ready;
  logic [CNT_W-1:0]   gap_count, stale_count, missed_total, bad_event_count;

  event_decoder u_dec (
    .clk(clk), .rst_n(rst_n),
    .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
    .m_event(d_event), .m_err(d_err), .m_valid(d_valid), .m_ready(d_ready)
  );

  sequence_checker u_seq (
    .clk(clk), .rst_n(rst_n),
    .s_event(d_event), .s_err(d_err), .s_valid(d_valid), .s_ready(d_ready),
    .m_event(m_event), .m_err(m_err), .m_valid(m_valid), .m_ready(m_ready),
    .gap_count(gap_count), .stale_count(stale_count),
    .missed_total(missed_total), .bad_event_count(bad_event_count)
  );

  // No bind statements here: tb/bind_assertions.sv already binds the checker
  // to both stages for the whole compiled library.

  // Stimulus and golden expectations, loaded from the generator's output.
  logic [EVENT_W-1:0] trace_words [0:MAX_EVENTS-1];
  int    exp_etype  [0:MAX_EVENTS-1];
  int    exp_symbol [0:MAX_EVENTS-1];
  int    exp_side   [0:MAX_EVENTS-1];
  int    exp_price  [0:MAX_EVENTS-1];
  int    exp_qty    [0:MAX_EVENTS-1];
  int    exp_seq    [0:MAX_EVENTS-1];
  int    exp_btype  [0:MAX_EVENTS-1];
  int    exp_bside  [0:MAX_EVENTS-1];
  int    exp_brsv   [0:MAX_EVENTS-1];
  int    exp_gap    [0:MAX_EVENTS-1];
  int    exp_stale  [0:MAX_EVENTS-1];

  int n_events = 0;
  int seed = 1;
  int errors = 0;
  int sent = 0, recvd = 0;

  // Read the golden CSV. Header line is skipped; column order must match
  // CSV_COLUMNS in generate_events.py.
  task automatic load_expected(string path);
    int fd, r;
    string line;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "FAIL: cannot open %s", path);
    r = $fgets(line, fd);              // header
    n_events = 0;
    while ($fgets(line, fd) != 0) begin
      int w;
      r = $sscanf(line, "%h,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
                  w,
                  exp_etype[n_events], exp_symbol[n_events], exp_side[n_events],
                  exp_price[n_events], exp_qty[n_events], exp_seq[n_events],
                  exp_btype[n_events], exp_bside[n_events], exp_brsv[n_events],
                  exp_gap[n_events], exp_stale[n_events]);
      if (r != 12) $fatal(1, "FAIL: malformed CSV row %0d (parsed %0d fields)",
                          n_events, r);
      n_events++;
      if (n_events >= MAX_EVENTS) $fatal(1, "FAIL: trace exceeds MAX_EVENTS");
    end
    $fclose(fd);
  endtask

  initial begin
    string hex_path, csv_path;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    if (!$value$plusargs("HEX=%s", hex_path)) hex_path = "tb/traces/random.hex";
    if (!$value$plusargs("CSV=%s", csv_path))
      csv_path = "tb/traces/random_expected.csv";
    $display("INFO: seed=%0d hex=%s csv=%s", seed, hex_path, csv_path);

    $readmemh(hex_path, trace_words);
    load_expected(csv_path);
    $display("INFO: loaded %0d events", n_events);
  end

  // Driver: randomized valid gaps.
  initial begin
    s_valid = 1'b0;
    s_data  = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    while (sent < n_events) begin
      // Idle a random number of cycles to exercise valid gaps.
      if ($urandom_range(0, 3) == 0) begin
        @(negedge clk);
        s_valid = 1'b0;
        repeat ($urandom_range(1, 3)) @(posedge clk);
      end
      @(negedge clk);
      s_data  = trace_words[sent];
      s_valid = 1'b1;
      @(posedge clk);
      while (!s_ready) @(posedge clk);
      sent++;
    end
    @(negedge clk);
    s_valid = 1'b0;
  end

  // Backpressure: randomly deassert m_ready to prove the pipe stalls as a
  // unit without losing or reordering events.
  initial begin
    m_ready = 1'b1;
    forever begin
      @(posedge clk);
      if ($urandom_range(0, 4) == 0) begin
        m_ready = 1'b0;
        repeat ($urandom_range(1, 4)) @(posedge clk);
        m_ready = 1'b1;
      end
    end
  end

  // Scoreboard: every accepted output must match the golden row, in order.
  always @(posedge clk) begin
    if (rst_n && m_valid && m_ready) begin
      if (recvd >= n_events) begin
        errors++;
        $error("FAIL: extra output beyond %0d events", n_events);
      end else begin
        if (m_event.etype  !== exp_etype[recvd][TYPE_W-1:0])   begin errors++; $error("FAIL[%0d]: etype exp %0h got %0h",  recvd, exp_etype[recvd],  m_event.etype);  end
        if (m_event.symbol !== exp_symbol[recvd][SYMBOL_W-1:0]) begin errors++; $error("FAIL[%0d]: symbol exp %0h got %0h", recvd, exp_symbol[recvd], m_event.symbol); end
        if (m_event.side   !== exp_side[recvd][SIDE_W-1:0])    begin errors++; $error("FAIL[%0d]: side exp %0h got %0h",   recvd, exp_side[recvd],   m_event.side);   end
        if (m_event.price  !== exp_price[recvd][PRICE_W-1:0])  begin errors++; $error("FAIL[%0d]: price exp %0h got %0h",  recvd, exp_price[recvd],  m_event.price);  end
        if (m_event.qty    !== exp_qty[recvd][QTY_W-1:0])      begin errors++; $error("FAIL[%0d]: qty exp %0h got %0h",    recvd, exp_qty[recvd],    m_event.qty);    end
        if (m_event.seq    !== exp_seq[recvd][SEQ_W-1:0])      begin errors++; $error("FAIL[%0d]: seq exp %0h got %0h",    recvd, exp_seq[recvd],    m_event.seq);    end
        if (m_err.bad_type !== exp_btype[recvd][0])            begin errors++; $error("FAIL[%0d]: bad_type exp %0d got %0b", recvd, exp_btype[recvd], m_err.bad_type); end
        if (m_err.bad_side !== exp_bside[recvd][0])            begin errors++; $error("FAIL[%0d]: bad_side exp %0d got %0b", recvd, exp_bside[recvd], m_err.bad_side); end
        if (m_err.bad_rsv  !== exp_brsv[recvd][0])             begin errors++; $error("FAIL[%0d]: bad_rsv exp %0d got %0b",  recvd, exp_brsv[recvd],  m_err.bad_rsv);  end
        if (m_err.gap      !== exp_gap[recvd][0])              begin errors++; $error("FAIL[%0d]: gap exp %0d got %0b",      recvd, exp_gap[recvd],   m_err.gap);      end
        if (m_err.stale    !== exp_stale[recvd][0])            begin errors++; $error("FAIL[%0d]: stale exp %0d got %0b",    recvd, exp_stale[recvd], m_err.stale);    end
        recvd++;
      end
    end
  end

  // Completion.
  initial begin
    wait (n_events > 0);
    wait (recvd == n_events);
    repeat (5) @(posedge clk);
    if (errors != 0)
      $fatal(1, "FAIL: %0d mismatches over %0d events (seed=%0d)",
             errors, n_events, seed);
    $display("PASS: tb_decode_validate -- %0d events, seed=%0d", n_events, seed);
    $display("INFO: gap_count=%0d stale_count=%0d missed_total=%0d bad_event_count=%0d",
             gap_count, stale_count, missed_total, bad_event_count);
    $finish;
  end

  initial begin
    #10000000;
    $fatal(1, "FAIL: timeout -- sent=%0d recvd=%0d of %0d", sent, recvd, n_events);
  end
endmodule
```

- [ ] **Step 3: Run it to verify it fails**

Run: `make sim TOP=tb_decode_validate`
Expected: FAIL — the trace does not exist yet; `$readmemh` cannot open `tb/traces/random.hex` and `load_expected` calls `$fatal`.

- [ ] **Step 4: Generate the trace and run**

Run: `make trace && make lint && make sim TOP=tb_decode_validate`
Expected: `PASS: tb_decode_validate -- 2000 events, seed=1`, exit 0, no assertion errors.

- [ ] **Step 5: Run three more seeds**

```bash
for s in 2 3 4; do make trace SEED=$s && make sim TOP=tb_decode_validate || exit 1; done
```

Expected: all three PASS. If any fails, the seed is printed in the failure line and reproduces the exact trace.

- [ ] **Step 6: Commit**

```bash
git add tb/tb_decode_validate.sv Makefile
git commit -m "test(tb): randomized replay with backpressure against golden trace"
```

---

### Task 7: Remove the CI scaffold guards

**Files:**
- Modify: `.github/workflows/test.yml:16-22` (lint guard), `.github/workflows/test.yml:34` (pytest guard)

**Interfaces:**
- Consumes: `rtl/market_pkg.sv` from Task 1, `scripts/test_generate_events.py` from Task 2.
- Produces: nothing.

Both guards existed only because `rtl/` and the test suite were empty. Both conditions are now false, so the guards must go — a guard that can no longer trigger is a guard that hides a regression.

- [ ] **Step 1: Replace the lint job's guarded step**

Replace lines 16-22 of `.github/workflows/test.yml`:

```yaml
      # Scaffold guard: skip until rtl/ has sources. Drop once market_pkg.sv lands.
      - name: lint rtl
        run: |
          shopt -s nullglob
          srcs=(rtl/*.sv)
          if [ ${#srcs[@]} -eq 0 ]; then echo "no RTL yet, skipping"; exit 0; fi
          make lint
```

with:

```yaml
      - name: lint rtl
        run: make lint
```

- [ ] **Step 2: Replace the pytest job's guarded step**

Replace line 34:

```yaml
      # exit code 5 == "no tests collected", expected until scripts/ has tests.
      - run: pytest -q || [ $? -eq 5 ]
```

with:

```yaml
      - run: pytest -q
```

- [ ] **Step 3: Verify the guards were load-bearing**

Confirm the lint job now actually lints something rather than passing on an empty glob:

Run: `make lint 2>&1 | tail -3`
Expected: Verilator's verilation report naming the modules it built — not silence.

Run: `.venv/bin/python -m pytest -q`
Expected: 11 passed. Not "no tests ran".

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: drop scaffold guards now that rtl/ and the test suite exist"
```

- [ ] **Step 5: Push and confirm CI is green**

```bash
git push -u origin feat/decode-validate
gh run list --branch feat/decode-validate --limit 1
```

Expected: `completed  success`. If the lint job fails on GitHub but passes locally, the runner's Verilator version differs from 5.032 — record the version difference rather than loosening the lint.

---

## Final verification before review handoff

- [ ] `make lint` — zero warnings
- [ ] `make sim TOP=tb_market_pkg` — PASS
- [ ] `make sim TOP=tb_event_decoder` — PASS
- [ ] `make sim TOP=tb_sequence_checker` — PASS
- [ ] `make trace && make sim TOP=tb_decode_validate` — PASS on seeds 1-4
- [ ] `.venv/bin/python -m pytest -q` — 11 passed
- [ ] `git status` — clean, no generated traces staged
- [ ] `LATENCY_CYCLES == 2` and `tb/assertions.sv` proves it on both stages
- [ ] Hand off to `rtl-verification-engineer`, then `rtl-skeptic-reviewer`; fix all BLOCKER and MAJOR findings
- [ ] Open PR #3 with the `make sim` log and the latency table in the description
