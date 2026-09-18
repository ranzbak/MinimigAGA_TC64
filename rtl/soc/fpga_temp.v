// On-die temperature from the XC7A100T's XADC.
//
// Asked for by Paul, 2026-09-18: the die temperature on the first line of the
// Chipset OSD menu.
//
// The XADC is left in its DEFAULT MODE (the sequencer bits SEQ[3:0] in
// configuration register 1 are zero, which is the primitive's reset value).
// In that mode it samples the on-chip sensors -- temperature, VCCINT, VCCAUX,
// VCCBRAM -- by itself and keeps the status registers up to date, so nothing
// here has to drive a conversion or program a channel sequence.  That is why
// this module configures almost nothing: the one setting that does matter is
// the DCLK divider, because ADCCLK has to land inside the XADC's operating
// range (1-26 MHz), and with DCLK at 113.4 MHz a divider of 8 puts it at about
// 14 MHz.
//
// It runs on clk_114, the clock cfide already uses, so the reading needs no
// clock crossing to reach the host bus.  A 12-bit value that changes every
// 20 ms is exactly the kind of thing that gets torn by a careless crossing,
// and the cheapest way not to get that wrong is not to have one.
//
// All this module does, then, is read DRP address 0x00 (the temperature status
// register) over and over and latch the result.  The 12-bit reading sits in
// DO[15:4]; the conversion to degrees is left to the firmware, which has the
// arithmetic to do it properly:
//
//     T (degC) = raw * 503.975 / 4096 - 273.15
//
// Reading a status register cannot disturb a conversion, so there is no need
// to interlock with EOC/EOS, and DO is stable when DRDY is asserted.
//
// The reads are deliberately slow -- a counter spaces them about 20 ms apart.
// The die temperature does not move quickly, the OSD polls it slower than
// that, and a tight DRP loop would be pointless traffic.
//
// UNVERIFIED ON HARDWARE.  The INIT values and the DO[15:4] field position are
// from the XADC primitive's own definition and the standard transfer function;
// they have not been read back from a running board yet.  Check the number is
// plausible (an idle board should read somewhere in the 40-60 degC range, and
// should climb under load) before trusting it.

module fpga_temp (
  input  wire        clk,        // clk_114 (113.4 MHz), also DCLK
  input  wire        reset,      // active high
  output reg  [11:0] temp_raw    // last temperature reading, DO[15:4]
);

// About 20 ms at 113.4 MHz.  Nothing depends on the exact interval.
localparam [21:0] INTERVAL = 22'd2268000;

reg [21:0] tick = 22'd0;
reg        den  = 1'b0;

wire [15:0] do_w;
wire        drdy_w;

always @(posedge clk) begin
  if (reset) begin
    tick     <= 22'd0;
    den      <= 1'b0;
    temp_raw <= 12'd0;
  end else begin
    // DEN is a single-cycle strobe; the XADC latches DADDR with it.
    den <= 1'b0;

    if (tick == INTERVAL) begin
      tick <= 22'd0;
      den  <= 1'b1;
    end else begin
      tick <= tick + 22'd1;
    end

    if (drdy_w)
      temp_raw <= do_w[15:4];
  end
end

XADC #(
  // Configuration registers 0 and 1 keep their reset values: default mode,
  // no averaging changes, no alarms acted on here.
  .INIT_40(16'h0000),   // config reg 0
  .INIT_41(16'h0000),   // config reg 1 -- SEQ[3:0] = 0000, default mode
  .INIT_42(16'h0800)    // config reg 2 -- DCLK divider = 8
) xadc_inst (
  .DO       (do_w),
  .DRDY     (drdy_w),
  .DADDR    (7'h00),    // temperature status register
  .DCLK     (clk),
  .DEN      (den),
  .DI       (16'h0000),
  .DWE      (1'b0),     // read only: nothing here writes the XADC
  .RESET    (reset),
  // No external analog inputs are used; only the on-die sensors.
  .VP       (1'b0),
  .VN       (1'b0),
  .VAUXP    (16'h0000),
  .VAUXN    (16'h0000),
  .CONVST   (1'b0),
  .CONVSTCLK(1'b0),
  .BUSY     (),
  .EOC      (),
  .EOS      (),
  .CHANNEL  (),
  .MUXADDR  (),
  .ALM      (),
  .OT       (),
  .JTAGBUSY (),
  .JTAGLOCKED(),
  .JTAGMODIFIED()
);

endmodule
