// ddr3_fastram_tb.v -- self-checking bench for rtl/ddr3/ddr3_fastram.v and
//                      rtl/ddr3/ddr3_cdc.v against sim/ddr3/mem_stub.v.
//
//   clk_sys  113.4375 MHz  (8815 ps, the Minimig clk_114)
//   clk_mem  100 MHz       (10000 ps, unrelated phase: +1731 ps offset)
//
// The CPU-port tasks follow the TG68K handshake used by
// sim/sdram_timing/sdram_timing_tb.v: the address is presented one cycle
// before the chip select, cpustate[2] is the active-low select, and the
// access completes when cpuena goes high (level).
//
// Tests
//   (a) fill / hit / re-fill after eviction over two lines
//   (b) byte-masked 16-bit writes and 32-bit (longword) writes
//   (c) read-after-write to the same line, before and after eviction
//   (d) wrapped burst order: every one of the 8 possible start words
//   (e) 200 random accesses against a reference model
//   (f) reset in the middle of a request, at three different points
//   (g) CDC stress: random 0-40 sysclk gaps between accesses
//
// Run with sim/ddr3/run.sh.

`timescale 1ps / 1ps

module ddr3_fastram_tb;

// ---------------------------------------------------------------- clocks
reg clk = 1'b0;                                   // clk_sys, 113.4375 MHz
always begin #4407 clk = 1'b1; #4408 clk = 1'b0; end

reg clk_mem = 1'b0;                               // 100 MHz, unrelated phase
initial begin #1731; forever #5000 clk_mem = ~clk_mem; end

// ---------------------------------------------------------------- DUT wires
reg          reset_in  = 1'b0;                    // active low
reg          cache_rst = 1'b0;                    // active low
reg  [25:1]  cpuAddr   = 25'd0;
reg  [ 6:0]  cpustate  = 7'b0000100;              // bit2 = 1: not selected
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
wire         init_done;

ddr3_fastram dut (
  .sysclk         (clk),
  .reset_in       (reset_in),
  .cache_rst      (cache_rst),
  .cacheline_clr  (1'b0),
  .cpu_cache_ctrl (4'b0011),
  .ddr_ready      (ddr_ready),
  .cpuAddr        (cpuAddr),
  .cpustate       (cpustate),
  .cpuL           (cpuL),
  .cpuU           (cpuU),
  .cpuWR          (cpuWR),
  .cpuRD          (cpuRD),
  .cpuena         (cpuena),
  .clk_mem        (clk_mem),
  .init_done      (init_done),
  .req_valid      (req_valid),
  .req_wr         (req_wr),
  .req_addr       (req_addr),
  .req_wdata      (req_wdata),
  .req_accept     (req_accept),
  .resp_valid     (resp_valid),
  .resp_rdata     (resp_rdata)
);

mem_stub #(
  .INIT_DELAY (200),
  .ACCEPT_MAX (5),
  .LAT_MIN    (5),
  .LAT_MAX    (30)
) stub (
  .clk        (clk_mem),
  .rst        (1'b0),
  .req_valid  (req_valid),
  .req_wr     (req_wr),
  .req_addr   (req_addr),
  .req_wdata  (req_wdata),
  .req_accept (req_accept),
  .resp_valid (resp_valid),
  .resp_rdata (resp_rdata),
  .init_done  (init_done)
);

// ---------------------------------------------------------------- reference model
// 32 kB window of DDR3 at BASE, as 16-bit words.
localparam [31:0] BASE  = 32'h0010_0000;
localparam [25:1] WBASE = BASE[25:1];             // word address of BASE
localparam integer NW   = 16384;                  // 32 kB / 2

reg [15:0] ref_mem [0:NW-1];

localparam integer TMO = 3000;                    // cycles before giving up

integer npass = 0, nfail = 0;
integer errs;
integer i, j, k, n, gap;
integer cyc;
integer seed;
reg [15:0] rd;
reg [25:1] wa;
reg [127:0] line;
reg [15:0] tmp;

task record;                                      // one PASS/FAIL line per test
  input [8*72:1] name;
  input integer  e;
  begin
    if (e == 0) begin npass = npass + 1; $display("PASS: %0s", name); end
    else        begin nfail = nfail + 1; $display("FAIL: %0s (%0d errors)", name, e); end
  end
endtask

function integer refidx;                          // ref_mem index of a word address
  input [25:1] a;
  begin refidx = a - WBASE; end
endfunction

task ref_write;
  input [25:1] a;
  input [15:0] d;
  input [ 1:0] bs;                                // {upper, lower}, active high
  begin
    tmp = ref_mem[refidx(a)];
    if (bs[0]) tmp[ 7:0] = d[ 7:0];
    if (bs[1]) tmp[15:8] = d[15:8];
    ref_mem[refidx(a)] = tmp;
  end
endtask

// ---------------------------------------------------------------- CPU port tasks
// address one cycle before select, wait for cpuena (level).

// Deselect.  Note cpuena can legitimately stay high while deselected: with
// cpustate[1:0] = 00 the cache still reports cpu_cacheline_valid for the L0
// line, exactly as it does in the real system.  So do not wait for it to
// fall; just hold the deselected state for a couple of cycles, as
// sim/sdram_timing/sdram_timing_tb.v does.
task cpu_idle;
  begin
    cpustate = 7'b0000100;
    repeat (2) @(posedge clk);
  end
endtask

task cpu_read;
  input  [25:1]  a;
  input          ir;                              // 1 = instruction read
  output [15:0]  d;
  output integer c;
  begin
    @(posedge clk); cpuAddr = a; cpuU = 1'b0; cpuL = 1'b0;
    @(posedge clk); cpustate = ir ? 7'b0000000 : 7'b0000010;
    c = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c < TMO) begin @(posedge clk); c = c + 1; end
    d = cpuRD;
    if (c >= TMO) $display("  ** cpu_read timeout at word address %h", a);
    @(posedge clk); cpu_idle;
    repeat (2) @(posedge clk);
  end
endtask

task cpu_write;
  input  [25:1]  a;
  input  [15:0]  d;
  input  [ 1:0]  bs;                              // {upper, lower}, active high
  output integer c;
  begin
    @(posedge clk); cpuAddr = a; cpuWR = d; cpuU = ~bs[1]; cpuL = ~bs[0];
    @(posedge clk); cpustate = 7'b0000011;
    c = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c < TMO) begin @(posedge clk); c = c + 1; end
    if (c >= TMO) $display("  ** cpu_write timeout at word address %h", a);
    @(posedge clk); cpu_idle;
    repeat (2) @(posedge clk);
  end
endtask

// 32-bit write, as the TG68K issues it: word at a, then word at a+1.
// cpustate[6] (cpuLongword) is asserted on the FIRST bus cycle ONLY:
// rtl/tg68k/TG68KdotC_Kernel.vhd line 424 drives longword <= not
// memmaskmux(3), and memmask shifts left two bits after each bus cycle
// (line 1082), so bit 3 is '1' -- longword '0' -- for the second word.
// That is what stops cpu_cache_new starting a fresh 32-bit sequence on the
// second half, and it is what makes a line-straddling longword degrade
// safely into two independent 16-bit writes (longword_en also masks
// cpuAddr_r[3:1] == 3'b111).
task cpu_write32;
  input  [25:1]  a;
  input  [15:0]  w0;
  input  [15:0]  w1;
  output integer c;
  integer c2;
  begin
    @(posedge clk); cpuAddr = a; cpuWR = w0; cpuU = 1'b0; cpuL = 1'b0;
    @(posedge clk); cpustate = 7'b1000011;
    c = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c < TMO) begin @(posedge clk); c = c + 1; end
    if (c >= TMO) $display("  ** cpu_write32 lo timeout at word address %h", a);
    @(posedge clk); cpu_idle;
    @(posedge clk); cpuAddr = a + 1'b1; cpuWR = w1;
    @(posedge clk); cpustate = 7'b0000011;      // longword flag drops here
    c2 = 0;
    @(posedge clk);
    while (cpuena !== 1'b1 && c2 < TMO) begin @(posedge clk); c2 = c2 + 1; end
    if (c2 >= TMO) $display("  ** cpu_write32 hi timeout at word address %h", a);
    @(posedge clk); cpu_idle;
    repeat (2) @(posedge clk);
    c = c + c2;
  end
endtask

// read three other lines in the same cache set (same byte address [11:4],
// different tag) so both ways and the L0 cacheline are displaced.
task evict;
  input [25:1] a;
  integer      e;
  reg   [15:0] dd;
  integer      cc;
  begin
    for (e = 1; e <= 3; e = e + 1)
      cpu_read(a ^ (e << 12), 1'b1, dd, cc);
  end
endtask

// check one word against the reference model
task chk_word;
  input [25:1]  a;
  input         ir;
  input [8*20:1] what;
  begin
    cpu_read(a, ir, rd, cyc);
    if (rd !== ref_mem[refidx(a)]) begin
      errs = errs + 1;
      if (errs < 12)
        $display("  %0s: word addr %h -> %h, expected %h", what, a, rd, ref_mem[refidx(a)]);
    end
  end
endtask

// ---------------------------------------------------------------- protocol checks
// Continuous checks on the island port: the request must stay stable while it
// is being offered, the line address must be 16-byte aligned, and a response
// must only arrive for a request that was accepted.
integer proto_errs = 0;
reg          prev_valid = 1'b0;
reg [ 15:0]  prev_wr;
reg [ 31:0]  prev_addr;
reg [127:0]  prev_wdata;
integer      outstanding = 0;

always @ (posedge clk_mem) begin
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

// ---------------------------------------------------------------- stimulus
initial begin
  $timeformat(-9, 3, " ns", 10);
  for (i = 0; i < NW; i = i + 1) ref_mem[i] = 16'h0000;
  seed = 32'h0BAD_F00D;
  if ($value$plusargs("seed=%d", seed))
    $display("stimulus seed overridden: %0d", seed);

  repeat (20) @(posedge clk);
  reset_in = 1'b1; cache_rst = 1'b1;
  wait (ddr_ready === 1'b1);
  repeat (20) @(posedge clk);
  $display("ddr_ready at %t", $time);
  $display("");

  // ---------------------------------------------------------- (a) fill/hit/refill
  errs = 0;
  for (i = 0; i < 16; i = i + 1) begin                 // two lines, 16-bit writes
    cpu_write(WBASE + i, 16'h1000 + i * 16'h0111, 2'b11, cyc);
    ref_write(WBASE + i, 16'h1000 + i * 16'h0111, 2'b11);
  end
  for (i = 0; i < 16; i = i + 1) chk_word(WBASE + i, 1'b1, "a/fill");
  for (i = 0; i < 16; i = i + 1) chk_word(WBASE + i, 1'b1, "a/hit");
  evict(WBASE);
  evict(WBASE + 8);
  for (i = 0; i < 16; i = i + 1) chk_word(WBASE + i, 1'b1, "a/refill");
  // and once more as data reads, to exercise the D-cache tags too
  for (i = 0; i < 16; i = i + 1) chk_word(WBASE + i, 1'b0, "a/dread");
  record("(a) fill / hit / evict / re-fill over two lines", errs);

  // ---------------------------------------------------------- (b) byte masks, 32-bit
  errs = 0;
  wa = WBASE + 16'h0080;                               // BASE + 0x100
  for (i = 0; i < 8; i = i + 1) begin                  // seed the line
    cpu_write(wa + i, 16'hA5A5, 2'b11, cyc);
    ref_write(wa + i, 16'hA5A5, 2'b11);
  end
  evict(wa);
  cpu_write(wa + 0, 16'h11FF, 2'b10, cyc); ref_write(wa + 0, 16'h11FF, 2'b10); // upper only
  cpu_write(wa + 1, 16'hFF22, 2'b01, cyc); ref_write(wa + 1, 16'hFF22, 2'b01); // lower only
  cpu_write(wa + 2, 16'h3344, 2'b11, cyc); ref_write(wa + 2, 16'h3344, 2'b11);
  cpu_write(wa + 3, 16'hDEAD, 2'b00, cyc);                                     // no bytes
  for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "b/mask-hit");
  evict(wa);
  for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "b/mask-mem");
  // aligned 32-bit writes at word offsets 0, 2, 4 of the line
  for (i = 0; i < 6; i = i + 2) begin
    cpu_write32(wa + i, 16'h5A00 + i, 16'h6B00 + i, cyc);
    ref_write(wa + i,     16'h5A00 + i, 2'b11);
    ref_write(wa + i + 1, 16'h6B00 + i, 2'b11);
  end
  for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "b/lw-hit");
  evict(wa);
  for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "b/lw-mem");
  // unaligned 32-bit write (odd word offset -> the split path in the cache)
  cpu_write32(wa + 1, 16'h7777, 16'h8888, cyc);
  ref_write(wa + 1, 16'h7777, 2'b11);
  ref_write(wa + 2, 16'h8888, 2'b11);
  evict(wa);
  for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "b/lw-unal");
  record("(b) byte-masked 16-bit and 32-bit writes", errs);

  // ---------------------------------------------------------- (c) read after write
  errs = 0;
  wa = WBASE + 16'h0100;                               // BASE + 0x200
  for (i = 0; i < 8; i = i + 1) begin
    cpu_write(wa + i, 16'hC000 + i, 2'b11, cyc);
    ref_write(wa + i, 16'hC000 + i, 2'b11);
    chk_word(wa + i, 1'b0, "c/raw-now");                // immediately after
    chk_word(wa + ((i + 4) % 8), 1'b0, "c/raw-other");  // another word, same line
  end
  evict(wa);
  for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "c/raw-mem");
  record("(c) read-after-write to the same line", errs);

  // ---------------------------------------------------------- (d) wrapped burst
  // For each start word 0..7: pre-load a fresh line through the memory
  // backdoor, read the word at that offset FIRST (so the DDR3 burst starts
  // there and wraps), then check all eight words of the line.
  errs = 0;
  for (k = 0; k < 8; k = k + 1) begin
    wa   = WBASE + 16'h0200 + k * 8;                   // one fresh line per k
    line = 128'd0;
    for (i = 0; i < 8; i = i + 1) begin
      tmp = 16'hD000 + k * 16'h0100 + i;
      line[16*i +: 16] = tmp;
      ref_mem[refidx(wa + i)] = tmp;
    end
    stub.poke({6'd0, {wa, 1'b0}} & 32'hFFFF_FFF0, line);
    cpu_read(wa + k, 1'b1, rd, cyc);                   // the wrapping start word
    if (rd !== ref_mem[refidx(wa + k)]) begin
      errs = errs + 1;
      $display("  d/start%0d: word addr %h -> %h, expected %h", k, wa + k, rd, ref_mem[refidx(wa + k)]);
    end
    for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "d/wrap");
  end
  record("(d) wrapped burst order, all 8 start words", errs);

  // ---------------------------------------------------------- (e) random accesses
  errs = 0;
  for (n = 0; n < 200; n = n + 1) begin
    wa = WBASE + ({$random(seed)} % NW);
    case ({$random(seed)} % 4)
      0, 1 : begin                                     // read
               chk_word(wa, ({$random(seed)} % 2) != 0, "e/rand-rd");
             end
      2    : begin                                     // 16-bit write, random mask
               tmp = {$random(seed)};
               j   = {$random(seed)} % 3;              // 0=lo 1=hi 2=both
               cpu_write(wa, tmp, (j == 0) ? 2'b01 : (j == 1) ? 2'b10 : 2'b11, cyc);
               ref_write(wa, tmp, (j == 0) ? 2'b01 : (j == 1) ? 2'b10 : 2'b11);
             end
      3    : begin                                     // 32-bit write
               if (wa == WBASE + NW - 1) wa = wa - 1;   // keep a+1 in the window
               tmp = {$random(seed)};
               rd  = {$random(seed)};
               cpu_write32(wa, tmp, rd, cyc);
               ref_write(wa,     tmp, 2'b11);
               ref_write(wa + 1, rd,  2'b11);
             end
    endcase
  end
  // full sweep of the touched window afterwards, through the cache
  for (i = 0; i < 256; i = i + 1) begin
    wa = WBASE + ({$random(seed)} % NW);
    chk_word(wa, 1'b1, "e/sweep");
  end
  record("(e) 200 random accesses + 256-read sweep vs reference model", errs);

  // ---------------------------------------------------------- (f) reset mid request
  errs = 0;
  for (k = 0; k < 3; k = k + 1) begin
    wa = WBASE + 16'h0400 + k * 8;
    // start a read and pull reset while it is somewhere in the CDC/memory
    @(posedge clk); cpuAddr = wa; cpuU = 1'b0; cpuL = 1'b0;
    @(posedge clk); cpustate = 7'b0000000;
    repeat (3 + k * 12) @(posedge clk);
    reset_in = 1'b0; cache_rst = 1'b0;
    cpustate = 7'b0000100;
    repeat (10) @(posedge clk);
    reset_in = 1'b1; cache_rst = 1'b1;
    wait (ddr_ready === 1'b1);
    repeat (20) @(posedge clk);
    // normal operation must resume
    for (i = 0; i < 8; i = i + 1) begin
      cpu_write(wa + i, 16'hE000 + k * 16'h0100 + i, 2'b11, cyc);
      ref_write(wa + i, 16'hE000 + k * 16'h0100 + i, 2'b11);
    end
    evict(wa);
    for (i = 0; i < 8; i = i + 1) chk_word(wa + i, 1'b1, "f/after-reset");
  end
  record("(f) reset during a request, three different points", errs);

  // ---------------------------------------------------------- (g) CDC stress
  errs = 0;
  for (n = 0; n < 150; n = n + 1) begin
    gap = {$random(seed)} % 41;                        // 0..40 sysclk of idle
    repeat (gap) @(posedge clk);
    wa = WBASE + 16'h0800 + ({$random(seed)} % 512);
    if (({$random(seed)} % 2) != 0) begin
      tmp = {$random(seed)};
      cpu_write(wa, tmp, 2'b11, cyc);
      ref_write(wa, tmp, 2'b11);
    end else begin
      chk_word(wa, ({$random(seed)} % 2) != 0, "g/stress");
    end
  end
  for (i = 0; i < 512; i = i + 1) begin
    if ((i % 8) == 0) evict(WBASE + 16'h0800 + i);      // force memory reads
    chk_word(WBASE + 16'h0800 + i, 1'b1, "g/verify");
  end
  record("(g) CDC stress, random 0-40 cycle gaps", errs);

  // ---------------------------------------------------------- backdoor check
  // everything the reference model says must also be in the memory itself
  errs = 0;
  for (i = 0; i < NW; i = i + 8) begin
    stub.peek({6'd0, {(WBASE + i), 1'b0}} & 32'hFFFF_FFF0, line);
    for (j = 0; j < 8; j = j + 1)
      if (line[16*j +: 16] !== ref_mem[i + j]) begin
        errs = errs + 1;
        if (errs < 12)
          $display("  backdoor: word addr %h -> %h, expected %h",
                   WBASE + i + j, line[16*j +: 16], ref_mem[i + j]);
      end
  end
  record("(h) memory contents match the reference model (backdoor)", errs);

  record("(i) island port protocol: alignment, stability, one in flight", proto_errs);

  $display("");
  $display("DDR3 FASTRAM TB: %0d passed, %0d failed", npass, nfail);
  $finish;
end

// global watchdog
initial begin
  #900_000_000;                                        // 900 us
  $display("DDR3 FASTRAM TB: WATCHDOG TIMEOUT");
  $display("DDR3 FASTRAM TB: %0d passed, %0d failed", npass, nfail + 1);
  $finish;
end

endmodule
