#!/usr/bin/env tclsh
# hostcpu_mock_test.tcl -- tools/vivado/hostcpu.tcl and build_ap040.tcl under a
# mocked Vivado: plain tclsh 8.6, no Vivado, no project_1, nothing written
# outside a temporary directory.
#
#   tclsh tools/vivado/test/hostcpu_mock_test.tcl [-keep <dir>]
#
# Every Vivado command the scripts call is a stub.  A small project model
# (filesets with ordered file lists, per-file IS_ENABLED / PROCESSING_ORDER,
# fileset properties such as the sources_1 generic, run properties) answers
# get_filesets / get_files / add_files / remove_files / get_property /
# set_property / get_runs; every other command (open_project, create_ip,
# launch_runs, report_*, get_cells, ...) is recorded and returns "".  Each
# call goes into a call list, and stdout is captured with it; the project
# state at `launch_runs impl_1` is kept too (what the run sees).  The
# repository root the scripts are given is a temporary fake one (the files the
# host CPU code checks for exist there, empty), so .hostcpu_undo and
# .last_generics are written there, never into the checkout's project_1.
#
# The project fixtures model a project_1 made before the EightThirtyTwo (832)
# was retired: it lists the 832's sources, its boot ROM and the bridge under
# its old name (rtl/host/832_bridge.vhd), none of which exist any more.  Checks:
#   default   build_ap040.tcl with RV_DEBUG unset and RV_DEBUG=0, ila 0/1,
#             reference / pipelined core, two project states: at launch_runs
#             the host CPU group (host_bridge.vhd, rv_hostcpu.v, VexOsd.v,
#             OSDBoot_rv_ROM.vhd) is in sources_1 and enabled, every retired
#             file disabled, no debug file in; afterwards the project is as
#             found; the generic has no HOSTCPU_RVDEBUG
#   unit      hostcpu_apply/hostcpu_restore (default call, and an explicit
#             rvdebug 0): the same groups after apply, identical call lists
#             for both calls, the project as found after restore
#   debug     hostcpu_apply $R 1: VexOsd_DMT.v + rv_bscane2.v added/enabled in
#             sources_1, rv_debug.xdc in XC7A100T (the runs' constraint set,
#             not constrs_1) with PROCESSING_ORDER LATE, all in the undo
#             record; hostcpu_restore leaves the project exactly as found
#   crash     apply, no restore (a dead Vivado): the next hostcpu_apply undoes
#             the .hostcpu_undo record first, debug files included
#   rvdebug   RV_DEBUG parsing: unset/""/0 -> 0, 1 -> 1, anything else an
#             error; RV_DEBUG=2 stops build_ap040.tcl before any project change
#   build     build_ap040.tcl with RV_DEBUG=1: the generic is the default
#             run's plus " HOSTCPU_RVDEBUG=1", the LAB banner, the default
#             run's call list is a subsequence of it (only additions), the
#             rv_debug.rpt calls, the project left as found, .last_generics
#             changed
#   repo      `echo 'source tools/vivado/hostcpu.tcl' | tclsh` parses silently;
#             the host CPU and debug sources and rv_debug.xdc exist in the checkout
# -keep <dir> writes every call list / stdout pair there (<case>.log) for a
# manual diff.  Ends "=== HOSTCPU MOCK PASS (<n> checks)" or
# "=== HOSTCPU MOCK FAIL (<k> of <n> checks)"; exit status 0 / 1.

set here [file normalize [file dirname [info script]]]
set repo [file normalize $here/../../..]
set keep ""
foreach {k v} $argv {
    switch -- $k {
        -keep { set keep [file normalize $v] }
        default { puts stderr "usage: tclsh [info script] \[-keep <dir>\]"; exit 2 }
    }
}

