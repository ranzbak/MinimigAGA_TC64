
# Intra clock paths
set_multicycle_path -setup -from [get_clocks -of_objects [get_pins clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 16
set_multicycle_path -hold -from [get_clocks -of_objects [get_pins clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 15

# set_multicycle_path -hold -from [get_clocks -of_objects [get_pins clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 7
set_multicycle_path -setup -from [get_clocks -of_objects [get_pins clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT2]] 4
set_multicycle_path -hold -from [get_clocks -of_objects [get_pins clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT2]] 3
set_multicycle_path -setup -from [get_clocks -of_objects [get_pins clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 4
set_multicycle_path -hold -from [get_clocks -of_objects [get_pins clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 3
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT1]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT1]] 3
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT1]] 8
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT1]] 7
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT2]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_main/CLKOUT2]] 3

# Clock paths in clk (112MHz)
set _xlnx_shared_i0 [get_nets -hierarchical -regexp .*(DPO|mulu_reg|use_base|PC|wbmemmask|regfile_reg).*]
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] -through $_xlnx_shared_i0 -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] -through $_xlnx_shared_i0 -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 3

set _xlnx_shared_i1 [get_nets -hierarchical -regexp .*(oddout_reg|opcode|trap|memory_config_reg|state|enable|SPO|Reset_reg|Flags|memaddr_delta).*]
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] -through $_xlnx_shared_i1 -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] -through $_xlnx_shared_i1 -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 3

set _xlnx_shared_i2 [get_nets -hierarchical -regexp .*(exec).*]
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] -through $_xlnx_shared_i2 -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] -through $_xlnx_shared_i2 -to [get_clocks -of_objects [get_pins clk_main/CLKOUT0]] 3

# set_false_path -from [get_pins -hierarchical -regexp {.*joy(a|b)_reg\[.*\].*}] -to [get_pins -hierarchical -regexp {.*myFampiga/MyMinimig/USERIO1/_sjoy1_reg\[.*\].*}]
