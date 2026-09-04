`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////
//
// ddr3_fastram.v -- Zorro-III fast RAM on the board's DDR3.
//
// The front end is rtl/sdram/cpu_cache_new.v, instantiated exactly as
// rtl/sdram/sdram_ctrl.v does (same parameters, same CPU handshake, snoop
// tied off, cache never inhibited).  Only the SDRAM backend is replaced: the
// eight-word cache line becomes one 128-bit DDR3 burst, carried to the
// 100 MHz island by rtl/ddr3/ddr3_cdc.v.
//
// See findings/ddr3/design.md (architecture items 1 and 2, decisions D4-D6)
// and findings/ddr3/implementation-plan.md section 3.
//
// ---------------------------------------------------------------------------
// CPU PORT
// ---------------------------------------------------------------------------
//
// Identical to sdram_ctrl's:
//   cpuAddr[25:1]  must be stable ONE CYCLE BEFORE cpustate[2] goes low.
//                  It is registered here into cpuAddr_r, exactly as
//                  sdram_ctrl does, and cpuAddr_r is what addresses the DDR3.
//   cpustate[2]    chip select, active low (cpuCSn).
//   cpustate[1:0]  00 = instruction read, 10 = data read, 11 = write.
//   cpustate[6]    longword (32-bit) access flag (cpuLongword).
//   cpuU, cpuL     byte selects, active low.
//   cpuena         access complete (level), = cache hit/ack.
//
//   longword_en    = cpuLongword && cpuAddr_r[3:1] != 3'b111 && write
//                    -- exactly the sdram_ctrl expression.  The [3:1]!=111
//                    guard is what guarantees a 32-bit write never straddles
//                    a cache line, so it is always ONE DDR3 request.
//
//   ddr_ready      init/reset done.  The wrapper must hold the CPU off this
//                  port until it is high; it is NOT a per-access ready
//                  (that is cpuena).
//
// ---------------------------------------------------------------------------
// ADDRESS MAP
// ---------------------------------------------------------------------------
//
// D6, identity: DDR3 byte address = CPU byte address.  cpuAddr is [25:1],
// i.e. a 16-bit word address, so the byte address is {cpuAddr, 1'b0} and the
// line address is {cpuAddr_r[25:4], 4'b0000} zero-extended to 32 bits.
//
// ---------------------------------------------------------------------------
// WORD ORDER AND BYTE LANE MAPPING  (must match cpu_cache_new exactly)
// ---------------------------------------------------------------------------
//
// A line is 8 x 16-bit words.  Word k (k = 0..7) of the line lives at byte
// offset 2*k within the 16-byte line and occupies bits [16*k+15 : 16*k] of
// the 128-bit bus.  The low byte of a word is at the LOWER bit index:
//
//     bit    127..112 111..96  95..80  79..64  63..48  47..32  31..16  15..0
//     word      7        6       5       4       3       2       1       0
//     bytes   15,14    13,12   11,10    9,8     7,6     5,4     3,2     1,0
//              ^ hi,lo of each word: word k = {byte 2k+1, byte 2k}
//
// req_wr[n] enables byte n of the line, i.e. byte address {line, n}.  So
// word k's low byte is req_wr[2*k] and its high byte is req_wr[2*k+1].
// The same mapping is used for reads and writes.
//
// READ BURST ORDER -- evidence from rtl/sdram/cpu_cache_new.v:
//   * CPU_SM_FILL1 (line ~464) writes the FIRST word delivered with
//     sdr_read_ack into cpu_cacheline_lo/hi[cpu_adr[3:1]].  So the first
//     word must be word index cpuAddr_r[3:1] of the line, not word 0.
//   * CPU_SM_FILL2 (line ~509) writes each subsequent word into
//     cpu_cacheline_lo/hi[cpu_sm_adr_next[2:0]] where
//        cpu_sm_adr_next = {cpu_sm_adr[10:3], cpu_sm_adr[2:0] + 2'b01}
//     (line ~63).  The increment is on the low 3 bits only, so it WRAPS
//     inside the 8-word line.
//   * The 8 acks must be back to back: CPU_SM_FILL2 leaves for CPU_SM_IDLE
//     as soon as it sees a cycle without sdr_read_ack (once the CPU has
//     been acked), which would abandon the rest of the line.
//   That is the SDRAM's wrapped burst order, and it is what this module
//   reproduces from the single 128-bit response.
//
// WRITES -- evidence from rtl/sdram/cpu_cache_new.v and sdram_ctrl.v:
//   * CPU_SM_IDLE (line ~319): sdr_adr <= cpu_adr[25:1],
//     sdr_dqm_w <= {2'b11, ~cpu_bs}, sdr_dat_w <= {cpu_dat_w, cpu_dat_w}.
//     For a 16-bit write the upper half of the mask is 2'b11 = both bytes
//     masked off, so only the word at sdr_adr[3:1] is written.
//   * CPU_SM_WRITE_32BIT (line ~346): sdr_dqm_w[3:2] <= ~cpu_bs and
//     sdr_dat_w[31:16] <= cpu_dat_w for the SECOND word of a longword.
//   * sdram_ctrl issues that as two SDRAM column writes: word sdr_adr[3:1]
//     with dqm = sdr_dqm_w[1:0] and data sdr_dat_w[15:0] (ph0), then word
//     sdr_adr[3:1]+1 with dqm = sdr_dqm_w[3:2] and data sdr_dat_w[31:16]
//     (ph2).  sdr_dqm_w is ACTIVE LOW: 0 = write that byte.
//   Here both words go out in ONE 128-bit request; the 16 byte enables are
//   built from the two dqm halves.  A 32-bit write is therefore one request
//   with two adjacent words, never two requests -- and it can never wrap,
//   because longword_en excludes cpuAddr_r[3:1] == 3'b111.
//
// ---------------------------------------------------------------------------
// BACKEND
// ---------------------------------------------------------------------------
//
// Exactly one request in flight.  Writes have priority over reads, which
// preserves program order: cpu_cache_new can have a posted write outstanding
// (sdr_write_req still high) when a read miss raises sdr_read_req, and the
// write is the older access.  sdr_write_ack is a one-cycle pulse issued when
// the payload has been copied into this module, so the write is posted and
// the CPU is not stalled for the DDR3 round trip; the payload is latched, so
// cpu_cache_new is free to change sdr_dat_w/sdr_dqm_w immediately after.
//
//////////////////////////////////////////////////////////////////////////////

module ddr3_fastram (
  // ---- system, clk_sys (113.4375 MHz) -------------------------------------
  input  wire           sysclk,
  input  wire           reset_in,        // active low, as in sdram_ctrl
  input  wire           cache_rst,       // active low, as in sdram_ctrl
  input  wire           cacheline_clr,
  input  wire [  4-1:0] cpu_cache_ctrl,
  output wire           ddr_ready,       // init + reset done

  // ---- CPU port, identical to sdram_ctrl's --------------------------------
  input  wire    [25:1] cpuAddr,
  input  wire [  7-1:0] cpustate,
  input  wire           cpuL,
  input  wire           cpuU,
  input  wire [ 16-1:0] cpuWR,
  output wire [ 16-1:0] cpuRD,
  output wire           cpuena,

  // ---- memory island port, clk_mem (100 MHz) ------------------------------
  input  wire           clk_mem,
  input  wire           init_done,       // island calibration complete
  output wire           req_valid,
  output wire [ 16-1:0] req_wr,          // byte enables, 1 = write; 0 = read
  output wire [ 32-1:0] req_addr,        // byte address, 16-byte aligned
  output wire [128-1:0] req_wdata,
  input  wire           req_accept,
  input  wire           resp_valid,
  input  wire [128-1:0] resp_rdata
);


//// local signals ////

wire          ccachehit;
wire          cpuLongword;
wire          cpuCSn;
wire          longword_en;

reg  [26-1:1] cpuAddr_r;      // registered CPU address, see header

// cache backend handshake
wire          cache_req;      // sdr_read_req  from the cache
reg           readcache_fill; // sdr_read_ack  to   the cache
reg  [16-1:0] sdr_dat_r;      // read data     to   the cache
wire [26-1:1] writebufferAddr;// sdr_adr       from the cache
wire [32-1:0] writebufferWR;  // sdr_dat_w     from the cache
wire [ 4-1:0] writebuffer_dqm;// sdr_dqm_w     from the cache (active low)
wire          writebuffer_req;// sdr_write_req from the cache
reg           writebuffer_ack;// sdr_write_ack to   the cache

// reset / init
reg  [ 8-1:0] reset_cnt;
reg           reset;
(* ASYNC_REG = "TRUE" *) reg [2-1:0] init_sync;

// CDC
wire          cdc_ready;
reg           cdc_req;
reg           cdc_rd;
reg  [ 16-1:0] cdc_be;
reg  [ 32-1:0] cdc_addr;
reg  [128-1:0] cdc_wdata;
wire           cdc_done;
wire [128-1:0] cdc_rdata;

// backend FSM
localparam [1:0]
  B_IDLE    = 2'd0,
  B_WRITE   = 2'd1,
  B_READ    = 2'd2,
  B_DELIVER = 2'd3;

reg  [ 2-1:0] bstate;
reg  [ 3-1:0] burst_cnt;
reg  [ 3-1:0] burst_first;

wire [16-1:0] cpu_dat_r_w;   // cpu_cache_new read data


//// misc signals ////

always @ (posedge sysclk) cpuAddr_r <= #1 cpuAddr;

assign cpuLongword = cpustate[6];
assign cpuCSn      = cpustate[2];
assign longword_en = cpuLongword && cpuAddr_r[3:1] != 3'b111 && cpustate[1:0] == 2'b11;
assign cpuena      = ccachehit;
assign cpuRD       = cpu_dat_r_w;


//// reset and init ////
// hold the cache in reset until the island reports calibration complete, then
// run sdram_ctrl's style of settling counter before releasing the CPU.

always @ (posedge sysclk) init_sync <= #1 {init_sync[0], init_done};

always @ (posedge sysclk) begin
  if (!reset_in) begin
    reset_cnt <= #1 8'd0;
    reset     <= #1 1'b0;
  end else if (init_sync[1]) begin
    if (reset_cnt == 8'hff) reset <= #1 1'b1;
    else                    reset_cnt <= #1 reset_cnt + 8'd1;
  end
end

assign ddr_ready = reset;


//// cpu cache ////
// identical parameters and wiring to the instance in rtl/sdram/sdram_ctrl.v,
// with the snoop port tied off and the cache never inhibited.

cpu_cache_new cpu_cache (
  .clk              (sysclk),                     // clock
  .rst              (!reset || !cache_rst),       // cache reset
  .cache_en         (1'b1),                       // cache enable
  .cpu_cache_ctrl   (cpu_cache_ctrl),             // CPU cache control
  .cache_inhibit    (1'b0),                       // cache inhibit
  .cacheline_clr    (cacheline_clr),
  .cpu_cs           (!cpuCSn),                    // cpu activity
  .cpu_adr          ({cpuAddr, 1'b0}),            // cpu address
  .cpu_bs           ({!cpuU, !cpuL}),             // cpu byte selects
  .cpu_32bit        (longword_en),                // cpu 32 bit write
  .cpu_we           (&cpustate[1:0]),             // cpu write
  .cpu_ir           (!(|cpustate[1:0])),          // cpu instruction read
  .cpu_dr           (cpustate[1] && !cpustate[0]),// cpu data read
  .cpu_dat_w        (cpuWR),                      // cpu write data
  .cpu_dat_r        (cpu_dat_r_w),                // cpu read data
  .cpu_ack          (ccachehit),                  // cpu acknowledge
  .sdr_dat_r        (sdr_dat_r),                  // memory read data
  .sdr_read_req     (cache_req),                  // memory read request
  .sdr_read_ack     (readcache_fill),             // memory read acknowledge
  .sdr_adr          (writebufferAddr),
  .sdr_dat_w        (writebufferWR),
  .sdr_dqm_w        (writebuffer_dqm),
  .sdr_write_req    (writebuffer_req),
  .sdr_write_ack    (writebuffer_ack),
  .snoop_act        (1'b0),                       // no chipset snooping here
  .snoop_adr        (26'd0),
  .snoop_dat_w      (32'd0),
  .snoop_bs         (4'b0000)
);


//// byte enables for a write ////
// writebuffer_dqm is active low: {word1_hi, word1_lo, word0_hi, word0_lo}
// where word0 sits at writebufferAddr[3:1] and word1 at [3:1]+1 (which can
// never wrap out of the line, see longword_en in the header).

wire [3-1:0] wr_word0 = writebufferAddr[3:1];
wire [3-1:0] wr_word1 = writebufferAddr[3:1] + 3'd1;

reg [16-1:0] wr_be;
always @ (*) begin
  wr_be = 16'h0000;
  wr_be[{wr_word0, 1'b0}] = !writebuffer_dqm[0];  // word0 low  byte
  wr_be[{wr_word0, 1'b1}] = !writebuffer_dqm[1];  // word0 high byte
  wr_be[{wr_word1, 1'b0}] = !writebuffer_dqm[2];  // word1 low  byte
  wr_be[{wr_word1, 1'b1}] = !writebuffer_dqm[3];  // word1 high byte
end

// the same 16-bit word replicated into both candidate lanes; only the enabled
// bytes matter, so the rest can be anything.
reg [128-1:0] wr_data;
always @ (*) begin
  wr_data = 128'd0;
  wr_data[{wr_word0, 4'b0000} +: 16] = writebufferWR[15:0];
  wr_data[{wr_word1, 4'b0000} +: 16] = writebufferWR[31:16];
end


//// backend state machine ////
// exactly one request in flight; writes take priority over reads (older).

wire [3-1:0] deliver_idx = burst_first + burst_cnt;   // wraps in the line

always @ (posedge sysclk) begin
  if (!reset) begin
    bstate         <= #1 B_IDLE;
    cdc_req        <= #1 1'b0;
    readcache_fill <= #1 1'b0;
    writebuffer_ack<= #1 1'b0;
    burst_cnt      <= #1 3'd0;
  end else begin
    cdc_req         <= #1 1'b0;
    writebuffer_ack <= #1 1'b0;
    readcache_fill  <= #1 1'b0;

    case (bstate)
      B_IDLE : begin
        if (cdc_ready) begin
          if (writebuffer_req) begin
            cdc_rd          <= #1 1'b0;
            cdc_be          <= #1 wr_be;
            cdc_addr        <= #1 {6'd0, writebufferAddr[25:4], 4'b0000};
            cdc_wdata       <= #1 wr_data;
            cdc_req         <= #1 1'b1;
            writebuffer_ack <= #1 1'b1;   // one-cycle ack: the write is posted
            bstate          <= #1 B_WRITE;
          end else if (cache_req) begin
            cdc_rd          <= #1 1'b1;
            cdc_be          <= #1 16'h0000;
            cdc_addr        <= #1 {6'd0, cpuAddr_r[25:4], 4'b0000};
            cdc_wdata       <= #1 128'd0;
            cdc_req         <= #1 1'b1;
            burst_first     <= #1 cpuAddr_r[3:1];
            burst_cnt       <= #1 3'd0;
            bstate          <= #1 B_READ;
          end
        end
      end

      B_WRITE : begin
        if (cdc_done) bstate <= #1 B_IDLE;
      end

      B_READ : begin
        if (cdc_done) begin
          burst_cnt <= #1 3'd0;
          bstate    <= #1 B_DELIVER;      // cdc_rdata is valid from next cycle
        end
      end

      B_DELIVER : begin
        // 8 back-to-back words, wrapped inside the line, starting at
        // burst_first = cpuAddr_r[3:1].  See the header.
        sdr_dat_r      <= #1 cdc_rdata[{deliver_idx, 4'b0000} +: 16];
        readcache_fill <= #1 1'b1;
        burst_cnt      <= #1 burst_cnt + 3'd1;
        if (burst_cnt == 3'd7) bstate <= #1 B_IDLE;
      end

      default : bstate <= #1 B_IDLE;
    endcase
  end
end


//// clock domain crossing to the 100 MHz island ////

ddr3_cdc cdc (
  .src_clk    (sysclk),
  .src_rst    (!reset),
  .src_ready  (cdc_ready),
  .src_req    (cdc_req),
  .src_rd     (cdc_rd),
  .src_wr_be  (cdc_be),
  .src_addr   (cdc_addr),
  .src_wdata  (cdc_wdata),
  .src_done   (cdc_done),
  .src_rdata  (cdc_rdata),
  .dst_clk    (clk_mem),
  .dst_rst    (1'b0),        // power-on only; the island holds the core in
                             // reset until init_done, which gates us anyway
  .req_valid  (req_valid),
  .req_wr     (req_wr),
  .req_addr   (req_addr),
  .req_wdata  (req_wdata),
  .req_accept (req_accept),
  .resp_valid (resp_valid),
  .resp_rdata (resp_rdata)
);

endmodule
