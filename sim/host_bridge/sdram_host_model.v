// sdram_host_model: the SDRAM controller's host port as hostcache sees it.
//
// Memory: 8 MB of 16-bit halfwords at host byte address 0 (mem[a >> 1],
// a = {addr, 2'b00}, addr[22:2] used), big endian: byte A+0 is the upper
// byte of halfword A.
//
// Request: ram_req (held by hostcache until ram_ack).  The model samples
// addr, wr, q and sel when it accepts the request and checks them unchanged
// at the ack (the bus contract: the master holds them until the ack).
//   latency  SLAT (+SLAT=, default 8) plus a random 0..SJIT (+SJIT=, default
//            0) clk_114 cycles from acceptance to the one-cycle ram_ack
//   write    at the ack; byte lanes as sdram_ctrl.v (slot1_dqm =
//            {!sel[0], !sel[1]}, dqm2 = {!sel[2], !sel[3]}):
//              sel[0]: q[31:24] -> mem[A/2][15:8]    (byte A+0)
//              sel[1]: q[23:16] -> mem[A/2][7:0]     (byte A+1)
//              sel[2]: q[15:8]  -> mem[A/2+1][15:8]  (byte A+2)
//              sel[3]: q[7:0]   -> mem[A/2+1][7:0]   (byte A+3)
//   read     an 8-halfword burst of the 4-word line, starting with the
//            requested word, wrapping inside the line: word0.hi on the ack
//            cycle, then word0.lo, word1.hi, ... (tb_832_dmode.v's order,
//            what hostcache's zFILL states expect)
//
// Preload: +SDRAM_HEX=<file>, $readmemh of big-endian 32-bit words, "@"
// addresses in words (byte address / 4), the first 1 MB (PRE_WORDS).  The
// rest of memory starts at 0.  The path may be up to 1024 characters; a file
// that cannot be opened ends the run at time 0 with "=== FAIL ...".
//
// Simulation only.
`timescale 1ns/1ps

module sdram_host_model #(
  parameter PRE_WORDS = 262144     // preload window: 1 MB from address 0
) (
  input  wire        clk,
  input  wire        ram_req,
  output reg         ram_ack,
  output reg  [15:0] ram_d,
  input  wire [31:2] addr,
  input  wire [31:0] q,
  input  wire [3:0]  sel,
  input  wire        wr
);

  localparam HW = 22;               // halfword index bits: 8 MB

  reg [15:0] mem [0:(1 << HW) - 1];
  reg [31:0] pre [0:PRE_WORDS - 1];

  integer slat = 8, sjit = 0, seed = 1;
  integer i, fd;
  reg [8*1024-1:0] hexfile;          // +SDRAM_HEX path, up to 1024 characters

  integer    errors = 0;            // bus contract violations seen
  integer    n_rd = 0, n_wr = 0;

  initial begin
    if (!$value$plusargs("SLAT=%d", slat)) slat = 8;
    if (!$value$plusargs("SJIT=%d", sjit)) sjit = 0;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    i = $urandom(seed);
    for (i = 0; i < (1 << HW); i = i + 1) mem[i] = 16'h0000;
    if ($value$plusargs("SDRAM_HEX=%s", hexfile)) begin : preload
      fd = $fopen(hexfile, "r");
      if (fd == 0) begin
        $display("=== FAIL cannot open +SDRAM_HEX=%0s", hexfile);
        $finish;
        disable preload;
      end
      $fclose(fd);
      for (i = 0; i < PRE_WORDS; i = i + 1) pre[i] = 32'hxxxxxxxx;
      $readmemh(hexfile, pre);
      for (i = 0; i < PRE_WORDS; i = i + 1)
        if (^pre[i] !== 1'bx) begin
          mem[2 * i]     = pre[i][31:16];
          mem[2 * i + 1] = pre[i][15:0];
        end
    end
  end

  // halfword read for the bench's checks (byte address a)
  function [15:0] hw_at(input [31:0] a);
    hw_at = mem[a[HW:1]];
  endfunction

  integer       lat_left = -1, burst = -1;
  reg   [HW-1:0] b_hw;               // halfword index of the requested word
  reg   [1:0]   b_word;
  reg   [31:0]  b_q;
  reg   [3:0]   b_sel;
  reg   [31:2]  b_addr;
  reg           b_wr;

  // halfword k (0..7) of the burst
  function [HW-1:0] burst_hw(input integer k);
    burst_hw = {b_hw[HW-1:3], 3'b000} + (((b_word + (k >> 1)) & 3) << 1) + (k & 1);
  endfunction

  always @(posedge clk) begin
    ram_ack <= 1'b0;
    if (burst >= 0) begin
      burst = burst + 1;
      if (burst < 8) ram_d <= mem[burst_hw(burst)];
      else           burst = -1;
    end else if (lat_left > 0) begin
      lat_left = lat_left - 1;
    end else if (lat_left == 0) begin
      lat_left = -1;
      ram_ack <= 1'b1;
      if (addr !== b_addr || wr !== b_wr || (b_wr && (q !== b_q || sel !== b_sel))) begin
        $display("=== BUS VIOLATION sdram model: request changed before its ack at %t (addr %h->%h wr %b->%b q %h->%h sel %b->%b)",
                 $time, {b_addr, 2'b00}, {addr, 2'b00}, b_wr, wr, b_q, q, b_sel, sel);
        errors = errors + 1;
      end
      if (b_wr) begin
        n_wr = n_wr + 1;
        if (b_sel[0]) mem[b_hw][15:8]     = b_q[31:24];
        if (b_sel[1]) mem[b_hw][7:0]      = b_q[23:16];
        if (b_sel[2]) mem[b_hw + 1][15:8] = b_q[15:8];
        if (b_sel[3]) mem[b_hw + 1][7:0]  = b_q[7:0];
      end else begin
        n_rd = n_rd + 1;
        burst = 0;
        ram_d <= mem[burst_hw(0)];
      end
    end else if (ram_req && !ram_ack && burst < 0) begin
      b_addr = addr;
      b_hw   = {addr[HW:2], 1'b0};
      b_word = addr[3:2];
      b_wr   = wr;
      b_q    = q;
      b_sel  = sel;
      if (addr[31:23] != 9'd0) begin
        $display("=== BUS VIOLATION sdram model: request outside 0..0x7FFFFF: %h at %t", {addr, 2'b00}, $time);
        errors = errors + 1;
      end
      lat_left = slat + (sjit ? ($urandom % (sjit + 1)) : 0);
    end
  end

endmodule
