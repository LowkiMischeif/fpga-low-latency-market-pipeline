"""The README's results table must say exactly what its evidence files say.

The project's non-negotiable is that only measured numbers are stated. The
README's Results table may contain only the rows listed in ROWS below, each
exactly once. For each, this test parses the value out of the file the row
links and requires the row's value cell to be exactly the string built from it
-- so a changed digit, a flipped sign, a stale count or an unchecked new row
fails.

What it cannot check: whether a number MEANS what the row's label says beyond
the few label facts asserted here, and any sentence outside the table.
rtl-skeptic-reviewer covers those.
"""
import csv
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
README = REPO / "README.md"
RES = REPO / "results"

ROWS = (
    "Input-to-decision latency",
    "Latency under the two committed policies",
    "Synthesizable top vs the verified pipeline",
    "Post-route WNS / WHS at 100 MHz",
    "Measured Fmax",
    "Utilisation: LUT / FF / block RAM tile / DSP",
    "Critical-path iterations: setup WNS at 100 MHz",
    "Mutation testing",
)
BUILD_RECORDS = ("results/iter0_100mhz/GATE_FAILED.md",
                 "results/iter1_100mhz/GATE_FAILED.md",
                 "results/100mhz/BUILD_SCOPE.md")


def _text(path):
    return (REPO / path).read_text()


def _rows():
    text = README.read_text()
    assert "## Results" in text, "README has no Results section"
    section = text.split("## Results", 1)[1].split("\n## ", 1)[0]
    rows = []
    for line in section.splitlines():
        if line.startswith("|") and not set(line.strip()) <= set("|-: "):
            rows.append([c.strip() for c in line.strip().strip("|").split("|")])
    return rows[1:]          # drop the header row


def _row(label):
    matches = [r for r in _rows() if r[0].startswith(label)]
    assert len(matches) == 1, f"expected one Results row starting {label!r}"
    return matches[0]


def _cell(label):
    return _row(label)[1]


def _signed(v):
    """README style: +0.250 / −73.898 (U+2212 minus)."""
    return f"−{v[1:]}" if v.startswith("-") else f"+{v}"


def _search(pattern, path):
    m = re.search(pattern, _text(path), re.M)
    assert m, f"{pattern!r} not found in {path}"
    return m.groups()


def _latency():
    pkg = _text("rtl/market_pkg.sv")
    terms = re.findall(r"localparam int (LAT_\w+)\s*=\s*(\d+);", pkg)
    return sum(int(v) for _, v in terms)


def test_results_table_has_exactly_the_checked_rows():
    labels = [r[0] for r in _rows()]
    for label in labels:
        owners = [k for k in ROWS if label.startswith(k)]
        assert len(owners) == 1, f"Results row is not checked by this test: {label!r}"
    for key in ROWS:
        assert sum(label.startswith(key) for label in labels) == 1, f"missing row {key!r}"


def test_every_results_row_cites_an_existing_artifact():
    for row in _rows():
        links = re.findall(r"\]\(([^)#\s]+)", row[2])
        assert links, f"results row cites no artifact: {row}"
        for link in links:
            assert (REPO / link).exists(), f"cited artifact does not exist: {link}"


def test_rows_labelled_100mhz_come_from_10ns_builds():
    for rec in BUILD_RECORDS:
        (period,) = _search(r"^- Clock: sys_clk at ([0-9.]+) ns", rec)
        assert period == "10.000", f"{rec} was not built at 10.000 ns"


def test_latency_row_equals_the_histogram():
    (events,) = _search(r"^events\s+(\d+)", "results/sim/analyze_latency.txt")
    lo, mean, hi = _search(r"^min/mean/max\s+(\d+) / (\d+) / (\d+) cycles",
                           "results/sim/analyze_latency.txt")
    assert lo == mean == hi == str(_latency()), "measured latency is not LATENCY_CYCLES"
    assert _cell("Input-to-decision latency") == \
        f"{lo} clock cycles for all {events} events: min = mean = max"


