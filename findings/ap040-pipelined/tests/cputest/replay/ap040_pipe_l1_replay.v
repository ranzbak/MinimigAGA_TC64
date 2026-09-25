//--------------------------------------------------------------------------//
// ap040_pipe_l1_replay.v - cputest corpus memory for the pipelined core.   //
//                                                                          //
// Drop-in replacement for rtl/ap040_pipe_l1.v (same module name, ports     //
// and parameters): compile this file INSTEAD of that one.  It is backed by //
// the corpus regions, not by one flat array:                              //
//   low memory   $0000_0000-$0000_7FFF   (lmem.dat)                       //
//   test memory  TBASE..TBASE+TSIZE-1    (tmem.dat; base/size from APR2)   //
//   high memory  $FFFF_8000-$FFFF_FFFF   (all zero: the corpus has none)  //
//   synthetic    SYN..SYN+$FFF           boot stub, vector table, handlers //
//                                         (written by the bench)           //
// Anything else reads 0 and ignores writes (as tb_dat_replay.v does);     //
// such accesses are counted in unmapped_rd/unmapped_wr.                   //
// boot_ovl (set by the bench around reset) answers the reset vector reads  //
// at $0-$7 with boot_isp/boot_pc instead of low memory.                    //
//                                                                          //
// Port behaviour exactly as rtl/ap040_pipe_l1.v:                           //
//   A: word index in (byte address = idx*2 + PC_RESET), the two words at   //
//      idx and idx+1 one clock later, held while en_a is low               //
//   R: rd_req one clock, byte address, size B/W/L, any alignment; rd_ack   //
//      and right-aligned data one clock later                              //
//   W: written at the clock edge; a read requested in the same clock sees  //
//      the write.                                                          //
// wr_log / wr_cnt record every port W write of the current round (address, //
// size, data, replaced bytes) for the bench's unexpected-write report.    //
//--------------------------------------------------------------------------//

module ap040_pipe_l1
#(
	parameter AW = 31,
	parameter DW = 16,
	parameter [31:0] PC_RESET = 32'h0000_0000
)
(
	input                clock,
	input                nreset,

	input      [AW-1:0]  address_a,
	input                en_a,
	output reg [31:0]    q_a,

	input                rd_req,
	input       [31:0]   rd_addr,
	input        [1:0]   rd_size,
	output reg           rd_ack,
	output reg  [31:0]   rd_data,

	input                wr_req,
	input       [31:0]   wr_addr,
	input        [1:0]   wr_size,
	input       [31:0]   wr_data,
	output               wr_ready
);

localparam [31:0] TMEM_MAX = 32'h0020_0000;
localparam [31:0] SYN      = 32'h7F00_0000;
localparam [31:0] SYN_SIZE = 32'h0000_1000;
localparam [31:0] HBASE    = 32'hFFFF_8000;

reg [7:0] lmem [0:32767];
reg [7:0] tmem [0:TMEM_MAX-1];
reg [7:0] hmem [0:32767];
reg [7:0] smem [0:SYN_SIZE-1];

reg [31:0] TBASE = 32'hFFFF_FFFF;
reg [31:0] TSIZE = 32'h0;
reg        boot_ovl = 1'b0;
reg [31:0] boot_isp = 32'h0;
reg [31:0] boot_pc  = 32'h0;

integer unmapped_rd = 0;
integer unmapped_wr = 0;

reg [31:0] wr_log_a  [0:255];
reg  [1:0] wr_log_sz [0:255];
reg [31:0] wr_log_d  [0:255];
reg [31:0] wr_log_o  [0:255];   // the bytes the write replaced
integer    wr_cnt = 0;

assign wr_ready = 1'b1;

integer i;
initial begin
	for (i = 0; i < 32768; i = i + 1) begin lmem[i] = 0; hmem[i] = 0; end
	for (i = 0; i < TMEM_MAX; i = i + 1) tmem[i] = 0;
	for (i = 0; i < SYN_SIZE; i = i + 1) smem[i] = 0;
