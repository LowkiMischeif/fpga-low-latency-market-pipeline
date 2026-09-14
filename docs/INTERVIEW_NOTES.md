# Interview notes

Ten questions I expect about this repository, with the answer I would give and
the file or log that backs each one. Every number here is copied from a
committed artifact; nothing has been run on a board.

---

## 1. "What's the latency, and how do you know it's fixed?"

Eight clock cycles from the edge the decoder accepts an event to the edge the
risk gate hands off the decision — with the condition that the output is not
stalled. Under backpressure an event waits wherever the stall holds it, and I
don't claim a number for that.

The eight is not asserted from a spreadsheet. The per-stage constants and their
sum are in the package, and three independent things check them:

- a per-stage property that the event accepted at T is *the one* presenting at
  T + latency, compared by tag — not just "something is valid";
- a measurement of every one of 2000 events end to end, including gapped, stale
  and malformed ones, which take the same registers: min = mean = max = 8;
- the synthesizable top, where every event that reached the output took 8
  cycles, including across a reset mid-replay.

In nanoseconds that's 8 × 10.000 ns = 80 ns, but that is arithmetic on a fixed
100 MHz oscillator, not a wall-clock measurement, and it excludes any input
interface because events come from an on-chip ROM.

**Points to:** `rtl/market_pkg.sv` (`LAT_*`, `LATENCY_CYCLES`),
`tb/assertions.sv` (`a_fixed_latency`), `results/sim/analyze_latency.txt`,
`results/sim/tb_market_pipeline_top.txt`, `docs/LATENCY.md`.

---

## 2. "Your XDC has no input or output delays. Isn't that just unconstrained I/O?"

No — it's a decision with a written reason, and the build proves nothing is
left unconstrained. The inputs are buttons and switches: asynchronous by
nature, each landing in a synchronizer or unused. The outputs are LEDs and a
seven-segment display read by a person. No external device drives or samples
any pin on a clock edge, so a `set_input_delay` value would describe hardware
that doesn't exist. They're `set_false_path`, with the reason beside each group.

What *is* timed is every synchronous path, including reset release: the button
asserts reset asynchronously and one synchronizer releases it on a clock edge,
so recovery and removal are analysed (+2.515 ns / +0.927 ns at 100 MHz). The
build gate fails unless every `check_timing` count is zero.

If this board had a real data interface, it would need real I/O constraints.

**Points to:** `constraints/target_board.xdc`, `rtl/reset_sync.sv`,
`results/100mhz/BUILD_SCOPE.md`, `scripts/build.tcl`.

---

## 3. "Tell me about a timing problem you found."

The reciprocal lookup table in the feature engine wasn't a table. I read it as
`recip_rom(idx1)` — a call to a constant function in the package on a live
index. A constant function is only folded when its arguments are constant, so
synthesis built the function body, which contains `(1 << 30) / den_mid`: a
32-bit combinational divider.

Every testbench and every mutant passed, because the arithmetic was right. It
surfaced only on the first real implementation: setup WNS −73.898 ns at 100 MHz,
196 logic levels, 162 of them carry cells, 83.530 ns of data path. The fix was
latency-neutral: build the 256 entries as elaboration-time constants, and move a
variable shift into the previous stage so the multiply stage shifts by a
constant. That took it to −0.071 ns.

The lesson I took: simulation tells you the function is right, not what
hardware you asked for. I should have synthesized each module the day I wrote
it.

**Points to:** `results/iter0_100mhz/GATE_FAILED.md`,
`results/iter1_100mhz/GATE_FAILED.md`, `rtl/feature_engine.sv`,
`docs/TIMING_CLOSURE.md` (iteration 1).

---

## 4. "How did you close the last 71 picoseconds, and how do you know you didn't break it?"

The remaining path started at the policy's decision register, which fans out to
136 loads, and went through three carry chains in series inside the risk gate:
the decision selected an addend for the prospective position, that sum was
compared with the limit, and the resulting decision selected an addend for a
*second* adder that produced the new position.

I computed `position + qty` and `position − qty` once, straight from registers,
compared each against its limit, and had the final decision select between the
precomputed sums. One adder left the path: 18 logic levels became 9, and setup
WNS went to +0.250 ns. No register was added, because the eight-cycle latency
was a fixed requirement — a pipeline register would have been the easy fix and
wasn't allowed.

