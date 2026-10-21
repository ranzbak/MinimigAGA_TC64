`timescale 1ns / 1ps
// rv_bscane2: the FPGA's own JTAG chain (Xilinx 7-series BSCANE2, USER4)
// as the jtagInstruction port of VexOsd_DMT (rv_hostcpu DEBUG = 1,
// bridge generic rv_debug = 1).
//
// THE ONLY VENDOR-PRIMITIVE FILE OF THE HOST CPU.  Xilinx 7-series only.
// Listed only in Vivado build/OOC/sim scripts, never in rtl/host/host.qip;
// rv_hostcpu instantiates it only inside its DEBUG = 1 generate branch, so
// DEBUG = 0 / 2 builds (and Quartus) never see this file.
//
// Pin mapping as SpinalHDL v1.13.0 spinal.lib.blackbox.xilinx.s7
// BSCANE2.toJtagTapInstructionCtrl (lib/.../xilinx/s7/Config.scala):
//   tdi <- TDI, enable(sel) <- SEL, capture <- CAPTURE, shift <- SHIFT,
//   update <- UPDATE, reset <- RESET, tdo -> TDO.
// JTAG_CHAIN = 4 (USER4): VexRiscv README "BSCANE2(userId = 4) // must be
// userId = 4"; OpenOCD `riscv use_bscan_tunnel` scans that USER register.
// TCK goes through a BUFG (as SpinalHDL Bscane2BmbMaster: BUFG.on(TCK)):
// it clocks the DTM and its clock crossing inside VexOsd_DMT.
//
// Timing: TCK is a clock of its own, asynchronous to clk.  A build that
// keeps rv_debug = 1 needs, e.g.:
//   create_clock -name rv_tck -period 50.000 [get_pins -hier -filter {NAME =~ *u_bscan/u_bscane2/TCK}]
//   set_clock_groups -asynchronous -group rv_tck -group <host clock>
// (tools/vivado/ooc_hostcpu/run_bridge.tcl, mode rv1, does this).
module rv_bscane2 (
  output wire tck,
  output wire tdi,
  output wire sel,
  output wire capture,
  output wire shift,
  output wire update,
  output wire reset,
  input  wire tdo
);
  wire tck_raw;

  BSCANE2 #(
    .DISABLE_JTAG ("FALSE"),
    .JTAG_CHAIN   (4)
  ) u_bscane2 (
    .CAPTURE (capture),
    .DRCK    (),
    .RESET   (reset),
    .RUNTEST (),
    .SEL     (sel),
    .SHIFT   (shift),
    .TCK     (tck_raw),
    .TDI     (tdi),
    .TMS     (),
    .UPDATE  (update),
    .TDO     (tdo)
  );

  BUFG u_bufg_tck (
    .I (tck_raw),
    .O (tck)
  );
endmodule
