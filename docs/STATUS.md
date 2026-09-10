# Status

Written for Tyler returning to the project. Updated 2026-09-10.

## The three things to look at first

1. **PR #6 needs your merge before #7 makes sense.** `feat/policy-risk` is
   *stacked* on `fix/generator-and-gating`, because it needs that branch's
   book-capable generator. GitHub will show #7's diff against `main` including
   #6's commits until #6 lands. Merge #6, then #7.

2. **The headline claim is proven, and I want you to check the experiment, not
   just the result.** `tb/tb_policy_configs.sv` replays one trace under both
   committed configs: 839 trades vs 1679, **1292 of 2000 decisions differ**,
   latency histograms **identical at 8 cycles**. The part worth your eye is
   whether the two passes are genuinely the same experiment — full reset
   between them, byte-identical stimulus rebuilt from one seed. If that is
   sound the claim is sound; if not, nothing else in the branch matters.

3. **Two mutants cannot be killed, and I left them out of the suite with
   reasons rather than quietly dropping them.** See the comments in
   `scripts/mutants.txt`. One is the policy saturation clamp (the score cannot
   reach the `SCORE_W` rail at these widths, so the clamp is defensive); one is
   the spread guard's `!book_empty` qualification (shadowed by reason
   precedence, since `book_empty` is tested first). Both are judgement calls I
   made alone and either could reasonably be decided the other way.

## Merged on `main`

| PR | What |
|---|---|
| #1 | Verible LSP plugin and lint rules |
| #2 | Toolchain: xsim notes, Makefile defaults, `run_sim.tcl` / `build.tcl` |
| #3 | `event_decoder`, `sequence_checker` — 2-cycle proven latency |
| #4 | `make lint-tb` in CI, `make sim-all`, reset-convention fix |
| #5 | `top_of_book`, `feature_engine` — 5-cycle proven latency |

`main` is at `ff6350d`. I have not touched it.

## Open

**PR #6 — `fix/generator-and-gating`.** Clears the three deferrals from #5:
the generator now reaches the book (cancel/trade hits went 0 → 169/181),
`feature_engine` has one gating rule, `MOMENTUM_LAG` deleted. CI green.
**Yours to merge.**

## On a branch, not yet a PR

**`feat/policy-risk`** — pushed, no PR opened yet; the skeptic review was still
running when I wrote this. Two commits:

- `36d196d` — `policy_engine`, `risk_gate`, `config_regs`
- `29cb825` — policy tooling, two committed configs, the 8-cycle proof

State: `make lint` clean, `make lint-tb` clean (12 testbenches), `pytest`
45 passed, `make sim-all` 12/12 plus the generated-trace replay,
`./scripts/mutate.sh` **39 mutants, 39 killed**.

| Stage | Constant | Cycles |
|---|---|---:|
| `event_decoder` | `LAT_DECODE` | 1 |
| `sequence_checker` | `LAT_SEQCHK` | 1 |
| `top_of_book` | `LAT_TOB` | 1 |
| `feature_engine` | `LAT_FEATURE` | 2 |
| `policy_engine` | `LAT_POLICY` | 2 |
| `risk_gate` | `LAT_RISK` | 1 |
| **Total** | **`LATENCY_CYCLES`** | **8** |

min = mean = max = 8 over 2000 events, 80 ns at the board's fixed 100 MHz.
That figure is arithmetic on the oscillator, **not a synthesis result** — there
is still no `market_pipeline_top`, no synthesis run, and no measured WNS
anywhere in this repo.

## Not done

- `market_pipeline_top` and the whole `feat/integration-timing` stage:
  synthesis, timing closure, the five `docs/*.md`, the README.
- No numbers have been published to the README. There is no README.
- Reset asserted mid-flight is covered per-module but not through the
  integrated chain.

## Decisions I made alone that you may want to overturn

- **Q3.12 weights, `SCORE_W = 32`.** The weights carry all the feature scaling
  so the features keep their natural units. It works, but it makes the tuner's
  numbers unintuitive — `w_spread = 1.0` means "one score unit per tick".
- **`order_qty` comes from config**, and `risk_gate` rejects it against
  `max_order_qty`. That is a misconfiguration guard rather than a market-aware
  size, and a real system would size against available liquidity.
- **The training objective is synthetic** and documented as such in
  `train_policy.py`: it rewards agreement with the next midprice move and
  penalises churn. It separates policies; it does not value them. Nothing
  claims profitability and nothing should.
- **Baseline config is spread-led, tuned is imbalance-led.** I picked
  thresholds from the measured feature range rather than from the tuner,
  because the tuner's own output traded zero times against this stimulus.
