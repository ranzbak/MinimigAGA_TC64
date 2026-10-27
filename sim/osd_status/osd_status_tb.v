// The OSD text layer's status (findings/osd-redesign Phase 4): VERSION
// (0x88) reply bytes 10..14 of userio_osd.v.  With OSD_TEXT = 1: B5, the
// layer version 2, 64, 32, then byte 14 = {7'd0, rtg_ena}, following
// rtg_ena both ways; with OSD_TEXT = 0 (a core without the layer): MINION_VER
// in all five, as before.  The firmware (fw/ctrl/osd2.c osd2_rtg_active)
// reads byte 14 only from layer version 2 on.  The RTG screen's Video Pos
// register is cfide's (VHDL): cfide_tb.vhd, run by run.sh under GHDL.
//
//   bash sim/osd_status/run.sh          both benches: "=== PASS" each
//   bash sim/osd_status/run.sh mutants  each mutant must FAIL where meant
`timescale 1ns/1ps

module osd_status_tb;

`include "minimig_version.vh"

  reg clk = 0;
  always #17.8 clk = ~clk;         // 28.375 MHz
  reg [1:0] ph = 0;
  always @(posedge clk) ph <= ph + 2'd1;
  wire clk7_en  = (ph == 2'd0);
  wire clk7n_en = (ph == 2'd2);

  reg  rtg_ena = 1'b0;
  reg  scs_txt = 1'b1, scs_old = 1'b1, sdi = 1'b0, sck = 1'b1;
  wire sdo_txt, sdo_old;
  integer errors = 0;

  // one instance with the text layer, one without
  userio_osd #(.CORE_CAPS(8'h0d), .OSD_TEXT(1)) dut (
    .clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .reset(1'b0),
    .c1(1'b0), .c3(1'b0), .sol(1'b0), .sof(1'b0),
    .varbeamen(1'b0), .rtg_ena(rtg_ena), .osd_ctrl(8'h00),
    .in_diag(32'h0), .in_diag_clr(),
    ._scs(scs_txt), .sdi(sdi), .sdo(sdo_txt), .sck(sck),
    .osd_rx_seq(), .osd_txt(), .osd_blank(), .osd_pixel(), .osd_enable(), .key_disable(),
    .memory_config(), .chipset_config(), .floppy_config(), .scanline(), .dither(),
    .ide_config0(), .ide_config1(), .cpu_config(), .autofire_config(), .cd32pad(),
    .usrrst(), .cpurst(), .cpuhlt(), .fifo_full(),
    .host_cs(), .host_adr(), .host_we(), .host_bs(), .host_wdat(),
    .host_rdat(16'h0000), .host_ack(1'b0)
  );
  userio_osd #(.CORE_CAPS(8'h0d), .OSD_TEXT(0)) old (
    .clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .reset(1'b0),
    .c1(1'b0), .c3(1'b0), .sol(1'b0), .sof(1'b0),
    .varbeamen(1'b0), .rtg_ena(rtg_ena), .osd_ctrl(8'h00),
    .in_diag(32'h0), .in_diag_clr(),
    ._scs(scs_old), .sdi(sdi), .sdo(sdo_old), .sck(sck),
    .osd_rx_seq(), .osd_txt(), .osd_blank(), .osd_pixel(), .osd_enable(), .key_disable(),
    .memory_config(), .chipset_config(), .floppy_config(), .scanline(), .dither(),
    .ide_config0(), .ide_config1(), .cpu_config(), .autofire_config(), .cd32pad(),
    .usrrst(), .cpurst(), .cpuhlt(), .fifo_full(),
    .host_cs(), .host_adr(), .host_we(), .host_bs(), .host_wdat(),
    .host_rdat(16'h0000), .host_ack(1'b0)
  );

  // an SPI byte as cfide clocks it (sck idles high, out on the falling edge,
  // in on the rising one), slow: this bench is about the bytes, not the link
  task spi_byte(input which, input [7:0] tx, output [7:0] rx_b);
    integer i;
    begin
      for (i = 7; i >= 0; i = i - 1) begin
        sck = 1'b0;  sdi = tx[i];  #500;
        rx_b[i] = which ? sdo_txt : sdo_old;
        sck = 1'b1;  #500;
      end
    end
  endtask

  reg [7:0] ver [0:14];
  task read_version(input which);
    integer k;
    reg [7:0] b;
    begin
      if (which) scs_txt = 1'b0; else scs_old = 1'b0;
      #200;
      spi_byte(which, 8'h88, b);
      for (k = 0; k < 15; k = k + 1) begin
        spi_byte(which, 8'h00, b);
        ver[k] = b;
      end
      #200;
      scs_txt = 1'b1;  scs_old = 1'b1;
      #2000;
    end
  endtask

  task check(input [8*40:1] what, input [39:0] got, input [39:0] want);
    begin
      if (got !== want) begin
        $display("FAIL: %0s = %010h, expected %010h", what, got, want);
        errors = errors + 1;
      end else
        $display("  ok: %0s = %010h", what, got);
    end
  endtask

  initial begin
    #3000;
    $display("--- the text layer, RTG off");
    read_version(1);
    check("(a) bytes 10..14, RTG off", {ver[10], ver[11], ver[12], ver[13], ver[14]}, 40'hB5_02_40_20_00);
    check("(a) byte 4 the magic", {32'd0, ver[4]}, {32'd0, 8'hA4});
    $display("--- the text layer, RTG on");
    rtg_ena = 1'b1;
    #2000;
    read_version(1);
    check("(b) bytes 10..14, RTG on", {ver[10], ver[11], ver[12], ver[13], ver[14]}, 40'hB5_02_40_20_01);
    $display("--- RTG off again");
    rtg_ena = 1'b0;
    #2000;
    read_version(1);
    check("(c) byte 14 follows rtg_ena back", {32'd0, ver[14]}, 40'd0);
    $display("--- no text layer (OSD_TEXT = 0), RTG on");
    rtg_ena = 1'b1;
    #2000;
    read_version(0);
    check("(d) bytes 10..14 MINION_VER", {ver[10], ver[11], ver[12], ver[13], ver[14]},
          {MINION_VER, MINION_VER, MINION_VER, MINION_VER, MINION_VER});
    if (errors == 0) $display("=== PASS");
    else $display("=== FAIL (%0d)", errors);
    $finish;
  end
endmodule
