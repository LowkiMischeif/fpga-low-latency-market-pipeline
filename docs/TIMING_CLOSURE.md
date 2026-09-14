# Timing closure

Every figure below is copied from a committed report, and the path is given beside
it. Nothing here was measured on a board: these are Vivado post-route analyses.

## Board constraint

- Part `xc7a35tcpg236-1` (Digilent Basys 3), one clock `sys_clk` on pin W5 at
  10.000 ns, no MMCM — `constraints/target_board.xdc`.
- **10.000 ns is the only period this design can run at on this board.** Any
  faster period below is usable only by adding an MMCM.
- Every synchronous path is timed, including reset recovery and removal (the
  `async_default` path group). Every top-level input and output is
  `set_false_path`, with the reason written in the XDC: the buttons and switches
  are asynchronous and either land in synchronizers or are unused, and the LEDs
  and display are read by a person. The build gate fails unless every
  `check_timing` check is zero, and each record below lists them.

## Records

Post-route builds at 10.000 ns, each stamped with the commit it was built from
and whether `rtl/`, `constraints/`, `scripts/build.tcl` and `Makefile` were clean
relative to it (all were):

| Record | Source commit | Result |
|---|---|---|
| `results/iter0_100mhz/GATE_FAILED.md` | `eb59c17` | gate failed: setup −73.898 ns |
| `results/iter1_100mhz/GATE_FAILED.md` | `86ffa17` | gate failed: setup −0.071 ns |
| `results/100mhz/BUILD_SCOPE.md` | `1dfcba9` | **gate passed: setup +0.250 ns** |

The Fmax sweep's records are under `results/sweep/`, with their source commit in
`results/sweep/FMAX.md`.

## Critical-path iteration 1: the reciprocal "ROM" was a divider

### Before — `results/iter0_100mhz/`

| Quantity | Value | Source |
|---|---|---|
| Setup WNS, `sys_clk` | −73.898 ns; 1188 of 4351 endpoints failing | `post_route_timing.rpt` |
| Recovery WNS, `async_default` | −3.742 ns; 265 of 2380 endpoints failing | `post_route_timing.rpt` |
| Worst path | `u_tob/m_book_reg[bid_qty][1]` → `u_feat/recip1_r_reg[0]` | `GATE_FAILED.md` |
| Logic levels | 196 (CARRY4 162, LUT6 30, other 4) | `post_route_timing.rpt` |
| Data path delay | 83.530 ns: logic 42.840 ns, route 40.690 ns | `post_route_timing.rpt` |
| Next distinct path | `u_feat/recip1_r_reg[2]` → imbalance output, −6.623 ns | `post_route_timing_paths.rpt` |
| LUT / FF / BRAM tile / DSP | 2456 / 2387 / 3 / 4 | `post_route_utilization.rpt` |

**Cause.** `rtl/feature_engine.sv` read the reciprocal table as
`recip1 = recip_rom(idx1)`: a call to the constant function in `rtl/market_pkg.sv`
on a *live* index. A constant function is only folded when its arguments are
constant; here synthesis built its body — `(1 << 30) / den_mid`, a 32-bit divide —
as combinational logic, which is the 162-cell carry chain. The table the package
comment describes was never built. Reset recovery also failed in this build; the
reports do not attribute that to the divider, but after the change alone it
passes (below).

### Change — commit `68c4297`

1. **Table built at elaboration.** Each of the 256 entries is a `localparam`
   computed by the same function, in a generate loop, and the live index selects
   among constants.
2. **Numerator normalised in stage 1.** Stage 2 computed
   `(num * recip) >>> (16 − sh)`: a multiply followed by a shifter on a registered
   shift amount — the next distinct path above. Stage 1 now computes `num <<< sh`
   alongside the denominator shift it already had, and stage 2 shifts by a
   constant: `((num << sh) * recip) >>> 16`. The two are the same integer for
   `0 <= sh <= 16` (`scripts/test_imbalance_model.py` checks the identity).

### After — `results/iter1_100mhz/`