#-----------------------------------------------------------------------------
# The mock, evaluated in a fresh interpreter for every run.
#-----------------------------------------------------------------------------
set MOCK {
namespace eval ::mock {
    variable log {}
    variable out ""
    variable files [dict create]
    variable fprops [dict create]
    variable fsprops [dict create]
    variable at_launch ""
}
proc ::mock::rec {args} { lappend ::mock::log $args }
proc ::mock::load {st} {
    set ::mock::files  [dict get $st files]
    set ::mock::fprops [dict get $st fprops]
    set ::mock::fsprops [dict get $st fsprops]
}
proc ::mock::state {} {
    return [dict create files $::mock::files fprops $::mock::fprops fsprops $::mock::fsprops]
}
proc ::mock::isfile {o} {
    foreach {s l} $::mock::files { if {[lsearch -exact $l $o] >= 0} { return 1 } }
    return 0
}
proc ::mock::norm {k v} {
    if {$k eq "IS_ENABLED"} { return [expr {[string is true -strict $v] ? 1 : 0}] }
    return $v
}
proc get_filesets {args} {
    ::mock::rec get_filesets {*}$args
    set n [lindex $args end]
    if {![dict exists $::mock::files $n]} { error "mock: no fileset '$n'" }
    return $n
}
proc get_files {args} {
    ::mock::rec get_files {*}$args
    set fs ""; set pats {}
    for {set i 0} {$i < [llength $args]} {incr i} {
        set a [lindex $args $i]
        switch -- $a {
            -quiet { }
            -of_objects { incr i; set fs [lindex $args $i] }
            default { lappend pats $a }
        }
    }
    set sets [expr {$fs eq "" ? [dict keys $::mock::files] : [list $fs]}]
    set r {}
    foreach s $sets {
        foreach f [dict get $::mock::files $s] {
            foreach p $pats {
                if {[string match $p $f]} { if {[lsearch -exact $r $f] < 0} { lappend r $f }; break }
            }
        }
    }
    return $r
}
proc add_files {args} {
    ::mock::rec add_files {*}$args
    set fs sources_1; set fl {}
    for {set i 0} {$i < [llength $args]} {incr i} {
        set a [lindex $args $i]
        switch -- $a {
            -fileset { incr i; set fs [lindex $args $i] }
            -norecurse { }
            default { lappend fl $a }
        }
    }
    if {![dict exists $::mock::files $fs]} { error "mock: no fileset '$fs'" }
    foreach f $fl {
        if {[lsearch -exact [dict get $::mock::files $fs] $f] < 0} {
            dict lappend ::mock::files $fs $f
            dict set ::mock::fprops $f [dict create IS_ENABLED 1 PROCESSING_ORDER NORMAL]
        }
    }
    return $fl
}
proc remove_files {args} {
    ::mock::rec remove_files {*}$args
    set fs ""; set objs {}
    for {set i 0} {$i < [llength $args]} {incr i} {
        set a [lindex $args $i]
        switch -- $a {
            -fileset { incr i; set fs [lindex $args $i] }
            default { lappend objs {*}$a }
        }
    }
    foreach o $objs {
        foreach s [expr {$fs eq "" ? [dict keys $::mock::files] : [list $fs]}] {
            set l [dict get $::mock::files $s]
            set k [lsearch -exact $l $o]
            if {$k >= 0} { dict set ::mock::files $s [lreplace $l $k $k] }
        }
        if {![::mock::isfile $o]} { dict unset ::mock::fprops $o }
    }
    return ""
}
proc set_property {args} {
    ::mock::rec set_property {*}$args
    if {[lindex $args 0] eq "-dict"} {
        set kv [lindex $args 1]; set objs [lindex $args 2]
    } else {
        lassign $args k v objs; set kv [list $k $v]
    }
    foreach o $objs {
        foreach {k v} $kv {
            set k [string toupper $k]
            if {[::mock::isfile $o]} {
                dict set ::mock::fprops $o $k [::mock::norm $k $v]
            } elseif {[dict exists $::mock::files $o]} {
                dict set ::mock::fsprops $o $k $v
            }
        }
    }
    return ""
}
proc get_property {args} {
    ::mock::rec get_property {*}$args
    set a [lsearch -all -inline -not -exact $args -quiet]
    lassign $a k o
    set k [string toupper $k]
    if {[::mock::isfile $o]} {
        if {$k eq "NAME"} { return $o }
        if {[dict exists $::mock::fprops $o $k]} { return [dict get $::mock::fprops $o $k] }
        return ""
    }
    if {[dict exists $::mock::files $o]} {
        if {[dict exists $::mock::fsprops $o $k]} { return [dict get $::mock::fsprops $o $k] }
        return ""
    }
    switch -- $k {
        PROGRESS      { return "100%" }
        STATUS        { return "write_bitstream Complete!" }
        NEEDS_REFRESH { return 0 }
    }
    return ""
}
proc get_cells {args} {
    ::mock::rec get_cells {*}$args
    if {[string match "*REF_NAME == BSCANE2*" $args]} {
        return openaars_virtual_top/hostcpu/myrv/g_core.u_bscan/u_bscane2
    }
    return ""
}
proc get_clocks {args} {
    ::mock::rec get_clocks {*}$args
    return [lindex $args end]
}
proc get_runs {args} {
    ::mock::rec get_runs {*}$args
    return [lindex $args end]
}
rename unknown ::mock::_unknown
proc unknown {cmd args} {
    if {[string match ::* $cmd] || [string match tcl* $cmd] || [string match auto_* $cmd]} {
        return [uplevel 1 [list ::mock::_unknown $cmd {*}$args]]
    }
    ::mock::rec $cmd {*}$args
    if {$cmd eq "launch_runs" && [lsearch -exact $args impl_1] >= 0} {
        set ::mock::at_launch [::mock::state]
    }
    return ""
}
rename puts ::mock::_puts
proc puts {args} {
    set nl 1
    if {[lindex $args 0] eq "-nonewline"} { set nl 0; set args [lrange $args 1 end] }
    if {[llength $args] == 1} { set ch stdout; set msg [lindex $args 0] } else { lassign $args ch msg }
    if {$ch eq "stdout"} { append ::mock::out $msg [expr {$nl ? "\n" : ""}]; return }
    if {$nl} { ::mock::_puts $ch $msg } else { ::mock::_puts -nonewline $ch $msg }
}
}

# build_ap040.tcl's add_src, verbatim (the unit cases have no build script).
set ADD_SRC {
proc add_src {f} {
    if {[get_files -quiet -of_objects [get_filesets sources_1] $f] eq ""} {
        add_files -fileset sources_1 -norecurse $f
        puts "build.tcl: added source $f"
    }
}
}

