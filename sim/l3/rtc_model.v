// rtc_model: the SPI real-time clock fw/ctrl/rtc.c talks to on sd_cs[7]
// (simulation only, sim/l3).  The part is the NXP PCF2123 (plan 7.1 item 12,
// rtl/openaars/pcf2123, doc/hardware.md); its datasheet is not in doc/rtc
// (README "Monitors", item 12).
//
// Protocol, as rtc.c and rtl/openaars/pcf2123/rtc_spi_clock.sv use it: after
// cs_n falls, the first byte is the command {R/W (1 = read), subaddress
// [6:4] (001), register [3:0]}; every further byte reads or writes that
// register and the address counts up (wrapping at 16).  rtc.c sends 0x92:
// read from register 2 (Seconds), then Minutes, Hours, Days, Weekdays,
// Months, Years (registers 2..8, BCD).  A command with another subaddress is
// ignored (MISO stays 1, writes are dropped and printed).
//
// SPI as cfide drives it (sd_clk idles high): MOSI sampled on the rising sck
// edge, MISO changed on the falling edge, MSB first.  MISO is 1 outside a
// read.
//
// The clock does not run: every read answers 2026-01-01 00:00:00, a
// Thursday (weekday 4, 0 = Sunday), so the RTC frames of a run do not depend
// on its timing.  Writes are recorded (printed, stored in the registers).
//
// Monitor: the CS-inactive time between two transfers (cs_n rising to the
// next falling), task report prints
//   === RTC transfers <n>, writes <m>
//   === RTC CS high min <ns> ns over <k> gaps (datasheet minimum: not found)
// ("none" without a gap); csh_min_ns / n_gaps for the bench's MARGIN line.
`timescale 1ns/1ps

module rtc_model (
  input  wire cs_n,
  input  wire sck,
  input  wire mosi,
  output reg  miso
);

  reg [7:0] regs [0:15];
  reg [7:0] sr = 8'h00;           // MOSI shift register
  reg [7:0] tx = 8'hFF;           // the byte being sent
  integer   bitn = 0, byten = 0;
  reg [3:0] ra = 4'h0;            // register address
  reg       rd = 1'b0, sa_ok = 1'b0;
  integer   k;

  integer   n_xfer = 0, n_wr = 0, n_gaps = 0;
  real      t_rise = -1.0, csh_min_ns = -1.0, g;
  // a transfer is cs_n going from a seen 1 to 0; a gap is the time from the
  // end of a transfer to the start of the next.  The edges of cs_n settling
  // at time 0 (cfide's reset; random under XRAND) are neither.
  integer   cs_prev = -1;           // the last cs_n level seen: 1, 0, -1 (X/Z)
  reg       in_xfer = 1'b0;

  initial begin
    miso = 1'b1;
    for (k = 0; k < 16; k = k + 1) regs[k] = 8'h00;
    regs[2] = 8'h00;   // Seconds
    regs[3] = 8'h00;   // Minutes
    regs[4] = 8'h00;   // Hours (24 h)
    regs[5] = 8'h01;   // Days
    regs[6] = 8'h04;   // Weekdays (Thursday)
    regs[7] = 8'h01;   // Months
    regs[8] = 8'h26;   // Years
  end

  always @(cs_n) begin
    if (cs_prev == 1 && cs_n === 1'b0 && $realtime > 0.0) begin
      in_xfer = 1'b1;
      start_xfer;
    end else if (cs_prev == 0 && cs_n === 1'b1 && in_xfer) begin
      in_xfer = 1'b0;
      t_rise = $realtime;
      miso = 1'b1;
    end
    cs_prev = (cs_n === 1'b1) ? 1 : (cs_n === 1'b0) ? 0 : -1;
  end

  // a new transfer: the gap since the last one, the shifter state
  task start_xfer;
    begin
      if (t_rise >= 0.0) begin
        g = $realtime - t_rise;
        n_gaps = n_gaps + 1;
        if (csh_min_ns < 0.0 || g < csh_min_ns) csh_min_ns = g;
      end
      n_xfer = n_xfer + 1;
      bitn = 0;
      byten = 0;
      rd = 1'b0;
      sa_ok = 1'b0;
      tx = 8'hFF;
      miso = 1'b1;
    end
  endtask

  always @(posedge sck) if (in_xfer && cs_n === 1'b0) begin
    sr = {sr[6:0], mosi};
    bitn = bitn + 1;
    if (bitn == 8) begin
      bitn = 0;
      if (byten == 0) begin
        rd = sr[7];
        sa_ok = (sr[6:4] == 3'b001);
        ra = sr[3:0];
        if (!sa_ok) $display("RTC: command %h ignored (subaddress %b, not 001)", sr, sr[6:4]);
      end else if (!rd) begin
        n_wr = n_wr + 1;
        if (sa_ok) begin
          $display("RTC: write register %h = %h", ra, sr);
          regs[ra] = sr;
        end else
          $display("RTC: write %h dropped (no valid command)", sr);
        ra = ra + 4'h1;
      end
      byten = byten + 1;
      // the next byte: a register of a read command, else 1s
      if (rd && sa_ok) begin
        tx = regs[ra];
        ra = ra + 4'h1;
      end else
        tx = 8'hFF;
    end
  end

  // MSB first, changed on the falling edge (bit 7 of a byte on its first
  // falling edge: the edge before its first rising edge)
  always @(negedge sck) if (in_xfer && cs_n === 1'b0) begin
    miso = tx[7 - bitn];
  end

  task report;
    begin
      $display("=== RTC transfers %0d, writes %0d", n_xfer, n_wr);
      if (n_gaps > 0)
        $display("=== RTC CS high min %0.1f ns over %0d gaps (datasheet minimum: not found)", csh_min_ns, n_gaps);
      else
        $display("=== RTC CS high min none ns over 0 gaps (datasheet minimum: not found)");
    end
  endtask

endmodule