def test_two_policy_row_equals_its_logs():
    log = "results/sim/analyze_latency_configs.txt"
    (events,) = _search(r"^events\s+(\d+)", log)
    dist, count = _search(r"^distribution\s+\{(\d+): (\d+)\}$", log)
    assert count == events, "the combined histogram does not cover every event"
    _search(r"^(both configurations share one latency distribution)", log)
    (differ,) = _search(r"^PASS: tb_policy_configs -- (\d+) decisions differ",
                        "results/sim/tb_policy_configs.txt")
    per = int(events) // 2
    assert _cell("Latency under the two committed policies") == \
        f"identical: all {per} events at {dist} cycles under each, while {differ} of {per} decisions differ"


def test_top_level_row_equals_its_log():
    log = "results/sim/tb_market_pipeline_top.txt"
    (matched,) = _search(r"^PASS: tb_market_pipeline_top -- (\d+) decisions matched", log)
    events, bad, cyc, before = _search(
        r"^INFO: top latency (\d+) events, (\d+) not at (\d+) cycles \((\d+) handed off before the reset\)", log)
    assert bad == "0"
    assert int(before) > 0, "the row claims a reset mid-replay, but nothing was handed off before it"
    assert _cell("Synthesizable top vs the verified pipeline") == \
        f"{matched} decisions matched, 0 mismatches; all {events} handed-off events at {cyc} cycles, across a reset mid-replay"


def test_wns_whs_row_equals_the_100mhz_build():
    wns, whs = _search(r"Post-route WNS (-?[0-9.]+) ns / WHS (-?[0-9.]+) ns",
                       "results/100mhz/BUILD_SCOPE.md")
    assert _cell("Post-route WNS / WHS at 100 MHz") == f"{_signed(wns)} ns / {_signed(whs)} ns"


def test_fmax_row_equals_the_sweep():
    fmax, period = _search(r"^measured_fmax_mhz=([0-9.]+) period_ns=([0-9.]+)",
                           "results/sweep/FMAX.md")
    with open(RES / "sweep" / "summary.csv") as fh:
        runs = list(csv.DictReader(fh))
    passes = [float(r["period_ns"]) for r in runs if r["result"] == "pass"]
    fails = [float(r["period_ns"]) for r in runs if r["result"] == "fail"]
    assert min(passes) == float(period), "summary.csv has a faster pass than FMAX.md reports"
    slower_fail = max(p for p in fails if p < float(period))
    assert "not usable on this board" in _row("Measured Fmax")[0]
    assert _cell("Measured Fmax") == f"{fmax} MHz ({period} ns passes, {slower_fail:.1f} ns fails)"


def test_utilisation_row_equals_the_report():
    rpt = "results/100mhz/post_route_utilization.rpt"
    vals = [_search(rf"^\|\s*{name}\s*\|\s*(\d+)", rpt)[0]
            for name in ("Slice LUTs", "Slice Registers", "Block RAM Tile", "DSPs")]
    assert _cell("Utilisation: LUT / FF / block RAM tile / DSP") == " / ".join(vals)


def test_iteration_row_equals_the_three_records():
    pat = r"Post-route WNS (-?[0-9.]+) ns"
    a, b, c = (_search(pat, rec)[0] for rec in BUILD_RECORDS)
    assert _cell("Critical-path iterations") == \
        f"{_signed(a)} ns → {_signed(b)} ns → {_signed(c)} ns"


def test_mutation_row_equals_the_log():
    killed, survived = _search(r"^killed (\d+), survived (\d+)$", "results/sim/mutation.txt")
    total = int(killed) + int(survived)
    assert _cell("Mutation testing") == f"{killed} of {total} mutants killed, {survived} survived"


def test_no_unmeasured_or_banned_claims():
    text = README.read_text().lower()
    banned = ("250 mhz", "32 ns", "production-ready", "production ready",
              "nanosecond latency", "sub-millisecond", "ready for live trading",
              "suitable for live trading", "live-trading ready", "hft-ready")
    for phrase in banned:
        assert phrase not in text, f"README contains an unsupported claim: {phrase}"


def test_hardware_status_is_stated():
    text = README.read_text().lower()
    assert "has not been run on" in text and "hardware" in text, \
        "README must state the design has not been run on physical hardware"
