/* amiga_clk.v */
/* 2012, rok.krajnc@gmail.com */


module amiga_clk (
  input  wire           rst,        // asynhronous reset input
  input  wire           ntsc,       // pal/ntsc clock select
  input  wire           clk_in,     // input clock        ( 27.000000MHz)
  output wire           clk_114,    // SDRAM ctrl   clock (114.750000MHz)
  output wire           clk_sdram,  // SDRAM output clock (114.750000MHz, -146.25 deg)
  output wire           clk_28,     // 28MHz output clock ( 28.375160MHz)
  output wire           clk7_en,    // 7MHz output clock enable (on 28MHz clock domain)
  output wire           clk7n_en,   // 7MHz negedge output clock enable (on 28MHz clock domain)
  output wire           c1,         // clk28m clock domain signal synchronous with clk signal
  output wire           c3,         // clk28m clock domain signal synchronous with clk signal delayed by 90 degrees
  output wire           cck,        // colour clock output (3.54 MHz)
  output wire [ 10-1:0] eclk,       // 0.709379 MHz clock enable output (clk domain pulse)
  output wire           locked      // PLL locked output
);


// simulation clocks ////
`ifdef SOC_SIM
reg            clk_114_r;
reg            clk_28_r;
reg            clk_sdram_r;
reg            pll_locked_r;
initial begin
  pll_locked_r  = 1'b0;
  wait (!rst);
  #50;
  pll_locked_r  = 1'b1;
end
initial begin
  clk_114_r     = 1'b1;
  #1;
  wait (pll_locked_r);
  #3;
  forever #4.357  clk_114_r   = ~clk_114_r;
end
initial begin
  clk_28_r      = 1'b1;
  #1;
  wait (pll_locked_r);
  #5;
  forever #17.428 clk_28_r    = ~clk_28_r;
end
initial begin
  clk_sdram_r   = 1'b1;
  #1;
  wait (pll_locked_r);
  #3;
  forever #4.357  clk_sdram_r = ~clk_sdram_r;
end
assign clk_114    = clk_114_r;
assign clk_28     = clk_28_r;
assign clk_sdram  = clk_sdram_r;
assign locked = pll_locked_r;

`else


//// hardware clocks ////

// device-specific PLL/DCM

`ifdef MINIMIG_ALTERA
amiga_clk_altera amiga_clk_i (
  .areset   (rst      ),
  .inclk0   (clk_in   ),
  .c0       (clk_sdram),
  .c1       (clk_114  ),
  .c2       (clk_28   ),
  .locked   (locked   )
);
`endif

//`ifdef MINIMIG_XILINX
amiga_clk_xilinx amiga_clk_i (
  .areset   (rst      ),
  .inclk0   (clk_in   ),
  .c0       (clk_114  ),
  .c1       (clk_28   ),
  .c2       (clk_sdram),
  .locked   (locked   )
);
//`endif

`ifdef MINIMIG_ALTERA_PLL_RECONFIG
wire       pll_reconfig_busy;
wire       pll_areset;
wire       pll_configupdate;
wire       pll_scanclk;
wire       pll_scanclkena;
wire       pll_scandata;
wire       pll_scandataout;
wire       pll_scandone;
reg        pll_reconfig_reset;
wire [7:0] pll_rom_address;
wire       pll_rom_q;
reg        pll_write_from_rom;
wire       pll_write_rom_ena;
reg        pll_reconfig;
wire       q_reconfig_ntsc;
wire       q_reconfig_pal;

amigaclk_reconfig_pal amigaclk_reconfig_pal_i
(
	.address(pll_rom_address),
	.clock(clk_in),
	.rden(pll_write_rom_ena),
	.q(q_reconfig_pal)
);

amigaclk_reconfig_ntsc amigaclk_reconfig_ntsc_i
(
	.address(pll_rom_address),
	.clock(clk_in),
	.rden(pll_write_rom_ena),
	.q(q_reconfig_ntsc)
);

assign pll_rom_q = ntsc ? q_reconfig_ntsc : q_reconfig_pal;

amigaclk_pll_reconfig amigaclk_pll_reconfig_i
(
	.busy(pll_reconfig_busy),
	.clock(clk_in),
	.counter_param(0),
	.counter_type(0),
	.data_in(0),
	.pll_areset(pll_areset),
	.pll_areset_in(0),
	.pll_configupdate(pll_configupdate),
	.pll_scanclk(pll_scanclk),
	.pll_scanclkena(pll_scanclkena),
	.pll_scandata(pll_scandata),
	.pll_scandataout(pll_scandataout),
	.pll_scandone(pll_scandone),
	.read_param(0),
	.reconfig(pll_reconfig),
	.reset(pll_reconfig_reset),
	.reset_rom_address(0),
	.rom_address_out(pll_rom_address),
	.rom_data_in(pll_rom_q),
	.write_from_rom(pll_write_from_rom),
	.write_param(0),
	.write_rom_ena(pll_write_rom_ena)
);

amiga_clk_altera amiga_clk_i
(
	.inclk0       (clk_in),
	.c0           (clk_sdram),
	.c1           (clk_114  ),
	.c2           (clk_28   ),
	.areset       (pll_areset),
	.scanclk      (pll_scanclk),
	.scandata     (pll_scandata),
	.scanclkena   (pll_scanclkena),
	.configupdate (pll_configupdate),
	.scandataout  (pll_scandataout),
	.scandone     (pll_scandone),
	.locked       (locked)
);

always @(posedge clk_in) begin
	reg ntsc_d, ntsc_d2, ntsc_d3;
	reg [1:0] pll_reconfig_state = 0;
	reg [9:0] pll_reconfig_timeout;

	ntsc_d <= ntsc;
	ntsc_d2 <= ntsc_d;
	pll_write_from_rom <= 0;
	pll_reconfig <= 0;
	pll_reconfig_reset <= 0;
	case (pll_reconfig_state)
	2'b00:
	begin
		ntsc_d3 <= ntsc_d2;
		if (ntsc_d2 ^ ntsc_d3) begin
			pll_write_from_rom <= 1;
			pll_reconfig_state <= 2'b01;
		end
	end
	2'b01: pll_reconfig_state <= 2'b10;
	2'b10:
		if (~pll_reconfig_busy) begin
			pll_reconfig <= 1;
			pll_reconfig_state <= 2'b11;
			pll_reconfig_timeout <= 10'd1000;
		end
	2'b11:
	begin
		pll_reconfig_timeout <= pll_reconfig_timeout - 1'd1;
		if (pll_reconfig_timeout == 10'd1) begin
			// pll_reconfig stuck in busy state
			pll_reconfig_reset <= 1;
			pll_reconfig_state <= 2'b00;
		end
		if (~pll_reconfig & ~pll_reconfig_busy) pll_reconfig_state <= 2'b00;
	end
	default: ;
	endcase
end

`endif

