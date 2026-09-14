# Integration and Timing Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the six verified stages and `config_regs` under one synthesizable Basys 3 top, close timing with committed reports and a measured Fmax, and document the project so that every number traces to a committed artifact.

**Architecture:** An on-chip trace ROM and a config-preset loader feed the existing pipeline; decisions drive LEDs and the 7-seg. All I/O is asynchronous and human-scale, so the XDC false-paths it with written reasons rather than inventing I/O delays. `build.tcl` gains a period override for an Fmax sweep; one latency-neutral critical-path change is recorded before and after.

**Tech Stack:** SystemVerilog-2012, Vivado 2026.1 (xsim, non-project synth/impl), Verilator 5.032 lint, Python 3 with pytest.

**Spec:** `docs/superpowers/specs/2026-09-13-integration-timing-design.md` (parent contract: `docs/superpowers/specs/2026-09-09-market-pipeline-design.md`)

## Global Constraints

- Part `xc7a35tcpg236-1`, Digilent Basys 3. Pins from Digilent's `Basys-3-Master.xdc`, which is labelled **Rev B**; cite it as that.
- One clock: `clk` on W5, `create_clock -period 10.000`. No MMCM.
- `LATENCY_CYCLES` stays **8**. No task may change any `LAT_*` constant. A critical-path fix that needs a register is recorded as analysed, not applied.
- Fixed-point only in `rtl/`. No floating point.
- Every module keeps its asynchronous active-low reset; `reset_sync` is the single synchronizer, instantiated once in `market_pipeline_top`.
- No `set_input_delay` / `set_output_delay`. Asynchronous inputs get `set_false_path -from`, human-scale outputs `set_false_path -to`, each with a written reason in the XDC.
- No hardware run exists. Nothing may claim behaviour observed on a board.
- No Fmax above 100 MHz may be presented as usable on the Basys 3; state that it needs an MMCM.
- README numbers must each cite a committed artifact. No "250 MHz", no "32 ns", no live-trading or exchange-connectivity claims.
- One module per file in `rtl/` (Verible `one-module-per-file`).
- Every RTL change: `make lint`, `make lint-tb`, `make sim-all`, `./scripts/mutate.sh` (baseline gate must pass) before commit.
- Before committing RTL, constraints or results docs: `rtl-skeptic-reviewer`; fix all BLOCKER/MAJOR.
- Commit messages end with the session attribution lines given in the conversation.
- CI: no scaffold guards remain in `.github/workflows/test.yml` (both were removed in #3). Nothing to remove; PR #9 states that rather than inventing a change.

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/generate_events.py` (modify) | `--mem PATH`: write the trace ROM image only |
| `scripts/export_config.py` (modify) | `--mem PATH`: write a 13-word `{addr,data}` preset ROM image |
| `rtl/mem/rom_trace.mem` (create) | 2000 × 64-bit trace, seed 1, committed |
| `rtl/mem/rom_cfg_baseline.mem`, `rtl/mem/rom_cfg_tuned.mem` (create) | Preset ROM images from `tb/configs/*.json` |
| `scripts/test_mem_files.py` (create) | Committed `.mem` files regenerate byte-identically |
| `rtl/reset_sync.sv` (create) | Async-assert, 2-flop sync-deassert reset |
| `rtl/trace_rom.sv` (create) | Registered-read ROM, `$readmemh` init |
| `rtl/replay_ctrl.sv` (create) | Button sync, edge, lockout; walks the ROM into `s_data/s_valid` |
| `rtl/cfg_loader.sv` (create) | Writes the selected preset into `config_regs` on reset and on switch change |
| `rtl/seg7_display.sv` (create) | 4-digit multiplexed hex display, active-low |
| `rtl/market_pipeline_top.sv` (create) | Wiring, counters, LEDs |
| `tb/mem/tb_trace8.mem` (create) | 8-event trace for `tb_replay_ctrl` |
| `tb/tb_reset_sync.sv`, `tb/tb_replay_ctrl.sv`, `tb/tb_cfg_loader.sv`, `tb/tb_seg7_display.sv`, `tb/tb_market_pipeline_top.sv` (create) | Directed and integrated tests |
| `constraints/target_board.xdc` (rewrite) | Full pinout, clock, false paths with reasons |
| `scripts/build.tcl` (modify) | `PERIOD` and run-name args, `read_mem`, clock override, per-run results dir |
| `scripts/fmax_sweep.sh` (create) | Coarse-then-bisect period sweep, `results/sweep/summary.csv`, `FMAX.md` |
| `Makefile` (modify) | `mem`, `PERIOD`/`RUN` on `build`, `fmax` |
| `scripts/mutants.txt` (modify) | Mutants for the new modules |
| `docs/TIMING_CLOSURE.md`, `docs/ARCHITECTURE.md`, `docs/LATENCY.md`, `docs/VERIFICATION.md`, `docs/AI_POLICY.md` (create) | Documentation |
| `README.md` (create) | Results table, every number cited |
| `scripts/test_readme_citations.py` (create) | README rows cite existing artifacts; key numbers match their artifacts |
| `docs/STATUS.md` (modify) | Handover state |

---

### Task 1: ROM images from the existing Python tools

**Files:**
- Modify: `scripts/generate_events.py` (argument parsing in `main`)
- Modify: `scripts/export_config.py` (add `write_mem`, `--mem`)
- Create: `rtl/mem/rom_trace.mem`, `rtl/mem/rom_cfg_baseline.mem`, `rtl/mem/rom_cfg_tuned.mem`
- Modify: `Makefile` (add `mem` target)
- Test: `scripts/test_mem_files.py`

**Interfaces:**
- Consumes: `generate(...)`, `encode_event`, `EVENT_W` from `generate_events.py`; `build_writes(policy)`, `A`, `C` from `export_config.py`.
- Produces: `rtl/mem/rom_trace.mem` — 2000 lines, 16 hex digits each. `rtl/mem/rom_cfg_{baseline,tuned}.mem` — 13 lines, 10 hex digits each: 2 digits address, 8 digits data; last line is `CFG_COMMIT`. `export_config.write_mem(policy: dict, out: Path) -> None`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test_mem_files.py`:

```python
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `.venv/bin/python -m pytest scripts/test_mem_files.py -q`
Expected: FAIL — `generate_events.py: error: unrecognized arguments: --mem`, and `rtl/mem/*.mem` not found.

- [ ] **Step 3: Implement**

In `scripts/generate_events.py` `main()`, add the argument next to `--out`, and write only the ROM image when it is given:

```python
    p.add_argument("--mem", type=Path,
                   help="write ONLY a $readmemh ROM image to this path")
```

and replace the tail of `main()`:

```python
    if a.mem:
        a.mem.parent.mkdir(parents=True, exist_ok=True)
        nibbles = EVENT_W // 4
        a.mem.write_text("".join(f"{e['word']:0{nibbles}x}\n" for e in events))
        print(f"wrote {a.n} events to {a.mem} (seed={a.seed})")
        return
    write_trace(events, a.out)
    print(f"wrote {a.n} events to {a.out}.hex and {a.out}_expected.csv "
          f"(seed={a.seed})")
```

In `scripts/export_config.py`, add after `write_cfg`:

```python
def write_mem(policy: dict, out: Path) -> None:
    """A $readmemh image for cfg_loader: one 40-bit word per register write.

    Two hex digits of address then eight of data, in the same order as the
    .cfg file, ending with CFG_COMMIT. cfg_loader replays the words in order.
    """
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("".join(f"{A[n]:02x}{d:08x}\n" for n, d in build_writes(policy)))
```

and in its `main()` make `--out` optional and add `--mem`:

```python
    p.add_argument("--out", type=Path)
    p.add_argument("--mem", type=Path, help="write a cfg_loader ROM image")
    a = p.parse_args()
    policy = json.loads(a.policy.read_text())
    if a.mem:
        write_mem(policy, a.mem)
        print(f"wrote {a.mem}")
    if a.out:
        writes = write_cfg(policy, a.out)
        print(f"wrote {len(writes)} register writes to {a.out}")
    if not (a.mem or a.out):
        p.error("give --out, --mem, or both")
```

In `Makefile`, add `mem` to `.PHONY` and:

```makefile
# ROM images baked into the bitstream. Regenerate after changing the trace
# seed or either committed config; scripts/test_mem_files.py fails if these
# drift from what the tools produce.
MEM_DIR := rtl/mem
mem:
	$(PYTHON) scripts/generate_events.py --n 2000 --seed 1 --mem $(MEM_DIR)/rom_trace.mem
	$(PYTHON) scripts/export_config.py tb/configs/baseline.json --mem $(MEM_DIR)/rom_cfg_baseline.mem
	$(PYTHON) scripts/export_config.py tb/configs/tuned.json --mem $(MEM_DIR)/rom_cfg_tuned.mem
```

Then generate: `make mem`

- [ ] **Step 4: Run the tests**

Run: `.venv/bin/python -m pytest -q`
Expected: all pass, including the 4 new tests.

- [ ] **Step 5: Commit**

```bash
git add scripts/generate_events.py scripts/export_config.py scripts/test_mem_files.py rtl/mem/ Makefile
git commit -m "feat(scripts): ROM images for the on-chip trace and config presets"
```

---

### Task 2: `reset_sync`

**Files:**
- Create: `rtl/reset_sync.sv`
- Test: `tb/tb_reset_sync.sv`

**Interfaces:**
- Produces: `module reset_sync (input logic clk, input logic arst_in, output logic rst_n)` — `arst_in` active high and asynchronous; `rst_n` asserts immediately, deasserts on the second rising edge after `arst_in` falls.

- [ ] **Step 1: Write the failing test** — `tb/tb_reset_sync.sv`:

```systemverilog
// Directed tests for reset_sync: the single reset synchronizer spec 3.3
// promises. Assertion must be asynchronous (no clock needed); release must be
// synchronous and take exactly two rising edges; a re-assertion during release
// must restart it.
module tb_reset_sync;
  logic clk = 1'b0, arst_in = 1'b0, rst_n;
  always #5 clk = ~clk;
  reset_sync dut (.*);

  int errors = 0;
  task automatic check(string name, logic cond);
    if (!cond) begin errors++; $error("FAIL: %s", name); end
  endtask

  initial begin
    // Establish released state.
    arst_in = 1'b1; #12; arst_in = 1'b0;
    repeat (4) @(posedge clk); #1;
    check("released after reset", rst_n === 1'b1);

    // Asynchronous assert: mid-cycle, no clock edge.
    @(posedge clk); #2;
    arst_in = 1'b1; #1;
    check("assert is immediate, without a clock edge", rst_n === 1'b0);

    // Synchronous release: exactly two rising edges.
    @(negedge clk); arst_in = 1'b0;
    @(posedge clk); #1;
    check("still in reset after one edge", rst_n === 1'b0);
    @(posedge clk); #1;
    check("released on the second edge", rst_n === 1'b1);

    // Re-assert during release restarts it.
    @(negedge clk); arst_in = 1'b1;
    @(negedge clk); arst_in = 1'b0;
    @(posedge clk); #1;
    @(negedge clk); arst_in = 1'b1; #1;
    check("re-assert during release forces reset again", rst_n === 1'b0);
    @(negedge clk); arst_in = 1'b0;
    @(posedge clk); #1;
    check("restarted release: one edge is not enough", rst_n === 1'b0);
    @(posedge clk); #1;
    check("restarted release: two edges", rst_n === 1'b1);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_reset_sync");
    $finish;
  end
endmodule
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make sim TOP=tb_reset_sync`
Expected: FAIL — `Module <reset_sync> not found`.

- [ ] **Step 3: Implement** — `rtl/reset_sync.sv`:

```systemverilog
// reset_sync.sv -- the design's single reset synchronizer (spec 3.3).
//
// Every other module resets asynchronously and has no synchronizer of its
// own. Asynchronous RELEASE is the hazard: on 7-series it can violate
// recovery/removal and drop flops out of reset on different cycles. This
// asserts asynchronously and releases through two flops, so rst_n leaves reset
// on a clock edge, and Vivado times that release as an ordinary recovery path.
module reset_sync (
  input  logic clk,
  input  logic arst_in,   // active high, asynchronous (a board button)
  output logic rst_n
);
  (* ASYNC_REG = "TRUE" *) logic stage1;
  (* ASYNC_REG = "TRUE" *) logic stage2;

  always_ff @(posedge clk or posedge arst_in) begin
    if (arst_in) begin
      stage1 <= 1'b0;
      stage2 <= 1'b0;
    end else begin
      stage1 <= 1'b1;
      stage2 <= stage1;
    end
  end

  assign rst_n = stage2;
endmodule
```

- [ ] **Step 4: Run the tests**

Run: `make lint && make lint-tb && make sim TOP=tb_reset_sync`
Expected: lint clean; `PASS: tb_reset_sync`.

- [ ] **Step 5: Add mutants** — append to `scripts/mutants.txt`:

```
== reset_sync ==
rst: release through one flop @@ rtl/reset_sync.sv @@ tb_reset_sync @@   assign rst_n = stage2; @@   assign rst_n = stage1;
rst: synchronous assert @@ rtl/reset_sync.sv @@ tb_reset_sync @@   always_ff @(posedge clk or posedge arst_in) begin @@   always_ff @(posedge clk) begin
```

Run: `./scripts/mutate.sh rst:` — Expected: `killed 2, survived 0`.

- [ ] **Step 6: Commit**

```bash
git add rtl/reset_sync.sv tb/tb_reset_sync.sv scripts/mutants.txt
git commit -m "feat(rtl): reset_sync, the single async-assert sync-release synchronizer"
```

---

### Task 3: `trace_rom` and `replay_ctrl`

**Files:**
- Create: `rtl/trace_rom.sv`, `rtl/replay_ctrl.sv`, `tb/mem/tb_trace8.mem`
- Test: `tb/tb_replay_ctrl.sv`

**Interfaces:**
- Consumes: `market_pkg::EVENT_W`.
- Produces:
  - `module trace_rom #(parameter int N = 2000, parameter string MEM_FILE = "rtl/mem/rom_trace.mem") (input logic clk, input logic [$clog2(N)-1:0] addr, output logic [EVENT_W-1:0] data)` — registered read, one cycle.
  - `module replay_ctrl #(parameter int N_TRACE = 2000, parameter int LOCKOUT_W = 20) (input clk, rst_n, btn, hold_off; output [$clog2(N_TRACE)-1:0] rom_addr; input [EVENT_W-1:0] rom_data; output [EVENT_W-1:0] s_data; output s_valid; input s_ready; output busy, start_pulse)`.

- [ ] **Step 1: Create the test trace** — `tb/mem/tb_trace8.mem`:

```
0101000000000011
0202000000000022
0303000000000033
0404000000000044
0505000000000055
0606000000000066
0707000000000077
0808000000000088
```

- [ ] **Step 2: Write the failing test** — `tb/tb_replay_ctrl.sv`:

```systemverilog
// Directed tests for replay_ctrl + trace_rom.
//
// The replay must present every ROM word exactly once, in order, with no
// bubble and no duplicate, under arbitrary backpressure -- the ROM has a
// registered read, so the address has to run one word ahead of the accept.
// A press during a replay, during the lockout, or while hold_off is high must
// be ignored.
module tb_replay_ctrl;
  import market_pkg::*;
  localparam int N = 8;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic btn = 1'b0, hold_off = 1'b0;
  logic [$clog2(N)-1:0] rom_addr;
  logic [EVENT_W-1:0]   rom_data, s_data;
  logic s_valid, s_ready, busy, start_pulse;

  trace_rom #(.N(N), .MEM_FILE("tb/mem/tb_trace8.mem"))
    u_rom (.clk(clk), .addr(rom_addr), .data(rom_data));
  replay_ctrl #(.N_TRACE(N), .LOCKOUT_W(6)) dut (.*);

  logic [EVENT_W-1:0] expect_mem [0:N-1];
  initial $readmemh("tb/mem/tb_trace8.mem", expect_mem);

  int errors = 0, got = 0, starts = 0;
  logic [EVENT_W-1:0] got_words [0:63];
  task automatic check(string name, logic cond);
    if (!cond) begin errors++; $error("FAIL: %s", name); end
  endtask

  always @(posedge clk) begin
    if (rst_n && s_valid && s_ready) begin
      if (got < 64) got_words[got] = s_data;
      got++;
    end
    if (rst_n && start_pulse) starts++;
  end

  // Random backpressure throughout.
  int unsigned st = 32'h1234_5678;
  always @(negedge clk) begin
    st ^= st << 13; st ^= st >> 17; st ^= st << 5;
    s_ready = (st % 3) != 0;
  end

  task automatic press();
    @(negedge clk); btn = 1'b1;
    repeat (4) @(negedge clk);
    btn = 1'b0;
  endtask

  task automatic wait_idle();
    int guard = 0;
    @(negedge clk);
    while (busy) begin @(negedge clk); guard++; if (guard > 2000) $fatal(1, "FAIL: replay hung"); end
  endtask

  initial begin
    repeat (3) @(posedge clk); rst_n = 1'b1;
    repeat (80) @(negedge clk);   // outlast the post-reset lockout (2**6)

    // --- one press replays all N words in order ------------------------
    press(); wait_idle();
    check("one press -> exactly N words", got == N);
    for (int i = 0; i < N; i++)
      check($sformatf("word %0d in order", i), got_words[i] === expect_mem[i]);
    check("one start pulse", starts == 1);
    check("s_valid low after the replay", s_valid === 1'b0);

    // --- a press during a replay is ignored -----------------------------
    repeat (80) @(negedge clk);
    got = 0; starts = 0;
    press();
    repeat (6) @(negedge clk);
    press();                       // mid-replay
    wait_idle();
    check("press during replay does not restart it", got == N && starts == 1);

    // --- a press inside the lockout is ignored --------------------------
    got = 0; starts = 0;
    press(); wait_idle();
    press();                       // lockout (64 cycles) not yet expired
    repeat (20) @(negedge clk);
    check("press inside lockout ignored", starts == 1 && got == N);

    // --- hold_off blocks a press ----------------------------------------
    repeat (80) @(negedge clk);
    got = 0; starts = 0;
    hold_off = 1'b1;
    press();
    repeat (20) @(negedge clk);
    check("hold_off blocks a press", starts == 0 && got == 0);
    hold_off = 1'b0;

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_replay_ctrl");
    $finish;
  end

  initial begin #2000000; $fatal(1, "FAIL: timeout"); end
endmodule
```

- [ ] **Step 3: Run it to verify it fails**

Run: `make sim TOP=tb_replay_ctrl`
Expected: FAIL — `Module <trace_rom> not found`.

- [ ] **Step 4: Implement** — `rtl/trace_rom.sv`:

```systemverilog
// trace_rom.sv -- the on-chip event trace, initialised from a .mem image
// written by scripts/generate_events.py. Registered read so it infers BRAM.
module trace_rom
  import market_pkg::*;
#(
  parameter int    N        = 2000,
  parameter string MEM_FILE = "rtl/mem/rom_trace.mem"
) (
  input  logic                  clk,
  input  logic [$clog2(N)-1:0]  addr,
  output logic [EVENT_W-1:0]    data
);
  (* rom_style = "block" *) logic [EVENT_W-1:0] mem [0:N-1];
  initial $readmemh(MEM_FILE, mem);
  always_ff @(posedge clk) data <= mem[addr];
endmodule
```

`rtl/replay_ctrl.sv`:

```systemverilog
// replay_ctrl.sv -- walks trace_rom into the pipeline once per button press.
//
// The ROM read is registered, so the address runs one word AHEAD on an accept:
// the word for idx+1 is being read on the same edge idx is consumed, and it is
// on rom_data the cycle after. That is what makes the replay bubble-free under
// backpressure; addressing idx alone would present the consumed word twice.
//
// The button is asynchronous: two flops, a rising-edge detect, and a lockout
// of 2**LOCKOUT_W cycles (about 10 ms at 100 MHz with the default) so contact
// bounce cannot restart a replay that finishes in well under a millisecond.
module replay_ctrl
  import market_pkg::*;
#(
  parameter int N_TRACE   = 2000,
  parameter int LOCKOUT_W = 20
) (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        btn,        // asynchronous
  input  logic                        hold_off,   // e.g. config still loading
  output logic [$clog2(N_TRACE)-1:0]  rom_addr,
  input  logic [EVENT_W-1:0]          rom_data,
  output logic [EVENT_W-1:0]          s_data,
  output logic                        s_valid,
  input  logic                        s_ready,
  output logic                        busy,
  output logic                        start_pulse
);
  localparam int AW = $clog2(N_TRACE);

  (* ASYNC_REG = "TRUE" *) logic b1;
  (* ASYNC_REG = "TRUE" *) logic b2;
  logic                 b_prev;
  logic [LOCKOUT_W-1:0] lockout;
  logic [AW-1:0]        idx;
  logic                 primed;   // rom_data holds the word for idx

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b1 <= 1'b0; b2 <= 1'b0; b_prev <= 1'b0;
    end else begin
      b1 <= btn; b2 <= b1; b_prev <= b2;
    end
  end

  logic press, accept, last;
  assign press  = b2 && !b_prev && (lockout == '0) && !busy && !hold_off;
  assign accept = s_valid && s_ready;
  assign last   = (idx == AW'(N_TRACE - 1));

  assign rom_addr = (accept && !last) ? (idx + 1'b1) : idx;
  assign s_data   = rom_data;
  assign s_valid  = busy && primed;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; idx <= '0; primed <= 1'b0; start_pulse <= 1'b0;
      lockout <= '1;              // ignore anything bouncing out of reset
    end else begin
      start_pulse <= 1'b0;
      if (lockout != '0) lockout <= lockout - 1'b1;
      if (press) begin
        busy <= 1'b1; idx <= '0; primed <= 1'b0;
        lockout <= '1; start_pulse <= 1'b1;
      end else if (busy) begin
        if (!primed) begin
          primed <= 1'b1;
        end else if (accept) begin
          if (last) begin busy <= 1'b0; primed <= 1'b0; end
          else      idx <= idx + 1'b1;
        end
      end
    end
  end
endmodule
```

- [ ] **Step 5: Run the tests**

Run: `make lint && make lint-tb && make sim TOP=tb_replay_ctrl`
Expected: lint clean; `PASS: tb_replay_ctrl`.

- [ ] **Step 6: Add mutants** — append to `scripts/mutants.txt`:

```
== replay_ctrl ==
replay: address does not run ahead @@ rtl/replay_ctrl.sv @@ tb_replay_ctrl @@   assign rom_addr = (accept && !last) ? (idx + 1'b1) : idx; @@   assign rom_addr = idx;
replay: press accepted mid-replay @@ rtl/replay_ctrl.sv @@ tb_replay_ctrl @@ (lockout == '0) && !busy && !hold_off; @@ (lockout == '0) && !hold_off;
replay: lockout ignored @@ rtl/replay_ctrl.sv @@ tb_replay_ctrl @@ assign press  = b2 && !b_prev && (lockout == '0) && !busy && !hold_off; @@ assign press  = b2 && !b_prev && !busy && !hold_off;
replay: hold_off ignored @@ rtl/replay_ctrl.sv @@ tb_replay_ctrl @@ && !busy && !hold_off; @@ && !busy;
replay: last word dropped @@ rtl/replay_ctrl.sv @@ tb_replay_ctrl @@   assign last   = (idx == AW'(N_TRACE - 1)); @@   assign last   = (idx == AW'(N_TRACE - 2));
```

Run: `./scripts/mutate.sh replay:` — Expected: `killed 5, survived 0`.

- [ ] **Step 7: Commit**

```bash
git add rtl/trace_rom.sv rtl/replay_ctrl.sv tb/tb_replay_ctrl.sv tb/mem/tb_trace8.mem scripts/mutants.txt
git commit -m "feat(rtl): trace_rom and replay_ctrl, bubble-free ROM replay"
```

---

### Task 4: `cfg_loader`

**Files:**
- Create: `rtl/cfg_loader.sv`
- Test: `tb/tb_cfg_loader.sv`

**Interfaces:**
- Consumes: `CFG_ADDR_W`, `CFG_DATA_W`, `cfg_addr_e` from `market_pkg`; `config_regs` ports `(clk, rst_n, cfg_addr, cfg_wdata, cfg_we, policy_cfg, risk_cfg, commit_count)`; `rtl/mem/rom_cfg_{baseline,tuned}.mem` from Task 1.
- Produces: `module cfg_loader #(parameter string MEM_BASE = "rtl/mem/rom_cfg_baseline.mem", parameter string MEM_TUNED = "rtl/mem/rom_cfg_tuned.mem") (input clk, rst_n, sw_preset; output [CFG_ADDR_W-1:0] cfg_addr; output [CFG_DATA_W-1:0] cfg_wdata; output cfg_we, busy, preset)`.

- [ ] **Step 1: Write the failing test** — `tb/tb_cfg_loader.sv`:

```systemverilog
// Directed tests for cfg_loader driving config_regs.
//
// The ground truth is the committed .cfg file, read independently of the .mem
// image the loader uses: after a load, every active field must equal what
// writing that .cfg by hand would have produced.
module tb_cfg_loader;
  import market_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic sw_preset = 1'b0;
  logic [CFG_ADDR_W-1:0] cfg_addr;
  logic [CFG_DATA_W-1:0] cfg_wdata;
  logic cfg_we, busy, preset;
  policy_cfg_t policy_cfg;
  risk_cfg_t   risk_cfg;
  logic [CNT_W-1:0] commit_count;

  cfg_loader  u_load (.*);
  config_regs u_regs (.*);

  int errors = 0;
  task automatic check(string name, logic cond);
    if (!cond) begin errors++; $error("FAIL: %s", name); end
  endtask

  // Expected active config, built by applying the .cfg file's writes in a
  // software model of the shadow/commit semantics.
  policy_cfg_t exp_p;
  risk_cfg_t   exp_r;
  task automatic expect_from_cfg(string path);
    int fd, r, a, d;
    string line;
    exp_p = '0; exp_r = '0;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "FAIL: cannot open %s", path);
    while ($fgets(line, fd) != 0) begin
      if (line.len() == 0 || line[0] == "#") continue;
      if ($sscanf(line, "%h %h", a, d) != 2) continue;
      unique case (cfg_addr_e'(a))
        CFG_W0:            exp_p.w0          = W_W'(d);
        CFG_W_SPREAD:      exp_p.w_spread    = W_W'(d);
        CFG_W_IMBALANCE:   exp_p.w_imbalance = W_W'(d);
        CFG_W_MOMENTUM:    exp_p.w_momentum  = W_W'(d);
        CFG_THETA_BUY:     exp_p.theta_buy   = SCORE_W'(d);
        CFG_THETA_SELL:    exp_p.theta_sell  = SCORE_W'(d);
        CFG_ORDER_QTY:     exp_p.order_qty   = QTY_W'(d);
        CFG_MAX_LONG:      exp_r.max_long    = (POS_W-1)'(d);
        CFG_MAX_SHORT:     exp_r.max_short   = (POS_W-1)'(d);
        CFG_MAX_ORDER_QTY: exp_r.max_order_qty = QTY_W'(d);
        CFG_MAX_SPREAD:    exp_r.max_spread  = SPREAD_W'(d);
        CFG_KILL:          exp_r.kill        = d[0];
        default: ;
      endcase
    end
    $fclose(fd);
  endtask

  task automatic wait_loaded();
    int guard = 0;
    @(negedge clk);
    while (busy) begin @(negedge clk); guard++; if (guard > 200) $fatal(1, "FAIL: load hung"); end
    @(negedge clk);
  endtask

  initial begin
    repeat (3) @(posedge clk);
    check("reset config is killed", risk_cfg.kill === 1'b1);
    rst_n = 1'b1;

    // --- reset release loads the baseline preset ------------------------
    wait_loaded();
    expect_from_cfg("tb/configs/baseline.cfg");
    check("baseline policy loaded", policy_cfg === exp_p);
    check("baseline risk loaded",   risk_cfg === exp_r);
    check("one commit",             commit_count === 32'd1);
    check("preset reports baseline", preset === 1'b0);

    // --- flipping the switch loads tuned ---------------------------------
    sw_preset = 1'b1;
    repeat (4) @(negedge clk);
    check("switch change starts a load", busy === 1'b1 || commit_count === 32'd2);
    wait_loaded();
    expect_from_cfg("tb/configs/tuned.cfg");
    check("tuned policy loaded", policy_cfg === exp_p);
    check("tuned risk loaded",   risk_cfg === exp_r);
    check("second commit",       commit_count === 32'd2);
    check("preset reports tuned", preset === 1'b1);

    // --- no switch change, no reload -------------------------------------
    repeat (50) @(negedge clk);
    check("steady switch does not reload", commit_count === 32'd2);

    // --- and back -------------------------------------------------------
    sw_preset = 1'b0;
    repeat (4) @(negedge clk);
    wait_loaded();
    expect_from_cfg("tb/configs/baseline.cfg");
    check("back to baseline", policy_cfg === exp_p && risk_cfg === exp_r);
    check("third commit", commit_count === 32'd3);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_cfg_loader");
    $finish;
  end

  initial begin #200000; $fatal(1, "FAIL: timeout"); end
endmodule
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make sim TOP=tb_cfg_loader`
Expected: FAIL — `Module <cfg_loader> not found`.

- [ ] **Step 3: Implement** — `rtl/cfg_loader.sv`:

```systemverilog
// cfg_loader.sv -- writes a configuration preset into config_regs.
//
// Two ROM images, one per committed config, each the exact register-write
// sequence export_config.py emits, ending in CFG_COMMIT. On reset release and
// whenever the synchronized preset switch changes, the selected image is
// replayed one write per cycle. busy covers the final registered write, so a
// replay started after busy falls always sees the new configuration active.
module cfg_loader
  import market_pkg::*;
#(
  parameter string MEM_BASE  = "rtl/mem/rom_cfg_baseline.mem",
  parameter string MEM_TUNED = "rtl/mem/rom_cfg_tuned.mem"
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  sw_preset,   // asynchronous
  output logic [CFG_ADDR_W-1:0] cfg_addr,
  output logic [CFG_DATA_W-1:0] cfg_wdata,
  output logic                  cfg_we,
  output logic                  busy,
  output logic                  preset       // preset most recently selected
);
  localparam int N_CFG      = 13;            // == len(cfg_addr_e); pytest pins it
  localparam int CFG_WORD_W = 40;            // 2 hex digits addr, 8 hex digits data

  /* verilator lint_off UNUSEDSIGNAL */
  // The address byte is 8 bits in the image; only CFG_ADDR_W of them are used.
  logic [CFG_WORD_W-1:0] rom_base  [0:N_CFG-1];
  logic [CFG_WORD_W-1:0] rom_tuned [0:N_CFG-1];
  logic [CFG_WORD_W-1:0] word;
  /* verilator lint_on UNUSEDSIGNAL */
  initial begin
    $readmemh(MEM_BASE,  rom_base);
    $readmemh(MEM_TUNED, rom_tuned);
  end

  (* ASYNC_REG = "TRUE" *) logic s1;
  (* ASYNC_REG = "TRUE" *) logic s2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin s1 <= 1'b0; s2 <= 1'b0; end
    else        begin s1 <= sw_preset; s2 <= s1; end
  end

  logic                     loading, loaded;
  logic [$clog2(N_CFG)-1:0] idx;

  assign word = preset ? rom_tuned[idx] : rom_base[idx];
  assign busy = loading || cfg_we;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      loading <= 1'b0; loaded <= 1'b0; idx <= '0; preset <= 1'b0;
      cfg_we <= 1'b0; cfg_addr <= '0; cfg_wdata <= '0;
    end else begin
      cfg_we <= 1'b0;
      if (!loading) begin
        if (!loaded || (s2 != preset)) begin
          loading <= 1'b1; idx <= '0; preset <= s2;
        end
      end else begin
        cfg_we    <= 1'b1;
        cfg_addr  <= word[32 +: CFG_ADDR_W];
        cfg_wdata <= word[31:0];
        if (idx == ($clog2(N_CFG))'(N_CFG - 1)) begin
          loading <= 1'b0; loaded <= 1'b1;
        end else begin
          idx <= idx + 1'b1;
        end
      end
    end
  end
endmodule
```

Add to `scripts/test_mem_files.py`:

```python
def test_cfg_loader_word_count_matches_the_register_map():
    """cfg_loader.sv hardcodes N_CFG; it must equal the register count."""
    import re
    src = (REPO / "rtl" / "cfg_loader.sv").read_text()
    m = re.search(r"localparam int N_CFG\s*=\s*(\d+);", src)
    assert m and int(m.group(1)) == len(A)
```

- [ ] **Step 4: Run the tests**

Run: `make lint && make lint-tb && make sim TOP=tb_cfg_loader && .venv/bin/python -m pytest -q`
Expected: lint clean; `PASS: tb_cfg_loader`; pytest all pass.

- [ ] **Step 5: Add mutants** — append to `scripts/mutants.txt`:

```
== cfg_loader ==
cfgl: switch change does not reload @@ rtl/cfg_loader.sv @@ tb_cfg_loader @@ if (!loaded || (s2 != preset)) begin @@ if (!loaded) begin
cfgl: presets swapped @@ rtl/cfg_loader.sv @@ tb_cfg_loader @@ assign word = preset ? rom_tuned[idx] : rom_base[idx]; @@ assign word = preset ? rom_base[idx] : rom_tuned[idx];
cfgl: final write (the commit) skipped @@ rtl/cfg_loader.sv @@ tb_cfg_loader @@ if (idx == ($clog2(N_CFG))'(N_CFG - 1)) begin @@ if (idx == ($clog2(N_CFG))'(N_CFG - 2)) begin
cfgl: busy drops before the last write lands @@ rtl/cfg_loader.sv @@ tb_cfg_loader @@ assign busy = loading || cfg_we; @@ assign busy = loading;
```

Run: `./scripts/mutate.sh cfgl:` — Expected: `killed 4, survived 0`. If "busy drops before the last write lands" survives, add to `tb_cfg_loader` a check that samples `policy_cfg` on the first negedge where `busy` is low (no extra settle cycle) and requires the new values.

- [ ] **Step 6: Commit**

```bash
git add rtl/cfg_loader.sv tb/tb_cfg_loader.sv scripts/test_mem_files.py scripts/mutants.txt
git commit -m "feat(rtl): cfg_loader replays a committed preset into config_regs"
```

---

### Task 5: `seg7_display` and `market_pipeline_top`

**Files:**
- Create: `rtl/seg7_display.sv`, `rtl/market_pipeline_top.sv`
- Test: `tb/tb_seg7_display.sv`, `tb/tb_market_pipeline_top.sv`

**Interfaces:**
- Consumes: every stage's ports as instantiated in `tb/tb_policy_configs.sv`; `reset_sync`, `trace_rom`, `replay_ctrl`, `cfg_loader` from Tasks 2–4.
- Produces:
  - `module seg7_display #(parameter int REFRESH_W = 17) (input clk, rst_n; input [15:0] value; output [6:0] seg; output dp; output [3:0] an)` — active low, `seg = {g,f,e,d,c,b,a}`.
  - `module market_pipeline_top #(parameter int N_TRACE = 2000, parameter string TRACE_MEM = "rtl/mem/rom_trace.mem", parameter string CFG_MEM_BASE = "rtl/mem/rom_cfg_baseline.mem", parameter string CFG_MEM_TUNED = "rtl/mem/rom_cfg_tuned.mem", parameter int LOCKOUT_W = 20, parameter int REFRESH_W = 17) (input clk, btnU, btnC; input [15:0] sw; output [15:0] led; output [6:0] seg; output dp; output [3:0] an)`.
  - Instance names the top-level test relies on: `u_rst`, `u_rom`, `u_replay`, `u_cfgl`, `u_cfg`, `u_dec`, `u_seq`, `u_tob`, `u_feat`, `u_pol`, `u_risk`, `u_seg`; counters `buy_cnt`, `sell_cnt`, `rej_cnt`.

- [ ] **Step 1: Write the failing seg7 test** — `tb/tb_seg7_display.sv`:

```systemverilog
module tb_seg7_display;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic [15:0] value;
  logic [6:0] seg; logic dp; logic [3:0] an;
  seg7_display #(.REFRESH_W(4)) dut (.*);

  // {g,f,e,d,c,b,a}, active low -- the Basys 3 common-anode wiring.
  localparam logic [6:0] HEX [16] = '{
    7'b1000000, 7'b1111001, 7'b0100100, 7'b0110000,
    7'b0011001, 7'b0010010, 7'b0000010, 7'b1111000,
    7'b0000000, 7'b0010000, 7'b0001000, 7'b0000011,
    7'b1000110, 7'b0100001, 7'b0000110, 7'b0001110 };

  int errors = 0;
  initial begin
    repeat (2) @(posedge clk); rst_n = 1'b1;
    for (int v = 0; v < 16; v++) begin
      value = {4'(v), 4'(v), 4'(v), 4'(v)};
      // Visit every anode at least once.
      repeat (4 * 16) begin
        @(negedge clk);
        if (dp !== 1'b1) begin errors++; $error("FAIL: dp lit"); end
        if (!(an inside {4'b1110, 4'b1101, 4'b1011, 4'b0111})) begin
          errors++; $error("FAIL: not exactly one anode low: %b", an);
        end
        if (seg !== HEX[v]) begin
          errors++; $error("FAIL: digit %0h shows %b, want %b", v, seg, HEX[v]);
        end
      end
    end
    // Digits land on the right anodes.
    value = 16'h1234;
    repeat (4 * 16) begin
      @(negedge clk);
      case (an)
        4'b1110: if (seg !== HEX[4]) begin errors++; $error("FAIL: an0"); end
        4'b1101: if (seg !== HEX[3]) begin errors++; $error("FAIL: an1"); end
        4'b1011: if (seg !== HEX[2]) begin errors++; $error("FAIL: an2"); end
        4'b0111: if (seg !== HEX[1]) begin errors++; $error("FAIL: an3"); end
        default: ;
      endcase
    end
    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_seg7_display");
    $finish;
  end
endmodule
```

- [ ] **Step 2: Implement** — `rtl/seg7_display.sv`:

```systemverilog
// seg7_display.sv -- four-digit multiplexed hex display for the Basys 3.
// Segments and anodes are active low; seg = {g,f,e,d,c,b,a}.
module seg7_display #(
  parameter int REFRESH_W = 17   // 2**17 cycles at 100 MHz ~ 1.3 ms per digit
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] value,
  output logic [6:0]  seg,
  output logic        dp,
  output logic [3:0]  an
);
  logic [REFRESH_W-1:0] ctr;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ctr <= '0; else ctr <= ctr + 1'b1;

  logic [1:0] digit;
  logic [3:0] nib;
  assign digit = ctr[REFRESH_W-1 -: 2];
  assign dp    = 1'b1;

  always_comb begin
    unique case (digit)
      2'd0: begin an = 4'b1110; nib = value[3:0];   end
      2'd1: begin an = 4'b1101; nib = value[7:4];   end
      2'd2: begin an = 4'b1011; nib = value[11:8];  end
      default: begin an = 4'b0111; nib = value[15:12]; end
    endcase
    unique case (nib)
      4'h0: seg = 7'b1000000;  4'h1: seg = 7'b1111001;
      4'h2: seg = 7'b0100100;  4'h3: seg = 7'b0110000;
      4'h4: seg = 7'b0011001;  4'h5: seg = 7'b0010010;
      4'h6: seg = 7'b0000010;  4'h7: seg = 7'b1111000;
      4'h8: seg = 7'b0000000;  4'h9: seg = 7'b0010000;
      4'hA: seg = 7'b0001000;  4'hB: seg = 7'b0000011;
      4'hC: seg = 7'b1000110;  4'hD: seg = 7'b0100001;
      4'hE: seg = 7'b0000110;  default: seg = 7'b0001110;
    endcase
  end
endmodule
```

Run: `make lint && make lint-tb && make sim TOP=tb_seg7_display` — Expected: `PASS: tb_seg7_display`.

- [ ] **Step 3: Write the failing top-level test** — `tb/tb_market_pipeline_top.sv`.

The oracle is the already-verified chain, not a new model: the testbench instantiates a reference copy of the seven modules, feeds it the same `.mem` trace directly, loads it from the committed `.cfg` files, and requires the top's decision stream to match event for event.

```systemverilog
// tb_market_pipeline_top.sv -- the real top, checked against the verified chain.
//
// A reference copy of decode..risk_gate + config_regs is fed the same ROM image
// directly and configured from the committed .cfg file. The top must produce
// the same decision, reason and position for every event, in both presets and
// across a second replay that starts with a populated book and a non-zero
// position. Latency inside the top, decoder accept to risk handoff, must be
// LATENCY_CYCLES for every event.
module tb_market_pipeline_top;
  import market_pkg::*;
  localparam int N = 2000;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic btnU = 1'b1, btnC = 1'b0;
  logic [15:0] sw = '0;
  logic [15:0] led;
  logic [6:0]  seg; logic dp; logic [3:0] an;

  market_pipeline_top #(.N_TRACE(N), .LOCKOUT_W(4), .REFRESH_W(4)) dut (.*);

  // ---------------- reference chain ----------------
  logic rrst_n = 1'b0;
  logic [EVENT_W-1:0] r_sdata; logic r_svalid, r_sready;
  market_event_t d_ev, q_ev, b_ev, f_ev, p_ev, m_ev;
  event_err_t    d_er, q_er, b_er, f_er, p_er, m_er;
  logic d_v, d_r, q_v, q_r, b_v, b_r, f_v, f_r, p_v, p_r, m_v;
  book_t b_bk; logic b_st; feature_t f_ft, p_ft, m_ft;
  decision_e p_dec; logic signed [SCORE_W-1:0] p_sc; logic [QTY_W-1:0] p_oq;
  risk_cfg_t p_rc; decision_t m_dec;
  logic [CNT_W-1:0] c0, c1, c2, c3, c4, ccnt;
  logic [CFG_ADDR_W-1:0] ca; logic [CFG_DATA_W-1:0] cd; logic cwe = 1'b0;
  policy_cfg_t pcfg; risk_cfg_t rcfg;

  event_decoder    r_dec (.clk(clk), .rst_n(rrst_n), .s_data(r_sdata), .s_valid(r_svalid), .s_ready(r_sready),
                          .m_event(d_ev), .m_err(d_er), .m_valid(d_v), .m_ready(d_r));
  sequence_checker r_seq (.clk(clk), .rst_n(rrst_n), .s_event(d_ev), .s_err(d_er), .s_valid(d_v), .s_ready(d_r),
                          .m_event(q_ev), .m_err(q_er), .m_valid(q_v), .m_ready(q_r),
                          .gap_count(c0), .stale_count(c1), .missed_total(c2), .bad_event_count(c3), .resync_count(c4));
  top_of_book      r_tob (.clk(clk), .rst_n(rrst_n), .s_event(q_ev), .s_err(q_er), .s_valid(q_v), .s_ready(q_r),
                          .m_event(b_ev), .m_err(b_er), .m_book(b_bk), .m_book_stale(b_st), .m_valid(b_v), .m_ready(b_r));
  feature_engine   r_feat(.clk(clk), .rst_n(rrst_n), .s_event(b_ev), .s_err(b_er), .s_book(b_bk), .s_book_stale(b_st),
                          .s_valid(b_v), .s_ready(b_r), .m_event(f_ev), .m_err(f_er), .m_feat(f_ft), .m_valid(f_v), .m_ready(f_r));
  policy_engine    r_pol (.clk(clk), .rst_n(rrst_n), .cfg(pcfg), .risk_cfg_in(rcfg),
                          .s_event(f_ev), .s_err(f_er), .s_feat(f_ft), .s_valid(f_v), .s_ready(f_r),
                          .m_event(p_ev), .m_err(p_er), .m_feat(p_ft), .m_decision(p_dec), .m_score(p_sc),
                          .m_order_qty(p_oq), .m_risk_cfg(p_rc), .m_valid(p_v), .m_ready(p_r));
  risk_gate        r_risk(.clk(clk), .rst_n(rrst_n), .cfg(p_rc), .s_event(p_ev), .s_err(p_er), .s_feat(p_ft),
                          .s_decision(p_dec), .s_score(p_sc), .s_order_qty(p_oq), .s_valid(p_v), .s_ready(p_r),
                          .m_event(m_ev), .m_err(m_er), .m_feat(m_ft), .m_decision(m_dec), .m_valid(m_v), .m_ready(1'b1));
  config_regs      r_cfg (.clk(clk), .rst_n(rrst_n), .cfg_addr(ca), .cfg_wdata(cd), .cfg_we(cwe),
                          .policy_cfg(pcfg), .risk_cfg(rcfg), .commit_count(ccnt));

  logic [EVENT_W-1:0] trace [0:N-1];
  initial $readmemh("rtl/mem/rom_trace.mem", trace);

  task automatic ref_load(string path);
    int fd, a, d; string line;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "FAIL: cannot open %s", path);
    while ($fgets(line, fd) != 0) begin
      if (line.len() == 0 || line[0] == "#") continue;
      if ($sscanf(line, "%h %h", a, d) != 2) continue;
      @(negedge clk); ca = CFG_ADDR_W'(a); cd = CFG_DATA_W'(d); cwe = 1'b1;
      @(negedge clk); cwe = 1'b0;
    end
    $fclose(fd);
  endtask

  task automatic ref_replay();
    for (int i = 0; i < N; i++) begin
      @(negedge clk); while (!r_sready) @(negedge clk);
      r_sdata = trace[i]; r_svalid = 1'b1;
      @(negedge clk); r_svalid = 1'b0;
    end
  endtask

  // ---------------- recorders ----------------
  localparam int CAP = 2 * N;
  decision_t top_d [0:CAP-1];
  decision_t ref_d [0:CAP-1];
  int n_top = 0, n_ref = 0;
  always @(posedge clk) begin
    if (dut.u_risk.m_valid && dut.u_risk.m_ready && n_top < CAP) begin
      top_d[n_top] = dut.u_risk.m_decision; n_top++;
    end
    if (rrst_n && m_v && n_ref < CAP) begin
      ref_d[n_ref] = m_dec; n_ref++;
    end
  end

  // Latency inside the top: decoder accept to risk handoff, FIFO by order.
  int cyc = 0, lat_bad = 0, lat_n = 0;
  int ing [$];
  always @(posedge clk) begin
    cyc++;
    if (dut.u_dec.s_valid && dut.u_dec.s_ready) ing.push_back(cyc);
    if (dut.u_risk.m_valid && dut.u_risk.m_ready && ing.size() > 0) begin
      int t0 = ing.pop_front();
      lat_n++;
      if (cyc - t0 != LATENCY_CYCLES) lat_bad++;
    end
  end

  int errors = 0;
  task automatic check(string name, logic cond);
    if (!cond) begin errors++; $error("FAIL: %s", name); end
  endtask

  task automatic top_press();
    @(negedge clk); btnC = 1'b1;
    repeat (6) @(negedge clk); btnC = 1'b0;
  endtask

  task automatic top_wait_idle();
    int guard = 0;
    repeat (8) @(negedge clk);
    while (dut.u_replay.busy || dut.u_cfgl.busy) begin
      @(negedge clk); guard++;
      if (guard > 50 * N) $fatal(1, "FAIL: top never went idle");
    end
    repeat (LATENCY_CYCLES + 8) @(negedge clk);
  endtask

  task automatic compare_run(int from, int upto, string tag);
    int buys = 0, sells = 0, rej = 0;
    for (int i = from; i < upto; i++) begin
      if (top_d[i] !== ref_d[i]) begin
        errors++;
        if (errors < 6) $error("FAIL: %s event %0d top=%p ref=%p", tag, i - from, top_d[i], ref_d[i]);
      end
      if (ref_d[i].decision == DEC_BUY)  buys++;
      if (ref_d[i].decision == DEC_SELL) sells++;
      if (ref_d[i].reason != RSN_NONE)   rej++;
    end
    check({tag, " BUY counter"},    dut.buy_cnt  === 16'(buys));
    check({tag, " SELL counter"},   dut.sell_cnt === 16'(sells));
    check({tag, " reject counter"}, dut.rej_cnt  === 16'(rej));
    check({tag, " LEDs show the counters"}, led === {sells[7:0], buys[7:0]});
    $display("INFO: %s buy=%0d sell=%0d rejected=%0d", tag, buys, sells, rej);
    check({tag, " policy actually traded"}, buys + sells > 0);
  endtask

  initial begin
    r_svalid = 1'b0; r_sdata = '0;
    // Reset both, release together.
    repeat (4) @(negedge clk);
    btnU = 1'b0; rrst_n = 1'b1;

    // Before the loader commits, the top must be killed and idle.
    @(negedge clk);
    check("top config is killed straight out of reset", dut.u_cfg.risk_cfg.kill === 1'b1);

    // ---- run 1: baseline ------------------------------------------------
    top_wait_idle();
    check("loader committed once", dut.u_cfg.commit_count === 32'd1);
    check("loader cleared the kill switch", dut.u_cfg.risk_cfg.kill === 1'b0);
    ref_load("tb/configs/baseline.cfg");
    fork top_press(); ref_replay(); join
    top_wait_idle();
    check("run 1 top produced N decisions", n_top == N);
    check("run 1 ref produced N decisions", n_ref == N);
    compare_run(0, N, "baseline");

    // ---- run 2: tuned, same trace, book and position carried over -------
    sw[0] = 1'b1;
    top_wait_idle();
    check("switch change committed again", dut.u_cfg.commit_count === 32'd2);
    ref_load("tb/configs/tuned.cfg");
    fork top_press(); ref_replay(); join
    top_wait_idle();
    check("run 2 top produced N more decisions", n_top == 2 * N);
    compare_run(N, 2 * N, "tuned");

    check("latency measured for every event", lat_n == 2 * N);
    check("latency is LATENCY_CYCLES for every event", lat_bad == 0);
    $display("INFO: top latency %0d events, %0d not at %0d cycles", lat_n, lat_bad, LATENCY_CYCLES);

    if (errors != 0) $fatal(1, "FAIL: %0d checks failed", errors);
    $display("PASS: tb_market_pipeline_top -- %0d decisions matched the reference chain, latency %0d cycles",
             2 * N, LATENCY_CYCLES);
    $finish;
  end

  initial begin #200000000; $fatal(1, "FAIL: timeout"); end
endmodule
```

- [ ] **Step 4: Run it to verify it fails**

Run: `make sim TOP=tb_market_pipeline_top`
Expected: FAIL — `Module <market_pipeline_top> not found`.

- [ ] **Step 5: Implement** — `rtl/market_pipeline_top.sv`:

```systemverilog
// market_pipeline_top.sv -- the synthesizable Basys 3 top.
//
// Stimulus is on-chip: trace_rom holds a generated trace and replay_ctrl walks
// it into the pipeline on a button press. Configuration is on-chip too:
// cfg_loader replays a committed preset into config_regs on reset release and
// whenever sw[0] changes. Decisions leave only as counters on the LEDs and the
// 7-seg. No data crosses a pin on a clock edge -- which is why the XDC
// false-paths every I/O instead of stating input and output delays.
module market_pipeline_top
  import market_pkg::*;
#(
  parameter int    N_TRACE       = 2000,
  parameter string TRACE_MEM     = "rtl/mem/rom_trace.mem",
  parameter string CFG_MEM_BASE  = "rtl/mem/rom_cfg_baseline.mem",
  parameter string CFG_MEM_TUNED = "rtl/mem/rom_cfg_tuned.mem",
  parameter int    LOCKOUT_W     = 20,
  parameter int    REFRESH_W     = 17
) (
  input  logic        clk,
  input  logic        btnU,     // reset
  input  logic        btnC,     // start replay
  input  logic [15:0] sw,       // sw[0]: 0 baseline, 1 tuned
  output logic [15:0] led,      // {SELL count, BUY count}, low bytes
  output logic [6:0]  seg,
  output logic        dp,
  output logic [3:0]  an
);
  logic rst_n;
  reset_sync u_rst (.clk(clk), .arst_in(btnU), .rst_n(rst_n));

  // ---- stimulus --------------------------------------------------------
  logic [$clog2(N_TRACE)-1:0] rom_addr;
  logic [EVENT_W-1:0] rom_data, s_data;
  logic s_valid, s_ready, replay_busy, start_pulse;

  trace_rom #(.N(N_TRACE), .MEM_FILE(TRACE_MEM))
    u_rom (.clk(clk), .addr(rom_addr), .data(rom_data));

  logic [CFG_ADDR_W-1:0] cfg_addr;
  logic [CFG_DATA_W-1:0] cfg_wdata;
  logic cfg_we, cfg_busy, preset;

  cfg_loader #(.MEM_BASE(CFG_MEM_BASE), .MEM_TUNED(CFG_MEM_TUNED))
    u_cfgl (.clk(clk), .rst_n(rst_n), .sw_preset(sw[0]),
            .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_we(cfg_we),
            .busy(cfg_busy), .preset(preset));

  replay_ctrl #(.N_TRACE(N_TRACE), .LOCKOUT_W(LOCKOUT_W))
    u_replay (.clk(clk), .rst_n(rst_n), .btn(btnC), .hold_off(cfg_busy),
              .rom_addr(rom_addr), .rom_data(rom_data),
              .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
              .busy(replay_busy), .start_pulse(start_pulse));

  // ---- pipeline --------------------------------------------------------
  market_event_t d_event, q_event, b_event, f_event, p_event, r_event;
  event_err_t    d_err, q_err, b_err, f_err, p_err, r_err;
  logic d_valid, d_ready, q_valid, q_ready, b_valid, b_ready;
  logic f_valid, f_ready, p_valid, p_ready, r_valid;
  book_t    b_book;
  logic     b_book_stale;
  feature_t f_feat, p_feat, r_feat;
  decision_e p_decision;
  logic signed [SCORE_W-1:0] p_score;
  logic [QTY_W-1:0]          p_order_qty;
  risk_cfg_t p_risk_cfg;
  decision_t r_decision;
  policy_cfg_t policy_cfg;
  risk_cfg_t   risk_cfg;

  /* verilator lint_off UNUSEDSIGNAL */
  // Telemetry the Basys 3 has nowhere to show. Kept connected so a future
  // readout does not change the pipeline's netlist.
  logic [CNT_W-1:0] gap_count, stale_count, missed_total, bad_event_count,
                    resync_count, commit_count;
  logic [14:0] sw_spare;
  assign sw_spare = sw[15:1];
  /* verilator lint_on UNUSEDSIGNAL */

  event_decoder u_dec (
    .clk(clk), .rst_n(rst_n),
    .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
    .m_event(d_event), .m_err(d_err), .m_valid(d_valid), .m_ready(d_ready));

  sequence_checker u_seq (
    .clk(clk), .rst_n(rst_n),
    .s_event(d_event), .s_err(d_err), .s_valid(d_valid), .s_ready(d_ready),
    .m_event(q_event), .m_err(q_err), .m_valid(q_valid), .m_ready(q_ready),
    .gap_count(gap_count), .stale_count(stale_count),
    .missed_total(missed_total), .bad_event_count(bad_event_count),
    .resync_count(resync_count));

  top_of_book u_tob (
    .clk(clk), .rst_n(rst_n),
    .s_event(q_event), .s_err(q_err), .s_valid(q_valid), .s_ready(q_ready),
    .m_event(b_event), .m_err(b_err), .m_book(b_book),
    .m_book_stale(b_book_stale), .m_valid(b_valid), .m_ready(b_ready));

  feature_engine u_feat (
    .clk(clk), .rst_n(rst_n),
    .s_event(b_event), .s_err(b_err), .s_book(b_book),
    .s_book_stale(b_book_stale), .s_valid(b_valid), .s_ready(b_ready),
    .m_event(f_event), .m_err(f_err), .m_feat(f_feat),
    .m_valid(f_valid), .m_ready(f_ready));

  policy_engine u_pol (
    .clk(clk), .rst_n(rst_n), .cfg(policy_cfg), .risk_cfg_in(risk_cfg),
    .s_event(f_event), .s_err(f_err), .s_feat(f_feat),
    .s_valid(f_valid), .s_ready(f_ready),
    .m_event(p_event), .m_err(p_err), .m_feat(p_feat),
    .m_decision(p_decision), .m_score(p_score), .m_order_qty(p_order_qty),
    .m_risk_cfg(p_risk_cfg), .m_valid(p_valid), .m_ready(p_ready));

  /* verilator lint_off UNUSEDSIGNAL */
  market_event_t r_event_unused;
  event_err_t    r_err_unused;
  feature_t      r_feat_unused;
  assign r_event_unused = r_event;
  assign r_err_unused   = r_err;
  assign r_feat_unused  = r_feat;
  /* verilator lint_on UNUSEDSIGNAL */

  risk_gate u_risk (
    .clk(clk), .rst_n(rst_n), .cfg(p_risk_cfg),
    .s_event(p_event), .s_err(p_err), .s_feat(p_feat),
    .s_decision(p_decision), .s_score(p_score), .s_order_qty(p_order_qty),
    .s_valid(p_valid), .s_ready(p_ready),
    .m_event(r_event), .m_err(r_err), .m_feat(r_feat),
    .m_decision(r_decision), .m_valid(r_valid), .m_ready(1'b1));

  config_regs u_cfg (
    .clk(clk), .rst_n(rst_n),
    .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_we(cfg_we),
    .policy_cfg(policy_cfg), .risk_cfg(risk_cfg), .commit_count(commit_count));

  // ---- readout ---------------------------------------------------------
  logic [15:0] buy_cnt, sell_cnt, rej_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      buy_cnt <= '0; sell_cnt <= '0; rej_cnt <= '0;
    end else if (start_pulse) begin
      buy_cnt <= '0; sell_cnt <= '0; rej_cnt <= '0;
    end else if (r_valid) begin
      if (r_decision.decision == DEC_BUY)  buy_cnt  <= buy_cnt  + 1'b1;
      if (r_decision.decision == DEC_SELL) sell_cnt <= sell_cnt + 1'b1;
      if (r_decision.reason != RSN_NONE)   rej_cnt  <= rej_cnt  + 1'b1;
    end
  end

  assign led = {sell_cnt[7:0], buy_cnt[7:0]};

  seg7_display #(.REFRESH_W(REFRESH_W))
    u_seg (.clk(clk), .rst_n(rst_n), .value(rej_cnt), .seg(seg), .dp(dp), .an(an));

  /* verilator lint_off UNUSEDSIGNAL */
  logic status_unused;
  assign status_unused = replay_busy ^ preset;
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
```

- [ ] **Step 6: Run the tests**

Run: `make lint && make lint-tb && make sim TOP=tb_market_pipeline_top`
Expected: lint clean; `PASS: tb_market_pipeline_top -- 4000 decisions matched the reference chain, latency 8 cycles`.

If Verilator's `make lint` rejects `$readmemh` paths or `parameter string`, fix the lint invocation rather than the RTL, and record why in the Makefile comment.

- [ ] **Step 7: Add mutants** — append to `scripts/mutants.txt`:

```
== seg7_display ==
seg7: digit 3 decodes as 8 @@ rtl/seg7_display.sv @@ tb_seg7_display @@ 4'h3: seg = 7'b0110000; @@ 4'h3: seg = 7'b0000000;
seg7: anodes 0 and 1 swapped @@ rtl/seg7_display.sv @@ tb_seg7_display @@ 2'd0: begin an = 4'b1110; nib = value[3:0];   end @@ 2'd0: begin an = 4'b1101; nib = value[3:0];   end

== market_pipeline_top ==
top: BUY and SELL counters swapped @@ rtl/market_pipeline_top.sv @@ tb_market_pipeline_top @@ if (r_decision.decision == DEC_BUY)  buy_cnt  <= buy_cnt  + 1'b1; @@ if (r_decision.decision == DEC_SELL) buy_cnt  <= buy_cnt  + 1'b1;
top: replay not held off while config loads @@ rtl/market_pipeline_top.sv @@ tb_market_pipeline_top @@ .btn(btnC), .hold_off(cfg_busy), @@ .btn(btnC), .hold_off(1'b0),
top: policy fed the live risk config @@ rtl/market_pipeline_top.sv @@ tb_market_pipeline_top @@ .clk(clk), .rst_n(rst_n), .cfg(p_risk_cfg), @@ .clk(clk), .rst_n(rst_n), .cfg(risk_cfg),
top: preset switch not wired @@ rtl/market_pipeline_top.sv @@ tb_market_pipeline_top @@ .sw_preset(sw[0]), @@ .sw_preset(1'b0),
```

Run: `./scripts/mutate.sh seg7:` and `./scripts/mutate.sh top:` — Expected: all killed. A survivor means the test needs a vector; add it before continuing, as the snapshot work on PR #8 did.

- [ ] **Step 8: Full regression**

Run: `make sim-all && ./scripts/mutate.sh && .venv/bin/python -m pytest -q`
Expected: every testbench passes, the baseline gate passes, 0 survivors, pytest green.

- [ ] **Step 9: Commit**

```bash
git add rtl/seg7_display.sv rtl/market_pipeline_top.sv tb/tb_seg7_display.sv tb/tb_market_pipeline_top.sv scripts/mutants.txt
git commit -m "feat(rtl): market_pipeline_top, checked event-for-event against the verified chain"
```

- [ ] **Step 10: Verification engineer hand-off**

Dispatch `rtl-verification-engineer` on the five new modules and their testbenches (CLAUDE.md workflow 1). Apply its test additions; report any RTL defect it finds before fixing it.

---

### Task 6: Full XDC and the 100 MHz build

**Files:**
- Rewrite: `constraints/target_board.xdc`
- Modify: `scripts/build.tcl`, `Makefile`

**Interfaces:**
- Consumes: `market_pipeline_top` ports from Task 5.
- Produces: `make build PERIOD=<ns> RUN=<name>` publishing to `results/<RUN>/` only when the gate passes; default `PERIOD=10.000 RUN=100mhz`. `results/<RUN>/BUILD_SCOPE.md`.

- [ ] **Step 1: Rewrite the XDC** — `constraints/target_board.xdc`:

```tcl
## Digilent Basys 3 (xc7a35tcpg236-1)
##
## Pins and IOSTANDARDs are from Digilent's Basys-3-Master.xdc
## (github.com/Digilent/digilent-xdc), which is labelled Rev B. Verify against
## the master file for your board revision before trusting a bitstream on
## hardware. No bitstream from this repository has been run on a board.

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## ---- clock ------------------------------------------------------------
## 100 MHz oscillator on W5, no MMCM: 10.000 ns is the only period this
## design can run at. build.tcl overrides the period for the Fmax sweep and
## records every run; nothing faster than 10.000 ns is usable on this board.
set_property -dict {PACKAGE_PIN W5 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

## ---- asynchronous inputs ------------------------------------------------
## Buttons and switches are asynchronous to sys_clk by nature and every one
## lands in a two-flop synchronizer (reset_sync, replay_ctrl, cfg_loader).
## There is no setup relationship to the clock to constrain, so the paths
## from these ports are false paths. They are NOT given set_input_delay: no
## external device drives them on a clock edge, and a delay value would
## describe hardware that does not exist.
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports btnU]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports btnC]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN W17 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} [get_ports {sw[4]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {sw[5]}]
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {sw[6]}]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {sw[7]}]
set_property -dict {PACKAGE_PIN V2  IOSTANDARD LVCMOS33} [get_ports {sw[8]}]
set_property -dict {PACKAGE_PIN T3  IOSTANDARD LVCMOS33} [get_ports {sw[9]}]
set_property -dict {PACKAGE_PIN T2  IOSTANDARD LVCMOS33} [get_ports {sw[10]}]
set_property -dict {PACKAGE_PIN R3  IOSTANDARD LVCMOS33} [get_ports {sw[11]}]
set_property -dict {PACKAGE_PIN W2  IOSTANDARD LVCMOS33} [get_ports {sw[12]}]
set_property -dict {PACKAGE_PIN U1  IOSTANDARD LVCMOS33} [get_ports {sw[13]}]
set_property -dict {PACKAGE_PIN T1  IOSTANDARD LVCMOS33} [get_ports {sw[14]}]
set_property -dict {PACKAGE_PIN R2  IOSTANDARD LVCMOS33} [get_ports {sw[15]}]
set_false_path -from [get_ports {btnU btnC sw[*]}]

## ---- human-scale outputs --------------------------------------------------
## LEDs and the 7-seg are read by a person. Nothing samples them on a clock
## edge, so the paths to these ports are false paths, not set_output_delay.
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN V3  IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN W3  IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN U3  IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN P3  IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN N3  IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN P1  IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN L1  IOSTANDARD LVCMOS33} [get_ports {led[15]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports {seg[0]}]
set_property -dict {PACKAGE_PIN W6 IOSTANDARD LVCMOS33} [get_ports {seg[1]}]
set_property -dict {PACKAGE_PIN U8 IOSTANDARD LVCMOS33} [get_ports {seg[2]}]
set_property -dict {PACKAGE_PIN V8 IOSTANDARD LVCMOS33} [get_ports {seg[3]}]
set_property -dict {PACKAGE_PIN U5 IOSTANDARD LVCMOS33} [get_ports {seg[4]}]
set_property -dict {PACKAGE_PIN V5 IOSTANDARD LVCMOS33} [get_ports {seg[5]}]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports {seg[6]}]
set_property -dict {PACKAGE_PIN V7 IOSTANDARD LVCMOS33} [get_ports dp]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports {an[0]}]
set_property -dict {PACKAGE_PIN U4 IOSTANDARD LVCMOS33} [get_ports {an[1]}]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports {an[2]}]
set_property -dict {PACKAGE_PIN W4 IOSTANDARD LVCMOS33} [get_ports {an[3]}]
set_false_path -to [get_ports {led[*] seg[*] an[*] dp}]

## ---- what is and is not timed -----------------------------------------------
## Every synchronous path inside the design is timed against sys_clk. The
## synchronized reset's release is timed as recovery/removal by Vivado's
## standard analysis. Clock uncertainty is left at Vivado's default modelling;
## docs/TIMING_CLOSURE.md states that as an assumption and how much slack it
## would consume, rather than a jitter figure that has not been measured.
```

- [ ] **Step 2: Add the period and run-name arguments to `scripts/build.tcl`**

Replace the `TOP` line and the `outdir/bitdir/rptdir` block:

```tcl
set TOP    [expr {[llength $argv] > 0 ? [lindex $argv 0] : "market_pipeline_top"}]
set PERIOD [expr {[llength $argv] > 1 ? double([lindex $argv 1]) : 10.000}]
set RUN    [expr {[llength $argv] > 2 ? [lindex $argv 2] : "100mhz"}]

set root [file normalize [file dirname [info script]]/..]
cd $root

set outdir [file join $root results $RUN]
set bitdir [file join $root build $RUN]
set rptdir [file join $bitdir reports]
file mkdir $outdir
file mkdir $bitdir
file mkdir $rptdir
```

After `read_xdc $xdc`, add:

```tcl
# The ROM images the RTL initialises from. Registered with the tool so a
# missing or moved .mem is an error at synthesis, not a silently empty ROM.
set mems [lsort [glob -nocomplain [file join $root rtl mem *.mem]]]
if {[llength $mems] == 0} {
    puts "ERROR: no .mem files in rtl/mem -- the trace and config ROMs would be empty."
    exit 1
}
read_mem $mems
```

Immediately after `synth_design ...`, before the post-synth reports:

```tcl
# Fmax sweep: override the board period. The XDC keeps 10.000 ns, the only
# period the Basys 3 can run at; this redefinition exists only to measure how
# far the fabric could go, and every result from it says so.
if {abs($PERIOD - 10.000) > 0.0005} {
    create_clock -name sys_clk -period $PERIOD \
        -waveform [list 0.000 [expr {$PERIOD / 2.0}]] [get_ports clk]
}
```

Replace the period check in the clock-bind guard:

```tcl
if {abs($clk_period - $PERIOD) > 0.001} {
    puts "ERROR: clock period is ${clk_period} ns, requested ${PERIOD} ns."
    exit 1
}
```

In the `BUILD_SCOPE.md` block, replace the scope paragraph with:

```tcl
puts $fh "**Every synchronous path in the design is timed against one clock.**"
puts $fh "All top-level I/O is asynchronous or human-scale and is set_false_path, with"
puts $fh "the reason written in constraints/target_board.xdc. No data crosses a pin on a"
puts $fh "clock edge, so there is no I/O timing to close. See"
puts $fh "post_route_check_timing.rpt for the generated endpoint list."
puts $fh ""
if {abs($PERIOD - 10.000) > 0.0005} {
    puts $fh "**This is an Fmax-sweep run at ${PERIOD} ns.** The Basys 3 oscillator is fixed at"
    puts $fh "100 MHz with no MMCM; this period is not usable on the board."
} else {
    puts $fh "Latency in nanoseconds is LATENCY_CYCLES * 10.000 ns at the board's fixed 100 MHz."
}
```

And make the bitstream name run-specific: `write_bitstream -force [file join $bitdir ${TOP}.bit]` already uses `$bitdir`, which is now per run.

- [ ] **Step 3: Makefile**

Replace the `build` target:

```makefile
PERIOD ?= 10.000
RUN    ?= 100mhz
build:
	$(VIVADO) -mode batch -notrace -source scripts/build.tcl -tclargs $(SYNTH_TOP) $(PERIOD) $(RUN)
```

- [ ] **Step 4: Run the 100 MHz build**

Run: `make build 2>&1 | tee build/build_100mhz.txt | grep -E "== |ERROR|CRITICAL WARNING" `
Expected: `== clock sys_clk bound at 10.000 ns ==`, a `WNS ... / WHS ...` line with both non-negative, `DRC violations 0`, `published ... reports to results/`. No UCIO-1 or NSTD-1 DRC.

If DRC reports UCIO-1 or NSTD-1, a port is unpinned: fix the XDC, never downgrade the check. If `CRITICAL WARNING` mentions `get_ports` matching nothing, a port name in the XDC does not match the top.

- [ ] **Step 5: Commit the constraints, flow and 100 MHz results**

Before committing, dispatch `rtl-skeptic-reviewer` on the XDC, `build.tcl` and `results/100mhz/` (CLAUDE.md workflow 2). Fix BLOCKER/MAJOR.

```bash
git add constraints/target_board.xdc scripts/build.tcl Makefile results/100mhz/
git commit -m "feat(timing): full Basys 3 constraints and the 100 MHz post-route build"
```

---

### Task 7: Fmax sweep

**Files:**
- Create: `scripts/fmax_sweep.sh`
- Modify: `Makefile` (add `fmax`)
- Create (by running): `results/sweep/summary.csv`, `results/sweep/FMAX.md`, `results/sweep/p<period>/`

**Interfaces:**
- Consumes: `make build PERIOD= RUN=` from Task 6.
- Produces: `results/sweep/FMAX.md` containing exactly one line `measured_fmax_mhz=<value> period_ns=<value>`; `results/sweep/summary.csv` with header `period_ns,result,wns_ns,whs_ns`.

- [ ] **Step 1: Write the sweep** — `scripts/fmax_sweep.sh`:

```bash
#!/usr/bin/env bash
# fmax_sweep.sh -- measure the fastest clock period that closes timing.
#
# Coarse steps of 1.0 ns down from 10.000 until a run fails the build gate,
# then bisection to 0.1 ns between the last pass and the first fail. Every run
# is recorded in results/sweep/summary.csv, passing or not, and each passing
# run's reports are published under results/sweep/p<period>/ by build.tcl.
#
# One implementation run per period, default directives. Timing closure is not
# strictly monotonic in the period -- placement varies -- so the bisection
# assumes it and the CSV is the evidence if it is not.
#
# The result is a fabric ceiling for this design on xc7a35tcpg236-1. The Basys
# 3 has a fixed 100 MHz oscillator and no MMCM here; anything faster is not
# usable on the board.
set -uo pipefail
cd "$(dirname "$0")/.."
# SWEEP names the result set, so a later iteration can sweep again without
# overwriting the baseline:  SWEEP=sweep_iter1 make fmax
SWEEP="${SWEEP:-sweep}"
mkdir -p "results/$SWEEP" build
SUMMARY="results/$SWEEP/summary.csv"
echo "period_ns,result,wns_ns,whs_ns" > "$SUMMARY"

run() {
  local p="$1" log="build/${SWEEP}_p$1.txt" r
  if make --no-print-directory build PERIOD="$p" RUN="$SWEEP/p$p" > "$log" 2>&1; then r=pass; else r=fail; fi
  local wns whs
  wns=$(grep -oE "WNS -?[0-9.]+ ns" "$log" | tail -1 | awk '{print $2}')
  whs=$(grep -oE "WHS -?[0-9.]+ ns" "$log" | tail -1 | awk '{print $2}')
  echo "$p,$r,${wns:-},${whs:-}" >> "$SUMMARY"
  echo "  period $p ns: $r (WNS ${wns:-n/a})"
  [ "$r" = pass ]
}

calc() { python3 -c "print(round($1, 3))"; }

best=""
p=10.0
echo "== coarse sweep"
while run "$p"; do
  best="$p"
  p=$(calc "$p - 1.0")
  if python3 -c "import sys; sys.exit(0 if $p <= 1.0 else 1)"; then break; fi
done
if [ -z "$best" ]; then
  echo "ERROR: 10.0 ns does not close; there is no Fmax to report." >&2
  exit 1
fi

echo "== bisection between $p (fail) and $best (pass)"
lo="$p"; hi="$best"
while python3 -c "import sys; sys.exit(0 if $hi - $lo > 0.1001 else 1)"; do
  mid=$(calc "($lo + $hi) / 2")
  if run "$mid"; then hi="$mid"; best="$mid"; else lo="$mid"; fi
done

fmax=$(python3 -c "print(round(1000.0 / $best, 1))")
echo "measured_fmax_mhz=$fmax period_ns=$best" > "results/$SWEEP/FMAX.md"
echo "== measured Fmax $fmax MHz at $best ns (see $SUMMARY)"
```

In the Makefile, add `fmax` to `.PHONY` and:

```makefile
# Measure the fastest period that closes. Slow: one full implementation per
# step. Results go to results/sweep/.
fmax:
	scripts/fmax_sweep.sh
```

- [ ] **Step 2: Run it**

Run: `chmod +x scripts/fmax_sweep.sh && make fmax`
Expected: a sequence of `period <p> ns: pass|fail` lines, ending `== measured Fmax <value> MHz at <period> ns`, and `results/sweep/FMAX.md` present.

- [ ] **Step 3: Record the baseline in `docs/TIMING_CLOSURE.md`**

Create it with these sections, filling every number from the named file and quoting the file path beside it:

```markdown
# Timing closure

All figures below are copied from committed reports; the path is given beside each.

## Board constraint
- Part, clock pin, period: `constraints/target_board.xdc`
- What is timed, and why every I/O is a false path: `results/100mhz/BUILD_SCOPE.md`

## 100 MHz post-route (before iteration)
| Quantity | Value | Source |
|---|---|---|
| WNS | <from BUILD_SCOPE.md> | `results/100mhz/BUILD_SCOPE.md` |
| WHS | <from BUILD_SCOPE.md> | same |
| LUTs / FFs / BRAM / DSP | <from report_utilization> | `results/100mhz/post_route_utilization.rpt` |
| Worst setup path (start -> end, logic levels) | <from report> | `results/100mhz/post_route_timing_paths.rpt` |

## Fmax
- **Slack-derived estimate** (upper bound): `1000 / (10.0 - WNS)` = <value> MHz
- **Measured Fmax**: <value> MHz at <period> ns — `results/sweep/FMAX.md`, every run in `results/sweep/summary.csv`
- Neither is usable on the Basys 3: its oscillator is fixed at 100 MHz and this design has no MMCM.

## Critical-path iteration
(Task 8)

## Assumptions
- Clock uncertainty: Vivado default modelling; no measured oscillator jitter. A 100 ps uncertainty would reduce WNS by 100 ps.
- One implementation run per period, default directives.
```

Replace every `<...>` with the value read from the cited file before committing. Run `grep -n "<" docs/TIMING_CLOSURE.md` — Expected: no matches.

- [ ] **Step 4: Commit**

```bash
git add scripts/fmax_sweep.sh Makefile results/sweep/ docs/TIMING_CLOSURE.md
git commit -m "feat(timing): Fmax sweep and the pre-iteration timing record"
```

---

### Task 8: One latency-neutral critical-path iteration

**Files:**
- Modify: the RTL file that contains the path the sweep fails on first (determined in Step 1)
- Modify: `docs/TIMING_CLOSURE.md`
- Create (by running): `results/iter1_100mhz/`, `results/sweep_iter1/` (the sweep script's `SWEEP` variable from Task 7 keeps the baseline sweep intact)

**Interfaces:**
- Consumes: `results/sweep/summary.csv`, `build/sweep/p<first-failing>/reports/post_route_timing_paths.rpt`.
- Produces: no interface change. Every `LAT_*` constant is unchanged.

This task is measurement-driven: the change depends on which path fails. The procedure and the acceptance rules are fixed.

- [ ] **Step 1: Identify the path**

Run: `grep -A30 "Max Delay Paths" build/sweep/p<first-failing-period>/reports/post_route_timing.rpt | head -40`
Record: source and destination cells, logic levels, and whether the delay is logic- or route-dominated.

- [ ] **Step 2: Choose a latency-neutral change, in this order of preference**

1. **Arithmetic restructuring inside the stage** (e.g. move a clamp or compare off the multiply output onto a pre-computed term) — no register added.
2. **DSP inference** — if a multiply mapped to LUTs, add `(* use_dsp = "yes" *)` on the product signal so it maps into a DSP48E1 without adding an unmatched register.
3. **Implementation directives** — `opt_design -directive Explore`, `place_design -directive ExtraTimingOpt`, `phys_opt_design -directive AggressiveExplore`, `route_design -directive AggressiveExplore`, added to `build.tcl` behind a variable.
4. **Anything needing a pipeline register: do not apply.** Record it in `docs/TIMING_CLOSURE.md` as analysed, with the path and the projected improvement, per the spec.

- [ ] **Step 3: Apply it and prove latency did not move**

Run: `make lint && make lint-tb && make sim-all && ./scripts/mutate.sh`
Expected: all pass; `tb_fixed_latency` and `tb_market_pipeline_top` still report `8` cycles; 0 survivors.

Run: `git diff --stat main -- rtl/market_pkg.sv | grep -c LAT_` — Expected: `0`.

- [ ] **Step 4: Rebuild and re-sweep into separate result sets**

Run: `make build RUN=iter1_100mhz` then `SWEEP=sweep_iter1 make fmax`.

Expected: `results/iter1_100mhz/BUILD_SCOPE.md` and `results/sweep_iter1/FMAX.md` exist. The baseline `results/sweep/` is untouched.

- [ ] **Step 5: Record before/after in `docs/TIMING_CLOSURE.md`**

Replace the `(Task 8)` placeholder with:

```markdown
## Critical-path iteration 1
- **Path:** <source> -> <destination>, <n> logic levels, <logic|route>-dominated — `build/sweep/p<period>/reports/post_route_timing.rpt`
- **Change:** <one sentence>, commit <hash>. Latency-neutral: no `LAT_*` constant changed; `tb_fixed_latency` and `tb_market_pipeline_top` still measure 8 cycles.

| | Before | After | Source |
|---|---|---|---|
| WNS at 100 MHz | <v> | <v> | `results/100mhz/`, `results/iter1_100mhz/` |
| Measured Fmax | <v> MHz | <v> MHz | `results/sweep/FMAX.md`, `results/sweep_iter1/FMAX.md` |
| LUT / FF / DSP | <v> | <v> | `post_route_utilization.rpt` in each |
```

If the change did not improve Fmax, say so plainly and keep it only if it is harmless; the record is the deliverable, not the improvement.

Run: `grep -n "<" docs/TIMING_CLOSURE.md` — Expected: no matches.

- [ ] **Step 6: Commit** (after `rtl-skeptic-reviewer` on the RTL change and the results docs; fix BLOCKER/MAJOR)

```bash
git add rtl/ scripts/build.tcl results/iter1_100mhz/ results/sweep_iter1/ docs/TIMING_CLOSURE.md
git commit -m "perf(timing): critical-path iteration 1, recorded before and after"
```

---

### Task 9: Architecture, latency, verification and AI-policy docs

**Files:**
- Create: `docs/ARCHITECTURE.md`, `docs/LATENCY.md`, `docs/VERIFICATION.md`, `docs/AI_POLICY.md`

**Interfaces:**
- Consumes: `rtl/market_pkg.sv`, `scripts/mutants.txt`, the logs below, `tb/configs/`.
- Produces: files the README links to by these exact paths.

- [ ] **Step 1: Capture the logs the docs cite**

`*.log` is gitignored, so evidence logs are committed as `.txt`:

```bash
mkdir -p results/sim
make sim-all                       > results/sim/sim_all.txt 2>&1
make sim TOP=tb_fixed_latency      > results/sim/tb_fixed_latency.txt 2>&1
make sim TOP=tb_policy_configs     > results/sim/tb_policy_configs.txt 2>&1
make sim TOP=tb_market_pipeline_top > results/sim/tb_market_pipeline_top.txt 2>&1
./scripts/mutate.sh                > results/sim/mutation.txt 2>&1
.venv/bin/python scripts/analyze_latency.py results/sim/tb_fixed_latency.txt --expect 8 > results/sim/analyze_latency.txt
```

Expected: `grep -c "^PASS:" results/sim/sim_all.txt` equals the number of testbenches; `tail -1 results/sim/mutation.txt` is `killed N, survived 0`.

- [ ] **Step 2: Write the four documents**

Each figure must be copied from, and cite, one of: `rtl/market_pkg.sv`, `results/sim/*.txt`, `scripts/mutants.txt`, `tb/configs/*`, `results/100mhz/*`. Required content:

- **`docs/ARCHITECTURE.md`**: stage list with one-line responsibility and `LAT_*` each; the top-level structure (ROM → replay → pipeline → counters; cfg_loader → config_regs); the valid/ready no-skid convention; the per-event configuration snapshot as the atomicity mechanism; the reset convention (async per module, one `reset_sync`); why all I/O is false-path.
- **`docs/LATENCY.md`**: the per-stage table from `market_pkg.sv`; the histogram from `results/sim/tb_fixed_latency.txt` and `analyze_latency.txt`; the conditional ("with `m_ready` held high"); the two-config identical-histogram result from `results/sim/tb_policy_configs.txt`; the top-level measurement from `tb_market_pipeline_top.txt`; the ns conversion stated as arithmetic on the fixed 100 MHz oscillator.
- **`docs/VERIFICATION.md`**: every testbench with what it proves; the assertion list from `tb/assertions.sv`; the mutation tally from `results/sim/mutation.txt`; the baseline gate and why it exists; the deliberately absent mutants from `scripts/mutants.txt` with their reasons.
- **`docs/AI_POLICY.md`**: the score formula and Q3.12 format; offline search in `train_policy.py`, scored on quantised weights with the RTL's integer arithmetic; that `baseline` is hand-chosen and `tuned` is regenerated by the command in its note; the synthetic objective and that it is not P&L; the export path to `.cfg` and `.mem`; nothing beyond offline-tuned fixed-point weights is "AI" here.

- [ ] **Step 3: Check for unsourced numbers**

Run: `grep -nE "[0-9]{2,}" docs/ARCHITECTURE.md docs/LATENCY.md docs/VERIFICATION.md docs/AI_POLICY.md`
Expected: every matched line either contains a backticked path or is a constant name/width that appears verbatim in `rtl/market_pkg.sv`. Fix any line that does neither.

- [ ] **Step 4: Commit** (after `rtl-skeptic-reviewer` on these docs; fix BLOCKER/MAJOR)

```bash
git add docs/ARCHITECTURE.md docs/LATENCY.md docs/VERIFICATION.md docs/AI_POLICY.md results/sim/
git commit -m "docs: architecture, latency, verification and AI-policy write-ups"
```

---

### Task 10: README, last, with a citation test

**Files:**
- Create: `README.md`, `scripts/test_readme_citations.py`

**Interfaces:**
- Consumes: every artifact from Tasks 6–9.

- [ ] **Step 1: Write the failing test** — `scripts/test_readme_citations.py`:

```python
"""Every number in the README's results table must trace to a committed artifact.

The project's non-negotiable is that only measured numbers are stated. This
test enforces the mechanical half: each results row links at least one file
that exists, and the headline figures equal the values in the files they come
from. rtl-skeptic-reviewer enforces the rest.
"""
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
README = REPO / "README.md"


def results_rows():
    text = README.read_text()
    assert "## Results" in text, "README has no Results section"
    section = text.split("## Results", 1)[1].split("\n## ", 1)[0]
    rows = [l for l in section.splitlines()
            if l.startswith("|") and not set(l.strip()) <= set("|-: ")]
    return rows[1:]          # drop the header row


def test_every_results_row_cites_an_existing_artifact():
    rows = results_rows()
    assert rows, "Results table is empty"
    for row in rows:
        links = re.findall(r"\]\(([^)#\s]+)", row)
        assert links, f"results row cites no artifact: {row}"
        for link in links:
            assert (REPO / link).exists(), f"cited artifact does not exist: {link}"


def test_latency_matches_the_package():
    pkg = (REPO / "rtl" / "market_pkg.sv").read_text()
    terms = dict(re.findall(r"localparam int (LAT_\w+)\s*=\s*(\d+);", pkg))
    total = sum(int(v) for k, v in terms.items())
    assert f"{total} clock cycles" in README.read_text() or f"{total} cycles" in README.read_text()


def test_fmax_matches_the_sweep():
    candidates = sorted(REPO.glob("results/sweep*/FMAX.md"))
    assert candidates, "no FMAX.md committed"
    values = [re.search(r"measured_fmax_mhz=([0-9.]+)", p.read_text()).group(1)
              for p in candidates]
    assert any(v in README.read_text() for v in values), \
        f"README quotes none of the measured Fmax values {values}"


def test_wns_matches_the_100mhz_build():
    scope = (REPO / "results" / "100mhz" / "BUILD_SCOPE.md").read_text()
    wns = re.search(r"WNS (-?[0-9.]+) ns", scope).group(1)
    text = README.read_text()
    iter_scope = REPO / "results" / "iter1_100mhz" / "BUILD_SCOPE.md"
    if iter_scope.exists():
        wns_after = re.search(r"WNS (-?[0-9.]+) ns", iter_scope.read_text()).group(1)
        assert wns in text or wns_after in text
    else:
        assert wns in text


def test_no_unmeasured_or_banned_claims():
    text = README.read_text().lower()
    for banned in ("250 mhz", "32 ns"):
        assert banned not in text, f"README contains an unmeasured figure: {banned}"


def test_hardware_status_is_stated():
    text = README.read_text().lower()
    assert "not been run on" in text and "hardware" in text, \
        "README must state the design has not been run on physical hardware"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `.venv/bin/python -m pytest scripts/test_readme_citations.py -q`
Expected: FAIL — `README.md` does not exist.

- [ ] **Step 3: Write `README.md`**

Structure — fill every value from the cited file:

```markdown
# fpga-low-latency-market-pipeline

A SystemVerilog market-event decision pipeline for the Digilent Basys 3
(xc7a35tcpg236-1): decode → sequence check → top of book → features →
fixed-point policy → risk gate, with a fixed, assertion-proven latency.

Synthetic events only. No exchange connectivity, no real market data, and no
claim of suitability for live trading. **This design has not been run on
physical hardware**; everything below is simulation and post-route analysis.

## Results

| Measurement | Value | Evidence |
|---|---|---|
| Input-to-decision latency | 8 clock cycles, min = mean = max | [histogram](results/sim/analyze_latency.txt) |
| Same latency under two different policies | identical histograms | [two-config run](results/sim/tb_policy_configs.txt) |
| Top-level decisions vs verified chain | <n> matched | [top-level run](results/sim/tb_market_pipeline_top.txt) |
| Post-route WNS at 100 MHz | <v> ns | [build scope](results/<run>/BUILD_SCOPE.md) |
| Measured Fmax (fabric ceiling, not usable on this board) | <v> MHz | [sweep](results/<sweep>/FMAX.md) |
| Utilisation | <LUT / FF / BRAM / DSP> | [report](results/<run>/post_route_utilization.rpt) |
| Mutation testing | <k> of <k> mutants killed | [log](results/sim/mutation.txt) |

Latency in nanoseconds is 8 × 10.0 ns at the board's fixed 100 MHz oscillator.
The measured Fmax is higher than the board can use: the Basys 3 has no faster
clock and this design has no MMCM.

## What "AI" means here
[docs/AI_POLICY.md](docs/AI_POLICY.md)

## Documentation
- [Architecture](docs/ARCHITECTURE.md) · [Latency](docs/LATENCY.md) · [Verification](docs/VERIFICATION.md) · [Timing closure](docs/TIMING_CLOSURE.md) · [AI policy](docs/AI_POLICY.md)

## Reproduce
make lint lint-tb pytest
make sim-all
./scripts/mutate.sh
make build
make fmax
```

Replace every `<...>` from the cited artifact. Run `grep -n "<" README.md` — Expected: no matches.

- [ ] **Step 4: Run the tests**

Run: `.venv/bin/python -m pytest -q`
Expected: all pass, including the six README tests.

- [ ] **Step 5: Skeptic review of the README, on its own**

Dispatch `rtl-skeptic-reviewer` with only `README.md` and the files it links as scope. Instruction: verify every number against its cited file and flag any claim not backed by a committed artifact. Fix every BLOCKER and MAJOR; re-run pytest.

- [ ] **Step 6: Commit**

```bash
git add README.md scripts/test_readme_citations.py
git commit -m "docs: README with every result cited to a committed artifact"
```

---

### Task 11: Status, full check, PR #9

**Files:**
- Modify: `docs/STATUS.md`

- [ ] **Step 1: Final regression**

Run: `make lint && make lint-tb && .venv/bin/python -m pytest -q && make sim-all && ./scripts/mutate.sh`
Expected: all green; `killed N, survived 0` with the baseline gate passing.

- [ ] **Step 2: Update `docs/STATUS.md`** — merged/open PRs, this branch's state, the three things to look at first, decisions made alone.

- [ ] **Step 3: Push and open PR #9**

The description must include: the latency table; the timing summary (WNS/WHS at 100 MHz, measured Fmax with the board caveat, utilisation), each with its `results/` path; the critical-path iteration before/after; the mutation tally; the stacking note (on #8 → #7 → #6); and the statement that nothing has been run on hardware.

```bash
git add docs/STATUS.md
git commit -m "docs: STATUS after integration and timing closure"
git push -u origin feat/integration-timing
gh pr create --base main --head feat/integration-timing --title "feat: Basys 3 top, timing closure, and documentation" --body-file <description file>
```

---

## Self-review notes

- Spec §1 decisions → Global Constraints and Tasks 5–10. §2 top → Tasks 2–5. §3 XDC → Task 6. §4 build and Fmax → Tasks 6–7. §5 iteration → Task 8. §6 verification → Tasks 2–5 and 11. §7 docs → Tasks 7, 9, 10. §8 not claimed → Global Constraints and README tests.
- Task 8 cannot contain the RTL diff in advance: which path fails is only known after Task 7 runs. Its procedure, preference order and acceptance checks are fixed instead.
- Task 9's prose depends on numbers produced in Tasks 6–8; its required content and a mechanical unsourced-number check are fixed instead.
