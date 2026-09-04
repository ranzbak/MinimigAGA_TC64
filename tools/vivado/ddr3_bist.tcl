# DDR3 built-in self-test over JTAG (stage-A bitstream with vio_ddr3).
# usage: -tclargs <bitstream> "<pattern list>" <range_log2> [program] [dqs_sweep <from> <to>]
set bit [lindex $argv 0]; set ltx [file rootname $bit].ltx
set patterns [lindex $argv 1]; set range [lindex $argv 2]
set do_prog [expr {[lsearch $argv program] >= 0}]
open_hw_manager; connect_hw_server -allow_non_jtag; open_hw_target
set dev [lindex [get_hw_devices] 0]; current_hw_device $dev
set_property PROBES.FILE $ltx $dev; set_property FULL_PROBES.FILE $ltx $dev; set_property PROGRAM.FILE $bit $dev
if {$do_prog} { program_hw_device $dev; puts "=== programmed $bit ===" }
refresh_hw_device $dev
set vio [get_hw_vios -of_objects $dev]
foreach p [get_hw_probes -of_objects $vio] { catch {set_property INPUT_VALUE_RADIX UNSIGNED $p}; catch {set_property OUTPUT_VALUE_RADIX UNSIGNED $p} }
proc P {n} { global vio; set p [get_hw_probes -of_objects $vio -filter "NAME =~ *$n"]; if {[llength $p] != 1} { error "probe $n -> $p" }; return $p }
proc rd {n} { global vio; refresh_hw_vio $vio; return [get_property INPUT_VALUE [P $n]] }
proc wr {n v} { global vio; set_property OUTPUT_VALUE $v [P $n]; commit_hw_vio $vio }
puts "=== pll_locked [rd ddr3_pll_locked]  init_done [rd ddr3_init_done]  busy [rd bist_busy] ==="
proc run_bist {pat range} {
  wr bist_pattern $pat; wr bist_range_log2 $range; wr bist_mode 0; wr bist_start 0
  set t0 [clock milliseconds]; wr bist_start 1; after 20; wr bist_start 0
  set n 0
  while {[rd bist_done] != 1 && $n < 6000} { after 50; incr n }
  set dt [expr {[clock milliseconds] - $t0}]
  puts [format "=== pattern %d range 2^%d: done %s busy %s errors %s lines %s first_err_addr 0x%08x xor 0x%08x  (%d ms) ===" \
    $pat $range [rd bist_done] [rd bist_busy] [rd bist_err_count] [rd bist_lines_done] [rd bist_first_err_addr] [rd bist_first_err_xor] $dt]
  return [rd bist_err_count]
}
set a [lsearch $argv align]
if {$a >= 0} {
  wr phy_dqs_inc 0; wr phy_dqs_rst 0; wr phy_dq_inc 0; wr phy_dq_rst 0
  wr phy_rdlat [lindex $argv [expr {$a+1}]]; wr phy_rdsel [lindex $argv [expr {$a+2}]]
  wr phy_cfg_valid 1; after 5; wr phy_cfg_valid 0
  puts "=== alignment applied: rdlat [lindex $argv [expr {$a+1}]] rdsel [lindex $argv [expr {$a+2}]] ==="
}
proc run_bist_quiet {pat range} {
  wr bist_pattern $pat; wr bist_range_log2 $range; wr bist_mode 0; wr bist_start 0
  wr bist_start 1; after 20; wr bist_start 0
  set n 0
  while {[rd bist_done] != 1 && $n < 6000} { after 50; incr n }
  return [rd bist_err_count]
}
set g [lsearch $argv grid]
if {$g >= 0} {
  # read-alignment grid: rdlat x rdsel, pattern = first of the list, small range. cfg_valid pulse applies rdlat/rdsel.
  wr phy_dqs_inc 0; wr phy_dqs_rst 0; wr phy_dq_inc 0; wr phy_dq_rst 0
  foreach rl {3 4 5 6 7} {
    set row ""
    for {set rs 0} {$rs < 16} {incr rs} {
      wr phy_rdlat $rl; wr phy_rdsel $rs; wr phy_cfg_valid 1; after 5; wr phy_cfg_valid 0
      set e [run_bist_quiet [lindex $patterns 0] $range]
      append row [format " %6s" $e]
    }
    puts "GRID rdlat $rl : rdsel 0..15 errors:$row"
  }
  close_hw_manager; exit
}
set dqs2 [lsearch $argv dq_sweep]
if {$dqs2 >= 0} {
  set steps [lindex $argv [expr {$dqs2+1}]]
  wr phy_dq_inc 0; wr phy_dq_rst 3; wr phy_cfg_valid 0; wr phy_cfg_valid 1; after 5; wr phy_cfg_valid 0; wr phy_dq_rst 0
  set tap 0
  for {set k 0} {$k < $steps} {incr k} {
    set e [run_bist_quiet [lindex $patterns 0] $range]
    puts "SWEEP dq_tap $tap errors $e"
    wr phy_dq_inc 3; wr phy_cfg_valid 1; after 5; wr phy_cfg_valid 0; wr phy_dq_inc 0
    set tap [expr {($tap + 1) % 32}]
  }
  close_hw_manager; exit
}
set i [lsearch $argv dqs_sweep]
if {$i >= 0} {
  set steps [lindex $argv [expr {$i+1}]]
  wr phy_dqs_inc 0; wr phy_dqs_rst 3; wr phy_cfg_valid 0; wr phy_cfg_valid 1; after 5; wr phy_cfg_valid 0; wr phy_dqs_rst 0
  set tap 27
  for {set k 0} {$k < $steps} {incr k} {
    set e [run_bist_quiet [lindex $patterns 0] $range]
    puts "SWEEP dqs_tap $tap errors $e"
    wr phy_dqs_inc 3; wr phy_cfg_valid 1; after 5; wr phy_cfg_valid 0; wr phy_dqs_inc 0
    set tap [expr {($tap + 1) % 32}]
  }
} else {
  foreach pat $patterns { run_bist $pat $range }
}
close_hw_manager
