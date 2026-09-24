# List EVERY failing setup path of a routed checkpoint, one line each.
#
# report_timing_summary prints only the single worst path per clock group, so
# a build with (say) 22 failing endpoints spread over four groups shows four
# paths and the rest have to be inferred from the TNS columns.  This opens the
# routed checkpoint and asks for all of them, which is what a gate image's
# verdict should be written from (findings/ap040-pipelined/PLAN.md, the
# "bar" in hw-gate1-checklist.md section 2).
#
#   env LD_LIBRARY_PATH=$HOME/lib/tinfo5 \
#     /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -nolog \
#     -source failing_paths.tcl -tclargs <routed.dcp> <out.txt>
#
# The routed checkpoint of the last build is
#   <tree>/project_1/project_1.runs/impl_1/minimig_openaars_top_routed.dcp
# and the NEXT build overwrites it -- copy it next to the build's reports if
# the listing may be wanted later.
#
# Vivado 2023.2 needs the libtinfo.so.5 shim and must NOT be given -stack
# (memory/vivado-lab-gotchas.md).

set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp

set paths [get_timing_paths -max_paths 500 -nworst 500 -slack_lesser_than 0 -setup]
set fh [open $out w]
puts $fh "routed checkpoint : $dcp"
puts $fh "failing setup paths: [llength $paths]"
puts $fh ""
puts $fh [format "%8s  %-16s %-16s  %s" "slack" "from clock" "to clock" "startpoint -> endpoint"]
foreach p $paths {
    set sc [get_property STARTPOINT_CLOCK $p]
    set ec [get_property ENDPOINT_CLOCK $p]
    puts $fh [format "%8.3f  %-16s %-16s  %s -> %s" \
        [get_property SLACK $p] $sc $ec \
        [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
close $fh
puts "=== WROTE $out ==="
