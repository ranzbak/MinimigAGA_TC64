set d /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo/RTL
foreach f {eightthirtytwo_pkg eightthirtytwo_alu eightthirtytwo_shifter eightthirtytwo_aligner eightthirtytwo_aligner_le eightthirtytwo_decode eightthirtytwo_fetchloadstore eightthirtytwo_hazard eightthirtytwo_debug eightthirtytwo_cpu} { read_vhdl $d/$f.vhd }
read_vhdl [file dirname [info script]]/w832.vhd
