set P /tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/3b5e887b-e330-40a2-82fb-18928449948e/scratchpad/tinycores/src/ibex/vendor/lowrisc_ip/ip
set R /tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/3b5e887b-e330-40a2-82fb-18928449948e/scratchpad/tinycores/src/ibex/rtl
set_property include_dirs [list $P/prim/rtl $P/../dv/sv/dv_utils] [current_fileset]
set pk [list $P/prim/rtl/prim_util_pkg.sv $P/prim/rtl/prim_mubi_pkg.sv $P/prim/rtl/prim_secded_pkg.sv $P/prim/rtl/prim_count_pkg.sv $P/prim_generic/rtl/prim_ram_1p_pkg.sv $P/prim/rtl/prim_cipher_pkg.sv $R/ibex_pkg.sv $R/ibex_cheriot_pkg.sv]
read_verilog -sv $pk
foreach f [glob $R/*.sv] { if {[lsearch $pk $f] < 0 && ![regexp {tracer|tracing|ibex_register_file_latch} $f]} { read_verilog -sv $f } }
foreach m {prim_buf prim_flop prim_and2 prim_clock_gating prim_clock_mux2 prim_ram_1p} { read_verilog -sv $P/prim_generic/rtl/$m.sv }
foreach m {prim_count prim_onehot_check prim_onehot_enc prim_onehot_mux prim_secded_inv_39_32_dec prim_secded_inv_39_32_enc prim_ram_1p_scr prim_ram_1p_adv prim_lfsr prim_prince prim_subst_perm prim_fifo_sync prim_fifo_sync_cnt prim_sec_anchor_buf prim_sec_anchor_flop prim_secded_inv_64_57_dec prim_secded_inv_64_57_enc prim_secded_inv_28_22_dec prim_secded_inv_28_22_enc} { if {[file exists $P/prim/rtl/$m.sv]} { read_verilog -sv $P/prim/rtl/$m.sv } }
read_verilog -sv [file dirname [info script]]/wibex.sv
