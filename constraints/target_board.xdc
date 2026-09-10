## Digilent Basys 3 (xc7a35tcpg236-1)
##
## Pin and IOSTANDARD below match Digilent's Basys3_Master.xdc for board
## revision C. Verify against the master XDC for your revision before
## trusting a bitstream on hardware.

## Configuration bank voltage. Not deferred with the I/O TODO below because
## it is a fixed board property, not a guess: without it 7-series emits a
## CFGBVS-1 violation at write_bitstream.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## Clock: 100 MHz oscillator on W5.
## The board oscillator is fixed at 100 MHz and there is no MMCM in front of
## it, so 10.000 ns is the only period this design can have. Any latency
## figure in ns is LATENCY_CYCLES * 10.0.
set_property -dict {PACKAGE_PIN W5 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

## TODO: clock uncertainty.
## create_clock alone models a mathematically perfect clock. The Basys 3
## oscillator has real period jitter, which makes every WNS reported against
## this constraint optimistic by that margin. Add set_input_jitter once the
## oscillator part number has been read off the board schematic. Do not
## invent a value.

## TODO: pin assignments and I/O delay constraints.
## Only clk is pinned. Two consequences, in order of when they bite:
##
##  1. `make build` cannot reach a bitstream. Every other top-level port is
##     an unconstrained logical port, which is a UCIO-1 DRC *error* at
##     write_bitstream, not a warning. Downgrading UCIO-1 to a warning is NOT
##     an acceptable workaround: it produces a bitstream whose pinout is
##     whatever the tool chose, which cannot be tested on the board.
##
##  2. Timing reports cover register-to-register paths only. get_timing_paths
##     considers constrained paths, so a design missing setup on every input
##     pin still reports a healthy WNS. results/BUILD_SCOPE.md and
##     results/post_route_check_timing.rpt record this scope automatically;
##     do not quote a timing number without them.
##
## Add set_input_delay/set_output_delay against sys_clk, plus PACKAGE_PIN and
## IOSTANDARD for the remaining ports, once the port list of
## market_pipeline_top is settled.
