# fpga-low-latency-market-pipeline
# Vivado is invoked in non-project (batch) mode; see scripts/*.tcl.

PYTHON  ?= python
VIVADO  ?= vivado
RTL     := $(wildcard rtl/*.sv)
TB      := $(wildcard tb/*.sv)

.PHONY: all lint sim build pytest clean
all: lint pytest

# Package must lead the file list: market_pkg.sv defines every width/enum/struct.
lint:
	verilator --lint-only -Wall --top-module market_pipeline_top rtl/market_pkg.sv $(filter-out rtl/market_pkg.sv,$(RTL))

sim:
	$(VIVADO) -mode batch -notrace -source scripts/run_sim.tcl

build:
	$(VIVADO) -mode batch -notrace -source scripts/build.tcl

pytest:
	$(PYTHON) -m pytest -q

clean:
	rm -rf build/ xsim.dir/ .Xil/ *.jou *.log *.pb *.wdb obj_dir/
