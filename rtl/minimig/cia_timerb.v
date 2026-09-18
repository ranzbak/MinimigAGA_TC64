module cia_timerb
(
  input   clk,            // clock
  input clk7_en,
  input  wr,            // write enable
  input   reset,           // reset
  input   tlo,          // timer low byte select
  input  thi,           // timer high byte select
  input  tcr,          // timer control register
  input   [7:0] data_in,      // bus data in
  output   [7:0] data_out,      // bus data out
  input  eclk,            // count enable
  input  cnt,            // CNT pin, idle high
  input  tmra_ovf,        // timer A underflow
  output  irq            // intterupt out
);

reg    [15:0] tmr;        // timer
reg    [7:0] tmlh;        // timer latch high byte
reg    [7:0] tmll;        // timer latch low byte
reg    [6:0] tmcr;        // timer control register
reg    forceload;        // force load strobe
wire  oneshot;        // oneshot mode
wire  start;          // timer start (enable)
reg    thi_load;         // load tmr after writing thi in one-shot mode
wire  reload;          // reload timer counter
wire  zero;          // timer counter is zero
wire  underflow;        // timer is going to underflow
wire  count;          // count enable signal

// CRB bits 6:5 (INMODE) select the count source, and all four modes are
// distinct.  Only bit 6 was decoded, so 00 and 01 both meant PHI2 and 10 and 11
// both meant cascade -- the CNT modes did not exist.
//
// CNT is tied high here (see cia_timera.v), so mode 01 correctly counts
// nothing, and mode 11 -- cascade gated by CNT high -- collapses to plain
// cascade, exactly what mode 10 does and what this code did before.
(* ASYNC_REG = "TRUE" *) reg [2:0] cnt_sync = 3'b111;
always @(posedge clk)
  if (clk7_en) begin
    if (reset)
      cnt_sync <= 3'b111;
    else
      cnt_sync <= {cnt_sync[1:0], cnt};
  end

wire cnt_rise = cnt_sync[1] & ~cnt_sync[2];

// Timer B count signal source
`ifdef CIA_INMODE_MUTANT
// sim/cia_timer's teeth check: only CRB bit 6 decoded, as it was before.
assign count = tmcr[6] ? tmra_ovf : eclk;
`else
assign count = tmcr[6] ? (tmcr[5] ? (tmra_ovf & cnt_sync[1]) : tmra_ovf)
                       : (tmcr[5] ? cnt_rise                 : eclk);
`endif

// writing timer control register
always @(posedge clk)
  if (clk7_en) begin
    if (reset)  // synchronous reset
      tmcr[6:0] <= 7'd0;
    else if (tcr && wr)  // load control register, bit 4(strobe) is always 0
      tmcr[6:0] <= {data_in[6:5],1'b0,data_in[3:0]};
    else if (thi_load && oneshot)  // start timer if thi is written in one-shot mode
      tmcr[0] <= 1'd1;
    else if (underflow && oneshot) // stop timer in one-shot mode
      tmcr[0] <= 1'd0;
  end

always @(posedge clk)
  if (clk7_en) begin
    forceload <= tcr & wr & data_in[4];  // force load strobe
  end

assign oneshot = tmcr[3];          // oneshot alias
assign start = tmcr[0];          // start alias

// timer B latches for high and low byte
always @(posedge clk)
  if (clk7_en) begin
    if (reset)
      tmll[7:0] <= 8'b1111_1111;
    else if (tlo && wr)
      tmll[7:0] <= data_in[7:0];
  end

always @(posedge clk)
  if (clk7_en) begin
    if (reset)
      tmlh[7:0] <= 8'b1111_1111;
    else if (thi && wr)
      tmlh[7:0] <= data_in[7:0];
  end

// thi is written in one-shot mode so tmr must be reloaded
always @(posedge clk)
  if (clk7_en) begin
    thi_load <= thi & wr & (~start | oneshot);
  end

// Reload on an E-clock edge, not on the next 7 MHz tick -- see the same change
// in cia_timera.v for why (Risky Woods music and effects).  The one-shot START
// keeps the ungated thi_load.
// MiSTer 058288b4 (#198); findings/aga-chipset/mister-fixes.md 1.2.
reg thi_load_latched;
always @(posedge clk)
  if (clk7_en) begin
    if (reset)
      thi_load_latched <= 1'b0;
    else if (thi_load)
      thi_load_latched <= 1'b1;
    else if (eclk)
      thi_load_latched <= 1'b0;
  end

wire thi_load_eclk = thi_load_latched & eclk;

// timer counter reload signal
assign reload = thi_load_eclk | forceload | underflow;

// timer counter
always @(posedge clk)
  if (clk7_en) begin
    if (reset)
      tmr[15:0] <= 16'hFF_FF;
    else if (reload)
      tmr[15:0] <= {tmlh[7:0],tmll[7:0]};
    else if (start && count)
      tmr[15:0] <= tmr[15:0] - 16'd1;
  end

// timer counter equals zero
assign zero = ~|tmr;

// timer counter is going to underflow
assign underflow = zero & start & count;

// timer underflow interrupt request
assign irq = underflow;

// data output
assign data_out[7:0] = ({8{~wr&tlo}} & tmr[7:0])
          | ({8{~wr&thi}} & tmr[15:8])
          | ({8{~wr&tcr}} & {1'b0,tmcr[6:0]});


endmodule

