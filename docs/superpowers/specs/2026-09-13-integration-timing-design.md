# Design: integration, timing closure, and documentation

Status: approved, pending implementation plan
Date: 2026-09-13
Parent: `docs/superpowers/specs/2026-09-09-market-pipeline-design.md` (the contract; this document extends §5.7, §8 and §10's final stage)
Branch: `feat/integration-timing`

The last stage of the plan: put the six verified stages and `config_regs` under
one synthesizable top, constrain it for the Basys 3, close timing with real
reports, and write documentation whose every number cites a committed artifact.

---

## 1. Decisions already taken

| Decision | Choice | Consequence |
|---|---|---|
| How events enter and decisions leave | On-chip trace ROM and replay; decisions to LEDs and 7-seg | No data crosses a pin synchronously. The XDC documents that instead of stating I/O delays for a device that does not exist |
| Where the ROM and presets come from | `.mem` files written by `generate_events.py` and `export_config.py`, loaded with `$readmemh` | The bitstream, the testbenches and the committed configs read the same files |
| Hardware | No board run | The README may claim a timing-clean, DRC-clean bitstream and nothing observed on hardware |
| Latency under timing iteration | `LATENCY_CYCLES` stays 8 | A critical-path change must be latency-neutral; a fix that needs a register is recorded as analysed, not applied |
| CI guards | None remain | Both scaffold guards were removed in #3; nothing to do but say so |

## 2. `market_pipeline_top.sv`

Ports, all Basys 3 pins from Digilent's Basys-3-Master.xdc, which is labelled Rev B:

| Port | Pin(s) | Role |
|---|---|---|
| `clk` | W5 | 100 MHz oscillator, the only clock |
| `btnU` | T18 | Reset, into the reset synchronizer |
| `btnC` | U18 | Start replay |
| `sw[15:0]` | board switches | `sw[0]` selects the config preset; the rest spare |
| `led[15:0]` | board LEDs | Decision counters (low byte BUY, high byte SELL) |
| `seg[6:0]`, `dp`, `an[3:0]` | 7-seg | Rejected-decision count, hex |

Internal structure:

- **`reset_sync`** — asynchronous assert, two-flop synchronous deassert, the
  single synchronizer §3.3 promised. Every module below it keeps its
  asynchronous reset.
- **`trace_rom`** — `N_TRACE` × `EVENT_W` ROM, inferred as BRAM, initialised
  from `rom_trace.mem`.
- **`replay_ctrl`** — two-flop synchronizer and rising-edge detect on `btnC`;
  walks the ROM once per press, presenting `s_data`/`s_valid` and holding while
  `s_ready` is low.
- **`cfg_loader`** — on reset release, and whenever the synchronized preset
  switch changes, writes the selected preset's register sequence into
  `config_regs`, ending with `CFG_COMMIT`. The preset ROMs are initialised from
  `rom_cfg_baseline.mem` and `rom_cfg_tuned.mem`.
- The six pipeline stages and `config_regs`, wired as in `tb_policy_configs`.
- **Decision counters** feeding the LEDs and 7-seg, updated on each handoff out
  of `risk_gate`.

## 3. Constraints — `constraints/target_board.xdc`

- `create_clock -period 10.000` on W5.
- `PACKAGE_PIN` and `IOSTANDARD LVCMOS33` for every port above.
- **Asynchronous inputs** (`btnU`, `btnC`, `sw`): `set_false_path -from`, each
  with a written reason — the signal is asynchronous to `sys_clk` by nature and
  lands in a two-flop synchronizer, so a setup relationship to the clock does not
  exist to constrain.
- **Human-scale outputs** (`led`, `seg`, `an`, `dp`): `set_false_path -to`, with
  the reason that nothing samples them synchronously.
- **No `set_input_delay` or `set_output_delay`.** The XDC says why: with
  on-chip stimulus, no data crosses a pin on a clock edge, and a delay value
  would describe an external device that is not there.
- **Reset recovery/removal**: timed by Vivado's standard analysis of the
  synchronized reset net, and cited in `TIMING_CLOSURE.md` from the report.
- **Clock uncertainty**: left at Vivado's default modelling, stated explicitly
  as an assumption in `TIMING_CLOSURE.md` with the slack margin it would
  consume, rather than a jitter figure that has not been read off the board.

## 4. Build, reports, and Fmax

- `scripts/build.tcl` gains a `PERIOD` argument (default 10.000). The
  clock-bind guard checks the bound period against the requested one.
- `make build` runs at 10.000 ns and publishes to `results/100mhz/`:
  `report_timing_summary`, `report_utilization`, `check_timing`,
  `report_methodology`, DRC, and `BUILD_SCOPE.md`.
- `make fmax` steps the period down from 10.000 ns until a run fails the gate,
  publishing each passing run to `results/sweep/<period>/`. The last closing
  period is the **measured Fmax**.
- `TIMING_CLOSURE.md` reports the measured Fmax next to the slack-derived
  estimate `1000 / (10.0 - WNS)`, labelled as an upper bound, and repeats §8.2's
  caveat: anything above 100 MHz is a fabric ceiling this board cannot use
  without an MMCM.

## 5. Critical-path iteration

1. Build at 100 MHz; record the worst setup path from the committed report.
2. Take the path that fails first in the sweep.
3. Apply one latency-neutral change aimed at it: restructuring logic, DSP
   inference, moving work within a stage, or an implementation directive.
4. Rebuild and re-sweep. Record path, slack and Fmax before and after in
   `TIMING_CLOSURE.md`, with both report sets committed.
5. Re-run `make sim-all` and `./scripts/mutate.sh`; the change must not move
   any latency proof.

If the only effective fix needs a pipeline register, it is recorded as analysed
with its projected Fmax and **not applied**.

## 6. Verification

- **`tb_market_pipeline_top`** drives the real top from the same `.mem` files
  and requires:
  - each preset's decision counts to match the counts the existing testbenches
    produce for that trace and config;
  - latency from ROM output to decision handoff to equal `LATENCY_CYCLES`;
  - reset released through the synchronizer to leave every stage idle with the
    kill switch on until `cfg_loader` commits.
- Mutants on `reset_sync`, `replay_ctrl` and `cfg_loader`, behind the baseline
  gate `scripts/mutate.sh` now enforces.
- Added to `make lint`, `make lint-tb` and `make sim-all`.

## 7. Documentation

| File | Content | Number sources |
|---|---|---|
| `docs/ARCHITECTURE.md` | Stage diagram, interfaces, snapshot and reset conventions | RTL constants |
| `docs/LATENCY.md` | Per-stage table, histogram, what "fixed" is conditional on | `market_pkg.sv`, `tb_fixed_latency` log |
| `docs/VERIFICATION.md` | Testbench map, assertion list, mutation tally and the two deliberate absences | `scripts/mutants.txt`, `make sim-all` log |
| `docs/AI_POLICY.md` | Offline search, quantisation, the synthetic objective and what it is not | `train_policy.py`, `tb/configs/`, `tb_policy_configs` log |
| `docs/TIMING_CLOSURE.md` | 100 MHz run, sweep, iteration before/after, measured Fmax | `results/` reports |
| `README.md` | Results table and project summary | Every figure links to one of the above artifacts |

The README is written last and reviewed by `rtl-skeptic-reviewer` on its own
before the PR opens.

## 8. Explicitly not claimed

- Anything observed on physical hardware.
- I/O timing closure against an external device.
- Any Fmax above 100 MHz as usable on the Basys 3.
- Network, exchange, or live-trading suitability.
