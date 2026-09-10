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


# ---------------------------------------------------------------------------
# Independent re-derivation of the flags.
#
# Everything above checks the generator against itself: it reads e["gap"] and
# e["stale"], which generate() set from its own bookkeeping. These reconstruct
# the flags from the sequence numbers alone, using the rule written out in the
# design spec's condition/action table, and never look at the generator's
# internal `expect`. If the generator's model of the feed drifts from the
# spec, this is what notices.
# ---------------------------------------------------------------------------
SEQ_MOD_16 = 1 << 16


def _signed16(x: int) -> int:
    x &= SEQ_MOD_16 - 1
    return x - SEQ_MOD_16 if x >= (SEQ_MOD_16 >> 1) else x


STALE_RESYNC_LIMIT_REF = 16   # must match rtl/sequence_checker.sv


def classify(seqs, trusted=None):
    """Return (gap, stale, missed) per event using the spec's rule.

    Written from the specified behaviour rather than from generate_events.py,
    so it is an independent check on the generator rather than a restatement
    of it.

    diff = rx - expect in 16-bit modular arithmetic, read as signed: positive
    is a gap, negative is stale, zero is in order.

    Only a trusted event -- one with no encoding defect -- may establish the
    baseline after reset or resync it past a gap. A malformed beat has already
    failed its field checks, so its seq is not trustworthy either; it rides the
    ordinary +1 when it lands exactly in order and is otherwise not allowed to
    move the expectation. A run of STALE_RESYNC_LIMIT_REF stale events forces
    a resync, which bounds the damage from sequence aliasing beyond +/-32767.

    `trusted` defaults to all-True, which reproduces the plain sequence rule.
    """
    if trusted is None:
        trusted = [True] * len(seqs)
    out = []
    expect = None
    stale_run = 0
    for rx, ok in zip(seqs, trusted):
        if expect is None:
            out.append((False, False, 0))
            if ok:
                expect = (rx + 1) % SEQ_MOD_16
            continue
        diff = _signed16(rx - expect)
        gap, stale = diff > 0, diff < 0
        missed = diff if (gap and ok) else 0
        force_resync = stale and stale_run >= STALE_RESYNC_LIMIT_REF - 1
        if diff == 0 or (gap and ok) or force_resync:
            expect = (rx + 1) % SEQ_MOD_16
        stale_run = stale_run + 1 if (stale and not force_resync) else 0
        out.append((gap, stale, missed))
    return out


def test_flags_match_independent_classifier():
    evs = generate(n=1000, seed=17, gap_rate=0.08, stale_rate=0.06,
                   bad_type_rate=0.02, bad_side_rate=0.02, bad_rsv_rate=0.01)
    ref = classify([e["seq"] for e in evs],
                   [not (e["bad_type"] or e["bad_side"] or e["bad_rsv"]) for e in evs])
    for i, (e, (gap, stale, _missed)) in enumerate(zip(evs, ref)):
        assert e["gap"] == gap, f"event {i}: generator gap={e['gap']}, spec rule says {gap}"
        assert e["stale"] == stale, f"event {i}: generator stale={e['stale']}, spec rule says {stale}"


def test_flags_match_independent_classifier_across_the_wrap():
    """The default trace never reaches 0xFFFF, so aim one at the wrap."""
    evs = generate(n=2000, seed=23, gap_rate=0.08, stale_rate=0.06,
                   bad_type_rate=0.02, bad_side_rate=0.02, bad_rsv_rate=0.01,
                   start_seq=SEQ_MOD_16 - 64)
    seqs = [e["seq"] for e in evs]
    assert max(seqs) > SEQ_MOD_16 - 32 and min(seqs) < 1000, "trace did not cross the wrap"
    ref = classify(seqs,
                   [not (e["bad_type"] or e["bad_side"] or e["bad_rsv"]) for e in evs])
    for i, (e, (gap, stale, _missed)) in enumerate(zip(evs, ref)):
        assert e["gap"] == gap, f"event {i} (seq {e['seq']}): gap disagrees across the wrap"
        assert e["stale"] == stale, f"event {i} (seq {e['seq']}): stale disagrees across the wrap"


def test_injected_defects_stay_inside_the_signed_comparison_window():
    """The generator cannot reach the +/-32768 aliasing boundary.

    sequence_checker reads a 16-bit modular difference as signed, so a forward
    jump of 32768 or more is indistinguishable from a backward one. This test
    records that the randomized replay never gets near that boundary -- gaps
    and stale distances are 1..8 by construction -- which is precisely why the
    boundary is covered by hand-written vectors in tb_sequence_checker.sv
    instead. If someone widens the injection range, this fails and the split of
    responsibility gets revisited on purpose rather than by accident.
    """
    evs = generate(n=3000, seed=29, gap_rate=0.15, stale_rate=0.15,
                   bad_type_rate=0.0, bad_side_rate=0.0, bad_rsv_rate=0.0)
    ref = classify([e["seq"] for e in evs],
                   [not (e["bad_type"] or e["bad_side"] or e["bad_rsv"]) for e in evs])
    gaps = [m for (g, _s, m) in ref if g]
    assert gaps, "no gaps generated"
    assert max(gaps) <= 8, f"gap of {max(gaps)} exceeds the documented 1..8 range"
    assert max(gaps) < (SEQ_MOD_16 >> 1), "generator can reach the signed-comparison boundary"


def test_start_seq_is_honoured():
    """--start-seq is what aims a randomized trace at the wrap; it has to work."""
    evs = generate(n=5, seed=31, start_seq=60000)
    assert evs[0]["seq"] == 60000
    evs = generate(n=5, seed=31, start_seq=SEQ_MOD_16 + 7)
    assert evs[0]["seq"] == 7, "start_seq must be taken modulo 2**16"
