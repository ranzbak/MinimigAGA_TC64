// Host cache
// Simplistic direct mapped Cache - 256 x 32bit words, so small enough to fit a single M9K
// - though Quartus chooses to use 2 - not sure why yet.
// 8 word bursts, 16-bit SDRAM interface, so cachelines of 4 32-bit words
// We use a dual-port RAM split between data and tag. 

module hostcache
(
	input wire sysclk,
	input wire reset_n,
	input wire [24:2] a,
	output wire [31:0] q,
	input wire req,
	input wire wr,
	output reg ack,
	input wire [15:0] sdram_d,
	output reg sdram_req,
	input wire sdram_ack
);


// host Cache signals

// 8 bits should result in using just 1 M9K - but doesn't,
// so we might as well make full use of 2 M9Ks with 9 bits.
parameter zcachebits=9;

wire [zcachebits-1:0] zdata_a;
wire [31:0] zdata_q;
reg[31:0] zdata_w;
reg zdata_wren;

wire [zcachebits-1:0] ztag_a;
wire [31:0] ztag_q;
reg [31:0] ztag_w;
reg ztag_wren;

// Host data always comes from the cache - we don't attempt to bypass during cache filling.
assign q = zdata_q;

// States for state machine
localparam zINIT=0, zWAIT=1, zREAD=2, zPAUSE=3;
localparam zWRITE=4, zWRITE2=5, zWAITFILL=6;
localparam zFLUSH1=7, zFLUSH2=8, zFILL1=9, zFILL2=10;
localparam zFILL3=11, zFILL4=12, zFILL5=13, zFILL6=14;
localparam zFILL7=15, zFILL8=16, zACK=17;
reg [17:0] zstate;
reg zinitcache;


// In the data blockram the lower two bits of the address determine
// which word of the burst we're reading.  When reading from the cache, this comes
// from the CPU address; when writing to the cache it's determined by the state
// machine.

reg zreadword_burst; // Set to 1 when the lsb of the cache address should
                     // track the SDRAM controller.
reg [1:0] zreadword;

wire [zcachebits-1:0] zcacheline;
assign zcacheline = {1'b0,a[zcachebits:4],(zreadword_burst ? zreadword : a[3:2])};

//   a bits 3:2 specify which words of a burst we're interested in.
//   Bits 10:4 specify the seven bit address of the cachelines;
assign zdata_a = zcacheline;


// Dual port RAM.
bytewrite_tdp_ram_rf #(
	.NUM_COL(1),
	.COL_WIDTH(32),
	.ADDR_WIDTH(zcachebits)
) hostcache (
	.clkA(sysclk),
	.clkB(sysclk),
	.addrA(zdata_a),
	.addrB(ztag_a),
	.dinA(zdata_w),
	.dinB(ztag_w),
	.doutA(zdata_q),
	.doutB(ztag_q),
	.weA(zdata_wren),
	.weB(ztag_wren),
	.enaA(1'b1),
	.enaB(1'b1)
);

wire zdata_valid;
assign zdata_valid = ztag_q[31];

reg [zcachebits-2:0] zinitctr;
assign ztag_a = zinitcache ? {1'b1,zinitctr} :
			{3'b100,a[zcachebits:4]};

wire ztag_hit;
assign ztag_hit = ztag_q[20:0]==a[24:4];

reg complete;

always @(posedge sysclk)
begin
	// Defaults
	zinitcache<=1'b0;	
	zdata_wren<=1'b0;
	ztag_wren<=1'b0;

	ack <= #1 1'b0;

	if(sdram_req)
		complete=1'b0;
	else if (!sdram_ack)
		complete=1'b1;

	case(zstate)

		// We use an init state here to loop through the data, clearing
		// the valid flag - for which we'll use bit 17 of the data entry.

		zINIT : begin
			zinitcache<=1'b1;	// need to mark the entire cache as invalid before starting.
			zinitctr<='h00000001;
			ztag_w = 32'h00000000;
			ztag_wren<=1'b1;
			zstate<=zFLUSH2;
		end

		zFLUSH2 : begin
			zinitcache<=1'b1;
			zinitctr<=zinitctr+1'd1;
			ztag_wren<=1'b1;
			if(zinitctr==0)
			begin
				zstate<=zWAIT;
			end
		end

		zWAIT : begin
			zreadword_burst <= 1'b0;
			ztag_w = {4'b1111,7'b0000000,a[24:4]};
			if(req) begin
				if(wr) begin// Write cycle - invalidate cacheline (FIXME - only when hit)
					if(complete) begin
						sdram_req<=1'b1;
						ztag_w = {4'b0000,7'b0000000,a[24:4]};
						if(ztag_hit)
							ztag_wren<=1'b1;
						zstate<=zWRITE;
					end
				end else	begin	// Read cycle
					zstate<=zREAD;
				end
			end
		end
		
		zWRITE : begin
			if(sdram_ack) begin
				sdram_req<=1'b0;
				ack<=1'b1;
				zstate<=zPAUSE;
			end
		end

		zREAD : begin
			// Check tags for a match...
			if(ztag_hit && zdata_valid) begin
				ack<=1'b1;
				zstate<=zPAUSE;
			end else begin // No matches?
				zreadword_burst <= 1'b1;
				zreadword<=a[3:2];
				if(complete) begin
					sdram_req<=1'b1;
					zstate<=zFILL1;
				end
			end
		end

		zACK : begin
			ack<=1'b1;
			zstate<=zPAUSE;
		end
		
		zPAUSE :	begin
			if(!req) begin
				zstate<=zWAIT;
			end
		end

		zFILL1 : begin
			zdata_w[31:16]<=sdram_d;
			if(sdram_ack) begin
				sdram_req<=1'b0;
				zstate<=zFILL2;
			end
		end

		zFILL2 : begin
			ztag_wren<=1'b1;	// Update tag as the first word becomes complete.
			zdata_w[15:0]<=sdram_d;
			zdata_wren<=1'b1;
			zstate<=zFILL3;
		end
		
		zFILL3 : begin
			zreadword<=zreadword+1'd1;
			zdata_w[31:16]<=sdram_d;
			zstate<=zFILL4;
		end

		zFILL4 : begin
			zdata_w[15:0]<=sdram_d;
			zdata_wren<=1'b1;
			zstate<=zFILL5;
		end

		zFILL5 : begin
			zreadword<=zreadword+1'd1;
			zdata_w[31:16]<=sdram_d;
			zstate<=zFILL6;
		end

		zFILL6 : begin
			zdata_w[15:0]<=sdram_d;
			zdata_wren<=1'b1;
			zstate<=zFILL7;
		end

		zFILL7 : begin
			zreadword<=zreadword+1'd1;
			zdata_w[31:16]<=sdram_d;
			zstate<=zFILL8;
		end

		zFILL8 : begin
			zdata_w[15:0]<=sdram_d;
			zdata_wren<=1'b1;
			zstate<=zWAIT;
		end
		
		default:
			zstate<=zWAIT;
	endcase

	if(!reset_n) begin
		zstate<=zINIT;
		zreadword_burst<=1'b0;
	end
end

endmodule
