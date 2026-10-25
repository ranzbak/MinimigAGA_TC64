# sdc_ila.tcl -- the SD card path ILA ("u_ila_sdc"), put into the synthesized
# netlist by the build script only: no RTL change, so the core stays
# vendor-neutral and the shipping image is built exactly as without it.
#
# Two ways in:
#   - tools/vivado/build_ap040.tcl with SDC_ILA=1 in the environment makes
#     this file impl_1's opt_design TCL.PRE hook for that run (restored
#     afterwards).  Sourced as the hook it inserts the core into the linked
#     netlist; opt_design then implements it together with the design's IP
#     ILAs ("Generate And Synthesize Debug Cores"), and write_bitstream writes
#     the .ltx with the bitstream.  SDC_ILA_DEPTH (default 2048) is the sample
#     depth.  As a hook it refuses to run without SDC_ILA=1 in the
#     environment: a hook left behind by a build that died before its restore
#     must fail the next (shipping) build loudly, not put the ILA into it.
#   - set ::sdc_ila_lib 1 before sourcing it, and the file only defines
#     sdc_ila_insert, for scripts that call it themselves
#     (tools/vivado/ooc_sdcard/run.tcl with SDC_ILA=1, the cost measurement).
#
# The core: clock = the clock of sdcard_spi's sck_r register (clk_114 on the
# board).  Every probe is a REGISTER output (or a card pin's input buffer):
# synthesis (flatten_hierarchy rebuilt) renames and moves the ports of the
# engine's instances, so a port or a combinational net cannot be found by
# name in the netlist, a register can (<name>_reg / <name>_reg[i]).  A probe
# names the register in the board design (minimig_openaars_top) and, where it
# differs, in tools/vivado/ooc_sdcard/ooc_sdcard_top.v (the OOC check); the
# first that resolves bit for bit is used.  A probe that resolves in neither
# stops the insertion with the list of what is missing (the build then fails
# at opt_design rather than ship a core without it).
#
# The bridge's Gayle-side registers (wr_r, rd_r, act, b_port, b_rst,
# cmd_since, etog) are dll_28 registers, sampled here on clk_114: one capture,
# one time base, one trigger for both sides.  dll_28 -> clk_114 is timed under
# wizard.xdc's 4-cycle multicycle, so such a probe can show its change up to 3
# clk_114 samples late (and the ILA's input register can catch it
# mid-change); every one of them holds for at least one clk7_en period (16
# clk_114 cycles), so none is missed.
#
# Probes, in order (the .ltx names each probe after its net, e.g.
# openaars_virtual_top/g_sdc.sdc_spi/busy):
#   card pins   sck_r (SCK), cs_n_r (CS#), mosi_r (MOSI), sd_miso (the input
#               buffer of sd_m_d0), sd_cd_n (of sd_m_cdet, raw), cd_n_stable
#               (debounced, 1 = no card)
#   host bus    the OSD CPU's register access as cfide decodes it (clk_114,
#               host_bridge.vhd / cfide.vhd): hw_req, wr, addr[23], addr[7:2],
#               q[15:0] (write data) and cfide's ext_req_d.  sdcard_spi sees
#               reg_wstb = addr[23] & addr[7:6] == 0 & addr[5:4] != 3 & hw_req
#               & !ext_req_d & wr (reg_rstb the same with !wr), register index
#               reg_addr = addr[5:2], reg_d = q[15:0].  A CMD write: index 4,
#               the op in q[3:0].
#   op          busy, run (a byte shifting), op_tx, op_rx, op_ctx, op_crx,
#               op_wait, op_ne, cph[1:0] (0 data, 1/2 CRC byte)
#   STATUS      st_crc_ok (bit 1), st_timeout (2), st_aborted (4), st_gone (5),
#               st_refused (6), st_gerr (7), st_misuse (8); busy is bit 0,
#               cd_n_stable bit 3 inverted
#   IRQ         irq_pend[4:0] (IRQPEND: 0 done, 1 RX high, 2 TX low, 3 error,
#               4 card change), irq_r (the irq line)
#   Gayle g_*   g_req_r, g_dir_r, g_port_r, g_wvalid_r (sdcard_spi); the
#               bridge's q_ack (= g_ack), q_err (= g_err), q_rvalid
#               (= g_rvalid), q_wtog (flips with every g_wnext, but also
#               when an owed request is absorbed), q_old, q_dir, q_req_s[1]
#               (q_req_s1): g_wnext is combinational, and from these it is
#               rebuilt offline exactly: g_wnext = g_req_r & q_old & q_dir &
#               (q_req_s1 != q_wtog) & g_wvalid_r
#   counters    cnt[10:0] (COUNT), rxlvl[10:0] (RXLVL)       -- data only
#   bytes       rxsh[7:0] (the receive shifter: the byte at byte_done),
#               poisoned
#   bridge      wr_r (data_wr), rd_r (data_rd: Gayle's dat_req is behind
#               every one), act (active), b_port (port), b_rst (a FIFO reset
#               in the op's first sample), cmd_since[1:0], etog (flips with
#               every Gayle-side error: fifo_reset_seen / reset / abandoned
#               command)
# 105 bits (52 signals) in 12 probe ports, one per group of the table below:
# an ILA port costs about 80 LUTs whatever its width, so the signals share
# ports; the .ltx still lists each signal as its own probe (named after its
# net, renamed ila_<signal> where synthesis left a name like
# <reg>_reg_n_0), and sdc_ila_hwprobes.tcl names them all sdc_<signal>.
#
# Trigger / capture: basic trigger, ALL_PROBE_SAME_MU with 2 comparators per
# port (trigger and capture control), capture control (storage
# qualification) on, no trigger in / out ports, one input pipeline stage
# (the core sits in a 96 % full device).  Measured on the OOC check
# (tools/vivado/ooc_sdcard, SDC_ILA=1 go.sh <name> io; 2048 deep): 1,610 LUT
# (277 of them SRL), 2,651 FF, 6 RAMB36, plus the debug hub (450 LUT, 741
# FF) when the design has no other ILA.  The advanced trigger (trigger state
# machine) would cost 3,569 LUT / 5,170 FF, one port per signal 4,650 LUT /
# 6,123 FF: both left out.  Depth: 4096 is 11 RAMB36 + 1 RAMB18.
# Triggers (compare values on the sdc_<signal> probes, or on the port bits):
#   op start     busy rising (R); or a CMD write: hw_req == 1, ext_req_d == 0,
#                wr == 1, addr23 == 1, addr == 4 (wdata[3:0] = the op)
#   error IRQ    irq_pend[3] rising
#   refuse       st_refused rising
#   Gayle error  st_gerr rising, or q_err == 1
# Capture control, e.g. hw_req rising OR q_wtog / rd_r / q_ack / q_err
# changing, keeps the buffer for events instead of idle cycles.

