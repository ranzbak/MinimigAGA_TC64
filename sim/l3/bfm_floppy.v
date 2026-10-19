// bfm_floppy: the Amiga side of paula_floppy in the L3 bench (scenario
// fdd_rd): the 68k through the CIAs (drive select, motor, side, step,
// direction) and Paula's registers, and Agnus's disk DMA channel.
//
// CIA side (ciab PRB as minimig.v wires it to paula_floppy): _sel[3:0],
// _motor, side, _step, direc; paula_floppy answers _track0 and _ready.  One
// CIA write is CIA_CLK7 = 10 clk7 cycles (an E-clock period, the shortest a
// 68k write to a CIA register takes).  `side` is the CIA's active-low
// _SIDE: paula_floppy's track byte is {cylinder, ~side}, so head h is
// side = ~h.  Idle (before go): _sel 1111, _motor 1, _step 1, direc 0,
// side 0, the values the bench tied these pins to before this model.
//
// Register side: a 68k write to a custom register is one clk7 cycle with
// cck low (minimig_m68k_bridge.v: the CPU's bus slot is the ~cck half of
// the colour clock), reg_address_in = the register, data_in = the value;
// idle reg_address_in = 8'hFF (Agnus's "no register", 0x1FE) and data_in
// 0.  `enable` is paula.v's dsken (DMACON DMAEN & DSKEN) and `wordsync`
// its adkcon[10] (ADKCON WORDSYNC): Paula registers outside paula_floppy,
// set here as trackdisk.device leaves them for a read (DMA on, WORDSYNC
// on).
//
// Agnus (rtl/minimig/agnus_diskdma.v, agnus.v): a beam counter h7 over the
// 227 colour clocks of a PAL line (454 clk7 cycles, hpos[8:1] = h7 >> 1,
// hpos[0] = cck = h7 bit 0).  The disk DMA engine's slots at normal floppy
// speed (floppy_speed 0, no turbo) are hpos[8:1] = 0x0C, 0x0E, 0x10 with
// hpos[0] = 1: three clk7 cycles per line.  In a slot with paula_floppy's
// dmal = 1, Agnus gives the bus to the disk channel (it has the highest
// priority): reg_address_in = DSKDATR for that clk7 cycle, and the word on
// data_out is what Agnus writes to chip RAM (collected here).  paula_floppy
// pops its FIFO at the end of that cycle (fifo_rd = busrd & dmaon).  Not
// modelled: the DMA pointer and chip RAM, the other DMA channels (disk DMA
// wins every slot it asks for), turbo / the refresh slots of
// floppy_speed 1, write DMA (dmas = 1 in a read slot is a bench error).
//
// Tasks (run by the sequencer below):
//   fdd_select(drive)      _sel = only that drive; _ready must be 0
//   fdd_motor(on)          as trackdisk: deselect, _motor = ~on, select again
//                          (paula_floppy latches the motor on _sel falling)
//   fdd_seek(cyl)          first a recalibration (step out, 4 ms apart, until
//                          _track0 = 0), then step pulses, 3 ms apart, and
//                          15 ms settle after the last step (trackdisk's
//                          defaults: step 3 ms, settle 15 ms, calibrate 4 ms);
//                          _track0 must be 0 exactly at cylinder 0
//   fdd_side(head)         side = ~head
//   fdd_dma_read(words, sync)  WORDSYNC and DMA on, DSKSYNC = sync, DSKLEN =
//                          0x4000 (DMA off), then DSKLEN = 0x8000 | words
//                          twice (paula_floppy starts on the second write in a
//                          row with bit 15 set), one DMA slot per dmal request
//                          until blckint; the words go to
//                          <+FDD_DUMP>_<cylinder>_<head>.hex (16 words per
//                          line, xxd -r -p reads it back)
//
// The bench (scenarios.vh) writes plan_n, plan (entry k in bits 8k+7..8k:
// bit 7 the head, bits 6..0 the cylinder), plan_words, plan_sync before it
// sets go; the sequencer selects drive 0, turns its motor on, and for each
// entry seeks, sets the side and reads; then done.  Read by the bench and
// mon_l3.vh: done, errors, slot (an Agnus disk slot this clk7 cycle),
// n_dma (track DMAs started), dma_busy (from the starting DSKLEN write to
// blckint), cur_cyl, cur_head.
`timescale 1ns/1ps

module bfm_floppy (
  input             clk28,
  input             clk7_en,
  input      [31:0] cyc,            // the bench's clk_114 cycle (log lines)
  // paula_floppy, CIA side
  output reg  [3:0] _sel,
  output reg        _motor,
  output reg        side,
  output reg        _step,
  output reg        direc,
  input             _track0,
  input             _ready,
  // paula_floppy, register bus and DMA side
  output      [8:1] reg_address_in,
  output reg [15:0] data_in,
  input      [15:0] data_out,
  input             dmal,
  input             dmas,
  input             blckint,
  output reg        enable,
  output reg        wordsync
);

  localparam [8:1] RGA_IDLE    = 8'hFF;      // 0x1FE: no register
  localparam [8:1] RGA_DSKDATR = 8'h04;      // 0x008
  localparam [8:1] RGA_DSKLEN  = 8'h12;      // 0x024
  localparam [8:1] RGA_DSKSYNC = 8'h3F;      // 0x07E
  localparam integer LINE_CLK7  = 454;       // 227 colour clocks
  localparam integer CIA_CLK7   = 10;        // one E-clock period
  // trackdisk.device's default delays at the PAL clk7 (7.09379 MHz)
  localparam integer STEP_CLK7  = 21281;     // 3 ms between steps
  localparam integer SETTLE_CLK7 = 106407;   // 15 ms after the last step
  localparam integer CALIB_CLK7 = 28375;     // 4 ms between recalibration steps
  localparam integer CAP_MAX    = 16384;

  initial begin
    _sel = 4'hF; _motor = 1'b1; side = 1'b0; _step = 1'b1; direc = 1'b0;
    data_in = 16'h0000; enable = 1'b0; wordsync = 1'b0;
  end

  // written by the bench
  reg               go = 1'b0;
  integer           plan_n = 0, plan_words = 0;
  reg      [127:0]  plan = 128'h0;
  reg       [15:0]  plan_sync = 16'h4489;
  // read by the bench
  reg               done = 1'b0;
  integer           errors = 0, n_dma = 0, cur_cyl = 0, cur_head = 0;
  reg               dma_busy = 1'b0;

  task fl_error(input [8*100-1:0] msg);
    begin
      $display("BENCH ERROR at cycle %0d: bfm_floppy: %0s", cyc, msg);
      errors = errors + 1;
    end
  endtask

  // ------------------------------------------------------------- Agnus
  reg [8:0] h7 = 9'd0;
  always @(posedge clk28) if (clk7_en) h7 <= (h7 == LINE_CLK7[8:0] - 9'd1) ? 9'd0 : h7 + 9'd1;
  wire   [7:0] cck_n = h7[8:1];
  wire         slot = h7[0] && (cck_n == 8'h0C || cck_n == 8'h0E || cck_n == 8'h10);
  wire         dma = slot && dmal === 1'b1;
  reg    [8:1] rga_cpu = RGA_IDLE;
  assign reg_address_in = dma ? RGA_DSKDATR : rga_cpu;

  // the words Agnus moves, read in the middle of the clk_28 cycle before the
  // clk7 edge that ends the slot (data_out is stable there); blckint the
  // same way
  reg [15:0] cap [0:CAP_MAX-1];
  reg        cap_on = 1'b0, blk_seen = 1'b0;
  integer    cap_n = 0;
  always @(negedge clk28) if (clk7_en === 1'b1) begin
    if (dma) begin
      if (dmas === 1'b1) fl_error("dmas = 1 in a read DMA slot");
      if (cap_on && cap_n < CAP_MAX) begin
        cap[cap_n] = data_out;
        cap_n = cap_n + 1;
      end else
        fl_error("a disk DMA slot taken outside fdd_dma_read");
    end
    if (blckint === 1'b1 && cap_on) blk_seen = 1'b1;
  end

  // ------------------------------------------------------------- timing
  // returns 1 ns after the next clk_28 edge that paula_floppy samples
  // (clk7_en), with h7 the clk7 cycle that starts there
  task clk7;
    begin
      @(posedge clk28);
      while (clk7_en !== 1'b1) @(posedge clk28);
      #1;
    end
  endtask

  task wait_clk7(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) clk7;
    end
  endtask

  // one 68k write to a custom register: a clk7 cycle with cck low
  task cpu_write(input [8:1] a, input [15:0] d);
    begin
      clk7;
      while (h7[0] != 1'b0) clk7;
      rga_cpu = a;
      data_in = d;
      clk7;
      rga_cpu = RGA_IDLE;
      data_in = 16'h0000;
    end
  endtask

  // ------------------------------------------------------------- tasks
  reg [3:0] sel_mask = 4'hF;
  reg       calibrated = 1'b0;

  task fdd_select(input integer drive);
    begin
      sel_mask = ~(4'b0001 << drive);
      _sel = sel_mask;
      wait_clk7(CIA_CLK7);
      if (_ready !== 1'b0) fl_error("_ready is not 0 with the drive selected");
      $display("=== FDD select drive %0d at cycle %0d", drive, cyc);
    end
  endtask

  task fdd_motor(input on);
    begin
      _sel = 4'hF;
      wait_clk7(CIA_CLK7);
      _motor = ~on;
      wait_clk7(CIA_CLK7);
      _sel = sel_mask;
      wait_clk7(CIA_CLK7);
      $display("=== FDD motor %0s at cycle %0d", on ? "on" : "off", cyc);
    end
  endtask

  // one step pulse: direc, _step low, _step high (paula_floppy steps on the
  // rising edge); out = 1 towards cylinder 0
  task step_pulse(input out);
    begin
      direc = out;
      wait_clk7(CIA_CLK7);
      _step = 1'b0;
      wait_clk7(CIA_CLK7);
      _step = 1'b1;
      wait_clk7(CIA_CLK7);
    end
  endtask

  task fdd_seek(input integer cyl);
    integer k, from;
    begin
      from = cur_cyl;
      if (!calibrated) begin
        k = 0;
        while (_track0 !== 1'b0 && k < 90) begin
          if (k > 0) wait_clk7(CALIB_CLK7);
          step_pulse(1'b1);
          k = k + 1;
        end
        if (_track0 !== 1'b0) fl_error("recalibration: no _track0 after 90 steps out");
        if (k > 0) wait_clk7(SETTLE_CLK7);
        $display("=== FDD recalibrated: %0d steps out to _track0 at cycle %0d", k, cyc);
        cur_cyl = 0;
        from = 0;
        calibrated = 1'b1;
      end
      k = 0;
      while (cur_cyl != cyl) begin
        if (k > 0) wait_clk7(STEP_CLK7);
        step_pulse(cyl < cur_cyl);
        cur_cyl = (cyl < cur_cyl) ? cur_cyl - 1 : cur_cyl + 1;
        k = k + 1;
      end
      if (k > 0) wait_clk7(SETTLE_CLK7);
      if ((_track0 === 1'b0) != (cur_cyl == 0)) fl_error("_track0 does not match the cylinder after the seek");
      $display("=== FDD seek cylinder %0d from %0d: %0d steps, done at cycle %0d", cyl, from, k, cyc);
    end
  endtask

  task fdd_side(input integer head);
    begin
      side = (head == 0);
      cur_head = head;
      wait_clk7(CIA_CLK7);
    end
  endtask

  reg [8*1024-1:0] prefix, fname;
  task fdd_dma_read(input integer words, input [15:0] sync);
    integer fd, i, t0;
    begin
      if (words < 1 || words > 16'h3FFF || words > CAP_MAX) fl_error("fdd_dma_read: words out of range");
      wordsync = 1'b1;
      enable = 1'b1;
      cpu_write(RGA_DSKSYNC, sync);
      cpu_write(RGA_DSKLEN, 16'h4000);
      cap_n = 0;
      blk_seen = 1'b0;
      cap_on = 1'b1;
      cpu_write(RGA_DSKLEN, 16'h8000 | words[15:0]);
      dma_busy = 1'b1;
      n_dma = n_dma + 1;
      t0 = cyc;
      $display("=== FDD dma %0d cylinder %0d head %0d: %0d words, sync %h, from cycle %0d",
               n_dma, cur_cyl, cur_head, words, sync, t0);
      cpu_write(RGA_DSKLEN, 16'h8000 | words[15:0]);
      wait (blk_seen === 1'b1);
      cap_on = 1'b0;
      dma_busy = 1'b0;
      if (cap_n != words) fl_error("the DMA moved another number of words than DSKLEN");
      $sformat(fname, "%0s_%0d_%0d.hex", prefix, cur_cyl, cur_head);
      fd = $fopen(fname, "w");
      if (fd == 0) fl_error("cannot open the dump file (+FDD_DUMP)");
      else begin
        for (i = 0; i < cap_n; i = i + 1) begin
          $fwrite(fd, "%h", cap[i]);
          if (i % 16 == 15 || i == cap_n - 1) $fwrite(fd, "\n");
        end
        $fclose(fd);
      end
      $display("=== FDD dma %0d cylinder %0d head %0d: %0d words to blckint at cycle %0d (%0d cycles), %0s",
               n_dma, cur_cyl, cur_head, cap_n, cyc, cyc - t0, fname);
    end
  endtask

  // ------------------------------------------------------------- sequencer
  integer pk = 0;
  initial begin
    if (!$value$plusargs("FDD_DUMP=%s", prefix)) prefix = "fdd_rd";
    wait (go === 1'b1);
    $display("=== FDD start: %0d track reads of %0d words, sync %h, at cycle %0d", plan_n, plan_words, plan_sync, cyc);
    if (plan_n < 1 || plan_n > 16) fl_error("plan_n: 1 to 16 tracks");
    fdd_select(0);
    fdd_motor(1'b1);
    for (pk = 0; pk < plan_n && pk < 16; pk = pk + 1) begin
      fdd_seek({25'd0, plan[8 * pk +: 7]});
      fdd_side({31'd0, plan[8 * pk + 7]});
      fdd_dma_read(plan_words, plan_sync);
    end
    $display("=== FDD done: %0d track reads at cycle %0d", n_dma, cyc);
    done = 1'b1;
  end

endmodule
