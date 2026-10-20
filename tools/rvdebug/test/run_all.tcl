# run_all.tcl -- the bridge's unit tests:  tclsh tools/rvdebug/test/run_all.tcl
# Exit status 0 = all pass.  SEED=<n> fixes the random streams (default: a
# new seed, printed); RANDOM_STREAMS=<n> (default 1000).
set here [file dirname [file normalize [info script]]]
source [file join $here testlib.tcl]
if {[info exists env(SEED)]} { set seed $env(SEED) } else { set seed [expr {[clock milliseconds] % 1000000}] }
expr {srand($seed)}
puts "seed $seed"
set t0 [clock seconds]
foreach f {test_core.tcl test_equiv.tcl test_hex.tcl} {
    puts "--- $f"
    source [file join $here $f]
}
puts "=== RVDEBUG TESTS: $test::pass passed, $test::fail failed ([expr {[clock seconds] - $t0}] s, seed $seed)"
if {$test::fail} {
    puts "failed: $test::failed"
    exit 1
}
exit 0
