# AP68040 build, the design's only CPU since Stage E4a: the pipelined MC68040
# of lib/AP68040-pipelined, with MMU, FPU and its split caches, inside rtl/soc/TG68K.vhd
# (which presents a TG68K-shaped port set; the TG68KdotC kernel itself was
# removed and builds at tag d3_stable).  Fileset generics
#   HAVEDDR3=1 DDR3_FASTRAM_ILA=<0|1>
# findings/ap68040/plan-v2-with-ddr3.md.
#
#   vivado -mode batch -source tools/vivado/build_ap040.tcl -tclargs <report-dir> [<ila>] [<repo-root>] [<post-stores>] [<cpu-clk-divide>] [<cpu-ila-depth>]
#
# <ila> = 1 (default) puts ila_fastram on the CPU side of the DDR3 fast RAM so
# a boot can be captured with tools/vivado/ila_fastram_capture.tcl; 0 builds
# the shipping configuration.  Use 1 for bring-up: the first AP040 boot is
# exactly when the traffic is worth seeing.
#
# The generics are set on sources_1 immediately before the run and cleared
# immediately after, so the project is left as it was found (project defaults
# are HAVEDDR3=1, DDR3_FASTRAM_ILA=0).
#
# The OSD host CPU is the VexRiscv RV32IMC: tools/vivado/hostcpu.tcl puts its
# sources in (and the files of the retired EightThirtyTwo out, should the
# project still list them) for the run and restores the project afterwards.
#
# RV_DEBUG=1 in the environment builds the LAB bitstream: the host CPU with the
# RISC-V debug module (VexOsd_DMT, its DTM tunnelled through the FPGA's own
# JTAG chain by a BSCANE2 on USER4; generic HOSTCPU_RVDEBUG=1, the bridge's
# rv_debug = 1), tools/vivado/rv_debug.xdc for its TCK clock, and an extra
# report rv_debug.rpt.  Unset or 0 builds the shipping image exactly as before
# (tools/vivado/test/hostcpu_mock_test.tcl checks that call for call).
#
# SDC_ILA=1 in the environment adds the SD card path ILA (u_ila_sdc,
# tools/vivado/sdc_ila.tcl) for this run only: that file becomes impl_1's
# opt_design TCL.PRE hook, which inserts the core into the linked netlist
# (registers of sdcard_spi / sdcard_gayle and the host bus, clk_114; no RTL
# change); opt_design implements it, write_bitstream writes the .ltx, and the
# core's probe map (sdc_ila_map.txt), a hardware-manager script that names
# its probes (sdc_ila_hwprobes.tcl: sdc_<signal>, what
# tools/vivado/sdc_ila_capture.tcl arms the core with), the .ltx net name of
# every core bit (sdc_ila_bits.txt, tools/vivado/sdc_ila_names.py: for
# reading a capture's CSV columns) and sdc_ila.rpt land
# next to the bitstream.  SDC_ILA_DEPTH (default 2048; a power of 2, 1024..16384) is its
# sample depth.  The hook is restored afterwards.  Unset or 0 builds exactly
# as before (tools/vivado/test/hostcpu_mock_test.tcl checks that call for
# call against the script before SDC_ILA); any other value stops the build
# before the project is touched.
#
# Vivado 2023.2 needs libtinfo.so.5 and must NOT be given -stack.
#
# Note the runs use the constraints fileset XC7A100T, not constrs_1.
#
# (tools/vivado/build.tcl, which built the TG68K design, is retired since
# Stage E4a; this is the build script.)
set out [lindex $argv 0]
# Repo root, set explicitly: second -tclargs wins, else it is derived from
# this script's own location.
set ila [expr {[llength $argv] > 1 ? [lindex $argv 1] : 1}]
# Posted stores in the AP68040's data cache: 1 is the design, 0 makes every
# store synchronous.  The A/B leg for the D3 chip-RAM coherency defect -- with
# Turbo chip RAM on, a store to chip RAM is a store to a CACHEABLE page and is
# therefore acknowledged before it reaches memory, so display DMA or the
# blitter can read the buffer before the write lands.  Stage D3 tripled the
# core's rate against the bus and so tripled that window.
# findings/ap68040/sdd-d3/d3-snoop-coherency.md.
set post [expr {[llength $argv] > 3 ? [lindex $argv 3] : 1}]
# AP68040 island clock divider: 30 = clk_114/3 (stage D3, shipping),
# 40 = clk_114/4, which is the PRE-D3 CPU RATE with the D3 architecture
# otherwise untouched -- the single-variable bisect for whether the chip
# RAM corruption is a rate-dependent window or a structural fault.
# 20 = clk_114/2 = 56.72 MHz, the faster core's clock and its default (below).
set cpudiv_arg [expr {[llength $argv] > 4 ? [lindex $argv 4] : ""}]
# ila_cpu040 capture depth (6th -tclargs, default 4096).  An ILA stores EVERY
# probe at the full depth, so a wide probe is expensive: the 384-bit dbg_phist
# histogram at 4096 samples pushed the design to 167 RAMB36 against 135 on the
# part.  The histogram needs one sample, so its builds pass 1024.
set cpuiladepth [expr {[llength $argv] > 5 ? [lindex $argv 5] : 4096}]
# Arguments 7-10 (phase gate, data register, gate delay, request gate) were
# folded into the RTL in Stage E4a: the shipping settings are the only ones.
# Refuse them rather than silently ignore a build that asks for something else.
if {[llength $argv] > 6} {
    error "build_ap040.tcl: arguments 7-10 were removed in Stage E4a (the phase gate is fixed in rtl/soc/TG68K.vhd); pass at most 6"
}
set R [expr {[llength $argv] > 2 ? [file normalize [lindex $argv 2]] \
                                 : [file normalize [file dirname [info script]]/../..]}]

# FASTER: the AP68040 `faster` core (lib/AP68040-faster, branch faster-dual)
# behind its 68040 bus bridge (rtl/soc/ap68040_minimig.sv), TG68K.vhd's
# ap040_faster.  Default 1 when the submodule is checked out; FASTER=0 in the
# environment builds the pipelined core as before.  Its clock is clk_114/2
# (CPU_CLK_DIVIDE 20) unless the 5th argument says otherwise, and a build at
# divider 20 takes its CPU constraints from cpu_r2.xdc instead of cpu.xdc.
set faster [expr {[file isdirectory $R/lib/AP68040-faster/rtl] &&
                  !([info exists ::env(FASTER)] && $::env(FASTER) eq "0")}]
if {[info exists ::env(FASTER)] && $::env(FASTER) eq "1" && !$faster} {
    error "build_ap040.tcl: FASTER=1 but $R/lib/AP68040-faster is not checked out"
}
set cpudiv [expr {$cpudiv_arg ne "" ? $cpudiv_arg : ($faster ? 20 : 30)}]
open_project $R/project_1/project_1.xpr

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------
# Add a design source once.
proc add_src {f} {
    if {[get_files -quiet -of_objects [get_filesets sources_1] $f] eq ""} {
        add_files -fileset sources_1 -norecurse $f
        puts "build.tcl: added source $f"
    }
}

# Add a constraint file to the XC7A100T fileset once, and make sure it is not
# also sitting unused in constrs_1.
proc add_xdc {f} {
    if {[get_files -quiet -of_objects [get_filesets constrs_1] $f] ne ""} {
        remove_files -fileset constrs_1 $f
    }
    if {[get_files -quiet -of_objects [get_filesets XC7A100T] $f] eq ""} {
        add_files -fileset XC7A100T -norecurse $f
        puts "build.tcl: added constraint $f"
    }
    set_property USED_IN {synthesis implementation} \
        [get_files -of_objects [get_filesets XC7A100T] $f]
}

