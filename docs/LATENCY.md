# Latency

## The claim

**Input-to-decision latency is exactly `LATENCY_CYCLES` clock cycles, whenever the
decision output is free to drain (`m_ready` held high).** It is measured from the
edge on which `event_decoder` accepts a beat (`s_valid && s_ready`) to the edge on
which `risk_gate` hands the decision off (`m_valid && m_ready`).

The condition is part of the claim, not a footnote to it. Under backpressure an
event waits wherever the stall holds it, its latency depends on the stall
pattern, and no figure is claimed.

## Where the cycles are

From `rtl/market_pkg.sv`. Every stage registers its output exactly once per
cycle it contributes, and the total is the sum, computed in the package rather
than restated.

| Constant | Stage | Work in those cycles |
|---|---|---|
| `LAT_DECODE` = 1 | `rtl/event_decoder.sv` | field slice, encoding checks |
| `LAT_SEQCHK` = 1 | `rtl/sequence_checker.sv` | gap / stale classification |
| `LAT_TOB` = 1 | `rtl/top_of_book.sv` | best bid and ask update |
| `LAT_FEATURE` = 2 | `rtl/feature_engine.sv` | spread, mid, normalise and reciprocal read; imbalance multiply, momentum |
| `LAT_POLICY` = 2 | `rtl/policy_engine.sv` | three multiplies; sum, scale, threshold compares |
| `LAT_RISK` = 1 | `rtl/risk_gate.sv` | limit checks, position update |
| **`LATENCY_CYCLES` = 8** | | sum of the above, `rtl/market_pkg.sv` |

## What was measured

| Measurement | Result | Evidence |
|---|---|---|
| Full chain, decoder to risk gate, 2000 events mixing in-order, gapped, stale and malformed beats, `m_ready` high throughout | every event 8 cycles: min = mean = max | `results/sim/tb_fixed_latency.txt`, histogram in `results/sim/analyze_latency.txt` |
| The same trace under the two committed policies | identical histograms, all 2000 events at 8 cycles under each, while 1188 decisions differ | `results/sim/tb_policy_configs.txt` |
| The synthesizable Basys 3 top: three replays of the on-chip trace, one interrupted by a reset mid-replay | every event handed off, including those in flight before the reset, at 8 cycles | `results/sim/tb_market_pipeline_top.txt` |
| Per stage, as a property | `a_fixed_latency`: the event accepted at T is the one presenting at T + `LATENCY`, bound to each of the six stages | `tb/assertions.sv`, `tb/bind_assertions.sv` |

The stimulus deliberately includes malformed and out-of-sequence events: those
take the same path through the same registers as clean ones, and the
measurement is there to show it (`tb/tb_fixed_latency.sv`).

`scripts/analyze_latency.py` turns the simulation log into the histogram and
fails unless every event has the same latency. It never reports a mean on its
own: a mean over a spread would let a variable-latency pipeline look fixed.

### Why the policy cannot move it

Configuration reaches the arithmetic only. No weight, threshold or limit appears
in any valid, ready or enable expression (`rtl/policy_engine.sv`), so a
configuration changes what is decided, never when. The two-policy measurement
above is the end-to-end check of that, and a mutant that routes a configuration
bit into the stall path is killed by it (`scripts/mutants.txt`, `cfg-indep`).

## In nanoseconds

The board clock is a fixed 100 MHz oscillator with no MMCM
(`constraints/target_board.xdc`), so the only legitimate conversion is
arithmetic: `LATENCY_CYCLES` × 10.000 ns = 80 ns, from `rtl/market_pkg.sv` and
`constraints/target_board.xdc`.

That figure is **not** a wall-clock measurement. It counts the pipeline only:
events come from an on-chip ROM, so it includes no input interface, no network,
and nothing outside the six stages. A measured Fmax above 100 MHz
(`docs/TIMING_CLOSURE.md`) does not shorten it on this board, because the board
has no faster clock.