`endif


//// generated clocks ////

// 7MHz
reg [2-1:0] clk7_cnt = 2'b10;
reg         clk7_en_reg = 1'b1;
reg         clk7n_en_reg = 1'b1;
always @ (posedge clk_28, negedge locked) begin
  if (!locked) begin
    clk7_cnt     <= 2'b10;
    clk7_en_reg  <= #1 1'b1;
    clk7n_en_reg <= #1 1'b1;
  end else begin
    clk7_cnt     <= clk7_cnt + 2'b01;
    clk7_en_reg  <= #1 (clk7_cnt == 2'b00);
    clk7n_en_reg <= #1 (clk7_cnt == 2'b10);
  end
end

wire clk_7 = clk7_cnt[1];
assign clk7_en = clk7_en_reg;
assign clk7n_en = clk7n_en_reg;

// amiga clocks & clock enables
//            __    __    __    __    __
// clk_28  __/  \__/  \__/  \__/  \__/  
//            ___________             __
// clk_7   __/           \___________/  
//            ___________             __
// c1      __/           \___________/   <- clk28m domain
//                  ___________
// c3      ________/           \________ <- clk28m domain
//

// clk_28 clock domain signal synchronous with clk signal delayed by 90 degrees
reg c3_r = 1'b0;
always @(posedge clk_28) begin
  c3_r <= clk_7;
end
assign c3 = c3_r;

// clk28m clock domain signal synchronous with clk signal
reg c1_r = 1'b0;
always @(posedge clk_28) begin
  c1_r <= ~c3_r;
end
assign c1 = c1_r;

// counter used to generate e clock enable
reg [3:0] e_cnt = 4'b0000;
always @(posedge clk_28) begin
  if (clk7_cnt == 2'b01) begin
    if (e_cnt[3] && e_cnt[0])
      e_cnt[3:0] <= 4'd0;
    else
      e_cnt[3:0] <= e_cnt[3:0] + 4'd1;
  end
end

// CCK clock output
assign cck = ~e_cnt[0];

// 0.709379 MHz clock enable output (clk domain pulse)
assign eclk[0] = ~e_cnt[3] & ~e_cnt[2] & ~e_cnt[1] & ~e_cnt[0]; // e_cnt == 0
assign eclk[1] = ~e_cnt[3] & ~e_cnt[2] & ~e_cnt[1] &  e_cnt[0]; // e_cnt == 1
assign eclk[2] = ~e_cnt[3] & ~e_cnt[2] &  e_cnt[1] & ~e_cnt[0]; // e_cnt == 2
assign eclk[3] = ~e_cnt[3] & ~e_cnt[2] &  e_cnt[1] &  e_cnt[0]; // e_cnt == 3
assign eclk[4] = ~e_cnt[3] &  e_cnt[2] & ~e_cnt[1] & ~e_cnt[0]; // e_cnt == 4
assign eclk[5] = ~e_cnt[3] &  e_cnt[2] & ~e_cnt[1] &  e_cnt[0]; // e_cnt == 5
assign eclk[6] = ~e_cnt[3] &  e_cnt[2] &  e_cnt[1] & ~e_cnt[0]; // e_cnt == 6
assign eclk[7] = ~e_cnt[3] &  e_cnt[2] &  e_cnt[1] &  e_cnt[0]; // e_cnt == 7
assign eclk[8] =  e_cnt[3] & ~e_cnt[2] & ~e_cnt[1] & ~e_cnt[0]; // e_cnt == 8
assign eclk[9] =  e_cnt[3] & ~e_cnt[2] & ~e_cnt[1] &  e_cnt[0]; // e_cnt == 9


endmodule

