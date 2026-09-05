//-----------------------------------------------------------------
// ddr3_bist - built-in self test for the DDR3 island (100 MHz domain)
//
// Bring-up engine for hardware stage A (findings/ddr3/implementation-plan.md
// section 2).  It owns the controller's native 128-bit port while `busy_o` is
// high; ddr3_top muxes the port away from the external requester for exactly
// that time.  Every control is a plain register with no handshake, so a VIO
// can drive it from JTAG.
//
// Request discipline (lib/core_ddr3_controller/README.md, "Native port"):
//   hold rd/wr/addr/wdata stable until inport_accept_o, then drop rd/wr and
//   wait for inport_ack_o.  Exactly one request is in flight, so req_id can be
//   tied to 0 and responses are trivially in order.  A write ack means the
//   command was issued, not that the data has reached the array.
//
// Byte-enable / lane mapping (shared with rtl/ddr3/ddr3_fastram.v):
//   byte n of the 128-bit line is bits [8n+7:8n]; 16-bit word k is
//   [16k+15:16k] with the low byte at the lower index.
//
// Patterns (per 16-byte line at byte address A):
//   0  address-as-data : {A+3, A+2, A+1, A}
//   1  0x5555.. / 0xAAAA.. alternating per line (bit 4 of the address)
//   2  walking ones     : 1 << (line index mod 128)
//   3  LFSR-32 seeded by the address, 4 words
//   4  two passes: all-zeros over the range, then all-ones over the range
//   5  masked  : background then a MASKED overwrite, then verify (see below)
//   6  wordwr  : background then eight 16-bit word writes, then verify
//
// Patterns 0..4 write the whole range and then read-verify the whole range.
// Patterns 5 and 6 are DM (data mask) tests and work LINE AT A TIME, because
// they need a read-modify-write ordering per line:
//
//   pattern 5 "masked"  (this is the CPU-path byte-enable proof)
//     B = LFSR-32(A) (the "background"), F = ~B (the "foreground").
//     phase 0: write the whole line with B and all 16 byte enables set,
//     phase 1: write the SAME line with F and only the byte enables in the
//              mask M(A) set - i.e. the DDR3 DM lanes are driven for the
//              first time,
//     then read the line and compare against
//              expected = (F & M) | (B & ~M)   bytewise.
//     M(A) cycles with the line index c = A[8:4] (32 lines = 512 bytes per
//     full cycle, so range_log2_i >= 9 exercises every mask):
//        c =  0..15  single byte      : 1 << c            (byte c only)
//        c = 16..23  one 16-bit word  : 3 << 2*(c-16)     (word c-16)
//        c = 24      0x5555  alternating bytes, even
//        c = 25      0xAAAA  alternating bytes, odd
//        c = 26..29  one 32-bit word  : 0x000F/0x00F0/0x0F00/0xF000
//                    (i.e. the low and high 16-bit half of each 32-bit word,
//                     covered pairwise by c = 16..23 and as a pair here)
//        c = 30      0x00FF  low half of the line
//        c = 31      0xFF00  high half of the line
//     Every byte position n is therefore both WRITTEN under a mask (c = n,
//     c = 16+n/2, and several of 24..31) and LEFT ALONE under a mask
//     (c = any other single-byte entry) within one 512-byte cycle, so a DM
//     lane stuck active shows as a corrupted background byte and a DM lane
//     stuck inactive shows as a foreground byte that never arrived.
//     M is never zero: a request with no byte enables is not a write.
//
//   pattern 6 "wordwr"
//     Mimics cpu_cache_new's write buffer exactly: ONE 16-bit word per
//     request, two byte enables set (rtl/ddr3/ddr3_fastram.v builds the same
//     shape from sdr_dqm_w for a 16-bit CPU write).
//     phase 0   : write the whole line with B, all 16 byte enables,
//     phase 1..8: write word k = phase-1 of the line with F and byte enables
//                 3 << 2*k  (bytes 2k and 2k+1) - eight separate requests,
//     then read the line and compare against F.  A word write that lands on
//     the wrong word, or that writes more or fewer than its two bytes, leaves
//     background behind and is caught.
//
// Modes:
//   0  write the whole range, then read-verify the whole range
//      (patterns 5/6: background + masked writes + verify, line at a time)
//   1  read-verify only (run after a pause, to test retention).  For patterns
//      5 and 6 this re-checks the same expected value without rewriting, so it
//      proves the masked write actually reached the array.
//
// range_log2_i selects the number of bytes tested: 0 .. 2^range_log2 - 1 in
// 16-byte steps.  28 is the full 256 MB of the QMTECH board.  Values below 4
// are clamped to one line.
//
// first_err_xor_o is the LOW 32 bits of (expected ^ read), as specified by the
// bring-up brief.  An error confined to the upper 96 bits therefore shows as
// err_count>0 with first_err_xor_o == 0; first_err_addr_o still locates it.
//
// pattern_i is 3 bits and codes 5 and 6 fit in it, so the vio_ddr3 probe map
// (tools/vivado/build.tcl) and tools/vivado/ddr3_bist.tcl are UNCHANGED.
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module ddr3_bist
(
     input           clk_i
    ,input           rst_i

    // Control (plain registers, VIO driven)
    ,input           start_i           // rising edge starts a run
    ,input  [  2:0]  pattern_i
    ,input  [  4:0]  range_log2_i
    ,input           mode_i            // 0 = write+verify, 1 = verify only

    // Status
    ,output          busy_o
    ,output          done_o
    ,output [ 31:0]  err_count_o
    ,output [ 31:0]  first_err_addr_o
    ,output [ 31:0]  first_err_xor_o
    ,output [ 31:0]  lines_done_o

    // PHY delay / latency configuration (plain registers, VIO driven).
    // Field positions are the `DDR_PHY_CFG_*_R defines in
    // lib/core_ddr3_controller/src_v/phy/xc7/ddr3_dfi_phy.v.
    //
    // Since the read-path rework the PHY no longer captures with the DQS
    // strobe, so phy_dqs_inc_i / phy_dqs_rst_i are NO-OPS: they keep their bit
    // positions (19:18 / 17:16) so the VIO probe map and
    // tools/vivado/ddr3_bist.tcl do not change, but nothing consumes them.
    // The controls that matter are phy_rdsel_i (which oversample is the beat
    // centre), phy_rdlat_i (whole clk100 cycles) and phy_dq_inc/rst_i (the
    // per-lane DQ IDELAYE2 fine trim, 78 ps a tap).
    ,input           phy_cfg_valid_i   // rising edge applies the fields below
    ,input  [  1:0]  phy_dqs_inc_i
    ,input  [  1:0]  phy_dqs_rst_i
    ,input  [  1:0]  phy_dq_inc_i
    ,input  [  1:0]  phy_dq_rst_i
    ,input  [  2:0]  phy_rdlat_i
    ,input  [  3:0]  phy_rdsel_i
    ,output          phy_cfg_valid_o   // one-cycle pulse to ddr3_dfi_phy.cfg_valid_i
    ,output [ 31:0]  phy_cfg_o         // to ddr3_dfi_phy.cfg_i

    // Controller native port (master)
    ,output [ 15:0]  mem_wr_o
    ,output          mem_rd_o
    ,output [ 31:0]  mem_addr_o
    ,output [127:0]  mem_write_data_o
    ,input           mem_accept_i
    ,input           mem_ack_i
    ,input  [127:0]  mem_read_data_i
);