#-----------------------------------------------------------------------------
# Fixtures
#-----------------------------------------------------------------------------
set tmpbase [expr {[info exists ::env(TMPDIR)] && $::env(TMPDIR) ne "" ? $::env(TMPDIR) : "/tmp"}]
set tmp [file normalize $tmpbase/hostcpu_mock.[pid]]
file delete -force $tmp
file mkdir $tmp
set R $tmp/R
set PIPE $tmp/pipe
set xdcdir $R/fpga/openaars/aars_v5.0/xc7a100t
foreach f [list rtl/host/host_bridge.vhd rtl/host/rv_hostcpu.v rtl/host/vexriscv/VexOsd.v fw/ctrl_boot/OSDBoot_rv_ROM.vhd \
                rtl/host/vexriscv/VexOsd_DMT.v rtl/host/xilinx/rv_bscane2.v tools/vivado/rv_debug.xdc] {
    file mkdir [file dirname $R/$f]
    close [open $R/$f w]
}
file mkdir $R/project_1
# The CPU core: a checkout named by AP040_PIPE_DIR ($PIPE), and the
# lib/AP68040-pipelined submodule of the fake root (SUB).
set SUB $R/lib/AP68040-pipelined
foreach f {ap040_pipe_pkg.sv ap040_core.v ap040_icache.v compat/ap040_compat.v} {
    foreach d [list $PIPE $SUB] {
        file mkdir [file dirname $d/rtl/$f]
        close [open $d/rtl/$f w]
    }
}

set NEW_BUILD  $repo/tools/vivado/build_ap040.tcl
set NEW_HOST   $repo/tools/vivado/hostcpu.tcl

proc file_entry {en {order NORMAL}} { return [dict create IS_ENABLED $en PROCESSING_ORDER $order] }

# fresh: a project_1.xpr from before the 832 and the reference 68040 core were
#        retired (the 832's sources, its boot ROM, the old bridge
#        rtl/host/832_bridge.vhd and a lib/AP68040 file in, no RV files).
#        Its include_dirs name lib/AP68040/rtl, as project_1's do.  (lib/AP68040
#        itself stays: the faster build takes its ap040_bus16_adapter.v, so its
#        files are not retired; a pipelined build turns them off for the run.)
# pre:   an untidy project: the RV group and both debug sources already listed
#        (some disabled), rv_debug.xdc listed but disabled, one retired file
#        already disabled.
proc state {kind} {
    global R xdcdir
    set src [list $R/rtl/soc/minimig_openaars_top.v $R/rtl/soc/minimig_virtual_top.v \
                  $R/rtl/host/832_bridge.vhd \
                  $R/EightThirtyTwo/RTL/eightthirtytwo_cpu.vhd $R/EightThirtyTwo/RTL/eightthirtytwo_alu.vhd \
                  $R/fw/ctrl_boot_832/OSDBoot_832_ROM.vhd $R/lib/AP68040/rtl/ap040_top.v]
    set xdc [list $xdcdir/clocks.xdc $xdcdir/wizard.xdc $xdcdir/cpu.xdc $xdcdir/ddr3.xdc]
    set fp [dict create]
    foreach f [concat $src $xdc] { dict set fp $f [file_entry 1] }
    if {$kind eq "pre"} {
        foreach {f en} [list $R/rtl/host/rv_hostcpu.v 0 $R/rtl/host/vexriscv/VexOsd.v 1 \
                             $R/fw/ctrl_boot/OSDBoot_rv_ROM.vhd 0 \
                             $R/rtl/host/vexriscv/VexOsd_DMT.v 0 $R/rtl/host/xilinx/rv_bscane2.v 0] {
            lappend src $f; dict set fp $f [file_entry $en]
        }
        dict set fp $R/EightThirtyTwo/RTL/eightthirtytwo_alu.vhd IS_ENABLED 0
        set xdc [linsert $xdc 1 $R/tools/vivado/rv_debug.xdc]
        dict set fp $R/tools/vivado/rv_debug.xdc [file_entry 0]
    }
    set files [dict create sources_1 $src constrs_1 {} XC7A100T $xdc sim_1 {}]
    set fsp [dict create sources_1 [dict create INCLUDE_DIRS [list $R/lib/AP68040/rtl $R/lib/AP68040-pipelined/rtl]] \
                         constrs_1 {} XC7A100T {} sim_1 {}]
    return [dict create files $files fprops $fp fsprops $fsp]
}

# The build switches build_ap040.tcl reads, cleared for every run so the
# caller's environment cannot steer a case.
set SWITCHES {RV_DEBUG AP040_PIPE_DIR AP040_PIPE_MMU AP040_PIPE_FPU FREE_CORE STORE_BUF FWD RAS
              PRECISE MISPLIT SB_MMU COPYBACK BTB LDX BTFN DFP_MIS WALLOC XC7 POST_CHIP POST_CI
              CWF FASTRAM_ILA CHIP32 IMPL_EFFORT STOP_AFTER_ROUTE}

