# Verification

Everything here is simulation (Vivado xsim), lint (Verilator) and Python tests.
The SystemVerilog assertions are checked in simulation, not proven formally, and
**no bitstream from this repository has been run on hardware.**

```
make lint lint-tb      # every rtl/ module and every testbench, Verilator -Wall
make pytest            # scripts/test_*.py
make sim-all           # every testbench, then the generated-trace replay
./scripts/mutate.sh    # mutation testing, below
```

## The circularity problem, and the answer to it

`scripts/generate_events.py` writes both the randomized stimulus and the
expected results, so a bug in the generator and the same bug in the RTL would
agree (spec §6.1). Four things stand against that:

1. **Hand-written directed testbenches** for every module, whose vectors never
   pass through the generator.
2. **Trace-independent assertions** (`tb/assertions.sv`), which reference no
   expected value at all.
3. **Re-derivation.** `tb/tb_decode_validate.sv` re-derives every golden row from
   the raw 64-bit word, from the spec's own tables, before driving an event.
4. **The top-level oracle is the verified chain, not a new model.**
   `tb/tb_market_pipeline_top.sv` feeds a second, separately instantiated copy of
   the six stages the same ROM image, configured from the committed `.cfg` files
   rather than the `.mem` images the top uses, and requires the two decision
   streams to match event for event.

## Testbenches

| Testbench | What it proves |
|---|---|
| `tb/tb_market_pkg.sv` | Every exported package symbol elaborates; the event fields tile the beat. |
| `tb/tb_event_decoder.sv` | Field placement and every encoding check, against the spec's literals rather than the package's own validators. |
| `tb/tb_sequence_checker.sv` | 16-bit wraparound, the signed-comparison boundary, first event after reset, resync, counter saturation. |
| `tb/tb_decode_validate.sv` | Randomized replay through decode and sequence check with random valid gaps and backpressure, scored against re-derived expectations. |
| `tb/tb_top_of_book.sv` | Every row of the update table, the trust gate, per-symbol independence, a real price of zero. |
| `tb/tb_feature_engine.sv` | Crossed, empty and zero-size books; imbalance accuracy swept against exact division; stalls. |
| `tb/tb_book_features.sv` | Randomized integrated replay through book and features against a reference model, with coverage floors; also replays a generated trace. |
| `tb/tb_policy_engine.sv` | Score arithmetic, and the per-event configuration snapshot under changes after accept, back-to-back accepts and a stall holding an event inside the snapshot stage. |
| `tb/tb_risk_gate.sv` | Every limit and reason code, position arithmetic at the width limit, the spread guard's empty-book qualification. |
| `tb/tb_config_regs.sv` | Writes stay in the shadow until commit; a batch lands on one edge. |
| `tb/tb_fixed_latency.sv` | End-to-end latency, every event, across all six stages. See `docs/LATENCY.md`. |
| `tb/tb_policy_configs.sv` | Two committed policies: different decisions, identical latency; a commit mid-stream never produces a decision matching neither. |
| `tb/tb_reset_sync.sv` | Asynchronous assert, release on exactly the second edge, restart on re-assert. |
| `tb/tb_replay_ctrl.sv` | Every ROM word once, in order, under random backpressure; a press refused mid-replay, in lockout and under hold-off, each tested with the other two guards out of the way. |
| `tb/tb_cfg_loader.sv` | Each preset loads on reset release and on a switch change, matching the committed `.cfg`, with no settle cycle after `busy` falls. |
| `tb/tb_seg7_display.sv` | Every hex digit's segment pattern, one anode at a time, each nibble on its own anode. |
| `tb/tb_market_pipeline_top.sv` | The synthesizable top against the reference chain, both presets, book carried across replays; latency inside the top; a press during a preset load refused. |

Pass lines for the full run: `results/sim/sim_all.txt`.

## Assertions

`tb/assertions.sv` defines `handshake_checker`; `tb/bind_assertions.sv` binds it,
exactly once each, to all six pipeline stages. Each property records which
testbench exercises its antecedent, because a property that never fires proves
nothing.

| Property | Holds that |
|---|---|
| tag queue | the stage is a FIFO: tags leave in the order they entered, none dropped or duplicated |
| `a_no_valid_retraction_in`, `a_no_valid_retraction_out` | an offer is not withdrawn before `ready` |
| `a_in_payload_stable`, `a_out_payload_stable` | an offered payload does not change during a stall |
| `a_no_x_when_valid` | an offered payload has no X or Z |
| `a_fixed_latency` | the event accepted at T is the one presenting at T + `LATENCY`, with the output drainable |
| `a_no_early_output` | an empty stage offers nothing |
| `a_no_spontaneous_output` | a stage never emits more than it accepted |
| `a_bounded_in_flight` | a stage never holds more than `LATENCY` events |
| `a_queue_matches_counters` | the queue model and the counters agree |

`a_fixed_latency` is hidden from Verilator, which cannot parse a parameterised
cycle delay; xsim evaluates it.

## Mutation testing

`scripts/mutate.sh` applies each single-line mutation in `scripts/mutants.txt` to
`rtl/`, runs the testbench named for it, and restores the file. A mutant that
survives is a behaviour the suite does not check.

- **Baseline gate.** Before any mutation, every testbench the selected mutants
  target must pass unmutated, or the run aborts (exit 2). Without it a testbench
  that does not elaborate scores every mutant aimed at it as a kill, and that
  happened once.
- **A kill needs a simulation that ran and failed.** A mutant whose replacement
  does not compile is reported as `DOES NOT BUILD` and counted as a failure, not
  a kill. A filter that matches nothing exits 3.

TALLY_PENDING

**Deliberately absent mutants**, with the reasons recorded in
`scripts/mutants.txt`:

- *Policy saturation clamp removed.* At these widths the score cannot reach the
  `SCORE_W` rail, so no stimulus can tell a saturating add from a plain one.
  `tb/tb_policy_engine.sv` pins the achievable range instead, so the mutant
  becomes listable if that range ever grows.
- *Spread guard not qualified by an empty book.* Reason precedence tests the
  empty book first, so the qualification is shadowed and removing it changes no
  output. `tb/tb_risk_gate.sv` asserts the observable property instead.

## Python

`scripts/test_*.py`, run by `pytest` locally and in CI. Among them:
`scripts/test_imbalance_model.py` is the exhaustive reference for the reciprocal
approximation and checks that the constant-shift form in `rtl/feature_engine.sv`
equals the variable-shift form; `scripts/test_mem_files.py` checks the committed
ROM images byte for byte against the tools that write them.

## Continuous integration

`.github/workflows/test.yml` runs `make lint`, `make lint-tb` and `pytest` on
every pull request. Simulation needs Vivado, so `make sim-all` and
`scripts/mutate.sh` run locally and their output is committed under
`results/sim/`.

## Not covered

- No hardware run.
- No formal proof; the assertions are simulation checks.
- Latency under backpressure is not claimed (`docs/LATENCY.md`).
- Oscillator jitter is not modelled in timing (`docs/TIMING_CLOSURE.md`).
