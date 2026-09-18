module cia_timera
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
  output  tmra_ovf,        // timer A underflow
  output  spmode,          // serial port mode
  output  irq            // intterupt out
);

reg    [15:0] tmr;        // timer
reg    [7:0] tmlh;        // timer latch high byte
reg    [7:0] tmll;        // timer latch low byte
reg    [6:0] tmcr;        // timer control register
reg    forceload;        // force load strobe
wire  oneshot;        // oneshot mode
wire  start;          // timer start (enable)
reg    thi_load;          // load tmr after writing thi in one-shot mode
wire  reload;          // reload timer counter
wire  zero;          // timer counter is zero
wire  underflow;        // timer is going to underflow
wire  count;          // count enable signal

// CRA bit 5 (INMODE) picks the count source: 0 = the E clock, 1 = a rising
// edge on the CNT pin.  The bit used to be stored and ignored, so a timer told
// to count CNT edges counted the 709 kHz E clock instead and a 16-bit one-shot
// underflowed within 92 ms where real hardware never underflows at all.
// MiSTer's case is Crystal Kingdom Dizzy [cr FLT], which writes CRA from a
// stale $FF -- INMODE=1 by accident -- and then hangs on a black screen.
//
// CNT is tied high in this design, as it is in MiSTer: CIA-A's CNT is KCLK and
// CIA-B's is a parallel-port handshake, and neither is modelled.  So selecting
// CNT now correctly counts nothing, which is the whole point.
(* ASYNC_REG = "TRUE" *) reg [2:0] cnt_sync = 3'b111;
always @(posedge clk)
  if (clk7_en) begin
    if (reset)
      cnt_sync <= 3'b111;
    else
      cnt_sync <= {cnt_sync[1:0], cnt};
  end

wire cnt_rise = cnt_sync[1] & ~cnt_sync[2];

// count enable signal
assign count = tmcr[5] ? cnt_rise : eclk;

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

assign oneshot = tmcr[3];    // oneshot alias
assign start = tmcr[0];      // start alias
assign spmode = tmcr[6];    // serial port mode (0-input, 1-output)

// timer A latches for high and low byte
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

// The reload has to land on an E-clock edge, not on the next 7 MHz tick.  The
// counter only decrements on E, so reloading between two E edges makes the
// first interval after the reload short by up to a whole E period -- which is
// heard rather than seen: Risky Woods gets its music tempo wrong and drops
// sound effects.  So the request is latched and held until E comes round.
// Note the one-shot START above still uses the UNGATED thi_load, as it does in
// MiSTer: this changes when the counter is reloaded, not when it is started.
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

// Timer A underflow signal for Timer B
assign tmra_ovf = underflow;

// timer underflow interrupt request
assign irq = underflow;

// data output
assign data_out[7:0] = ({8{~wr&tlo}} & tmr[7:0])
          | ({8{~wr&thi}} & tmr[15:8])
          | ({8{~wr&tcr}} & {1'b0,tmcr[6:0]});


endmodule

