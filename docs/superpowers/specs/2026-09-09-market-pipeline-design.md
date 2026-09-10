# Design: deterministic market-event decision pipeline

Status: approved, in implementation
Date: 2026-09-09
Target: `xc7a35tcpg236-1` (Digilent Basys 3), Vivado 2026.1, Verilator 5.032

A SystemVerilog pipeline that ingests synthetic market events, maintains a
compact top-of-book model, applies an offline-tuned fixed-point policy, gates
the result against hard risk limits, and emits a decision in a fixed,
assertion-proven number of clock cycles.

This document is the contract the implementation is checked against.
`rtl-skeptic-reviewer` reads it before the integration stage.

---

## 1. Definition of done

The project is finished when all nine goals below hold simultaneously on
`main`, each closed by a committed artifact rather than an assertion in prose.

| # | Goal | Evidence that closes it |
|---|---|---|
| 1 | Events decode correctly; gaps and malformed events are flagged | Randomized replay testbench passes |
| 2 | A trace flows end to end through decode → book → features | End-to-end testbench passes |
| 3 | Input-to-decision latency is fixed | `analyze_latency.py` histogram with min = mean = max |
| 4 | Two policy configurations produce demonstrably different behaviour | Replay comparison table; identical structural latency in both |
| 5 | Risk limits work | Directed tests: position limit, quantity limit, spread guard, kill switch, saturation |
| 6 | The design closes timing on the target part | `results/BUILD_SCOPE.md` generated from a real post-route run |
| 7 | The critical path is understood and documented | `docs/TIMING_CLOSURE.md` with before/after runs and the achieved Fmax |
| 8 | CI runs lint, Python tests, and simulation | Green Actions run with the scaffold guards removed |
| 9 | Docs and README state only measured numbers | Five `docs/*.md`; README figures sourced from `BUILD_SCOPE.md` |

### Explicitly not delivered

- **The 2–3 minute demo video.** Every artifact it would show — waveform,
  latency histogram, config-change comparison, timing and utilization reports
  — is committed and screen-recordable, but the recording itself is out of
  scope.
- **Real exchange connectivity, real market data, or any claim of
  live-trading suitability.** The event source is synthetic by design.
- **Network-to-exchange latency.** Every latency figure in this repo is core
  pipeline latency: `LATENCY_CYCLES * T_clk`, nothing more.
- **"AI" in any sense beyond offline-tuned fixed-point weights** loaded over
  the register bus.

---

## 2. Architecture

```
 64-bit beat
      │
      ▼
┌──────────────┐   market_event_t + event_err_t
│event_decoder │ 1 cycle   field slice, encoding validation
└──────┬───────┘
       ▼
┌──────────────┐
│sequence_check│ 1 cycle   gap / stale classification, resync
└──────┬───────┘
       ▼
┌──────────────┐
│ top_of_book  │ 1 cycle   best bid/ask per symbol
└──────┬───────┘
       ▼
┌──────────────┐
│feature_engine│ 2 cycles  spread, imbalance, momentum (fixed point)
└──────┬───────┘
       ▼
┌──────────────┐
│policy_engine │ 2 cycles  weighted score, threshold compare
└──────┬───────┘
       ▼
┌──────────────┐
│  risk_gate   │ 1 cycle   position / qty / spread limits, kill switch
└──────┬───────┘
       ▼
  decision + reason + ingress/egress timestamps
```

Every stage registers its output exactly once. `market_pkg.sv` is the sole
source of widths, enums and structs; no module declares a magic number.

---

## 3. Interface contract

### 3.1 Event wire format — one 64-bit beat

```
63    56 55  52 51 50 49    34 33   18 17        2 1  0
┌───────┬──────┬────┬────────┬───────┬──────────┬─────┐
│ type  │symbol│side│ price  │  qty  │ seq_id   │ rsv │
│  8b   │  4b  │ 2b │  16b   │  16b  │   16b    │ 2b  │
└───────┴──────┴────┴────────┴───────┴──────────┴─────┘
```

Single beat, so decode is a slice-and-register and the latency claim stays
trivially provable. `rsv` must be zero; a non-zero value is a malformed event.

### 3.2 Handshake — valid/ready, no skid

```systemverilog
assign s_ready = m_ready || !m_valid;
always_ff @(posedge clk)
  if (s_ready) begin m_valid <= s_valid; m_event <= decoded; end
```

Ready propagates combinationally upstream; the pipeline stalls as a unit with
no bubble and no reordering. Rules, which the assertions encode:

- `valid` must not deassert before `ready` is seen (no retraction).
- Payload must be stable while `valid` is high and `ready` is low.
- Latency is exactly `LATENCY_CYCLES` **whenever `ready` is held high**. This
  conditional is part of the claim, not a footnote to it.

