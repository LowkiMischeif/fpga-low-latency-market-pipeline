## Digilent Basys 3 (xc7a35tcpg236-1)
##
## Pins and IOSTANDARDs are from Digilent's Basys-3-Master.xdc
## (github.com/Digilent/digilent-xdc), which is labelled Rev B. Verify against
## the master file for your board revision before trusting a bitstream on
## hardware. No bitstream from this repository has been run on a board.

## Configuration bank voltage: a fixed board property. Without it 7-series
## emits a CFGBVS-1 violation at write_bitstream.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## ---- clock ------------------------------------------------------------
## 100 MHz oscillator on W5, no MMCM: 10.000 ns is the only period this
## design can run at. build.tcl can override the period for an Fmax sweep;
## nothing faster than 10.000 ns is usable on this board.
set_property -dict {PACKAGE_PIN W5 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

## ---- asynchronous inputs ------------------------------------------------
## Buttons and switches are asynchronous to sys_clk by nature. btnU asserts
## reset asynchronously and its release passes through reset_sync's two
## flops; btnC and sw[0] land in two-flop synchronizers (replay_ctrl,
## cfg_loader); sw[15:1] are pinned but unused. There is
## no setup relationship to the clock to constrain, so the paths from these
## ports are false paths. They are NOT given set_input_delay: no external
## device drives them on a clock edge, and a delay value would describe
## hardware that does not exist.
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports btnU]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports btnC]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN W17 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} [get_ports {sw[4]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {sw[5]}]
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {sw[6]}]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {sw[7]}]
set_property -dict {PACKAGE_PIN V2  IOSTANDARD LVCMOS33} [get_ports {sw[8]}]
set_property -dict {PACKAGE_PIN T3  IOSTANDARD LVCMOS33} [get_ports {sw[9]}]
set_property -dict {PACKAGE_PIN T2  IOSTANDARD LVCMOS33} [get_ports {sw[10]}]
set_property -dict {PACKAGE_PIN R3  IOSTANDARD LVCMOS33} [get_ports {sw[11]}]
set_property -dict {PACKAGE_PIN W2  IOSTANDARD LVCMOS33} [get_ports {sw[12]}]
set_property -dict {PACKAGE_PIN U1  IOSTANDARD LVCMOS33} [get_ports {sw[13]}]
set_property -dict {PACKAGE_PIN T1  IOSTANDARD LVCMOS33} [get_ports {sw[14]}]
set_property -dict {PACKAGE_PIN R2  IOSTANDARD LVCMOS33} [get_ports {sw[15]}]
set_false_path -from [get_ports {btnU btnC sw[*]}]

## ---- human-scale outputs --------------------------------------------------
## LEDs and the 7-seg are read by a person. Nothing samples them on a clock
## edge, so the paths to these ports are false paths, not set_output_delay.
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN V3  IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN W3  IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN U3  IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN P3  IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN N3  IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN P1  IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN L1  IOSTANDARD LVCMOS33} [get_ports {led[15]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports {seg[0]}]
set_property -dict {PACKAGE_PIN W6 IOSTANDARD LVCMOS33} [get_ports {seg[1]}]
set_property -dict {PACKAGE_PIN U8 IOSTANDARD LVCMOS33} [get_ports {seg[2]}]
set_property -dict {PACKAGE_PIN V8 IOSTANDARD LVCMOS33} [get_ports {seg[3]}]
set_property -dict {PACKAGE_PIN U5 IOSTANDARD LVCMOS33} [get_ports {seg[4]}]
set_property -dict {PACKAGE_PIN V5 IOSTANDARD LVCMOS33} [get_ports {seg[5]}]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports {seg[6]}]
set_property -dict {PACKAGE_PIN V7 IOSTANDARD LVCMOS33} [get_ports dp]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports {an[0]}]
set_property -dict {PACKAGE_PIN U4 IOSTANDARD LVCMOS33} [get_ports {an[1]}]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports {an[2]}]
set_property -dict {PACKAGE_PIN W4 IOSTANDARD LVCMOS33} [get_ports {an[3]}]
set_false_path -to [get_ports {led[*] seg[*] an[*] dp}]

## ---- what is and is not timed -----------------------------------------------
## Every synchronous path inside the design is timed against sys_clk. The
## synchronized reset's release is timed as recovery/removal by Vivado's
## standard analysis. Clock uncertainty is left at Vivado's default modelling;
## docs/TIMING_CLOSURE.md states that as an assumption and how much slack it
## would consume, rather than a jitter figure that has not been measured.