# probe table: group name width type alternatives
#   group         the ILA probe port (consecutive rows of one group share it)
#   type          T = DATA_AND_TRIGGER, D = DATA
#   alternatives  {inst reg bits} ...: inst is the pattern of a hierarchical
#                 instance (get_cells -hierarchical -filter NAME =~, exactly
#                 one match; {} = the top), reg the register cell in it, with
#                 %d for the bit index when bits is a list of indices (probe
#                 bit 0 first); {ibuf <port>} is the output of that port's
#                 input buffer
set ::sdc_ila_probes {
    card    sck_r         1 T {{*sdc_spi sck_r_reg {}}}
    card    cs_n_r        1 T {{*sdc_spi cs_n_r_reg {}}}
    card    mosi_r        1 T {{*sdc_spi mosi_r_reg {}}}
    card    sd_miso       1 T {{ibuf sd_m_d0}}
    card    sd_cd_n       1 T {{ibuf sd_m_cdet}}
    card    cd_n_stable   1 T {{*sdc_spi cd_n_stable_reg {}}}
    host    hw_req        1 T {{*hostcpu hw_req_reg {}} {{} req_r_reg {}}}
    host    wr            1 T {{*hostcpu wr_reg {}} {{} wr_r_reg {}}}
    host    ext_req_d     1 T {{*mycfide ext_req_d_reg {}} {{} req_d_reg {}}}
    host    addr23        1 T {{*hostcpu addr_reg[23] {}} {{} a23_r_reg {}}}
    addr    addr          6 T {{*hostcpu addr_reg[%d] {2 3 4 5 6 7}} {{} a_r_reg[%d] {2 3 4 5 6 7}}}
    wdata   wdata        16 T {{*hostcpu q_reg[%d] {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}} {{} d_r_reg[%d] {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}}}
    op      busy          1 T {{*sdc_spi busy_reg {}}}
    op      run           1 T {{*sdc_spi run_reg {}}}
    op      op_tx         1 T {{*sdc_spi op_tx_reg {}}}
    op      op_rx         1 T {{*sdc_spi op_rx_reg {}}}
    op      op_ctx        1 T {{*sdc_spi op_ctx_reg {}}}
    op      op_crx        1 T {{*sdc_spi op_crx_reg {}}}
    op      op_wait       1 T {{*sdc_spi op_wait_reg {}}}
    op      op_ne         1 T {{*sdc_spi op_ne_reg {}}}
    op      cph           2 T {{*sdc_spi cph_reg[%d] {0 1}}}
    status  st_crc_ok     1 T {{*sdc_spi st_crc_ok_reg {}}}
    status  st_timeout    1 T {{*sdc_spi st_timeout_reg {}}}
    status  st_aborted    1 T {{*sdc_spi st_aborted_reg {}}}
    status  st_gone       1 T {{*sdc_spi st_gone_reg {}}}
    status  st_refused    1 T {{*sdc_spi st_refused_reg {}}}
    status  st_gerr       1 T {{*sdc_spi st_gerr_reg {}}}
    status  st_misuse     1 T {{*sdc_spi st_misuse_reg {}}}
    status  poisoned      1 T {{*sdc_spi poisoned_reg {}}}
    irq     irq_pend      5 T {{*sdc_spi irq_pend_reg[%d] {0 1 2 3 4}}}
    irq     irq_r         1 T {{*sdc_spi irq_r_reg {}}}
    gayle   g_req_r       1 T {{*sdc_spi g_req_r_reg {}}}
    gayle   g_dir_r       1 T {{*sdc_spi g_dir_r_reg {}}}
    gayle   g_port_r      1 T {{*sdc_spi g_port_r_reg {}}}
    gayle   g_wvalid_r    1 T {{*sdc_spi g_wvalid_r_reg {}}}
    gayle   q_ack         1 T {{*SDCGAYLE1 q_ack_reg {}}}
    gayle   q_err         1 T {{*SDCGAYLE1 q_err_reg {}}}
    gayle   q_rvalid      1 T {{*SDCGAYLE1 q_rvalid_reg {}}}
    gayle   q_wtog        1 T {{*SDCGAYLE1 q_wtog_reg {}}}
    gayle   q_old         1 T {{*SDCGAYLE1 q_old_reg {}}}
    gayle   q_dir         1 T {{*SDCGAYLE1 q_dir_reg {}}}
    gayle   q_req_s1      1 T {{*SDCGAYLE1 q_req_s_reg[1] {}}}
    cnt     cnt          11 D {{*sdc_spi cnt_reg[%d] {0 1 2 3 4 5 6 7 8 9 10}}}
    rxlvl   rxlvl        11 D {{*sdc_spi rxlvl_reg[%d] {0 1 2 3 4 5 6 7 8 9 10}}}
    rxsh    rxsh          8 T {{*sdc_spi rxsh_reg[%d] {0 1 2 3 4 5 6 7}}}
    bridge  wr_r          1 T {{*SDCGAYLE1 wr_r_reg {}}}
    bridge  rd_r          1 T {{*SDCGAYLE1 rd_r_reg {}}}
    bridge  act           1 T {{*SDCGAYLE1 act_reg {}}}
    bridge  b_port        1 T {{*SDCGAYLE1 b_port_reg {}}}
    bridge  b_rst         1 T {{*SDCGAYLE1 b_rst_reg {}}}
    bridge  cmd_since     2 T {{*SDCGAYLE1 cmd_since_reg[%d] {0 1}}}
    bridge  etog          1 T {{*SDCGAYLE1 etog_reg {}}}
}

