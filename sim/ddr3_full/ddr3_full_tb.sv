//-----------------------------------------------------------------
// ddr3_full_tb - the whole Zorro-III fast RAM chain (task 4 gate)
//
// DUT: rtl/ddr3/ddr3_fastram.v (cpu_cache_new + backend + ddr3_cdc) on the
// 113.4375 MHz Minimig clock, driving rtl/ddr3/ddr3_top.v (PLL + vendored
// DLL-off controller + xc7 PHY + BIST) on its own 100 MHz island clock,
// against the Micron 2Gb DDR3 model that ships with the vendored controller
// (lib/core_ddr3_controller/tb/ddr3_core_xc7/ddr3.v).  This is the bench that
// stands in for the real 68k: everything between the CPU pins and the DRAM
// pins is the real RTL.
//
// The CPU stimulus is faithful to rtl/soc/TG68K.vhd:
//   * cpuAddr (= ddraddr, cpuaddr(25 downto 1)) is presented while the select
//     is inactive and is stable for at least one clock before the select goes
//     low, because ddr3_fastram registers it into cpuAddr_r one cycle early
//     exactly as sdram_ctrl does.
//   * cpustate[2] is ddrcs, active low.  In TG68K it is
//       ddrcs <= NOT (NOT cpu_int AND sel_ddr_d AND NOT sel_nmi_vector) OR slower(0)
//     and `slower` is loaded with "0111" on the clkena that ends a bus cycle
//     and shifts right every clock, so slower(0) keeps the select high for the
//     three clocks after an acknowledge and a new bus cycle can start at the
//     earliest on the FOURTH.  GAP_MIN = 3 below is that cadence.
//   * cpustate[1:0]: 00 instruction read, 10 data read, 11 write.
//   * cpustate[6] (cpuLongword) is asserted by the kernel on the FIRST bus
//     cycle of a 32-bit access ONLY (TG68KdotC_Kernel.vhd: longword <= not
//     memmaskmux(3), and memmask shifts after each cycle), so cpu_write32
//     drops it for the second word.
//   * the access completes when cpuena (= ccachehit) is high; TG68K releases
//     the CPU with (ddr_ena AND sel_ddr_d AND ddr_ready).
//
// Tests
//   (a) ddr_ready comes up (island init + cache init)
//   (b) fills, hits, evictions and re-fills across 4 lines of one cache set
//   (c) byte-masked 16-bit writes and 32-bit writes, read back from cache and
//       from the DRAM after eviction
//   (d) 500 random accesses against a reference model, then a sweep after a
//       full cache flush so every check comes from the DRAM
//   (e) a burst of back-to-back accesses at the wrapper's real cadence
//   (f) island port protocol: 16-byte alignment, request held stable while
//       offered, never more than one request in flight
//
// Run with sim/ddr3_full/run.sh.
//-----------------------------------------------------------------
`timescale 1ps / 1ps

module ddr3_full_tb;

//-----------------------------------------------------------------
// Scoreboard
//-----------------------------------------------------------------
integer npass = 0, nfail = 0;

task record;
  input [8*80:1] name;
  input integer  e;
  begin
    if (e == 0) begin npass = npass + 1; $display("PASS: %0s", name); end
    else        begin nfail = nfail + 1; $display("FAIL: %0s (%0d errors)", name, e); end
  end
endtask

//-----------------------------------------------------------------
// Clocks
//-----------------------------------------------------------------
// Minimig system clock, 113.4375 MHz (8815 ps).  Unrelated to the island's
// 100 MHz, which comes out of the island's own PLL from the 50 MHz board
// oscillator, exactly as on the board.
reg clk = 1'b0;
always begin #4407 clk = 1'b1; #4408 clk = 1'b0; end

reg clk_50 = 1'b0;
always #10000 clk_50 = ~clk_50;

reg reset_n = 1'b0;                         // board reset chain, active low
initial begin #500_000; reset_n = 1'b1; end

//-----------------------------------------------------------------
// DUT wiring
//-----------------------------------------------------------------
reg          reset_in      = 1'b0;          // active low, = sdctl_rst
reg          cache_rst     = 1'b0;          // active low, = tg68_rst
reg          cacheline_clr = 1'b0;
reg  [ 3:0]  cpu_cache_ctrl = 4'b0011;      // = tg68_CACR_out

reg  [25:1]  cpuAddr  = 25'd0;
reg  [ 6:0]  cpustate = 7'b0000100;         // bit2 = 1: not selected
reg          cpuL = 1'b1, cpuU = 1'b1;
reg  [15:0]  cpuWR = 16'd0;
wire [15:0]  cpuRD;
wire         cpuena;
wire         ddr_ready;

wire         req_valid;
wire [ 15:0] req_wr;
wire [ 31:0] req_addr;
wire [127:0] req_wdata;
wire         req_accept;
wire         resp_valid;
wire [127:0] resp_rdata;

wire         clk100;
wire         rst100;
wire         init_done;
wire         pll_locked;

ddr3_fastram u_fast (
  .sysclk         (clk),
  .reset_in       (reset_in),
  .cache_rst      (cache_rst),
  .cacheline_clr  (cacheline_clr),
  .cpu_cache_ctrl (cpu_cache_ctrl),
  .ddr_ready      (ddr_ready),
  .cpuAddr        (cpuAddr),
  .cpustate       (cpustate),
  .cpuL           (cpuL),
  .cpuU           (cpuU),
  .cpuWR          (cpuWR),
  .cpuRD          (cpuRD),
  .cpuena         (cpuena),
  .clk_mem        (clk100),
  .init_done      (init_done),
  .req_valid      (req_valid),
  .req_wr         (req_wr),
  .req_addr       (req_addr),
  .req_wdata      (req_wdata),
  .req_accept     (req_accept),
  .resp_valid     (resp_valid),
  .resp_rdata     (resp_rdata)
);

wire [ 13:0] ddr3_addr;
wire [  2:0] ddr3_ba;
wire         ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_cs_n;
wire         ddr3_cke, ddr3_odt, ddr3_reset_n, ddr3_ck_p, ddr3_ck_n;
wire [  1:0] ddr3_dm;
wire [ 15:0] ddr3_dq;
wire [  1:0] ddr3_dqs_p, ddr3_dqs_n;

// DDR3_BIST_VIO = 0 in minimig_openaars_top.v: no VIO, so the BIST controls
// are constants and bist_busy never rises -- the mux inside ddr3_top leaves
// the native port to the external requester at all times.
ddr3_top u_isl (
   .clk_50(clk_50)
  ,.reset_n(reset_n)
  ,.clk100(clk100)
  ,.rst100(rst100)
  ,.init_done(init_done)
  ,.pll_locked(pll_locked)
  ,.req_valid(req_valid)
  ,.req_wr(req_wr)
  ,.req_addr(req_addr)
  ,.req_wdata(req_wdata)
  ,.req_accept(req_accept)
  ,.resp_valid(resp_valid)
  ,.resp_rdata(resp_rdata)
  ,.bist_start(1'b0)
  ,.bist_pattern(3'd0)
  ,.bist_range_log2(5'd28)
  ,.bist_mode(1'b0)
  ,.bist_busy()
  ,.bist_done()
  ,.bist_err_count()
  ,.bist_first_err_addr()
  ,.bist_first_err_xor()
  ,.bist_lines_done()
  ,.phy_cfg_valid(1'b0)
  ,.phy_dqs_inc(2'b0)
  ,.phy_dqs_rst(2'b0)
  ,.phy_dq_inc(2'b0)
  ,.phy_dq_rst(2'b0)
  ,.phy_rdlat(3'd5)
  ,.phy_rdsel(4'd0)
  ,.ddr3_addr(ddr3_addr)
  ,.ddr3_ba(ddr3_ba)
  ,.ddr3_ras_n(ddr3_ras_n)
  ,.ddr3_cas_n(ddr3_cas_n)
  ,.ddr3_we_n(ddr3_we_n)
  ,.ddr3_cs_n(ddr3_cs_n)
  ,.ddr3_cke(ddr3_cke)
  ,.ddr3_odt(ddr3_odt)
  ,.ddr3_reset_n(ddr3_reset_n)
  ,.ddr3_ck_p(ddr3_ck_p)
  ,.ddr3_ck_n(ddr3_ck_n)
  ,.ddr3_dm(ddr3_dm)
  ,.ddr3_dq(ddr3_dq)
  ,.ddr3_dqs_p(ddr3_dqs_p)
  ,.ddr3_dqs_n(ddr3_dqs_n)
);

ddr3 u_ram (
   .rst_n(ddr3_reset_n)
  ,.ck(ddr3_ck_p)
  ,.ck_n(ddr3_ck_n)
  ,.cke(ddr3_cke)
  ,.cs_n(ddr3_cs_n)
  ,.ras_n(ddr3_ras_n)
  ,.cas_n(ddr3_cas_n)
  ,.we_n(ddr3_we_n)
  ,.dm_tdqs(ddr3_dm)
  ,.ba(ddr3_ba)
  ,.addr(ddr3_addr)
  ,.dq(ddr3_dq)
  ,.dqs(ddr3_dqs_p)
  ,.dqs_n(ddr3_dqs_n)
  ,.tdqs_n()
  ,.odt(ddr3_odt)
);

// Silence the model's per-command transcript; the bench checks data.
defparam u_ram.DEBUG = 0;

//-----------------------------------------------------------------
// Reference model
//-----------------------------------------------------------------
// A 128 kB window of the DDR3 as 16-bit words, plus a "has been written"
// bit per word.  Locations that were never written come back from the model
// as X (DRAM is not initialised); those are read but never compared.
localparam [31:0] BASE  = 32'h0010_0000;
localparam [25:1] WBASE = BASE[25:1];
localparam integer NW   = 65536;             // 128 kB / 2

reg [15:0] ref_mem [0:NW-1];
reg [ 1:0] ref_val [0:NW-1];       // {upper byte known, lower byte known}

// Region map, as word offsets from WBASE (byte offset = 2x):
//   0x0000,0x1000,0x2000,0x3000  (b) four lines of ONE cache set
//                                    (cpu_cache_new indexes on byte [11:4],
//                                     tags on byte [25:12]; these four differ
//                                     only in byte bits 13 and 14)
//   0x4000                       (c) masks and longwords
//   0x6000                       (e) back-to-back burst
//   0x8000..0xFFFF               (d) random accesses (64 kB, 16 tags per set)
localparam [25:1] R_SET  = WBASE + 25'h0000;
localparam [25:1] R_MASK = WBASE + 25'h4000;
localparam [25:1] R_BURST= WBASE + 25'h6000;
localparam [25:1] R_RAND = WBASE + 25'h8000;
localparam integer RAND_NW = 32768;

localparam integer TMO    = 6000;            // sysclk cycles before giving up
localparam integer GAP_MIN = 3;              // TG68K slower(0) cadence

// Stimulus is applied STIM after a rising edge, never ON it.  The DUT updates
// its registers 1 ns after the edge (`<= #1` in modules with a 1ns timescale),
// so 2 ns is clear of both the edge itself and those updates, and every signal
// the bench drives is stable well before the next edge samples it.  Driving on
// the edge with blocking assignments is a race against the DUT's always blocks
// and xsim and iverilog resolve it differently -- it produced a phantom
// "32-bit write stores the high word twice" failure here before this was fixed.
// DUT outputs are read in the active region straight after @(posedge clk),
// i.e. sampled AS OF that edge, which is what a synchronous requester sees.
localparam time STIM = 2000;                 // 2 ns

