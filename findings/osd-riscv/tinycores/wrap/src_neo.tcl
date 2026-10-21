set fl [open /tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/3b5e887b-e330-40a2-82fb-18928449948e/scratchpad/tinycores/src/neorv32/rtl/file_list_core.f]; set lines [split [read $fl] "\n"]; close $fl
foreach l $lines { set l [string trim $l]; if {$l eq ""} continue
  regsub {\$NEORV32_HOME} $l /tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/3b5e887b-e330-40a2-82fb-18928449948e/scratchpad/tinycores/src/neorv32 l; read_vhdl -vhdl2008 -library neorv32 $l }
read_vhdl -vhdl2008 [file dirname [info script]]/wneo.vhd