# run <st> <envdict> <body>: a fresh interpreter with the mock loaded with
# state <st> and the environment <envdict>, then <body>.  Returns a dict
# {log out state err}.
proc run {st envd body} {
    global MOCK SWITCHES
    foreach s $SWITCHES { unset -nocomplain ::env($s) }
    dict for {k v} $envd { set ::env($k) $v }
    set i [interp create]
    $i eval $MOCK
    $i eval [list ::mock::load $st]
    set err ""
    if {[catch {$i eval $body} e]} { set err $e }
    set r [dict create log [$i eval {set ::mock::log}] out [$i eval {set ::mock::out}] \
                       state [$i eval {::mock::state}] err $err \
                       at_launch [$i eval {set ::mock::at_launch}]]
    interp delete $i
    foreach s $SWITCHES { unset -nocomplain ::env($s) }
    return $r
}

# The whole build script with -tclargs <out> <ila> <R>.
proc run_build {script st envd ila out} {
    global R
    file delete -force $out $R/project_1/.last_generics $R/project_1/.hostcpu_undo
    return [run $st $envd [list apply {{script argv} {
        set ::argv $argv; set ::argc [llength $argv]
        uplevel #0 [list source $script]
    }} $script [list $out $ila $R]]]
}

# hostcpu.tcl alone: source it, then <calls>.
proc run_unit {host st envd calls} {
    global ADD_SRC
    return [run $st $envd "$ADD_SRC\nsource [list $host]\n$calls"]
}

proc text {r} {
    set t ""
    foreach c [dict get $r log] { append t "CALL $c\n" }
    foreach l [split [string trimright [dict get $r out] \n] \n] { append t "OUT  $l\n" }
    if {[dict get $r err] ne ""} { append t "ERROR [dict get $r err]\n" }
    return $t
}

proc save {name r} {
    global keep
    if {$keep eq ""} { return }
    file mkdir $keep
    set fh [open $keep/$name.log w]; puts -nonewline $fh [text $r]; close $fh
}

#-----------------------------------------------------------------------------
# Check bookkeeping
#-----------------------------------------------------------------------------
set n_checks 0
set n_fail 0
proc check {name ok {detail ""}} {
    global n_checks n_fail
    incr n_checks
    if {$ok} {
        puts "PASS $name"
    } else {
        incr n_fail
        puts "FAIL $name[expr {$detail ne "" ? ": $detail" : ""}]"
    }
}

# The first line where two texts differ, for a failure message.
proc first_diff {a b} {
    set la [split $a \n]; set lb [split $b \n]
    for {set k 0} {$k < max([llength $la], [llength $lb])} {incr k} {
        if {[lindex $la $k] ne [lindex $lb $k]} {
            return "line [expr {$k + 1}]: '[lindex $la $k]' / '[lindex $lb $k]'"
        }
    }
    return "identical"
}

# Is list a an in-order subsequence of list b?  Returns the entries of b not
# matched (the additions), or the string "MISSING <entry>".
proc additions {a b} {
    set extra {}
    set j 0
    foreach x $a {
        while {$j < [llength $b] && [lindex $b $j] ne $x} { lappend extra [lindex $b $j]; incr j }
        if {$j >= [llength $b]} { return [list MISSING $x] }
        incr j
    }
    return [concat $extra [lrange $b $j end]]
}

proc generic_of {r} {
    set g ""
    foreach c [dict get $r log] {
        if {[lindex $c 0] eq "set_property" && [lindex $c 1] eq "generic" && [lindex $c 2] ne ""} {
            set g [lindex $c 2]
        }
    }
    return $g
}

proc in_fs {st fs f} { return [expr {[lsearch -exact [dict get $st files $fs] $f] >= 0}] }
proc prop {st f k} {
    if {[dict exists $st fprops $f $k]} { return [dict get $st fprops $f $k] }
    return ""
}
proc read_file {f} { set fh [open $f r]; set t [read $fh]; close $fh; return $t }

set DMT  $R/rtl/host/vexriscv/VexOsd_DMT.v
set BSC  $R/rtl/host/xilinx/rv_bscane2.v
set XDC  $R/tools/vivado/rv_debug.xdc
set UNDO $R/project_1/.hostcpu_undo
set BANNER "build_ap040.tcl: host CPU = RISC-V, DEBUG MODULE (rv_debug = 1, LAB BUILD)"
set TOKEN " HOSTCPU_RVDEBUG=1"

#-----------------------------------------------------------------------------
# The host CPU group and the retired files of the fixture project
#-----------------------------------------------------------------------------
set RVGROUP [list $R/rtl/host/host_bridge.vhd $R/rtl/host/rv_hostcpu.v \
                  $R/rtl/host/vexriscv/VexOsd.v $R/fw/ctrl_boot/OSDBoot_rv_ROM.vhd]
set RETIRED [list $R/rtl/host/832_bridge.vhd $R/EightThirtyTwo/RTL/eightthirtytwo_cpu.vhd \
                  $R/EightThirtyTwo/RTL/eightthirtytwo_alu.vhd $R/fw/ctrl_boot_832/OSDBoot_832_ROM.vhd]

