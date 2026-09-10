# run_sim.tcl -- batch xsim run for the market pipeline testbenches.
#
#   make sim                 # default TOP
#   make sim TOP=tb_event_decoder
#
# Invoked as: vivado -mode batch -notrace -source scripts/run_sim.tcl -tclargs $(TOP)
# Runs xvlog/xelab/xsim as external steps so the same commands can be pasted
# into a shell when debugging a failure.

set TOP [expr {[llength $argv] > 0 ? [lindex $argv 0] : "tb_market_pipeline_top"}]

set root [file normalize [file dirname [info script]]/..]
cd $root

# market_pkg.sv must lead the file list: it defines every width, enum and
# struct the rest of the design elaborates against.
set pkg [file join $root rtl market_pkg.sv]
set rtl [lsort [glob -nocomplain [file join $root rtl *.sv]]]
set tb  [lsort [glob -nocomplain [file join $root tb  *.sv]]]

if {[llength $rtl] == 0} {
    puts "ERROR: no sources in rtl/. Nothing to simulate."
    exit 1
}
if {[llength $tb] == 0} {
    puts "ERROR: no sources in tb/. Nothing to simulate."
    exit 1
}
if {[file exists $pkg]} {
    set rtl [concat [list $pkg] [lsearch -all -inline -not -exact $rtl $pkg]]
}

set srcs [concat $rtl $tb]

proc run_step {label args} {
    puts "== $label =="
    puts "   [join $args " "]"
    if {[catch {exec -ignorestderr {*}$args >@ stdout 2>@ stderr} err]} {
        puts "ERROR: $label failed: $err"
        exit 1
    }
}

run_step xvlog xvlog -sv -L uvm {*}$srcs
run_step xelab xelab -debug typical -relax -s ${TOP}_snap $TOP

# -R runs the simulation to completion and exits.
#
# xsim exits 0 even when the testbench hits $fatal, so the process exit code
# alone will happily report a failing simulation as a passing build. The only
# reliable signal is the log: $fatal prints "Fatal:", $error and a failing SVA
# print "Error:". Scan for both and fail on either.
puts "== xsim =="
file mkdir [file join $root build]
set simlog [file join $root build sim_${TOP}.log]
catch {exec -ignorestderr xsim ${TOP}_snap -R >& $simlog}

set fh [open $simlog r]
set out [read $fh]
close $fh
puts $out

set bad [lsearch -all -inline -regexp [split $out "\n"] {^\s*(Fatal|Error|FATAL_ERROR):}]
if {[llength $bad] > 0} {
    puts "== SIMULATION FAILED: $TOP =="
    foreach line $bad { puts "   $line" }
    puts "   full log: [file join build sim_${TOP}.log]"
    exit 1
}

puts "== sim complete: $TOP =="
exit 0
