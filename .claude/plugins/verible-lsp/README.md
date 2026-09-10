# verible-lsp

SystemVerilog/Verilog language server for this repo, backed by
[Verible](https://github.com/chipsalliance/verible)'s `verible-verilog-ls`.
Gives Claude Code diagnostics, document symbols, hover, go-to-definition,
references, rename, and formatting on `.sv`, `.svh`, and `.v` files.

This plugin only wires up the server — **the binary is not bundled.**

## Installing the server

Pick the asset for your platform from the latest
[Verible release](https://github.com/chipsalliance/verible/releases/latest)
and put `verible-verilog-ls` somewhere on `PATH`:

```bash
VER=v0.0-4171-ga5e38787   # latest as of 2026-09-09
cd "$(mktemp -d)"
curl -sfLO "https://github.com/chipsalliance/verible/releases/download/$VER/verible-$VER-linux-static-x86_64.tar.gz"
tar xzf "verible-$VER-linux-static-x86_64.tar.gz"
install -m 755 "verible-$VER/bin/verible-verilog-ls" ~/.local/bin/
verible-verilog-ls --version
```

Confirm `~/.local/bin` is on `PATH` — the plugin resolves `verible-verilog-ls`
from `PATH`, so an unreachable binary means the server silently never starts.

## Enabling

The marketplace and the plugin are both declared in `.claude/settings.json`, so
a fresh clone picks them up on the next session. To toggle manually:

```bash
claude plugin install verible-lsp@fpga-market-pipeline-local -s project
claude plugin disable verible-lsp@fpga-market-pipeline-local
```

Edits to `.lsp.json` need `/reload-plugins` or a restart.

## Lint rules

The server runs with `--rules_config_search`, so it walks upward from each
analyzed file looking for a `.rules.verible_lint` config. Drop one at the repo
root to align editor diagnostics with whatever the lint step enforces. Without
that file Verible applies its default ruleset.

## Verified

Against a scratch `.sv` file on 2026-09-09 with `verible-verilog-ls
v0.0-4171-ga5e38787`: `initialize` advertises `diagnosticProvider`,
`documentSymbolProvider`, `definitionProvider`, `hoverProvider`,
`referencesProvider`, `renameProvider`, and both formatting providers. A missing
statement terminator produced three `publishDiagnostics` entries; the corrected
file produced zero diagnostics and a correct symbol tree.

Note Verible parses each file standalone — it does not elaborate a design, so
cross-file package/interface references may resolve incompletely. It complements
`verilator --lint-only -Wall`; it does not replace it.