| Quantity | Before | After |
|---|---|---|
| Setup WNS, `sys_clk` | −73.898 ns | −0.071 ns (1 of 4342 endpoints failing) |
| Recovery WNS, `async_default` | −3.742 ns | +2.300 ns |
| Worst path, logic levels | 196 | 18 |
| LUT / FF / BRAM tile / DSP | 2456 / 2387 / 3 / 4 | 1675 / 2379 / 3 / 4 |

The divider is gone and the design misses 100 MHz by 71 ps, on a different path.

## Critical-path iteration 2: three carry chains behind one register

### Before — `results/iter1_100mhz/`

| Quantity | Value | Source |
|---|---|---|
| Worst path | `u_pol/m_decision_reg[0]` → `u_risk/position_reg[21]` | `GATE_FAILED.md` |
| Logic levels | 18 (CARRY4 13, LUT 5) | `post_route_timing.rpt` |
| Data path delay | 10.072 ns: logic 5.007 ns, route 5.065 ns | `post_route_timing.rpt` |

**Cause.** In `rtl/risk_gate.sv` the policy decision selected the addend of the
prospective position (`position ± qty`), that sum was compared against the
position limit, the comparison fed the reason chain, and the resulting decision
selected the addend of a *second* adder for the new position. Three carry chains
in series, starting from a register with a fanout of 136
(`post_route_timing.rpt`).

### Change — commit `1dfcba9`

`position + qty` and `position − qty` are computed once, straight from registers.
The limit compares read them directly, and the new position selects between them
instead of adding again. The position update is the low `POS_W` bits of the same
sums, which at `POS_W` is the same value as the previous `position ± qty`, and
each limit compare reads exactly the sum the previous code selected for that
decision. That is the argument that no decision, reason or position changes.

The committed evidence is `tb/tb_risk_gate_equiv.sv`. It holds
`rtl/risk_gate.sv` exactly as it was before this change (at `57fd22d`, renamed),
drives that copy and the committed module with identical, protocol-legal
stimulus, and requires every output and the position to agree on every cycle.
Over 62373 accepted events and 129336 compared cycles there were 0 mismatches
(`results/sim/tb_risk_gate_equiv.txt`). Its coverage floors were met near both
limits: 348 events within one maximum order of the long limit and 567 of the
short limit, 116 buys whose sum exceeds 2**23−1, and 931 `RSN_MAX_LONG` and 1476
`RSN_MAX_SHORT` decisions. A third copy with a planted off-by-one in its
long-limit check was detected, so the comparison is not vacuous.
`tb/tb_risk_gate.sv`, `tb/tb_market_pipeline_top.sv` and the `risk:` mutants,
four of them added for the new sums, also pass. The comparison covers the
stimulus above; it is a simulation, not a formal equivalence proof.

### After — `results/100mhz/`

| Quantity | Before (`iter1_100mhz`) | After (`100mhz`) |
|---|---|---|
| Setup WNS, `sys_clk` | −0.071 ns (1 of 4342 failing) | **+0.250 ns** (0 of 4342 failing) |
| Hold WHS, `sys_clk` | +0.106 ns | +0.122 ns |
| Recovery / removal, `async_default` | +2.300 / +0.764 ns | +2.515 / +0.927 ns |
| Worst path, logic levels | 18 | 9 |
| LUT / FF / BRAM tile / DSP | 1675 / 2379 / 3 / 4 | 1544 / 2379 / 3 / 4 |

Pulse-width slack is 4.020 ns, there are 0 DRC errors, and every `check_timing`
check reports zero (`results/100mhz/BUILD_SCOPE.md`).

Both changes are latency-neutral: no `LAT_*` constant changed and no register was
added. `tb_fixed_latency`, `tb_policy_configs` and `tb_market_pipeline_top` still
measure 8 cycles for every event (`results/sim/`).

## Fmax

**Measured Fmax: 106.4 MHz at 9.4 ns** — `results/sweep/FMAX.md`. Coarse 1.0 ns
steps, then bisection on a 0.1 ns grid; every point synthesized and implemented
against its own period, one run each, published under `results/sweep/p<period>/`.
From `results/sweep/summary.csv`:

| Target period | Result | Setup WNS | Target − WNS |
|---|---|---|---|
| 10.0 ns | pass | +0.250 ns | 9.750 ns |
| 9.5 ns | pass | +0.151 ns | 9.349 ns |
| **9.4 ns** | **pass** | +0.018 ns | 9.382 ns |
| 9.3 ns | fail | −0.139 ns | 9.439 ns |
| 9.2 ns | fail | −0.124 ns | 9.324 ns |
| 9.0 ns | fail | −0.240 ns | 9.240 ns |

**This is the fastest passing period the search found, not a ceiling.** The last
column is the period each routed result would need by the same slack arithmetic:
the 9.2 ns and 9.0 ns attempts routed faster than the passing 9.4 ns run, so a
tighter target produced a faster netlist. Pass and fail are monotonic in this
table (10.0, 9.5 and 9.4 ns pass; 9.3, 9.2 and 9.0 ns fail), but slack is not:
9.3 ns failed by more than 9.2 ns did, and the 9.0 ns run's routed result
corresponds to 9.240 ns. The 9.3 ns failure is therefore a property of that one
run, not a demonstrated limit of the design.

The **slack-derived estimate** from the 10.000 ns build is
`1000 / (10.000 − 0.250)` = 102.6 MHz. It is lower than the measured figure for
the same reason: the sweep's tighter targets routed faster than the 10 ns build
did. The measured figure is the one quoted.

Neither is usable on the Basys 3: its oscillator is fixed at 100 MHz and this
design has no MMCM.

## What limits it now

The worst setup path in `results/100mhz/post_route_timing.rpt` runs from
`u_seq/m_event_reg[symbol][1]_rep` to `u_tob/book_reg[4][bid_price][13]`: 9 logic
levels (CARRY4 1, LUT2 1, LUT4 1, LUT5 2, LUT6 2, MUXF7 1, MUXF8 1), with a
data path delay of 9.526 ns — logic 2.639 ns, **route 6.887 ns (72%)**. The next
worst paths in `post_route_timing_paths.rpt` are the same register driving other
symbols' book entries, mostly `bid_price[13]`. This is the per-symbol book update
in `top_of_book`, and it is dominated by routing rather than logic depth. No
third iteration was applied.

## Assumptions and method

- **Clock uncertainty** is Vivado's default modelling (0.035 ns on the iteration 2
  path, `results/iter1_100mhz/post_route_timing.rpt`). No oscillator jitter figure
  has been measured or entered, so every slack figure here is optimistic by the
  real jitter of the board's oscillator.
- **One implementation run per period, default directives** (`scripts/build.tcl`).
  See the Fmax section for what that means for the measured figure.
- **Scope.** Timing covers every synchronous path in the design on one clock. No
  I/O timing is claimed, because no data crosses a pin on a clock edge.
- **DRC warnings.** `results/100mhz/post_route_drc.rpt` lists no errors and these
  warnings; the gate fails only on Error and Critical Warning:
  - **REQP-1839 ×20**, and **CHECK-3** says that rule hit its report limit, so the
    true count is higher. Asynchronously reset flops drive the trace ROM's block
    RAM address, and Vivado's default timing analysis does not analyse that path.
    The ROM has no write port, so a reset landing on the address can only corrupt
    the word read in that cycle; reset also clears the replay's `busy` and
    `primed` state (`rtl/replay_ctrl.sv`), and a new replay primes the ROM output
    before offering a word.
  - **RBOR-1 ×3**: no block RAM output register. The ROM's read is registered once
    by design (`rtl/trace_rom.sv`).
  - **DPIP-1 ×8, DPOP-1 ×1, DPOP-2 ×4**: DSP blocks without their optional
    internal pipeline registers. `policy_engine`'s three products are already
    registered in the RTL, but those registers were not absorbed into the DSP
    blocks; the committed reports do not say why (one candidate is this design's
    asynchronous reset, which DSP48E1 internal registers do not support).
    `feature_engine`'s product feeds a shift and a clamp before its register, so
    pipelining inside that DSP would add a stage, and latency.