# What a run must see: the RV group in sources_1 and enabled, every retired
# file disabled, no debug file enabled (rvdebug 0).  Returns "" or the problem.
proc run_view {st rvdebug} {
    global RVGROUP RETIRED DMT BSC XDC
    if {$st eq ""} { return "no state (launch_runs not reached?)" }
    foreach f $RVGROUP {
        if {![in_fs $st sources_1 $f] || [prop $st $f IS_ENABLED] ne "1"} { return "[file tail $f] not in/enabled" }
    }
    foreach f $RETIRED {
        if {[in_fs $st sources_1 $f] && [prop $st $f IS_ENABLED] ne "0"} { return "retired [file tail $f] enabled" }
    }
    foreach f [list $DMT $BSC] {
        set on [expr {[in_fs $st sources_1 $f] && [prop $st $f IS_ENABLED] eq "1"}]
        if {$on != $rvdebug} { return "[file tail $f] enabled = $on" }
    }
    set on [expr {[in_fs $st XC7A100T $XDC] && [prop $st $XDC IS_ENABLED] eq "1"}]
    if {$on != $rvdebug} { return "rv_debug.xdc enabled = $on" }
    return ""
}

# The project after a whole build as found before it, as far as the host CPU
# goes: every file of <st0> still there with the same IS_ENABLED and
# PROCESSING_ORDER, and no host CPU or debug file added (build_ap040.tcl's own
# add_src calls, the DDR3 sources for one, are permanent and not looked at).
# Returns "" or the first problem.
proc left_as_found {st0 st1} {
    global RVGROUP DMT BSC XDC
    foreach fs [dict keys [dict get $st0 files]] {
        foreach f [dict get $st0 files $fs] {
            if {![in_fs $st1 $fs $f]} { return "$fs: [file tail $f] removed" }
            foreach k {IS_ENABLED PROCESSING_ORDER} {
                if {[prop $st0 $f $k] ne [prop $st1 $f $k]} { return "$fs: [file tail $f] $k [prop $st0 $f $k] -> [prop $st1 $f $k]" }
            }
        }
        foreach f [dict get $st1 files $fs] {
            if {[in_fs $st0 $fs $f]} { continue }
            if {$f in [concat $RVGROUP [list $DMT $BSC $XDC]]} { return "$fs: [file tail $f] added" }
        }
    }
    return ""
}

#-----------------------------------------------------------------------------
# default: the whole build script, RV_DEBUG unset or 0
#-----------------------------------------------------------------------------
set DEFAULT_RUN [dict create]
foreach envcase {unset 0} {
    set envd [expr {$envcase eq "unset" ? {} : [dict create RV_DEBUG 0]}]
    foreach ila {0 1} {
        foreach pipe {sub pipe} {
            if {$pipe eq "pipe"} { dict set envd AP040_PIPE_DIR $PIPE } else { dict unset envd AP040_PIPE_DIR }
            foreach kind {fresh pre} {
                set case default_rv${envcase}_ila${ila}_${pipe}_$kind
                set st [state $kind]
                set rn [run_build $NEW_BUILD $st $envd $ila $tmp/out/$case]
                save $case $rn
                dict set DEFAULT_RUN $envcase,$ila,$pipe,$kind $rn
                check "$case: ran clean" [expr {[dict get $rn err] eq ""}] [dict get $rn err]
                set v [run_view [dict get $rn at_launch] 0]
                check "$case: at launch_runs: RV group in and enabled, retired files off, no debug files" [expr {$v eq ""}] $v
                set v [left_as_found $st [dict get $rn state]]
                check "$case: project left as found" [expr {$v eq ""}] $v
                check "$case: no .hostcpu_undo left" [expr {![file exists $UNDO]}]
                set core [expr {$pipe eq "pipe" ? $PIPE : $SUB}]
                set inc [expr {[dict get $rn at_launch] eq "" ? "" : [dict get [dict get $rn at_launch] fsprops sources_1 INCLUDE_DIRS]}]
                set want [list $R/lib/AP68040/rtl $SUB/rtl]
                foreach d [list $core/rtl $core/rtl/compat] { if {$d ni $want} { lappend want $d } }
                check "$case: at launch_runs: include_dirs = the project's plus the core's" \
                    [expr {$inc eq $want}] "got '$inc' want '$want'"
                set ref $R/lib/AP68040/rtl/ap040_top.v
                set ren [expr {[dict get $rn at_launch] eq "" ? "?" : [dict get [dict get $rn at_launch] fprops $ref IS_ENABLED]}]
                check "$case: at launch_runs: lib/AP68040 files off (the pipelined compat has the same modules)" \
                    [expr {$ren eq "0"}] "IS_ENABLED '$ren'"
                check "$case: generic has no AP040_PIPELINED (the only core)" [expr {[string first AP040_PIPELINED [generic_of $rn]] < 0}]
                check "$case: generic without HOSTCPU_RVDEBUG" \
                    [expr {[generic_of $rn] ne "" && [string first HOSTCPU_RVDEBUG [generic_of $rn]] < 0}] [generic_of $rn]
            }
        }
    }
    if {$envcase eq "0"} {
        set same 1
        dict for {k r} $DEFAULT_RUN {
            if {![string match unset,* $k]} { continue }
            set k0 [string map {unset, 0,} $k]
            if {[string map {default_rvunset_ default_rv0_} [text $r]] ne [text [dict get $DEFAULT_RUN $k0]]} { set same 0 }
        }
        check "default: RV_DEBUG=0 runs identical to RV_DEBUG unset (call list + stdout)" $same
    }
}

