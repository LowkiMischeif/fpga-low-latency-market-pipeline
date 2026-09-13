"""The ROM images baked into the bitstream must be exactly what the tools write.

The bitstream, the top-level testbench and the committed configs all read
these files, so a stale or hand-edited .mem would make the hardware replay a
trace nothing else was tested against.
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from export_config import A, build_writes  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
MEM = REPO / "rtl" / "mem"


def test_trace_mem_regenerates_identically(tmp_path):
    out = tmp_path / "rom_trace.mem"
    subprocess.run([sys.executable, str(REPO / "scripts" / "generate_events.py"),
                    "--n", "2000", "--seed", "1", "--mem", str(out)], check=True)
    assert out.read_text() == (MEM / "rom_trace.mem").read_text()


def test_trace_mem_shape():
    lines = (MEM / "rom_trace.mem").read_text().split()
    assert len(lines) == 2000
    assert all(len(l) == 16 for l in lines)


def test_cfg_mems_match_their_json():
    for name in ("baseline", "tuned"):
        js = json.loads((REPO / "tb" / "configs" / f"{name}.json").read_text())
        expect = [f"{A[n]:02x}{d:08x}" for n, d in build_writes(js)]
        got = (MEM / f"rom_cfg_{name}.mem").read_text().split()
        assert got == expect, f"rom_cfg_{name}.mem is stale"


def test_cfg_mem_ends_with_commit_and_has_one_word_per_register():
    for name in ("baseline", "tuned"):
        got = (MEM / f"rom_cfg_{name}.mem").read_text().split()
        assert len(got) == len(A) == 13
        assert int(got[-1][:2], 16) == A["CFG_COMMIT"]
