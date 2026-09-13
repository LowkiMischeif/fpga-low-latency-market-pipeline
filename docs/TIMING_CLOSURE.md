# Timing closure

Every figure below is copied from a committed report, and the path is given beside
it. Nothing here was measured on a board: these are Vivado post-route analyses.

## Board constraint

- Part `xc7a35tcpg236-1` (Digilent Basys 3), one clock `sys_clk` on pin W5 at
  10.000 ns, no MMCM — `constraints/target_board.xdc`.
- **10.000 ns is the only period this design can run at on this board.** Any Fmax
  above 100 MHz below is a fabric ceiling, reachable only by adding an MMCM.
- Every synchronous path is timed, including reset recovery and removal (the
  `async_default` path group). Every top-level input and output is
  `set_false_path`, with the reason written in the XDC: the buttons and switches
  are asynchronous and land in synchronizers, and the LEDs and display are read
  by a person. The build gate fails unless every `check_timing` check is zero,
  and `BUILD_SCOPE.md` in each passing run records the result.

## Critical-path iteration 1: the reciprocal "ROM" was a divider

### Before

BEFORE_PENDING — from `results/iter0_100mhz/GATE_FAILED.md` and the reports beside
it: setup and recovery slack per path group, failing endpoints per group, the
worst path with its logic levels and logic/route split, and utilisation.

**Cause.** `rtl/feature_engine.sv` read the reciprocal table as
`recip1 = recip_rom(idx1)`: a call to the constant function in `rtl/market_pkg.sv`
on a *live* index. A constant function is only folded when its arguments are
constant; here synthesis built its body — `(1 << 30) / den_mid`, a 32-bit divide —
as combinational logic. The table the package comment describes was never built.

### Change

Latency-neutral, in `rtl/feature_engine.sv`, commit AFTER_PENDING:

1. **Table built at elaboration.** Each of the 256 entries is a `localparam`
   computed by the same function, in a generate loop, and the live index selects
   among constants.
2. **Numerator normalised in stage 1.** Stage 2 computed
   `(num * recip) >>> (16 − sh)`: a multiply, then a shifter driven by a
   registered shift amount. Stage 1 now computes `num <<< sh` alongside the
   denominator shift it already had, and stage 2 shifts by a constant:
   `((num << sh) * recip) >>> 16`. The two are the same integer for
   `0 <= sh <= 16` (`scripts/test_imbalance_model.py` checks the identity).

No `LAT_*` constant changed and no register stage was added. The evidence that
the RTL is still correct is the `feature_engine` unit and integrated testbenches
and the `feat:` mutants, including sign-extension and width mutants of the new
normalisation (`scripts/mutants.txt`); the latency testbenches still measure 8
cycles.

### After

AFTER_PENDING — `results/100mhz/BUILD_SCOPE.md`, `results/100mhz/post_route_utilization.rpt`

## Fmax

AFTER_PENDING — slack-derived estimate from `results/100mhz/BUILD_SCOPE.md`,
measured Fmax from `results/sweep/FMAX.md`, every run in `results/sweep/summary.csv`

## What limits it now

AFTER_PENDING — worst path from `results/100mhz/post_route_timing.rpt`

## Assumptions and method

- **Clock uncertainty** is Vivado's default modelling. No oscillator jitter figure
  has been measured or entered, so every slack figure here is optimistic by the
  real jitter of the board's oscillator.
- **One implementation run per period, default directives** (`scripts/build.tcl`).
  The Fmax search (`scripts/fmax_sweep.sh`) assumes that closure is monotonic in
  the period; placement varies between periods, and `results/sweep/summary.csv`
  records every run so a non-monotonic result is visible.
- **Scope.** Timing covers every synchronous path in the design on one clock. No
  I/O timing is claimed, because no data crosses a pin on a clock edge.
- **DRC warnings.** `post_route_drc.rpt` lists warnings on the trace ROM:
  REQP-1839 (asynchronously reset flops drive the block RAM address) and RBOR-1
  (no block RAM output register). Both concern a read-only ROM read into a
  registered pipeline and do not block the bitstream; the gate fails only on
  Error and Critical Warning severities.