#-----------------------------------------------------------------------------
# unit: hostcpu_apply / hostcpu_restore
#-----------------------------------------------------------------------------
foreach kind {fresh pre} {
    set st [state $kind]
    file delete -force $UNDO
    set ra [run_unit $NEW_HOST $st {} [list hostcpu_apply $R]]
    file delete -force $UNDO
    set rn [run_unit $NEW_HOST $st {} [list hostcpu_apply $R]\nhostcpu_restore]
    file delete -force $UNDO
    set r0 [run_unit $NEW_HOST $st {} [list hostcpu_apply $R 0]\nhostcpu_restore]
    file delete -force $UNDO
    save unit_$kind $rn
    save unit_${kind}_rvdebug0 $r0
    set v [run_view [dict get $ra state] 0]
    check "unit $kind: after hostcpu_apply \$R: RV group in and enabled, retired files off" [expr {$v eq ""}] $v
    check "unit $kind: hostcpu_apply \$R 0 identical to hostcpu_apply \$R" [expr {[text $rn] eq [text $r0]}] [first_diff [text $rn] [text $r0]]
    check "unit $kind: restored to the state found" [expr {[dict get $rn state] eq $st}]
}

#-----------------------------------------------------------------------------
# debug: hostcpu_apply $R 1, then hostcpu_restore
#-----------------------------------------------------------------------------
foreach kind {fresh pre} {
    set st [state $kind]
    file delete -force $UNDO
    set ra [run_unit $NEW_HOST $st {} [list hostcpu_apply $R 1]]
    save debug_${kind}_apply $ra
    set sa [dict get $ra state]
    check "debug $kind: apply ran clean" [expr {[dict get $ra err] eq ""}] [dict get $ra err]
    foreach f [list $DMT $BSC] {
        check "debug $kind: [file tail $f] in sources_1, enabled" \
            [expr {[in_fs $sa sources_1 $f] && [prop $sa $f IS_ENABLED] eq "1"}]
    }
    check "debug $kind: rv_debug.xdc in XC7A100T, enabled, PROCESSING_ORDER LATE" \
        [expr {[in_fs $sa XC7A100T $XDC] && [prop $sa $XDC IS_ENABLED] eq "1" && [prop $sa $XDC PROCESSING_ORDER] eq "LATE"}]
    check "debug $kind: rv_debug.xdc not in constrs_1 or sources_1" \
        [expr {![in_fs $sa constrs_1 $XDC] && ![in_fs $sa sources_1 $XDC]}]
    set ok 1
    foreach f [list $R/rtl/host/rv_hostcpu.v $R/rtl/host/vexriscv/VexOsd.v $R/fw/ctrl_boot/OSDBoot_rv_ROM.vhd] {
        if {!([in_fs $sa sources_1 $f] && [prop $sa $f IS_ENABLED] eq "1")} { set ok 0 }
    }
    check "debug $kind: the RV group enabled as in a default apply" $ok
    set u [expr {[file exists $UNDO] ? [read_file $UNDO] : ""}]
    set ok 1
    foreach f [list $DMT $BSC $XDC] { if {[string first $f $u] < 0} { set ok 0 } }
    check "debug $kind: .hostcpu_undo names the three debug files" $ok
    set rx [run_unit $NEW_HOST $st {} "[list hostcpu_apply $R 1]\nhostcpu_restore"]
    save debug_${kind}_apply_restore $rx
    check "debug $kind: hostcpu_restore leaves the project as found" [expr {[dict get $rx state] eq $st}]
    check "debug $kind: .hostcpu_undo deleted by restore" [expr {![file exists $UNDO]}]
    set apply_calls {}
    foreach c [dict get $rx log] { if {[lindex $c 0] in {add_files remove_files set_property}} { lappend apply_calls $c } }
    check "debug $kind: restore removes only what apply added" \
        [expr {[llength [lsearch -all -index 0 $apply_calls add_files]] == [llength [lsearch -all -index 0 $apply_calls remove_files]]}]
}
file delete -force $UNDO

#-----------------------------------------------------------------------------
# crash: apply with no restore, then the next run's apply
#-----------------------------------------------------------------------------
foreach kind {fresh pre} {
    set st [state $kind]
    foreach {first second} {1 0  1 1  0 0  0 1} {
        file delete -force $UNDO
        set r1 [run_unit $NEW_HOST $st {} [list hostcpu_apply $R $first]]
        set what "apply rvdebug $first"
        set dead [dict get $r1 state]
        set left [file exists $UNDO]
        set r2 [run_unit $NEW_HOST $dead {} "[list hostcpu_apply $R $second]\nhostcpu_restore"]
        save crash_${kind}_${first}_${second} $r2
        set case "crash $kind: $what, dead, then apply rvdebug $second"
        check "$case: record left behind" $left
        check "$case: next apply undid it first" \
            [expr {[string first "an earlier run was not restored" [dict get $r2 out]] >= 0}]
        check "$case: after its restore the project is as originally found" \
            [expr {[dict get $r2 state] eq $st}] [dict get $r2 err]
        check "$case: no .hostcpu_undo left" [expr {![file exists $UNDO]}]
    }
    # the recovery alone (no new apply): the debug files leave with the record
    file delete -force $UNDO
    set r1 [run_unit $NEW_HOST $st {} [list hostcpu_apply $R 1]]
    set r2 [run_unit $NEW_HOST [dict get $r1 state] {} "[list hostcpu_apply $R 0]"]
    set s2 [dict get $r2 state]
    if {$kind eq "fresh"} {
        check "crash $kind: recovery + default apply: no debug file left in the project" \
            [expr {![in_fs $s2 sources_1 $DMT] && ![in_fs $s2 sources_1 $BSC] && ![in_fs $s2 XC7A100T $XDC]}]
    } else {
        check "crash $kind: recovery + default apply: debug files back to disabled, xdc order NORMAL" \
            [expr {[prop $s2 $DMT IS_ENABLED] eq "0" && [prop $s2 $BSC IS_ENABLED] eq "0" \
                   && [prop $s2 $XDC IS_ENABLED] eq "0" && [prop $s2 $XDC PROCESSING_ORDER] eq "NORMAL"}]
    }
    file delete -force $UNDO
}