end

function [7:0] be_byte(input [31:0] v, input [1:0] lane);
	case (lane)
		2'd0: be_byte = v[31:24];
		2'd1: be_byte = v[23:16];
		2'd2: be_byte = v[15:8];
		default: be_byte = v[7:0];
	endcase
endfunction

function mapped(input [31:0] a);
	mapped = (a[31:15] == 0) || (a >= TBASE && a - TBASE < TSIZE) ||
	         (a >= HBASE) || (a >= SYN && a - SYN < SYN_SIZE);
endfunction

// side-effect free byte read (the bench uses it too)
function [7:0] rd8(input [31:0] a);
	if (boot_ovl && a < 8)
		rd8 = be_byte(a < 4 ? boot_isp : boot_pc, a[1:0]);
	else if (a[31:15] == 0)
		rd8 = lmem[a[14:0]];
	else if (a >= TBASE && a - TBASE < TSIZE)
		rd8 = tmem[a - TBASE];
	else if (a >= HBASE)
		rd8 = hmem[a[14:0]];
	else if (a >= SYN && a - SYN < SYN_SIZE)
		rd8 = smem[a - SYN];
	else
		rd8 = 8'h00;
endfunction

// ok = 1 if the byte landed in a mapped region
task wr8(input [31:0] a, input [7:0] v, output ok);
	begin
		ok = 1'b1;
		if (a[31:15] == 0)                       lmem[a[14:0]] = v;
		else if (a >= TBASE && a - TBASE < TSIZE) tmem[a - TBASE] = v;
		else if (a >= HBASE)                      hmem[a[14:0]] = v;
		else if (a >= SYN && a - SYN < SYN_SIZE)  smem[a - SYN] = v;
		else                                      ok = 1'b0;
	end
endtask

function [2:0] nbytes(input [1:0] sz);
	nbytes = (sz == 2'd0) ? 3'd1 : (sz == 2'd1) ? 3'd2 : 3'd4;
endfunction

reg  [31:0] rv, ba, fa;
reg         okw, okr, okb;
integer     k, n;

always @(posedge clock) begin
	if (en_a) begin
		fa  = {address_a, 1'b0} + PC_RESET;
		q_a <= {rd8(fa), rd8(fa + 1), rd8(fa + 2), rd8(fa + 3)};
	end
	if (!nreset) begin
		rd_ack <= 1'b0;
	end else begin
		if (wr_req) begin
			n = nbytes(wr_size);
			okw = 1'b1;
			rv = 32'd0;
			for (k = 0; k < n; k = k + 1) rv = (rv << 8) | rd8(wr_addr + k);
			if (wr_cnt < 256) wr_log_o[wr_cnt] = rv;
			for (k = 0; k < n; k = k + 1) begin
				ba = wr_addr + k;
				wr8(ba, wr_data >> (8 * (n - 1 - k)), okb);
				if (!okb) okw = 1'b0;
			end
			if (!okw) unmapped_wr = unmapped_wr + 1;
			if (wr_cnt < 256) begin
				wr_log_a[wr_cnt] = wr_addr; wr_log_sz[wr_cnt] = wr_size; wr_log_d[wr_cnt] = wr_data;
			end
			wr_cnt = wr_cnt + 1;
		end
		rd_ack <= rd_req;
		if (rd_req) begin
			n = nbytes(rd_size);
			rv = 32'd0;
			okr = 1'b1;
			for (k = 0; k < n; k = k + 1) begin
				rv = (rv << 8) | rd8(rd_addr + k);
				if (!mapped(rd_addr + k) && !(boot_ovl && rd_addr + k < 8)) okr = 1'b0;
			end
			if (!okr) unmapped_rd = unmapped_rd + 1;
			rd_data <= rv;
		end
	end
end

endmodule
