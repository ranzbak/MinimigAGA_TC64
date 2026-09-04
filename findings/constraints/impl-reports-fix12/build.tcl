set out [file dirname [info script]]/out_fix12b
set R /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64
open_project $R/project_1/project_1.xpr
set x $R/fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc
if {[get_files -quiet -of_objects [get_filesets constrs_1] $x] ne ""} { remove_files -fileset constrs_1 $x }
if {[get_files -quiet -of_objects [get_filesets XC7A100T] $x] eq ""} { add_files -fileset XC7A100T -norecurse $x }
set_property USED_IN {synthesis implementation} [get_files -of_objects [get_filesets XC7A100T] $x]
puts "=== runs use: synth=[get_property CONSTRSET [get_runs synth_1]] impl=[get_property CONSTRSET [get_runs impl_1]] ==="
foreach f [get_files -of_objects [get_filesets XC7A100T]] { puts "  XC7A100T: [file tail $f]" }
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "=== impl_1 status: [get_property STATUS [get_runs impl_1]] / progress [get_property PROGRESS [get_runs impl_1]] ==="
open_run impl_1
report_timing_summary -report_unconstrained -max_paths 5 -file $out/timing_summary.rpt
report_methodology -file $out/methodology.rpt
check_timing -verbose -override_defaults {no_input_delay no_output_delay} -file $out/check_timing.rpt
report_exceptions -ignored -file $out/exceptions_ignored.rpt
report_clock_interaction -file $out/clock_interaction.rpt
report_cdc -details -file $out/cdc.rpt
report_timing -hold -from [get_clocks dll_28] -to [get_clocks clk_114] -max_paths 3 -file $out/hold_dll28_clk114.rpt
report_timing -to [get_ports {dr_a[*] dr_ba[*] dr_dqm[*] dr_ras_n dr_cas_n dr_we_n dr_d[*]}] -max_paths 3 -file $out/sdram_out.rpt
report_timing -from [get_ports {dr_d[*]}] -max_paths 3 -delay_type min_max -file $out/sdram_in.rpt
report_timing -from [get_clocks clk_sd_rd] -to [get_clocks clk_114] -max_paths 3 -delay_type min_max -file $out/sdram_retime.rpt
report_timing -to [get_ports {dv_d[*] dv_de dv_hsync dv_vsync}] -max_paths 3 -delay_type min_max -file $out/dv_out.rpt
report_timing -from [get_cells -hier -filter {NAME =~ "openaars_virtual_top/tg68k/pf68K_Kernel_inst/*" && (IS_SEQUENTIAL || PRIMITIVE_TYPE =~ "DMEM.*")}] -max_paths 3 -file $out/tg68k.rpt
report_timing -from [get_clocks {dll_28 clk_114 clk_sd_114}] -to [get_clocks clk_148] -max_paths 3 -file $out/to_clk148.rpt

report_timing -from [get_ports {dr_d[*]}] -to [get_clocks clk_sd_rd] -delay_type min -path_type full_clock_expanded -max_paths 2 -file $out/sdram_in_hold.rpt
report_timing -from [get_ports {dr_d[*]}] -to [get_clocks clk_sd_rd] -delay_type max -path_type full_clock_expanded -max_paths 2 -file $out/sdram_in_setup.rpt
report_utilization -file $out/utilization.rpt
puts "=== ALL DONE ==="