# The OSD host CPU file groups: hostcpu_apply / hostcpu_restore (the board top
# builds the RISC-V host CPU, osd-riscv Phase 5).
source [file dirname [info script]]/hostcpu.tcl
# RV_DEBUG (0 or 1, checked before anything is changed): 1 is the LAB build.
set rv_debug [hostcpu_rvdebug]
# SDC_ILA (0 or 1) and, with 1, SDC_ILA_DEPTH: checked before anything is
# changed too.  Nothing below runs a Vivado command for SDC_ILA unless it is 1.
set sdc_ila 0
if {[info exists ::env(SDC_ILA)]} {
    switch -exact -- $::env(SDC_ILA) {
        "" - 0 { }
        1      { set sdc_ila 1 }
        default { error "build_ap040.tcl: SDC_ILA='$::env(SDC_ILA)': must be 0 (or unset) or 1 (the SD card path ILA)" }
    }
}
if {$sdc_ila} {
    set sdc_ila_depth [expr {[info exists ::env(SDC_ILA_DEPTH)] && $::env(SDC_ILA_DEPTH) ne "" ? $::env(SDC_ILA_DEPTH) : 2048}]
    if {$sdc_ila_depth ni {1024 2048 4096 8192 16384}} {
        error "build_ap040.tcl: SDC_ILA_DEPTH='$sdc_ila_depth': must be 1024, 2048, 4096, 8192 or 16384"
    }
    set ::env(SDC_ILA_DEPTH) $sdc_ila_depth
    set sdc_ila_hook $R/tools/vivado/sdc_ila.tcl
    if {![file exists $sdc_ila_hook]} { error "build_ap040.tcl: SDC_ILA=1 but $sdc_ila_hook is missing" }
}

#-----------------------------------------------------------------------------
# Constraints
#-----------------------------------------------------------------------------
# cpu.xdc relaxes the CPU island's crossings for ratio 3; at ratio 2 they are
# single-cycle and cpu_r2.xdc says so.  The one not used is disabled for the
# run and re-enabled at the end (xdc_off).
set xdc_off {}
if {$cpudiv == 20} {
    set cpu_xdc_on  $R/fpga/openaars/aars_v5.0/xc7a100t/cpu_r2.xdc
    set cpu_xdc_off $R/fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc
} else {
    set cpu_xdc_on  $R/fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc
    set cpu_xdc_off $R/fpga/openaars/aars_v5.0/xc7a100t/cpu_r2.xdc
}
add_xdc $cpu_xdc_on
set_property IS_ENABLED true [get_files -of_objects [get_filesets XC7A100T] $cpu_xdc_on]
foreach f [get_files -quiet -of_objects [get_filesets XC7A100T] $cpu_xdc_off] {
    if {[get_property IS_ENABLED $f]} { set_property IS_ENABLED false $f; lappend xdc_off $f }
}
puts "build_ap040.tcl: CPU constraints [file tail $cpu_xdc_on] (CPU_CLK_DIVIDE $cpudiv)"
add_xdc $R/fpga/openaars/aars_v5.0/xc7a100t/ddr3.xdc
# The SD card's timing (an unmanaged Tcl constraint file: it picks the SD card
# engine's constraints or today's false paths by what the netlist holds), after
# the XDC files that define the clocks.
add_xdc $R/fpga/openaars/aars_v5.0/xc7a100t/sd_card_engine.tcl
set_property PROCESSING_ORDER LATE \
    [get_files -of_objects [get_filesets XC7A100T] $R/fpga/openaars/aars_v5.0/xc7a100t/sd_card_engine.tcl]

#-----------------------------------------------------------------------------
# DDR3 island sources
#
# From the vendored controller only what synthesis needs: the two SystemVerilog
# controller sources and the xc7 PHY.  NOT ddr3_const.svh (dead code, nothing
# includes it), NOT the testbench, NOT examples/arty_a7/artix7_pll.v (the
# island has its own PLL wrapper, rtl/ddr3/ddr3_pll.v).
#-----------------------------------------------------------------------------
add_src $R/lib/core_ddr3_controller/src_v/ddr3_core.sv
add_src $R/lib/core_ddr3_controller/src_v/ddr3_dfi_seq.sv
add_src $R/lib/core_ddr3_controller/src_v/phy/xc7/ddr3_dfi_phy.v

add_src $R/rtl/ddr3/ddr3_pll.v
add_src $R/rtl/ddr3/ddr3_bist.v
add_src $R/rtl/ddr3/ddr3_top.v

# Zorro-III fast RAM: the cache backend and the clk_114 <-> clk100 handshake.
add_src $R/rtl/ddr3/ddr3_fastram.v
add_src $R/rtl/ddr3/ddr3_cdc.v

# The CPU enable cadence (Task 4, one source for sdram_ctrl and the bench).
# project_1.xpr predates the file,
# and a source that is not in sources_1 is simply not compiled.
add_src $R/rtl/sdram/cpu_enable_cadence.v
# The second Gayle IDE port (findings/cdrom/plan.md 7.3): gayle.v instantiates
# gayle_port.v once per port; project_1.xpr predates the file.
add_src $R/rtl/minimig/gayle_port.v
# The SD card engine (findings/sdcard-engine): the SPI peripheral
# minimig_virtual_top instantiates with SD_ENGINE = 1, and its Gayle bridge
# and mux minimig.v instantiates; project_1.xpr predates both.
add_src $R/rtl/host/sdcard_spi.v
add_src $R/rtl/minimig/sdcard_gayle.v
# Stage E2: the unit splitter TG68K.vhd instantiates for both RAM ports.
add_src $R/rtl/soc/ap040_ram_seq.vhd
# The XADC die-temperature reader, for the Chipset OSD menu's first line.
add_src $R/rtl/soc/fpga_temp.v
# frame_freq.v became frame_freq.sv (HDMI chain clean-up, 2026-10-26);
# project_1.xpr still names the .v, which no longer exists.
set ff_v [get_files -quiet -of_objects [get_filesets sources_1] */rtl/openaars/adv7511/frame_freq.v]
if {$ff_v ne ""} {
    remove_files -fileset sources_1 $ff_v
    puts "build.tcl: removed source $ff_v"
}
add_src $R/rtl/openaars/adv7511/frame_freq.sv
# adv_ddr.v became adv_ddr.sv (HDMI chain clean-up, 2026-10-27); the same.
set ad_v [get_files -quiet -of_objects [get_filesets sources_1] */rtl/openaars/adv7511/adv_ddr.v]
if {$ad_v ne ""} {
    remove_files -fileset sources_1 $ad_v
    puts "build.tcl: removed source $ad_v"
}
add_src $R/rtl/openaars/adv7511/adv_ddr.sv
# pal_to_hd_upsample.v became pal_to_hd_upsample.sv (2026-10-27); the same.
set up_v [get_files -quiet -of_objects [get_filesets sources_1] */rtl/openaars/adv7511/pal_to_hd_upsample.v]
if {$up_v ne ""} {
    remove_files -fileset sources_1 $up_v
    puts "build.tcl: removed source $up_v"
}
add_src $R/rtl/openaars/adv7511/pal_to_hd_upsample.sv
# HDMI CRT emulation (2026-10-09): the post stage pal_to_ddr.sv instantiates,
# and its three tables ($readmemh by name: as memory files of the project,
# synthesis finds them; a missing one leaves its effect black, the plain
# picture never reads them).
add_src $R/rtl/openaars/adv7511/crt_post.v
add_src $R/rtl/openaars/adv7511/crt_wrom.mem
add_src $R/rtl/openaars/adv7511/crt_lut.mem
add_src $R/rtl/openaars/adv7511/crt_bloom.mem
# The horizontal beam spot before the upsamplers (crt_beamh.v, clk_114) and
# its tables (decode, encode, kernels); off, the picture never reads them.
add_src $R/rtl/openaars/adv7511/crt_beamh.v
add_src $R/rtl/openaars/adv7511/crt_hdec.mem
add_src $R/rtl/openaars/adv7511/crt_henc.mem
add_src $R/rtl/openaars/adv7511/crt_hk.mem
# the scaler's linear-light tables (crt_post.v, 2026-10-13; sim/hdmi_upsample/scl_mkroms.py)
add_src $R/rtl/openaars/adv7511/crt_sdec.mem
add_src $R/rtl/openaars/adv7511/crt_senc.mem
add_src $R/rtl/openaars/adv7511/crt_swrom.mem
# The dual-port RAM the AP040 MMU's ATC and the caches instantiate (module
# dpram); project_1 had it only as a hand-added source, so a fresh clone's
# project did not.
add_src $R/rtl/cpu040/dpram.v