//-----------------------------------------------------------------
// PHY configuration register block
//-----------------------------------------------------------------
reg phy_cfg_valid_q;
always @(posedge clk_i)
    if (rst_i) phy_cfg_valid_q <= 1'b0;
    else       phy_cfg_valid_q <= phy_cfg_valid_i;

// The PHY itself edge-detects cfg_valid_i, but a clean one-cycle pulse keeps
// a slow VIO write from being seen as many applications of the same field.
assign phy_cfg_valid_o = phy_cfg_valid_i & ~phy_cfg_valid_q;

assign phy_cfg_o = { 8'b0,
                     phy_dq_inc_i,      // 23:22 DLY_DQ_INC
                     phy_dq_rst_i,      // 21:20 DLY_DQ_RST
                     phy_dqs_inc_i,     // 19:18 DLY_DQS_INC  (no-op)
                     phy_dqs_rst_i,     // 17:16 DLY_DQS_RST  (no-op)
                     5'b0,
                     phy_rdlat_i,       // 10:8  RDLAT
                     4'b0,
                     phy_rdsel_i };     //  3:0  RDSEL

//-----------------------------------------------------------------
// Pattern generation
//-----------------------------------------------------------------
function [127:0] lfsr32;
    input [31:0] seed;
    reg   [31:0] s;
    integer i, j;
begin
    s = seed ^ 32'h12345678;
    if (s == 32'b0) s = 32'h1;
    lfsr32 = 128'b0;
    for (j = 0; j < 4; j = j + 1)
    begin
        for (i = 0; i < 32; i = i + 1)
            s = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};   // x^32+x^22+x^2+x^1+1
        lfsr32[j*32 +: 32] = s;
    end
end
endfunction

// The LFSR value is passed in rather than recomputed here so that the whole
// design contains exactly one LFSR XOR tree (patterns 3, 5 and 6 share it).
function [127:0] pattern_data;
    input [  2:0] pat;
    input         pass;
    input [ 31:0] addr;
    input [127:0] lfsr;
    reg   [  6:0] widx;
