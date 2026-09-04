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
//
// Modes:
//   0  write the whole range, then read-verify the whole range
//   1  read-verify only (run after a pause, to test retention)
//
// range_log2_i selects the number of bytes tested: 0 .. 2^range_log2 - 1 in
// 16-byte steps.  28 is the full 256 MB of the QMTECH board.  Values below 4
// are clamped to one line.
//
// first_err_xor_o is the LOW 32 bits of (expected ^ read), as specified by the
// bring-up brief.  An error confined to the upper 96 bits therefore shows as
// err_count>0 with first_err_xor_o == 0; first_err_addr_o still locates it.
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
                     phy_dqs_inc_i,     // 19:18 DLY_DQS_INC
                     phy_dqs_rst_i,     // 17:16 DLY_DQS_RST
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

function [127:0] pattern_data;
    input [  2:0] pat;
    input         pass;
    input [ 31:0] addr;
    reg   [  6:0] widx;
begin
    widx = addr[10:4];   // line index modulo 128, for the walking one
    case (pat)
    3'd0:    pattern_data = {addr + 32'd3, addr + 32'd2, addr + 32'd1, addr};
    3'd1:    pattern_data = addr[4] ? {8{16'hAAAA}} : {8{16'h5555}};
    3'd2:    pattern_data = (128'd1 << widx);
    3'd3:    pattern_data = lfsr32(addr);
    3'd4:    pattern_data = pass ? {128{1'b1}} : {128{1'b0}};
    default: pattern_data = {addr + 32'd3, addr + 32'd2, addr + 32'd1, addr};
    endcase
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

reg [  2:0] state_q;
reg [ 31:0] addr_q;
reg         pass_q;
reg         mode_q;
reg [  2:0] pattern_q;
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
wire [127:0] expect_w     = pattern_data(pattern_q, pass_q, addr_q);
wire [127:0] xor_w        = mem_read_data_i ^ expect_w;

always @(posedge clk_i)
if (rst_i)
begin
    state_q          <= ST_IDLE;
    addr_q           <= 32'b0;
    pass_q           <= 1'b0;
    mode_q           <= 1'b0;
    pattern_q        <= 3'b0;
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
            if (last_line_w)
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
                state_q <= ST_RD;
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
assign mem_wr_o         = (state_q == ST_WR) ? 16'hFFFF : 16'h0000;
assign mem_rd_o         = (state_q == ST_RD);
assign mem_addr_o       = addr_q;
assign mem_write_data_o = expect_w;

assign busy_o           = busy_q;
assign done_o           = done_q;
assign err_count_o      = err_count_q;
assign first_err_addr_o = first_err_addr_q;
assign first_err_xor_o  = first_err_xor_q;
assign lines_done_o     = lines_done_q;

endmodule
