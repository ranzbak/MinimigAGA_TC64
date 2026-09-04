set out [file dirname [info script]]
set src /home/paul/work/fpga/Xilinx/artix7/minimig/AP68040/rtl
foreach cfg {{nofpu 1 0 1} {min 0 0 0}} {
  lassign $cfg name mmu fpu cache
  create_project -in_memory -part xc7a100tfgg676-2
  set_property include_dirs $src [current_fileset]
  foreach f [glob $src/*.v] { read_verilog -sv $f }
  read_verilog -sv $src/primitives/dpram.v
  synth_design -top ap040_tg68k_compat -part xc7a100tfgg676-2 -mode out_of_context \
    -generic AP040_HAS_MMU=$mmu -generic AP040_HAS_FPU=$fpu -generic AP040_ENABLE_CACHE=$cache
  create_clock -period 8.815 -name clk [get_ports clk]
  report_utilization -file $out/util_$name.rpt
  report_utilization -hierarchical -hierarchical_depth 2 -file $out/util_${name}_hier.rpt
  report_timing -max_paths 1 -file $out/worst_$name.rpt
  close_project
  puts "=== $name DONE ==="
}
