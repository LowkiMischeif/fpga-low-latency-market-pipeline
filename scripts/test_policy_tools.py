"""Tests for the offline policy tooling.

The point of contention these guard: export_config.py is the boundary where
floats become the fixed-point numbers the hardware runs. A silent wrap here
turns a maximally bullish constant into a bearish one, and nothing downstream
can tell.
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from analyze_latency import parse_histogram, parse_paired_histograms, summarise  # noqa: E402
from export_config import A, C, build_writes, quantise, write_cfg  # noqa: E402
from train_policy import replay_features, score_policy, search  # noqa: E402
from generate_events import generate  # noqa: E402

REPO = Path(__file__).resolve().parent.parent


def base_policy(**over):
    p = {"w0": 0, "w_spread": 1.0, "w_imbalance": 0.0, "w_momentum": 1.0,
         "theta_buy": 40, "theta_sell": 15, "order_qty": 5,
         "max_long": 1000, "max_short": 1000, "max_order_qty": 100,
         "max_spread": 20000, "kill": False}
    p.update(over)
    return p


# --------------------------------------------------------------------------
# export_config
# --------------------------------------------------------------------------
def test_widths_come_from_the_package_not_from_here():
    for name in ("W_W", "W_FRAC_W", "SCORE_W", "QTY_W", "POS_W", "SPREAD_W"):
        assert name in C, f"{name} not parsed out of market_pkg.sv"
    assert C["W_W"] == 16 and C["W_FRAC_W"] == 12


def test_addresses_come_from_the_enum():
    assert A["CFG_W0"] == 0
    assert A["CFG_COMMIT"] == max(A.values()), "commit must be the last write"


def test_quantise_rounds_to_the_fixed_point_grid():
    assert quantise(1.0, 12, 16, "x") == 4096
    assert quantise(0.5, 12, 16, "x") == 2048
    assert quantise(-1.0, 12, 16, "x") == 0x10000 - 4096
    assert quantise(0.0, 12, 16, "x") == 0


def test_quantise_refuses_to_wrap():
    """The failure this file exists to prevent."""
    with pytest.raises(ValueError, match="outside the signed"):
        quantise(8.0, 12, 16, "w_spread")      # 32768, one past the limit
    with pytest.raises(ValueError, match="outside the signed"):
        quantise(-9.0, 12, 16, "w_spread")


def test_quantise_accepts_the_exact_limits():
    assert quantise(32767 / 4096, 12, 16, "x") == 32767
    assert quantise(-8.0, 12, 16, "x") == 0x8000


def test_commit_is_the_last_register_written():
    writes = build_writes(base_policy())
    assert writes[-1][0] == "CFG_COMMIT"
    assert [n for n, _ in writes].count("CFG_COMMIT") == 1


def test_every_mapped_register_is_written():
    written = {n for n, _ in build_writes(base_policy())}
    assert written == set(A), f"unwritten registers: {set(A) - written}"


def test_kill_flag_round_trips():
    assert dict(build_writes(base_policy(kill=True)))["CFG_KILL"] == 1
    assert dict(build_writes(base_policy(kill=False)))["CFG_KILL"] == 0


def test_written_file_is_what_the_testbench_parses(tmp_path):
    out = tmp_path / "x.cfg"
    write_cfg(base_policy(), out)
    rows = [l.split() for l in out.read_text().splitlines()
            if l and not l.startswith("#")]
    assert len(rows) == len(A)
    for r in rows:
        int(r[0], 16), int(r[1], 16)      # both parse as hex
    assert int(rows[-1][0], 16) == A["CFG_COMMIT"]


def test_committed_configs_are_in_sync_with_their_json():
    """The .cfg files in the repo must match their .json, or the headline
    test is running a policy nobody described."""
    for name in ("baseline", "tuned"):
        js = json.loads((REPO / "tb" / "configs" / f"{name}.json").read_text())
        expect = build_writes(js)
        got = [l.split() for l in (REPO / "tb" / "configs" / f"{name}.cfg")
               .read_text().splitlines() if l and not l.startswith("#")]
        assert len(got) == len(expect), f"{name}.cfg has the wrong write count"
        for (ename, edata), row in zip(expect, got):
            assert int(row[0], 16) == A[ename], f"{name}: address for {ename}"
            assert int(row[1], 16) == edata, f"{name}: data for {ename}"


def test_the_two_committed_configs_actually_differ():
    a = dict(build_writes(json.loads(
        (REPO / "tb" / "configs" / "baseline.json").read_text())))
    b = dict(build_writes(json.loads(
        (REPO / "tb" / "configs" / "tuned.json").read_text())))
    differing = {k for k in a if a[k] != b[k]}
    assert differing, "the two configs are identical"
    # They must differ in the WEIGHTS, not merely in a limit or the kill bit.
    assert differing & {"CFG_W_SPREAD", "CFG_W_IMBALANCE", "CFG_W_MOMENTUM"}, \
        f"configs differ only in {differing}, not in any weight"


def test_neither_committed_config_ships_with_the_kill_switch_on():
    for name in ("baseline", "tuned"):
        js = json.loads((REPO / "tb" / "configs" / f"{name}.json").read_text())
        assert not js["kill"], f"{name} ships killed; it would never trade"


# --------------------------------------------------------------------------
# train_policy
# --------------------------------------------------------------------------
def test_replay_produces_features_in_the_rtl_ranges():
    rows = replay_features(generate(n=800, seed=1, gap_rate=0.05, stale_rate=0.03,
                                    bad_type_rate=0.02, bad_side_rate=0.02,
                                    bad_rsv_rate=0.01))
    assert len(rows) == 800
    assert any(not r["empty"] for r in rows), "every row was an empty book"
    for r in rows:
        assert -16384 <= r["imbalance"] <= 16384
        if r["empty"]:
            assert r["spread"] == 0 and r["imbalance"] == 0 and r["momentum"] == 0


def test_search_is_reproducible_and_beats_a_null_policy():
    rows = replay_features(generate(n=1200, seed=3, gap_rate=0.05, stale_rate=0.03,
                                    bad_type_rate=0.02, bad_side_rate=0.02,
                                    bad_rsv_rate=0.01))
    a = search(rows, seed=5, iters=60)
    b = search(rows, seed=5, iters=60)
    assert a == b, "the same seed must give the same policy"
    null = {"w0": 0, "w_spread": 0, "w_imbalance": 0, "w_momentum": 0,
            "theta_buy": 1 << 30, "theta_sell": -(1 << 30)}
    assert a["objective"] >= score_policy(rows, null)


def test_different_seeds_give_different_policies():
    rows = replay_features(generate(n=1200, seed=3, gap_rate=0.05, stale_rate=0.03,
                                    bad_type_rate=0.02, bad_side_rate=0.02,
                                    bad_rsv_rate=0.01))
    assert search(rows, seed=1, iters=60) != search(rows, seed=2, iters=60)


# --------------------------------------------------------------------------
# analyze_latency
# --------------------------------------------------------------------------
def test_histogram_parsing():
    assert parse_histogram("INFO:   8: 2000\n") == {8: 2000}
    a, b = parse_paired_histograms("INFO:   8: 12 / 34\n")
    assert a == {8: 12} and b == {8: 34}


def test_a_fixed_latency_is_reported_as_fixed():
    s = summarise({8: 2000})
    assert s["fixed"] and s["min"] == s["max"] == 8 and s["mean"] == 8


def test_a_spread_of_latencies_is_not_fixed():
    """The tool must refuse to average away a variable latency."""
    s = summarise({8: 1999, 9: 1})
    assert not s["fixed"]
    assert s["min"] == 8 and s["max"] == 9
    assert 8 < s["mean"] < 9        # a mean alone would look like "about 8"


def test_cli_fails_on_a_variable_latency(tmp_path):
    log = tmp_path / "l.log"
    log.write_text("INFO:   8: 1999\nINFO:   9: 1\n")
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "analyze_latency.py"),
                        str(log)], capture_output=True, text=True)
    assert r.returncode == 1
    assert "NOT fixed" in r.stderr


def test_cli_fails_when_configs_have_different_distributions(tmp_path):
    log = tmp_path / "l.log"
    log.write_text("INFO:   8: 2000 / 1999\nINFO:   9: 0 / 1\n")
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "analyze_latency.py"),
                        str(log), "--compare-configs"], capture_output=True, text=True)
    assert r.returncode == 1
    assert "different latency distributions" in r.stderr


# --------------------------------------------------------------------------
# Provenance.
#
# tuned.json claims to be the output of a specific train_policy.py command.
# That claim shipped false once -- the file said "from train_policy.py --seed 7"
# while holding hand-picked quarter-integers that random.uniform cannot emit --
# so it gets a test that actually reruns the command.
# --------------------------------------------------------------------------
def test_tuned_config_regenerates_from_the_command_in_its_note():
    import re
    import train_policy

    js = json.loads((REPO / "tb" / "configs" / "tuned.json").read_text())
    m = re.match(r"Generated by: scripts/train_policy\.py (.+)$", js["note"])
    assert m, f"tuned.json's note does not name a command: {js['note']!r}"

    args = m.group(1).split()
    opts = dict(zip(args[::2], args[1::2]))
    events = train_policy.generate(
        n=int(opts["--events"]), seed=int(opts["--seed"]), gap_rate=0.05,
        stale_rate=0.03, bad_type_rate=0.02, bad_side_rate=0.02,
        bad_rsv_rate=0.01)
    rows = train_policy.replay_features(events)
    best = train_policy.search(rows, int(opts["--seed"]), int(opts["--iters"]))

    for k in ("w0", "w_spread", "w_imbalance", "w_momentum",
              "theta_buy", "theta_sell"):
        assert abs(best[k] - js[k]) < 1e-9, (
            f"{k}: committed {js[k]}, the command produces {best[k]}. "
            "tuned.json no longer matches its own provenance note.")


def test_baseline_does_not_claim_to_be_trained():
    js = json.loads((REPO / "tb" / "configs" / "baseline.json").read_text())
    assert "HAND-CHOSEN" in js["note"], \
        "baseline is hand-picked; its note must say so"
    assert "train_policy" not in js["note"]


def test_the_trainer_output_is_directly_consumable_by_export_config():
    """There must be a real trainer -> config path, not a hand-edited file."""
    import train_policy
    rows = train_policy.replay_features(generate(
        n=1500, seed=11, gap_rate=0.05, stale_rate=0.03, bad_type_rate=0.02,
        bad_side_rate=0.02, bad_rsv_rate=0.01))
    best = train_policy.search(rows, 11, 120)
    policy = train_policy.as_policy(best, "t", "cmd", 5, 1000, 1000, 100, 20000)
    writes = build_writes(policy)          # must not raise
    assert {n for n, _ in writes} == set(A)


def test_the_trainer_refuses_a_policy_that_never_trades():
    """An off switch scores zero and would beat a losing policy."""
    import train_policy
    rows = train_policy.replay_features(generate(
        n=400, seed=2, gap_rate=0.0, stale_rate=0.0, bad_type_rate=0.0,
        bad_side_rate=0.0, bad_rsv_rate=0.0))
    never = {"w0": 0, "w_spread": 0, "w_imbalance": 0, "w_momentum": 0,
             "theta_buy": 1 << 30, "theta_sell": -(1 << 30)}
    assert train_policy.score_policy(rows, never) == float("-inf")


def test_offline_score_is_bit_exact_with_the_rtl_formula():
    """The trainer scores QUANTISED candidates using integer arithmetic.

    Searching in float and quantising afterwards would let the tuner pick a
    policy whose hardware twin behaves differently.
    """
    import train_policy
    qw = train_policy.quantise_weights(
        {"w0": 3.0, "w_spread": 1.0, "w_imbalance": -0.5, "w_momentum": 0.25,
         "theta_buy": 100, "theta_sell": -100})
    assert qw["w_spread"] == 4096 and qw["w_imbalance"] == -2048
    row = {"spread": 1000, "imbalance": 8192, "momentum": 40, "empty": False}
    expect = ((4096 * 1000) + (-2048 * 8192) + (1024 * 40)) >> 12
    assert train_policy.rtl_score(qw, row) == expect + 3
