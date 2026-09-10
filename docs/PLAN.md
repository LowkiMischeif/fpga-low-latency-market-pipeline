# fpga-low-latency-market-pipeline — One-Month Plan

Build a **parameterized FPGA market-data decision pipeline**: a small SystemVerilog design that accepts simplified quote/order events, maintains a tiny top-of-book state, applies a configurable risk/strategy rule, and emits an action with measured fixed-cycle latency.

It is a strong one-month GitHub project because it demonstrates RTL design, verification, pipelining, timing constraints, deterministic latency, and clean engineering — not because it pretends to be a production trading system. FPGA trading systems are valued for predictable, parallel processing; published work has demonstrated microsecond-scale fixed-latency feed processing at high bandwidth. ([dl.acm](https://dl.acm.org/doi/10.1109/HOTI.2012.15))

## Project concept

### Name
`fpga-low-latency-market-pipeline`

### Elevator pitch
> A fully verified, timing-constrained SystemVerilog FPGA pipeline for processing synthetic market events, updating a compact order-book model, performing configurable risk checks, and generating deterministic trade decisions in a fixed number of clock cycles.

### What it should do

Use a **synthetic binary market-event stream** rather than real exchange connectivity. Each event might contain:

| Field | Example | Purpose |
|---|---:|---|
| `event_type` | ADD / CANCEL / TRADE | Selects processing path |
| `symbol_id` | 0–15 | Shows scalable state partitioning |
| `side` | BID / ASK | Updates or evaluates the book |
| `price` | Fixed-point integer | Avoids floating-point latency |
| `quantity` | Integer | Supports risk logic |
| `sequence_id` | Integer | Enables loss/reorder detection |
| `timestamp` | Cycle counter | Measures end-to-end latency |

Pipeline behavior:

1. **Decode** the incoming fixed-width event.
2. **Validate** protocol fields and sequence number.
3. **Update** best bid / best ask state for a small configurable symbol universe.
4. **Calculate** spread, imbalance, and simple momentum.
5. **Apply a runtime-configurable strategy/risk rule.**
6. **Generate** `BUY`, `SELL`, or `HOLD`.
7. **Emit telemetry** including ingress and egress timestamps, latency in cycles, decision reason, and drop/error counters.

Do not make "AI" mean "run an LLM on an FPGA." For a one-month trading-oriented FPGA portfolio project, the credible AI customization is a **hardware-friendly, configurable model**:

```
score = w0 + w1*(spread) + w2*(book imbalance) + w3*(momentum)
```

Then:

- `BUY` if `score > theta_buy`
- `SELL` if `score < theta_sell`
- `HOLD` otherwise

Keep weights, thresholds, maximum position, and maximum order size in registers. The Python-side "AI tuner" can train or search for values offline, export them to a config file, and replay them in simulation. This demonstrates **AI-customized policy deployed as deterministic fixed-point RTL**, which is much more defensible for low-latency FPGA work.

## Architecture

```text
Synthetic Event Source
          │
          ▼
┌─────────────────────┐
│ Event Decode        │  Fixed-width packet / AXI-stream-like interface
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ Sequence + Sanity   │  Invalid-type, out-of-order, malformed-event counters
│ Validation          │
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ Top-of-Book State   │  Best bid/ask, quantities, position per symbol
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ Feature Pipeline    │  Spread, imbalance, momentum; all fixed point
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ Policy + Risk Gate  │  Parameterized weights and hard risk limits
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ Decision Output     │  BUY / SELL / HOLD + reason + cycle-latency measure
└─────────────────────┘
```

Design for a **fixed, documented latency**, e.g. 6–10 cycles from valid input handshake to valid decision handshake. The key claim should be:

> "For non-stalled input traffic, action latency is fixed at 8 cycles, verified with assertions and randomized simulation."

Avoid claiming nanoseconds unless you have implementation reports and know the target board/part. In the final report you can compute the estimated timing from the achieved clock period:

```
t_latency = N_cycles * T_clock
```

For example, 8 cycles at 250 MHz is 32 ns core pipeline latency — not full network-to-exchange latency.

> **EXAMPLE ONLY — NOT THIS BOARD.** The 250 MHz / 32 ns figures above are illustrative arithmetic, not a
> target. The committed constraint is a fixed 100 MHz oscillator on a Basys 3 (`xc7a35tcpg236-1`, the slowest
> speed grade of the smallest Artix-7) with no MMCM, so this design's only possible rate is 100 MHz and an
> 8-cycle pipeline is **80 ns**, not 32 ns. Do not copy 250 MHz or 32 ns into the README.

## One-month build plan

### Week 1 — RTL foundations and simulation

**Goal:** Create a simulation-first, testable baseline before touching board I/O.

- Choose one accessible target:
  - Basys 3 / Artix-7 if you own one.
  - Any supported AMD/Xilinx board you can access.
  - Otherwise, develop and verify entirely in Vivado simulation, with a documented target part for synthesis.
- Install Vivado and create a non-project-mode Tcl build flow.
- Learn/review:
  - Combinational vs sequential logic.
  - Nonblocking assignment discipline.
  - Register pipelines and valid/ready handshakes.
  - Signed fixed-point arithmetic and bit-growth.
  - Reset behavior.
- Write:
  - `market_pkg.sv` for enums, structs, widths, and constants.
  - `event_decoder.sv`.
  - `sequence_checker.sv`.
  - A self-checking `tb_event_decoder.sv`.
- Add a Python generator that produces randomized synthetic event traces.

**End-of-week deliverable:**
- Events decode correctly.
- Sequence gaps and malformed events are flagged.
- Randomized testbench passes.
- README contains a waveform screenshot and a module-level latency table.

Vivado Simulator supports behavioral, functional, and timing simulation across VHDL, Verilog, and SystemVerilog, making it suitable for this verification-centered workflow. ([docs.amd](https://docs.amd.com/r/en-US/ug937-vivado-design-suite-simulation-tutorial/Introduction))

### Week 2 — Deterministic market pipeline

**Goal:** Implement data-path state and fixed-cycle processing.

- Build `top_of_book.sv`:
  - Support 4 or 8 synthetic symbols.
  - Maintain bid price/size and ask price/size.
  - Make update rules explicit and fully tested.
- Build `feature_engine.sv`:
  - Spread: `ask - bid`.
  - Midprice approximation.
  - Order-book imbalance: `I = (Q_bid - Q_ask) / (Q_bid + Q_ask)`
  - Use bounded fixed-point representation; handle divide-by-zero safely.
- Pipeline the stages intentionally:
  - Define expected latency per module.
  - Register every major stage.
  - Maintain an input timestamp / transaction tag.
- Add assertions:
  - No decision without a valid event.
  - Output tag matches input tag.
  - No event is duplicated.
  - Latency is exactly `N` cycles under non-stalled conditions.

**End-of-week deliverable:**
- An event trace passes through the full decode → state → feature pipeline.
- Testbench proves all expected outputs.
- A latency histogram script reports min/mean/max cycle counts; ideally min = mean = max.

### Week 3 — AI-customizable policy and risk logic

**Goal:** Add the "AI customization" without sacrificing low-latency credibility.

- Implement `policy_engine.sv`:
  - Fixed-point weighted linear score.
  - Runtime-configurable weights and thresholds.
  - Saturating arithmetic and overflow checks.
- Implement `risk_gate.sv`:
  - Maximum long and short position.
  - Maximum order quantity.
  - Spread guard.
  - Kill switch.
  - Reject decision on invalid/stale sequence data.
- Create Python tooling:
  - `train_policy.py`: searches weights/thresholds from a synthetic replay dataset.
  - `export_config.py`: writes hardware register values.
  - `replay_and_score.py`: compares baseline vs tuned policies.
- Add configuration interface:
  - Simple register write bus in RTL, not PCIe.
  - A config loader in the testbench.
- Run directed and randomized tests:
  - Normal buy/sell conditions.
  - Position limit rejects.
  - Kill-switch behavior.
  - Overflow / saturation.
  - Parameter changes taking effect at defined safe boundaries.

**End-of-week deliverable:**
- Two configurations produce demonstrably different behavior.
- The configurable model still has a constant structural latency.
- A chart or table of simulated policy metrics, such as fill decisions, rejected orders, and synthetic P&L — not real trading performance.

### Week 4 — Vivado timing, polish, and portfolio readiness

**Goal:** Turn a class project into an FPGA-team-quality portfolio artifact.

- Add an XDC constraints file:
  - Clock definition.
  - Explicit input/output delay assumptions if using external I/O.
  - Carefully documented clock-domain crossings if more than one clock is used.
- Run:
  - Synthesis.
  - Implementation.
  - `report_timing_summary`.
  - `report_utilization`.
  - Timing-constraint checks.
- Iterate:
  - Identify critical path.
  - Insert a pipeline register or simplify arithmetic.
  - Rebuild and document before/after timing results.
- Add GitHub Actions:
  - Lint with Verilator if compatible.
  - Run Python replay/tooling tests.
  - Run HDL tests through the chosen simulator setup where practical.
- Write documentation:
  - `docs/ARCHITECTURE.md`
  - `docs/LATENCY.md`
  - `docs/VERIFICATION.md`
  - `docs/TIMING_CLOSURE.md`
  - `docs/AI_POLICY.md`
- Record a 2–3 minute demo:
  - Show testbench waveform.
  - Show fixed latency measurement.
  - Show a config change altering decisions.
  - Show Vivado timing and utilization reports.

Timing constraints should be treated as a first-class engineering output: AMD's methodology explicitly distinguishes clock, I/O, clock-domain-crossing, and timing-exception constraints, and recommends reviewing missing constraints with its Timing Constraints Wizard. ([docs.amd](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Defining-Timing-Constraints-in-Four-Steps))

## Recommended GitHub structure

```text
fpga-low-latency-market-pipeline/
├── README.md
├── LICENSE
├── Makefile
├── requirements.txt
├── .github/
│   └── workflows/
│       └── test.yml
├── rtl/
│   ├── market_pkg.sv
│   ├── event_decoder.sv
│   ├── sequence_checker.sv
│   ├── top_of_book.sv
│   ├── feature_engine.sv
│   ├── policy_engine.sv
│   ├── risk_gate.sv
│   └── market_pipeline_top.sv
├── tb/
│   ├── tb_market_pipeline.sv
│   ├── assertions.sv
│   └── traces/
├── scripts/
│   ├── build.tcl
│   ├── run_sim.tcl
│   ├── train_policy.py
│   ├── export_config.py
│   ├── generate_events.py
│   └── analyze_latency.py
├── constraints/
│   └── target_board.xdc
├── docs/
│   ├── ARCHITECTURE.md
│   ├── LATENCY.md
│   ├── VERIFICATION.md
│   ├── TIMING_CLOSURE.md
│   └── AI_POLICY.md
└── results/
    ├── timing_summary.md
    ├── utilization.md
    └── waveforms/
```

## What recruiters should see

The README should lead with **measured engineering evidence**, not buzzwords:

```md
# FPGA Low-Latency Market Pipeline

A SystemVerilog/Vivado implementation of a deterministic market-event
processing and risk-decision pipeline.

## Results
- Fixed input-to-decision latency: 8 clock cycles
- Target clock: 250 MHz
- Core pipeline latency: 32 ns
- Functional verification: directed + randomized replay tests
- Safety checks: sequence validation, saturation arithmetic, position limits,
  quantity limits, and kill switch
- AI customization: offline-tuned fixed-point policy weights loaded at runtime
- Build: Vivado Tcl, XDC constraints, synthesis and timing reports committed
```

Only state values actually measured. If timing does not close at 250 MHz, change the number. Honest evidence is much more impressive than a high unverified claim.

## Skills it demonstrates

| Desired FPGA-team quality | Evidence in the repo |
|---|---|
| Digital logic / SystemVerilog | Modular synthesizable RTL, interfaces, state machines, fixed-point arithmetic |
| Analytical problem solving | Critical-path analysis, pipeline changes, before/after timing results |
| Fast and accurate decisions | Deterministic decision pipeline, cycle-level latency checks, sequence validation |
| Easily testable design | Self-checking testbench, assertions, randomized replay, coverage goals |
| Rapidly changing requirements | Parameterized symbols, policy weights, limits, and thresholds |
| Build systems from scratch | Event format, datapath, verification environment, Python tooling, Vivado flow |
| Innovation | AI-tuned policy compiled to FPGA-friendly fixed-point parameters |
| Production mindset | Risk limits, kill switch, overflow handling, invalid-input behavior, documented assumptions |

## Important scope choices

- Do **not** build actual exchange protocol hardware in a month.
- Do **not** claim it is suitable for live trading.
- Do **not** use floating point in the core path.
- Do **not** call a generic rules engine "AI." Be precise: it is a fixed-point model whose parameters were selected offline.
- Do prioritize: determinism, testability, correctness, latency accounting, and timing closure.

A polished version of this project will communicate exactly the qualities FPGA trading teams want: HDL fluency, thoughtful architecture, disciplined verification, numerical rigor, and the ability to optimize an evolving system under a strict latency budget.
