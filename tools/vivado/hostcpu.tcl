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
# enable flags go back to what they were), so the project is left as found.
#
# The record is also written to project_1/.hostcpu_undo and deleted by
# hostcpu_restore: a build that died between the two leaves it behind, and the
# next hostcpu_apply restores from it first, so a crashed run cannot leave the
# project switched.
#
# Never added: rtl/host/xilinx/rv_bscane2.v, rtl/host/vexriscv/VexOsd_DMT.v and
# VexOsd_DMJ.v (the debug cores; production HOSTCPU_RVDEBUG = 0).
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

proc hostcpu__832_files {} {
    set fs [get_filesets sources_1]
    set l [get_files -quiet -of_objects $fs */EightThirtyTwo/RTL/*]
    foreach f [get_files -quiet -of_objects $fs */fw/ctrl_boot_832/OSDBoot_832_ROM.vhd] {
        lappend l $f
    }
    return $l
}

# Undo a record, last change first.  Entries: {remove <path>} and
# {enable <path> <previous IS_ENABLED>}.
proc hostcpu__undo {undo} {
    set fs [get_filesets sources_1]
    set removed 0
    set reset 0
    foreach u [lreverse $undo] {
        lassign $u op f was
        set o [get_files -quiet -of_objects $fs $f]
        if {$o eq ""} {
            puts "[hostcpu__tag]: WARNING host CPU restore: $f is no longer in sources_1"
            continue
        }
        switch -- $op {
            remove { remove_files -fileset sources_1 $o; incr removed }
            enable { set_property IS_ENABLED $was $o; incr reset }
            default { error "hostcpu.tcl: unknown undo entry '$u'" }
        }
    }
    return [list $removed $reset]
}

proc hostcpu_apply {R} {
    global hostcpu_undo hostcpu_undo_file
    set hostcpu_undo_file $R/project_1/.hostcpu_undo
    if {[file exists $hostcpu_undo_file]} {
        set fh [open $hostcpu_undo_file r]; set stale [read $fh]; close $fh
        lassign [hostcpu__undo $stale] rm rs
        file delete $hostcpu_undo_file
        puts "[hostcpu__tag]: host CPU: an earlier run was not restored; undone first ($rm files removed, $rs enable flags reset)"
    }

    set fs [get_filesets sources_1]
    set undo {}
    foreach f [hostcpu__rv_files $R] {
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
    set hostcpu_undo $undo
    set fh [open $hostcpu_undo_file w]; puts $fh $undo; close $fh

    set n [llength [hostcpu__rv_files $R]]
    puts "[hostcpu__tag]: host CPU = RISC-V ($n RV files enabled, $off 832 files disabled)"
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
