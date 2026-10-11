// The CIA time-of-day counter (timer D) against the MOS 8520, and where in
// the beam frame CIA-A's TOD ticks.
//
// Two board tools read the TOD and got numbers that cannot be true under chip
// load: IrqLat's "expected" copper count (frames from CIA-A's TOD) said 264
// for 1001 taken, and the Cure meter's frame durations (TOD frames * 313 +
// line) came out a little under 256 frames, i.e. slightly negative.  Either the
// TOD or the tools are wrong; this bench asks the TOD directly.
//
// What a real 8520 does (MOS 8520 data sheet; WinUAE cia.cpp, the read and
// write cases for registers 8-10, and custom.cpp hsync_handler_post):
//   - TOD is a 24-bit binary counter, counting rising edges of the TOD pin.
//     CIA-A's pin is VSYNC on the A500/A1200 (WinUAE ciaatod=vblank), and the
//     count goes up when the VSYNC pulse ENDS: PAL line 5 (custom.cpp
//     "CIA-A TOD counter increases when vsync pulse ends", VSYNC_ENDLINE_PAL
//     = 5 in include/custom.h).  CIA-B's pin is HSYNC, counted at hsync end.
//   - Reading TODHI latches all three bytes (unless already latched, and not
//     while CRB bit 7 ALARM is set); reads of MID and LO return the latch;
//     the LO read releases it.  LO read while not latched reads live.
//   - Writing TODHI (ALARM=0) stops the counter, writing TODLO starts it.
//     With ALARM=1 the writes go to the alarm register and the counter keeps
//     running.  The alarm sets ICR bit 2 when the count reaches it.
//   - After reset the TOD is stopped until TODLO is written (WinUAE clears
//     todon on reset).
//
// And the one thing the RTL must never do: lose a count because the CPU was
// doing something else at the time.  The CIA's `wr` input is the CPU's write
// strobe for ANY address (minimig.v: .wr(cpu_lwr|cpu_hwr)); only the register
// selects are gated by the CIA's address enable.
//
// Mutants (run.sh): CIA_TOD_WRGATE_MUTANT puts back the old counter, where any
// CPU write anywhere blocked the count in that 7 MHz cycle; CIA_TOD_LATCH_MUTANT
// puts back the old latch release at the START of the TODLO read.  The bench
// must fail on each.
//
// iverilog.  Run: ./run.sh