set ipdir $R/ip/ddr3
file mkdir $ipdir

#-----------------------------------------------------------------------------
# vio_ddr3: the bring-up VIO for the BIST and the PHY tap sweep
# (minimig_openaars_top.v parameter DDR3_BIST_VIO).  Not instantiated by this
# build (DDR3_BIST_VIO=0), but the IP is kept in the project so that switching
# back to tools/vivado/build_bist.tcl needs no regeneration.
#
# probe_in : 0 busy, 1 done, 2 err_count, 3 first_err_addr, 4 first_err_xor,
#            5 lines_done, 6 init_done, 7 pll_locked
# probe_out: 0 start, 1 pattern, 2 range_log2, 3 mode, 4 phy_cfg_valid,
#            5 dqs_inc, 6 dqs_rst, 7 dq_inc, 8 dq_rst, 9 rdlat (init 5),
#            10 rdsel
#-----------------------------------------------------------------------------
if {[get_ips -quiet vio_ddr3] eq ""} {
    puts "build_ap040.tcl: creating vio_ddr3"
    create_ip -name vio -vendor xilinx.com -library ip -version 3.0 \
        -module_name vio_ddr3 -dir $ipdir
    set_property -dict [list \
        CONFIG.C_NUM_PROBE_IN      {8} \
        CONFIG.C_PROBE_IN0_WIDTH   {1} \
        CONFIG.C_PROBE_IN1_WIDTH   {1} \
        CONFIG.C_PROBE_IN2_WIDTH   {32} \
        CONFIG.C_PROBE_IN3_WIDTH   {32} \
        CONFIG.C_PROBE_IN4_WIDTH   {32} \
        CONFIG.C_PROBE_IN5_WIDTH   {32} \
        CONFIG.C_PROBE_IN6_WIDTH   {1} \
        CONFIG.C_PROBE_IN7_WIDTH   {1} \
        CONFIG.C_NUM_PROBE_OUT     {11} \
        CONFIG.C_PROBE_OUT0_WIDTH  {1} \
        CONFIG.C_PROBE_OUT1_WIDTH  {3} \
        CONFIG.C_PROBE_OUT2_WIDTH  {5} \
        CONFIG.C_PROBE_OUT3_WIDTH  {1} \
        CONFIG.C_PROBE_OUT4_WIDTH  {1} \
        CONFIG.C_PROBE_OUT5_WIDTH  {2} \
        CONFIG.C_PROBE_OUT6_WIDTH  {2} \
        CONFIG.C_PROBE_OUT7_WIDTH  {2} \
        CONFIG.C_PROBE_OUT8_WIDTH  {2} \
        CONFIG.C_PROBE_OUT9_WIDTH  {3} \
        CONFIG.C_PROBE_OUT10_WIDTH {4} \
        CONFIG.C_PROBE_OUT2_INIT_VAL {0x1c} \
        CONFIG.C_PROBE_OUT9_INIT_VAL {0x5} \
    ] [get_ips vio_ddr3]
    generate_target all [get_files [get_property IP_FILE [get_ips vio_ddr3]]]
    catch { create_ip_run [get_files [get_property IP_FILE [get_ips vio_ddr3]]] }
}

#-----------------------------------------------------------------------------
# ila_fastram: the CPU-path capture core (minimig_virtual_top.v parameter
# DDR3_FASTRAM_ILA).  Clocked by CLK_114; every probe is a clk_114 register of
# ddr3_fastram / the clk_114 half of ddr3_cdc, so the core adds no crossing of
# its own.
#
# probe0  cpu_wadr[25:1]       probe12 dbg_resp_rdata[127:0]
# probe1  ddr_ila_st[6:0]      probe13 dbg_ack_tgl        (Stage E2: probes 0-6
# probe2  ddr_ila_two          probe14 dbg_bstate[1:0]     are the unit port,
# probe3  cpu_ir               probe15 dbg_sdr_read_req    widths unchanged)
# probe4  cpu_wdat[31:16]      probe16 dbg_sdr_read_ack
# probe5  cpu_rdat[31:16]      probe17 dbg_sdr_dat_r[15:0]
# probe6  cpu_ack              probe18 dbg_sdr_write_req
# probe7  ddr_ready            probe19 dbg_sdr_write_ack
# probe8  dbg_req_rd           probe20 dbg_sdr_adr[25:1]
# probe9  dbg_req_be[15:0]     probe21 dbg_sdr_dat_w[31:0]
# probe10 dbg_req_addr[31:0]   probe22 dbg_sdr_dqm_w[3:0]
# probe11 dbg_req_wdata[127:0] probe23 {cdc_ready,cdc_req,cdc_done,req_tgl}
#
# Comparators: only four probes take part in a trigger or storage-qualifier
# condition (probe1 ddr_ila_st and probe14 bstate qualify storage, probe6 cpu_ack
# and probe7 ddr_ready arm the trigger -- see
# tools/vivado/ila_fastram_capture.tcl), and those get two match units each so
# the supervisor can put either probe on either side.  Every other probe is
# recorded only, and one match unit for a 128-bit probe is a lot of LUTs, so
# ALL_PROBE_SAME_MU is off.  This is not cosmetic: with two match units on all
# 24 probes the core costs about 3.9k LUTs on clk_114, and the congestion that
# adds pushes the TG68K-ALU-to-cache path in the Minimig core into a setup
# violation, i.e. the debug build would no longer be a faithful copy of the
# design under investigation.
#
# 461 probe bits.  ILA_DEPTH is the sample depth; the capture RAM costs
# ceil(461 * ILA_DEPTH / 36864) RAMB36 and this device has 85 tiles free after
# the Minimig core, so 8192 (about 103 tiles) does not fit and 4096 (about 52)
# does.  Storage qualification (C_EN_STRG_QUAL) is what makes the shallower
# buffer sufficient: only cycles with a CPU access or a busy backend are
# stored, so 4096 samples are thousands of DDR3 transactions rather than
# 36 microseconds of idle.
set ILA_DEPTH 4096
if {[get_ips -quiet ila_fastram] eq ""} {
    puts "build_ap040.tcl: creating ila_fastram (depth $ILA_DEPTH)"
    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 \
        -module_name ila_fastram -dir $ipdir
    set_property -dict [list \
        CONFIG.C_NUM_OF_PROBES     {24} \
        CONFIG.C_DATA_DEPTH        $ILA_DEPTH \
        CONFIG.C_EN_STRG_QUAL      {1} \
        CONFIG.C_ADV_TRIGGER       {false} \
        CONFIG.C_TRIGIN_EN         {false} \
        CONFIG.C_TRIGOUT_EN        {false} \
        CONFIG.C_INPUT_PIPE_STAGES {1} \
        CONFIG.ALL_PROBE_SAME_MU     {false} \
        CONFIG.C_PROBE1_MU_CNT  {2} \
        CONFIG.C_PROBE6_MU_CNT  {2} \
        CONFIG.C_PROBE7_MU_CNT  {2} \
        CONFIG.C_PROBE14_MU_CNT {2} \
        CONFIG.C_PROBE0_WIDTH  {25} \
        CONFIG.C_PROBE1_WIDTH  {7} \
        CONFIG.C_PROBE2_WIDTH  {1} \
        CONFIG.C_PROBE3_WIDTH  {1} \
        CONFIG.C_PROBE4_WIDTH  {16} \
        CONFIG.C_PROBE5_WIDTH  {16} \
        CONFIG.C_PROBE6_WIDTH  {1} \
        CONFIG.C_PROBE7_WIDTH  {1} \
        CONFIG.C_PROBE8_WIDTH  {1} \
        CONFIG.C_PROBE9_WIDTH  {16} \
        CONFIG.C_PROBE10_WIDTH {32} \
        CONFIG.C_PROBE11_WIDTH {128} \
        CONFIG.C_PROBE12_WIDTH {128} \
        CONFIG.C_PROBE13_WIDTH {1} \
        CONFIG.C_PROBE14_WIDTH {2} \
        CONFIG.C_PROBE15_WIDTH {1} \
        CONFIG.C_PROBE16_WIDTH {1} \
        CONFIG.C_PROBE17_WIDTH {16} \
        CONFIG.C_PROBE18_WIDTH {1} \
        CONFIG.C_PROBE19_WIDTH {1} \
        CONFIG.C_PROBE20_WIDTH {25} \
        CONFIG.C_PROBE21_WIDTH {32} \
        CONFIG.C_PROBE22_WIDTH {4} \
        CONFIG.C_PROBE23_WIDTH {4} \
    ] [get_ips ila_fastram]
    generate_target all [get_files [get_property IP_FILE [get_ips ila_fastram]]]
    catch { create_ip_run [get_files [get_property IP_FILE [get_ips ila_fastram]]] }
}

