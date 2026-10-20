# The OSD host CPU's file groups in project_1, for the Vivado build scripts.
#
# minimig_openaars_top builds the VexRiscv RV32IMC host CPU (parameter
# HOSTCPU_RISCV = 1, osd-riscv Phase 5): rtl/host/832_bridge.vhd then
# elaborates rv_hostcpu and OSDBoot_rv_ROM instead of the EightThirtyTwo and
# OSDBoot_832_ROM.  project_1.xpr predates the RISC-V sources and lists the
# 832's, so a build script sources this file after defining add_src and calls
#
#   set changed [hostcpu_apply $R]    ;# before the run
#   ...
#   hostcpu_restore                   ;# with the script's other restores
#
# hostcpu_apply adds the RV group if missing and enables it, disables the 832
# group (every sources_1 file under EightThirtyTwo/RTL/ and
# fw/ctrl_boot_832/OSDBoot_832_ROM.vhd), so the bitstream carries one host CPU
# and no idle 832 sources.  It returns the number of changes it made.
# hostcpu_restore undoes exactly those changes (files it added are removed,
# enable flags and the xdc's PROCESSING_ORDER go back to what they were), so
# the project is left as found.
#
# The record is also written to project_1/.hostcpu_undo and deleted by
# hostcpu_restore: a build that died between the two leaves it behind, and the
# next hostcpu_apply restores from it first, so a crashed run cannot leave the
# project switched.
#
# Never added by a default build: rtl/host/xilinx/rv_bscane2.v,
# rtl/host/vexriscv/VexOsd_DMT.v and VexOsd_DMJ.v (the debug cores; the
# shipping image has HOSTCPU_RVDEBUG = 0).  The one exception is the LAB build,
# RV_DEBUG=1 in build_ap040.tcl's environment (hostcpu_rvdebug below), which
# calls
#
#   hostcpu_apply $R 1
#
# and so also adds and enables VexOsd_DMT.v and rv_bscane2.v in sources_1 and
# tools/vivado/rv_debug.xdc (the BSCANE2 TCK clock, rv_tck) in XC7A100T, the
# constraint set the runs use, with PROCESSING_ORDER LATE.  They are recorded
# like the RV group, so hostcpu_restore (or the next run's recovery from
# .hostcpu_undo) takes them out again.  VexOsd_DMJ.v (DEBUG = 2, the pin TAP)
# is never added.
#
# There is no 832 mode: the 832 board image is build/stage_spicdc_49b1868
# (branch 5.0-040-pipelined).  Sourcing this file only defines procs.

# The prefix of every message: the calling build script's name.
proc hostcpu__tag {} {
    set s [file tail [info script]]
    if {$s eq ""} { set s "hostcpu.tcl" }
    return $s
}

proc hostcpu__rv_files {R} {
    return [list $R/rtl/host/rv_hostcpu.v \
                 $R/rtl/host/vexriscv/VexOsd.v \
                 $R/fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd]
}

# The LAB build's debug module (rv_hostcpu DEBUG = 1): the core with the
# debug plugin and the BSCANE2 USER4 tunnel; and its timing constraints.
proc hostcpu__dbg_files {R} {
    return [list $R/rtl/host/vexriscv/VexOsd_DMT.v \
                 $R/rtl/host/xilinx/rv_bscane2.v]
}

proc hostcpu__dbg_xdc {R} {
    return $R/tools/vivado/rv_debug.xdc
}

# RV_DEBUG from the environment: unset, empty or 0 -> 0 (the shipping image),
# 1 -> 1 (the LAB build with the debug module); anything else is refused, so a
# typo cannot quietly build the image without it.
proc hostcpu_rvdebug {} {
    if {![info exists ::env(RV_DEBUG)]} { return 0 }
    switch -exact -- $::env(RV_DEBUG) {
        "" - 0 { return 0 }
        1      { return 1 }
    }
    error "hostcpu.tcl: RV_DEBUG='$::env(RV_DEBUG)': must be 0 (or unset) or 1 (the LAB build with the RISC-V debug module)"
}

proc hostcpu__832_files {} {
    set fs [get_filesets sources_1]
    set l [get_files -quiet -of_objects $fs */EightThirtyTwo/RTL/*]
    foreach f [get_files -quiet -of_objects $fs */fw/ctrl_boot_832/OSDBoot_832_ROM.vhd] {
        lappend l $f
    }
    return $l
}

