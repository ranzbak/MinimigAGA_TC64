// SDRAM chip-RAM coherency testbench
//
// Answers one question that NOTHING else in this project simulates: with the
// CPU and the chipset both hitting chip RAM through the REAL rtl/sdram/
// sdram_ctrl.v -- and so through its cpu_cache_new, its line buffer, its write
// buffer and its slot arbiter -- does either master ever read a value the
// other master did not write?
//
// Why it exists.  Turbo chip RAM puts chip RAM in SDRAM, where the CPU reaches
// it through cpu_cache_new and the chipset reaches it directly through slot 1.
// sim/ddr3_cpu drives ddr3_fastram with a behavioural stand-in for this
// controller and has no chipset master; sim/sdram_timing drives the real
// controller but only for read-path timing, one master at a time.  The region
// every hardware control points at -- see
// findings/ap68040/sdd-d3/d3-snoop-coherency.md -- is exactly the region
// neither of them covers.
//
// PORT OWNERSHIP.  Exactly one process drives each port, because two Verilog
// processes assigning the same reg is a race that looks like a DUT bug:
//
//   chip_seq   owns chipAddr/chipWR/chipRW/chip_dma/chipL/chipU
//   cpu_seq    owns cpuAddr/cpustate/cpuWR/cpuL/cpuU
//   main       owns neither: it asks the two sequencers through the small
//              request/done mailboxes below, and does the checking
//
// Each sequencer serves a request when it has one and otherwise generates
// background traffic, so the controller stays loaded the way a demo loads it.
//
// THE SEQUENCE.  Per round, two directions, each with an unambiguous expected
// value because the write is complete before the read is asked for:
//
//   C2P   chipset writes A, then the CPU must read the new value
//   P2C   CPU writes B, then the chipset must read the new value
//
// The four address windows are disjoint, so a failure is a coherency failure
// and never a scoreboard race.
//
// Corner: use FAST.  At the slow corner the read path itself is one word late
// (findings/constraints/sdram-sim-results.md) and every chipset read would
// fail for a reason that has nothing to do with coherency.
//
// Usage: ./run.sh [fast|slow] [sg6|sg7] [+rounds=N] [+nobg]
//
//   +nobg   background agents off.  VALIDATES THE BENCH: with no contention
//           both directions must pass.  If they do not, the bench's own
//           protocol is wrong and nothing it says about contention means
//           anything.  Run this first, always.

`timescale 1ps / 1ps
`define SOC_SIM

module sdram_coherency_tb;

`ifdef FAST
  localparam integer DLY_CLK_PIN = 6999;
  localparam integer T_CO        = 200;
  localparam integer T_IN        = 493;
  localparam         CORNER      = "FAST";
`else
  localparam integer DLY_CLK_PIN = 1410;
  localparam integer T_CO        = 840;
  localparam integer T_IN        = 1512;
  localparam         CORNER      = "SLOW";
