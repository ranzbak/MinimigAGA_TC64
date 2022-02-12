################################################################################
# IO constraints DDR3 memory qmtech xc7ac100t
################################################################################

# Internal VREF
set_property INTERNAL_VREF 0.675 [get_iobanks 16]

# ddram:0.a
set_property SLEW FAST IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[*]}]

# ddram:0.a
set_property PACKAGE_PIN E17 [get_ports {ddr3_addr_o[0]}]
set_property PACKAGE_PIN G17 [get_ports {ddr3_addr_o[1]}]
set_property PACKAGE_PIN F17 [get_ports {ddr3_addr_o[2]}]
set_property PACKAGE_PIN C17 [get_ports {ddr3_addr_o[3]}]
set_property PACKAGE_PIN G16 [get_ports {ddr3_addr_o[4]}]
set_property PACKAGE_PIN D16 [get_ports {ddr3_addr_o[5]}]
set_property PACKAGE_PIN H16 [get_ports {ddr3_addr_o[6]}]
set_property PACKAGE_PIN E16 [get_ports {ddr3_addr_o[7]}]
set_property PACKAGE_PIN H14 [get_ports {ddr3_addr_o[8]}]
set_property PACKAGE_PIN F15 [get_ports {ddr3_addr_o[9]}]
set_property PACKAGE_PIN F20 [get_ports {ddr3_addr_o[10]}]
set_property PACKAGE_PIN H15 [get_ports {ddr3_addr_o[11]}]
set_property PACKAGE_PIN C18 [get_ports {ddr3_addr_o[12]}]
set_property PACKAGE_PIN G15 [get_ports {ddr3_addr_o[13]}]

# ddram:0.ba
set_property SLEW FAST IOSTANDARD SSTL135 [get_ports {ddr3_ba_o[*]}]
set_property PACKAGE_PIN B17 [get_ports {ddr3_ba_o[0]}]
set_property PACKAGE_PIN D18 [get_ports {ddr3_ba_o[1]}]
set_property PACKAGE_PIN A17 [get_ports {ddr3_ba_o[2]}]

# ddram:0.ras_n
set_property PACKAGE_PIN A19 [get_ports ddr3_ras_n_o]
set_property SLEW FAST IOSTANDARD SSTL135 [get_ports {ddr3_ras_n_o}]

# ddram:0.cas_n
set_property PACKAGE_PIN B19 [get_ports ddr3_cas_n_o]
set_property SLEW FAST IOSTANDARD SSTL135 [get_ports {ddr3_cas_n_o}]

# ddram:0.we_n
set_property PACKAGE_PIN A18 [get_ports ddr3_we_n_o]
set_property SLEW FAST IOSTANDARD SSTL135 [get_ports {ddr3_we_n_o}]

# ddram:0.cs_n
set_property PACKAGE_PIN L2 [get_ports {ddr3_cs_n_o}]
set_property SLEW FAST IOSTANDARD SSTL135 [get_ports {ddr3_cs_n_o}]

# ddram:0.dm
set_property SLEW FAST IOSTANDARD SSTL135 [get_ports {ddr3_dm_o[*]}]
set_property PACKAGE_PIN A22 [get_ports {ddr3_dm_o[0]}]
set_property PACKAGE_PIN C22 [get_ports {ddr3_dm_o[1]}]

# ddram:0.dq
set_property IN_TERM UNTUNED_SPLIT_50 SLEW FAST IOSTANDARD SSTL135 [get_ports {ddr3_dq_io[*]}]
set_property PACKAGE_PIN D21 [get_ports {ddr3_dq_io[0]}]
set_property PACKAGE_PIN C21 [get_ports {ddr3_dq_io[1]}]
set_property PACKAGE_PIN B22 [get_ports {ddr3_dq_io[2]}]
set_property PACKAGE_PIN B21 [get_ports {ddr3_dq_io[3]}]
set_property PACKAGE_PIN D19 [get_ports {ddr3_dq_io[4]}]
set_property PACKAGE_PIN E20 [get_ports {ddr3_dq_io[5]}]
set_property PACKAGE_PIN C19 [get_ports {ddr3_dq_io[6]}]
set_property PACKAGE_PIN D20 [get_ports {ddr3_dq_io[7]}]
set_property PACKAGE_PIN C23 [get_ports {ddr3_dq_io[8]}]
set_property PACKAGE_PIN D23 [get_ports {ddr3_dq_io[9]}]
set_property PACKAGE_PIN B24 [get_ports {ddr3_dq_io[10]}]
set_property PACKAGE_PIN B25 [get_ports {ddr3_dq_io[11]}]
set_property PACKAGE_PIN C24 [get_ports {ddr3_dq_io[12]}]
set_property PACKAGE_PIN C26 [get_ports {ddr3_dq_io[13]}]
set_property PACKAGE_PIN A25 [get_ports {ddr3_dq_io[14]}]
set_property PACKAGE_PIN B26 [get_ports {ddr3_dq_io[15]}]

# ddram:0.dqs_p
set_property SLEW FAST IN_TERM UNTUNED_SPLIT_50 IOSTANDARD DIFF_SSTL135 [get_ports {ddr3_dqs_p_io[*]}]

# ddram:0.dqs_n
set_property SLEW FAST IN_TERM UNTUNED_SPLIT_50 IOSTANDARD DIFF_SSTL135 [get_ports {ddr3_dqs_n_io[*]}]
set_property PACKAGE_PIN B20 [get_ports {ddr3_dqs_p_io[0]}]
set_property PACKAGE_PIN A20 [get_ports {ddr3_dqs_n_io[0]}]
set_property PACKAGE_PIN A23 [get_ports {ddr3_dqs_p_io[1]}]
set_property PACKAGE_PIN A24 [get_ports {ddr3_dqs_n_io[1]}]

# ddram:0.clk_p
set_property SLEW FAST IOSTANDARD SSTL135 IO_BUFFER_TYPE NONE [get_ports {ddr3_ck_p_o}]

# ddram:0.clk_n
set_property PACKAGE_PIN F18 [get_ports ddr3_ck_p_o]
set_property PACKAGE_PIN F19 [get_ports ddr3_ck_n_o]
set_property SLEW FAST IOSTANDARD SSTL135 IO_BUFFER_TYPE NONE [get_ports {ddr3_ck_n_o}]

# ddram:0.cke
set_property PACKAGE_PIN E18 [get_ports ddr3_cke_o]
set_property SLEW FAST IOSTANDARD SSTL135[get_ports {ddr3_cke_o}]

# ddram:0.odt
set_property PACKAGE_PIN G19 [get_ports ddr3_odt_o]
set_property SLEW FAST IOSTANDARD SSTL135[get_ports {ddr3_odt_o}]

# ddram:0.reset_n
set_property PACKAGE_PIN H17 [get_ports ddr3_reset_n_o]
set_property SLEW FAST IOSTANDARD SSTL135[get_ports {ddr3_reset_n_o}]

