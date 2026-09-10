# build.tcl -- non-project synthesis + implementation for the Basys 3 board.
#
#   make build
#
# Non-project mode (read_verilog / synth_design / ... ) rather than
# create_project: the flow is fully described here, nothing is hidden in a
# .xpr, and the reports land in results/ where docs/ can cite them.

set PART  xc7a35tcpg236-1
set BOARD "Digilent Basys 3"
set TOP   [expr {[llength $argv] > 0 ? [lindex $argv 0] : "market_pipeline_top"}]

set root [file normalize [file dirname [info script]]/..]
cd $root

set outdir [file join $root results]
set bitdir [file join $root build]
file mkdir $outdir
file mkdir $bitdir

# market_pkg.sv must lead the file list: it defines every width, enum and
# struct the rest of the design elaborates against.
set pkg [file join $root rtl market_pkg.sv]
set rtl [lsort [glob -nocomplain [file join $root rtl *.sv]]]
set xdc [lsort [glob -nocomplain [file join $root constraints *.xdc]]]

if {[llength $rtl] == 0} {
    puts "ERROR: no sources in rtl/. Nothing to build."
    exit 1
}
if {[file exists $pkg]} {
    set rtl [concat [list $pkg] [lsearch -all -inline -not -exact $rtl $pkg]]
}
if {[llength $xdc] == 0} {
    puts "ERROR: no .xdc in constraints/. Refusing to build: without timing"
    puts "       constraints the timing reports below would be meaningless."
    exit 1
}

puts "== reading sources for $TOP ($PART, $BOARD) =="
read_verilog -sv $rtl
read_xdc $xdc

puts "== synth =="
synth_design -top $TOP -part $PART -flatten_hierarchy rebuilt
write_checkpoint -force [file join $bitdir post_synth.dcp]
report_utilization -file [file join $outdir post_synth_utilization.rpt]
report_timing_summary -file [file join $outdir post_synth_timing.rpt]

puts "== implementation =="
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $bitdir post_route.dcp]

puts "== reports =="
report_utilization        -file [file join $outdir post_route_utilization.rpt]
report_timing_summary     -file [file join $outdir post_route_timing.rpt]
report_timing -sort_by group -max_paths 20 -path_type summary \
                          -file [file join $outdir post_route_timing_paths.rpt]
report_clock_utilization  -file [file join $outdir post_route_clock_util.rpt]
report_power              -file [file join $outdir post_route_power.rpt]
report_drc                -file [file join $outdir post_route_drc.rpt]

write_bitstream -force [file join $bitdir ${TOP}.bit]

# Fail the build on negative slack rather than shipping a green-looking run:
# a timing-failing bitstream is not a result worth quoting.
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "== WNS ${wns} ns / WHS ${whs} ns =="
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met (WNS ${wns}, WHS ${whs}). See results/post_route_timing.rpt"
    exit 1
}

puts "== build complete: [file join $bitdir ${TOP}.bit] =="
exit 0
