// bfm_akiko: the Amiga side of cfide's Akiko request window in the L3 bench
// (scenario akiko): the signals minimig_virtual_top.v ties off today
// (tg68_host_addr / _d / _wr = 0, amigahost_req = 0 in the non-TG68 build)
// and that the TG68K side drives when it has an Akiko register cycle for the
// host to serve.
//
// Protocol (rtl/host/cfide.vhd "Amiga interface at 0fffff80", the firmware's
// akiko_inthandler in fw/ctrl_rv/akiko.c): the requester sets amiga_addr,
// amiga_d (a write's data), amiga_wr and raises amiga_req, and holds all of
// them until amiga_ack.  The rising edge of amiga_req is the host's
// interrupt (EDGE, one per request).  The host's handler reads ADDR
// ({req, wr, 000000, amiga_addr}) and DATA (amiga_d), prints one UART line,
// and writes DATA = 0: that write is the ack (one clk_28 pulse) and puts 0 on
// amiga_q.  A read request therefore returns 0 (the host path is a logging
// stub: the Akiko C2P itself is rtl/minimig/akiko.v, on the Amiga side).
//
// Tasks (clk_28 domain; the latency is in bench clk_114 cycles, `cyc`):
//   akiko_write(addr, data)   request, wait for the ack
//   akiko_read(addr, data)    request, wait for the ack; data = amiga_q
// After an ack the model waits for the host to re-arm its interrupt (the
// firmware's inthandler: DisableInterrupts ... akiko_inthandler ...
// EnableInterrupts, an 0xFFFFFFA0 write with bit 0 set, `ena_wr`) and
// +AKI_GAP=<n> more clk_28 cycles (default 4) before the next request.  A
// request raised while the interrupt is disabled sets no interrupt flag
// (cfide.vhd int_legacy_nx needs interrupt_ena) and its edge is lost: the
// model never does that, it measures the window (rearm = ack to the
// EnableInterrupts write, logged per request) and reports it as a finding
// (findings/osd-riscv/phase4.md).
//
// Blocks: block b (0, 1) is 32 write requests then 32 read requests,
//   addr(b, i) = 0x20 + 0x80 * b + i                     (writes and reads)
//   data(b, i) = ((i + 1) * 0x9E37) & 0xFFFF, xor 0xC3A5 in block 1
// (l3check.py akiko computes the same).  `go1` starts block 0, `go2` block 1;
// b1_done / done are set at the end of each.  `busy` is the floppy DMA's
// (fdd.dma_busy), logged per request.
//
// One log line per request, read by l3check.py akiko:
//   === AKIKO req <b> <k> <W|R> addr <hh> d <hhhh> q <hhhh> req <cyc> ack <cyc> lat <n> rearm <n> dma <0|1>
// and per block "=== AKIKO block <b> from cycle <c> to cycle <c>".
`timescale 1ns/1ps

module bfm_akiko (
  input  wire        clk28,
  input  wire        clk114,
  input  wire [31:0] cyc,            // the bench's clk_114 cycle
  input  wire        ena_wr,         // a completed write to the INTERRUPT window with bit 0 set (clk_114)
  input  wire        busy,           // the floppy DMA is in progress (fdd.dma_busy)
  // cfide's amiga_* ports
  output reg  [7:0]  addr = 8'h00,
  output reg  [15:0] d = 16'h0000,
  output reg         wr = 1'b0,
  output reg         req = 1'b0,
  input  wire [15:0] q,
  input  wire        ack
);

  localparam integer N = 32;                  // writes (and reads) per block
  localparam integer TIMEOUT_C28 = 3000000;   // a request unanswered this long is lost

  // written by the bench
  reg     go1 = 1'b0, go2 = 1'b0;
  // read by the bench
  reg     b1_done = 1'b0, done = 1'b0;
  integer errors = 0;

  integer gap = 4;
  initial if (!$value$plusargs("AKI_GAP=%d", gap)) gap = 4;

  // the host's re-arm: the clk_114 cycle of the last EnableInterrupts write
  integer ena_cyc = 0, ena_n = 0;
  always @(posedge clk114) if (ena_wr) begin
    ena_cyc <= cyc;
    ena_n <= ena_n + 1;
  end

  function [7:0] req_addr(input integer b, input integer i);
    req_addr = 8'h20 + 8'h80 * b[7:0] + i[7:0];
  endfunction

  function [15:0] req_data(input integer b, input integer i);
    reg [31:0] t;
    begin
      t = (i + 1) * 32'h9E37;
      req_data = t[15:0] ^ (b == 1 ? 16'hC3A5 : 16'h0000);
    end
  endfunction

  integer n_req = 0;

  // one request: raise, hold until ack, drop, wait for the re-arm
  task request(input integer b, input integer k, input is_wr, input [7:0] a, input [15:0] dat, output [15:0] got);
    integer t_req, t_ack, to, ena0, rearm;
    reg     ack_seen, dma;
    begin
      // drive and sample on the falling clk_28 edge: half a cycle from cfide's
      // (rising-edge) sampling, no race in any simulator; amiga_ack is one
      // full clk_28 cycle wide, so the falling edge sees it
      @(negedge clk28);
      addr = a;
      d = dat;
      wr = is_wr;
      req = 1'b1;
      t_req = cyc;
      to = 0;
      ack_seen = 1'b0;
      while (!ack_seen && to < TIMEOUT_C28) begin
        @(negedge clk28);
        to = to + 1;
        if (ack === 1'b1) ack_seen = 1'b1;
      end
      t_ack = cyc;
      ena0 = ena_n;         // the ISR's EnableInterrupts comes after its DATA write (the ack)
      dma = busy;
      got = q;
      req = 1'b0;
      wr = 1'b0;
      if (!ack_seen) begin
        $display("BENCH ERROR at cycle %0d: bfm_akiko: request %0d/%0d (%0s addr %h) not acked in %0d clk_28 cycles (lost?)",
                 cyc, b, k, is_wr ? "write" : "read", a, TIMEOUT_C28);
        errors = errors + 1;
        got = 16'hxxxx;
      end else begin
        // the host re-arms its interrupt (EnableInterrupts) after the ack
        to = 0;
        while (ena_n == ena0 && to < TIMEOUT_C28) begin
          @(negedge clk28);
          to = to + 1;
        end
        if (ena_n == ena0) begin
          $display("BENCH ERROR at cycle %0d: bfm_akiko: request %0d/%0d: no EnableInterrupts write after the ack", cyc, b, k);
          errors = errors + 1;
          rearm = -1;
        end else begin
          rearm = ena_cyc - t_ack;
        end
        $display("=== AKIKO req %0d %0d %0s addr %h d %h q %h req %0d ack %0d lat %0d rearm %0d dma %0d",
                 b, k, is_wr ? "W" : "R", a, dat, got, t_req, t_ack, t_ack - t_req, rearm, dma);
        repeat (gap) @(negedge clk28);
      end
      n_req = n_req + 1;
    end
  endtask

  task akiko_write(input integer b, input integer k, input [7:0] a, input [15:0] dat);
    reg [15:0] ign;
    begin
      request(b, k, 1'b1, a, dat, ign);
    end
  endtask

  task akiko_read(input integer b, input integer k, input [7:0] a, output [15:0] dat);
    begin
      request(b, k, 1'b0, a, 16'h5A5A, dat);   // d is not used by a read (the ISR still reads DATA)
    end
  endtask

  task block(input integer b);
    integer i, c0;
    reg [15:0] rd;
    begin
      c0 = cyc;
      for (i = 0; i < N; i = i + 1) akiko_write(b, i, req_addr(b, i), req_data(b, i));
      for (i = 0; i < N; i = i + 1) begin
        akiko_read(b, N + i, req_addr(b, i), rd);
        if (rd !== 16'h0000 && rd !== 16'hxxxx) begin
          $display("BENCH ERROR at cycle %0d: bfm_akiko: read %0d/%0d returned %h, the host answers 0", cyc, b, N + i, rd);
          errors = errors + 1;
        end
      end
      $display("=== AKIKO block %0d from cycle %0d to cycle %0d", b, c0, cyc);
    end
  endtask

  initial begin
    wait (go1 === 1'b1);
    block(0);
    b1_done = 1'b1;
    wait (go2 === 1'b1);
    block(1);
    done = 1'b1;
  end

endmodule
