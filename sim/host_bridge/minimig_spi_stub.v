`timescale 1ns/1ps
// minimig_spi_stub: stand-in for the Minimig SPI slaves behind cfide in the
// L2 firmware boot (tb_host_bridge.v with -d FWBOOT, run.sh fwboot).  Only
// what the firmware needs to reach its main loop on a card without a
// kickstart; every reply is fixed, nothing is decoded beyond the OSD command.
//
//   cs[4]  FPGA (EnableFpga, CS 0x10)   every byte 0x00: no drive request
//   cs[5]  OSD  (EnableOsd,  CS 0x20)   byte 0 (the command) answers 0x00;
//          after it, by command:
//            OSD_CMD_VERSION 0x88  01 1A 0A 02 A4 7D, 4 x 00, B5 02 40 20
//                                  00, then 0x00 (the board's reply,
//                                  174322f: beta 1, 2026-10-02, magic A4,
//                                  caps 7D; the input diagnostic 0; the
//                                  OSD text layer version 2, 64 x 32,
//                                  status 0 -- the layer the boot ROM's
//                                  lock-step wants, OSD2_REQUIRED, since
//                                  OSD redesign Phase 6)
//            OSD_CMD_KEYQ    0x98  0x00 (queue empty)
//            anything else         0x00 (OSD_CMD_READ 0x00 reads its level
//                                  during byte 0: 0x00, no key)
//   cs[7]  RTC  (EnableRTC,  CS 0x80)   every byte 0x00
// miso is 1 while none of the three is selected (the bench gives cfide the
// SD card model's MISO while cs[1] is low).
//
// osd_rx_seq (Phase 4 Task 11): userio_osd's reply sequence as cfide's
// HOST_REQ OSD_RDY compares it (rtl/minimig/userio_osd.v osd_rx_seq, a byte
// count mod 4).  +1 for every byte clocked while cs[5] is low, +STUB_RDY_DLY
// clk_114 cycles (default 40) after its last sck edge, counted from the
// first clk_114 edge after that edge; in the RTL osd_rx_seq steps at most
// 40 clk_114 after that edge (findings/osd-riscv/phase4.md, "The rx
// window"), so the default is userio_osd's worst case.  +STUB_RDY_DLY=-1: frozen at 0, the firmware's every OSD
// wait runs into its bound (except where cfide's 2-bit count wraps onto
// it: README "OSD_RDY").  rdy_pending is 1 while an increment is due and not
// yet applied (the bench's OSD RDY early monitor).
//
// SPI mode as cfide drives it: sck idles high, the master changes MOSI on
// the falling edge and samples MISO on the rising edge.  The stub loads the
// next reply byte at the falling edge that starts a byte and samples MOSI on
// the rising edges.  The falling edge of a select starts a new frame (byte
// counter 0).  Only edge-triggered blocks write the state: a level-sensitive
// "always @(cs)" writing the counters made Verilator 5.020 lose the
// OSD_CMD_VERSION reply (all 00) in one build and not in another.
module minimig_spi_stub (
  input        clk,       // clk_114 (the OSD_RDY delay counts its edges)
  input        n_reset,
  input  [7:0] cs,        // cfide's sd_cs, active low
  input        sck,
  input        mosi,
  output       miso,
  output [1:0] osd_rx_seq
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

  // OSD_RDY: osd_bytes is written by the sck block, the rest by the clk
  // block; rdy_done and rx_seq with non-blocking assignments, so a reader at
  // the same clk_114 edge sees the value from before it.
  integer   rdy_dly = 40;          // +STUB_RDY_DLY
  integer   osd_bytes = 0;         // OSD bytes whose last sck edge has passed
  integer   rdy_seen = 0;          // of those, queued with their due cycle
  integer   rdy_done = 0;          // increments applied
  integer   rdy_cyc = 0;           // clk_114 edges
  integer   rdy_due [0:63];        // due cycle per queued byte (mod 64)
  reg [1:0] rx_seq = 2'd0;
  assign osd_rx_seq = rx_seq;
  wire      rdy_pending = osd_bytes != rdy_done;

  initial if (!$value$plusargs("STUB_RDY_DLY=%d", rdy_dly)) rdy_dly = 40;

  always @(posedge clk) begin
    rdy_cyc = rdy_cyc + 1;
    if (rdy_dly >= 0) begin
      if (rdy_seen < osd_bytes) begin
        rdy_due[rdy_seen % 64] = rdy_cyc + rdy_dly;
        rdy_seen = rdy_seen + 1;
      end
      if (rdy_done < rdy_seen && rdy_cyc >= rdy_due[rdy_done % 64]) begin
        rx_seq <= rx_seq + 2'd1;
        rdy_done <= rdy_done + 1;
      end
    end
  end

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
          11: osd_reply = 8'hB5;
          12: osd_reply = 8'h02;
          13: osd_reply = 8'h40;
          14: osd_reply = 8'h20;
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
      if (sel_osd) osd_bytes = osd_bytes + 1;
      nbyte = nbyte + 1;
      nbit = 0;
    end
  end

endmodule