integer errs;
integer i, j, k, n;
integer cyc;
integer seed;
reg [15:0] rd;
reg [25:1] wa;
reg [15:0] tmp;

function integer refidx;
  input [25:1] a;
  begin refidx = a - WBASE; end
endfunction

task ref_write;
  input [25:1] a;
  input [15:0] d;
  input [ 1:0] bs;                            // {upper, lower}, active high
  begin
    tmp = ref_mem[refidx(a)];
    if (bs[0]) tmp[ 7:0] = d[ 7:0];
    if (bs[1]) tmp[15:8] = d[15:8];
    ref_mem[refidx(a)] = tmp;
    ref_val[refidx(a)] = ref_val[refidx(a)] | bs;
  end
endtask

//-----------------------------------------------------------------
// CPU port tasks -- see the header for the handshake they reproduce
//-----------------------------------------------------------------
// Every task starts from "just after the clock edge on which the previous
// access was acknowledged", deselects and puts the new address out in that
// same instant (which is what the TG68K does: cpuaddr and sel_ddr_d change on
// the clkena edge), lets `gap` clocks pass, and only then asserts the select.
// gap = GAP_MIN = 3 is the fastest the wrapper can ever go.

task cpu_idle;
  begin
    #STIM cpustate = 7'b0000100;
    repeat (2) @(posedge clk);
  end
