# fpga-low-latency-market-pipeline

Deterministic SystemVerilog market-event pipeline: decode → sequence check → top-of-book → feature engine → policy engine → risk gate → decision. Full plan lives in `docs/PLAN.md` (paste the one-month plan there).

## Non-negotiables
- Fixed-point only in the core path. No floating point.
- Fixed, documented input-to-decision latency (`LATENCY_CYCLES` in `rtl/market_pkg.sv`), proven by SVA + randomized sim.
- Only state measured numbers in README/docs. No claims of live-trading suitability or exchange connectivity.
- "AI" means offline-tuned fixed-point weights loaded via the register bus. Nothing else.

## Layout
- `rtl/` synthesizable SV (`market_pkg.sv` is the single source of truth for widths/enums/structs)
- `tb/` testbenches, `tb/assertions.sv`, `tb/traces/`
- `scripts/` Vivado Tcl (`build.tcl`, `run_sim.tcl`) + Python tooling (`generate_events.py`, `train_policy.py`, `export_config.py`, `analyze_latency.py`)
- `constraints/target_board.xdc`, `docs/`, `results/`

## Tooling
- Lint: `verilator --lint-only -Wall`
- Sim: Vivado xsim via `scripts/run_sim.tcl` (Makefile target `make sim`)
- Python: `pip install -r requirements.txt`, tests via `pytest`

## Workflow
1. Any change under `rtl/` → run `rtl-verification-engineer` to add/update tests and assertions.
2. Before committing RTL, constraints, or results docs → run `rtl-skeptic-reviewer`; fix all BLOCKER/MAJOR findings.
3. Use Superpowers' brainstorm → plan → implement flow for each week's milestone; one branch per milestone, PR via the GitHub plugin.
4. Use `#` to save durable lessons (e.g. a timing fix that worked) to this file.
