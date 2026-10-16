// L1 bench memory + sim MMIO, slave side of the 832 req/ack bus contract.
//
// Memory: 1 MB of big-endian words (byte A+0 in bits 31:24: the lane
// rule's memory side, as rtl/sdram/sdram_ctrl.v), 0x00000000-0x000FFFFF,
// loaded from +HEX=<file> (one BE hex word per line, file byte i in lane i =
// the romgen order, no "@" addresses), word 0 first; everything else 0.  A
// missing or unreadable file, or one larger than 1 MB, ends the run at time 0
// with "=== FAIL" (no silent all-zero memory).  sel[i] writes byte A+i, i.e.
// bits 31-8i:24-8i.
//
// Latency (cycles from the accepting cycle to the ack cycle):
//   addr < 0x2000 (ROM region)  1 + ROMWS   (+ROMWS=, default 1)
//   other memory                1 + WS      (+WS=,    default 3)
//   hw window (addr[23] = 1)    4
// A request is accepted only in a cycle with req = 1 and ack = 0.  ack is
// high for one cycle; d is valid in that cycle.
//
// hw window: 16-bit registers, value = q[15:0] / d = {16'h0, value}, no
// swap, decoded on addr[7:2]; unmapped reads return 0, unmapped writes are
// ignored.
//   0xFFFFFF00 TIME     W   print "=== TIME <value> cycle <n>"
//   0xFFFFFF04 DONE     W   done = 1, done_code = value
//   0xFFFFFF08 IRQ_AT   W   interrupt event <value> cycles later (one timer)
//   0xFFFFFF0C SCRATCH  R/W sel[0] -> bits 7:0, sel[1] -> bits 15:8
//   0xFFFFFFA0 INTR     W   bit 0 = enable; any access clears pending;
//                           an event sets pending if enabled (cfide-like)
//   0xFFFFFFF0 UART     W   character out ($write).  A read fails the run
//                           (uart_rd): cfide never acks a UART read, so on
//                           the real bus the CPU would hang; there is no
//                           TX-ready bit (cfide holds a write until the
//                           transmitter takes it).
// irq = pending.  Any memory access at or above 1 MB with addr[23] = 0
// prints "=== BAD ADDRESS" and raises bad_addr.
module mem_model (
  input  wire        clk,
  input  wire        rst,
  input  wire [31:2] addr,
  input  wire [31:0] q,
  input  wire [3:0]  sel,
  input  wire        wr,
  input  wire        req,
  output reg         ack,
  output reg  [31:0] d,
  output wire        irq,
  output reg         done,
  output reg  [15:0] done_code,
  output reg         bad_addr,
  output reg         uart_rd
);
  localparam MEMWORDS = 262144;          // 1 MB
  reg [31:0] mem [0:MEMWORDS-1];

  integer ws, romws, i, fd, rc, eof;
  reg [8*1024-1:0] hexfile;          // +HEX path, up to 1024 characters
  reg [31:0] w;
  initial begin
    if (!$value$plusargs("WS=%d", ws))       ws = 3;
    if (!$value$plusargs("ROMWS=%d", romws)) romws = 1;
    for (i = 0; i < MEMWORDS; i = i + 1) mem[i] = 32'h0;
    if ($value$plusargs("HEX=%s", hexfile)) begin : load
      fd = $fopen(hexfile, "r");
      if (fd == 0) begin
        $display("=== FAIL cannot open +HEX=%0s", hexfile);
        $finish;
        disable load;
      end
      // word by word: $readmemh would warn on every image shorter than 1 MB
      i = 0;
      rc = $fscanf(fd, "%h", w);
      while (rc == 1 && i < MEMWORDS) begin
        mem[i] = w;
        i = i + 1;
        rc = $fscanf(fd, "%h", w);
      end
      eof = $feof(fd);
      $fclose(fd);
      if (rc == 1 || !eof) begin
        $display("=== FAIL +HEX=%0s: %0s after word %0d", hexfile,
                 rc == 1 ? "more than 1 MB" : "not a hex word", i);
        $finish;
        disable load;
      end
      $display("=== MEMLOAD %0d words from %0s", i, hexfile);
    end else $display("=== WARNING no +HEX=<file>, memory is all zero");
    $display("=== MEMCFG WS=%0d ROMWS=%0d", ws, romws);
  end

  // ---- request acceptance and latency ----
  reg         busy;
  integer     cnt;
  reg  [31:2] a;
  reg  [31:0] wq;
  reg  [3:0]  ws_sel;
  reg         wwr;
  reg  [63:0] cycle;

  // hw registers
  reg  [15:0] scratch;
  reg         intr_ena, pending;
  integer     irq_cnt;
  assign irq = pending;

  function integer latency(input [31:2] ad);
    begin
      if (ad[23])                      latency = 4;
      else if ({ad, 2'b00} < 32'h2000) latency = 1 + romws;
      else                             latency = 1 + ws;
    end
  endfunction

  // perform the access at the ack: write memory/registers, return read data
  task do_access;
    reg [31:0] w;
    reg [7:0]  r;
    begin
      d <= 32'h0;
      if (a[23]) begin
        r = {a[7:2], 2'b00};
        if (r == 8'hA0) pending <= 1'b0;                 // any access clears
        if (wwr) begin
          case (r)
            8'h00: $display("=== TIME %0d cycle %0d", wq[15:0], cycle);
            8'h04: begin done <= 1'b1; done_code <= wq[15:0]; end
            8'h08: irq_cnt <= wq[15:0];
            8'h0C: begin
                     if (ws_sel[0]) scratch[7:0]  <= wq[7:0];
                     if (ws_sel[1]) scratch[15:8] <= wq[15:8];
                   end
            8'hA0: intr_ena <= wq[0];
            8'hF0: $write("%c", wq[7:0]);
            default: ;
          endcase
        end else begin
          case (r)
            8'h0C:   d <= {16'h0, scratch};
            8'hF0:   begin
                       $display("=== UART READ at cycle %0d: cfide never acks a read of 0xFFFFFFF0, the CPU would hang", cycle);
                       uart_rd <= 1'b1;
                     end
            default: d <= 32'h0;
          endcase
        end
      end else if (a[31:20] != 12'h0) begin
        $display("=== BAD ADDRESS %08x (%s) cycle %0d", {a, 2'b00}, wwr ? "write" : "read", cycle);
        bad_addr <= 1'b1;
      end else if (wwr) begin
        w = mem[a[19:2]];
        if (ws_sel[0]) w[31:24] = wq[31:24];
        if (ws_sel[1]) w[23:16] = wq[23:16];
        if (ws_sel[2]) w[15:8]  = wq[15:8];
        if (ws_sel[3]) w[7:0]   = wq[7:0];
        mem[a[19:2]] <= w;
      end else begin
        d <= mem[a[19:2]];
      end
    end
  endtask

  always @(posedge clk) begin
    if (rst) begin
      ack <= 1'b0; d <= 32'h0; busy <= 1'b0; cnt <= 0; cycle <= 64'd0;
      done <= 1'b0; done_code <= 16'h0; bad_addr <= 1'b0; uart_rd <= 1'b0;
      scratch <= 16'h0; intr_ena <= 1'b0; pending <= 1'b0; irq_cnt <= 0;
    end else begin
      cycle <= cycle + 64'd1;
      ack   <= 1'b0;

      // IRQ_AT timer: an event when it reaches 1 (N cycles after the write)
      if (irq_cnt != 0) begin
        irq_cnt <= irq_cnt - 1;
        if (irq_cnt == 1 && intr_ena) pending <= 1'b1;
      end

      if (!busy) begin
        if (req && !ack) begin
          // latched with blocking assignments: private to this block
          a = addr; wq = q; ws_sel = sel; wwr = wr;
          if (latency(addr) == 1) begin
            ack <= 1'b1;
            do_access;
          end else begin
            busy <= 1'b1;
            cnt  <= latency(addr) - 2;
          end
        end
      end else if (cnt == 0) begin
        ack  <= 1'b1;
        busy <= 1'b0;
        do_access;
      end else begin
        cnt <= cnt - 1;
      end
    end
  end
endmodule