# Make sure the IPs' out-of-context synthesis results exist before the top run.
foreach ip {vio_ddr3 ila_fastram} {
    set ipr [get_runs -quiet ${ip}_synth_1]
    if {$ipr ne "" && [get_property PROGRESS $ipr] ne "100%"} {
        launch_runs $ipr -jobs 8
        wait_on_run $ipr
    }
}

#-----------------------------------------------------------------------------
# Build
#-----------------------------------------------------------------------------
#-----------------------------------------------------------------------------
# ila_cpu040: the chipset bus, with its data, and where the CPU is.
#
# This started as a fault capture -- vector, faulting address, SR -- because a
# yellow Kickstart screen was assumed to be an exception before the trap
# handlers existed.  It is not.  The 040 reaches Exec with no exception at all
# and spins in AllocMem (Kickstart 46.143 $F8068E-$F806A0), so the fault ports
# earn nothing and the read/write data earns everything: telling "the memory
# region is small" from "the free list is corrupt" needs the mc_Bytes the
# allocator reads back, and both look identical in an address-only trace.
#
#   probe0 pc[31:0]      probe1 adr[31:0]   probe2 data_read[15:0]
#   probe3 data_write[15:0]  probe4 {as,rw,uds,lds}  probe5 flags[3:0]
#   probe6 ir[15:0]      probe7 tg68_ram_hs[6:0] (unit-port handshakes + busy, E2)
#   probe8 dbg_phist[383:0] -- chip-RAM acknowledge phase histogram
#   probe9 dbg_rtg[31:0]    probe10 {rtg_ena,rtg_16bit,rtg_clut,pixelwidth,baseaddr}[28:0]
# (The stage D3 dbg_snoop counters were removed in Stage E4a; they proved no
# snoop is lost across clk_114 -> clk_38.)
#
# 4096 deep, and storage qualification stays on: with Turbo off a chip access
# is a 7 MHz chipset cycle against an 8.8 ns clock, so capturing on !as is the
# difference between 4096 real transfers and about 64.
#-----------------------------------------------------------------------------
if {$ila} {
    set ipdir $R/ip/ddr3
    file mkdir $ipdir
    if {[get_ips -quiet ila_cpu040] eq ""} {
        puts "build_ap040.tcl: creating ila_cpu040"
        create_ip -name ila -vendor xilinx.com -library ip -version 6.2 \
            -module_name ila_cpu040 -dir $ipdir
    }
    # Applied every run, not only on creation.  The probe map changed once
    # already; an existing IP left at the old widths would elaborate against
    # the new port list and fail somewhere far from here.  Re-applying is free
    # when nothing changed -- Vivado only marks the IP out of date if it did.
    set_property -dict [list \
        CONFIG.C_NUM_OF_PROBES {11} \
        CONFIG.C_DATA_DEPTH $cpuiladepth \
        CONFIG.C_TRIGIN_EN {false} \
        CONFIG.C_EN_STRG_QUAL {1} \
        CONFIG.C_ADV_TRIGGER {false} \
        CONFIG.C_PROBE0_WIDTH {32} \
        CONFIG.C_PROBE1_WIDTH {32} \
        CONFIG.C_PROBE2_WIDTH {16} \
        CONFIG.C_PROBE3_WIDTH {16} \
        CONFIG.C_PROBE4_WIDTH {4} \
        CONFIG.C_PROBE5_WIDTH {4} \
        CONFIG.C_PROBE6_WIDTH {16} \
        CONFIG.C_PROBE7_WIDTH {7} \
        CONFIG.C_PROBE8_WIDTH {384} \
        CONFIG.C_PROBE9_WIDTH {32} \
        CONFIG.C_PROBE10_WIDTH {29} \
    ] [get_ips ila_cpu040]
    generate_target all [get_files [get_property IP_FILE [get_ips ila_cpu040]]]
    catch { create_ip_run [get_files [get_property IP_FILE [get_ips ila_cpu040]]] }
    set ipr [get_runs -quiet ila_cpu040_synth_1]
    if {$ipr ne "" && [get_property PROGRESS $ipr] ne "100%"} {
        launch_runs $ipr -jobs 8
        wait_on_run $ipr
    }
}

