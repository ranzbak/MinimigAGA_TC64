set out [file dirname [info script]]
set src /home/paul/work/fpga/Xilinx/artix7/minimig/AP68040/rtl
create_project -in_memory -part xc7a100tfgg676-2
set_property include_dirs $src [current_fileset]
foreach f [glob $src/*.v] { read_verilog -sv $f }
read_verilog -sv $src/primitives/dpram.v
# constrain the core clock at the Minimig CPU clock so timing numbers mean something
synth_design -top ap040_tg68k_compat -part xc7a100tfgg676-2 -mode out_of_context \
  -generic AP040_HAS_MMU=1 -generic AP040_HAS_FPU=1 -generic AP040_ENABLE_CACHE=1
create_clock -period 8.815 -name clk [get_ports clk]
report_utilization -file $out/util_full.rpt
report_timing_summary -no_detailed_paths -file $out/timing_full.rpt
report_timing -max_paths 3 -file $out/worst_full.rpt
puts "=== FULL DONE ==="