The trade-off accepted here: `ready` is a combinational path through the whole
pipe, which will show up as a critical path if the pipeline grows deep. If
timing closure demands it, the fix is skid buffers at named stage boundaries,
which adds a cycle per buffered stage — and `LATENCY_CYCLES` moves with it.
Recorded in `docs/TIMING_CLOSURE.md` if it happens.

### 3.3 Fixed-point convention

- **Price**: 16-bit unsigned, Q14.2 — quarter-tick resolution.
  `PRICE_FRAC_W = 2`.
- **Quantity**: 16-bit unsigned integer, no fractional part.
- **Features and policy arithmetic**: signed, with explicit bit growth at every
  operator and saturation rather than wraparound at every stage boundary.
  Widths are named constants in `market_pkg.sv`; no implicit truncation.
- **No floating point anywhere in `rtl/`.** The Python tooling may use floats
  offline, but everything it exports is quantized to these formats and the
  quantization is checked by `pytest`.

---

## 4. `market_pkg.sv`

Contents, in dependency order:

1. **Field widths** — `EVENT_W`, `TYPE_W`, `SYMBOL_W`, `SIDE_W`, `PRICE_W`,
   `QTY_W`, `SEQ_W`, `RSV_W`, and `PRICE_FRAC_W`.
2. **Enums** — `event_type_e {EVT_ADD, EVT_CANCEL, EVT_TRADE}` and
   `side_e {SIDE_BID, SIDE_ASK}`, each with explicit encodings.
   The enums are deliberately *not* exhaustive over their bit widths: the
   decoder must classify arbitrary garbage, so out-of-range encodings are a
   defined input, not an impossible one. Modules compare against named
   constants and never cast a raw field to an enum.
3. **`market_event_t`** — decoded fields, unpacked.
4. **`event_err_t`** — `bad_type`, `bad_side`, `bad_rsv`, `gap`, `stale`.
   Carried alongside the event rather than encoded into it, because
   `risk_gate` rejects on these and they must survive to the end of the pipe.
5. **Latency constants** — see below.
6. **Symbol universe** — `N_SYMBOLS`, sized by `SYMBOL_W`.

### 4.1 Latency constants — frozen and auditable

`LATENCY_CYCLES` is the sum of named per-stage constants, never a literal.
Each stage's constant is defined only once that stage exists in `rtl/`, so the
constant always equals what the RTL can demonstrate, and the assertion that
checks it moves in the same commit.

```systemverilog
// Input-to-decision latency in clock cycles, for non-stalled traffic
// (m_ready held high). Every stage registers its output exactly once.
//
//   constant      cycles  stage             contribution
//   ------------  ------  ----------------  ----------------------------
//   LAT_DECODE         1  event_decoder     field slice + encoding checks
//   LAT_SEQCHK         1  sequence_checker  gap / stale classification
//   LAT_TOB            1  top_of_book       best bid/ask update      [planned]
//   LAT_FEATURE        2  feature_engine    spread, imbalance        [planned]
//   LAT_POLICY         2  policy_engine     MAC tree + compare       [planned]
//   LAT_RISK           1  risk_gate         limit checks             [planned]
//   ------------  ------
//   LATENCY_CYCLES     2  <- sum of stages implemented today
//
// Stages marked [planned] are not yet in rtl/ and contribute nothing. When a
// stage lands, its constant and its row here are added in the same commit as
// the module, and tb/assertions.sv proves the new total.
localparam int LAT_DECODE     = 1;
localparam int LAT_SEQCHK     = 1;
localparam int LATENCY_CYCLES = LAT_DECODE + LAT_SEQCHK;
```

The design target is 8 cycles. That number appears nowhere in the RTL until
the RTL actually achieves it.

---

## 5. Module specifications

### 5.1 `event_decoder.sv` — 1 cycle

Slices the 64-bit beat into `market_event_t` and validates encodings:
`bad_type` for a `type` outside the defined set, `bad_side` for a `side`
outside `{SIDE_BID, SIDE_ASK}`, `bad_rsv` for non-zero reserved bits.

**Malformed events are flagged and forwarded, never dropped.** The decision to
discard market data belongs to `risk_gate`, where it is visible to the policy
layer and counted in telemetry.

### 5.2 `sequence_checker.sv` — 1 cycle

One global expected-sequence counter (feed-level sequence, not per-symbol).

| Condition | Action |
|---|---|
| `rx == expect` | in order; `expect := rx + 1` |
| `rx > expect` | `gap`, `missed_total += rx - expect`; `expect := rx + 1` |
| `rx < expect` | `stale`; `expect` unchanged |

Two correctness details that are easy to get wrong and are called out here
because the testbench must target them:

- **Wraparound.** `seq_id` is 16 bits and wraps. A magnitude comparison would
  report a ~65000-event gap at every wrap. The comparison computes
  `diff = rx - expect` in 16-bit modular arithmetic and interprets it as
  *signed*: positive is a gap, negative is stale, zero is in order. Correct for
  any real gap below 32768.
- **First event after reset.** The checker adopts the first event's `seq_id`
  as its baseline instead of expecting zero, so a trace that starts mid-stream
  does not report a spurious gap on its first event.

Counters exposed as output ports: `gap_count`, `stale_count`, `missed_total`,
`bad_event_count`. All saturate rather than wrap, so telemetry cannot silently
roll over.

### 5.3 `top_of_book.sv` — 1 cycle

Best bid/ask price and size per symbol, `N_SYMBOLS` entries. Update rules are
stated explicitly per event type and each rule gets a directed test. Reset
clears the book to a defined empty state distinguishable from a real price of
zero.

### 5.4 `feature_engine.sv` — 2 cycles

- `spread = ask - bid`, saturating, with an explicit empty-book result.
- Midprice approximation.
- Imbalance `I = (Q_bid - Q_ask) / (Q_bid + Q_ask)`, bounded to [-1, +1].
  Division is the one place this design cannot avoid real arithmetic cost.
  Implemented as a **LUT-based reciprocal of the denominator followed by a
  multiply** — fixed latency, no variable-iteration divider, no stall. A
  restoring shift-subtract divider was rejected: it either costs one cycle per
  quotient bit or becomes the critical path.
  **Divide-by-zero (empty book, `Q_bid + Q_ask == 0`) returns a defined
  neutral zero**, never an X, and sets a `book_empty` flag so the policy layer
  can tell "balanced" from "no data".
- Momentum: signed difference between the current midprice and the midprice
  `MOMENTUM_LAG` updates ago, held in a small shift register sized by a named
  constant. Fixed depth, fixed latency, saturating.

### 5.5 `policy_engine.sv` — 2 cycles

`score = w0 + w1*spread + w2*imbalance + w3*momentum`, signed fixed point,
saturating at every accumulation. Weights and thresholds arrive over the
register bus. `BUY` if `score > theta_buy`, `SELL` if `score < theta_sell`,
else `HOLD`.

Structural latency is independent of the weight values — that is the whole
point of the "AI customization" claim and it is asserted, not assumed.

### 5.6 `risk_gate.sv` — 1 cycle

Rejects with a reason code on: maximum long position, maximum short position,
maximum order quantity, spread guard, kill switch, and any event carrying
`gap`, `stale`, or a malformed flag from upstream. Reason codes are an enum in
`market_pkg.sv` and appear in telemetry.

### 5.7 `market_pipeline_top.sv`

Wires the stages, exposes the register bus, and emits the decision with
ingress and egress timestamps. Port names are fixed here and the XDC is
updated to match in the same commit — a mismatch silently unbinds the clock
constraint, which `build.tcl` now catches.

---

## 6. Verification strategy

### 6.1 The circularity problem, stated up front

`scripts/generate_events.py` emits both the stimulus and the golden
expectations. If the generator and the RTL are wrong in the same way, the
suite passes and proves nothing. Three independent mitigations:

1. **Hand-written directed vectors** in the testbench — known-good and
   known-bad events with results written by hand, never touched by the
   generator. These are the ground truth.
2. **Property assertions** in `tb/assertions.sv` that hold regardless of the
   trace: latency is exactly `LATENCY_CYCLES` under held `ready`; no output
   without a prior input; output tag matches input tag; no event duplicated or
   dropped; `valid` never retracted. This file exists from the first branch,
   not added later — the latency claim is the headline result, so it is
   asserted from the first stage that has a latency to assert.
3. **`pytest` tests for the generator itself**, including round-tripping the
   hex encoding back into fields.

### 6.2 Randomized replay

Traces are seeded and reproducible (`--seed`; `+SEED` plusarg in the
testbench, echoed into the log so a failure can be replayed exactly). The
driver randomizes `valid` gaps and `ready` deassertions so backpressure is
exercised continuously, not as a special case.

Defect injection rates are parameters: `--gap-rate`, `--stale-rate`,
`--bad-type-rate`, `--bad-side-rate`, `--bad-rsv-rate`.

### 6.3 Failure reporting

A mismatch calls `$fatal`. This matters mechanically: **xsim exits 0 even on
`$fatal`**, so `scripts/run_sim.tcl` scans the captured log for `Fatal:` and
`Error:` lines and fails the build on either. Without that, a red test is a
green build. Verified against a deliberately failing testbench.

---

## 7. Python tooling