#-----------------------------------------------------------------------------
# core: AP040_PIPE_DIR=none (the removed reference core) and a missing core
#-----------------------------------------------------------------------------
foreach {what envd} [list none [dict create AP040_PIPE_DIR none] missing [dict create AP040_PIPE_DIR $tmp/nonexistent]] {
    set r [run_build $NEW_BUILD [state fresh] $envd 0 $tmp/out/core_$what]
    set changes [lsearch -all -inline -regexp -index 0 [dict get $r log] {^(launch_runs|reset_run)$}]
    check "core: AP040_PIPE_DIR $what stops with an error" [expr {[dict get $r err] ne ""}] [dict get $r err]
    check "core: AP040_PIPE_DIR $what: no run launched" [expr {[llength $changes] == 0}]
}

#-----------------------------------------------------------------------------
# rvdebug: RV_DEBUG parsing
#-----------------------------------------------------------------------------
foreach {val want} {unset 0 "" 0 0 0 1 1 2 error yes error " 1" error} {
    set envd [expr {$val eq "unset" ? {} : [dict create RV_DEBUG $val]}]
    set r [run_unit $NEW_HOST [state fresh] $envd {set ::rvd [hostcpu_rvdebug]; puts "rvdebug=$::rvd"}]
    if {$want eq "error"} {
        check "rvdebug RV_DEBUG='$val': refused" \
            [expr {[string match *RV_DEBUG* [dict get $r err]]}] "err '[dict get $r err]' out '[string trim [dict get $r out]]'"
    } else {
        check "rvdebug RV_DEBUG='$val': $want" [expr {[dict get $r err] eq "" && [string trim [dict get $r out]] eq "rvdebug=$want"}] \
            "err '[dict get $r err]' out '[string trim [dict get $r out]]'"
    }
}
set r [run_build $NEW_BUILD [state fresh] [dict create RV_DEBUG 2] 0 $tmp/out/rv2]
save build_rv2 $r
set changes [lsearch -all -inline -regexp -index 0 [dict get $r log] {^(add_files|remove_files|set_property|create_ip|launch_runs|reset_run)$}]
check "rvdebug: build_ap040.tcl RV_DEBUG=2 stops with an error" [string match *RV_DEBUG* [dict get $r err]] [dict get $r err]
check "rvdebug: ... before any project change" [expr {[llength $changes] == 0}] [lrange $changes 0 2]

