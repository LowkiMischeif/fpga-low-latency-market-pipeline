# Status

Written for Tyler returning to the project. Updated 2026-09-13.

## The three things to look at first

1. **The reciprocal "ROM" in `feature_engine` was a 32-bit divider, and no
   simulation could have shown it.** `recip1 = recip_rom(idx1)` called the
   package's constant function on a live index, so synthesis built the function
   body: WNS −73.898 ns at 100 MHz, 196 logic levels
   (`results/iter0_100mhz/GATE_FAILED.md`). Every testbench and mutant passed
   throughout, because the arithmetic was right. It took the first real build to
   find, and a second latency-neutral iteration in `risk_gate` to close timing.
   The whole trail is in `docs/TIMING_CLOSURE.md`.

2. **I committed the integration top (now `2f00873`) before its skeptic
   review, against the CLAUDE.md workflow.** The review, run afterwards, found
   four MAJOR problems, all fixed in later commits on the branch:
   - button bounce on release started a second replay;
   - the build gate's pulse-width check could never fail, yet every build
     record said "pulse-width clean";
   - a failed or aborted build left an earlier passing result in `results/`;
   - the first "before" record was built from a scratch tree that no longer
     existed.

   A later review of the docs found the same kind of flaw in the first version
   of `scripts/test_readme_citations.py`: it passed with a wrong WNS in the
   README. It now compares every results cell exactly with its linked file.
   Worth your eye because checks that cannot fail are the failure mode this
   project keeps meeting.

3. **#7 and #8 were rebased and force-pushed before merging.** After #6 was
   squash-merged, #7 conflicted in `scripts/mutate.sh` because its branch still
   carried #6's individual commits. As you directed, each branch was rebased onto
   `main` with `--onto`, dropping the already-merged commits; before each
   `--force-with-lease` push the rebased tree was confirmed identical to the
   reviewed PR head (`git diff` empty), and CI was green before each merge.

## Merged on `main` (at `cd3065e`)

| PR | What |
|---|---|
| #1 | Verible LSP plugin and lint rules |
| #2 | Toolchain: xsim notes, Makefile defaults, `run_sim.tcl` / `build.tcl` |
| #3 | `event_decoder`, `sequence_checker` — 2-cycle proven latency |
| #4 | `make lint-tb` in CI, `make sim-all`, reset-convention fix |
| #5 | `top_of_book`, `feature_engine` — 5-cycle proven latency |
| #6 | Generator reaches the book, one feature gating rule, `MOMENTUM_LAG` deleted |
| #7 | `policy_engine`, `risk_gate`, `config_regs`, policy tooling — 8-cycle latency |
| #8 | `cfg_boundary` deleted; per-event snapshot pinned; `mutate.sh` baseline gate |

## Open: the pull request for `feat/integration-timing`

`market_pipeline_top` for the Basys 3, with on-chip trace replay and config
presets; the full XDC; a gated build flow and Fmax sweep; two critical-path
iterations; `docs/ARCHITECTURE.md`, `docs/LATENCY.md`, `docs/VERIFICATION.md`,
`docs/TIMING_CLOSURE.md`, `docs/AI_POLICY.md`; the README.

| Check | Result |
|---|---|
| Top level vs the verified pipeline | 6000 decisions matched, 7000 events at 8 cycles across a mid-replay reset — `results/sim/tb_market_pipeline_top.txt` |
| Latency | 8 cycles for all 2000 events; identical under both policies — `results/sim/analyze_latency.txt`, `results/sim/analyze_latency_configs.txt` |
| Simulation and Python at `1dfcba9` | sim-all: 17 testbenches plus the generated-trace replay; pytest 56 passed — `results/sim/sim_all.txt`, `results/sim/pytest.txt` |
| Post-route timing at 100 MHz | setup WNS +0.250 ns, hold WHS +0.122 ns, 0 DRC errors — `results/100mhz/BUILD_SCOPE.md` |
| Measured Fmax | 106.4 MHz at 9.4 ns: the fastest passing period of the sweep, not a ceiling, and not usable on the board — `results/sweep/FMAX.md` |
| Mutation testing | 87 of 87 killed, 0 survived — `results/sim/mutation.txt` |

## Not done

- **Nothing has run on a board.** Every result is simulation or post-route
  analysis, and the README says so.
- **Oscillator jitter is not modelled.** Slack is optimistic by the real jitter.
- **Latency under backpressure is not claimed.** Inside the Basys 3 top the
  output is never stalled, so the fixed-latency condition always holds there.
- **No committed equivalence check for the `risk_gate` restructure.** The
  argument is in `docs/TIMING_CLOSURE.md`; the evidence is that every testbench
  and mutant passes on the new RTL. A reviewer's differential simulation found no
  mismatch, but it lives only in scratch.
- `train_policy.py` trains on `generate_events` traces while
  `tb_policy_configs` builds its own ladder stimulus. Different distributions;
  still true from #7.

## Decisions I made alone that you may want to overturn

- **No I/O delays.** Every button, switch, LED and display pin is
  `set_false_path` with the reason in the XDC, per the approved integration spec.
  If a future board has a real data interface, it will need real I/O constraints.
- **Two latency-neutral timing fixes, no implementation directives.** Both
  iterations changed RTL structure (constant table and constant shift in
  `feature_engine`; precomputed sums in `risk_gate`) rather than turning on
  Vivado's aggressive directives, so the result does not rely on non-default
  directives. It still depends on the tool version and placement.
- **`busy` from the config loader includes a load that is due**, and a load
  waits for a running replay. A switch change takes effect only after the replay
  ends.
- **Two more mutants were moved to NOT LISTED**, each with the argument written
  in `scripts/mutants.txt`: a level-sensitive button press, which the fixes
  above made equivalent, and a one-cycle "busy gap", which now only starts a
  second load a cycle later — observable, but required by nothing. That makes
  four with the two from #7 (policy saturation clamp, spread guard
  qualification); all four are listed in `docs/VERIFICATION.md`.
- **Failing builds are kept as records.** `PUBLISH_FAILED=1` publishes a failing
  run as `GATE_FAILED.md`; the two "before" records are committed that way.
- **An accidental full build ran once.** An unquoted empty Makefile argument
  shifted the run name to `0` during a guard test; it was killed before it
  published anything, and the Makefile now quotes its arguments and `build.tcl`
  refuses any argument count but 0 or 4.
