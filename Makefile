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

.PHONY: all lint sim build pytest clean
all: lint pytest

# Package must lead the file list: market_pkg.sv defines every width/enum/struct.
# No --top-module: market_pipeline_top does not exist until the integration
# stage, and forcing a top that is absent fails the lint outright. Verilator
# infers the top from what is present; the package still leads the list.
lint:
	verilator --lint-only -Wall rtl/market_pkg.sv $(filter-out rtl/market_pkg.sv,$(RTL))

sim:
	$(VIVADO) -mode batch -notrace -source scripts/run_sim.tcl -tclargs $(TOP)

build:
	$(VIVADO) -mode batch -notrace -source scripts/build.tcl -tclargs $(SYNTH_TOP)

pytest:
	$(PYTHON) -m pytest -q

clean:
	rm -rf build/ xsim.dir/ .Xil/ *.jou *.log *.pb *.wdb obj_dir/
