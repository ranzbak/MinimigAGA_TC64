`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////
//
// mem_stub.v -- behavioural model of the DDR3 island's native 128-bit port,
//               for sim/ddr3/ddr3_fastram_tb.v.  Runs on clk_mem (100 MHz).
//
// It stands in for rtl/ddr3/ddr3_top.v + core_ddr3_controller: same handshake,
// random accept delay and random response latency, so the CDC and the cache
// backend are exercised over a wide range of timings.
//
// Interface (as named in findings/ddr3/implementation-plan.md section 2):
//   req_valid   held by the requester until req_accept
//   req_wr      16 byte enables, 1 = write that byte; all zero = read
//   req_addr    byte address, 16-byte aligned for line accesses
//   req_wdata   128 bits, byte n of the line at bits [8n+7 : 8n]
//   req_accept  one cycle, this request has been taken
//   resp_valid  one cycle per request -- READS AND WRITES ALIKE
//   resp_rdata  valid with resp_valid on a read; don't care on a write
//   init_done   goes high INIT_DELAY clk_mem cycles after reset is released
//
// Storage is sparse: an open-addressed hash table of 16-byte lines covering
// the full 256 MB address space.  Only the lines actually touched cost
// anything.  Untouched lines read back as 128'h0 (like a zeroed DRAM), which
// keeps the reference model in the testbench simple.
//
//////////////////////////////////////////////////////////////////////////////

module mem_stub #(
  parameter integer INIT_DELAY  = 200,     // clk cycles from reset release
  parameter integer ACCEPT_MAX  = 5,       // random accept delay, 0..ACCEPT_MAX
  parameter integer LAT_MIN     = 5,       // random response latency, cycles
  parameter integer LAT_MAX     = 30,
  parameter integer TBL_BITS    = 14,      // 16384 line slots
  parameter integer SEED        = 32'h1234_5678
) (
  input  wire           clk,
  input  wire           rst,               // active high
  input  wire           req_valid,
  input  wire [ 16-1:0] req_wr,
  input  wire [ 32-1:0] req_addr,
  input  wire [128-1:0] req_wdata,
  output reg            req_accept,
  output reg            resp_valid,
  output reg  [128-1:0] resp_rdata,
  output reg            init_done
);

localparam integer TBL_SIZE = (1 << TBL_BITS);
localparam integer ADDR_BITS = 28;                 // 256 MB
localparam integer LINE_BITS = ADDR_BITS - 4;      // line index bits

// ---------------------------------------------------------------- storage
reg                  tbl_valid [0:TBL_SIZE-1];
reg [LINE_BITS-1:0]  tbl_tag   [0:TBL_SIZE-1];
reg [128-1:0]        tbl_data  [0:TBL_SIZE-1];
integer              tbl_used;

integer k;
initial begin
  for (k = 0; k < TBL_SIZE; k = k + 1) begin
    tbl_valid[k] = 1'b0;
    tbl_tag[k]   = {LINE_BITS{1'b0}};
    tbl_data[k]  = 128'd0;
  end
  tbl_used = 0;
end

function [TBL_BITS-1:0] hash;
  input [LINE_BITS-1:0] line;
  reg [31:0] h;
  begin
    h = {{(32-LINE_BITS){1'b0}}, line} * 32'h9E37_79B1;
    hash = h[31 -: TBL_BITS];
  end
endfunction

// find the slot for a line, allocating on demand.  s_out = -1 if absent and
// alloc is 0, or if the table is full.
task find_slot;
  input  [LINE_BITS-1:0] line_in;
  input                  alloc;
  output integer         s_out;
  integer s, n;
  reg     done;
  begin
    s = hash(line_in);
    done  = 1'b0;
    s_out = -1;
    for (n = 0; n < TBL_SIZE && !done; n = n + 1) begin
      if (tbl_valid[s] && tbl_tag[s] == line_in) begin
        s_out = s;
        done  = 1'b1;
      end else if (!tbl_valid[s]) begin
        s_out = alloc ? s : -1;
        done  = 1'b1;
      end else begin
        s = (s + 1) % TBL_SIZE;
      end
    end
  end
endtask

// backdoor access for the testbench
task peek;                                        // read a whole line
  input  [ 32-1:0] addr;
  output [128-1:0] data;
  integer s;
  begin
    find_slot(addr[ADDR_BITS-1:4], 1'b0, s);
    data = (s < 0) ? 128'd0 : tbl_data[s];
  end
endtask

task poke;                                        // write a whole line
  input [ 32-1:0] addr;
  input [128-1:0] data;
  integer s;
  begin
    find_slot(addr[ADDR_BITS-1:4], 1'b1, s);
    if (s < 0) begin
      $display("mem_stub: TABLE FULL at %h", addr);
      $finish;
    end
    if (!tbl_valid[s]) begin
      tbl_valid[s] = 1'b1;
      tbl_tag[s]   = addr[ADDR_BITS-1:4];
      tbl_used     = tbl_used + 1;
    end
    tbl_data[s] = data;
  end
endtask

// ---------------------------------------------------------------- timing
localparam [1:0] M_IDLE = 2'd0, M_WAIT = 2'd1, M_RUN = 2'd2;

reg  [  2-1:0] mstate;
integer        rnd;
integer        delay;
reg  [ 16-1:0] wr_q;
reg  [ 32-1:0] adr_q;
reg  [128-1:0] wd_q;
reg  [128-1:0] line;
integer        s_idx;
integer        b;
integer        init_cnt;

initial begin
  rnd        = SEED;
  mstate     = M_IDLE;
  req_accept = 1'b0;
  resp_valid = 1'b0;
  resp_rdata = 128'd0;
  init_done  = 1'b0;
  init_cnt   = 0;
  delay      = 0;
end

always @ (posedge clk) begin
  if (rst) begin
    mstate     <= M_IDLE;
    req_accept <= 1'b0;
    resp_valid <= 1'b0;
    init_done  <= 1'b0;
    init_cnt   <= 0;
  end else begin
    req_accept <= 1'b0;
    resp_valid <= 1'b0;

    if (init_cnt < INIT_DELAY) init_cnt <= init_cnt + 1;
    else                       init_done <= 1'b1;

    case (mstate)
      M_IDLE : begin
        if (req_valid) begin
          wr_q   <= req_wr;
          adr_q  <= req_addr;
          wd_q   <= req_wdata;
          delay  <= ({$random(rnd)} % (ACCEPT_MAX + 1));
          mstate <= M_WAIT;
        end
      end

      M_WAIT : begin                       // random accept delay 0..ACCEPT_MAX
        if (delay == 0) begin
          req_accept <= 1'b1;
          delay      <= LAT_MIN + ({$random(rnd)} % (LAT_MAX - LAT_MIN + 1));
          mstate     <= M_RUN;
        end else begin
          delay <= delay - 1;
        end
      end

      M_RUN : begin                        // random response latency
        if (delay == 0) begin
          // perform the access at the moment the response is produced
          find_slot(adr_q[ADDR_BITS-1:4], (wr_q != 16'h0000), s_idx);
          line  = (s_idx < 0) ? 128'd0 : tbl_data[s_idx];
          if (wr_q != 16'h0000) begin
            if (s_idx < 0) begin
              $display("mem_stub: TABLE FULL at %h", adr_q);
              $finish;
            end
            if (!tbl_valid[s_idx]) begin
              tbl_valid[s_idx] = 1'b1;
              tbl_tag[s_idx]   = adr_q[ADDR_BITS-1:4];
              tbl_data[s_idx]  = 128'd0;
              tbl_used         = tbl_used + 1;
              line             = 128'd0;
            end
            for (b = 0; b < 16; b = b + 1)
              if (wr_q[b]) line[8*b +: 8] = wd_q[8*b +: 8];
            tbl_data[s_idx] = line;
            resp_rdata <= 128'hxxxx_xxxx_xxxx_xxxx_xxxx_xxxx_xxxx_xxxx;
          end else begin
            resp_rdata <= line;
          end
          resp_valid <= 1'b1;
          mstate     <= M_IDLE;
        end else begin
          delay <= delay - 1;
        end
      end

      default : mstate <= M_IDLE;
    endcase
  end
end

endmodule