endtask

task cpu_read;
  input  [25:1]  a;
  input          ir;                          // 1 = instruction read
  input  integer gap;
  output [15:0]  d;
  output integer c;
  begin
    #STIM;
    cpustate = 7'b0000100;                    // deselect
    cpuAddr  = a; cpuU = 1'b0; cpuL = 1'b0;   // address out, stable from here
    repeat (gap) @(posedge clk);
    #STIM;
    cpustate = ir ? 7'b0000000 : 7'b0000010;  // select from the next edge
    c = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c < TMO) begin @(posedge clk); c = c + 1; end
    d = cpuRD;
    if (c >= TMO) begin
      errs = errs + 1;
      $display("  ** cpu_read timeout at word address %h", a);
    end
  end
endtask

task cpu_write;
  input  [25:1]  a;
  input  [15:0]  d;
  input  [ 1:0]  bs;                          // {upper, lower}, active high
  input  integer gap;
  output integer c;
  begin
    #STIM;
    cpustate = 7'b0000100;
    cpuAddr  = a; cpuWR = d; cpuU = ~bs[1]; cpuL = ~bs[0];
    repeat (gap) @(posedge clk);
    #STIM;
    cpustate = 7'b0000011;
    c = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c < TMO) begin @(posedge clk); c = c + 1; end
    if (c >= TMO) begin
      errs = errs + 1;
      $display("  ** cpu_write timeout at word address %h", a);
    end
  end