# Undo a record, last change first.  Entries: {remove <path>} and
# {enable <path> <previous IS_ENABLED>} for sources_1; a fourth element names
# another fileset ({remove <path> {} XC7A100T}, {enable <path> <was> XC7A100T},
# {order <path> <previous PROCESSING_ORDER> XC7A100T}: the RV_DEBUG=1 xdc).
proc hostcpu__undo {undo} {
    set fs [get_filesets sources_1]
    set removed 0
    set reset 0
    foreach u [lreverse $undo] {
        lassign $u op f was fsn
        if {$fsn eq ""} {
            set fsn sources_1
            set ufs $fs
        } else {
            set ufs [get_filesets $fsn]
        }
        set o [get_files -quiet -of_objects $ufs $f]
        if {$o eq ""} {
            puts "[hostcpu__tag]: WARNING host CPU restore: $f is no longer in $fsn"
            continue
        }
        switch -- $op {
            remove { remove_files -fileset $fsn $o; incr removed }
            enable { set_property IS_ENABLED $was $o; incr reset }
            order  { set_property PROCESSING_ORDER $was $o; incr reset }
            default { error "hostcpu.tcl: unknown undo entry '$u'" }
        }
    }
    return [list $removed $reset]
}

# rvdebug 1 (build_ap040.tcl with RV_DEBUG=1) also puts the debug module in:
# hostcpu__dbg_files in sources_1 like the RV group, hostcpu__dbg_xdc in
# XC7A100T, enabled, PROCESSING_ORDER LATE (read after clocks.xdc, which names
# clk_114, and after wizard.xdc).
proc hostcpu_apply {R {rvdebug 0}} {
    global hostcpu_undo hostcpu_undo_file
    if {$rvdebug ni {0 1}} { error "hostcpu.tcl: hostcpu_apply rvdebug '$rvdebug': must be 0 or 1" }
    if {$rvdebug} {
        foreach f [concat [hostcpu__dbg_files $R] [list [hostcpu__dbg_xdc $R]]] {
            if {![file exists $f]} { error "hostcpu.tcl: RISC-V debug module file missing: $f" }
        }
    }
    set hostcpu_undo_file $R/project_1/.hostcpu_undo
    if {[file exists $hostcpu_undo_file]} {
        set fh [open $hostcpu_undo_file r]; set stale [read $fh]; close $fh
        lassign [hostcpu__undo $stale] rm rs
        file delete $hostcpu_undo_file
        puts "[hostcpu__tag]: host CPU: an earlier run was not restored; undone first ($rm files removed, $rs enable flags reset)"
    }

    set fs [get_filesets sources_1]
    set undo {}
    set srcs [hostcpu__rv_files $R]
    if {$rvdebug} { lappend srcs {*}[hostcpu__dbg_files $R] }
    foreach f $srcs {
        if {![file exists $f]} { error "hostcpu.tcl: RISC-V host CPU source missing: $f" }
        if {[get_files -quiet -of_objects $fs $f] eq ""} {
            add_src $f
            lappend undo [list remove $f]
        }
        set o [get_files -of_objects $fs $f]
        set was [get_property IS_ENABLED $o]
        if {!$was} {
            set_property IS_ENABLED true $o
            lappend undo [list enable $f $was]
        }
    }
    set off 0
    foreach o [hostcpu__832_files] {
        set was [get_property IS_ENABLED $o]
        if {$was} {
            set_property IS_ENABLED false $o
            lappend undo [list enable [get_property NAME $o] $was]
        }
        incr off
    }
    if {$rvdebug} {
        set xdc [hostcpu__dbg_xdc $R]
        set cs [get_filesets XC7A100T]
        if {[get_files -quiet -of_objects $cs $xdc] eq ""} {
            add_files -fileset XC7A100T -norecurse $xdc
            lappend undo [list remove $xdc {} XC7A100T]
        }
        set o [get_files -of_objects $cs $xdc]
        set was [get_property IS_ENABLED $o]
        if {!$was} {
            set_property IS_ENABLED true $o
            lappend undo [list enable $xdc $was XC7A100T]
        }
        set was [get_property PROCESSING_ORDER $o]
        if {$was ne "LATE"} {
            set_property PROCESSING_ORDER LATE $o
            lappend undo [list order $xdc $was XC7A100T]
        }
    }
    set hostcpu_undo $undo
    set fh [open $hostcpu_undo_file w]; puts $fh $undo; close $fh

    set n [llength [hostcpu__rv_files $R]]
    puts "[hostcpu__tag]: host CPU = RISC-V ($n RV files enabled, $off 832 files disabled)"
    if {$rvdebug} {
        puts "[hostcpu__tag]: host CPU: debug module in: [file tail [lindex [hostcpu__dbg_files $R] 0]], [file tail [lindex [hostcpu__dbg_files $R] 1]] (sources_1), [file tail [hostcpu__dbg_xdc $R]] (XC7A100T, LATE)"
    }
    puts "[hostcpu__tag]: host CPU: [llength $undo] project changes to restore afterwards"
    return [llength $undo]
}

proc hostcpu_restore {} {
    global hostcpu_undo hostcpu_undo_file
    if {![info exists hostcpu_undo]} {
        puts "[hostcpu__tag]: host CPU: nothing to restore (hostcpu_apply was not called)"
        return
    }
    lassign [hostcpu__undo $hostcpu_undo] rm rs
    if {[file exists $hostcpu_undo_file]} { file delete $hostcpu_undo_file }
    unset hostcpu_undo
    puts "[hostcpu__tag]: host CPU file groups restored ($rm added RV files removed, $rs enable flags reset)"
}
