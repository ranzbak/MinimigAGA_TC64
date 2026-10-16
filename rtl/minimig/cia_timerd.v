// timer D
//----------------------------------------------------------------------------------
//----------------------------------------------------------------------------------


module cia_timerd
(
  input   clk,            // clock
  input clk7_en,
  input  wr,            // write enable
  input   reset,           // reset
  input   tlo,          // timer low byte select
  input   tme,          // timer mid byte select
  input  thi,           // timer high byte select
  input  tcr,          // timer control register
  input   [7:0] data_in,      // bus data in
  output   reg [7:0] data_out,    // bus data out
  input  count,            // count enable
  output  irq            // intterupt out
);

  reg    latch_ena;        // timer d output latch enable
  reg   count_ena;        // timer d count enable
  reg    crb7;          // bit 7 of control register B
  reg    [23:0] tod;        // timer d
  reg    [23:0] alarm;      // alarm
  reg    [23:0] tod_latch;    // timer d latch
  reg    count_del;        // delayed count signal for interrupt requesting

// timer D output latch control
//
// Reading TODHI freezes all three bytes until the TODLO read is OVER: the LO
// read itself still returns the frozen byte.  Releasing at the start of the
// LO read let the rest of that read follow the live count, so a tick inside a
// LO read stretched by the bus returned the new low byte under the old high
// ones -- $0001FF read as $000100 (sim/cia_tod test 5).
reg tlo_rd_d; // TODLO read in the previous clk7 cycle
always @(posedge clk)
  if (clk7_en)
    tlo_rd_d <= tlo & ~wr;

`ifdef CIA_TOD_LATCH_MUTANT
wire lo_rd_end = 1'b0;
`else
wire lo_rd_end = tlo_rd_d & ~(tlo & ~wr); // the TODLO read has just ended
`endif

always @(posedge clk)
  if (clk7_en) begin
    if (reset)
      latch_ena <= 1'd1;
`ifdef CIA_TOD_LATCH_MUTANT
    else if (!wr)
    begin
      if (thi && !crb7) // if MSB read and ALARM is not selected, hold data for subsequent reads
        latch_ena <= 1'd0;
      else if (tlo) // if LSB read, update data every clock
        latch_ena <= 1'd1;
    end
`else
    else if (thi && !wr && !crb7) // MSB read, ALARM not selected: hold data for subsequent reads
      latch_ena <= 1'd0;
    else if (lo_rd_end) // LSB read just ended: follow the count again
      latch_ena <= 1'd1;
`endif
  end

// (also on the release itself, so a TODHI read that began right then latches
// the current count rather than keeping the old one)
always @(posedge clk)
  if (clk7_en) begin
    if (latch_ena || lo_rd_end)
      tod_latch[23:0] <= tod[23:0];
  end

// timer D and crb7 read
always @(*)
  if (!wr)
  begin
    if (thi) // high byte of timer D
      data_out[7:0] = tod_latch[23:16];
    else if (tme) // medium byte of timer D (latched)
      data_out[7:0] = tod_latch[15:8];
    else if (tlo) // low byte of timer D (latched)
      data_out[7:0] = tod_latch[7:0];
    else if (tcr) // bit 7 of crb
      data_out[7:0] = {crb7,7'b000_0000};
    else
      data_out[7:0] = 8'd0;
  end
  else
    data_out[7:0] = 8'd0;

// timer D count enable control
always @(posedge clk)
  if (clk7_en) begin
    if (reset)
      count_ena <= 1'd0; // AMR - experimental fix for 3.1.4 TODA_SAFE problem - on reset disable counting until first access.
    else if (wr) // AMR && !crb7) // crb7==0 enables writing to TOD counter
    begin
      if (thi && !crb7 /* || tme*/) // stop counting
        count_ena <= 1'd0;
      else if (tlo || (tcr && !data_in[7])) // write to LSB [or CR with bit 7=0 -- AMR] starts counting again
        count_ena <= 1'd1;
    end
  end

// timer D counter
always @(posedge clk)
  if (clk7_en) begin
    if (reset) // synchronous reset
    begin
      tod[23:0] <= 24'd0;
    end
`ifdef CIA_TOD_WRGATE_MUTANT
    else if (wr && !crb7) // crb7==0 enables writing to TOD counter
`else
    // Only a write to a TOD register may take the place of a count.  `wr` is
    // the CPU's write strobe for ANY address (minimig.v: cpu_lwr|cpu_hwr);
    // testing it alone dropped every count that met a CPU write anywhere --
    // under a chip RAM write load three VSYNCs in four (IrqLat, the Cure
    // meter; sim/cia_tod test 3).
    else if (wr && !crb7 && (tlo || tme || thi)) // crb7==0 enables writing to TOD counter
`endif
    begin
      if (tlo)
        tod[7:0] <= data_in[7:0];
      if (tme)
        tod[15:8] <= data_in[7:0];
      if (thi)
        tod[23:16] <= data_in[7:0];
    end
    else if (count_ena && count)
      tod[23:0] <= tod[23:0] + 24'd1;
  end

// alarm write
always @(posedge clk)
  if (clk7_en) begin
    if (reset) // synchronous reset
    begin
      alarm[7:0] <= 8'b1111_1111;
      alarm[15:8] <= 8'b1111_1111;
      alarm[23:16] <= 8'b1111_1111;
    end
    else if (wr && crb7) // crb7==1 enables writing to ALARM
    begin
      if (tlo)
        alarm[7:0] <= data_in[7:0];
      if (tme)
        alarm[15:8] <= data_in[7:0];
      if (thi)
        alarm[23:16] <= data_in[7:0];
    end
  end

// crb7 write
always @(posedge clk)
  if (clk7_en) begin
    if (reset)
      crb7 <= 1'd0;
    else if (wr && tcr)
      crb7 <= data_in[7];
  end

// delayed count enable signal
always @(posedge clk)
  if (clk7_en) begin
    count_del <= count & count_ena;
  end

// alarm interrupt request
assign irq = (tod[23:0]==alarm[23:0] && count_del) ? 1'b1 : 1'b0;


endmodule

