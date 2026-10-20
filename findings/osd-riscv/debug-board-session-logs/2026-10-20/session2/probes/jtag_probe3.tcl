# probe3: rvb::main called from a wrapper after sourcing with RVBRIDGE_NO_MAIN=1
set ::env(RVBRIDGE_NO_MAIN) 1
source -notrace /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/rvdebug/rv_jtag_bridge.tcl
puts "PROBE3: calling rvb::main"; flush stdout
if {[catch {rvb::main {-exit_on_disconnect 1}} err]} { puts "PROBE3: main error: $err" }
puts "PROBE3: main returned"
