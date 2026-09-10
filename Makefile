# fpga-low-latency-market-pipeline
# Vivado is invoked in non-project (batch) mode; see scripts/*.tcl.

# Prefer the repo venv when it exists; fall back to the system interpreter.
PYTHON  ?= $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)
# The Vivado installer does not touch PATH, so fall back to the default
# install location. See docs/SETUP_NOTES.md.
VIVADO  ?= $(if $(shell command -v vivado 2>/dev/null),vivado,$(HOME)/Xilinx/2026.1/Vivado/bin/vivado)
RTL     := $(wildcard rtl/*.sv)
TB      := $(wildcard tb/*.sv)
# Override per run: make sim TOP=tb_event_decoder
TOP       ?= tb_market_pipeline_top
SYNTH_TOP ?= market_pipeline_top

.PHONY: all lint sim build pytest trace clean
all: lint pytest

# Package must lead the file list: market_pkg.sv defines every width/enum/struct.
# Lint each module as its own explicit top.
#
# Forcing --top-module market_pipeline_top fails until the integration stage
# builds it; omitting --top-module entirely trips MULTITOP as soon as there is
# more than one leaf module. Naming each module in turn avoids both, and is a
# stronger check: every module must lint cleanly on its own, not merely as
# part of a tree where something else drives its inputs. The package leads the
# file list so its types resolve.
MODULES := $(basename $(notdir $(filter-out rtl/market_pkg.sv,$(RTL))))
lint:
	@test -n "$(MODULES)" || { echo "no RTL modules to lint"; exit 1; }
	@for m in $(MODULES); do \
	  echo "== lint $$m"; \
	  verilator --lint-only -Wall --top-module $$m \
	    rtl/market_pkg.sv $(filter-out rtl/market_pkg.sv,$(RTL)) || exit 1; \
	done
	@echo "== lint clean: $(MODULES)"

sim:
	$(VIVADO) -mode batch -notrace -source scripts/run_sim.tcl -tclargs $(TOP)

build:
	$(VIVADO) -mode batch -notrace -source scripts/build.tcl -tclargs $(SYNTH_TOP)

pytest:
	$(PYTHON) -m pytest -q

# Regenerate the randomized replay trace. SEED is explicit on purpose: a
# failing run prints its seed and is reproduced by rerunning with the same one.
SEED    ?= 1
NEVENTS ?= 2000
trace:
	$(PYTHON) scripts/generate_events.py --n $(NEVENTS) --seed $(SEED) \
	    --out tb/traces/random

clean:
	rm -rf build/ xsim.dir/ .Xil/ *.jou *.log *.pb *.wdb obj_dir/
