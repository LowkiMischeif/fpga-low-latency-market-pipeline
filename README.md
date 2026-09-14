# fpga-low-latency-market-pipeline

A SystemVerilog market-event decision pipeline for the Digilent Basys 3
(xc7a35tcpg236-1): decode → sequence check → top of book → features →
fixed-point policy → risk gate, with a fixed, assertion-checked latency of 8
clock cycles whenever the decision output is not stalled — and inside the
Basys 3 top it never is.

Synthetic events only. No exchange connectivity, no real market data, and no
claim of suitability for live trading. **This design has not been run on
physical hardware**; everything below is simulation and Vivado post-route
analysis.

## Results

| Measurement | Value | Evidence |
|---|---|---|
| Input-to-decision latency, output drainable | 8 clock cycles for all 2000 events: min = mean = max | [histogram](results/sim/analyze_latency.txt) |
| Latency under the two committed policies | identical: all 2000 events at 8 cycles under each, while 1188 of 2000 decisions differ | [two-policy run](results/sim/tb_policy_configs.txt), [histograms](results/sim/analyze_latency_configs.txt) |
| Synthesizable top vs the verified pipeline | 6000 decisions matched, 0 mismatches; all 7000 handed-off events at 8 cycles, across a reset mid-replay | [top-level run](results/sim/tb_market_pipeline_top.txt) |
| Post-route WNS / WHS at 100 MHz | +0.250 ns / +0.122 ns | [build scope](results/100mhz/BUILD_SCOPE.md) |
| Measured Fmax (fastest passing period in a one-run-per-period sweep; not usable on this board) | 106.4 MHz (9.4 ns passes, 9.3 ns fails) | [sweep](results/sweep/FMAX.md), [every run](results/sweep/summary.csv) |
| Utilisation: LUT / FF / block RAM tile / DSP | 1544 / 2379 / 3 / 4 | [report](results/100mhz/post_route_utilization.rpt) |
| Critical-path iterations: setup WNS at 100 MHz | −73.898 ns → −0.071 ns → +0.250 ns | [iteration 1 before](results/iter0_100mhz/GATE_FAILED.md), [iteration 2 before](results/iter1_100mhz/GATE_FAILED.md), [after](results/100mhz/BUILD_SCOPE.md) |
| Mutation testing | 87 of 87 mutants killed, 0 survived | [log](results/sim/mutation.txt) |

`scripts/test_readme_citations.py` checks that each value above equals what its
linked file says.

Latency in nanoseconds is only arithmetic on the board's fixed 100 MHz
oscillator: 8 × 10.000 ns. It counts the pipeline alone, with events from an
on-chip ROM. The measured Fmax is higher than the board can use, because the
Basys 3 has no faster clock and this design has no MMCM; see
[docs/TIMING_CLOSURE.md](docs/TIMING_CLOSURE.md) for why it is not a ceiling.

## What "AI" means here

Offline-tuned fixed-point weights, loaded as configuration: a seeded search over
a constant term, three feature weights and two thresholds, scored with an
integer mirror of the RTL's arithmetic. No neural network and no claim of
profitability. See [docs/AI_POLICY.md](docs/AI_POLICY.md).

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — stages, handshake, configuration snapshot, reset, the Basys 3 top
- [Latency](docs/LATENCY.md) — where the 8 cycles are and how they were measured
- [Verification](docs/VERIFICATION.md) — testbenches, assertions, mutation testing, what is not covered
- [Timing closure](docs/TIMING_CLOSURE.md) — constraints, the critical-path iterations, Fmax
- [AI policy](docs/AI_POLICY.md) — what the configurable policy is and is not

## Reproduce

Vivado 2026.1 (xsim and implementation), Verilator 5.032 locally (CI installs
the distribution's package), Python 3 with `requirements.txt`.

```
make lint lint-tb pytest   # Verilator lint of rtl/ and tb/, Python tests
make sim-all               # every testbench plus a generated-trace replay
./scripts/mutate.sh        # mutation testing
make build                 # 100 MHz synth + implementation -> results/100mhz/
make fmax                  # Fmax sweep -> results/sweep/
```
