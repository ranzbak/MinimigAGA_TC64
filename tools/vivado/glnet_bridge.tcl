# Vivado's funcsim netlist of rtl/soc/ap68040_minimig.sv with the faster core
# (lib/AP68040-faster), for sim/ddr3_cpu GLNET=<netlist.v>: the board's logic
# instead of the source, which xsim cannot be trusted with (the core's RAMs
# and unreset flops start X there; on the board and in Verilator they are 0).
#
#   LC_ALL=C LANG=C LD_LIBRARY_PATH=<tinfo5 shim> \
#     vivado -mode batch -nojournal -source tools/vivado/glnet_bridge.tcl \
#            -tclargs <repo> <out_dir> [ICHIP]
#   python3 tools/vivado/glnet_rename.py <out_dir>/net_raw.v <out_dir>/net.v
#   GLNET=<out_dir>/net.v FASTER=1 CPU_RATIO=2 FREECORE=1 RUNTAG=gl \
#     sim/ddr3_cpu/run.sh --ap040
#
# Out of context, the board's part, the bridge's default parameters (the
# board configuration) and ICHIP (default 1).  Also writes the synthesis
# utilization and timing estimate; grep the log for "decloning" and
# "inactive write enable" (the two Vivado 2023.2 traps in this core).
lassign $argv REPO O ICHIP
if {$ICHIP eq ""} { set ICHIP 1 }
set R $REPO/lib/AP68040-faster/rtl
file mkdir $O
set_param general.maxThreads 4
foreach f [list \
  $R/ap68040_pkg.sv $R/gen/ap68040_upkg.sv $R/ap68040_alu.sv $R/ap68040_alu_slow.sv \
  $R/ap68040_muldiv.sv $R/ap68040_biu.sv $R/ap68040_ram.sv $R/ap68040_atc.sv \
  $R/ap68040_dmu.sv $R/ap68040_predec.sv $R/ap68040_fetch.sv $R/ap68040_decode.sv \
  $R/ap68040_useq.sv $R/ap68040_fpif.sv $R/ap68040_backend.sv $R/ap68040_snoop.sv $R/ap68040.sv \
  $REPO/rtl/soc/ap68040_minimig.sv] {
  read_verilog -sv $f
}
read_verilog $R/fpu/ap040_fpu.v
synth_design -top ap68040_minimig -part xc7a100tfgg676-2 -mode out_of_context \
  -include_dirs [list $R $R/gen $R/fpu] -generic ICHIP=$ICHIP
create_clock -name clk -period 17.630 [get_ports clk]
report_utilization -file $O/synth_util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $O/hier_util.rpt
report_timing_summary -max_paths 20 -file $O/synth_timing.rpt
write_verilog -mode funcsim -force $O/net_raw.v
puts "GLNET DONE"
