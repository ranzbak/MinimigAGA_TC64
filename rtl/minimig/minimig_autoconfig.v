// Minimig autoconfig logic

module minimig_autoconfig #(
	parameter TOCCATA_SND = 1'b0, // Toccata sound card enabled?
	// Third Zorro-III RAM board ("leftover" space in the SDRAM map).  It does
	// not exist when the Zorro-III fast RAM lives on the DDR3 island
	// (findings/ddr3/design.md D8), and a board that is autoconfigured but has
	// no memory behind it would corrupt the OS free list.  With this 0 the
	// chain skips straight from the ZIII board(s) to the Toccata card or to the
	// NULL terminator, using the same acdevice values the 0x44 handler already
	// uses -- no new mechanism.
	parameter Z3RAM3 = 1'b1
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
	output reg [4:0] board_configured,
	output reg [4:0] board_shutup,
	output wire [7:0] toccata_base_addr, // Base address for the cards
	output reg autoconfig_done
);

// IO base for cards
reg [7:0] board_base_addr [0:4];
assign toccata_base_addr = board_base_addr[4];

reg [2:0] acdevice;
// A Zorro III PIC that configures in the Zorro II configuration block is given
// its base address with *two* writes (Zorro III spec 8.2, register 44/48):
// register 44 takes A31-A24 and register 48 takes A23-A16, and the ordering
// table lists 44 first.  This block acts on the 44 write, so the 48 write that
// follows arrives after acdevice has already moved on and would be taken as the
// configuration of the *next* device -- with TOCCATA_SND and Z3RAM3 = 0 that
// next device is the Toccata card, which was then silently configured at base
// $00 and never offered to the OS at all.  No real board can be configured
// before the OS has read its ROM, so a base-address write at 48 that arrives
// with no configuration-space read in between is always such a leftover.
reg z3_base_wr;
// What follows the third ZIII RAM board in the chain: the Toccata card if it is
// enabled, otherwise the NULL device that terminates autoconfig.  Also used
// directly when Z3RAM3 = 0 and that board is skipped altogether.
wire [2:0] ac_after_z3ram3 = (TOCCATA_SND == 1'b1) ? 3'b101 : 3'b111;

// The device the chain moves to once the OS is done with the current one --
// whether that is because the board was configured (register 44/48) or because
// it was told to shut up (register 4C).  Kept in one place so the two paths
// cannot drift apart.
function [2:0] ac_next;
	input [2:0] dev;
	begin
		case(dev)
			3'b000  : ac_next = (&fastram_config & m68020) ? 3'b001 : 3'b111; // ZII RAM -> ZIII RAM
			3'b001  : ac_next = ram_64meg ? 3'b010 : (Z3RAM3 ? 3'b011 : ac_after_z3ram3);
			3'b010  : ac_next = Z3RAM3 ? 3'b011 : ac_after_z3ram3;
			3'b011  : ac_next = ac_after_z3ram3;
			3'b100  : ac_next = 3'b111; // ETH
			3'b101  : ac_next = 3'b111; // Toccata
			default : ac_next = 3'b111; // unused / NULL: stay on the terminator
		endcase
	end
endfunction
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
		z3_base_wr<=1'b0;

		// board_base_addr is [0:4]; entry 4 is the Toccata base that gary.v
		// compares against A23-A16, so it has to be cleared too.
		for (loop = 0; loop < 5; loop = loop + 1) begin
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

			// Any read of the configuration space means the OS has moved on
			// to the next board, so the next 48 write is that board's own.
			if(clk7_en && sel && !(lwr|hwr))
				z3_base_wr <= 1'b0;

			if(clk7_en && sel && (lwr|hwr))
			begin
				case({address_in,1'b0})
					9'h048 : if(!z3_base_wr) begin  // Zorro II configures at 48
						case(acdevice)
							3'b000 : begin // ZII RAM
								board_configured[0] <= 1'b1;
								acdevice<=ac_next(acdevice); // ZIII RAM next, or the NULL device
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
								z3_base_wr <= 1'b1;
								roma_wr[8:6] <= 3'b011; // Third ZIII entry
								roma_wr[5:0] <= 6'h05;  // Write address for modifying size of 2nd ZIII RAM.
								ramsize <= |slowram_config ? 4'b1000 : 4'b0111; // 2 meg or 4 meg
								rom_we<=1'b1;
								// skip straight to 3'b011 on 32 meg platforms
								acdevice<=ac_next(acdevice);
//                              acdevice<=3'b011; // Ethernet after ZIII RAM
							end
							3'b010 : begin // ZIII RAM 2 - 2nd 32 meg on 64 meg platforms
								board_configured[2] <= 1'b1;
								z3_base_wr <= 1'b1;
								acdevice<=ac_next(acdevice);
							end
							3'b011 : begin // ZIII RAM 3 - Use leftover space in the memory map.
								board_configured[3] <= 1'b1;
								z3_base_wr <= 1'b1;
								acdevice<=ac_next(acdevice);
							end
							3'b100 : begin // ETH
								board_configured[3] <= 1'b1;
								z3_base_wr <= 1'b1;
								acdevice<=3'b111; // NULL device to terminate the chain
							end
							default:
								;
						endcase
					end
					9'h04c : begin // Zorro II / III shut up register (ec_Shutup, spec 8.2)
						// A board that is told to shut up has to stop answering
						// in the configuration space just as a configured one
						// does, and the chain has to move on to the next board.
						// Without the advance the OS keeps being offered the
						// same board forever and autoconfig never terminates --
						// the ZII RAM board and the Toccata both advertise
						// NOSHUTUP clear, so the OS is allowed to do this.
						case(acdevice)
							3'b000: board_shutup[0] <= 1'b1; // ZII RAM
							3'b001: board_shutup[1] <= 1'b1; // ZIII RAM
							3'b010: board_shutup[2] <= 1'b1; // ZIII RAM 2
							3'b011: board_shutup[3] <= 1'b1; // ZIII RAM 3
							3'b100: board_shutup[3] <= 1'b1; // ETH (shares bit 3 with the 44 handler)
							3'b101: board_shutup[4] <= 1'b1; // Toccata sound card
							default:
								;
						endcase
						// Same successor the 44/48 handlers would have picked.
						acdevice<=ac_next(acdevice);
					end
				endcase
			end
		end
	end
end


endmodule