`timescale 1ns/1ps

module cia_tod_tb;

  // The modules only act on clk7_en, so the bench runs clk at 7 MHz with the
  // enable always up: same behaviour, eight times fewer events (a PAL frame
  // is 142,000 ticks and test 9 watches four).
  reg clk = 0;
  always #70.5 clk = ~clk;
  wire clk7_en = 1'b1;

  // cck: high on every other clk7 tick, as the beam counter expects
  reg cck = 0;
  always @(posedge clk) if (clk7_en) cck <= ~cck;

  reg        reset = 1;

  // ---------------------------------------------------------------- CIA bus
  reg        aen = 0, rd = 0, wr = 0;
  reg  [3:0] rs = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire       irq;
  reg        tick_unit = 1;         // the TOD pin in the unit tests
  reg        use_beam = 0;          // 1: the pin is the beam counter's _vsync
  wire       _vsync, _hsync;
  wire       tick = use_beam ? _vsync : tick_unit;

  ciaa cia (
    .clk(clk), .clk7_en(clk7_en), .clk7n_en(1'b0),
    .aen(aen), .rd(rd), .wr(wr), .reset(reset),
    .rs(rs), .data_in(din), .data_out(dout),
    .tick(tick), .eclk(1'b0), .cnt_in(1'b1),
    .irq(irq),
    .porta_in(6'h3f), .porta_out(), .portb_in(8'hff),
    .key_strobe(1'b0), .key_data(8'h00), .keyack()
  );

  // CIA-B on the beam counter's _hsync, for the line count
  reg        baen = 0;
  wire [7:0] bdout;
  ciab ciab_i (
    .clk(clk), .clk7_en(clk7_en),
    .aen(baen), .rd(rd), .wr(wr), .reset(reset),
    .rs(rs), .data_in(din), .data_out(bdout),
    .tick(_hsync), .eclk(1'b0), .cnt_in(1'b1),
    .irq(), .flag(1'b0),
    .porta_in(6'h3f), .porta_out(), .portb_out()
  );

  // ---------------------------------------------------------------- Agnus beam counter
  reg  [8:1] reg_address = 8'hff;   // $1FE, a register the counter ignores
  reg  [15:0] beam_din = 16'h0000;
  wire [15:0] beam_out;
  wire [8:0]  hpos;
  wire [10:0] vpos;
  agnus_beamcounter beam (
    .clk(clk), .clk7_en(clk7_en), .reset(reset), .cck(cck),
    .ntsc(1'b0), .aga(1'b1), .ecs(1'b1), .a1k(1'b0),
    .data_in(beam_din), .data_out(beam_out), .reg_address_in(reg_address),
    .hpos(hpos), .vpos(vpos), ._hsync(_hsync), .hsyncpol(), ._vsync(_vsync),
    .vsyncpol(), ._csync(), .blank(), .vbl(), .vblend(), .eol(), .eof(),
    .vbl_int(), .htotal_out(), .harddis_out(), .varbeamen_out(), .rtg_ena(),
    .hblank_out()
  );

  integer errors = 0;

  task t7(input integer n);         // n clk7 ticks
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) begin
        @(posedge clk);
        while (!clk7_en) @(posedge clk);
      end
    end
  endtask

  // Set the bus on the edge AFTER a clk7 tick so it is stable at the next one.
  task bus_settle;
    begin
      @(posedge clk);
      while (!clk7_en) @(posedge clk);
      #1;
    end
  endtask

  // One CIA-A write: select + wr for one clk7 tick
  task cwr(input [3:0] r, input [7:0] v);
    begin
      bus_settle;
      aen = 1; wr = 1; rs = r; din = v;
      t7(1); #1;
      aen = 0; wr = 0;
      t7(1); #1;
    end
  endtask

  // One CIA-A read with the strobe held for len clk7 ticks.  The value is
  // taken at the last tick, where the bridge's data latch would close.
  task crd(input [3:0] r, input integer len, output [7:0] v);
    begin
      bus_settle;
      aen = 1; rd = 1; rs = r;
      if (len > 1) t7(len - 1);
      #1 v = dout;
      t7(1); #1;
      aen = 0; rd = 0;
      t7(1); #1;
    end
  endtask

  // CIA-B read (for the hsync count)
  task brd(input [3:0] r, output [7:0] v);
    begin
      bus_settle;
      baen = 1; rd = 1; rs = r;
      #1 v = bdout;
      t7(1); #1;
      baen = 0; rd = 0;
      t7(1); #1;
    end
  endtask

  // CIA-B write
  task bwr(input [3:0] r, input [7:0] v);
    begin
      bus_settle;
      baen = 1; wr = 1; rs = r; din = v;
      t7(1); #1;
      baen = 0; wr = 0;
      t7(1); #1;
    end
  endtask

  // The TOD pin: low for 3 ticks, then the rising edge (the counting edge)
  task pulse;
    begin
      bus_settle;
      tick_unit = 0; t7(3); #1;
      tick_unit = 1; t7(3); #1;
    end
  endtask

  reg [7:0] hi, me, lo;
  reg [23:0] tod;
  task rd_tod(output [23:0] v);     // HI, MID, LO as the tools do it
    begin
      crd(4'hA, 1, hi); crd(4'h9, 1, me); crd(4'h8, 1, lo);
      v = {hi, me, lo};
    end
  endtask

  task set_tod(input [23:0] v);     // HI (stops), MID, LO (starts)
    begin
      cwr(4'hA, v[23:16]); cwr(4'h9, v[15:8]); cwr(4'h8, v[7:0]);
    end
  endtask

  task check(input [8*48-1:0] what, input [23:0] got, input [23:0] want);
    begin
      if (got === want)
        $display("  ok   %0s: %06h", what, got);
      else begin
        $display("FAIL   %0s: got %06h want %06h", what, got, want);
        errors = errors + 1;
      end
    end
  endtask

  integer i, n, lost, line_at, h_at, lines_seen, ticks;
  reg [7:0] v8;
  reg [23:0] t0, t1;
  reg [15:0] vh, vh_prev;

  initial begin
    reset = 1; t7(4); #1; reset = 0; t7(2);
    // The beam counters have no reset (the OS's first VPOSW/VHPOSW is not
    // needed on hardware, X is a simulation artefact): set them to line 0,
    // long frame, as Kickstart leaves a PAL machine.
    #1 reg_address = 8'h15; beam_din = 16'h8000; t7(1);   // VPOSW: LOF, V8=0
    #1 reg_address = 8'h16; beam_din = 16'h0000; t7(1);   // VHPOSW: V=0, H=0
    #1 reg_address = 8'hff; t7(1);

    // ------------------------------------------------------------------
    $display("--- 1. after reset the TOD is stopped until TODLO is written");
    pulse; pulse;
    rd_tod(tod); check("two pulses after reset, no LO write", tod, 24'h000000);
    set_tod(24'h000000);
    pulse; pulse; pulse;
    rd_tod(tod); check("three pulses after HI/MID/LO write", tod, 24'h000003);

    // ------------------------------------------------------------------
    $display("--- 2. it counts the RISING edge of the pin (end of the sync pulse)");
    bus_settle; tick_unit = 0; t7(3); #1;
    rd_tod(tod); check("after the falling edge", tod, 24'h000003);
    tick_unit = 1; t7(3); #1;
    rd_tod(tod); check("after the rising edge", tod, 24'h000004);

    // ------------------------------------------------------------------
    $display("--- 3. a CPU write ELSEWHERE across the counting edge must not cost a count");
    // a chip RAM write: wr up, CIA-A not selected
    bus_settle; tick_unit = 0; t7(2); #1;
    wr = 1; t7(1); #1;
    tick_unit = 1; t7(3); #1;       // the edge is counted while wr is up
    wr = 0; t7(2); #1;
    rd_tod(tod); check("edge during a chip RAM write", tod, 24'h000005);
    // a CIA-B write (CIA-B selected, CIA-A not)
    bus_settle; tick_unit = 0; t7(2); #1;
    baen = 1; wr = 1; rs = 4'hE; din = 8'h00; t7(1); #1;
    tick_unit = 1; t7(3); #1;
    baen = 0; wr = 0; t7(2); #1;
    rd_tod(tod); check("edge during a CIA-B CRA write", tod, 24'h000006);
    // CIA-A PRA write (CIA-A selected, another register)
    bus_settle; tick_unit = 0; t7(2); #1;
    aen = 1; wr = 1; rs = 4'h0; din = 8'h03; t7(1); #1;
    tick_unit = 1; t7(3); #1;
    aen = 0; wr = 0; t7(2); #1;
    rd_tod(tod); check("edge during a CIA-A PRA write", tod, 24'h000007);
    // 200 edges under a busy write pattern (wr up 3 ticks in 4, like a CPU
    // streaming to chip RAM): every edge must count
    rd_tod(t0);
    for (i = 0; i < 200; i = i + 1) begin
      bus_settle;
      tick_unit = 0;
      wr = 1; t7(1 + i % 3); #1;
      tick_unit = 1; t7(1); #1;
      wr = 0; t7(1); #1;
      wr = 1; t7(2); #1;
      wr = 0; t7(1); #1;
    end
    rd_tod(t1);
    check("200 edges under a 75% write load", t1 - t0, 24'd200);

    // ------------------------------------------------------------------
    $display("--- 4. TODHI read latches until TODLO is read; LO alone reads live");
    set_tod(24'h0012FE);
    crd(4'hA, 1, hi);
    pulse; pulse; pulse;
    crd(4'h9, 1, me); crd(4'h8, 1, lo);
    check("HI, 3 pulses, MID, LO", {hi, me, lo}, 24'h0012FE);
    crd(4'h8, 1, lo);
    check("LO again (released: live)", {16'h0, lo}, 24'h000001);
    crd(4'h9, 1, me);
    check("MID unlatched (live)", {16'h0, me}, 24'h000013);
    // a second HI read while latched must not re-latch
    crd(4'hA, 1, hi); pulse; crd(4'hA, 1, hi); crd(4'h9, 1, me); crd(4'h8, 1, lo);
    check("HI, pulse, HI, MID, LO (first latch holds)", {hi, me, lo}, 24'h001301);

    // ------------------------------------------------------------------
    $display("--- 5. a tick DURING a long TODLO read must not tear the latched value");
    // HI latches 0001FF; the LO read's strobe is stretched (a CIA cycle the
    // bus holds open) and the counter carries to 000200 in the middle of it.
    set_tod(24'h0001FF);
    crd(4'hA, 1, hi); crd(4'h9, 1, me);
    bus_settle;
    aen = 1; rd = 1; rs = 4'h8;
    t7(2); #1;
    tick_unit = 0; t7(2); #1; tick_unit = 1; t7(4); #1;   // the carry, mid-read
    lo = dout;
    t7(1); #1; aen = 0; rd = 0; t7(2); #1;
    check("HI, MID, long LO with a carry inside", {hi, me, lo}, 24'h0001FF);
    rd_tod(tod); check("next HI/MID/LO", tod, 24'h000200);

    // ------------------------------------------------------------------
    $display("--- 6. TODHI write stops the count, TODLO write starts it");
    cwr(4'hA, 8'h00);
    pulse; pulse;
    cwr(4'h9, 8'h10);
    pulse;
    cwr(4'h8, 8'h20);
    rd_tod(tod); check("stopped across HI..LO writes", tod, 24'h001020);
    pulse;
    rd_tod(tod); check("running again", tod, 24'h001021);

    // ------------------------------------------------------------------
    $display("--- 7. ALARM: CRB7=1 writes go to the alarm, TOD runs on, ICR bit 2");
    cwr(4'hF, 8'h80);                       // CRB: ALARM
    cwr(4'hA, 8'h00); cwr(4'h9, 8'h10); cwr(4'h8, 8'h23);
    pulse;
    cwr(4'hF, 8'h00);
    rd_tod(tod); check("TOD not stopped/overwritten by alarm writes", tod, 24'h001022);
    crd(4'hD, 1, v8);                       // clear the ICR
    cwr(4'hD, 8'h84);                       // enable the alarm interrupt
    if (irq) begin $display("FAIL   irq before the alarm"); errors = errors + 1; end
    pulse;
    if (!irq) begin $display("FAIL   no irq at TOD == alarm"); errors = errors + 1; end
    crd(4'hD, 1, v8);
    check("ICR at the alarm", {16'h0, v8}, 24'h000084);
    crd(4'hD, 1, v8);
    check("ICR read again (cleared)", {16'h0, v8}, 24'h000000);
    cwr(4'hD, 8'h04);

    // ------------------------------------------------------------------
    $display("--- 8. TODHI read with ALARM set does not latch (WinUAE: A1200 confirmed)");
    cwr(4'hF, 8'h80);
    crd(4'hA, 1, hi); pulse; crd(4'h8, 1, lo);
    cwr(4'hF, 8'h00);
    check("LO after HI (ALARM set) and a pulse", {16'h0, lo}, 24'h000024);

    // ------------------------------------------------------------------
    $display("--- 9. where in the frame CIA-A's TOD ticks (Agnus beam counter, PAL)");
    use_beam = 1;
    cwr(4'h8, 8'h00);                       // make sure it runs
    bwr(4'h8, 8'h00);                       // CIA-B's TOD: stopped since reset
    // run to line 100, then watch three increments (two whole frames between
    // the first and the last); CIA-B's TOD (HSYNC) over the same two frames
    wait (vpos == 11'd100);
    for (n = 0; n < 3; n = n + 1) begin
      t0 = cia.tmrd.tod;
      @(cia.tmrd.tod);
      $display("  TOD %06h -> %06h at vpos %0d, hpos %0d (colour clock %0d)",
               t0, cia.tmrd.tod, vpos, hpos, hpos >> 1);
      line_at = vpos;
      if (n == 0) begin brd(4'hA, hi); brd(4'h9, me); brd(4'h8, lo); t1 = {hi, me, lo}; end
    end
    brd(4'hA, hi); brd(4'h9, me); brd(4'h8, lo);
    if (line_at >= 16) begin
      $display("FAIL   TOD ticks at line %0d, not in the vertical blank before line 16", line_at);
      errors = errors + 1;
    end else
      $display("  ok   CIA-A TOD ticks once a frame at line %0d (8520 on VSYNC: end of the sync pulse; WinUAE: line 5)", line_at);
    check("CIA-B TOD (HSYNC) over two frames", {hi, me, lo} - t1, 24'd626);

    // ------------------------------------------------------------------
    $display("--- 10. VHPOSR at the line wrap: H=0,1 still carry the previous line's V");
    reg_address = 8'h03;                    // VHPOSR ($006)
    wait (vpos == 11'd51);
    wait (beam_out[7:0] == 8'hE0);
    t7(1);
    vh_prev = beam_out;
    for (i = 0; i < 16; i = i + 1) begin
      t7(1);
      if (beam_out != vh_prev) begin
        $display("  VHPOSR %04h  (V %0d H %02h)", beam_out, beam_out[15:8], beam_out[7:0]);
        vh_prev = beam_out;
      end
    end
    reg_address = 8'hff;

    if (errors == 0) $display("=== PASS");
    else $display("=== FAIL (%0d)", errors);
    $finish;
  end

endmodule
