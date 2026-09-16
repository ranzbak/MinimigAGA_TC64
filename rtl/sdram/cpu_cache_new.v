`timescale 1ns / 1ns
// cpu_cache_new.v
// 2015, rok.krajnc@gmail.com
// this is a 2-way set-associative cache
// seperate instruction and data caches
// write-through, look-through
// 8kB cache size, 4kB per way
// whole cache size (I+D) is 16kB
// ! requires Altera Quartus prepared memories because of the byte-selects !

// AMR - adjust for 8-word bursts.

module cpu_cache_new (
  // system
  input  wire           clk, // clock
  input  wire           rst, // cache reset
  input  wire           cache_en, // cache enable
  input  wire [  4-1:0] cpu_cache_ctrl, // CPU cache control
  input  wire           cache_inhibit, // cache inhibit
  input  wire           cacheline_clr,
  // cpu -- the UNIT PORT (Stage E2 Task 3).  One request is at most two
  // CONSECUTIVE WORDS INSIDE ONE 16-BYTE LINE, with a byte select per byte.
  // The wrapper splits anything that does not fit (an odd-aligned longword, a
  // word at line offset 15, a longword at 14) with the table in
  // findings/ap68040/stage-e/2026-09-15-e2-plan.md; this module therefore never
  // sees an access that crosses a line, and a longword is ONE request instead
  // of the paired cpu_32bit protocol the bus16 adapter could not speak.
  //
  //   cpu_req    level, every field below stable while it is high AND on the
  //              clock edge before it rises (see the SOC_SIM check at cpu_ack)
  //   cpu_wadr   word address of word A
  //   cpu_bs     {A hi, A lo, A+2 hi, A+2 lo}, active high; bs[1:0] != 0 means
  //              a two-word unit, and then cpu_wadr[3:1] != 3'b111
  //   cpu_wdat   {word A, word A+2}
  //   cpu_rdat   {word A, word A+2}, valid with cpu_ack
  //   cpu_ack    LEVEL, high only while cpu_req is high.  Unlike the old port
  //              this never answers before the request: the line buffer's
  //              "answer without waiting for the select" fast path is gone, and
  //              with it the class of bug that needed bus_fresh in the wrapper.
  input  wire           cpu_req,
  input  wire           cpu_we, // cpu write
  input  wire           cpu_ir, // cpu instruction read (selects the I ways)
  input  wire [ 26-1:1] cpu_wadr,
  input  wire [  4-1:0] cpu_bs,
  input  wire [ 32-1:0] cpu_wdat,
  output reg  [ 32-1:0] cpu_rdat,
  output                cpu_ack,
  // sdram
  input  wire [ 16-1:0] sdr_dat_r, // sdram read data
  output reg            sdr_read_req, // sdram read request from cache
  input  wire           sdr_read_ack, // sdram read acknowledge to cache
  output reg  [ 26-1:1] sdr_adr, // sdram address
  output reg  [ 32-1:0] sdr_dat_w, // sdram write data
  output reg  [  4-1:0] sdr_dqm_w, // sdram write byte selects (active low)
  output reg            sdr_write_req, // sdram write request from cache
  input  wire           sdr_write_ack, // sdram write acknowledge to cache
  // snoop
  input  wire           snoop_act, // snoop act (write only - just update existing data in cache)
  input  wire [ 26-1:0] snoop_adr, // chip address
  input  wire [ 32-1:0] snoop_dat_w, // snoop write data
  input  wire [  4-1:0] snoop_bs // snoop byte selects
);


  //// internal signals ////

  // cache init
  reg           cache_init_done;
  // state
  reg  [ 4-1:0] cpu_sm_state;
  reg  [ 2-1:0] sdr_sm_state;
  reg           write_ena;
  // state signals
  reg           fill;
  // '1' while the next CPU_SM_FILL2 beat is the second word of the unit
  // (word A+2).  The SDRAM burst is wrapped and starts at word A, so exactly
  // one beat completes a two-word unit.
  reg           fill_first;
  reg           cpu_acked;
  reg           cpu_cache_ack;
  reg  [11-1:0] cpu_sm_adr;
  wire [11-1:0] cpu_sm_adr_next = { cpu_sm_adr[10:3], cpu_sm_adr[2:0] + 2'b01 };
  reg           cpu_sm_itag_we;
  reg           cpu_sm_dtag_we;
  reg           cpu_sm_iram0_we;
  reg           cpu_sm_iram1_we;
  reg           cpu_sm_dram0_we;
  reg           cpu_sm_dram1_we;
  reg  [ 4-1:0] cpu_sm_bs;
  reg  [32-1:0] cpu_sm_mem_dat_w;
  reg  [32-1:0] cpu_sm_tag_dat_w;
  reg           cpu_sm_id;
  reg           cpu_sm_ilru;
  reg           cpu_sm_dlru;
  reg  [14-1:0] sdr_sm_tag_adr;
  reg  [10-1:0] sdr_sm_adr;
  reg           sdr_sm_itag_we;
  reg           sdr_sm_dtag_we;
  reg           sdr_sm_iram0_we;
  reg           sdr_sm_iram1_we;
  reg           sdr_sm_dram0_we;
  reg           sdr_sm_dram1_we;
  reg  [ 4-1:0] sdr_sm_bs;
  reg  [32-1:0] sdr_sm_mem_dat_w;
  reg  [32-1:0] sdr_sm_tag_dat_w;
  reg           sdr_sm_id;
  reg           sdr_sm_ilru;
  reg           sdr_sm_dlru;

  // cpu cache control
  reg  [ 2-1:0] cc_clr_r;
  wire          cpu_cache_enable;
  wire          cpu_cache_freeze;
  wire          cpu_cache_clear;
  reg           cc_en;
  reg           cc_fr;
  reg           cc_clr;
  // cpu address
  reg  [ 3-1:0] cpu_adr_blk_ptr;
  wire [ 3-1:0] cpu_adr_blk_ptr_next = {cpu_adr_blk_ptr[2:1] + 1'd1, 1'b0};
  wire [ 3-1:0] cpu_adr_blk_ptr_prev = {cpu_adr_blk_ptr[2:1] - 1'd1, 1'b0};
  wire [ 3-1:0] cpu_adr_blk;
  wire [ 8-1:0] cpu_adr_idx;
  wire [14-1:0] cpu_adr_tag;
  // cache line cache
  reg   [8-1:0] cpu_cacheline_lo[0:7];
  reg   [8-1:0] cpu_cacheline_hi[0:7];
  reg  [26-1:4] cpu_cacheline_adr;
  wire          cpu_cacheline_valid;
  reg           cpu_cacheline_dirty;
  reg           cpu_cacheline_match;
  reg   [2-1:0] cpu_cacheline_cnt;
  // idram0
  wire [10-1:0] idram0_cpu_adr;
  wire [ 4-1:0] idram0_cpu_bs;
  wire          idram0_cpu_we;
  wire [32-1:0] idram0_cpu_dat_w;
  wire [32-1:0] idram0_cpu_dat_r;
  wire [10-1:0] idram0_sdr_adr;
  wire [ 4-1:0] idram0_sdr_bs;
  wire          idram0_sdr_we;
  wire [32-1:0] idram0_sdr_dat_w;
  wire [32-1:0] idram0_sdr_dat_r;
  // idram1
  wire [10-1:0] idram1_cpu_adr;
  wire [ 4-1:0] idram1_cpu_bs;
  wire          idram1_cpu_we;
  wire [32-1:0] idram1_cpu_dat_w;
  wire [32-1:0] idram1_cpu_dat_r;
  wire [10-1:0] idram1_sdr_adr;
  wire [ 4-1:0] idram1_sdr_bs;
  wire          idram1_sdr_we;
  wire [32-1:0] idram1_sdr_dat_w;
  wire [32-1:0] idram1_sdr_dat_r;
  // ddram0
  wire [10-1:0] ddram0_cpu_adr;
  wire [ 4-1:0] ddram0_cpu_bs;
  wire          ddram0_cpu_we;
  wire [32-1:0] ddram0_cpu_dat_w;
  wire [32-1:0] ddram0_cpu_dat_r;
  wire [10-1:0] ddram0_sdr_adr;
  wire [ 4-1:0] ddram0_sdr_bs;
  wire          ddram0_sdr_we;
  wire [32-1:0] ddram0_sdr_dat_w;
  wire [32-1:0] ddram0_sdr_dat_r;
  // ddram1
  wire [10-1:0] ddram1_cpu_adr;
  wire [ 4-1:0] ddram1_cpu_bs;
  wire          ddram1_cpu_we;
  wire [32-1:0] ddram1_cpu_dat_w;
  wire [32-1:0] ddram1_cpu_dat_r;
  wire [10-1:0] ddram1_sdr_adr;
  wire [ 4-1:0] ddram1_sdr_bs;
  wire          ddram1_sdr_we;
  wire [32-1:0] ddram1_sdr_dat_w;
  wire [32-1:0] ddram1_sdr_dat_r;
  // itram
  wire [ 8-1:0] itram_cpu_adr;
  wire          itram_cpu_we;
  wire [32-1:0] itram_cpu_dat_w;
  wire [32-1:0] itram_cpu_dat_r;
  wire [ 8-1:0] itram_sdr_adr;
  wire          itram_sdr_we;
  wire [32-1:0] itram_sdr_dat_w;
  wire [32-1:0] itram_sdr_dat_r;
  wire          itag0_match;
  wire          itag1_match;
  wire          itag_hit;
  wire          itag_lru;
  wire          itag0_valid;
  wire          itag1_valid;
  wire          sdr_itag0_match;
  wire          sdr_itag1_match;
  wire          sdr_itag_hit;
  wire          sdr_itag_lru;
  wire          sdr_itag0_valid;
  wire          sdr_itag1_valid;
  // dtram
  wire [ 8-1:0] dtram_cpu_adr;
  wire          dtram_cpu_we;
  wire [32-1:0] dtram_cpu_dat_w;
  wire [32-1:0] dtram_cpu_dat_r;
  wire [ 8-1:0] dtram_sdr_adr;
  wire          dtram_sdr_we;
  wire [32-1:0] dtram_sdr_dat_w;
  wire [32-1:0] dtram_sdr_dat_r;
  wire          dtag0_match;
  wire          dtag1_match;
  wire          dtag_hit;
  wire          dtag_lru;
  wire          dtag0_valid;
  wire          dtag1_valid;
  wire          sdr_dtag0_match;
  wire          sdr_dtag1_match;
  wire          sdr_dtag_hit;
  wire          sdr_dtag_lru;
  wire          sdr_dtag0_valid;
  wire          sdr_dtag1_valid;

  //// params ////

  // cpu-side state machine
  localparam [3:0]
  CPU_SM_INIT  = 4'd0,
  CPU_SM_IDLE  = 4'd1,
  // 4'd2 and 4'd3 were CPU_SM_WAIT_LOWORD and CPU_SM_WRITE_32BIT, the paired
  // 32-bit write protocol: one request acknowledged at once, then a second bus
  // cycle taken as its low half.  The unit port carries both words in ONE
  // request, so the pair is gone; WRITE2 is the second WAY write an
  // odd-aligned unit needs, which is a different thing entirely.
  CPU_SM_WRITE2 = 4'd2,
  CPU_SM_WRITE = 4'd4,
  CPU_SM_WB    = 4'd5,
  CPU_SM_READ  = 4'd6,
  CPU_SM_WAIT  = 4'd7,
  CPU_SM_SDWAI = 4'd8,
  CPU_SM_FILL1 = 4'd9,
  CPU_SM_FILL2 = 4'd10,
  CPU_SM_FILLW = 4'd11;

  // sdram-side state machine
  localparam [1:0]
  SDR_SM_INIT0 = 2'd0,
  SDR_SM_INIT1 = 2'd1,
  SDR_SM_IDLE  = 2'd2,
  SDR_SM_SNOOP = 2'd3;


  //// cpu side ////

  // cpu cache control
  always @ (posedge clk) begin
    if (rst)
      cc_clr_r <= #1 2'd0;
    else if (!cpu_req)
      cc_clr_r <= #1 {cc_clr_r[0], cpu_cache_ctrl[3]};
  end

  assign cpu_cache_enable = cpu_cache_ctrl[0];
  assign cpu_cache_freeze = cpu_cache_ctrl[1];
  assign cpu_cache_clear  = cc_clr_r[0] && !cc_clr_r[1];

  always @ (posedge clk) begin
    if (rst) begin
      cc_en  <= #1 1'b0;
      cc_fr  <= #1 1'b0;
      cc_clr <= #1 1'b0;
    end else if (!cpu_req) begin
      cc_en  <= #1 cpu_cache_enable;
      cc_fr  <= #1 cpu_cache_freeze;
      cc_clr <= #1 cpu_cache_clear;
    end
  end

  // slice up the cpu address.  cpu_wadr is a WORD address, so bit k of it is
  // bit k of the byte address the old cpu_adr carried: the slices are unchanged.
  assign cpu_adr_blk = cpu_wadr[3:1]; // cache block address (inside cache row), 3 bits for 8x16 rows
  assign cpu_adr_idx = cpu_wadr[11:4]; // cache row address, 8 bits
  assign cpu_adr_tag = cpu_wadr[25:12]; // tag, 14 bits

  // The unit's two words.  cpu_blk_b never wraps out of the line: the wrapper
  // splits a request that would cross one, so cpu_bs[1:0] != 0 implies
  // cpu_wadr[3:1] != 3'b111.
  wire [3-1:0] cpu_blk_a = cpu_wadr[3:1];
  wire [3-1:0] cpu_blk_b = cpu_wadr[3:1] + 3'd1;
  wire         cpu_two   = |cpu_bs[1:0];   // a two-word unit

  always @(posedge clk) cpu_cacheline_match <= cpu_wadr[25:4] == cpu_cacheline_adr && !cpu_cacheline_dirty;
  assign cpu_cacheline_valid = cpu_cacheline_match && (cpu_sm_state == CPU_SM_IDLE) && !cpu_we && !cache_inhibit;
  // ACKNOWLEDGE ONLY WHILE A REQUEST IS UP.  The old port drove cpu_ack from a
  // registered compare of the LIVE address, so it answered before the select
  // and even with no access outstanding; a consumer that judged that answer
  // against the wrong address is the D3-FIX walker bug, and bus_fresh in the
  // wrapper existed to mask exactly that one cycle.  Gating on cpu_req removes
  // the class.
  assign cpu_ack = cpu_req && (cpu_cache_ack || cpu_cacheline_valid);

  // FIELDS ONE CYCLE BEFORE THE REQUEST.  cpu_cacheline_match, the hit path's
  // cpu_rdat, cpu_adr_blk_ptr and the way RAM read addresses are all
  // registered from the LIVE cpu_wadr, and CPU_SM_IDLE acts in the first cycle
  // cpu_req is high -- so the fields must already have been there on the edge
  // before it, exactly as the old port needed the address one cycle before the
  // select.  ap040_ram_seq meets this with a setup cycle.  Found in
  // sim/ddr3_cpu (E2 Task 4b-2): a master raising fields and request on one
  // edge got a line-buffer hit with the previous offset's words (the reset PC
  // came back as the SSP), then a block pointer from the old address.
`ifdef SOC_SIM
  reg         chk_req_d = 1'b0;
  reg [62:0]  chk_fld_d = 63'd0;
  wire [62:0] chk_fld   = {cpu_we, cpu_ir, cpu_wadr, cpu_bs, cpu_wdat};
  always @(posedge clk) begin
    if (!rst && cpu_req && !chk_req_d && chk_fld !== chk_fld_d)
      $display("ERROR: cpu_cache_new: unit port fields changed on the edge cpu_req rose (t = %t)", $time);
    chk_req_d <= cpu_req;
    chk_fld_d <= chk_fld;
  end
