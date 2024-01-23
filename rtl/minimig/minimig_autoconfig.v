// Minimig autoconfig logic

module minimig_autoconfig #(
	parameter TOCCATA_SND = 1'b0 // Toccata sound card enabled?
) (
	input clk,
	input clk7_en,
	input reset,
	input [8:1] address_in, //cpu address bus input
	output [15:0] data_out,
	input [15:0] data_in,
	input   rd,                 //cpu read
	input   hwr,                //cpu high write
	input   lwr,                //cpu low write
	input sel,
	input [1:0] slowram_config,
	input   [1:0] fastram_config,
	input m68020,
	input ram_64meg,
	(* MARK_DEBUG = "true", KEEP = "true" *)
	output reg [4:0] board_configured,
	(* MARK_DEBUG = "true", KEEP = "true" *)
	output reg [4:0] board_shutup,
	(* MARK_DEBUG = "true", KEEP = "true" *)
	output wire [7:0] toccata_base_addr, // Base address for the cards
	output reg autoconfig_done
);

// IO base for cards
reg [7:0] board_base_addr [0:4];
assign toccata_base_addr = board_base_addr[4];

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
	.a_write(roma_wr),  // We only write to change the size of the ZII RAM board
	.we(rom_we),
	.d(ramsize),
	.q(rom_q)
);

reg init;

integer loop;
always @(posedge clk)
begin
	rom_we<=1'b0;

	if(reset) begin
		init<=1'b1;
		board_configured<=5'b00000;
		board_shutup<=5'b00000;
		acdevice<=3'b000;
		roma_wr<=9'h001;
		ramsize<=4'b1111; // disabled
		autoconfig_done<=1'b0;

		for (loop = 0; loop < 4; loop = loop + 1) begin
			board_base_addr[loop] <= 8'h00;
		end
	end else begin



		if(init)
		begin
			case(fastram_config)
				2'b00 : ramsize <= 4'b1111;  // don't care, disabled
				2'b01 : ramsize <= 4'b0110; // 2 Meg
				2'b10 : ramsize <= 4'b0111; // 4 Meg
				2'b11   : ramsize <= 4'b0000;  // 8 Meg
			endcase
			roma_wr[8:0] <= 9'h001; // Write address for modifying size of ZII RAM.
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
					9'h048 : begin  // Zorro II configures at 48
						case(acdevice)
							3'b000 : begin // ZII RAM
								board_configured[0] <= 1'b1;
								acdevice<=(&fastram_config & m68020) ? 3'b001 : 3'b111; // ZIII RAM next
							end
							3'b101: begin // Toccata sound card
								board_configured[4] <= 1'b1;
								acdevice<=3'b111; // NULL device to terminate the chain
								board_base_addr[4] <= data_in[7:0]; // Store Toccata base address
							end
							default :
								;
						endcase
					end
					9'h044 : begin // Zorro III configures at 44 if in ZIII space, should be 48 in ZII space but seems to configure twice?
						case(acdevice)
							3'b001 : begin // ZIII RAM
								board_configured[1] <= 1'b1;
								roma_wr[8:6] <= 3'b011; // Third ZIII entry
								roma_wr[5:0] <= 6'h05;  // Write address for modifying size of 2nd ZIII RAM.
								ramsize <= |slowram_config ? 4'b1000 : 4'b0111; // 2 meg or 4 meg
								rom_we<=1'b1;
								// skip straight to 3'b011 on 32 meg platforms
								acdevice<=ram_64meg ? 3'b010 : 3'b011;
//                              acdevice<=3'b011; // Ethernet after ZIII RAM
							end
							3'b010 : begin // ZIII RAM 2 - 2nd 32 meg on 64 meg platforms
								board_configured[2] <= 1'b1;
								acdevice<=3'b011;
							end
							3'b011 : begin // ZIII RAM 3 - Use leftover space in the memory map.
								board_configured[3] <= 1'b1;
								if (TOCCATA_SND == 1'b1) begin
									acdevice<=3'b101; // Toccata sound card
								end else begin
									acdevice<=3'b111; // NULL device to terminate the chain
								end
							end
							3'b100 : begin // ETH
								board_configured[3] <= 1'b1;
								acdevice<=3'b111; // NULL device to terminate the chain
							end
							default:
								;
						endcase
					end
					9'h04c : begin // Zorre II / III shut up register
						case(acdevice)
							3'b101: begin // Shut up Toccata Sound card
								board_shutup[4] <= 1'b1;
							end
							default:
								;
						endcase
					end
				endcase
			end
		end
	end
end


endmodule
