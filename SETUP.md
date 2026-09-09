# Claude Code setup — fpga-low-latency-market-pipeline

## 0. Copy these files into the repo root
```
.claude/agents/rtl-verification-engineer.md
.claude/agents/rtl-skeptic-reviewer.md
CLAUDE.md
```
Then run `claude` in the repo and confirm with `/agents` that both local agents are listed.

## 1. Install the plugin stack (in this order)
Inside a Claude Code session:
```
/plugin marketplace add <superpowers-marketplace>
/plugin install superpowers

/plugin marketplace add <ponytail-lite-marketplace>
/plugin install ponytail-lite

/plugin marketplace add <sv-lsp-marketplace>
/plugin install <systemverilog-lsp-plugin>

/plugin install github          # recommended
```
Replace the `<...>` placeholders with the marketplace/plugin names from each plugin's README — I don't want to guess names and have you install the wrong thing. Use `/plugin marketplace list` and `/plugin list` to verify.

Superpowers first so its brainstorm/plan/implement skills are available when you scaffold; the LSP plugin needs a language server on PATH (`verible-verilog-ls` or `svls`) — install that with your OS package manager before enabling the plugin.

## 2. Local tools the agents expect
- Verilator (lint)
- Vivado (xsim + synthesis) with `vivado` on PATH
- Python 3.11+, `pip install -r requirements.txt`

## 3. Kick-off prompt for Week 1
```
Read CLAUDE.md and docs/PLAN.md. Use Superpowers to brainstorm then plan Week 1:
market_pkg.sv, event_decoder.sv, sequence_checker.sv, tb_event_decoder.sv,
scripts/generate_events.py. After implementing, hand off to
rtl-verification-engineer, then rtl-skeptic-reviewer, and open a PR.
```
