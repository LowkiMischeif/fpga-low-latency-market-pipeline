# Status

Written for Tyler returning to the project. Updated 2026-09-10.

## The three things to look at first

1. **Merge order: #6 then #7.** `feat/policy-risk` is *stacked* on
   `fix/generator-and-gating`, because it needs that branch's book-capable
   generator. PR #7's diff will shrink to just the policy/risk commits once #6
   lands. Neither is merged; I have merged nothing.

2. **A false claim shipped in a committed artifact and I did not catch it —
   the skeptic did.** `tuned.json`/`tuned.cfg` said "from
   `scripts/train_policy.py --seed 7`" and were hand-picked values that
   `random.uniform` cannot produce. `STATUS.md` said so honestly while the
   artifact the testbench reads said otherwise. It is fixed — the trainer now
   emits a complete policy, `tuned.json` is regenerated from a real run, and a
   test reruns the command in its own note — but the near-miss is worth your
   eye, because it was in the one piece of evidence this project is named for.

3. **`cfg_boundary` turned out to be redundant.** Writing the mid-stream commit
   test showed that forcing it high changes nothing: atomicity comes from the
   per-event configuration snapshot, not from the boundary signal. I documented
   that in the RTL, the spec and `mutants.txt` rather than leaving it looking
   load-bearing — but if you would rather delete the signal than keep it as
   defence in depth, that is a reasonable call and it is yours.

## Merged on `main`

| PR | What |
|---|---|
| #1 | Verible LSP plugin and lint rules |
| #2 | Toolchain: xsim notes, Makefile defaults, `run_sim.tcl` / `build.tcl` |
| #3 | `event_decoder`, `sequence_checker` — 2-cycle proven latency |
| #4 | `make lint-tb` in CI, `make sim-all`, reset-convention fix |
| #5 | `top_of_book`, `feature_engine` — 5-cycle proven latency |

`main` is at `ff6350d`. I have not touched it.

## Open, both yours to merge

**PR #6 — `fix/generator-and-gating`.** The three deferrals from #5: the
generator reaches the book (cancel/trade hits 0 → 169/181), one feature gating
rule, `MOMENTUM_LAG` deleted. CI green.

**PR #7 — `feat/policy-risk`.** `policy_engine`, `risk_gate`, `config_regs`,
the three Python tools, two committed configs, `LATENCY_CYCLES` = 8. CI green.
Skeptic-reviewed: 1 BLOCKER and 5 MAJOR found, all fixed.

| Check | Result |
|---|---|
| `make lint` / `make lint-tb` | clean / clean (12 testbenches) |
| `pytest` | 50 passed |
| `make sim-all` | 12/12 plus generated-trace replay |
| `./scripts/mutate.sh` | **41 mutants, 41 killed** |
| Latency | min = mean = max = **8 cycles** over 2000 events |
| Two configs | 839 vs 1485 trades, 1188/2000 decisions differ, histograms identical |
| Mid-stream commit | 1371 under A, 1441 under B, **0 split** |

## What the reviewer found in #7, in case you only read one thing

- **`risk_gate` failed open.** `next_pos` wrapped at `POS_W`, so a large limit
  plus a large order allowed a trade that should have been refused. Reachable
  through the supported config path. A risk gate that fails open is the one
  failure mode that module exists to prevent.
- **The reason codes did not implement their own purpose.** Every HOLD was
  labelled a suppressed trade (`hold=1619 rejected=1618`). Now 1027.
- **`risk_cfg` was not snapshotted**, so a commit applied new limits to a score
  computed under old weights.

## Not done

- `market_pipeline_top` and the whole integration stage: synthesis, timing
  closure, the five `docs/*.md`, the README.
- **No numbers have been published to a README. There is no README.** The 80 ns
  figure is arithmetic on the oscillator and the testbench log now says so in
  as many words.
- Reset asserted mid-flight is covered per-module, not through the integrated
  chain.
- `train_policy.py` trains on `generate_events` traces while
  `tb_policy_configs` builds its own ladder stimulus. The trained policy does
  trade well on both, but they are different distributions and it would be
  better if they were not.

## Decisions I made alone that you may want to overturn

- **Q3.12 weights, `SCORE_W = 32`.** Weights carry all the feature scaling, so
  `w_spread = 1.0` means "one score unit per tick" — correct but unintuitive.
- **`order_qty` comes from config**, and `risk_gate` checks it against
  `max_order_qty`. That is a misconfiguration guard, not market-aware sizing.
- **The training objective is synthetic** and documented as such: it rewards
  agreement with the next midprice move and penalises churn. It separates
  policies; it does not value them. Nothing claims profitability.
- **Baseline is hand-chosen, not trained**, and says so. It exists to be a
  different policy on a different signal, which is a stronger demonstration
  than two tuner outputs that happen to differ.
- **Two mutants are deliberately absent** from the suite with written reasons:
  the policy saturation clamp and the spread guard's `!book_empty`
  qualification. Both are unkillable for structural reasons, not weak tests.
