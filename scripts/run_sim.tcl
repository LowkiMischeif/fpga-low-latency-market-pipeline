# run_sim.tcl -- batch xsim run for the market pipeline testbenches.
#
#   make sim                 # default TOP
#   make sim TOP=tb_event_decoder
#   make sim TOP=tb_decode_validate PLUSARGS="SEED=7"
#
# Invoked as:
#   vivado -mode batch -notrace -source scripts/run_sim.tcl -tclargs $(TOP) [plusarg ...]
# Runs xvlog/xelab/xsim as external steps so the same commands can be pasted
# into a shell when debugging a failure.
#
# Every tclarg after the top name is a NAME=VALUE plusarg forwarded to the
# simulation. Without this the +SEED plusarg the testbenches echo into the log
# could never actually be set, so a "reproduce with this seed" instruction had
# no mechanism behind it.

set TOP [expr {[llength $argv] > 0 ? [lindex $argv 0] : "tb_market_pipeline_top"}]
set PLUSARGS [lrange $argv 1 end]

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

# --maxlogsize caps the log at 64 MB. A DUT broken badly enough to fail an
# assertion on every clock edge produced a 1.1 GB log during mutation testing,
# which this script then tried to slurp into a single Tcl string. The cap makes
# a catastrophic failure reportable instead of fatal to the harness -- and the
# PASS gate below is what keeps a truncated log from reading as success.
set xsim_cmd [list xsim ${TOP}_snap -R --maxlogsize 64]
foreach pa $PLUSARGS { lappend xsim_cmd --testplusarg $pa }
puts "   [join $xsim_cmd " "]"
catch {exec -ignorestderr {*}$xsim_cmd >& $simlog}

set fh [open $simlog r]
set out [read $fh]
close $fh
puts $out

set lines [split $out "\n"]
set bad [lsearch -all -inline -regexp $lines {^\s*(Fatal|Error|FATAL_ERROR):}]
if {[llength $bad] > 0} {
    puts "== SIMULATION FAILED: $TOP =="
    foreach line [lrange $bad 0 49] { puts "   $line" }
    if {[llength $bad] > 50} {
        puts "   ... and [expr {[llength $bad] - 50}] more"
    }
    puts "   full log: [file join build sim_${TOP}.log]"
    exit 1
}

# A clean log is not the same as a completed run. If xsim dies -- crash, log
# cap, killed process -- it leaves no Fatal:/Error: line behind and the scan
# above reports success on a simulation that never finished. Every testbench
# ends by printing "PASS: <name>"; require that marker.
if {[llength [lsearch -all -inline -regexp $lines {^\s*PASS:}]] == 0} {
    puts "== SIMULATION FAILED: $TOP =="
    puts "   no PASS: marker in the log -- the run did not reach the end of the"
    puts "   testbench (crash, log-size cap, or a missing \$display)."
    puts "   full log: [file join build sim_${TOP}.log]"
    exit 1
}

puts "== sim complete: $TOP =="
exit 0
