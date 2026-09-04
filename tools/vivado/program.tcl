open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
puts "=== devices: [get_hw_devices] ; using $dev ==="
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE [lindex $argv 0] $dev
program_hw_device $dev
refresh_hw_device $dev
puts "=== DONE: [get_property PROGRAM.FILE $dev] loaded, DONE pin = [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev] ==="
close_hw_manager