# The names of <nets>, a bus bit as its bus (cnt_reg[3] -> cnt_reg[*]).
proc sdc_ila__names {nets} {
    set r {}
    foreach n $nets {
        set nm [get_property NAME $n]
        if {[get_property -quiet BUS_NAME $n] ne ""} { regsub {\[[0-9]+\]$} $nm {[*]} nm }
        lappend r $nm
    }
    return $r
}

# The net driven by register <cell> (its Q), or "".
proc sdc_ila__qnet {cell} {
    set q [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == Q}]
    if {[llength $q] != 1} { return "" }
    set n [get_nets -quiet -of_objects $q]
    return [expr {[llength $n] == 1 ? $n : ""}]
}

# The nets of one alternative (bit 0 first), or "".
proc sdc_ila__alt {alt w} {
    if {[lindex $alt 0] eq "ibuf"} {
        set port [get_ports -quiet [lindex $alt 1]]
        if {[llength $port] != 1 || $w != 1} { return "" }
        set buf [get_cells -quiet -of_objects [get_nets -quiet -of_objects $port] -filter {REF_NAME =~ IBUF*}]
        if {[llength $buf] != 1} { return "" }
        set n [get_nets -quiet -of_objects [get_pins -quiet -of_objects $buf -filter {DIRECTION == OUT}]]
        return [expr {[llength $n] == 1 ? $n : ""}]
    }
    lassign $alt inst reg bits
    set pre ""
    if {$inst ne ""} {
        set i [get_cells -quiet -hierarchical -filter "NAME =~ \"$inst\" && IS_PRIMITIVE == 0"]
        if {[llength $i] != 1} { return "" }
        set pre "$i/"
    }
    # (Vivado's Tcl is 8.5: no lmap)
    set names {}
    if {[llength $bits]} { foreach b $bits { lappend names [format $reg $b] } } else { set names [list $reg] }
    if {[llength $names] != $w} { error "sdc_ila.tcl: probe table: $inst/$reg has [llength $names] bits, not $w" }
    set nets {}
    foreach nm $names {
        set c [get_cells -quiet $pre$nm]
        if {[llength $c] != 1 || ![get_property IS_SEQUENTIAL $c]} { return "" }
        set n [sdc_ila__qnet $c]
        if {$n eq ""} { return "" }
        lappend nets $n
    }
    return $nets
}

