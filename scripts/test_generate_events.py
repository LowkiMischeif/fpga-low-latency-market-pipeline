import csv
import re
import subprocess
import sys
from pathlib import Path

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
    pkg = (REPO / "rtl" / "market_pkg.sv").read_text()
    widths = {
        m.group(1).lower(): int(m.group(2))
        for m in re.finditer(r"localparam\s+int\s+(\w+)_W\s*=\s*(\d+)\s*;", pkg)
    }
    # The generator calls the type field "etype" because market_event_t does
    # too -- "type" is a SystemVerilog keyword, so the struct member cannot use
    # it, but the width constant TYPE_W can. Map across that one difference
    # rather than renaming either side.
    pkg_name = {"etype": "type"}
    for name, (_lsb, width) in FIELDS.items():
        key = pkg_name.get(name, name)
        assert key in widths, f"{key.upper()}_W not declared in market_pkg.sv"
        assert widths[key] == width, (
            f"{name}: generator has {width} bits, market_pkg.sv has {widths[key]}"
        )
    assert widths["event"] == EVENT_W
    # The fields must tile the beat exactly -- no gap, no overlap.
    assert sum(w for _, w in FIELDS.values()) == EVENT_W
    covered = sorted((lsb, lsb + w) for lsb, w in FIELDS.values())
    for (_, end), (start, _) in zip(covered, covered[1:]):
        assert end == start, f"field layout has a hole or overlap at bit {end}"


def test_encode_decode_roundtrip():
    word = encode_event(etype=1, symbol=5, side=1, price=1234, qty=99, seq=4242)
    assert decode_event(word) == {
        "etype": 1, "symbol": 5, "side": 1,
        "price": 1234, "qty": 99, "seq": 4242, "rsv": 0,
    }


def test_encode_fits_in_event_width():
    word = encode_event(etype=0xFF, symbol=0xF, side=0x3, price=0xFFFF,
                        qty=0xFFFF, seq=0xFFFF, rsv=0x3)
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
    kw = dict(n=100, seed=7, gap_rate=0.1, stale_rate=0.1,
              bad_type_rate=0.1, bad_side_rate=0.1, bad_rsv_rate=0.1)
    assert generate(**kw) == generate(**kw)


def test_different_seeds_differ():
    kw = dict(n=100, gap_rate=0.2, stale_rate=0.0, bad_type_rate=0.0,
              bad_side_rate=0.0, bad_rsv_rate=0.0)
    assert generate(seed=1, **kw) != generate(seed=2, **kw)


def test_gaps_are_injected_and_flagged():
    evs = generate(n=500, seed=3, gap_rate=0.2, stale_rate=0.0,
                   bad_type_rate=0.0, bad_side_rate=0.0, bad_rsv_rate=0.0)
    assert sum(e["gap"] for e in evs) > 0
    for prev, cur in zip(evs, evs[1:]):
        step = (cur["seq"] - prev["seq"]) % (1 << 16)
        assert cur["gap"] == (step > 1), f"gap flag disagrees with seq step {step}"


def test_stale_events_are_flagged():
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
    assert [e for e in evs if e["seq"] < 20], "test did not cross the wrap"
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
