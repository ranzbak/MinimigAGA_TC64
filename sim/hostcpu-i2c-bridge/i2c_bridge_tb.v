`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02/27/2021 08:27:46 PM
// Design Name: 
// Module Name: i2c_bridge_tb
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module i2c_bridge_tb(

    );

	reg			clk_28;
	reg			clk_114;
	reg [31:0]	count;
	reg			reset_n;

	reg  [31:2]	addr;
	reg  [31:0]	addr_p;

	reg	 [15:0]	d;
	wire [15:0] q;
	reg         req;
	reg			wr;
	wire		ack;

	// Clock generation
	initial begin
		clk_114 = 1'b0;
		clk_28  = 1'b0;
		count   = 0;
		reset_n = 1'b0;

		addr    = 0;
		addr_p  = 0;
		d       = 0;
		req     = 1'b0;
		wr      = 1'b0;
	end

	// 114 MHz
    always #4.464 clk_114 = ~clk_114;

	// 28MHz
	always @(posedge clk_114) begin
		clk_28 = ~clk_28;
	end

	// Do write
	always @(posedge clk_28) begin
		count = count + 1;
		d <= 0;
		addr <= 0;
		addr_p = 0;
		wr <= 0;
		req <= 0;

		// release reset
		if (count == 5) reset_n <= 1'b1;

		// Start first write to I2C bridge
		// i2c_select <= '1' when addr(23)='1' and addr(7 downto 4)=X"6" else '0';
		if (count == 6) begin
			addr_p = 32'h800060;
			addr <= (addr_p >> 2);
			wr <= 1'b1;
			req <= 1'b1;
			d <= 16'hff; 
		end
	end
	

	// CFIDE test subject
	cfide #(
		.spimux(1'b0),
		.havespirtc(1'b0),
		.havei2c(1'b1)
	)mycfide ( 

	.sysclk(clk_114), //	: in std_logic;
	.n_reset(reset_n), //	: in std_logic;

	.addr(addr), //	: in std_logic_vector(31 downto 2);
	.d(d), //		: in std_logic_vector(15 downto 0);	
	.q(q), //		: out std_logic_vector(15 downto 0);		
	.req(req), // 	: in std_logic;
	.wr(wr), // 	: in std_logic;
	.ack(ack), // 	: out std_logic;

	.sd_di(1'b1), //		: in std_logic;		
	.sd_cs(), // 	: out std_logic_vector(7 downto 0);
	.sd_clk(), // 	: out std_logic;
	.sd_do(), //		: out std_logic;
	.sd_dimm(1'b1), //	: in std_logic;		--for sdcard
	.sd_ack(1'b1), // 	: in std_logic; -- indicates that SPI signal has made it to the wire
	.debugTxD(), //TxD : out std_logic;
	.debugRxD(1'b1), //RxD : in std_logic;
	.menu_button(1'b1), //	: in std_logic:='1';
	.scandoubler(), //	: out std_logic;

	.audio_ena(), // : out std_logic;
	.audio_clear(), // : out std_logic;
	.audio_buf(), // : in std_logic;
	.audio_amiga(), // : in std_logic;

	.vbl_int(1'b0), //	: in std_logic;
	.interrupt(), //	: out std_logic;
	.c64_keys('hf), //	: in std_logic_vector(63 downto 0) :=X"FFFFFFFFFFFFFFFF";
	.amiga_key(), //	: out std_logic_vector(7 downto 0);
	.amiga_key_stb(), //	: out std_logic;

	.amiga_addr(8'h0), // : in std_logic_vector(7 downto 0);
	.amiga_d(16'h00), // : in std_logic_vector(15 downto 0);
	.amiga_q(), // : out std_logic_vector(15 downto 0);
	.amiga_req(1'b0), // : in std_logic;
	.amiga_wr(1'b0), // : in std_logic;
	.amiga_ack(), // : out std_logic;

	.rtc_q(), // : out std_logic_vector(63 downto 0);

	// 28Mhz signals
	.clk_28(clk_28), //	: in std_logic;
	.tick_in(1'b0) // : in std_logic	-- 44.1KHz - makes it easy to keep timer in lockstep with audio.
);

    
endmodule
