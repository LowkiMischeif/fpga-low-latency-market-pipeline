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

.PHONY: all lint lint-tb sim sim-all build pytest trace clean
all: lint lint-tb pytest

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

# Lint the testbenches.
#
# CI ran green for the whole of the decode/validate branch without ever
# elaborating tb/, because `lint` above globs rtl/ only. A syntax error in any
# testbench went green on GitHub and surfaced only when someone ran make sim
# locally. This target closes that.
#
# Each testbench is elaborated as its own top against the full RTL plus the
# assertion library, so a bind that does not resolve or a port that is not
# connected is an error here rather than a surprise at simulation time.
#
# The waivers are testbench idioms, not defects:
#   DECLFILENAME  tb/assertions.sv declares handshake_checker; the filename is
#                 fixed by the layout in CLAUDE.md.
#   BLKSEQ        `always #5 clk = ~clk;` is the standard clock generator.
#   UNUSEDSIGNAL  verilator's dataflow does not track variables read only
#                 inside tasks and initial blocks (the driver RNG state).
#   SYNCASYNCNET  a testbench drives rst_n procedurally while the DUT samples
#                 it asynchronously. Unavoidable, and harmless in simulation.
# Everything else stays on. PINMISSING in particular earned its keep the first
# time this target ran, catching a sequence_checker.resync_count that had been
# added to the module and never connected in tb_fixed_latency.
TB_SRCS  := $(wildcard tb/tb_*.sv)
TB_TOPS  := $(basename $(notdir $(TB_SRCS)))
TB_LIB   := rtl/market_pkg.sv $(filter-out rtl/market_pkg.sv,$(RTL)) \
            tb/assertions.sv tb/bind_assertions.sv
TB_WAIVE := -Wno-DECLFILENAME -Wno-BLKSEQ -Wno-UNUSEDSIGNAL -Wno-SYNCASYNCNET

lint-tb:
	@test -n "$(TB_TOPS)" || { echo "no testbenches to lint"; exit 1; }
	@for t in $(TB_TOPS); do \
	  echo "== lint-tb $$t"; \
	  verilator --lint-only -Wall --timing $(TB_WAIVE) --top-module $$t \
	    $(TB_LIB) tb/$$t.sv || exit 1; \
	done
	@echo "== lint-tb clean: $(TB_TOPS)"

# PLUSARGS is a space-separated list of NAME=VALUE forwarded to the sim as
# +NAME=VALUE, e.g.  make sim TOP=tb_decode_validate PLUSARGS="SEED=7"
PLUSARGS ?=
sim:
	$(VIVADO) -mode batch -notrace -source scripts/run_sim.tcl -tclargs $(TOP) $(PLUSARGS)

# Run every testbench. run_sim.tcl already fails a run on any Fatal:/Error:
# line and on a missing PASS: marker, so a non-zero make sim is the gate here;
# the loop stops at the first failure rather than reporting a green summary
# over a red run. Regenerates the trace first, since tb_decode_validate reads
# a gitignored trace that will not exist on a fresh clone.
sim-all: trace
	@test -n "$(TB_TOPS)" || { echo "no testbenches to run"; exit 1; }
	@for t in $(TB_TOPS); do \
	  echo "== sim $$t"; \
	  $(MAKE) --no-print-directory sim TOP=$$t || exit 1; \
	done
	@echo "== replay the generated trace through book + features"
	@$(MAKE) --no-print-directory sim TOP=tb_book_features \
	    PLUSARGS="HEX=$(TRACEOUT).hex NEVENTS=$(NEVENTS)" || exit 1
	@echo "== sim-all passed: $(TB_TOPS) (+ generated-trace replay)"

build:
	$(VIVADO) -mode batch -notrace -source scripts/build.tcl -tclargs $(SYNTH_TOP)

pytest:
	$(PYTHON) -m pytest -q

# Regenerate the randomized replay trace. SEED is explicit on purpose: a
# failing run prints its seed and is reproduced by rerunning with the same one.
# STARTSEQ exists so the randomized replay can be aimed at the 16-bit
# wraparound: with the default 0 and 2000 events the trace never reaches
# 0xFFFF, so the wrap path was only ever covered by the directed testbench.
SEED     ?= 1
NEVENTS  ?= 2000
STARTSEQ ?= 0
TRACEOUT ?= tb/traces/random
trace:
	$(PYTHON) scripts/generate_events.py --n $(NEVENTS) --seed $(SEED) \
	    --start-seq $(STARTSEQ) --out $(TRACEOUT)

clean:
	rm -rf build/ xsim.dir/ .Xil/ *.jou *.log *.pb *.wdb obj_dir/