`endif

// ---------------------------------------------------------------- clocks
reg clk = 1'b0;
always begin #4407 clk = 1'b1; #4408 clk = 1'b0; end

reg pin_clk = 1'b0;
always @(clk) pin_clk <= #DLY_CLK_PIN clk;

localparam integer T_RDCLK = 551;          // fix-12 read capture clock
reg rdclk = 1'b0;
always @(clk) rdclk <= #T_RDCLK clk;

reg [3:0] c16 = 4'd0;
always @(posedge clk) c16 <= c16 + 4'd1;
wire clk7_en = (c16 < 4'd4);

// ---------------------------------------------------------------- DUT wires
reg          reset_in = 1'b0;
wire [12:0]  sdaddr;
wire [3:0]   sd_cs;
wire [1:0]   ba;
wire         sd_we, sd_ras, sd_cas;
wire [1:0]   dqm;
wire [15:0]  sdata_fpga;
wire         reset_out;

reg  [23:1]  chipAddr = 23'd0;
reg          chipL = 1'b1, chipU = 1'b1, chipL2 = 1'b1, chipU2 = 1'b1;
reg          chipRW = 1'b1, chip_dma = 1'b1;
reg  [15:0]  chipWR = 16'd0, chipWR2 = 16'd0;
wire [15:0]  chipRD;
wire [47:0]  chip48;

reg  [25:1]  cpuAddr  = 25'd0;
reg  [6:0]   cpustate = 7'b0000100;   // bit6 longword, bit2 = cpuCSn (1 = idle), [1:0] = state
reg  [15:0]  cpuWR    = 16'd0;
reg          cpuL = 1'b0, cpuU = 1'b0;
wire [15:0]  cpuRD;
wire         cpuena;

// FIX SELECTION.  Both default off, so the DUT is what HEAD builds unless a
// switch is given: +wrsync drives cpu_wr_sync for the whole (chip RAM) window,
// -DCL_SNOOP compiles in the line-buffer snoop invalidate.
reg wrsync = 1'b0;
// CACHE-INHIBIT AND CACHELINE-CLR, previously tied to zero here -- which meant
// the KICKSTART TURBO path was never simulated at all.
//
// On hardware `cache_inhibit <= sel_kickram` (rtl/soc/TG68K.vhd), and inside
// cpu_cache_new that signal kills cpu_cacheline_valid and drives the
// ci_inv_pend machinery -- a cache-inhibited HIT owes a row invalidate, and
// ci_inv_pend shares port B with store_inv_lost.  That is the same port-B
// contention upstream's a8a50ce is about, so leaving it at zero left the most
// interesting corner of this module untested.
//
// `cacheline_clr <= turbochipram XOR turbochip_d` pulses whenever Turbo chip
// RAM is toggled in the OSD -- which happened in every one of the hardware
// tests that corrupted -- and forces cpu_cacheline_dirty.  Also never
// simulated.
reg ci_now  = 1'b0;
reg clr_now = 1'b0;
`ifdef CL_SNOOP
sdram_ctrl #(.CL_SNOOP(1)) dut (
`else
sdram_ctrl dut (
`endif
  .sysclk(clk), .clk7_en(clk7_en), .reset_in(reset_in), .cache_rst(reset_in),
  .cache_inhibit(ci_now), .cacheline_clr(clr_now), .cpu_wr_sync(wrsync), .cpu_cache_ctrl(4'b0011), .reset_out(reset_out),
  .sdaddr(sdaddr), .sd_cs(sd_cs), .ba(ba), .sd_we(sd_we), .sd_ras(sd_ras), .sd_cas(sd_cas),
  .dqm(dqm), .sdata(sdata_fpga),
  .hostWR(32'd0), .hostAddr(22'd0), .hostce(1'b0), .hostwe(1'b0), .hostbytesel(4'b0000),
  .hostRD(), .hostena(),
  .chipAddr(chipAddr), .chipL(chipL), .chipU(chipU), .chipL2(chipL2), .chipU2(chipU2),
  .chipRW(chipRW), .chip_dma(chip_dma), .chipWR(chipWR), .chipWR2(chipWR2),
  .chipRD(chipRD), .chip48(chip48),
  .rtgAddr(26'd0), .rtgce(1'b0), .rtgfill(), .rtgRd(),
  .audAddr(23'd0), .audce(1'b0), .audfill(), .audRd(),
  .cpuAddr(cpuAddr), .cpustate(cpustate), .cpuL(cpuL), .cpuU(cpuU),
  .cpuWR(cpuWR), .cpuRD(cpuRD),
  .enaWRreg(), .ena7RDreg(), .ena7WRreg(), .cpuena(cpuena)
);

// ---------------------------------------------------------------- board / IOB delay model
wire [12:0] pin_addr;  assign #T_CO pin_addr = sdaddr;
wire [1:0]  pin_ba;    assign #T_CO pin_ba   = ba;
wire        pin_cs;    assign #T_CO pin_cs   = sd_cs[0];
wire        pin_ras;   assign #T_CO pin_ras  = sd_ras;
wire        pin_cas;   assign #T_CO pin_cas  = sd_cas;
wire        pin_we;    assign #T_CO pin_we   = sd_we;
wire [1:0]  pin_dqm;   assign #T_CO pin_dqm  = dqm;

wire        oe = dut.sdata_oe;
reg         oe_d = 1'b0;      always @(oe)            oe_d     <= #T_CO oe;
reg  [15:0] dq_out_d;         always @(dut.sdata_out) dq_out_d <= #T_CO dut.sdata_out;
wire [15:0] dq_pin = oe_d ? dq_out_d : 16'bz;
reg  [15:0] dq_in_d = 16'bz;  always @(dq_pin)        dq_in_d  <= #T_IN dq_pin;
assign sdata_fpga = oe ? 16'bz : dq_in_d;

sdr16mx16 sdram (
  .Dq(dq_pin), .Addr(pin_addr), .Ba(pin_ba), .Clk(pin_clk), .Cke(1'b1),
  .Cs_n(pin_cs), .Ras_n(pin_ras), .Cas_n(pin_cas), .We_n(pin_we),
  .LDQM(pin_dqm[0]), .UDQM(pin_dqm[1])
);

// ---------------------------------------------------------------- address map
//
// Both masters must reach the same SDRAM cell.  The chipset's slot address is
// {2'b00, chipAddr, 1'b0} with ba = 0; the CPU's is {cpuAddr[25:1], 1'b0} with
// ba = cpuAddr[24:23].  So a CPU word address with [25:23] = 0 addresses the
// same cell as chipAddr[22:1] = cpuAddr[22:1], with chipAddr[23] = 0 as well.
//
// Indices are doubled everywhere below, so every address used is longword
// aligned: a chipset write puts chipWR at chipAddr and chipWR2 at chipAddr+1,
// and that pair is only well defined when chipAddr[1] is zero.
//
// Four disjoint windows, all bank 0, spaced far enough apart to land in
// different sixteen-byte lines and different cache sets.
localparam [22:1] W_C2P  = 22'h001000;   // chipset writes, CPU reads
localparam [22:1] W_P2C  = 22'h002000;   // CPU writes, chipset reads
localparam [22:1] W_CHIP = 22'h004000;   // chipset background load
localparam [22:1] W_CPU  = 22'h006000;   // CPU background load
localparam [22:1] W_CLB  = 22'h008000;   // C2P with the line buffer primed
localparam [22:1] W_WAY  = 22'h00a000;   // C2P with the 2-way cache primed
localparam [22:1] W_LW   = 22'h00c000;   // longword CPU writes
localparam [22:1] W_KICK = 22'h00e000;   // accessed CACHE-INHIBITED, as Kickstart is

// ---------------------------------------------------------------- scoreboard
integer errors   = 0;
integer checks   = 0;
integer c2p_err  = 0, c2p_chk = 0;
integer p2c_err  = 0, p2c_chk = 0;
integer p2c_late = 0, p2c_lost = 0;
integer bg_err   = 0, bg_chk  = 0;
integer clb_err  = 0, clb_chk = 0;   // C2P with the CPU's LINE BUFFER primed
integer way_err  = 0, way_chk = 0;   // C2P with the 2-way cache primed
integer lw_err   = 0, lw_chk  = 0;   // P2C by longword write
integer ci_err   = 0, ci_chk  = 0;   // cache-inhibited (Kickstart turbo) path
integer clr_err  = 0, clr_chk = 0;   // coherency across a cacheline_clr pulse
integer timeouts = 0;

task fail;
  input [8*16:1] what;
  input [25:0]   byte_a;
  input [15:0]   got;
  input [15:0]   want;
  begin
    errors = errors + 1;
    if (errors <= 40)
      $display("FAIL %0s addr %06h  got %04h  want %04h   at %t",
               what, byte_a, got, want, $time);
  end
endtask

// ---------------------------------------------------------------- mailboxes
// req: 0 idle, 1 write, 2 read.  The requester sets adr/val and req, then
// waits for done; the sequencer clears req when it has taken the request and
// raises done when the transfer is complete.
reg        c_req_wr = 1'b0, c_req_rd = 1'b0, c_done = 1'b0;
reg [22:1] c_adr;   reg [15:0] c_val, c_got;
reg        p_req_wr = 1'b0, p_req_rd = 1'b0, p_req_lw = 1'b0, p_done = 1'b0;
reg [22:1] p_adr;   reg [15:0] p_val, p_val2, p_got;

reg        seeded = 1'b0;
reg        run_bg = 1'b0;
integer    ROUNDS = 200;
integer    NOBG   = 0;

// ---------------------------------------------------------------- chipset sequencer
localparam [3:0] PH2 = 4'd2, PH12 = 4'd12, PH15 = 4'd15;

task wait_state;
  input [3:0] s;
  begin @(posedge clk); while (dut.sdram_state !== s) @(posedge clk); end
endtask

task chip_write;
  input [22:1] a;
  input [15:0] w0;
  begin
    wait_state(PH15);
    chipAddr = {1'b0, a}; chipWR = w0; chipWR2 = ~w0;
    chipRW = 1'b0; chip_dma = 1'b1;
    chipL = 1'b0; chipU = 1'b0; chipL2 = 1'b1; chipU2 = 1'b1;   // low word only
    wait_state(PH2);
    chipRW = 1'b1;
    wait_state(PH12);
  end
endtask

task chip_read;
  input  [22:1] a;
  output [15:0] d;
  begin
    wait_state(PH15);
    chipAddr = {1'b0, a}; chipRW = 1'b1; chip_dma = 1'b0;
    chipL = 1'b0; chipU = 1'b0;
    wait_state(PH2);
    chip_dma = 1'b1;
    wait_state(PH12);
    d = chipRD;
    wait_state(PH15);
  end
endtask

integer    ci;
integer    sseed = 32'h0BAD_F00D;
reg [15:0] bg_chip [0:63];
reg [15:0] cd;

initial begin : chip_seq
  wait (reset_out === 1'b1);
  forever begin
    if (c_req_wr) begin
      c_req_wr = 1'b0;
      chip_write(c_adr, c_val);
      c_done = 1'b1;
      while (c_done) @(posedge clk);
    end
    else if (c_req_rd) begin
      c_req_rd = 1'b0;
      chip_read(c_adr, cd);
      c_got  = cd;
      c_done = 1'b1;
      while (c_done) @(posedge clk);
    end
    else if (run_bg) begin
      // Duty-cycled, not back to back.  Chip RAM is bank 0 and a CPU access
      // there can only use slot 1 (cpu_slot2ok requires a non-zero bank), and
      // slot 1 goes to the chipset first -- so a chipset agent that never
      // pauses starves the CPU port completely and the bench livelocks.  Real
      // DMA has gaps: blanking, and the chipset does not claim every slot even
      // during display.  Pause a few rounds between writes.
      ci = {$random(sseed)} % 64;
      bg_chip[ci] = bg_chip[ci] + 16'h0100;
      chip_write(W_CHIP + 2*ci, bg_chip[ci]);
      repeat (16 * (1 + ({$random(sseed)} % 4))) @(posedge clk);
    end
    else @(posedge clk);
  end
end

// ---------------------------------------------------------------- CPU sequencer
// The port contract: cpuAddr stable one cycle before cpustate[2] falls
// (sdram_ctrl.v:226), then held until cpuena, then released.
task cpu_read;
  input  [22:1] a;
  output [15:0] d;
  integer c;
  begin
    @(posedge clk); cpuAddr = {3'b000, a};
                    ci_now = (a[22:12] == W_KICK[22:12]);   // sel_kickram
    @(posedge clk); cpustate = 7'b0000010;      // ramcs low, [1:0] = 10 data read
    c = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c < 4000) begin @(posedge clk); c = c + 1; end
    if (c >= 4000) begin
      timeouts = timeouts + 1;
      $display("TIMEOUT cpu_read %06h at %t", {a, 1'b0}, $time);
    end
    d = cpuRD;
    @(posedge clk); cpustate = 7'b0000100;
    @(posedge clk);
  end
endtask

task cpu_write;
  input [22:1] a;
  input [15:0] d;
  integer c;
  begin
    @(posedge clk); cpuAddr = {3'b000, a}; cpuWR = d; cpuL = 1'b0; cpuU = 1'b0;
                    ci_now = (a[22:12] == W_KICK[22:12]);   // sel_kickram
    @(posedge clk); cpustate = 7'b0000011;      // ramcs low, [1:0] = 11 write
    c = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c < 4000) begin @(posedge clk); c = c + 1; end
    if (c >= 4000) begin
      timeouts = timeouts + 1;
      $display("TIMEOUT cpu_write %06h at %t", {a, 1'b0}, $time);
    end
    @(posedge clk); cpustate = 7'b0000100;
    @(posedge clk);
  end
endtask

// LONGWORD WRITE.  The AP68040 does these constantly and the 16-bit path
// above never touches CPU_SM_WAIT_LOWORD / CPU_SM_WRITE_32BIT, which is a
// third of cpu_cache_new's write logic and the half that any change to the
// acknowledge has to keep working.  Protocol, from cpu_cache_new's IDLE
// branch: assert the write with cpuLongword set and the word at A; the cache
// acknowledges immediately (cpu_32bit_ena) and waits for cs to fall; assert
// again with the word at A+2; that cycle issues the 32-bit SDRAM write.
task cpu_write_lw;
  input [22:1] a;
  input [15:0] w_hi;   // the word AT a
  input [15:0] w_lo;   // the word at a+2
  integer c;
  begin
    @(posedge clk); cpuAddr = {3'b000, a}; cpuWR = w_hi; cpuL = 1'b0; cpuU = 1'b0;
    @(posedge clk); cpustate = 7'b1000011;      // longword | ramcs low | write
    c = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c < 4000) begin @(posedge clk); c = c + 1; end
    if (c >= 4000) begin timeouts = timeouts + 1; $display("TIMEOUT lw phase1 %06h at %t", {a,1'b0}, $time); end
    @(posedge clk); cpustate = 7'b0000100;      // cs high between the halves
    @(posedge clk); cpuWR = w_lo;
    @(posedge clk); cpustate = 7'b1000011;
    c = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c < 4000) begin @(posedge clk); c = c + 1; end
    if (c >= 4000) begin timeouts = timeouts + 1; $display("TIMEOUT lw phase2 %06h at %t", {a,1'b0}, $time); end
    @(posedge clk); cpustate = 7'b0000100;
    @(posedge clk);
  end
endtask

integer    bi;
reg [22:1] ba_bg;   // the background address, kept so fail() can print it
integer    cseed = 32'h1234_5678;
reg [15:0] bg_cpu [0:63];
reg [15:0] pd;

initial begin : cpu_seq
  wait (reset_out === 1'b1);
  forever begin
    if (p_req_wr) begin
      p_req_wr = 1'b0;
      cpu_write(p_adr, p_val);
      p_done = 1'b1;
      while (p_done) @(posedge clk);
    end
    else if (p_req_lw) begin
      p_req_lw = 1'b0;
      cpu_write_lw(p_adr, p_val, p_val2);
      p_done = 1'b1;
      while (p_done) @(posedge clk);
    end
    else if (p_req_rd) begin
      p_req_rd = 1'b0;
      cpu_read(p_adr, pd);
      p_got  = pd;
      p_done = 1'b1;
      while (p_done) @(posedge clk);
    end
    else if (run_bg) begin
      bi = {$random(cseed)} % 64;
      ba_bg = W_CPU + 2*bi;
      cpu_read(ba_bg, pd);
      bg_chk = bg_chk + 1; checks = checks + 1;
      if (pd !== bg_cpu[bi]) begin
        bg_err = bg_err + 1;
        fail("BG cpu-read", {ba_bg, 1'b0}, pd, bg_cpu[bi]);
      end
    end
    else @(posedge clk);
  end
end

// ---------------------------------------------------------------- request helpers
task do_chip_write; input [22:1] a; input [15:0] v;
  begin c_adr = a; c_val = v; c_req_wr = 1'b1;
        while (!c_done) @(posedge clk); c_done = 1'b0; end
endtask
task do_chip_read;  input [22:1] a; output [15:0] v;
  begin c_adr = a; c_req_rd = 1'b1;
        while (!c_done) @(posedge clk); v = c_got; c_done = 1'b0; end
endtask
task do_cpu_write;  input [22:1] a; input [15:0] v;
  begin p_adr = a; p_val = v; p_req_wr = 1'b1;
        while (!p_done) @(posedge clk); p_done = 1'b0; end
endtask
task do_cpu_write_lw; input [22:1] a; input [15:0] v1; input [15:0] v2;
  begin p_adr = a; p_val = v1; p_val2 = v2; p_req_lw = 1'b1;
        while (!p_done) @(posedge clk); p_done = 1'b0; end
endtask
task do_cpu_read;   input [22:1] a; output [15:0] v;
  begin p_adr = a; p_req_rd = 1'b1;
        while (!p_done) @(posedge clk); v = p_got; p_done = 1'b0; end
endtask

// ---------------------------------------------------------------- main
integer i, j;
reg [15:0] rd;
reg [15:0] rd2;
reg [22:1] ta, tb, tw, tl, tl2, tk, tc;      // scratch word address, so {ta,1'b0} has a defined width

initial begin
  $timeformat(-9, 3, " ns", 10);
  if (!$value$plusargs("rounds=%d", ROUNDS)) ROUNDS = 200;
  if ($test$plusargs("nobg")) NOBG = 1;
  if ($test$plusargs("wrsync")) wrsync = 1'b1;

  repeat (20) @(posedge clk);
  reset_in = 1'b1;
  @(posedge reset_out);
  $display("=== sdram_coherency [%0s] init at %t, %0d rounds, background %0s, wrsync %0d, cl_snoop %0d ===",
           CORNER, $time, ROUNDS, NOBG ? "OFF" : "ON", wrsync,
           `ifdef CL_SNOOP 1 `else 0 `endif );
  repeat (64) @(posedge clk);

  // Seed both background windows so a background read has a known answer.
  for (i = 0; i < 64; i = i + 1) begin
    bg_chip[i] = 16'hB000 + i;
    do_chip_write(W_CHIP + 2*i, bg_chip[i]);
  end
  for (i = 0; i < 64; i = i + 1) begin
    bg_cpu[i] = 16'hC000 + i;
    do_cpu_write(W_CPU + 2*i, bg_cpu[i]);
  end
  // Read one of each back with no contention at all: if this fails the bench
  // cannot address the memory and nothing below is meaningful.
  do_cpu_read(W_CPU + 2*5, rd);
  if (rd !== bg_cpu[5]) $display("SANITY cpu read-back FAILED: got %04h want %04h", rd, bg_cpu[5]);
  do_chip_read(W_CHIP + 2*7, rd);
  if (rd !== bg_chip[7]) $display("SANITY chip read-back FAILED: got %04h want %04h", rd, bg_chip[7]);
  $display("=== windows seeded at %t ===", $time);

  seeded = 1'b1;
  run_bg = NOBG ? 1'b0 : 1'b1;

  for (j = 0; j < ROUNDS; j = j + 1) begin
    // ---- C2P: the chipset writes, then the CPU must see it ----
    ta = W_C2P + 2*j;
    do_chip_write(ta, 16'hD000 + j);
    do_cpu_read  (ta, rd);
    c2p_chk = c2p_chk + 1; checks = checks + 1;
    if (rd !== (16'hD000 + j)) begin
      c2p_err = c2p_err + 1;
      fail("C2P cpu-read", {ta, 1'b0}, rd, 16'hD000 + j);
    end

    // ---- C2P with the CPU's LINE BUFFER PRIMED ----
    // The plain C2P round above reads an address the CPU has never touched, so
    // cpu_cache_new's sixteen-byte line buffer never holds it and an unsnooped
    // buffer cannot show.  Prime it first, THEN let the chipset write, then
    // read again: this is the shape a chunky-to-planar demo actually has.
    tb = W_CLB + 2*j;
    do_chip_write(tb, 16'h5000 + j);       // known starting value
    do_cpu_read  (tb, rd);                 // prime: the line is now in the buffer
    do_chip_write(tb, 16'hF000 + j);       // the chipset moves it behind the CPU
    do_cpu_read  (tb, rd);
    clb_chk = clb_chk + 1; checks = checks + 1;
    if (rd !== (16'hF000 + j)) begin
      clb_err = clb_err + 1;
      fail("C2P linebuf ", {tb, 1'b0}, rd, 16'hF000 + j);
    end

    // ---- C2P with the TWO-WAY CACHE primed ----
    // Same, but the line buffer is displaced by a read of a different line
    // first, so the hit that must be coherent comes out of the tag RAM ways
    // rather than the buffer.  Those ARE snooped -- this is the control that
    // says whether the buffer is the only unsnooped structure.
    tw = W_WAY + 2*j;
    do_chip_write(tw, 16'h6000 + j);
    do_cpu_read  (tw, rd);                 // into the buffer and the ways
    do_cpu_read  (W_CPU + 2*((j+7) % 64), rd);   // displace the buffer
    do_chip_write(tw, 16'h7000 + j);
    do_cpu_read  (tw, rd);
    way_chk = way_chk + 1; checks = checks + 1;
    if (rd !== (16'h7000 + j)) begin
      way_err = way_err + 1;
      fail("C2P way     ", {tw, 1'b0}, rd, 16'h7000 + j);
    end

    // ---- P2C by LONGWORD: both halves must reach the chipset ----
    tl = W_LW + 4*j;
    do_cpu_write_lw(tl, 16'h8000 + j, 16'h9000 + j);
    do_chip_read   (tl,   rd);
    lw_chk = lw_chk + 1; checks = checks + 1;
    if (rd !== (16'h8000 + j)) begin
      lw_err = lw_err + 1;
      fail("P2C lw hi   ", {tl, 1'b0}, rd, 16'h8000 + j);
    end
    tl2 = tl + 1'b1;
    do_chip_read   (tl2, rd);
    lw_chk = lw_chk + 1; checks = checks + 1;
    if (rd !== (16'h9000 + j)) begin
      lw_err = lw_err + 1;
      fail("P2C lw lo   ", {tl2, 1'b0}, rd, 16'h9000 + j);
    end

    // ---- CACHE-INHIBITED read, the Kickstart turbo shape ----
    // A cache-inhibited read must bypass the cache AND kill any line resident
    // for that row (ci_inv_pend).  Prime the line cacheable first so there IS
    // something to kill, then let the chipset move memory underneath, then
    // read it cache-inhibited: the answer must come from memory, not the line.
    tk = W_KICK + 2*j;
    do_chip_write(tk, 16'hA000 + j);
    do_cpu_read  (tk, rd);                 // ci_now is asserted for this window
    do_chip_write(tk, 16'hB000 + j);
    do_cpu_read  (tk, rd);
    ci_chk = ci_chk + 1; checks = checks + 1;
    if (rd !== (16'hB000 + j)) begin
      ci_err = ci_err + 1;
      fail("CI kick read", {tk, 1'b0}, rd, 16'hB000 + j);
    end

    // ---- coherency across a cacheline_clr pulse ----
    // cacheline_clr fires whenever Turbo chip RAM is toggled, which happened
    // in every hardware test that corrupted.  Prime a line, pulse it, and the
    // next read must still return what memory holds.
    tc = W_CLB + 2*j + 1;
    do_chip_write(tc, 16'hC000 + j);
    do_cpu_read  (tc, rd);                 // line now resident
    @(posedge clk); clr_now = 1'b1;
    @(posedge clk); clr_now = 1'b0;
    do_chip_write(tc, 16'hD000 + j);
    do_cpu_read  (tc, rd);
    clr_chk = clr_chk + 1; checks = checks + 1;
    if (rd !== (16'hD000 + j)) begin
      clr_err = clr_err + 1;
      fail("CLR line rd ", {tc, 1'b0}, rd, 16'hD000 + j);
    end

    // ---- P2C: the CPU writes, then the chipset must see it ----
    ta = W_P2C + 2*j;
    do_cpu_write (ta, 16'hE000 + j);
    do_chip_read (ta, rd);
    p2c_chk = p2c_chk + 1; checks = checks + 1;
    if (rd !== (16'hE000 + j)) begin
      // LATE or LOST?  Wait a few SDRAM rounds and look again.  A value that
      // turns up on the retry was merely still in the controller's write
      // buffer when the chipset read it -- the posted-write hazard.  One that
      // never turns up was dropped, which is a different bug entirely.
      repeat (200) @(posedge clk);
      do_chip_read(ta, rd2);
      p2c_err = p2c_err + 1;
      if (rd2 === (16'hE000 + j)) begin
        p2c_late = p2c_late + 1;
        fail("P2C LATE    ", {ta, 1'b0}, rd, 16'hE000 + j);
      end else begin
        p2c_lost = p2c_lost + 1;
        fail("P2C LOST    ", {ta, 1'b0}, rd2, 16'hE000 + j);
      end
    end
  end

  run_bg = 1'b0;
  repeat (400) @(posedge clk);
  $display("");
  $display("=== RESULT [%0s] background %0s ===", CORNER, NOBG ? "OFF" : "ON");
  $display("  checks                            %0d", checks);
  $display("  C2P (chipset write -> CPU read)   %0d checked, %0d FAILED", c2p_chk, c2p_err);
  $display("  P2C (CPU write -> chipset read)   %0d checked, %0d FAILED  (%0d late, %0d lost)", p2c_chk, p2c_err, p2c_late, p2c_lost);
  $display("  C2P line buffer primed            %0d checked, %0d FAILED", clb_chk, clb_err);
  $display("  C2P two-way cache primed          %0d checked, %0d FAILED", way_chk, way_err);
  $display("  P2C longword write                %0d checked, %0d FAILED", lw_chk, lw_err);
  $display("  cache-inhibited (Kickstart) read   %0d checked, %0d FAILED", ci_chk, ci_err);
  $display("  read across a cacheline_clr pulse  %0d checked, %0d FAILED", clr_chk, clr_err);
  $display("  background CPU reads              %0d checked, %0d FAILED", bg_chk, bg_err);
  $display("  port timeouts                     %0d", timeouts);
  if (errors == 0 && timeouts == 0) $display("=== PASS ===");
  else                              $display("=== FAIL: %0d errors, %0d timeouts ===", errors, timeouts);
  $finish;
end

// ---------------------------------------------------------------- watchdog
initial begin
  #4_000_000_000;                          // 4 ms of simulated time
  $display("=== WATCHDOG: bench did not finish ===");
  $display("  checks %0d errors %0d timeouts %0d", checks, errors, timeouts);
  $finish;
end

endmodule
