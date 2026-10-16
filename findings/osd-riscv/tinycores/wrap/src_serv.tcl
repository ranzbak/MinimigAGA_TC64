foreach f [glob /tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/3b5e887b-e330-40a2-82fb-18928449948e/scratchpad/tinycores/src/serv/rtl/*.v] { if {![string match *synth_wrapper* $f]} { read_verilog $f } }
read_verilog [file dirname [info script]]/wserv.v