# Readable probe names: the .ltx names every probe after its net, and a
# register's output net is often called <reg>_reg_n_0, p_0_in_7 or the like.
# (Where that cannot be helped, the map file written with the core names
# every bit, and its hardware-manager script makes probes with the signal
# names: see sdc_ila_insert.)
# Unless every net of <signal> is already called <signal> / <signal>[i] (in
# its own hierarchy), each is renamed ila_<signal> / ila_<signal>[i] (i the
# register's own bit index, <idx>), all bits of a bus together; a net whose
# new name is taken keeps its old one.  Returns the nets (bit 0 first) by
# their new names.
proc sdc_ila__rename {signal idx nets} {
    set w [llength $nets]
    if {[llength $idx] != $w} { set idx {}; for {set i 0} {$i < $w} {incr i} { lappend idx $i } }
    set clean 1
    for {set i 0} {$i < $w} {incr i} {
        set n [lindex $nets $i]
        set leaf [expr {$w == 1 ? $signal : "$signal\[[lindex $idx $i]\]"}]
        if {[file tail [get_property NAME $n]] ne $leaf} { set clean 0 }
    }
    if {$clean} { return $nets }
    # a bit of a bus net (p_0_in_7[1]) cannot be renamed: then none is, so a
    # signal never ends up split between two names
    foreach n $nets { if {[get_property -quiet BUS_NAME $n] ne ""} { return $nets } }
    set out {}
    for {set i 0} {$i < $w} {incr i} {
        set n [lindex $nets $i]
        set nm [get_property NAME $n]
        set dir [file dirname $nm]
        set leaf [expr {$w == 1 ? "ila_$signal" : "ila_$signal\[[lindex $idx $i]\]"}]
        set full [expr {$dir eq "." ? $leaf : "$dir/$leaf"}]
        if {[get_nets -quiet $full] eq "" && ![catch {rename_net -to $leaf $n}]} {
            set n [get_nets -quiet $full]
        }
        lappend out $n
    }
    return $out
}

