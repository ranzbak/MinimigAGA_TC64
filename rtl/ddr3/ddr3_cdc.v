`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////
//
// ddr3_cdc.v -- toggle-handshake request/response crossing between the
//               Minimig system clock (clk_sys, 113.4375 MHz) and the DDR3
//               island clock (clk_mem, 100 MHz).  The two clocks are
//               asynchronous: unrelated sources, unrelated phases.
//
// Used by rtl/ddr3/ddr3_fastram.v (source side, clk_sys) to reach the native
// 128-bit port of rtl/ddr3/ddr3_top.v (destination side, clk_mem).
//
// ---------------------------------------------------------------------------
// PROTOCOL
// ---------------------------------------------------------------------------
//
//   source (clk_sys)                          destination (clk_mem)
//   ----------------                          ---------------------
//   src_ready = 1                             idle, req_tgl == ack_tgl
//   src_req pulse  -> latch {rd,be,addr,wd}
//                     req_tgl ^= 1     ---2FF-->  edge detected
//                     src_ready = 0               req_valid = 1 (held)
//                                                 wait req_accept
//                                                 wait resp_valid
//                                                 rdata_r <= resp_rdata
//                                     <--2FF---   ack_tgl ^= 1
//                     src_rdata <= rdata_r
//                     src_done pulse
//                     src_ready = 1
//
// Exactly one request is in flight.  src_req is only honoured when src_ready
// is high; the caller must qualify it.
//
// ---------------------------------------------------------------------------
// CDC INVARIANT  (this is what makes the wide buses safe to cross)
// ---------------------------------------------------------------------------
//
//   The payload registers {req_rd, req_wr, req_addr, req_wdata} on the source
//   side, and the response register rdata_r on the destination side, are ONLY
//   written while req_toggle == ack_toggle as seen on the source side (i.e.
//   while src_ready is high / the far side is idle).  They are therefore
//   stable for at least the whole round trip through both two-flop
//   synchronisers -- several source and several destination clock periods --
//   before and after the far side samples them.  No bus bit is ever sampled
//   while it can be changing, so no bus needs to be synchronised: only the
//   two single-bit toggles cross through synchronisers.
//
//   Corollary for rdata_r: it is written on the same clk_mem edge that flips
//   ack_tgl.  The source cannot see that flip for at least two clk_mem edges
//   plus two clk_sys edges, so rdata_r is settled long before src_rdata
//   latches it, and it is not touched again until the next request completes.
//
// ---------------------------------------------------------------------------
// CONSTRAINTS THE INTEGRATOR MUST ADD  (ddr3.xdc)
// ---------------------------------------------------------------------------
//
//   # the island and the Minimig clock tree are unrelated
//   set_clock_groups -asynchronous \
//       -group [get_clocks {ddr3_clk100 ddr3_clk400 ddr3_clk400_90 ddr3_clk200}] \
//       -group [get_clocks {clk_114 dll_28 clk_sd_114}]
//
//   # the payload buses are quasi-static: bound the skew, do not time them
//   set_max_delay -datapath_only -from [get_cells {*/req_rd_r*  */req_wr_r*
//                                                  */req_adr_r* */req_wd_r*}] \
//                 -to   [get_clocks ddr3_clk100] 8.000
//   set_max_delay -datapath_only -from [get_cells {*/rdata_r*}] \
//                 -to   [get_clocks clk_114] 8.000
//   set_false_path -from [get_cells {*/req_tgl*}] -to [get_cells {*/req_sync_reg[0]*}]
//   set_false_path -from [get_cells {*/ack_tgl*}] -to [get_cells {*/ack_sync_reg[0]*}]
//
//   (the two set_false_path lines are optional -- ASYNC_REG plus the async
//    clock group already covers the toggles; the set_max_delay lines are NOT
//    optional, they are what keeps the bus skew below one destination period.)
//
// ---------------------------------------------------------------------------
// RESET
// ---------------------------------------------------------------------------
//
//   src_rst (clk_sys, active high) does NOT clear req_tgl.  It only abandons
//   the source side's interest in an outstanding request.  Because src_ready
//   also requires ack_sync == req_tgl, the source will not start a new
//   request until the abandoned one has drained through the memory and the
//   destination has flipped ack_tgl.  A reset in the middle of a transaction
//   therefore costs one discarded response and nothing else.
//
//   dst_rst (clk_mem, active high) realigns ack_tgl to the synchronised
//   source toggle, so the pair comes out of reset consistent.  It must only
//   be used as a power-on reset, together with src_rst; asserting it alone
//   while the source has a request outstanding would complete that request
//   with stale read data.
//
//////////////////////////////////////////////////////////////////////////////

module ddr3_cdc (
  // ---- source side, clk_sys (113.4375 MHz) --------------------------------
  input  wire         src_clk,
  input  wire         src_rst,        // active high, synchronous to src_clk
  output wire         src_ready,      // safe to issue a request this cycle
  input  wire         src_req,        // one-cycle pulse, only when src_ready
  input  wire         src_rd,         // 1 = read, 0 = write
  input  wire [ 16-1:0] src_wr_be,    // byte enables, 1 = write that byte
  input  wire [ 32-1:0] src_addr,     // byte address, 16-byte aligned
  input  wire [128-1:0] src_wdata,
  output reg            src_done,     // one-cycle pulse, response captured
  output reg  [128-1:0] src_rdata,    // valid at src_done, held until next

  // ---- destination side, clk_mem (100 MHz) --------------------------------
  input  wire         dst_clk,
  input  wire         dst_rst,        // active high, power-on only
  output wire         req_valid,      // held until req_accept
  output wire [ 16-1:0] req_wr,       // all zero = read
  output wire [ 32-1:0] req_addr,
  output wire [128-1:0] req_wdata,
  input  wire         req_accept,
  input  wire         resp_valid,     // one pulse per request, read or write
  input  wire [128-1:0] resp_rdata
);


//// destination side state (declared first: referenced by the source side) ////

localparam [1:0]
  D_IDLE = 2'd0,
  D_REQ  = 2'd1,
  D_RESP = 2'd2;

reg [  2-1:0] dst_state = D_IDLE;
reg           ack_tgl   = 1'b0;
reg           req_seen  = 1'b0;
reg [128-1:0] rdata_r   = 128'd0;


//// source side ////

reg           req_tgl = 1'b0;
reg           busy    = 1'b0;
reg           req_rd_r  = 1'b0;
reg [ 16-1:0] req_wr_r  = 16'd0;
reg [ 32-1:0] req_adr_r = 32'd0;
reg [128-1:0] req_wd_r  = 128'd0;

// two-flop synchroniser: destination ack toggle -> source domain
(* ASYNC_REG = "TRUE" *) reg [2-1:0] ack_sync = 2'b00;
always @ (posedge src_clk) ack_sync <= #1 {ack_sync[0], ack_tgl};

// idle when the toggles agree and we are not holding a request
assign src_ready = !busy && (ack_sync[1] == req_tgl);

always @ (posedge src_clk) begin
  src_done <= #1 1'b0;
  if (src_rst) begin
    // do not touch req_tgl: let the outstanding request drain (see header)
    busy <= #1 1'b0;
  end else if (!busy) begin
    if (src_req && (ack_sync[1] == req_tgl)) begin
      req_rd_r  <= #1 src_rd;
      req_wr_r  <= #1 src_wr_be;
      req_adr_r <= #1 src_addr;
      req_wd_r  <= #1 src_wdata;
      req_tgl   <= #1 ~req_tgl;
      busy      <= #1 1'b1;
    end
  end else begin
    if (ack_sync[1] == req_tgl) begin
      src_rdata <= #1 rdata_r;
      src_done  <= #1 1'b1;
      busy      <= #1 1'b0;
    end
  end
end


//// destination side ////

// two-flop synchroniser: source request toggle -> destination domain
(* ASYNC_REG = "TRUE" *) reg [2-1:0] req_sync = 2'b00;
always @ (posedge dst_clk) req_sync <= #1 {req_sync[0], req_tgl};

// the payload buses cross combinationally from the source-side registers;
// they are quasi-static (see the CDC invariant in the header).
assign req_valid = (dst_state == D_REQ);
assign req_wr    = req_rd_r ? 16'h0000 : req_wr_r;
assign req_addr  = req_adr_r;
assign req_wdata = req_wd_r;

always @ (posedge dst_clk) begin
  if (dst_rst) begin
    dst_state <= #1 D_IDLE;
    req_seen  <= #1 req_sync[1];
    ack_tgl   <= #1 req_sync[1];
  end else begin
    case (dst_state)
      D_IDLE : begin
        if (req_sync[1] != req_seen) begin
          req_seen  <= #1 req_sync[1];
          dst_state <= #1 D_REQ;
        end
      end
      D_REQ : begin
        if (req_accept) dst_state <= #1 D_RESP;
      end
      D_RESP : begin
        if (resp_valid) begin
          rdata_r   <= #1 resp_rdata;
          ack_tgl   <= #1 ~ack_tgl;
          dst_state <= #1 D_IDLE;
        end
      end
      default : dst_state <= #1 D_IDLE;
    endcase
  end
end

endmodule