endtask

// 32-bit write: word at a with cpuLongword set, then word at a+1 without it.
task cpu_write32;
  input  [25:1]  a;
  input  [15:0]  w0;
  input  [15:0]  w1;
  input  integer gap;
  output integer c;
  integer c2;
  begin
    #STIM;
    cpustate = 7'b0000100;
    cpuAddr  = a; cpuWR = w0; cpuU = 1'b0; cpuL = 1'b0;
    repeat (gap) @(posedge clk);
    #STIM;
    cpustate = 7'b1000011;                    // cpuLongword on the FIRST cycle
    c = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c < TMO) begin @(posedge clk); c = c + 1; end
    if (c >= TMO) begin errs = errs + 1; $display("  ** cpu_write32 lo timeout at %h", a); end

    #STIM;
    cpustate = 7'b0000100;
    cpuAddr  = a + 1'b1; cpuWR = w1;
    repeat (gap) @(posedge clk);
    #STIM;
    cpustate = 7'b0000011;                    // longword flag gone
    c2 = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c2 < TMO) begin @(posedge clk); c2 = c2 + 1; end
    if (c2 >= TMO) begin errs = errs + 1; $display("  ** cpu_write32 hi timeout at %h", a); end
    c = c + c2;
  end
endtask

// Read one word and compare, but only if the reference model knows it.
task chk_word;
  input [25:1]   a;
  input          ir;
  input [8*20:1] what;
  begin
    cpu_read(a, ir, GAP_MIN, rd, cyc);
    // only the bytes the reference model has actually seen written are
    // compared; the rest of the DRAM was never written and reads back as X.
    if ((ref_val[refidx(a)][0] && rd[ 7:0] !== ref_mem[refidx(a)][ 7:0]) ||
        (ref_val[refidx(a)][1] && rd[15:8] !== ref_mem[refidx(a)][15:8])) begin
      errs = errs + 1;
      if (errs < 12)
        $display("  %0s: word addr %h -> %h, expected %h (valid %b)",
                 what, a, rd, ref_mem[refidx(a)], ref_val[refidx(a)]);
    end
  end