To show it changed nothing, there's a committed comparison testbench: a verbatim
copy of the pre-change module against the committed one, identical legal
stimulus, every output and the position compared every cycle. 62373 events, 0
mismatches, with coverage floors near both limits and a planted off-by-one in a
third copy that must be caught or the test fails as vacuous. It's simulation,
not a formal equivalence proof, and I'd say that.

**Points to:** `results/iter1_100mhz/post_route_timing.rpt`,
`results/100mhz/BUILD_SCOPE.md`, `rtl/risk_gate.sv`,
`tb/tb_risk_gate_equiv.sv`, `results/sim/tb_risk_gate_equiv.txt`.

---

## 5. "What's the worst bug you shipped?"

The risk gate failed open — and I didn't catch it; the adversarial review did.

Position is 24 bits signed, the long limit can be up to 2**23−1, and an order can
be 65535 lots. I computed the prospective position at the same 24 bits. With the
position near the limit and a large order, the sum wrapped negative, so
"position > limit" read false and a trade that should have been refused went
through. That's reachable through the supported configuration path — the export
tool accepts exactly that limit and order size — and failing open is the one
thing a risk gate exists to prevent.

The fix is one bit: compare at `CHK_W = POS_W + 1`. The part worth talking about
is the test. A single large order against a large limit never reaches the wrap,
because the *position* has to be near 2**23 first; the directed test walks it
there with about 128 maximum-size fills. There's a mutant that sets the width
back to `POS_W`, and it's killed. A related trap sits right next to it: writing
the limit inline as an unsigned expression makes the whole comparison unsigned,
so a negative position trips the long limit; that has its own mutants too.