# Insert u_ila_sdc.  Returns a one-line summary; errors if anything is missing.
# <mapdir>: where to write sdc_ila_map.txt (ILA port and bits -> signal ->
# net, one line per signal) and sdc_ila_hwprobes.tcl (for the hardware
# manager, after the .ltx is loaded: create_hw_probe for every signal under
# the name sdc_<signal>, so a probe whose net is called p_0_in_7 can be used
# as sdc_rxlvl); "" writes neither.
proc sdc_ila_insert {{depth 2048} {adv 0} {mu 2} {strg 1} {mapdir ""}} {
    set spi [get_cells -quiet -hierarchical -filter {NAME =~ *sdc_spi && IS_PRIMITIVE == 0}]
    set br  [get_cells -quiet -hierarchical -filter {NAME =~ *SDCGAYLE1 && IS_PRIMITIVE == 0}]
    if {[llength $spi] != 1 || [llength $br] != 1} {
        error "sdc_ila.tcl: SD card engine instances: [llength $spi] sdc_spi, [llength $br] SDCGAYLE1 (1 / 1 expected: SDC_ILA needs a build with SD_ENGINE = 1)"
    }
    if {[get_debug_cores -quiet u_ila_sdc] ne ""} {
        error "sdc_ila.tcl: u_ila_sdc already exists"
    }
    set ck [get_pins -quiet $spi/sck_r_reg/C]
    set clk [get_nets -quiet -top_net_of_hierarchical_group -of_objects $ck]
    if {[llength $clk] != 1} { error "sdc_ila.tcl: no clock net on $spi/sck_r_reg/C" }

    # resolve every probe first: nothing is created unless all are there
    set found {}
    set missing {}
    foreach {group name w type alts} $::sdc_ila_probes {
        set nets ""
        set ib 0
        set idx {}
        foreach alt $alts {
            set nets [sdc_ila__alt $alt $w]
            set ib [expr {[lindex $alt 0] eq "ibuf"}]
            set idx [expr {$ib ? {} : [lindex $alt 2]}]
            if {$nets ne ""} break
        }
        if {$nets eq ""} {
            set tried {}
            foreach a $alts { lappend tried [join [lrange $a 0 1] /] }
            lappend missing "$name ([join $tried { or }])"
            continue
        }
        lappend found $group $name $w $type $ib $idx $nets
    }
    if {[llength $missing]} {
        error "sdc_ila.tcl: [llength $missing] probe(s) not in the netlist: [join $missing {; }]"
    }
    set plan {}
    set bits 0
    set map {}
    foreach {group name w type ib idx nets} $found {
        if {!$ib} { set nets [sdc_ila__rename $name $idx $nets] }
        # port number and the signal's low bit in it
        if {[llength $plan] && [lindex $plan end-3] eq $group} {
            set port [expr {[llength $plan] / 4 - 1}]
            set lo [lindex $plan end-2]
        } else {
            set port [expr {[llength $plan] / 4}]
            set lo 0
        }
        lappend map $port $lo $w $name $group $nets
        # one ILA probe port per group (consecutive rows): the cost of a port
        # is mostly per port, not per bit; the .ltx still names every
        # signal of a port on its own (the hardware manager's probes are the
        # nets' names: busy, op_tx, cph[1:0], ...)
        if {[llength $plan] && [lindex $plan end-3] eq $group} {
            set plan [lreplace $plan end-2 end [expr {[lindex $plan end-2] + $w}] \
                          [expr {$type eq "D" && [lindex $plan end-1] eq "DATA" ? "DATA" : "DATA_AND_TRIGGER"}] \
                          [concat [lindex $plan end] $nets]]
        } else {
            lappend plan $group $w [expr {$type eq "D" ? "DATA" : "DATA_AND_TRIGGER"}] $nets
        }
        incr bits $w
    }

    create_debug_core u_ila_sdc ila
    set c [get_debug_cores u_ila_sdc]
    set_property C_DATA_DEPTH          $depth $c
    set_property C_TRIGIN_EN           false $c
    set_property C_TRIGOUT_EN          false $c
    set_property C_ADV_TRIGGER         [expr {$adv ? true : false}]  $c
    set_property C_EN_STRG_QUAL        [expr {$strg ? true : false}] $c
    set_property C_INPUT_PIPE_STAGES   1     $c
    set_property ALL_PROBE_SAME_MU     true  $c
    set_property ALL_PROBE_SAME_MU_CNT $mu   $c
    set_property port_width 1 [get_debug_ports u_ila_sdc/clk]
    connect_debug_port u_ila_sdc/clk $clk
    set k 0
    foreach {name w type nets} $plan {
        if {$k > 0} { create_debug_port u_ila_sdc probe }
        set p [get_debug_ports u_ila_sdc/probe$k]
        set_property port_width $w $p
        set_property PROBE_TYPE $type $p
        connect_debug_port u_ila_sdc/probe$k $nets
        incr k
    }
    # the hub (shared with any IP ILA of the design): on the same clock, user
    # scan chain 1 (USER1; the RISC-V debug tunnel is on USER4)
    set h [get_debug_cores -quiet dbg_hub]
    if {$h ne ""} {
        if {[get_nets -quiet -of_objects [get_debug_ports dbg_hub/clk]] eq ""} {
            connect_debug_port dbg_hub/clk $clk
        }
        set_property C_CLK_INPUT_FREQ_HZ  113437500 $h
        set_property C_ENABLE_CLK_DIVIDER false $h
        set_property C_USER_SCAN_CHAIN    1 $h
    }
    if {$mapdir ne ""} {
        set fm [open $mapdir/sdc_ila_map.txt w]
        set fp [open $mapdir/sdc_ila_hwprobes.tcl w]
        puts $fm "# u_ila_sdc (tools/vivado/sdc_ila.tcl): port\[bits\] signal group  net(s)"
        puts $fm "# depth $depth, $k ports, $bits bits, clock [get_property NAME $clk]"
        puts $fp "# sdc_ila_hwprobes.tcl -- written by tools/vivado/sdc_ila.tcl with the core."
        puts $fp "# In the hardware manager, after the bitstream's .ltx is loaded"
        puts $fp "# (refresh_hw_device), source this file: every u_ila_sdc signal also as"
        puts $fp "# a probe named sdc_<signal> (create_hw_probe -map), whatever its net is called."
        puts $fp "set sdc_ila \[get_hw_ilas -of_objects \[current_hw_device\] -filter {CELL_NAME =~ *u_ila_sdc*}\]"
        puts $fp "if {\[llength \$sdc_ila\] != 1} { error \"sdc_ila_hwprobes.tcl: no u_ila_sdc in the device (lab bitstream and its .ltx loaded?)\" }"
        foreach {port lo w name group nets} $map {
            set hi [expr {$lo + $w - 1}]
            set rng [expr {$w == 1 ? "\[$lo\]" : "\[$hi:$lo\]"}]
            puts $fm [format "probe%-2d %-8s %-12s %-7s %s" $port $rng $name $group [join [lsort -unique [sdc_ila__names $nets]] { }]]
            # bits listed most significant first, as in create_hw_probe's help
            set bl {}
            for {set b $hi} {$b >= $lo} {incr b -1} { lappend bl "probe$port\[$b\]" }
            puts $fp "create_hw_probe -map {$bl} sdc_$name \$sdc_ila"
        }
        close $fm
        close $fp
    }
    set s "sdc_ila.tcl: u_ila_sdc inserted: $k probes, $bits bits, depth $depth, adv $adv, mu $mu, strg $strg, clock [get_property NAME $clk], hub [expr {$h ne {} ? {dbg_hub} : {none yet}}]"
    puts $s
    return $s
}

if {[info exists ::sdc_ila_lib] && $::sdc_ila_lib} { return }

# ---- the opt_design TCL.PRE hook (build_ap040.tcl SDC_ILA=1)
if {![info exists ::env(SDC_ILA)] || $::env(SDC_ILA) ne "1"} {
    error "sdc_ila.tcl: run as impl_1's opt_design hook but SDC_ILA is not 1 in the environment: a build with SDC_ILA=1 died before restoring STEPS.OPT_DESIGN.TCL.PRE. Clear it (set_property STEPS.OPT_DESIGN.TCL.PRE {} \[get_runs impl_1\]) and build again."
}
set sdc_ila_depth [expr {[info exists ::env(SDC_ILA_DEPTH)] && $::env(SDC_ILA_DEPTH) ne "" ? $::env(SDC_ILA_DEPTH) : 2048}]
# the impl run's directory: build_ap040.tcl copies the map and the hardware
# manager script from there to the build's output directory
sdc_ila_insert $sdc_ila_depth 0 2 1 [pwd]
