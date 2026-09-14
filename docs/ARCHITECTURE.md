# Architecture

A deterministic market-event decision pipeline in SystemVerilog, built for the
Digilent Basys 3 (xc7a35tcpg236-1). Synthetic events in, one decision per event
out, after a fixed number of clock cycles. Nothing here connects to an exchange,
and no bitstream from this repository has been run on a board.

The contract every module is built to is
`docs/superpowers/specs/2026-09-09-market-pipeline-design.md`; the integration
is specified in `docs/superpowers/specs/2026-09-13-integration-timing-design.md`.
`rtl/market_pkg.sv` is the single source of every width, encoding, struct and
latency constant.

## The pipeline

```
 64-bit event beat
        |
  event_decoder     LAT_DECODE    field slice, encoding checks
        |
  sequence_checker  LAT_SEQCHK    gap / stale classification, resync
        |
  top_of_book       LAT_TOB       best bid and ask, per symbol
        |
  feature_engine    LAT_FEATURE   spread, mid, imbalance, momentum
        |
  policy_engine     LAT_POLICY    weighted score, two threshold compares
        |
  risk_gate         LAT_RISK      kill switch, limits, net position
        |
  decision_t: decision, reason, order_qty, score, position
```

| Module | Responsibility | Latency constant |
|---|---|---|
| `rtl/event_decoder.sv` | Slices the beat into `market_event_t`; flags an unknown type, an unknown side or non-zero reserved bits in `event_err_t`. | `LAT_DECODE` |
| `rtl/sequence_checker.sv` | Compares each sequence number with the expected one; flags gaps and stale events, and resynchronises after a run of stale events. | `LAT_SEQCHK` |
| `rtl/top_of_book.sv` | Keeps the best bid and ask for each of `N_SYMBOLS` symbols. Only trusted, in-sequence events update the book. | `LAT_TOB` |
| `rtl/feature_engine.sv` | Spread, midprice, order-book imbalance (normalise, reciprocal table, multiply) and per-symbol momentum, with one gating rule: an empty book zeroes every feature. | `LAT_FEATURE` |
| `rtl/policy_engine.sv` | Fixed-point weighted score and BUY / SELL / HOLD. Snapshots the configuration per event (below). | `LAT_POLICY` |
| `rtl/risk_gate.sv` | Suppresses a trade on kill, malformed input, a sequence error, an empty book, a wide spread, an oversize order or a position limit, and records the reason; tracks net position. | `LAT_RISK` |
| `rtl/config_regs.sv` | Register bus for weights, thresholds and limits: shadow copy plus commit. | not in the data path |

The latency constants and their sum, `LATENCY_CYCLES`, are defined in
`rtl/market_pkg.sv`. The measurements that back them are in
[`docs/LATENCY.md`](LATENCY.md).

Arithmetic is fixed point throughout `rtl/`. The formats (Q14.2 prices, Q1.14
imbalance, Q3.12 weights) are named constants in `rtl/market_pkg.sv`, and the
policy's weighted sum is computed wide enough that it cannot wrap, then
saturated to `SCORE_W`.

## Handshake: valid/ready with no skid buffer

Every stage uses the same rule (spec §3.2):

```systemverilog
assign s_ready = m_ready || !m_valid;
```

Two-stage modules generalise it as `advance = m_ready || !v2` and move both
registers together. `ready` is therefore combinational through the whole
pipeline: the pipeline stalls as a unit, with no bubble and no reordering, and
the latency is exactly `LATENCY_CYCLES` **whenever the downstream `m_ready` is
held high**. That condition is part of the claim. Inside `market_pipeline_top`,
`risk_gate`'s `m_ready` is tied high, so every event that reaches the output of
the integrated design takes exactly `LATENCY_CYCLES` (an event still in flight
when reset is asserted is discarded, not delayed); `tb/tb_market_pipeline_top.sv`
measures it.

The cost is a combinational `ready` path through every stage. If it ever became
the critical path, the fix named in the spec is skid buffers at chosen stage
boundaries, and `LATENCY_CYCLES` would move with them.

## Configuration and atomicity

Two mechanisms, each for its own problem:

1. **A batch of register writes lands together.** `rtl/config_regs.sv` holds
   every write in a shadow copy; writing `CFG_COMMIT` makes the whole shadow
   active on one edge.
2. **Each event is decided by exactly one configuration.** `rtl/policy_engine.sv`
   captures the active weights, thresholds, order size **and the risk limits**
   on the edge it accepts an event, and carries the risk limits to
   `rtl/risk_gate.sv` alongside the event. A commit that lands while events are
   in flight cannot score an event with half of one weight set, or apply new
   limits to a score computed under old weights.

This per-event snapshot is the atomicity mechanism. There is no separate
"safe to swap" handshake: an earlier one was deleted after forcing it high was
shown to change no output. A consequence, stated in the spec: a kill-switch
commit is not retroactive. Events already past `policy_engine`'s accept edge
finish under the configuration they were accepted with.

Configuration reaches the arithmetic only. No weight, threshold or limit
appears in a valid, ready or enable expression, so no configuration can change
when an event emerges. See [`docs/AI_POLICY.md`](AI_POLICY.md).

## The Basys 3 top

`rtl/market_pipeline_top.sv` wraps the pipeline for a board with buttons,
switches, LEDs and a four-digit display, and no data interface:

```
 btnU --> reset_sync --> rst_n (every module with state)

 btnC --> replay_ctrl <-- trace_rom (generated trace, block RAM)
               |
               v
          pipeline ... risk_gate --> BUY / SELL / reject counters --> led, seg7_display

 sw[0] --> cfg_loader (two preset ROMs) --> config_regs --> policy_engine
```

| Module | What it does |
|---|---|
| `rtl/reset_sync.sv` | The design's only reset synchronizer: asserts asynchronously, releases through two flops. |
| `rtl/trace_rom.sv` | The on-chip event trace, initialised from `rtl/mem/rom_trace.mem`, which `scripts/generate_events.py` writes. Registered read. |
| `rtl/replay_ctrl.sv` | On a press, walks the ROM into the pipeline once, with no bubble or duplicate under backpressure. The lockout restarts on every cycle the button reads high, so it expires only after the button has been released for the whole window, covering bounce on both press and release. Ignores a press during a replay, during the lockout, or while a configuration load is due or running. |
| `rtl/cfg_loader.sv` | On reset release and whenever `sw[0]` changes, writes the selected preset (`rtl/mem/rom_cfg_baseline.mem` or `rtl/mem/rom_cfg_tuned.mem`) into `config_regs`, ending with the commit. A load that becomes due during a replay waits for the replay to end. That is a timing margin, not a structural guarantee: with the output never stalled, `policy_engine` snapshots the last replayed event 5 clock edges after it is accepted, while the loader starts one edge after the replay ends and `config_regs` applies the preset's commit 15 edges after it (13 register writes, `N_CFG` in the module), so that event is still decided under the old preset. |
| `rtl/seg7_display.sv` | Multiplexed hex display, active low. |

The LEDs show the low bytes of the SELL and BUY counts; the display shows the
reject count in hex. All three counters clear when a replay starts. The
sequence and commit telemetry counters stay connected but have nowhere to be
shown on this board. `sw[15:1]` are pinned and unused.

## Reset

Every module with state resets asynchronously on `negedge rst_n` (spec §3.3).
The two exceptions are `rtl/trace_rom.sv`, a block RAM with no reset, and
`rtl/reset_sync.sv` itself, which asserts on the button's rising edge. An
asynchronously *released* reset can violate recovery/removal on the target part
and drop flops out of reset on different cycles, so `rtl/reset_sync.sv` is
instantiated once, where the pushbutton enters the design. Its output is
released on a clock edge, and Vivado times that release as recovery and removal
against the one clock.

## Clock and I/O constraints

`constraints/target_board.xdc` defines one clock, on the board's fixed 100 MHz
oscillator, with no MMCM. Every input is a button or switch, asynchronous by
nature, and either lands in a synchronizer or is unused; every output is read by
a person. Neither kind has a clock-edge relationship to constrain, so both are
`set_false_path` with the reason written beside them, rather than given input or
output delays that would describe hardware that does not exist. Every
synchronous path inside the design is timed. Results and their scope are in
[`docs/TIMING_CLOSURE.md`](TIMING_CLOSURE.md).