#-----------------------------------------------------------------------------
# build: the whole script with RV_DEBUG=1
#-----------------------------------------------------------------------------
foreach {ila pipe kind} {0 pipe fresh  1 sub pre  0 sub fresh} {
    set envd [dict create RV_DEBUG 1]
    if {$pipe eq "pipe"} { dict set envd AP040_PIPE_DIR $PIPE }
    set case build_rv1_ila${ila}_${pipe}_$kind
    set st [state $kind]
    set envb [dict create]
    if {$pipe eq "pipe"} { dict set envb AP040_PIPE_DIR $PIPE }
    set rb [run_build $NEW_BUILD $st $envb $ila $tmp/out/$case]
    set gb [generic_of $rb]
    set rn [run_build $NEW_BUILD $st $envd $ila $tmp/out/$case]
    save $case $rn
    set gn [generic_of $rn]
    check "$case: ran clean" [expr {[dict get $rn err] eq ""}] [dict get $rn err]
    set v [run_view [dict get $rn at_launch] 1]
    check "$case: at launch_runs: RV group and debug files in and enabled, retired files off" [expr {$v eq ""}] $v
    check "$case: generic = the default run's + '$TOKEN'" [expr {$gb ne "" && $gn eq "$gb$TOKEN"}] "new '$gn'"
    set outl [split [dict get $rn out] \n]
    check "$case: LAB banner printed once" [expr {[llength [lsearch -all -exact $outl $BANNER]] == 1}]
    # the default run's calls, with the generic of this run, must all be there in order
    set blog {}
    foreach c [dict get $rb log] {
        if {[lindex $c 0] eq "set_property" && [lindex $c 1] eq "generic" && [lindex $c 2] eq $gb} {
            set c [lreplace $c 2 2 "$gb$TOKEN"]
        }
        lappend blog $c
    }
    set extra [additions $blog [dict get $rn log]]
    check "$case: only additions to the default run's call list ([llength $extra] extra calls)" \
        [expr {[lindex $extra 0] ne "MISSING"}] [lrange $extra 0 1]
    if {$kind eq "fresh"} {
        foreach f [list $DMT $BSC] {
            check "$case: adds [file tail $f] to sources_1" \
                [expr {[lsearch -exact $extra [list add_files -fileset sources_1 -norecurse $f]] >= 0}]
        }
        check "$case: adds rv_debug.xdc to XC7A100T" \
            [expr {[lsearch -exact $extra [list add_files -fileset XC7A100T -norecurse $XDC]] >= 0}]
    }
    check "$case: rv_debug.xdc PROCESSING_ORDER LATE" \
        [expr {[lsearch -exact $extra [list set_property PROCESSING_ORDER LATE $XDC]] >= 0}]
    foreach {what pat} {
        "BSCANE2 cells"            {get_cells -quiet -hierarchical -filter {REF_NAME == BSCANE2}}
        "JTAG_CHAIN property"      {*JTAG_CHAIN*}
        "VexOsd_DMT cell count"    {get_cells -quiet -hierarchical -filter {IS_PRIMITIVE == 0}}
        "rv_tck in report_clocks"  {report_clocks -file *rv_debug.rpt -append rv_tck}
        "timing -from rv_tck"      {report_timing -from rv_tck -setup *-file *rv_debug.rpt -append}
        "timing -to rv_tck"        {report_timing -to rv_tck -setup *-file *rv_debug.rpt -append}
        "timing rv_tck intra"      {report_timing -from rv_tck -to rv_tck -setup *-file *rv_debug.rpt -append}
    } {
        check "$case: rv_debug.rpt: $what" [expr {[lsearch -glob $extra $pat] >= 0}]
    }
    set rpt $tmp/out/$case/rv_debug.rpt
    set rt [expr {[file exists $rpt] ? [read_file $rpt] : ""}]
    check "$case: rv_debug.rpt written (BSCANE2 + VexOsd_DMT count lines)" \
        [expr {[string match "*BSCANE2*" $rt] && [string match "*count VexOsd_DMT *" $rt]}]
    set v [left_as_found $st [dict get $rn state]]
    check "$case: project left as found" [expr {$v eq ""}] $v
    check "$case: project left as the default run leaves it" [expr {[dict get $rb state] eq [dict get $rn state]}]
    check "$case: no .hostcpu_undo left" [expr {![file exists $UNDO]}]
    set lg [expr {[file exists $R/project_1/.last_generics] ? [string trim [read_file $R/project_1/.last_generics]] : ""}]
    check "$case: .last_generics = the debug generic" [expr {$lg eq "$gb$TOKEN"}] "'$lg'"
}
# After a B build (.last_generics = the default generic) the lab build re-synthesises.
set st [state fresh]
set gb [generic_of [dict get $DEFAULT_RUN unset,0,pipe,fresh]]
file delete -force $tmp/out/resynth
set fh [open $R/project_1/.last_generics w]; puts $fh $gb; close $fh
set r [run [state fresh] [dict create RV_DEBUG 1] [list apply {{script argv} {
    set ::argv $argv; set ::argc [llength $argv]
    uplevel #0 [list source $script]
}} $NEW_BUILD [list $tmp/out/resynth 0 $R]]]
check "build: after a B build, RV_DEBUG=1 resets synth_1" \
    [expr {[lsearch -exact [dict get $r log] {reset_run synth_1}] >= 0 \
           && [string match "*re-synthesising*" [dict get $r out]]}]
file delete -force $R/project_1/.last_generics $UNDO

#-----------------------------------------------------------------------------
# repo: the real files
#-----------------------------------------------------------------------------
set rc [catch {exec sh -c "cd '$repo' && echo 'source tools/vivado/hostcpu.tcl' | tclsh" 2>@1} msg]
check "repo: echo 'source tools/vivado/hostcpu.tcl' | tclsh parses silently" [expr {$rc == 0 && $msg eq ""}] $msg
foreach f {rtl/host/host_bridge.vhd rtl/host/rv_hostcpu.v rtl/host/vexriscv/VexOsd.v fw/ctrl_boot/OSDBoot_rv_ROM.vhd
           rtl/host/vexriscv/VexOsd_DMT.v rtl/host/xilinx/rv_bscane2.v tools/vivado/rv_debug.xdc} {
    check "repo: $f exists" [file exists $repo/$f]
}
if {[file exists $repo/tools/vivado/rv_debug.xdc]} {
    set x [read_file $repo/tools/vivado/rv_debug.xdc]
    check "repo: rv_debug.xdc creates rv_tck on the BSCANE2 TCK pin, 50 ns" \
        [expr {[string first {create_clock -name rv_tck -period 50.000 [get_pins -hier -filter {NAME =~ *u_bscan/u_bscane2/TCK}]} $x] >= 0}]
    check "repo: rv_debug.xdc rv_tck asynchronous to clk_114" \
        [expr {[string first {set_clock_groups -asynchronous -group [get_clocks rv_tck] -group [get_clocks clk_114]} $x] >= 0}]
}

file delete -force $tmp
if {$n_fail == 0} {
    puts "=== HOSTCPU MOCK PASS ($n_checks checks)"
    exit 0
}
puts "=== HOSTCPU MOCK FAIL ($n_fail of $n_checks checks)"
exit 1