| Script | Responsibility |
|---|---|
| `generate_events.py` | Seeded trace generation into `tb/traces/`, plus golden expectations CSV |
| `train_policy.py` | Offline weight/threshold search over a replay dataset |
| `export_config.py` | Quantize trained weights to the RTL fixed-point formats and emit register values |
| `analyze_latency.py` | Parse simulation telemetry into a latency histogram; assert min = mean = max |

All four are covered by `pytest`. `export_config.py` is the boundary where
floats become fixed point, so its quantization is tested against the same
constants the RTL uses — the widths live in one place and both sides read
them.

Traces are generated artifacts and stay gitignored; the generator plus a seed
reproduces them exactly.

---

## 8. Timing and constraints

### 8.1 Board constraint

The Basys 3 oscillator is fixed at 100 MHz with no MMCM in the design, so
`create_clock -period 10.000` is the only rate this design can actually run
at. Latency in nanoseconds is `LATENCY_CYCLES * 10.0`, and no other conversion
is legitimate for a figure describing this board.

### 8.2 Achieved Fmax — an honest ceiling

"Closes at 100 MHz" understates a design that closes with 7 ns of slack.
`docs/TIMING_CLOSURE.md` records two distinct numbers, and the distinction is
the point:

- **Slack-derived estimate**: `Fmax_est = 1000 / (10.0 - WNS)` MHz from the
  100 MHz run. Cheap, and an *upper* bound — the router stops optimizing once
  the constraint is met, so the true achievable frequency is usually lower.
- **Measured Fmax**: re-run synthesis and implementation with the clock period
  tightened stepwise until WNS goes negative. The last period that closes is
  the measured Fmax. This requires `build.tcl` to accept a period override, so
  the clock-bind guard checks the bound period against the *requested* period
  rather than a hardcoded 10.000.

`TIMING_CLOSURE.md` states both, labels which is which, and states plainly
that any Fmax above 100 MHz is a fabric ceiling **not reachable on this board
without adding an MMCM**. The README quotes the measured figure with that
caveat attached, never the estimate alone.

### 8.3 Report hygiene

`build.tcl` stages all reports in `build/reports/` and copies them to
`results/` only after the gate passes: WNS, WHS, pulse width, DRC violation
count, and a non-empty constrained-path list. It generates
`results/BUILD_SCOPE.md` stating the part, the bound clock, the slack figures,
and that they cover register-to-register paths only. `check_timing` output
travels with them as generated evidence of which endpoints are unconstrained.

I/O delays are currently unconstrained. Until pins are assigned, `make build`
cannot reach a bitstream at all — unpinned ports are a UCIO-1 DRC *error*, and
downgrading that check is not an acceptable workaround.

---

## 9. CI

The two scaffold guards in `.github/workflows/test.yml` — the `nullglob` skip
in the lint job and `pytest -q || [ $? -eq 5 ]` — are removed as soon as
`rtl/market_pkg.sv` and the first Python test exist. Until then a green run
proves only that the workflow executes.

Vivado is not available on GitHub-hosted runners, so CI runs Verilator lint
and `pytest`. Simulation runs locally through `make sim` and its log is
attached to the pull request that changes RTL.

---

## 10. Delivery sequence

Four branches, each a pull request, each reviewed by
`rtl-verification-engineer` then `rtl-skeptic-reviewer` with all BLOCKER and
MAJOR findings fixed before merge.

| Branch | Contents |
|---|---|
| `feat/decode-validate` | `market_pkg`, `event_decoder`, `sequence_checker`, `generate_events.py`, `tb_event_decoder`, `tb/assertions.sv`, CI guards removed |
| `feat/book-features` | `top_of_book`, `feature_engine`, `analyze_latency.py` |
| `feat/policy-risk` | `policy_engine`, `risk_gate`, register bus, `train_policy.py`, `export_config.py` |
| `feat/integration-timing` | `market_pipeline_top`, full XDC with I/O delays, timing closure, five docs, README |

`LATENCY_CYCLES` grows across all four as a running sum, so the stated number
never outruns the assertion that proves it.

---

## 11. Known risks

| Risk | Mitigation |
|---|---|
| Generator and RTL wrong in the same way | Hand-written directed vectors and trace-independent property assertions |
| Combinational `ready` becomes the critical path | Named skid-buffer insertion points; `LATENCY_CYCLES` moves with them; recorded in `TIMING_CLOSURE.md` |
| Imbalance division dominates the critical path | Bounded fixed-latency approximation, not a variable-latency divider |
| A number reaches the README that no run produced | README figures come from generated `BUILD_SCOPE.md`; `build.tcl` publishes nothing that has not passed the gate |
| Sequence wraparound treated as a gap | Signed modular comparison, with a directed test that crosses the wrap |