**Points to:** `rtl/risk_gate.sv` (`CHK_W` and its comment), `tb/tb_risk_gate.sv`
("a large limit plus a large order must not wrap the check"),
`scripts/mutants.txt` ("risk: position check wraps at POS_W", "risk: long limit
compared unsigned").

---

## 6. "Sequence numbers are 16 bits. What happens at the edges?"

Wraparound is handled by comparing the modular difference as a signed number:
positive is a gap, negative is stale, zero is in order. A naive magnitude compare
would report a ~65000-event gap at every wrap.

The cost is a window of ±32767. A forward jump of 32768 or more is
indistinguishable from a backward jump — the information isn't on the wire — so
both directions alias: +32768 reads as stale, and an event 40000 behind reads as a
gap of 25536 that drags the expectation backwards. I can't widen the window
without a wider sequence field or an epoch counter, and this wire format has
neither.

What I could do was bound the damage. Left alone, a forward alias never recovers:
stale events don't advance the expectation, so the checker would report the next
32768 events stale while the gap counters sit at zero — telemetry saying the feed
is clean while nothing gets through. After 16 consecutive stale events it
abandons its baseline and resynchronises, and counts the resync, so an alias
costs at most 16 events and is visible. Only an event with no encoding defect may
move the baseline, so one corrupt beat can't redefine the feed's origin.

The boundary itself is pinned by vectors on both sides of 32767/32768, so if
anyone changes the comparison, a test fails rather than production telemetry.

**Points to:** `rtl/sequence_checker.sv`,
`docs/superpowers/specs/2026-09-09-market-pipeline-design.md` (§5.2),
`tb/tb_sequence_checker.sv` ("gap of 32767 flagged as gap", "gap of 32768
aliases to stale", "stale of 40000 aliases to gap").

---

## 7. "How do you know your tests actually test anything?"

Mutation testing — and the story of how it once reported success while measuring
nothing.

The harness applies a single-line change to the RTL, runs the testbench aimed at
it, and counts a failure as a kill. Midway through, the policy-engine testbench
stopped elaborating: xsim rejects nonblocking writes to associative arrays. Every
simulation of it now failed — so the harness scored every mutant aimed at it as
killed, including five written specifically to be hard to kill. Green report,
zero measurement.

The fix was to make the harness prove its own premise: every targeted testbench
must pass *unmutated* first or the run aborts, a kill requires evidence that a
simulation actually ran and failed, and a mutant that doesn't compile is reported
as its own failure rather than a kill. Today: 87 of 87 mutants killed, with four
deliberately left out and the reason for each written down.

The same failure mode showed up three more times, and I now look for it first:

- the first latency property, without a tag comparison, passes on any pipeline
  that stays full;
- the build's pulse-width check searched for a word Vivado never prints, so it
  could never fail — while every build record said "pulse-width clean";
- the first README citation test passed with a wrong WNS in the table.

Each was fixed by making the check demonstrate it can fail: a gate-proof build
at 2.5 ns that failed on pulse width, recovery and setup, and fifteen deliberate
corruptions of the README that the test now rejects (both recorded in the
message of commit `75728dd`), and a planted defect in the equivalence testbench
that must be caught on every run.

**Points to:** `scripts/mutate.sh`, `results/sim/mutation.txt`,
`docs/VERIFICATION.md`, `tb/assertions.sv` (the comment above
`p_fixed_latency`), `scripts/build.tcl` (the pulse-width comment),
`scripts/test_readme_citations.py`.

---

## 8. "Your README says AI. What does that mean, and can it change the timing?"

It means offline-tuned fixed-point weights loaded as configuration — a seeded
search over a constant, three feature weights and two thresholds, scored with an
integer mirror of the RTL's arithmetic. No neural network, nothing learned on the
FPGA, and no claim that any policy makes money: the objective is synthetic.

It can't change *when* a decision comes out, only *what* it is. No weight,
threshold or limit appears in any valid, ready or enable expression. The check is
end to end: the same trace under two committed policies gives different decisions
on 1188 of 2000 events and bit-identical latency histograms.

Changing configuration mid-stream is safe because the policy stage snapshots the
whole configuration — including the risk limits it carries to the gate — on the
edge it accepts each event. I originally had a separate "safe to swap" handshake
too; forcing it permanently high changed no output, so I deleted it rather than
keep something that looked load-bearing. The end-to-end test couldn't kill the
"read the live config" mutants, so they're aimed at a directed snapshot test that
holds an event inside the snapshot stage during a stall.

**Points to:** `docs/AI_POLICY.md`, `rtl/policy_engine.sv`,
`results/sim/tb_policy_configs.txt`, `results/sim/analyze_latency_configs.txt`,
`scripts/mutants.txt` (the `pol-snap:` block),
`docs/superpowers/specs/2026-09-09-market-pipeline-design.md` (§5.5).

---

## 9. "So your Fmax is 106.4 MHz?"

That's the fastest period my sweep passed — 9.4 ns — and I'd call it a floor, not
a ceiling. The sweep runs one implementation per period, and the data shows why
that matters: the 9.2 ns and 9.0 ns attempts failed, but by slack arithmetic
their routed results were faster than the passing 9.4 ns run, and 9.3 ns failed
by more than 9.2 ns did. Placement varies run to run.

It's also not usable on the board: the Basys 3 oscillator is fixed at 100 MHz
and there's no MMCM, so 10.000 ns is the only period this design actually runs
at. The slack-derived estimate from the 100 MHz build, 102.6 MHz, is lower than
the measured number for the same reason — tighter targets routed faster.

What limits it now is the per-symbol book update in top-of-book: 9 logic levels,
72% of the delay is routing.

**Points to:** `results/sweep/FMAX.md`, `results/sweep/summary.csv`,
`docs/TIMING_CLOSURE.md` (Fmax, "What limits it now").

---

## 10. "What would you do differently?"

- **Synthesize every module when I write it.** The divider cost a full timing
  iteration late in the project, and it was visible to the tool from day one.
- **Prove each check can fail before trusting it.** Four of my checks — the
  mutation harness, a latency property, the pulse-width gate, the README guard —
  passed while measuring nothing. A negative control belongs in the same commit
  as the check.
- **Get the review before the commit, not after.** I committed the integration top
  before its adversarial review; that review found four major problems, including
  a button bounce that started a second replay and the pulse-width gate above.
- **Commit the equivalence evidence with the change.** I argued the risk-gate
  restructure was equivalent and only added the comparison testbench when asked.
- **Put it on a board.** Everything here is simulation and post-route analysis; a
  hardware bring-up with an integrated logic analyser would be the next step, and
  latency under backpressure remains unmeasured.

**Points to:** `docs/STATUS.md`, `docs/TIMING_CLOSURE.md`, the README's
"Not done" section in `README.md`.