#-----------------------------------------------------------------------------
# The CPU core: the faster AP68040 (FASTER, above), or else the pipelined
# one (findings/ap040-pipelined/PLAN.md), its sources and its rtl/compat
# (wrapper, cache, MMU, adapters).  The pipelined core comes from the
# lib/AP68040-pipelined submodule, or from the checkout AP040_PIPE_DIR=<dir>
# in the environment names.  Its rtl/compat carries lifted copies of
# lib/AP68040's cache and adapters under the same module names, so
# lib/AP68040's files are disabled for the run and re-enabled afterwards.
# (The non-pipelined reference core and AP040_PIPE_DIR=none were removed
# 2026-10-21; lib/AP68040 stays only for ap040_bus16_adapter.v, which the
# faster build takes from it.)
#-----------------------------------------------------------------------------
set pipe_gen ""
set pipe_off {}
set pipe_dir ""
if {[info exists ::env(AP040_PIPE_DIR)] && $::env(AP040_PIPE_DIR) ne ""} {
    if {$::env(AP040_PIPE_DIR) eq "none"} {
        error "build_ap040.tcl: AP040_PIPE_DIR=none built the reference core, which was removed; unset it to build lib/AP68040-pipelined"
    }
    set pipe_dir $::env(AP040_PIPE_DIR)
} else {
    set pipe_dir $R/lib/AP68040-pipelined
}
if {$faster} {
    # The faster core: its SystemVerilog sources in the order of its own
    # bench (tb/build_sim.sh: packages first), the bridge, and lib/AP68040's
    # and the pipelined core's files off for the run (a crashed pipelined run
    # can leave its files enabled; both carry modules the wrapper would not
    # instantiate, but a stale enabled set is how black boxes happened before).
    set P [file normalize $R/lib/AP68040-faster]/rtl
    # (all but ap040_bus16_adapter.v: the wrapper keeps the 16-bit adapter for
    # the chipset bus, the NMI vector and undecoded space; its ap040_defs.svh
    # defines are the faster core's rtl/fpu copy, identical).  Added here, not
    # taken on trust from the project: a project_1 without lib/AP68040's files
    # left the adapter a black box (opt_design DRC INBB-3, 2026-10-26).
    add_src $R/lib/AP68040/rtl/ap040_bus16_adapter.v
    foreach f [get_files -quiet -of_objects [get_filesets sources_1] $R/lib/AP68040/rtl/*.v] {
        if {[file tail $f] eq "ap040_bus16_adapter.v"} {
            set_property IS_ENABLED true $f
            continue
        }
        if {[get_property IS_ENABLED $f]} { set_property IS_ENABLED false $f; lappend pipe_off $f }
    }
    foreach f [get_files -quiet -of_objects [get_filesets sources_1] *AP68040-pipelined/rtl/*] {
        set_property IS_ENABLED false $f
    }
    set pf {}
    foreach n {ap68040_pkg.sv gen/ap68040_upkg.sv ap68040_alu.sv ap68040_alu_slow.sv
               ap68040_muldiv.sv ap68040_biu.sv ap68040_ram.sv ap68040_atc.sv
               ap68040_dmu.sv ap68040_predec.sv ap68040_fetch.sv ap68040_decode.sv
               ap68040_useq.sv fpu/ap040_fpu.v ap68040_fpif.sv ap68040_backend.sv
               ap68040_snoop.sv ap68040.sv} {
        lappend pf $P/$n
    }
    lappend pf $R/rtl/soc/ap68040_minimig.sv
    foreach f $pf {
        add_src $f
        set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
        set_property IS_ENABLED true [get_files -of_objects [get_filesets sources_1] $f]
    }
    set inc [get_property include_dirs [get_filesets sources_1]]
    foreach d [list $P $P/fpu $P/gen] { if {[lsearch -exact $inc $d] < 0} { lappend inc $d } }
    set_property include_dirs $inc [get_filesets sources_1]
    # The core's own switches (TG68K.vhd ap040_fast_*): DUAL dual issue,
    # DC1_ATC the data ATC's own port for DC1 (timing).  Both default 1.
    set fdual [expr {[info exists ::env(FAST_DUAL)] && $::env(FAST_DUAL) eq "0" ? 0 : 1}]
    set fdc1  [expr {[info exists ::env(FAST_DC1ATC)] && $::env(FAST_DC1ATC) eq "0" ? 0 : 1}]
    # FAST_BTIC=0: the fetch BTB without its target words (BTIC)
    set fbtic [expr {[info exists ::env(FAST_BTIC)] && $::env(FAST_BTIC) eq "0" ? 0 : 1}]
    # FAST_ICHIP=0: code from chip/slow RAM and the ROM stays out of the
    # instruction cache, as before (the A/B leg; findings/aga-perf/fix.md)
    set fichip [expr {[info exists ::env(FAST_ICHIP)] && $::env(FAST_ICHIP) eq "0" ? 0 : 1}]
    set free_core 1
    set pipe_gen " AP040_FASTER=1 AP040_FREE_CORE=1 AP040_FAST_DUAL=$fdual AP040_FAST_DC1ATC=$fdc1 AP040_FAST_BTIC=$fbtic AP040_FAST_ICHIP=$fichip"
    puts "build_ap040.tcl: FASTER core from $P (DUAL=$fdual DC1_ATC=$fdc1 BTIC=$fbtic ICHIP=$fichip, CPU_CLK_DIVIDE $cpudiv, [llength $pipe_off] lib/AP68040 files disabled)"
} else {
    if {![file isdirectory $pipe_dir/rtl]} {
        error "build_ap040.tcl: no CPU core sources in $pipe_dir/rtl (git submodule update --init lib/AP68040-pipelined, or AP040_PIPE_DIR=<checkout>)"
    }
    set P [file normalize $pipe_dir]/rtl
    foreach f [get_files -quiet -of_objects [get_filesets sources_1] $R/lib/AP68040/rtl/*.v] {
        if {[get_property IS_ENABLED $f]} {
            set_property IS_ENABLED false $f
            lappend pipe_off $f
        }
    }
    set pf [list $P/ap040_pipe_pkg.sv]
    foreach f [glob $P/ap040_*.v] { lappend pf $f }
    foreach f [glob $P/compat/*.v] { lappend pf $f }
    foreach f $pf {
        add_src $f
        set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
        set_property IS_ENABLED true [get_files -of_objects [get_filesets sources_1] $f]
    }
    set inc [get_property include_dirs [get_filesets sources_1]]
    foreach d [list $P $P/compat] { if {[lsearch -exact $inc $d] < 0} { lappend inc $d } }
    set_property include_dirs $inc [get_filesets sources_1]
    # (2026-10-05) Every CPU switch below defaults to the configuration the
    # board runs (build/stage_r04mis: copyback + misaligned from the cache,
    # xSysInfo 1.44): the MMU, the FPU, STORE_BUF FWD RAS PRECISE SB_MMU
    # COPYBACK LDX BTFN DFP_MIS WALLOC on; BTB, MISPLIT, XC7, POST_CHIP, POST_CI and CWF off.  Each one can still be
    # switched off from the environment (e.g. COPYBACK=0) for an A/B.
    # AP040_PIPE_MMU: the lifted MMU (plan M7, gate 2); =0 leaves it out
    set pmmu [expr {[info exists ::env(AP040_PIPE_MMU)] && $::env(AP040_PIPE_MMU) eq "0" ? 0 : 1}]
    # AP040_PIPE_FPU: the lifted FPU (plan M10); every release image has it.
    # =0 builds a 68LC040.
    set pfpu [expr {[info exists ::env(AP040_PIPE_FPU)] && $::env(AP040_PIPE_FPU) eq "0" ? 0 : 1}]
    # The pipelined core runs free of the bus wait (findings/unfreeze/): default
    # since 2026-09-26 (board SysInfo 0.83x -> 1.00x).  FREE_CORE=0 in the
    # environment builds the frozen core, for an A/B.
    set free_core [expr {[info exists ::env(FREE_CORE)] && $::env(FREE_CORE) eq "0" ? 0 : 1}]
    # STORE_BUF=1|2 in the environment: the core's store buffer
    # (findings/storebuf/plan.md; 2 = the same hardware never posting).
    set store_buf [expr {[info exists ::env(STORE_BUF)] && $::env(STORE_BUF) ne "" ? $::env(STORE_BUF) : 1}]
    # FWD=1 / RAS=1: store-to-load forwarding and ID's return-address stack
    # (findings/catchup/plan.md).
    set fwd [expr {[info exists ::env(FWD)] && $::env(FWD) ne "" ? $::env(FWD) : 1}]
    set ras [expr {[info exists ::env(RAS)] && $::env(RAS) ne "" ? $::env(RAS) : 1}]
    # PRECISE=1 / MISPLIT=1: address-precise fast reads, misaligned split
    set precise [expr {[info exists ::env(PRECISE)] && $::env(PRECISE) ne "" ? $::env(PRECISE) : 1}]
    set misplit [expr {[info exists ::env(MISPLIT)] && $::env(MISPLIT) ne "" ? $::env(MISPLIT) : 0}]
    # SB_MMU=1: store buffer stage 4, stores posted with translation on
    set sb_mmu [expr {[info exists ::env(SB_MMU)] && $::env(SB_MMU) ne "" ? $::env(SB_MMU) : 1}]
    # COPYBACK=1: the copyback data cache (CM = 01 pages, DDR3 board only)
    set copyback [expr {[info exists ::env(COPYBACK)] && $::env(COPYBACK) ne "" ? $::env(COPYBACK) : 1}]
    # BTB=1: IF's branch target buffer
    set btb [expr {[info exists ::env(BTB)] && $::env(BTB) ne "" ? $::env(BTB) : 0}]
    # LDX=1: late-operand load dispatch (findings/loadstore/plan.md step 1)
    set ldx [expr {[info exists ::env(LDX)] && $::env(LDX) ne "" ? $::env(LDX) : 1}]
    # BTFN=1: forward conditional branches guessed not taken (findings/loadstore/plan.md section 11)
    set btfn [expr {[info exists ::env(BTFN)] && $::env(BTFN) ne "" ? $::env(BTFN) : 1}]
    # DFP_MIS=1: misaligned accesses served from the data cache (findings/loadstore/plan.md step 3)
    set dfp_mis [expr {[info exists ::env(DFP_MIS)] && $::env(DFP_MIS) ne "" ? $::env(DFP_MIS) : 1}]
    # WALLOC=1: write-allocate on a copyback store miss (copyback plan S3; board 1.50 / 49,444)
    set walloc [expr {[info exists ::env(WALLOC)] && $::env(WALLOC) ne "" ? $::env(WALLOC) : 1}]
    # XC7=1: Artix-7 resource mapping in the core (cache tables in distributed RAM, -3.3k LUTs).
    # Default 0: the XC7=1 board image (stage_combo1, 2026-10-09) failed at boot with
    # #80000004/#80000005 while the same build with XC7=0 runs; every simulation passes
    # with it on, the cause is open.
    set xc7 [expr {[info exists ::env(XC7)] && $::env(XC7) ne "" ? $::env(XC7) : 0}]
    # POST_CHIP=1: with the MMU on, stores to chip RAM are posted too; POST_CI=1|2:
    # stores to cache-inhibited pages are (1 noncachable nonserialized, CM = 11:
    # MuFastChip, a demo's DTT0 = $0000C060; 2 serialized ones, CM = 10, as well).
    # findings/postchip.  Both default 0 until the board says otherwise.
    set post_chip [expr {[info exists ::env(POST_CHIP)] && $::env(POST_CHIP) ne "" ? $::env(POST_CHIP) : 0}]
    set post_ci [expr {[info exists ::env(POST_CI)] && $::env(POST_CI) ne "" ? $::env(POST_CI) : 0}]
    # CWF=1: critical-word-first data-cache line fills with early restart (the core
    # goes on when the missed longword arrives, the line finishes in the background;
    # M68040UM 4.6.1).  Default 0 until the board says otherwise.
    set cwf [expr {[info exists ::env(CWF)] && $::env(CWF) ne "" ? $::env(CWF) : 0}]
    set pipe_gen " AP040_HAS_MMU=$pmmu AP040_HAS_FPU=$pfpu AP040_FREE_CORE=$free_core AP040_STORE_BUF=$store_buf AP040_FWD=$fwd AP040_RAS=$ras AP040_PRECISE=$precise AP040_MISPLIT=$misplit AP040_SB_MMU=$sb_mmu AP040_COPYBACK=$copyback AP040_BTB=$btb AP040_LDX=$ldx AP040_BTFN=$btfn AP040_DFP_MIS=$dfp_mis AP040_WALLOC=$walloc AP040_XC7=$xc7 AP040_POST_CHIP=$post_chip AP040_POST_CI=$post_ci AP040_CWF=$cwf"
    puts "build_ap040.tcl: PIPELINED build from $P ([llength $pipe_off] lib/AP68040 files disabled), FREE_CORE=$free_core STORE_BUF=$store_buf FWD=$fwd RAS=$ras PRECISE=$precise MISPLIT=$misplit SB_MMU=$sb_mmu COPYBACK=$copyback BTB=$btb LDX=$ldx BTFN=$btfn DFP_MIS=$dfp_mis WALLOC=$walloc XC7=$xc7 POST_CHIP=$post_chip POST_CI=$post_ci CWF=$cwf"
}

# The one functional difference from build.tcl: which kernel the wrapper
# elaborates, and whether the fast-RAM ILA comes along for the ride.
# FASTRAM_ILA=0 in the environment keeps the CPU ILA but drops the fast-RAM
# one: with M14's cache copies in block RAM, both ILAs together need 279
# RAMB18-equivalents of the 270 the device has (2026-09-24).
set fila [expr {[info exists ::env(FASTRAM_ILA)] && $::env(FASTRAM_ILA) ne "" ? $::env(FASTRAM_ILA) : $ila}]
# CHIP32=0 in the environment builds the wrapper with every longword as two
# word cycles (findings/chip32/plan.md); default 1.
set chip32 [expr {[info exists ::env(CHIP32)] && $::env(CHIP32) ne "" ? $::env(CHIP32) : 1}]
# RV_DEBUG=1: the board top's HOSTCPU_RVDEBUG (default 0) set to 1, which
# minimig_virtual_top hands to the bridge as rv_debug = 1 (rv_hostcpu DEBUG =
# 1).  The token is appended, so .last_generics differs from the shipping
# image's and the run re-synthesises.
set rv_gen ""
if {$rv_debug} {
    set rv_gen " HOSTCPU_RVDEBUG=1"
    puts "build_ap040.tcl: host CPU = RISC-V, DEBUG MODULE (rv_debug = 1, LAB BUILD)"
}
set_property generic "HAVEDDR3=1 DDR3_BIST_VIO=0 DDR3_FASTRAM_ILA=$fila CPU040_DEBUG_ILA=$ila AP040_POST_STORES=$post CPU_CLK_DIVIDE=$cpudiv CHIP32=$chip32$pipe_gen$rv_gen" \
    [get_filesets sources_1]

# The host CPU's sources in, retired ones out, for this run only (restored below).
# A run that changed the file groups always re-synthesises (below), so a
# synthesis of the other CPU is never reused.  RV_DEBUG=1 also puts the debug
# module's two sources and rv_debug.xdc in, restored the same way.
set hostcpu_changed [hostcpu_apply $R $rv_debug]

# The debug core adds a few thousand LUTs and flip-flops to clk_114, and with
# the default implementation strategy (no physical optimisation at all) the
# extra congestion costs the Minimig core about 0.4 ns on the TG68K-ALU to
# cpu_cache path -- a debug bitstream that violates setup on the very path
# being investigated is worthless.  Both physical-optimisation steps are
# therefore enabled for this run only and restored afterwards, exactly like the
# generics above.
set impl [get_runs impl_1]
set ppo_was [get_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED $impl]
set pro_was [get_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $impl]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $impl

# SDC_ILA=1: the ILA insertion as impl_1's opt_design TCL.PRE hook, for this
# run only (restored below).  The run inherits SDC_ILA / SDC_ILA_DEPTH from
# this process's environment; the hook refuses to run without SDC_ILA=1, so
# a hook left by a build that died before its restore fails the next build
# instead of slipping the ILA into it.
if {$sdc_ila} {
    set sdc_pre_was [get_property STEPS.OPT_DESIGN.TCL.PRE $impl]
    # a stale hook of a build that died before its restore is not "the
    # previous value": restore to none then
    if {$sdc_pre_was eq $sdc_ila_hook} {
        puts "build_ap040.tcl: opt_design hook was left set by an earlier SDC_ILA build; it is cleared afterwards"
        set sdc_pre_was {}
    }
    set_property STEPS.OPT_DESIGN.TCL.PRE $sdc_ila_hook $impl
    puts "build_ap040.tcl: SD card path ILA u_ila_sdc (SDC_ILA=1, depth $sdc_ila_depth, opt_design hook [file tail $sdc_ila_hook]), LAB BUILD"
}

# IMPL_EFFORT=high in the environment raises the implementation effort for ONE
# run and restores the previous directives afterwards, exactly like the two
# switches above.  It is for the case where a build misses timing by a tenth of
# a nanosecond on a path that is route-bound rather than structural -- not a
# way to make a structurally failing design "pass"
# (findings/ap040-pipelined/PLAN.md Q11).  The directives are the ones Xilinx
# documents for each step; a step that rejects its name fails the build rather
# than silently running the default.
set eff_was {}
if {[info exists ::env(IMPL_EFFORT)] && $::env(IMPL_EFFORT) eq "high"} {
    foreach {st dirname} {PLACE_DESIGN ExtraTimingOpt
                          PHYS_OPT_DESIGN AggressiveExplore
                          ROUTE_DESIGN AggressiveExplore
                          POST_ROUTE_PHYS_OPT_DESIGN AggressiveExplore} {
        set prop STEPS.$st.ARGS.DIRECTIVE
        dict set eff_was $st [get_property $prop $impl]
        set_property $prop $dirname $impl
    }
    puts "build_ap040.tcl: IMPL_EFFORT=high -- place ExtraTimingOpt, phys_opt/route/post-route AggressiveExplore"
}

# RE-SYNTHESISE ONLY WHEN SOMETHING ACTUALLY CHANGED.  This was an
# unconditional `reset_run synth_1`, so every build re-ran the longest stage
# even when only a constraint file had changed (an XDC is read by
# implementation, not synthesis).  Vivado already tracks its own inputs:
# NEEDS_REFRESH covers edited sources, and the generic string above is
# compared by hand because setting it does not always mark the run stale.
# A stale synthesis is never reused: any doubt resets the run.
#
# NOT INCREMENTAL IMPLEMENTATION.  Reusing a previous routed checkpoint
# (INCREMENTAL_CHECKPOINT) would cut implementation time too, and it is
# deliberately not used here: Paul has had builds that met timing with it and
# then misbehaved on the board, while the same design built from scratch was
# fine.  The result depends on the reference checkpoint, which is exactly what
# a timing-critical design must not do.  Do not add it.
#
# NOT INCREMENTAL SYNTHESIS either.  project_1 had synth_1's auto-incremental
# checkpoint on (Vivado's default for new projects): each synthesis started
# from a copy of an earlier run's netlist.  On 2026-10-09 that crashed 2023.2
# with signal 11 on every run after a small pal_to_ddr change, at a different
# place each time (Mimic Skeleton from Reference, then GXorGen::bestSoln /
# NGenJob::dumpJob in Cross Boundary and Area Optimization), depending on
# which earlier run had left the reference.  Always synthesise from scratch.
set synthrun [get_runs synth_1]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 $synthrun
set_property INCREMENTAL_CHECKPOINT {} $synthrun
set gen_now  [get_property generic [get_filesets sources_1]]
set gen_file $R/project_1/.last_generics
set gen_was  ""
if {[file exists $gen_file]} {
    set fh [open $gen_file r]; set gen_was [string trim [read $fh]]; close $fh
}
if {$gen_now ne $gen_was
    || $hostcpu_changed
    || [get_property NEEDS_REFRESH $synthrun]
    || [get_property PROGRESS $synthrun] ne "100%"
    || [get_property STATUS $synthrun] eq "Not started"} {
    puts "build_ap040.tcl: re-synthesising (generics, sources or host CPU file groups changed)"
    reset_run synth_1
} else {
    puts "build_ap040.tcl: synthesis is up to date, implementing only"
}
set fh [open $gen_file w]; puts $fh $gen_now; close $fh

# STOP_AFTER_ROUTE=1 in the environment skips write_bitstream: a timing-only
# experiment does not need a file it will never load.
set last_step "write_bitstream"
if {[info exists ::env(STOP_AFTER_ROUTE)] && $::env(STOP_AFTER_ROUTE) eq "1"} {
    set last_step "route_design"
    puts "build_ap040.tcl: STOP_AFTER_ROUTE=1, no bitstream will be written"
}
launch_runs impl_1 -to_step $last_step -jobs 8
wait_on_run impl_1
open_run impl_1
file mkdir $out
report_timing_summary -file $out/timing_summary.rpt
report_utilization   -file $out/utilization.rpt
# The point of this build: prove that every clk_114 <-> clk_ddr100 path is now
# timed, that the exceptions written for them are applied and not overridden,
# and that no crossing is left unprotected.
report_exceptions              -file $out/exceptions.rpt
report_exceptions -ignored     -file $out/exceptions_ignored.rpt
report_cdc                     -file $out/cdc.rpt
report_cdc -show_waiver        -file $out/cdc_with_waivers.rpt
report_waivers                 -file $out/waivers.rpt
report_cdc -details -from [get_clocks clk_114] -to [get_clocks clk_ddr100] \
    -file $out/cdc_114_to_100.rpt
report_cdc -details -from [get_clocks clk_ddr100] -to [get_clocks clk_114] \
    -file $out/cdc_100_to_114.rpt
report_cdc -details -from [get_clocks dll_28] -to [get_clocks clk_ddr100] \
    -file $out/cdc_28_to_100.rpt
report_clock_interaction -delay_type min_max -file $out/clock_interaction.rpt

# The host CPU reports (osd-riscv Phase 5): where the resources go, which CPU
# is in the netlist, the OSD reply handshake crossing (rtl/host/cfide.vhd:
# osd_rx_seq dll_28 -> osd_tx_seq clk_114 resync, osd_tx_seq/osd_rx_seq ->
# host_req_q dll_28), every failing path and the DRCs.  Each one in a catch:
# a report that fails must not cost the bitstream copy or the restores below.
proc try_report {name body} {
    if {[catch {uplevel 1 $body} msg]} {
        puts "build_ap040.tcl: WARNING report $name failed: $msg"
    }
}
try_report util_hier.rpt {
    report_utilization -hierarchical -hierarchical_depth 4 -file $out/util_hier.rpt
}
try_report util_hostcpu.rpt {
    report_utilization -cells [get_cells openaars_virtual_top/hostcpu] \
        -hierarchical -hierarchical_depth 3 -file $out/util_hostcpu.rpt
}
try_report clocks.rpt {
    report_clocks -file $out/clocks.rpt
}
try_report hostcpu_cells.txt {
    set fh [open $out/hostcpu_cells.txt w]
    puts $fh "# openaars_virtual_top/hostcpu: every hierarchical (leaf-parent) cell below it, with its REF_NAME"
    set hc [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE == 0 && NAME =~ openaars_virtual_top/hostcpu/*}]
    foreach c [lsort $hc] { puts $fh "$c [get_property REF_NAME $c]" }
    puts $fh "# hierarchical cells in the whole design per REF_NAME pattern (case-insensitive)"
    puts $fh "# patterns: VexOsd*, rv_hostcpu*, OSDBoot_rv_ROM*, the bridge host_bridge*"
    set refs [get_property REF_NAME [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE == 0}]]
    foreach pat {VexOsd* rv_hostcpu* OSDBoot_rv_ROM* host_bridge*} {
        set n 0
        foreach r $refs { if {[string match -nocase $pat $r]} { incr n } }
        puts $fh "count $pat $n"
    }
    close $fh
}
try_report handshake_timing.rpt {
    set hs_to   [get_cells -quiet -hierarchical -filter {NAME =~ *mycfide/osd_tx_seq_reg* || NAME =~ *mycfide/host_req_q_reg*}]
    set hs_from [get_cells -quiet -hierarchical -filter {NAME =~ *osd_rx_seq_reg*}]
    set hs_tx   [get_cells -quiet -hierarchical -filter {NAME =~ *mycfide/osd_tx_seq_reg*}]
    set hs_hq   [get_cells -quiet -hierarchical -filter {NAME =~ *mycfide/host_req_q_reg*}]
    set fh [open $out/handshake_timing.rpt w]
    puts $fh "# cells: to [llength $hs_to] (osd_tx_seq_reg*, host_req_q_reg*), from [llength $hs_from] (osd_rx_seq_reg*)"
    puts $fh "# 1: -from osd_rx_seq -to osd_tx_seq, host_req_q; 2: -from osd_tx_seq -to host_req_q"
    close $fh
    if {[llength $hs_to] && [llength $hs_from]} {
        report_timing -setup -hold -from $hs_from -to $hs_to -max_paths 4 -nworst 1 \
            -file $out/handshake_timing.rpt -append
    }
    if {[llength $hs_tx] && [llength $hs_hq]} {
        report_timing -setup -hold -from $hs_tx -to $hs_hq -max_paths 4 -nworst 1 \
            -file $out/handshake_timing.rpt -append
    }
}
try_report failing.rpt {
    report_timing -setup -hold -max_paths 100 -nworst 1 -slack_lesser_than 0 \
        -file $out/failing.rpt
}
try_report drc.rpt {
    report_drc -file $out/drc.rpt
}
# RV_DEBUG=1: the debug module's evidence in one file -- the BSCANE2 cell(s)
# and their JTAG_CHAIN (4 = USER4, what OpenOCD's BSCAN tunnel scans), the
# VexOsd_DMT cell count (1; VexOsd 0), the rv_tck clock rv_debug.xdc creates,
# and its paths: from it, to it, within it (the JTAG side of the DTM and the
# tunnel), plus the CDC report of the two crossings the asynchronous clock
# groups leave untimed (the DTM's FlowCCByToggle/BufferCC synchronisers).
if {$rv_debug} {
    try_report rv_debug.rpt {
        set fh [open $out/rv_debug.rpt w]
        puts $fh "# RV_DEBUG=1 LAB build: the RISC-V debug module (VexOsd_DMT, BSCANE2 USER4 tunnel, rv_debug = 1)"
        set bs [get_cells -quiet -hierarchical -filter {REF_NAME == BSCANE2}]
        puts $fh "# BSCANE2 cells: [llength $bs] (expected 1, JTAG_CHAIN 4)"
        foreach c [lsort $bs] { puts $fh "bscane2 $c JTAG_CHAIN [get_property JTAG_CHAIN $c]" }
        puts $fh "# hierarchical cells per REF_NAME (case-insensitive; VexOsd_DMT_* are its submodules)"
        set refs [get_property REF_NAME [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE == 0}]]
        foreach pat {VexOsd_DMT VexOsd_DMT_* VexOsd VexOsd_DMJ rv_bscane2} {
            set n 0
            foreach r $refs { if {[string match -nocase $pat $r]} { incr n } }
            puts $fh "count $pat $n"
        }
        close $fh
    }
    try_report "rv_debug.rpt (rv_tck clock)" {
        report_clocks -file $out/rv_debug.rpt -append [get_clocks rv_tck]
    }
    try_report "rv_debug.rpt (timing from rv_tck)" {
        report_timing -from [get_clocks rv_tck] -setup -hold -max_paths 10 -nworst 1 -file $out/rv_debug.rpt -append
    }
    try_report "rv_debug.rpt (timing to rv_tck)" {
        report_timing -to [get_clocks rv_tck] -setup -hold -max_paths 10 -nworst 1 -file $out/rv_debug.rpt -append
    }
    try_report "rv_debug.rpt (timing within rv_tck)" {
        report_timing -from [get_clocks rv_tck] -to [get_clocks rv_tck] -setup -hold -max_paths 10 -nworst 1 -file $out/rv_debug.rpt -append
    }
    try_report "rv_debug.rpt (CDC rv_tck <-> clk_114)" {
        report_cdc -details -from [get_clocks rv_tck] -to [get_clocks clk_114] -file $out/rv_debug.rpt -append
        report_cdc -details -from [get_clocks clk_114] -to [get_clocks rv_tck] -file $out/rv_debug.rpt -append
    }
}

# SDC_ILA=1: the core's size and the timing of its probe inputs.
if {$sdc_ila} {
    try_report sdc_ila.rpt {
        report_utilization -cells [get_cells u_ila_sdc] -hierarchical -hierarchical_depth 2 -file $out/sdc_ila.rpt
    }
    try_report "sdc_ila.rpt (debug cores)" {
        report_debug_core -file $out/sdc_ila_cores.rpt
    }
    try_report "sdc_ila.rpt (timing into the core)" {
        report_timing -to [get_cells -hierarchical -filter {NAME =~ u_ila_sdc/*}] -setup -hold -max_paths 10 -nworst 1 -file $out/sdc_ila.rpt -append
    }
}

# Deliverables next to the reports.
set impldir $R/project_1/project_1.runs/impl_1
file mkdir $out
foreach ext {bit ltx} {
    if {[file exists $impldir/minimig_openaars_top.$ext]} {
        file copy -force $impldir/minimig_openaars_top.$ext $out/
        puts "build_ap040.tcl: copied minimig_openaars_top.$ext to $out"
    } else {
        puts "build_ap040.tcl: WARNING minimig_openaars_top.$ext not produced"
    }
}
if {$sdc_ila} {
    foreach f {sdc_ila_map.txt sdc_ila_hwprobes.tcl} {
        if {[file exists $impldir/$f]} {
            file copy -force $impldir/$f $out/
            puts "build_ap040.tcl: copied $f to $out"
        } else {
            puts "build_ap040.tcl: WARNING $f not produced"
        }
    }
    # the .ltx net name of every core bit (for the CSV columns; the capture
    # script arms on sdc_ila_hwprobes.tcl's probes, not on these names)
    if {[catch {exec python3 $R/tools/vivado/sdc_ila_names.py $out} msg]} {
        puts "build_ap040.tcl: WARNING sdc_ila_names.py: $msg"
    } else {
        puts "build_ap040.tcl: $msg"
    }
}

set_property generic {} [get_filesets sources_1]
foreach f $pipe_off { set_property IS_ENABLED true $f }
if {$pipe_gen ne ""} {
    foreach f [get_files -quiet -of_objects [get_filesets sources_1] $P/*] { set_property IS_ENABLED false $f }
    if {$faster} {
        foreach f [get_files -quiet -of_objects [get_filesets sources_1] $R/rtl/soc/ap68040_minimig.sv] {
            set_property IS_ENABLED false $f
        }
        # The project's resting state whatever an earlier run left behind (a
        # run that dies in wait_on_run never reaches this point, and the next
        # one finds nothing of its own to restore): lib/AP68040 on, cpu.xdc
        # on, cpu_r2.xdc off.  Every build mode sets its own state at start.
        foreach f [get_files -quiet -of_objects [get_filesets sources_1] $R/lib/AP68040/rtl/*.v] {
            set_property IS_ENABLED true $f
        }
        foreach {x on} [list $R/fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc true \
                             $R/fpga/openaars/aars_v5.0/xc7a100t/cpu_r2.xdc false] {
            foreach f [get_files -quiet -of_objects [get_filesets XC7A100T] $x] { set_property IS_ENABLED $on $f }
        }
        set xdc_off {}
    }
    puts "build_ap040.tcl: lib/AP68040 re-enabled, [expr {$faster ? {faster} : {pipelined}}] sources disabled"
}
foreach f $xdc_off { set_property IS_ENABLED true $f }
hostcpu_restore
if {$sdc_ila} {
    set_property STEPS.OPT_DESIGN.TCL.PRE $sdc_pre_was $impl
    puts "build_ap040.tcl: opt_design hook restored to '$sdc_pre_was'"
}
foreach {st was} $eff_was { set_property STEPS.$st.ARGS.DIRECTIVE $was $impl }
if {[dict size $eff_was]} { puts "build_ap040.tcl: implementation directives restored" }
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED $ppo_was $impl
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $pro_was $impl
puts "build_ap040.tcl: generics cleared: '[get_property generic [get_filesets sources_1]]'"
puts "build_ap040.tcl: phys_opt steps restored to $ppo_was / $pro_was"
puts "=== ALL DONE ==="