endtask

// Invalidate everything: the tag RAMs through cpu_cache_ctrl[3] (the CACR
// "clear cache" bit, edge-detected in cpu_cache_new while cpu_cs is low) and
// the L0 line register through cacheline_clr.  After this every read has to
// come from the DRAM.
task cache_flush;
  begin
    cpu_idle;
    #STIM;
    cacheline_clr  = 1'b1;
    cpu_cache_ctrl = 4'b1011;
    repeat (4) @(posedge clk);
    #STIM cacheline_clr = 1'b0;
    repeat (600) @(posedge clk);              // the tag clear walks 256 entries
    #STIM cpu_cache_ctrl = 4'b0011;
    repeat (8) @(posedge clk);
  end
endtask

//-----------------------------------------------------------------
// Island port protocol checker
//-----------------------------------------------------------------
integer proto_errs = 0;
reg          prev_valid = 1'b0;
reg [ 15:0]  prev_wr;
reg [ 31:0]  prev_addr;
reg [127:0]  prev_wdata;
integer      outstanding = 0;

always @ (posedge clk100) begin
  if (req_valid) begin
    if (req_addr[3:0] !== 4'h0) begin
      proto_errs = proto_errs + 1;
      $display("  proto: req_addr %h is not 16-byte aligned", req_addr);
    end
    if (prev_valid && !$isunknown({prev_wr, prev_addr})) begin
      if (req_wr !== prev_wr || req_addr !== prev_addr ||
          (req_wr != 16'h0000 && req_wdata !== prev_wdata)) begin
        proto_errs = proto_errs + 1;
        $display("  proto: request changed while offered (addr %h -> %h)", prev_addr, req_addr);
      end
    end
    if (req_accept) outstanding = outstanding + 1;
  end
  prev_valid = req_valid && !req_accept;
  prev_wr    = req_wr;
  prev_addr  = req_addr;
  prev_wdata = req_wdata;
  if (resp_valid) begin
    if (outstanding == 0) begin
      proto_errs = proto_errs + 1;
      $display("  proto: resp_valid with no accepted request outstanding");
    end else outstanding = outstanding - 1;
    if (outstanding > 0) begin
      proto_errs = proto_errs + 1;
      $display("  proto: more than one request in flight");
    end
  end
end

// Cadence monitor: shortest gap, in sysclk cycles, between two falling edges
// of the chip select.  The wrapper can never do better than 4.
integer cs_cycle = 0;
integer cs_last  = -1;
integer cs_min   = 1000000;
reg     cs_prev  = 1'b1;
always @ (posedge clk) begin
  cs_cycle = cs_cycle + 1;
  if (cs_prev === 1'b1 && cpustate[2] === 1'b0) begin
    if (cs_last >= 0 && (cs_cycle - cs_last) < cs_min) cs_min = cs_cycle - cs_last;
    cs_last = cs_cycle;
  end
  cs_prev = cpustate[2];
end

//-----------------------------------------------------------------
// Stimulus
//-----------------------------------------------------------------
integer ready_cyc;

initial begin
  $timeformat(-9, 3, " ns", 10);
  for (i = 0; i < NW; i = i + 1) begin ref_mem[i] = 16'h0000; ref_val[i] = 2'b00; end
  seed = 32'h0DD3_3FA5;
  if ($value$plusargs("seed=%d", seed))
    $display("stimulus seed overridden: %0d", seed);

  //------------------------------------------------------------- (a) ddr_ready
  errs = 0;
  repeat (20) @(posedge clk);
  #STIM;
  reset_in = 1'b1; cache_rst = 1'b1;
  ready_cyc = 0;
  while (ddr_ready !== 1'b1 && ready_cyc < 20000) begin @(posedge clk); ready_cyc = ready_cyc + 1; end
  if (ddr_ready !== 1'b1) begin
    errs = errs + 1;
    $display("  ** ddr_ready never came up");
  end else begin
    $display("INFO: ddr_ready at %t (%0d sysclk after reset release), init_done=%b pll_locked=%b",
             $time, ready_cyc, init_done, pll_locked);
  end
  record("(a) island init and cache reset complete, ddr_ready high", errs);
  if (errs != 0) begin
    $display("");
    $display("DDR3 FULL TB: %0d passed, %0d failed", npass, nfail);
    $finish;
  end
  repeat (600) @(posedge clk);          // cpu_cache_new clears its own tags
  cpu_idle;

  //------------------------------------------------------------- (b) 4 lines
  // R_SET + k*0x1000 words = byte offset k*0x2000: same cache index
  // (byte [11:4]), four different tags, so all four fight over the two ways
  // plus the L0 line register.
  errs = 0;
  for (k = 0; k < 4; k = k + 1) begin
    for (i = 0; i < 8; i = i + 1) begin
      wa = R_SET + k * 25'h1000 + i;
      tmp = 16'h1000 + k * 16'h0100 + i;
      cpu_write(wa, tmp, 2'b11, GAP_MIN, cyc);
      ref_write(wa, tmp, 2'b11);
    end
  end
  // read them all back: first pass fills, second pass must hit
  for (k = 0; k < 4; k = k + 1)
    for (i = 0; i < 8; i = i + 1) chk_word(R_SET + k * 25'h1000 + i, 1'b1, "b/fill");
  for (k = 0; k < 4; k = k + 1)
    for (i = 0; i < 8; i = i + 1) chk_word(R_SET + k * 25'h1000 + i, 1'b1, "b/hit");
  // evict line k by touching the other three, then re-read it from the DRAM
  for (k = 0; k < 4; k = k + 1) begin
    for (n = 0; n < 2; n = n + 1)
      for (j = 0; j < 4; j = j + 1)
        if (j != k) begin
          chk_word(R_SET + j * 25'h1000, 1'b1, "b/evict-ir");
          chk_word(R_SET + j * 25'h1000, 1'b0, "b/evict-dr");
        end
    for (i = 0; i < 8; i = i + 1) chk_word(R_SET + k * 25'h1000 + i, 1'b1, "b/refill");
    for (i = 0; i < 8; i = i + 1) chk_word(R_SET + k * 25'h1000 + i, 1'b0, "b/refill-dr");
  end
  record("(b) fills, hits, evictions and re-fills across 4 lines of one set", errs);

  //------------------------------------------------------------- (c) masks / 32-bit
  errs = 0;
  wa = R_MASK;
  for (i = 0; i < 8; i = i + 1) begin              // seed the line
    cpu_write(wa + i, 16'hA5A5, 2'b11, GAP_MIN, cyc);
    ref_write(wa + i, 16'hA5A5, 2'b11);
  end
  cache_flush;
  cpu_write(wa + 0, 16'h11FF, 2'b10, GAP_MIN, cyc); ref_write(wa + 0, 16'h11FF, 2'b10); // upper byte only
  cpu_write(wa + 1, 16'hFF22, 2'b01, GAP_MIN, cyc); ref_write(wa + 1, 16'hFF22, 2'b01); // lower byte only
  cpu_write(wa + 2, 16'h3344, 2'b11, GAP_MIN, cyc); ref_write(wa + 2, 16'h3344, 2'b11);
  cpu_write(wa + 3, 16'hDEAD, 2'b00, GAP_MIN, cyc);                                     // no byte at all
  for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "c/mask-hit");
  cache_flush;
  for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "c/mask-mem");
  // aligned 32-bit writes at word offsets 0, 2, 4 of the line
  for (i = 0; i < 6; i = i + 2) begin
    cpu_write32(wa + i, 16'h5A00 + i, 16'h6B00 + i, GAP_MIN, cyc);
    ref_write(wa + i,     16'h5A00 + i, 2'b11);
    ref_write(wa + i + 1, 16'h6B00 + i, 2'b11);
  end
  for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "c/lw-hit");
  cache_flush;
  for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "c/lw-mem");
  // odd word offset: the split path in cpu_cache_new
  cpu_write32(wa + 1, 16'h7777, 16'h8888, GAP_MIN, cyc);
  ref_write(wa + 1, 16'h7777, 2'b11);
  ref_write(wa + 2, 16'h8888, 2'b11);
  // and the line-straddling case: word 7 of the line, which longword_en
  // excludes, so it degrades into two independent 16-bit writes
  cpu_write32(wa + 7, 16'h9999, 16'hAAAA, GAP_MIN, cyc);
  ref_write(wa + 7, 16'h9999, 2'b11);
  ref_write(wa + 8, 16'hAAAA, 2'b11);
  cache_flush;
  for (i = 0; i < 9; i = i + 1) chk_word(wa + i, 1'b1, "c/lw-mem2");
  record("(c) byte-masked 16-bit and 32-bit writes, cache and DRAM", errs);

  //------------------------------------------------------------- (d) random
  errs = 0;
  for (n = 0; n < 500; n = n + 1) begin
    wa = R_RAND + ({$random(seed)} % RAND_NW);
    case ({$random(seed)} % 4)
      0, 1 : chk_word(wa, ({$random(seed)} % 2) != 0, "d/rand-rd");
      2    : begin
               tmp = {$random(seed)};
               j   = {$random(seed)} % 3;             // 0 = lo, 1 = hi, 2 = both
               cpu_write(wa, tmp, (j == 0) ? 2'b01 : (j == 1) ? 2'b10 : 2'b11, GAP_MIN, cyc);
               ref_write(wa, tmp, (j == 0) ? 2'b01 : (j == 1) ? 2'b10 : 2'b11);
             end
      3    : begin
               if (wa == R_RAND + RAND_NW - 1) wa = wa - 1;
               tmp = {$random(seed)};
               rd  = {$random(seed)};
               cpu_write32(wa, tmp, rd, GAP_MIN, cyc);
               ref_write(wa,     tmp, 2'b11);
               ref_write(wa + 1, rd,  2'b11);
             end
    endcase
    if ((n % 100) == 99) $display("INFO: (d) %0d/500 at %t, %0d mismatches so far", n + 1, $time, errs);
  end
  // every check from here on must come out of the DRAM
  cache_flush;
  for (n = 0; n < 250; n = n + 1) begin
    wa = R_RAND + ({$random(seed)} % RAND_NW);
    chk_word(wa, ({$random(seed)} % 2) != 0, "d/sweep");
  end
  record("(d) 500 random accesses + 250-read sweep vs the reference model", errs);

  //------------------------------------------------------------- (e) burst
  // 8 consecutive lines written and read back with no idle time beyond the
  // three clocks the TG68K's slower(0) forces between bus cycles.
  errs = 0;
  cs_min = 1000000; cs_last = -1;
  for (i = 0; i < 64; i = i + 1) begin
    tmp = 16'hB000 + i;
    cpu_write(R_BURST + i, tmp, 2'b11, GAP_MIN, cyc);
    ref_write(R_BURST + i, tmp, 2'b11);
  end
  cache_flush;
  for (i = 0; i < 64; i = i + 1) chk_word(R_BURST + i, 1'b1, "e/burst-mem");
  for (i = 0; i < 64; i = i + 1) chk_word(R_BURST + i, 1'b1, "e/burst-hit");
  $display("INFO: (e) shortest chip-select to chip-select spacing: %0d sysclk (wrapper minimum is 4)", cs_min);
  if (cs_min < 4) begin
    errs = errs + 1;
    $display("  e: the bench drove the port faster than the wrapper ever can");
  end
  record("(e) back-to-back accesses at the wrapper's real cadence", errs);

  //------------------------------------------------------------- (f) protocol
  record("(f) island port protocol: alignment, stability, one request in flight", proto_errs);

  cpu_idle;
  $display("");
  $display("DDR3 FULL TB: %0d passed, %0d failed", npass, nfail);
  $finish;
end

// global watchdog
initial begin
  repeat (4) #1_000_000_000;                        // 4 ms
  $display("DDR3 FULL TB: WATCHDOG TIMEOUT");
  $display("DDR3 FULL TB: %0d passed, %0d failed", npass, nfail + 1);
  $finish;
end

endmodule
