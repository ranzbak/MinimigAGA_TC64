// Minimig autoconfig logic

module minimig_autoconfig
(
	input clk,
	input clk7_en,
	input reset,
	input [8:1] address_in,	//cpu address bus input
	output [15:0] data_out,
	input [15:0] data_in,
	input	rd,					//cpu read
	input	hwr,				//cpu high write
	input	lwr,				//cpu low write
	input sel,
	input [1:0] slowram_config,
	input	[1:0] fastram_config,
	input m68020,
	output reg [3:0] board_configured,
	output reg autoconfig_done
);

reg [2:0] acdevice;
reg [3:0] ramsize;
wire [8:0] roma_rd;
reg [8:0] roma_wr;
wire [3:0] rom_q;
reg rom_we;

assign roma_rd[5:0] = address_in[6:1];
assign roma_rd[8:6] = acdevice;
assign data_out = sel ? {rom_q,12'hfff} : 16'h0000;

Autoconfig_ROM acrom
(
	.clk(clk),
	.a_read(roma_rd),
	.a_write(roma_wr),	// We only write to change the size of the ZII RAM board
	.we(rom_we),
	.d(ramsize),
	.q(rom_q)
);

reg init;

always @(posedge clk)
begin

	if(reset)
	begin
		init=1'b1;
		board_configured<=4'b0000;
		acdevice<=3'b000;
		roma_wr<=9'h001;
	end

	rom_we<=1'b0;
	
	if(init)
	begin
		case(fastram_config)
			2'b00 : ramsize <= 4'b1111;  // don't care, disabled
			2'b01 : ramsize <= 4'b0110;	// 2 Meg
			2'b10 : ramsize <= 4'b0111;	// 4 Meg
			2'b11	: ramsize <= 4'b0000;  // 8 Meg
		endcase
		roma_wr[8:0] <= 9'h001;	// Write address for modifying size of ZII RAM.
		rom_we<=1'b1;
	
		// Either 1st board (ZII fast RAM) or null board if RAM is disabled
		acdevice <= |fastram_config ? 3'b000 : 3'b111;
		init<=1'b0;
	end
	else
	begin
		if(clk7_en && sel)
			autoconfig_done <= (acdevice==3'b111) ? 1'b1 : 1'b0;
	
		if(clk7_en && sel && (lwr|hwr))
		begin

			case({address_in,1'b0})
				9'h048 : begin	// Zorro II configures at 48
					case(acdevice)
						3'b000 : begin // ZII RAM
								board_configured[0] <= 1'b1;
								acdevice<=(&fastram_config & m68020) ? 3'b001 : 3'b111; // ZIII RAM next
							end
						default :
							;
					endcase
				end
				9'h044 : begin // Zorro III configures at 44 if in ZIII space, should be 48 in ZII space but seems to configure twice?
					case(acdevice)
						3'b001 : begin // ZIII RAM
								board_configured[1] <= 1'b1;
								
								roma_wr[8:6] <= 3'b010;
								roma_wr[5:0] <= 6'h05;	// Write address for modifying size of 2nd ZIII RAM.
								ramsize <= |slowram_config ? 4'b1000 : 4'b0111; // 2 meg or 4 meg
								rom_we<=1'b1;
								acdevice<=3'b010;
//								acdevice<=3'b011; // Ethernet after ZIII RAM
							end
						3'b010 : begin // ZIII RAM
								board_configured[2] <= 1'b1;
								acdevice<=3'b111; // NULL device to terminate the chain
							end
						3'b011 : begin // ETH
								board_configured[3] <= 1'b1;
								acdevice<=3'b111; // NULL device to terminate the chain
							end
						default:
							;
					endcase
				end
			endcase
		end
	end
end


endmodule
