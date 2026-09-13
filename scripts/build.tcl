# build.tcl -- non-project synthesis + implementation for the Basys 3 board.
#
#   make build                                      # 10.000 ns -> results/100mhz/
#   make build PERIOD=7.5 RUN=sweep/p7.5            # Fmax sweep point
#   make build RUN=iter0_100mhz PUBLISH_FAILED=1    # keep a failing run as a record
#
# Invoked as:
#   vivado -mode batch -source scripts/build.tcl -tclargs TOP [PERIOD] [RUN] [PUBLISH_FAILED]
#
# Non-project mode (read_verilog / synth_design / ... ) rather than
# create_project: the flow is fully described here, nothing is hidden in a
# .xpr, and the reports land in results/ where docs/ can cite them.

# Positional arguments: an empty one dropped by the shell would shift the rest
# (RUN= once arrived as RUN "0", the PUBLISH_FAILED value), so accept either
# no arguments or all four.
if {[llength $argv] != 0 && [llength $argv] != 4} {
    puts "ERROR: expected 0 or 4 arguments (TOP PERIOD RUN PUBLISH_FAILED), got [llength $argv]: $argv"
    exit 1
}

set PART  xc7a35tcpg236-1
set BOARD "Digilent Basys 3"
set TOP    [expr {[llength $argv] > 0 ? [lindex $argv 0] : "market_pipeline_top"}]
set PERIOD [expr {[llength $argv] > 1 ? double([lindex $argv 1]) : 10.000}]
set RUN    [expr {[llength $argv] > 2 ? [lindex $argv 2] : "100mhz"}]
set PUBLISH_FAILED [expr {[llength $argv] > 3 ? [lindex $argv 3] : 0}]
set SWEEP_RUN [expr {abs($PERIOD - 10.000) > 0.0005}]

# RUN names a directory under results/ that this script deletes and replaces,
# so it must be a plain relative name. An empty RUN would name results/ itself
# and an absolute one would name somewhere else entirely.
if {![regexp {^[A-Za-z0-9_]+(/[A-Za-z0-9_.]+)*$} $RUN] || [string match {*..*} $RUN]} {
    puts "ERROR: RUN '$RUN' must be a relative name such as 100mhz or sweep/p9.5"
    puts "       (letters, digits and _, with '.' allowed after the first segment, no '..')."
    exit 1
}

set root [file normalize [file dirname [info script]]/..]
cd $root

# Which sources these numbers belong to. A report that cannot be tied to a
# commit cannot be cited, so the commit, and whether each input to the build
# differed from it, are stamped into whatever this run publishes.
set src_commit "unknown (not a git checkout)"
set src_state  "unknown"
catch {
    set src_commit [exec git -C $root rev-parse --short HEAD]
    set st {}
    foreach d {rtl constraints scripts/build.tcl Makefile} {
        set dirty [exec git -C $root status --porcelain -- $d]
        lappend st "$d [expr {$dirty eq {} ? {clean} : {MODIFIED}}]"
    }
    set src_state [join $st ", "]
}

# Reports are staged in build/<RUN>/ and only published to results/<RUN>/
# after the gate at the bottom passes. A post-synthesis WNS is computed on an
# unplaced, unrouted netlist and is systematically optimistic, so nothing
# lands in results/ that has not been through implementation and the gate.
#
# Whatever was published under this run name before is deleted FIRST, before
# anything can fail: a run that passes, fails or aborts must never leave an
# earlier result sitting in results/<RUN>/ looking current.
set outdir [file join $root results $RUN]
set bitdir [file join $root build $RUN]
set rptdir [file join $bitdir reports]
file delete -force $outdir
file mkdir $bitdir
file delete -force $rptdir
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

puts "== reading sources for $TOP ($PART, $BOARD), period ${PERIOD} ns, run $RUN =="
puts "== source commit $src_commit: $src_state =="
read_verilog -sv $rtl
read_xdc $xdc

