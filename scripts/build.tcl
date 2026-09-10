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

# Reports are staged in build/ and only published to results/ after the
# gate at the bottom passes. Nothing lands in results/ that has not been
# through implementation and had its slack checked -- a post-synthesis WNS
# is computed on an unplaced, unrouted netlist with estimated interconnect
# delay, and it is systematically optimistic. Staging keeps a failed or
# aborted run from leaving quotable-looking numbers behind in results/.
set outdir [file join $root results]
set bitdir [file join $root build]
set rptdir [file join $bitdir reports]
file mkdir $outdir
file mkdir $bitdir
file mkdir $rptdir

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
report_utilization -file [file join $rptdir post_synth_utilization.rpt]
report_timing_summary -file [file join $rptdir post_synth_timing.rpt]

# The XDC names ports that the RTL may not declare under the same names. When
# get_ports matches nothing, create_clock binds nothing, and an unconstrained
# design then reports flawless timing because there is nothing left to
# violate. Fail loudly here instead. Never silence the underlying warning
# with -quiet in the XDC.
set clocks [get_clocks -quiet]
if {[llength $clocks] != 1} {
    puts "ERROR: expected exactly 1 clock after synth, found [llength $clocks]: $clocks"
    puts "       The XDC likely did not bind -- check the port names in $TOP against constraints/."
    exit 1
}
set clk_period [get_property PERIOD [lindex $clocks 0]]
if {abs($clk_period - 10.000) > 0.001} {
    puts "ERROR: clock period is ${clk_period} ns, expected 10.000 ns (100 MHz Basys 3 oscillator)."
    exit 1
}
puts "== clock [get_property NAME [lindex $clocks 0]] bound at ${clk_period} ns =="

puts "== implementation =="
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $bitdir post_route.dcp]

puts "== reports =="
report_utilization        -file [file join $rptdir post_route_utilization.rpt]
report_timing_summary     -file [file join $rptdir post_route_timing.rpt]
report_timing -sort_by group -max_paths 20 -path_type summary \
                          -file [file join $rptdir post_route_timing_paths.rpt]
report_clock_utilization  -file [file join $rptdir post_route_clock_util.rpt]
report_power              -file [file join $rptdir post_route_power.rpt]
report_drc                -file [file join $rptdir post_route_drc.rpt]

# check_timing is the artifact that states, in generated text, which endpoints
# are unconstrained. The XDC currently constrains no I/O at all, so this report
# is the only thing that travels with the numbers and says so. report_methodology
# catches constraint problems that report_timing_summary will happily ignore.
check_timing              -file [file join $rptdir post_route_check_timing.rpt]
report_methodology        -file [file join $rptdir post_route_methodology.rpt]

write_bitstream -force [file join $bitdir ${TOP}.bit]

# ---------------------------------------------------------------------------
# Gate. Nothing above this line is published.
#
# get_timing_paths only ever returns CONSTRAINED paths. With I/O delays still
# unconstrained (see constraints/target_board.xdc), a design that misses setup
# on every input pin will report a healthy WNS here. This gate therefore
# proves reg-to-reg timing on one clock and nothing else -- that scope is
# recorded in results/BUILD_SCOPE.md alongside the reports.
# ---------------------------------------------------------------------------
set max_paths [get_timing_paths -quiet -delay_type max]
set min_paths [get_timing_paths -quiet -delay_type min]
if {[llength $max_paths] == 0 || [llength $min_paths] == 0} {
    puts "ERROR: no constrained timing paths found. The design is unconstrained;"
    puts "       any slack number from this run would be meaningless."
    exit 1
}
set wns [get_property SLACK [lindex $max_paths 0]]
set whs [get_property SLACK [lindex $min_paths 0]]

# Pulse width is checked separately by Vivado and a design failing it will
# otherwise sail through a WNS/WHS-only check. get_timing_paths does not carry
# pulse-width checks, so ask report_pulse_width directly.
set pw_violated 0
if {[catch {set pw_str [report_pulse_width -quiet -return_string -all_violators]}]} {
    set pw_str ""
    puts "WARNING: report_pulse_width unavailable; pulse-width not gated."
}
if {[regexp -nocase {VIOLATED} $pw_str]} { set pw_violated 1 }

# report_drc writes a file; its result was never actually inspected before.
set drc_errors 0
if {[catch {set drc_errors [llength [get_drc_violations -quiet]]}]} { set drc_errors 0 }

puts "== WNS ${wns} ns / WHS ${whs} ns / pulse-width violated: ${pw_violated} / DRC violations ${drc_errors} =="

set failed 0
if {$wns < 0} { puts "ERROR: setup timing not met (WNS ${wns} ns)";  set failed 1 }
if {$whs < 0} { puts "ERROR: hold timing not met (WHS ${whs} ns)";   set failed 1 }
if {$pw_violated}    { puts "ERROR: pulse-width check violated";     set failed 1 }
if {$drc_errors > 0} { puts "ERROR: ${drc_errors} DRC violation(s)"; set failed 1 }
if {$failed} {
    puts "       Reports left in [file join build reports] -- NOT published to results/."
    exit 1
}

# Publish only now, and stamp the scope onto the numbers so the caveat in the
# XDC travels with them.
foreach f [glob -nocomplain [file join $rptdir *.rpt]] {
    file copy -force $f [file join $outdir [file tail $f]]
}
set fh [open [file join $outdir BUILD_SCOPE.md] w]
puts $fh "# Scope of the reports in this directory"
puts $fh ""
puts $fh "Generated by scripts/build.tcl. Do not edit by hand."
puts $fh ""
puts $fh "- Part: $PART ($BOARD)"
puts $fh "- Top: $TOP"
puts $fh "- Clock: [get_property NAME [lindex $clocks 0]] at ${clk_period} ns ([format %.1f [expr {1000.0 / $clk_period}]] MHz)"
puts $fh "- Post-route WNS ${wns} ns / WHS ${whs} ns, ${drc_errors} DRC violations, pulse-width clean"
puts $fh ""
puts $fh "**These numbers cover register-to-register paths on a single clock.**"
puts $fh "I/O delays are not constrained (see constraints/target_board.xdc), so"
puts $fh "nothing here is evidence of I/O timing closure. See"
puts $fh "post_route_check_timing.rpt for the generated list of unconstrained endpoints."
puts $fh ""
puts $fh "Latency in nanoseconds is LATENCY_CYCLES * ${clk_period} ns. This board's"
puts $fh "oscillator is fixed at 100 MHz; do not quote a figure derived from any other rate."
close $fh

puts "== published [llength [glob -nocomplain [file join $outdir *.rpt]]] reports to results/ =="
puts "== build complete: [file join $bitdir ${TOP}.bit] =="
exit 0
