`timescale 1ns/1ps
// minimig_spi_stub: stand-in for the Minimig SPI slaves behind cfide in the
// L2 firmware boot (tb_host_bridge.v with -d FWBOOT, run.sh fwboot).  Only
// what the firmware needs to reach its main loop on a card without a
// kickstart; every reply is fixed, nothing is decoded beyond the OSD command.
//
//   cs[4]  FPGA (EnableFpga, CS 0x10)   every byte 0x00: no drive request
//   cs[5]  OSD  (EnableOsd,  CS 0x20)   byte 0 (the command) answers 0x00;
//          after it, by command:
//            OSD_CMD_VERSION 0x88  01 1A 0A 02 A4 7D, then 0x00
//                                  (the board's reply, 174322f: beta 1,
//                                  2026-10-02, magic A4, caps 7D)
//            OSD_CMD_KEYQ    0x98  0x00 (queue empty)
//            anything else         0x00 (OSD_CMD_READ 0x00 reads its level
//                                  during byte 0: 0x00, no key)
//   cs[7]  RTC  (EnableRTC,  CS 0x80)   every byte 0x00
// miso is 1 while none of the three is selected (the bench gives cfide the
// SD card model's MISO while cs[1] is low).
//
// SPI mode as cfide drives it: sck idles high, the master changes MOSI on
// the falling edge and samples MISO on the rising edge.  The stub loads the
// next reply byte at the falling edge that starts a byte and samples MOSI on
// the rising edges.  The falling edge of a select starts a new frame (byte
// counter 0).  Only edge-triggered blocks write the state: a level-sensitive
// "always @(cs)" writing the counters made Verilator 5.020 lose the
// OSD_CMD_VERSION reply (all 00) in one build and not in another.
module minimig_spi_stub (
  input        n_reset,
  input  [7:0] cs,        // cfide's sd_cs, active low
  input        sck,
  input        mosi,
  output       miso
);

  wire sel_fpga = cs[4] === 1'b0;
  wire sel_osd  = cs[5] === 1'b0;
  wire sel_rtc  = cs[7] === 1'b0;
  wire sel      = sel_fpga | sel_osd | sel_rtc;

  integer   nbyte = 0, nbit = 0;   // in the current frame
  reg [7:0] cmd = 8'h00;           // OSD: byte 0 of the frame
  reg [7:0] rx = 8'h00, tx = 8'h00;
  reg       miso_r = 1'b1;
  assign miso = sel ? miso_r : 1'b1;

  always @(negedge cs[4] or negedge cs[5] or negedge cs[7]) begin
    nbyte = 0;
    nbit = 0;
  end

  function [7:0] osd_reply(input [7:0] c, input integer n);
    begin
      osd_reply = 8'h00;
      if (c == 8'h88)
        case (n)
          1: osd_reply = 8'h01;
          2: osd_reply = 8'h1A;
          3: osd_reply = 8'h0A;
          4: osd_reply = 8'h02;
          5: osd_reply = 8'hA4;
          6: osd_reply = 8'h7D;
          default: osd_reply = 8'h00;
        endcase
    end
  endfunction

  always @(negedge sck) if (n_reset && sel) begin
    if (nbit == 0) tx = (sel_osd && nbyte > 0) ? osd_reply(cmd, nbyte) : 8'h00;
    miso_r <= #2 tx[7 - nbit];
  end

  always @(posedge sck) if (n_reset && sel) begin
    rx = {rx[6:0], mosi};
    nbit = nbit + 1;
    if (nbit == 8) begin
      if (nbyte == 0) cmd = rx;
      nbyte = nbyte + 1;
      nbit = 0;
    end
  end

endmodule
