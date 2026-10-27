# ooc_pal_to_ddr.tcl -- resources of the HDMI output chain (rtl/openaars/
# adv7511: pal_to_ddr and its children) on their own: out-of-context
# synthesis, top pal_to_ddr, the board's part.  The before/after numbers of
# the chain's clean-up (sim/hdmi_upsample proves the picture, this the size).
#
#   LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C \
#     /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log build/ooc_pal_to_ddr/vivado.log \
#       -source tools/vivado/ooc_pal_to_ddr.tcl [-tclargs <outdir>]
#
# Run from the repo root (mkdir -p build/ooc_pal_to_ddr first for the -log).
# The libtinfo shim as in tools/vivado/ooc_hostcpu/README.md; never -stack.
# <outdir> defaults to build/ooc_pal_to_ddr (git-ignored).  Results there:
# util_hier.rpt (report_utilization -hierarchical), util.rpt, synth.dcp.
# About two minutes.
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../..]
set outdir [file normalize [expr {[llength $argv] > 0 ? [lindex $argv 0] : "$repo/build/ooc_pal_to_ddr"}]]
set part xc7a100tfgg676-2
file mkdir $outdir

set A $repo/rtl/openaars/adv7511
read_verilog -sv $A/pal_to_ddr.sv $A/signal_generator.sv $A/frame_freq.sv
read_verilog $A/pal_to_hd_upsample.v $A/crt_post.v $A/crt_beamh.v $A/bram_tdp.v $A/adv_ddr.v
# The CRT tables: pal_to_ddr's CRT_*_FILE parameters name them without a
# path ($readmemh by name); as memory files of the design synthesis finds
# them, as build_ap040.tcl's add_src does in the project.
foreach m {crt_wrom crt_lut crt_bloom crt_hdec crt_henc crt_hk crt_sdec crt_senc crt_swrom} {
    read_mem $A/$m.mem
}

synth_design -top pal_to_ddr -part $part -mode out_of_context
write_checkpoint -force $outdir/synth.dcp
report_utilization -file $outdir/util.rpt
report_utilization -hierarchical -file $outdir/util_hier.rpt
puts "=== ooc_pal_to_ddr: $outdir/util_hier.rpt"