`endif

  // cpu side state machine
  always @ (posedge clk) begin
    if (rst) begin
      fill              <= #1 1'b0;
      fill_first        <= #1 1'b0;
      sdr_read_req      <= #1 1'b0;
      sdr_write_req     <= #1 1'b0;
      write_ena         <= #1 1'b0;
      cpu_cache_ack     <= #1 1'b0;
      cpu_sm_state      <= #1 CPU_SM_INIT;
      cpu_sm_itag_we    <= #1 1'b0;
      cpu_sm_dtag_we    <= #1 1'b0;
      cpu_sm_iram0_we   <= #1 1'b0;
      cpu_sm_iram1_we   <= #1 1'b0;
      cpu_sm_dram0_we   <= #1 1'b0;
      cpu_sm_dram1_we   <= #1 1'b0;
      cpu_sm_bs         <= #1 4'b1111;
      cpu_adr_blk_ptr   <= #1 3'b000;
      cpu_cacheline_dirty <= #1 1'b1;
    end else begin
      // default values
      fill              <= #1 1'b0;
      sdr_read_req      <= #1 1'b0;
      write_ena         <= #1 1'b0;
      cpu_sm_itag_we    <= #1 1'b0;
      cpu_sm_dtag_we    <= #1 1'b0;
      cpu_sm_iram0_we   <= #1 1'b0;
      cpu_sm_iram1_we   <= #1 1'b0;
      cpu_sm_dram0_we   <= #1 1'b0;
      cpu_sm_dram1_we   <= #1 1'b0;
      cpu_sm_bs         <= #1 4'b1111;

      // The unit's two words out of the line buffer, every clock: word A in
      // the high half, word A+2 in the low half.  A one-word unit simply
      // ignores the low half (its cpu_bs[1:0] is zero).
      cpu_rdat <= {cpu_cacheline_hi[cpu_blk_a], cpu_cacheline_lo[cpu_blk_a],
                   cpu_cacheline_hi[cpu_blk_b], cpu_cacheline_lo[cpu_blk_b]};

      if (cacheline_clr) cpu_cacheline_dirty <= #1 1'b1;

      // state machine
      case (cpu_sm_state)
        CPU_SM_INIT : begin
          // waiting for cache init
          if (cache_init_done) begin
            cpu_sm_state <= #1 CPU_SM_IDLE;
          end else begin
            cpu_sm_state <= #1 CPU_SM_INIT;
          end
        end
        CPU_SM_IDLE : begin
          cpu_adr_blk_ptr <= #1 cpu_adr_blk;
          write_ena <= #1 !sdr_write_req && !sdr_write_ack;
          // waiting for CPU access
          if (cpu_req) begin
            if (cpu_we) begin
              if (!cpu_cacheline_match) cpu_cacheline_dirty <= #1 1'b1; //invalidate
              // the unit's bytes, into the line buffer: word A then word A+2
              if (cpu_bs[3]) cpu_cacheline_hi[cpu_blk_a] <= #1 cpu_wdat[31:24];
              if (cpu_bs[2]) cpu_cacheline_lo[cpu_blk_a] <= #1 cpu_wdat[23:16];
              if (cpu_bs[1]) cpu_cacheline_hi[cpu_blk_b] <= #1 cpu_wdat[15: 8];
              if (cpu_bs[0]) cpu_cacheline_lo[cpu_blk_b] <= #1 cpu_wdat[ 7: 0];

              if (write_ena) begin
                // ONE write-buffer request for the whole unit.  sdram_ctrl
                // writes sdr_dat_w[15:0] at sdr_adr and [31:16] at sdr_adr+1,
                // so the low half carries word A; dqm is active low.
                sdr_adr   <= #1 cpu_wadr[25:1];
                sdr_dqm_w <= #1 ~{cpu_bs[1:0], cpu_bs[3:2]};
                sdr_dat_w <= #1 {cpu_wdat[15:0], cpu_wdat[31:16]};
                sdr_write_req <= #1 1'b1;
                cpu_sm_state <= #1 CPU_SM_WRITE;
              end
            end else if (!cpu_cacheline_valid) begin
              cpu_adr_blk_ptr <= #1 cpu_adr_blk_ptr_next;
              cpu_sm_state <= #1 CPU_SM_READ;
              cpu_cacheline_cnt <= #1 2'b00;
            end
          end else begin
            if (cc_clr)
              cpu_sm_state <= #1 CPU_SM_INIT;
            else
              cpu_sm_state <= #1 CPU_SM_IDLE;
          end
        end
        // A way entry at {idx, blk[2:1]} holds word 2m in bits [15:0] and word
        // 2m+1 in [31:16]; cpu_sm_bs is {hi 2m+1, lo 2m+1, hi 2m, lo 2m}.  A
        // unit whose word A is EVEN sits entirely in one entry; an odd word A
        // puts its second word in the next entry, so that takes two writes.
        CPU_SM_WRITE : begin
          cpu_adr_blk_ptr <= #1 cpu_blk_a;
          if (!cpu_blk_a[0]) begin
            cpu_sm_bs        <= #1 {cpu_bs[1], cpu_bs[0], cpu_bs[3], cpu_bs[2]};
            cpu_sm_mem_dat_w <= #1 {cpu_wdat[15:0], cpu_wdat[31:16]};
            cpu_cache_ack <= #1 1'b1;
            cpu_sm_state  <= #1 CPU_SM_WB;
          end else begin
            cpu_sm_bs        <= #1 {cpu_bs[3], cpu_bs[2], 2'b00};
            cpu_sm_mem_dat_w <= #1 {cpu_wdat[31:16], 16'h0000};
            if (cpu_two) begin
              cpu_sm_state  <= #1 CPU_SM_WRITE2;
            end else begin
              cpu_cache_ack <= #1 1'b1;
              cpu_sm_state  <= #1 CPU_SM_WB;
            end
          end
          cpu_sm_iram0_we <= #1 itag0_match && itag0_valid /*&& !cc_fr*/;
          cpu_sm_iram1_we <= #1 itag1_match && itag1_valid /*&& !cc_fr*/;
          cpu_sm_dram0_we <= #1 dtag0_match && dtag0_valid /*&& !cc_fr*/;
          cpu_sm_dram1_we <= #1 dtag1_match && dtag1_valid /*&& !cc_fr*/;
        end
        CPU_SM_WRITE2 : begin
          // the second word of an odd-aligned unit, in the next way entry
          cpu_adr_blk_ptr  <= #1 cpu_blk_b;
          cpu_sm_bs        <= #1 {2'b00, cpu_bs[1], cpu_bs[0]};
          cpu_sm_mem_dat_w <= #1 {16'h0000, cpu_wdat[15:0]};
          cpu_sm_iram0_we <= #1 itag0_match && itag0_valid /*&& !cc_fr*/;
          cpu_sm_iram1_we <= #1 itag1_match && itag1_valid /*&& !cc_fr*/;
          cpu_sm_dram0_we <= #1 dtag0_match && dtag0_valid /*&& !cc_fr*/;
          cpu_sm_dram1_we <= #1 dtag1_match && dtag1_valid /*&& !cc_fr*/;
          cpu_cache_ack <= #1 1'b1;
          cpu_sm_state <= #1 CPU_SM_WB;
        end
        CPU_SM_WB : begin
          if (!cpu_req) cpu_sm_state <= #1 CPU_SM_IDLE;
        end
        CPU_SM_READ : begin
          cpu_cacheline_adr <= #1 cpu_wadr[25:4];
          cpu_cacheline_cnt <= #1 cpu_cacheline_cnt + 1'b1;
          // Early ack, one beat later for a two-word unit: each beat copies one
          // 32-bit way entry (two words) into the buffer, so word A+2 can still
          // be one beat behind word A when they straddle two entries.
          if(cpu_cacheline_cnt == (cpu_two ? 2'b10 : 2'b01)) begin
            cpu_cacheline_dirty <= #1 1'b0;
            cpu_cache_ack <= #1 1'b1; //early ack
          end
          if(cpu_cacheline_cnt == 2'b11)
            cpu_sm_state <= #1 cpu_req ? CPU_SM_WAIT : CPU_SM_IDLE;

          cpu_adr_blk_ptr <= cpu_adr_blk_ptr_next;
          // on hit update LRU flag in tag memory
          if (cc_en && itag0_match && itag0_valid) begin
            // data is already in instruction cache way 0
            cpu_sm_itag_we <= #1 (cpu_cacheline_cnt == 2'b00); // update at the first cycle only
            cpu_sm_tag_dat_w <= #1 {1'b0, itram_cpu_dat_r[30:0]};
            cpu_cacheline_lo[{cpu_adr_blk_ptr_prev[2:1], 1'b0}] <= #1 idram0_cpu_dat_r[ 7: 0];
            cpu_cacheline_hi[{cpu_adr_blk_ptr_prev[2:1], 1'b0}] <= #1 idram0_cpu_dat_r[15: 8];
            cpu_cacheline_lo[{cpu_adr_blk_ptr_prev[2:1], 1'b1}] <= #1 idram0_cpu_dat_r[23:16];
            cpu_cacheline_hi[{cpu_adr_blk_ptr_prev[2:1], 1'b1}] <= #1 idram0_cpu_dat_r[31:24];
          end else if (cc_en && itag1_match && itag1_valid) begin
            // data is already in instruction cache way 1
            cpu_sm_itag_we <= #1 (cpu_cacheline_cnt == 2'b00); // update at the first cycle only
            cpu_sm_tag_dat_w <= #1 {1'b1, itram_cpu_dat_r[30:0]};
            cpu_cacheline_lo[{cpu_adr_blk_ptr_prev[2:1], 1'b0}] <= #1 idram1_cpu_dat_r[ 7: 0];
            cpu_cacheline_hi[{cpu_adr_blk_ptr_prev[2:1], 1'b0}] <= #1 idram1_cpu_dat_r[15: 8];
            cpu_cacheline_lo[{cpu_adr_blk_ptr_prev[2:1], 1'b1}] <= #1 idram1_cpu_dat_r[23:16];
            cpu_cacheline_hi[{cpu_adr_blk_ptr_prev[2:1], 1'b1}] <= #1 idram1_cpu_dat_r[31:24];
          end else if (cc_en && dtag0_match && dtag0_valid) begin
            // data is already in data cache way 0
            cpu_sm_dtag_we <= #1 (cpu_cacheline_cnt == 2'b00); // update at the first cycle only
            cpu_sm_tag_dat_w <= #1 {1'b0, dtram_cpu_dat_r[30:0]};
            cpu_cacheline_lo[{cpu_adr_blk_ptr_prev[2:1], 1'b0}] <= #1 ddram0_cpu_dat_r[ 7: 0];
            cpu_cacheline_hi[{cpu_adr_blk_ptr_prev[2:1], 1'b0}] <= #1 ddram0_cpu_dat_r[15: 8];
            cpu_cacheline_lo[{cpu_adr_blk_ptr_prev[2:1], 1'b1}] <= #1 ddram0_cpu_dat_r[23:16];
            cpu_cacheline_hi[{cpu_adr_blk_ptr_prev[2:1], 1'b1}] <= #1 ddram0_cpu_dat_r[31:24];
          end else if (cc_en && dtag1_match && dtag1_valid) begin
            // data is already in data cache way 1
            cpu_sm_dtag_we <= #1 (cpu_cacheline_cnt == 2'b00); // update at the first cycle only
            cpu_sm_tag_dat_w <= #1 {1'b1, dtram_cpu_dat_r[30:0]};
            cpu_cacheline_lo[{cpu_adr_blk_ptr_prev[2:1], 1'b0}] <= #1 ddram1_cpu_dat_r[ 7: 0];
            cpu_cacheline_hi[{cpu_adr_blk_ptr_prev[2:1], 1'b0}] <= #1 ddram1_cpu_dat_r[15: 8];
            cpu_cacheline_lo[{cpu_adr_blk_ptr_prev[2:1], 1'b1}] <= #1 ddram1_cpu_dat_r[23:16];
            cpu_cacheline_hi[{cpu_adr_blk_ptr_prev[2:1], 1'b1}] <= #1 ddram1_cpu_dat_r[31:24];
          end else begin
            // on miss fetch data from SDRAM
            cpu_acked <= #1 1'b0;
            cpu_adr_blk_ptr <= #1 cpu_adr_blk;
            if (!sdr_read_ack) begin
              sdr_read_req <= #1 1'b1;
              cpu_sm_state <= #1 CPU_SM_FILL1;
            end else begin
              // wait if the previous request is still going
              // (when the cache is inhibited, we don't wait until the burst is finished)
              cpu_sm_state <= #1 CPU_SM_SDWAI;
            end
          end
        end
        CPU_SM_WAIT : begin
          cpu_adr_blk_ptr <= #1 cpu_adr_blk;
          if (!cpu_req) cpu_sm_state <= #1 CPU_SM_IDLE;
        end
        CPU_SM_SDWAI : begin
          if (!sdr_read_ack) begin
            sdr_read_req <= #1 1'b1;
            cpu_sm_state <= #1 CPU_SM_FILL1;
          end
        end
        CPU_SM_FILL1 : begin
          fill <= #1 1'b1;
          cpu_sm_adr <= #1 {cpu_adr_idx, cpu_adr_blk_ptr};
          if (!sdr_read_ack) begin
            sdr_read_req <= #1 1'b1;
          end else begin
            sdr_read_req <= #1 1'b0;
            // Word A, the first of the wrapped burst.  A one-word unit is
            // complete here; a two-word unit waits for A+2, which is the next
            // beat (CPU_SM_FILL2, fill_first).
            if (!cpu_two) cpu_cache_ack <= #1 1'b1;
            fill_first <= #1 1'b1;
            cpu_cacheline_lo[cpu_blk_a] <= #1 sdr_dat_r[7:0];
            cpu_cacheline_hi[cpu_blk_a] <= #1 sdr_dat_r[15:8];
            cpu_rdat[31:16] <= sdr_dat_r;
            if (cache_inhibit) begin
              // don't update cache if caching is inhibited
              cpu_cacheline_dirty <= #1 1'b1; //invalidate
              cpu_sm_state <= #1 CPU_SM_FILLW;
            end else begin
              cpu_cacheline_adr <= #1 cpu_wadr[25:4];
              cpu_cacheline_dirty <= #1 1'b0;

              // update tag ram
              if (cpu_ir) begin
                if (itag_lru) begin
                  cpu_sm_tag_dat_w <= #1 {1'b0, 1'b1, itram_cpu_dat_r[29], 1'b0, itram_cpu_dat_r[27:14], cpu_adr_tag}; // Removed zero bit
                end else begin
                  cpu_sm_tag_dat_w <= #1 {1'b1, itram_cpu_dat_r[30], 1'b1, 1'b0, cpu_adr_tag, itram_cpu_dat_r[13: 0]}; // Removed zero bit
                end
              end else begin
                if (dtag_lru) begin
                  cpu_sm_tag_dat_w <= #1 {1'b0, 1'b1, dtram_cpu_dat_r[29], 1'b0, dtram_cpu_dat_r[27:14], cpu_adr_tag}; // Removed zero bit
                end else begin
                  cpu_sm_tag_dat_w <= #1 {1'b1, dtram_cpu_dat_r[30], 1'b1, 1'b0, cpu_adr_tag, dtram_cpu_dat_r[13: 0]}; // Removed zero bit
                end
              end
              cpu_sm_itag_we <= #1  cpu_ir;
              cpu_sm_dtag_we <= #1 !cpu_ir;
              // cache line fill 1st word
              cpu_sm_id   <= #1 cpu_ir;
              cpu_sm_ilru <= #1 itag_lru;
              cpu_sm_dlru <= #1 dtag_lru;
              cpu_sm_bs <= #1 cpu_adr_blk[0] ? 4'b1100 : 4'b0011;
              cpu_sm_mem_dat_w <= #1 { sdr_dat_r, sdr_dat_r };
              cpu_sm_iram0_we <= #1  itag_lru &&  cpu_ir;
              cpu_sm_iram1_we <= #1 !itag_lru &&  cpu_ir;
              cpu_sm_dram0_we <= #1  dtag_lru && !cpu_ir;
              cpu_sm_dram1_we <= #1 !dtag_lru && !cpu_ir;
              cpu_sm_state <= #1 CPU_SM_FILL2;
            end
          end
        end
        CPU_SM_FILL2 : begin
          if (sdr_read_ack) begin
            // The first beat here is word A+2 (the burst is wrapped and starts
            // at word A), so it completes a two-word unit.
            if (fill_first) begin
              fill_first <= #1 1'b0;
              cpu_rdat[15:0] <= sdr_dat_r;
              if (cpu_two) cpu_cache_ack <= #1 1'b1;
            end
            if (!cpu_req) cpu_acked <= #1 1'b1;
            // cache line fill 2nd...8th word
            cpu_cacheline_lo[cpu_sm_adr_next[2:0]] <= #1 sdr_dat_r[7:0];
            cpu_cacheline_hi[cpu_sm_adr_next[2:0]] <= #1 sdr_dat_r[15:8];
            fill <= #1 1'b1;
            cpu_sm_adr[2:0] <= #1 cpu_sm_adr_next[2:0];
            cpu_sm_bs <= #1 ~cpu_sm_bs;
            cpu_sm_mem_dat_w <= #1 { sdr_dat_r, sdr_dat_r };
            cpu_sm_iram0_we <= #1  cpu_sm_ilru &&  cpu_sm_id;
            cpu_sm_iram1_we <= #1 !cpu_sm_ilru &&  cpu_sm_id;
            cpu_sm_dram0_we <= #1  cpu_sm_dlru && !cpu_sm_id;
            cpu_sm_dram1_we <= #1 !cpu_sm_dlru && !cpu_sm_id;
          end else if (!cpu_req | cpu_acked) begin
            cpu_sm_state <= #1 CPU_SM_IDLE;
            cpu_adr_blk_ptr <= #1 cpu_adr_blk; // if CS already activated during fill
          end
        end
        CPU_SM_FILLW : begin
          if (!cpu_req) begin
            cpu_sm_state <= #1 CPU_SM_IDLE;
            cpu_adr_blk_ptr <= #1 cpu_adr_blk; // if CS already activated during fill
          end
        end
        default: ;
      endcase

      // when the SDRAM ack'ed the write, lower the request
      if (sdr_write_ack) sdr_write_req <= #1 1'b0;

      // when the CPU drops its request, lower the acknowledge too
      if (!cpu_req) cpu_cache_ack <= #1 1'b0;

      // THE LINE BUFFER IS NOT SNOOPED.  cpu_cacheline_lo/hi is a sixteen-byte buffer
      // in front of both ways, tagged by cpu_cacheline_adr, and a hit on it
      // answers the CPU in the same cycle (cpu_cacheline_valid feeds cpu_ack
      // directly).  Every other structure in this module is kept coherent
      // with chipset DMA by snoop_act -- the sdram-side machine below updates
      // the matching way -- but this buffer was NOT, and nothing else clears
      // it: cpu_cacheline_dirty is set only by reset, cacheline_clr, a CPU
      // write that misses it, and a refill.
      //
      // With Turbo chip RAM that is a straight coherency hole, and the only
      // window it can appear in: chip RAM is the one region the chipset
      // writes AND the CPU reads through this cache.  The chipset writes,
      // the way is updated, and the CPU goes on reading the stale sixteen
      // bytes it already had until something displaces them.  Kickstart under
      // Turbo cannot show it (read-only, never a DMA target) and the Zorro
      // boards cannot (CPU-private) -- which is exactly the pattern the
      // hardware showed.
      //
      // NOT FIXED HERE.  An invalidate on snoop_act (the CL_SNOOP option) made
      // the hardware worse (build d3clsnoop) and was removed in Stage E4a.
      // Whether the line buffer stays at all is decided in Stage E4;
      // sim/sdram_coherency counts the hole as "C2P line buffer primed".

    end
  end


`ifdef SOC_SIM
  // THE UNIT INVARIANT, CHECKED.  A two-word unit must not cross a 16-byte
  // line: word A+2 would then belong to the next line, and this module would
  // write it into the current one -- eight words low, silently.  That is
  // exactly what a converted bench task did on 2026-09-16 (26 DDR3 backdoor
  // mismatches, every one a line apart, with every functional check passing),
  // and it cost a full bench run to find.  A master that gets the split wrong
  // now says so on the cycle it happens.
  // An all-zero cpu_bs is NOT an error: a write with no byte enabled is a
  // legitimate no-op (sim/ddr3/ddr3_fastram_tb.v section (b) issues one
  // deliberately), and a read ignores the selects anyway.  Only the
  // line-crossing case is a real fault, because it silently lands a word in
  // the wrong line.
  always @(posedge clk) begin
    if (!rst && cpu_req && |cpu_bs[1:0] && cpu_wadr[3:1] == 3'b111)
      $display("FAIL cpu_cache_new: two-word unit at word %06h CROSSES a line (bs %b) at %t",
               cpu_wadr, cpu_bs, $time);
  end
`endif


  //// sdram side ////

  // sdram side state machine
  always @ (posedge clk) begin
    if (rst) begin
      cache_init_done   <= #1 1'b0;
      sdr_sm_state      <= #1 SDR_SM_INIT0;
      sdr_sm_itag_we    <= #1 1'b0;
      sdr_sm_dtag_we    <= #1 1'b0;
      sdr_sm_iram0_we   <= #1 1'b0;
      sdr_sm_iram1_we   <= #1 1'b0;
      sdr_sm_dram0_we   <= #1 1'b0;
      sdr_sm_dram1_we   <= #1 1'b0;
      sdr_sm_bs         <= #1 4'b1111;
    end else begin
      // default values
      cache_init_done   <= #1 1'b1;
      sdr_sm_itag_we    <= #1 1'b0;
      sdr_sm_dtag_we    <= #1 1'b0;
      sdr_sm_iram0_we   <= #1 1'b0;
      sdr_sm_iram1_we   <= #1 1'b0;
      sdr_sm_dram0_we   <= #1 1'b0;
      sdr_sm_dram1_we   <= #1 1'b0;
      sdr_sm_bs         <= #1 4'b1111;
      // state machine
      case (sdr_sm_state)
        SDR_SM_INIT0 : begin
          // prepare to clear cache
          cache_init_done <= #1 1'b0;
          sdr_sm_adr <= #1 10'd0;
          sdr_sm_tag_dat_w <= #1 32'd0;
          sdr_sm_itag_we <= #1 1'b1;
          sdr_sm_dtag_we <= #1 1'b1;
          sdr_sm_state <= #1 SDR_SM_INIT1;
        end
        SDR_SM_INIT1 : begin
          // clear cache
          cache_init_done <= #1 1'b0;
          sdr_sm_adr <= #1 sdr_sm_adr + 10'd4;
          sdr_sm_itag_we <= #1 1'b1;
          sdr_sm_dtag_we <= #1 1'b1;
          if (&sdr_sm_adr[9:2]) begin
            sdr_sm_state <= #1 SDR_SM_IDLE;
          end else begin
            sdr_sm_state <= #1 SDR_SM_INIT1;
          end
        end
        SDR_SM_IDLE : begin
          // wait for action
          cache_init_done <= #1 1'b1;
          sdr_sm_adr <= #1 snoop_adr[11:2];
          if (cc_clr) begin
            sdr_sm_state <= #1 SDR_SM_INIT0;
          end
          else if (snoop_act) begin
            // chip write happening
            sdr_sm_state <= #1 SDR_SM_SNOOP;
          end
        end
        SDR_SM_SNOOP : begin
          // update if a matching address is in cache
          if (snoop_adr[1]) begin
            sdr_sm_mem_dat_w <= #1 { snoop_dat_w[15:0], snoop_dat_w[15:0] };
            sdr_sm_bs <= #1 { snoop_bs[1:0], 2'b00 };
          end else begin
            sdr_sm_mem_dat_w <= #1 snoop_dat_w;
            sdr_sm_bs <= #1 snoop_bs;
          end
          sdr_sm_iram0_we <= #1 sdr_itag0_match && sdr_itag0_valid;
          sdr_sm_iram1_we <= #1 sdr_itag1_match && sdr_itag1_valid;
          sdr_sm_dram0_we <= #1 sdr_dtag0_match && sdr_dtag0_valid;
          sdr_sm_dram1_we <= #1 sdr_dtag1_match && sdr_dtag1_valid;
          sdr_sm_state <= #1 SDR_SM_IDLE;
        end
        default: ;
      endcase
    end
  end


  //// instruction memories ////

  // instruction tag ram
  assign itram_cpu_adr    = cpu_adr_idx;
  assign itram_cpu_we     = cpu_sm_itag_we;
  assign itram_cpu_dat_w  = cpu_sm_tag_dat_w;
  assign itag0_match      = (cpu_adr_tag == itram_cpu_dat_r[13:0]);
  assign itag1_match      = (cpu_adr_tag == itram_cpu_dat_r[27:14]);
  assign itag_hit         = itag0_match || itag1_match;
  assign itag_lru         = itram_cpu_dat_r[31];
  assign itag0_valid      = itram_cpu_dat_r[30];
  assign itag1_valid      = itram_cpu_dat_r[29];
  assign itram_sdr_adr    = sdr_sm_adr[9:2];
  assign itram_sdr_we     = sdr_sm_itag_we;
  assign itram_sdr_dat_w  = sdr_sm_tag_dat_w;
  assign sdr_itag0_match  = (snoop_adr[25:12] == itram_sdr_dat_r[13:0]);
  assign sdr_itag1_match  = (snoop_adr[25:12] == itram_sdr_dat_r[27:14]);
  assign sdr_itag_hit     = sdr_itag0_match || sdr_itag1_match;
  assign sdr_itag_lru     = itram_sdr_dat_r[31];
  assign sdr_itag0_valid  = itram_sdr_dat_r[30];
  assign sdr_itag1_valid  = itram_sdr_dat_r[29];

`ifdef SOC_SIM
dpram_inf_256x32
`else
dpram_256x32
`endif
itram (
    .clock      (clk              ),
    .address_a  (itram_cpu_adr    ),
    .wren_a     (itram_cpu_we     ),
    .data_a     (itram_cpu_dat_w  ),
    .q_a        (itram_cpu_dat_r  ),
    .address_b  (itram_sdr_adr    ),
    .wren_b     (itram_sdr_we     ),
    .data_b     (itram_sdr_dat_w  ),
    .q_b        (itram_sdr_dat_r  )
  );

  // instruction data ram 0
  assign idram0_cpu_adr   = fill ? cpu_sm_adr[10:1] : {cpu_adr_idx, cpu_adr_blk_ptr[2:1]};
  assign idram0_cpu_bs    = cpu_sm_bs;
  assign idram0_cpu_we    = cpu_sm_iram0_we;
  assign idram0_cpu_dat_w = cpu_sm_mem_dat_w;
  assign idram0_sdr_adr   = sdr_sm_adr;
  assign idram0_sdr_bs    = sdr_sm_bs;
  assign idram0_sdr_we    = sdr_sm_iram0_we;
  assign idram0_sdr_dat_w = sdr_sm_mem_dat_w;

`ifdef SOC_SIM
dpram_inf_be_1024x32
`else
dpram_be_1024x32
`endif
idram0 (
    .clock      (clk              ),
    .address_a  (idram0_cpu_adr   ),
    .byteena_a  (idram0_cpu_bs    ),
    .wren_a     (idram0_cpu_we    ),
    .data_a     (idram0_cpu_dat_w ),
    .q_a        (idram0_cpu_dat_r ),
    .address_b  (idram0_sdr_adr   ),
    .byteena_b  (idram0_sdr_bs    ),
    .wren_b     (idram0_sdr_we    ),
    .data_b     (idram0_sdr_dat_w ),
    .q_b        (idram0_sdr_dat_r )
  );

  // instruction data ram 1
  assign idram1_cpu_adr   = fill ? cpu_sm_adr[10:1] : {cpu_adr_idx, cpu_adr_blk_ptr[2:1]};
  assign idram1_cpu_bs    = cpu_sm_bs;
  assign idram1_cpu_we    = cpu_sm_iram1_we;
  assign idram1_cpu_dat_w = cpu_sm_mem_dat_w;
  assign idram1_sdr_adr   = sdr_sm_adr;
  assign idram1_sdr_bs    = sdr_sm_bs;
  assign idram1_sdr_we    = sdr_sm_iram1_we;
  assign idram1_sdr_dat_w = sdr_sm_mem_dat_w;

`ifdef SOC_SIM
dpram_inf_be_1024x32
`else
dpram_be_1024x32
`endif
idram1 (
    .clock      (clk              ),
    .address_a  (idram1_cpu_adr   ),
    .byteena_a  (idram1_cpu_bs    ),
    .wren_a     (idram1_cpu_we    ),
    .data_a     (idram1_cpu_dat_w ),
    .q_a        (idram1_cpu_dat_r ),
    .address_b  (idram1_sdr_adr   ),
    .byteena_b  (idram1_sdr_bs    ),
    .wren_b     (idram1_sdr_we    ),
    .data_b     (idram1_sdr_dat_w ),
    .q_b        (idram1_sdr_dat_r )
  );


  //// data data memories ////

  // data tag ram
  assign dtram_cpu_adr    = cpu_adr_idx;
  assign dtram_cpu_we     = cpu_sm_dtag_we;
  assign dtram_cpu_dat_w  = cpu_sm_tag_dat_w;
  assign dtag0_match      = (cpu_adr_tag == dtram_cpu_dat_r[13:0]);
  assign dtag1_match      = (cpu_adr_tag == dtram_cpu_dat_r[27:14]);
  assign dtag_hit         = dtag0_match || dtag1_match;
  assign dtag_lru         = dtram_cpu_dat_r[31];
  assign dtag0_valid      = dtram_cpu_dat_r[30];
  assign dtag1_valid      = dtram_cpu_dat_r[29];
  assign dtram_sdr_adr    = sdr_sm_adr[9:2];
  assign dtram_sdr_we     = sdr_sm_dtag_we;
  assign dtram_sdr_dat_w  = sdr_sm_tag_dat_w;
  assign sdr_dtag0_match  = (snoop_adr[25:12] == dtram_sdr_dat_r[13:0]);
  assign sdr_dtag1_match  = (snoop_adr[25:12] == dtram_sdr_dat_r[27:14]);
  assign sdr_dtag_hit     = sdr_dtag0_match || sdr_dtag1_match;
  assign sdr_dtag_lru     = dtram_sdr_dat_r[31];
  assign sdr_dtag0_valid  = dtram_sdr_dat_r[30];
  assign sdr_dtag1_valid  = dtram_sdr_dat_r[29];

`ifdef SOC_SIM
dpram_inf_256x32
`else
dpram_256x32
`endif
dtram (
    .clock      (clk              ),
    .address_a  (dtram_cpu_adr    ),
    .wren_a     (dtram_cpu_we     ),
    .data_a     (dtram_cpu_dat_w  ),
    .q_a        (dtram_cpu_dat_r  ),
    .address_b  (dtram_sdr_adr    ),
    .wren_b     (dtram_sdr_we     ),
    .data_b     (dtram_sdr_dat_w  ),
    .q_b        (dtram_sdr_dat_r  )
  );

  // data data ram 0
  assign ddram0_cpu_adr   = fill ? cpu_sm_adr[10:1] : {cpu_adr_idx, cpu_adr_blk_ptr[2:1]};
  assign ddram0_cpu_bs    = cpu_sm_bs;
  assign ddram0_cpu_we    = cpu_sm_dram0_we;
  assign ddram0_cpu_dat_w = cpu_sm_mem_dat_w;
  assign ddram0_sdr_adr   = sdr_sm_adr;
  assign ddram0_sdr_bs    = sdr_sm_bs;
  assign ddram0_sdr_we    = sdr_sm_dram0_we;
  assign ddram0_sdr_dat_w = sdr_sm_mem_dat_w;

`ifdef SOC_SIM
dpram_inf_be_1024x32
`else
dpram_be_1024x32
`endif
ddram0 (
    .clock      (clk              ),
    .address_a  (ddram0_cpu_adr   ),
    .byteena_a  (ddram0_cpu_bs    ),
    .wren_a     (ddram0_cpu_we    ),
    .data_a     (ddram0_cpu_dat_w ),
    .q_a        (ddram0_cpu_dat_r ),
    .address_b  (ddram0_sdr_adr   ),
    .byteena_b  (ddram0_sdr_bs    ),
    .wren_b     (ddram0_sdr_we    ),
    .data_b     (ddram0_sdr_dat_w ),
    .q_b        (ddram0_sdr_dat_r )
  );

  // data data ram 1
  assign ddram1_cpu_adr   = fill ? cpu_sm_adr[10:1] : {cpu_adr_idx, cpu_adr_blk_ptr[2:1]};
  assign ddram1_cpu_bs    = cpu_sm_bs;
  assign ddram1_cpu_we    = cpu_sm_dram1_we;
  assign ddram1_cpu_dat_w = cpu_sm_mem_dat_w;
  assign ddram1_sdr_adr   = sdr_sm_adr;
  assign ddram1_sdr_bs    = sdr_sm_bs;
  assign ddram1_sdr_we    = sdr_sm_dram1_we;
  assign ddram1_sdr_dat_w = sdr_sm_mem_dat_w;

`ifdef SOC_SIM
dpram_inf_be_1024x32
`else
dpram_be_1024x32
`endif
ddram1 (
    .clock      (clk              ),
    .address_a  (ddram1_cpu_adr   ),
    .byteena_a  (ddram1_cpu_bs    ),
    .wren_a     (ddram1_cpu_we    ),
    .data_a     (ddram1_cpu_dat_w ),
    .q_a        (ddram1_cpu_dat_r ),
    .address_b  (ddram1_sdr_adr   ),
    .byteena_b  (ddram1_sdr_bs    ),
    .wren_b     (ddram1_sdr_we    ),
    .data_b     (ddram1_sdr_dat_w ),
    .q_b        (ddram1_sdr_dat_r )
  );


endmodule