begin
    widx = addr[10:4];   // line index modulo 128, for the walking one
    case (pat)
    3'd0:    pattern_data = {addr + 32'd3, addr + 32'd2, addr + 32'd1, addr};
    3'd1:    pattern_data = addr[4] ? {8{16'hAAAA}} : {8{16'h5555}};
    3'd2:    pattern_data = (128'd1 << widx);
    3'd3:    pattern_data = lfsr;
    3'd4:    pattern_data = pass ? {128{1'b1}} : {128{1'b0}};
    default: pattern_data = {addr + 32'd3, addr + 32'd2, addr + 32'd1, addr};
    endcase
end
endfunction

// Byte-enable mask for pattern 5, selected by the line index (see the header).
// Never returns 0: a request with no byte enables set is not a write.
function [15:0] mask_sel;
    input [31:0] addr;
    reg   [ 4:0] c;
begin
    c = addr[8:4];
    if (c < 5'd16)
        mask_sel = (16'd1 << c);                       // single byte c
    else if (c < 5'd24)
        mask_sel = (16'd3 << ((c - 5'd16) << 1));      // 16-bit word c-16
    else
        case (c[2:0])
        3'd0:    mask_sel = 16'h5555;                  // alternating, even bytes
        3'd1:    mask_sel = 16'hAAAA;                  // alternating, odd bytes
        3'd2:    mask_sel = 16'h000F;                  // 32-bit word 0
        3'd3:    mask_sel = 16'h00F0;                  // 32-bit word 1
        3'd4:    mask_sel = 16'h0F00;                  // 32-bit word 2
        3'd5:    mask_sel = 16'hF000;                  // 32-bit word 3
        3'd6:    mask_sel = 16'h00FF;                  // low half of the line
        default: mask_sel = 16'hFF00;                  // high half of the line
        endcase
end
endfunction

// 16 byte enables -> 128 bit-lane mask.
function [127:0] be_expand;
    input [15:0] be;
    integer n;
begin
    be_expand = 128'b0;
    for (n = 0; n < 16; n = n + 1)
        be_expand[n*8 +: 8] = {8{be[n]}};
end
endfunction

//-----------------------------------------------------------------
// Control FSM
//-----------------------------------------------------------------
localparam ST_IDLE   = 3'd0;
localparam ST_WR     = 3'd1;
localparam ST_WR_ACK = 3'd2;
localparam ST_RD     = 3'd3;
localparam ST_RD_ACK = 3'd4;
localparam ST_DONE   = 3'd5;

localparam PAT_MASKED = 3'd5;
localparam PAT_WORDWR = 3'd6;

reg [  2:0] state_q;
reg [ 31:0] addr_q;
reg         pass_q;
reg         mode_q;
reg [  2:0] pattern_q;
reg [  3:0] phase_q;          // sub-step within a line, patterns 5 and 6 only
reg [ 31:0] limit_q;          // byte count, always a multiple of 16
reg         first_err_q;
reg [ 31:0] err_count_q;
reg [ 31:0] first_err_addr_q;
reg [ 31:0] first_err_xor_q;
reg [ 31:0] lines_done_q;
reg         busy_q;
reg         done_q;
reg         start_d_q;

wire        start_pulse_w = start_i & ~start_d_q;
wire [31:0] limit_w       = (range_log2_i < 5'd4) ? 32'd16 : (32'd1 << range_log2_i);
wire        last_line_w   = ((addr_q + 32'd16) >= limit_q);

// Patterns 5 and 6 run background-write / masked-write(s) / verify per LINE
// instead of write-everything then verify-everything.
wire        perline_w      = (pattern_q == PAT_MASKED) || (pattern_q == PAT_WORDWR);
wire [ 3:0] last_wr_phase_w = (pattern_q == PAT_WORDWR) ? 4'd8 : 4'd1;

wire [127:0] lfsr_w       = lfsr32(addr_q);
wire [127:0] bg_w         = lfsr_w;                 // background
wire [127:0] fg_w         = ~lfsr_w;                // foreground, inverse of it
wire [ 15:0] mask_w       = mask_sel(addr_q);       // pattern 5 byte enables
wire [127:0] mask_bits_w  = be_expand(mask_w);
// pattern 6: byte enables of 16-bit word (phase-1); phase 0 is the background.
wire [ 15:0] wordmask_w   = 16'h0003 << ((phase_q - 4'd1) * 2);

wire [ 15:0] be_w         = (!perline_w)         ? 16'hFFFF :
                            (phase_q == 4'd0)    ? 16'hFFFF :
                            (pattern_q == PAT_MASKED) ? mask_w : wordmask_w;

wire [127:0] expect_w     = (pattern_q == PAT_MASKED) ?
                                ((fg_w & mask_bits_w) | (bg_w & ~mask_bits_w)) :
                            (pattern_q == PAT_WORDWR) ? fg_w :
                                pattern_data(pattern_q, pass_q, addr_q, lfsr_w);

wire [127:0] wdata_w      = (!perline_w)      ? expect_w :
                            (phase_q == 4'd0) ? bg_w : fg_w;

wire [127:0] xor_w        = mem_read_data_i ^ expect_w;

always @(posedge clk_i)
if (rst_i)
begin
    state_q          <= ST_IDLE;
    addr_q           <= 32'b0;
    pass_q           <= 1'b0;
    mode_q           <= 1'b0;
    pattern_q        <= 3'b0;
    phase_q          <= 4'b0;
    limit_q          <= 32'd16;
    first_err_q      <= 1'b0;
    err_count_q      <= 32'b0;
    first_err_addr_q <= 32'b0;
    first_err_xor_q  <= 32'b0;
    lines_done_q     <= 32'b0;
    busy_q           <= 1'b0;
    done_q           <= 1'b0;
    start_d_q        <= 1'b0;
end
else
begin
    start_d_q <= start_i;

    case (state_q)
    //-------------------------------------------------------------
    ST_IDLE:
        if (start_pulse_w)
        begin
            // Latch the controls so a VIO write during the run cannot corrupt it.
            mode_q           <= mode_i;
            pattern_q        <= pattern_i;
            limit_q          <= limit_w;
            addr_q           <= 32'b0;
            pass_q           <= 1'b0;
            phase_q          <= 4'b0;
            first_err_q      <= 1'b0;
            err_count_q      <= 32'b0;
            first_err_addr_q <= 32'b0;
            first_err_xor_q  <= 32'b0;
            lines_done_q     <= 32'b0;
            busy_q           <= 1'b1;
            done_q           <= 1'b0;
            state_q          <= mode_i ? ST_RD : ST_WR;
        end
    //-------------------------------------------------------------
    ST_WR:
        if (mem_accept_i)
            state_q <= ST_WR_ACK;
    //-------------------------------------------------------------
    ST_WR_ACK:
        if (mem_ack_i)
        begin
            if (perline_w)
            begin
                // Stay on this line until the background and every masked
                // write have been issued, then verify it.
                if (phase_q == last_wr_phase_w)
                begin
                    phase_q <= 4'd0;
                    state_q <= ST_RD;
                end
                else
                begin
                    phase_q <= phase_q + 4'd1;
                    state_q <= ST_WR;
                end
            end
            else if (last_line_w)
            begin
                addr_q  <= 32'b0;
                state_q <= ST_RD;
            end
            else
            begin
                addr_q  <= addr_q + 32'd16;
                state_q <= ST_WR;
            end
        end
    //-------------------------------------------------------------
    ST_RD:
        if (mem_accept_i)
            state_q <= ST_RD_ACK;
    //-------------------------------------------------------------
    ST_RD_ACK:
        if (mem_ack_i)
        begin
            lines_done_q <= lines_done_q + 32'd1;

            if (xor_w != 128'b0)
            begin
                err_count_q <= err_count_q + 32'd1;
                if (!first_err_q)
                begin
                    first_err_q      <= 1'b1;
                    first_err_addr_q <= addr_q;
                    first_err_xor_q  <= xor_w[31:0];
                end
            end

            if (last_line_w)
            begin
                // Pattern 4 is a two-pass test: zeros over the range, then ones.
                if ((pattern_q == 3'd4) && (pass_q == 1'b0))
                begin
                    pass_q  <= 1'b1;
                    addr_q  <= 32'b0;
                    state_q <= mode_q ? ST_RD : ST_WR;
                end
                else
                    state_q <= ST_DONE;
            end
            else
            begin
                addr_q  <= addr_q + 32'd16;
                // Patterns 5/6 go back to the write phases for the next line
                // (unless this is a verify-only run).
                state_q <= (perline_w && !mode_q) ? ST_WR : ST_RD;
            end
        end
    //-------------------------------------------------------------
    ST_DONE:
    begin
        busy_q  <= 1'b0;
        done_q  <= 1'b1;
        state_q <= ST_IDLE;
    end
    //-------------------------------------------------------------
    default: state_q <= ST_IDLE;
    endcase
end

//-----------------------------------------------------------------
// Outputs
//-----------------------------------------------------------------
assign mem_wr_o         = (state_q == ST_WR) ? be_w : 16'h0000;
assign mem_rd_o         = (state_q == ST_RD);
assign mem_addr_o       = addr_q;
assign mem_write_data_o = wdata_w;

assign busy_o           = busy_q;
assign done_o           = done_q;
assign err_count_o      = err_count_q;
assign first_err_addr_o = first_err_addr_q;
assign first_err_xor_o  = first_err_xor_q;
assign lines_done_o     = lines_done_q;

endmodule