# Fmax sweep: override the board period BEFORE synthesis, so each sweep point
# is synthesized and implemented against its own period. The committed XDC
# keeps 10.000 ns, the only period the Basys 3 can run at.
if {$SWEEP_RUN} {
    set ovr [file join $bitdir period_override.xdc]
    set fh [open $ovr w]
    puts $fh "create_clock -name sys_clk -period $PERIOD -waveform {0.000 [expr {$PERIOD / 2.0}]} \[get_ports clk\]"
    close $fh
    read_xdc $ovr
}

# The ROM images the RTL initialises from. $readmemh resolves its path
# relative to this directory (root), and read_mem registers the files with the
# tool.
set mems [lsort [glob -nocomplain [file join $root rtl mem *.mem]]]
if {[llength $mems] == 0} {
    puts "ERROR: no .mem files in rtl/mem -- the trace and config ROMs would be empty."
    exit 1
}
read_mem $mems

# A $readmemh that cannot open its file is only a CRITICAL WARNING by default,
# and synthesis then succeeds with an all-zero ROM: a probe with a missing
# .mem inferred 0 BRAM and completed. Make it fatal.
set_msg_config -id {Synth 8-4445} -new_severity ERROR

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
if {abs($clk_period - $PERIOD) > 0.001} {
    puts "ERROR: clock period is ${clk_period} ns, requested ${PERIOD} ns."
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
check_timing              -file [file join $rptdir post_route_check_timing.rpt]
report_methodology        -file [file join $rptdir post_route_methodology.rpt]

# A sweep point is a measurement, not a deliverable: its bitstream could not
# run on the board anyway, so do not spend the minute writing one.
if {!$SWEEP_RUN} {
    write_bitstream -force [file join $bitdir ${TOP}.bit]
}

# ---------------------------------------------------------------------------
# Gate. Nothing above this line is published. Every check reads a number and
# fails closed: if the number cannot be read, the run fails.
# ---------------------------------------------------------------------------
proc read_report {name} {
    upvar #0 rptdir rptdir
    set fh [open [file join $rptdir $name] r]
    set txt [read $fh]
    close $fh
    return $txt
}
set reasons {}

# Setup, hold, recovery and removal. get_timing_paths only returns constrained
# paths, so an empty result is itself a failure.
set max_paths [get_timing_paths -quiet -delay_type max]
set min_paths [get_timing_paths -quiet -delay_type min]
if {[llength $max_paths] == 0 || [llength $min_paths] == 0} {
    puts "ERROR: no constrained timing paths found. The design is unconstrained;"
    puts "       any slack number from this run would be meaningless."
    exit 1
}
set wns [get_property SLACK [lindex $max_paths 0]]
set whs [get_property SLACK [lindex $min_paths 0]]

# Per path group, so a failure is named for what it is: the async_default
# group holds reset recovery and removal, not setup and hold.
set group_lines {}
set saw_sys_clk 0
foreach g [get_path_groups -quiet] {
    set async [string match {*async_default*} $g]
    if {$g eq "sys_clk"} { set saw_sys_clk 1 }
    set p [get_timing_paths -quiet -delay_type max -group $g -max_paths 1]
    set q [get_timing_paths -quiet -delay_type min -group $g -max_paths 1]
    set gs [expr {[llength $p] ? [get_property SLACK $p] : "n/a"}]
    set gh [expr {[llength $q] ? [get_property SLACK $q] : "n/a"}]
    set kmax [expr {$async ? "recovery" : "setup"}]
    set kmin [expr {$async ? "removal" : "hold"}]
    lappend group_lines "`$g`: $kmax $gs ns, $kmin $gh ns"
    if {$gs ne "n/a" && $gs < 0} { lappend reasons "$kmax not met in path group `$g` (worst slack $gs ns)" }
    if {$gh ne "n/a" && $gh < 0} { lappend reasons "$kmin not met in path group `$g` (worst slack $gh ns)" }
}
# The overall verdict must not depend on the group loop finding anything.
if {!$saw_sys_clk}                 { lappend reasons "no sys_clk path group found" }
if {$wns < 0 && [llength $reasons] == 0} { lappend reasons "max-delay timing not met (WNS $wns ns)" }
if {$whs < 0 && [lsearch -glob $reasons {*hold*}] < 0 && [lsearch -glob $reasons {*removal*}] < 0} {
    lappend reasons "min-delay timing not met (WHS $whs ns)"
}

set worst [lindex $max_paths 0]
set worst_desc "unavailable"
catch {
    set worst_desc "[get_property STARTPOINT_PIN $worst] -> [get_property ENDPOINT_PIN $worst],\
 [get_property LOGIC_LEVELS $worst] logic levels, datapath\
 [get_property DATAPATH_DELAY $worst] ns"
}

# Pulse width. report_pulse_width never prints the word "VIOLATED" (checked
# against a routed checkpoint with a 0.9 ns clock), so an earlier regexp on
# that word could not fail. Read WPWS from the Design Timing Summary table.
set wpws ""
set tlines [split [read_report post_route_timing.rpt] "\n"]
set hi [lsearch -regexp $tlines {^\s+WNS\(ns\)\s+TNS\(ns\).*WPWS\(ns\)}]
if {$hi >= 0} {
    set vals [regexp -all -inline {\S+} [lindex $tlines [expr {$hi + 2}]]]
    if {[llength $vals] == 12} { set wpws [lindex $vals 8] }
}
if {![string is double -strict $wpws]} {
    puts "ERROR: could not read WPWS from post_route_timing.rpt; refusing to gate without it."
    exit 1
}
if {$wpws < 0} { lappend reasons "pulse width not met (WPWS $wpws ns)" }

# Scope. BUILD_SCOPE.md says every synchronous path is timed; check_timing is
# where that is true or not, so every one of its checks must report zero. The
# two I/O-delay checks also count ports that carry a false path, which is the
# intended treatment of every port here, so for those only the ports WITHOUT a
# false path are counted.
set ct [read_report post_route_check_timing.rpt]
set checks [regexp -all -inline {checking (\w+) \((\d+)\)} $ct]
if {[llength $checks] == 0} {
    puts "ERROR: could not read any check from post_route_check_timing.rpt; refusing to gate without it."
    exit 1
}
set io_detail {
    no_input_delay  {There are (\d+) input ports with no input delay specified}
    no_output_delay {There are (\d+) ports with no output delay specified}
}
set scope_line {}
set seen {}
foreach {all name n} $checks {
    if {[lsearch -exact $seen $name] >= 0} continue
    lappend seen $name
    if {[dict exists $io_detail $name]} {
        if {![regexp [dict get $io_detail $name] $ct -> n]} {
            puts "ERROR: could not read the $name detail from post_route_check_timing.rpt."
            exit 1
        }
        set name "${name}_without_false_path"
    }
    lappend scope_line "$name $n"
    if {$n != 0} { lappend reasons "check_timing: $name = $n" }
}

# DRC. Advisory and Warning severities are listed in post_route_drc.rpt but do
# not block a bitstream.
set drc_errors 0
if {[catch {set drc_errors [llength [get_drc_violations -quiet \
        -filter {SEVERITY == "Error" || SEVERITY == "Critical Warning"}]]}]} {
    puts "ERROR: could not read DRC results."
    exit 1
}
if {$drc_errors > 0} { lappend reasons "${drc_errors} DRC violation(s) at Error or Critical Warning" }

puts "== WNS ${wns} ns / WHS ${whs} ns / WPWS ${wpws} ns / DRC violations ${drc_errors} =="
foreach l $group_lines { puts "== path group $l ==" }
puts "== check_timing: [join $scope_line {, }] =="
puts "== worst setup path: $worst_desc =="

proc run_facts {fh} {
    upvar #0 PART PART BOARD BOARD TOP TOP clocks clocks clk_period clk_period \
             wns wns whs whs wpws wpws drc_errors drc_errors worst_desc worst_desc \
             src_commit src_commit src_state src_state group_lines group_lines \
             scope_line scope_line SWEEP_RUN SWEEP_RUN
    puts $fh "- Tool: Vivado [version -short], non-project flow, default directives"
    puts $fh "- Part: $PART ($BOARD)"
    puts $fh "- Top: $TOP"
    puts $fh "- Source: commit $src_commit; relative to it: $src_state"
    puts $fh "- Clock: [get_property NAME [lindex $clocks 0]] at ${clk_period} ns ([format %.1f [expr {1000.0 / $clk_period}]] MHz)[expr {$SWEEP_RUN ? {, applied before synthesis} : {}}]"
    puts $fh "- Post-route WNS ${wns} ns / WHS ${whs} ns / WPWS ${wpws} ns, ${drc_errors} DRC errors"
    foreach l $group_lines { puts $fh "- Path group $l" }
    puts $fh "- check_timing: [join $scope_line {, }]"
    puts $fh "- Worst setup path: `$worst_desc`"
}

if {[llength $reasons] > 0} {
    foreach r $reasons { puts "ERROR: $r" }
    puts "== GATE FAILED =="
    set fh [open [file join $rptdir GATE_FAILED.md] w]
    puts $fh "# GATE FAILED -- a failure record, not a timing result"
    puts $fh ""
    puts $fh "Generated by scripts/build.tcl. Do not edit by hand."
    puts $fh ""
    run_facts $fh
    puts $fh ""
    puts $fh "Failed because:"
    foreach r $reasons { puts $fh "- $r" }
    puts $fh ""
    puts $fh "Nothing in this directory is evidence that the design closes timing."
    close $fh
    if {$PUBLISH_FAILED} {
        file mkdir $outdir
        foreach f [glob -nocomplain [file join $rptdir *]] {
            file copy -force $f [file join $outdir [file tail $f]]
        }
        puts "== published to results/$RUN as a failure record (GATE_FAILED.md) =="
    } else {
        puts "       Reports left in [file join build $RUN reports] -- NOT published to results/."
    }
    exit 1
}

# Publish only now, and stamp the scope onto the numbers so the caveats travel
# with them.
file mkdir $outdir
foreach f [glob -nocomplain [file join $rptdir *.rpt]] {
    file copy -force $f [file join $outdir [file tail $f]]
}
set fh [open [file join $outdir BUILD_SCOPE.md] w]
puts $fh "# Scope of the reports in this directory"
puts $fh ""
puts $fh "Generated by scripts/build.tcl. Do not edit by hand."
puts $fh ""
run_facts $fh
puts $fh ""
puts $fh "**Every synchronous path in the design is timed against one clock**, including"
puts $fh "reset recovery and removal; every check_timing check above reports zero. All"
puts $fh "top-level I/O is asynchronous or human-scale and is set_false_path, with the"
puts $fh "reason written in constraints/target_board.xdc. No data crosses a pin on a"
puts $fh "clock edge, so there is no I/O timing to close."
puts $fh ""
if {$SWEEP_RUN} {
    puts $fh "**This is an Fmax-sweep run at ${PERIOD} ns.** The Basys 3 oscillator is fixed at"
    puts $fh "100 MHz with no MMCM; this period is not usable on the board. No bitstream was written."
} else {
    puts $fh "Latency in nanoseconds is LATENCY_CYCLES * 10.000 ns at the board's fixed 100 MHz."
    puts $fh "The bitstream was written to build/ and has not been run on a board."
}
close $fh

puts "== published [llength [glob -nocomplain [file join $outdir *.rpt]]] reports to results/$RUN =="
puts "== build complete: $RUN =="
exit 0
