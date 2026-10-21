library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- -----------------------------------------------------------------------
-- Updated toplevel for de0_nano by Alastair M. Robinson
-- 
-- Untested, since I don't have the hardware, but does build.
--
-- Supports RTG and secondary Audio.
--
-- -----------------------------------------------------------------------


entity minimig_de0_nano_top is
	port
	(
		-- clock inputs
		CLOCK_50 : in std_logic;     -- 50 MHz
		-- push button inputs
		KEY : in std_logic_vector(1 downto 0);          -- Pushbutton[1:0]
		-- switch inputs
		SW : in std_logic_vector(3 downto 0);           -- Toggle Switch[3:0]
		-- LED s
		LEDG : out std_logic_vector(7 downto 0);         -- LED Green[7:0]

		-- UART
		UART_TXD : out std_logic;     -- UART Transmitter
		UART_RXD : in std_logic;     -- UART Receiver

		-- PS2
		PS2_DAT : inout std_logic;      -- PS2 Keyboard Data
		PS2_CLK : inout std_logic;      -- PS2 Keyboard Clock
		PS2_MDAT : inout std_logic;     -- PS2 Mouse Data
		PS2_MCLK : inout std_logic;     -- PS2 Mouse Clock

		-- VGA
		VGA_RST : out std_logic;      -- VGA Reset (active low.)
		VGA_PCLK : out std_logic;     -- VGA Pixel Clock
		VGA_DEN : out std_logic;      -- VGA DATA EN
		VGA_HS : out std_logic;       -- VGA H_SYNC
		VGA_VS : out std_logic;       -- VGA V_SYNC
		VGA_R : out std_logic_vector(7 downto 0);        -- VGA Red[7:0]
		VGA_G : out std_logic_vector(7 downto 0);        -- VGA Green[7:0]
		VGA_B : out std_logic_vector(7 downto 0);        -- VGA Blue[7:0]

		-- SD Card
		SD_DAT : in std_logic;       -- SD Card Data            - spi MISO
		SD_DAT3 : out std_logic;      -- SD Card Data 3          - spi CS
		SD_CMD : out std_logic;       -- SD Card Command Signal  - spi MOSI
		SD_CLK : out std_logic;       -- SD Card Clock           - spi CLK

		-- SDRAM
		DRAM_DQ : inout  std_logic_vector(15 downto 0);      -- SDRAM Data bus 16 Bits
		DRAM_ADDR : out std_logic_vector(12 downto 0);    -- SDRAM Address bus 12 Bits
		DRAM_LDQM : out std_logic;    -- SDRAM Low-byte Data Mask
		DRAM_UDQM : out std_logic;    -- SDRAM High-byte Data Mask
		DRAM_WE_N : out std_logic;    -- SDRAM Write Enable
		DRAM_CAS_N : out std_logic;   -- SDRAM Column Address Strobe
		DRAM_RAS_N : out std_logic;   -- SDRAM Row Address Strobe
		DRAM_CS_N : out std_logic;    -- SDRAM Chip Select
		DRAM_BA_0 : out std_logic;    -- SDRAM Bank Address 0
		DRAM_BA_1 : out std_logic;    -- SDRAM Bank Address 1
		DRAM_CLK : out std_logic;     -- SDRAM Clock
		DRAM_CKE : out std_logic;     -- SDRAM Clock Enable

		-- MINIMIG specific
		Joya : in std_logic_vector(5 downto 0);         -- joystick port A
		Joyb : in std_logic_vector(5 downto 0);         -- joystick port B
		AUDIOLEFT : out std_logic;    -- sigma-delta DAC output left
		AUDIORIGHT : out std_logic   -- sigma-delta DAC output right
);
END entity;

architecture RTL of minimig_de0_nano_top is
   constant reset_cycles : integer := 131071;
	
-- System clocks

	signal sysclk : std_logic;

-- SPI signals

	signal diskled :std_logic;
	signal floppyled : std_logic;
	signal powerled : unsigned(1 downto 0);

	signal sd_cs : std_logic;
	signal sd_mosi : std_logic;
	signal sd_miso : std_logic;
	
-- PS/2 Keyboard socket
	signal ps2_keyboard_clk_in : std_logic;
	signal ps2_keyboard_dat_in : std_logic;
	signal ps2_keyboard_clk_out : std_logic;
	signal ps2_keyboard_dat_out : std_logic;

-- PS/2 Mouse
	signal ps2_mouse_clk_in: std_logic;
	signal ps2_mouse_dat_in: std_logic;
	signal ps2_mouse_clk_out: std_logic;
	signal ps2_mouse_dat_out: std_logic;

	
-- Video
	signal vga_pixel : std_logic;
	signal vga_red: std_logic_vector(7 downto 0);
	signal vga_green: std_logic_vector(7 downto 0);
	signal vga_blue: std_logic_vector(7 downto 0);
	signal vga_window : std_logic;
	signal vga_selcsync : std_logic;
	signal vga_csync : std_logic;
	signal vga_hsync : std_logic;
	signal vga_vsync : std_logic;
	signal vbl : std_logic;
	signal osd_window : std_logic;
	signal osd_pixel : std_logic;
	
	signal VGA_HS_i : STD_LOGIC;
	signal VGA_VS_i : STD_LOGIC;
	signal VGA_R_i : UNSIGNED(3 DOWNTO 0);
	signal VGA_G_i : UNSIGNED(3 DOWNTO 0);
	signal VGA_B_i : UNSIGNED(3 DOWNTO 0);
	
-- RS232 serial
	signal rs232_rxd : std_logic;
	signal rs232_txd : std_logic;

	signal audio_l : std_logic_vector(15 downto 0);
	signal audio_r : std_logic_vector(15 downto 0);
	
-- IO

	COMPONENT hybrid_pwm_sd
		PORT
		(
			clk		:	 IN STD_LOGIC;
			d_l		:	 IN STD_LOGIC_VECTOR(15 DOWNTO 0);
			q_l		:	 OUT STD_LOGIC;
			d_r		:	 IN STD_LOGIC_VECTOR(15 DOWNTO 0);
			q_r		:	 OUT STD_LOGIC
		);
	END COMPONENT;
	
	COMPONENT minimig_virtual_top
	generic
	( havertg : boolean := true;
		haveaudio : boolean := true;
		havec2p : boolean := true
	);
	PORT
	(
		CLK_IN		:	 IN STD_LOGIC;
		CLK_28		:	 OUT STD_LOGIC;
		CLK_114		:	 OUT STD_LOGIC;
		RESET_N     :   IN STD_LOGIC;
		LED_POWER	:	 OUT STD_LOGIC;
		LED_DISK    :   OUT STD_LOGIC;
		MENU_BUTTON :   IN STD_LOGIC;
		CTRL_TX		:	 OUT STD_LOGIC;
		CTRL_RX		:	 IN STD_LOGIC;
		AMIGA_TX		:	 OUT STD_LOGIC;
		AMIGA_RX		:	 IN STD_LOGIC;
		VGA_PIXEL   : OUT STD_LOGIC;
		VGA_SELCS   : OUT STD_LOGIC;
		VGA_CS		:	 OUT STD_LOGIC;
		VGA_HS		:	 OUT STD_LOGIC;
		VGA_VS		:	 OUT STD_LOGIC;
		VGA_R		:	 OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		VGA_G		:	 OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		VGA_B		:	 OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		SDRAM_DQ		:	 INOUT STD_LOGIC_VECTOR(15 DOWNTO 0);
		SDRAM_A		:	 OUT STD_LOGIC_VECTOR(12 DOWNTO 0);
		SDRAM_DQML		:	 OUT STD_LOGIC;
		SDRAM_DQMH		:	 OUT STD_LOGIC;
		SDRAM_nWE		:	 OUT STD_LOGIC;
		SDRAM_nCAS		:	 OUT STD_LOGIC;
		SDRAM_nRAS		:	 OUT STD_LOGIC;
		SDRAM_nCS		:	 OUT STD_LOGIC;
		SDRAM_BA		:	 OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
		SDRAM_CLK		:	 OUT STD_LOGIC;
		SDRAM_CKE		:	 OUT STD_LOGIC;
		AUDIO_L		:	 OUT STD_LOGIC_VECTOR(15 downto 0);
		AUDIO_R		:	 OUT STD_LOGIC_VECTOR(15 downto 0);
		PS2_DAT_I		:	 INOUT STD_LOGIC;
		PS2_CLK_I		:	 INOUT STD_LOGIC;
		PS2_MDAT_I	:	 INOUT STD_LOGIC;
		PS2_MCLK_I		:	 INOUT STD_LOGIC;
		PS2_DAT_O		:	 INOUT STD_LOGIC;
		PS2_CLK_O		:	 INOUT STD_LOGIC;
		PS2_MDAT_O		:	 INOUT STD_LOGIC;
		PS2_MCLK_O		:	 INOUT STD_LOGIC;
		AMIGA_RESET_N : IN STD_LOGIC;
		AMIGA_KEY	: IN STD_LOGIC_VECTOR(7 DOWNTO 0);
		AMIGA_KEY_STB : IN STD_LOGIC;
		C64_KEYS	:	IN STD_LOGIC_VECTOR(63 DOWNTO 0);
		JOYA		:	 IN STD_LOGIC_VECTOR(6 DOWNTO 0);
		JOYB		:	 IN STD_LOGIC_VECTOR(6 DOWNTO 0);
		JOYC		:	 IN STD_LOGIC_VECTOR(6 DOWNTO 0);
		JOYD		:	 IN STD_LOGIC_VECTOR(6 DOWNTO 0);
		SD_MISO	:	 IN STD_LOGIC;
		SD_MOSI	:	 OUT STD_LOGIC;
		SD_CLK	:	 OUT STD_LOGIC;
		SD_CS		:	 OUT STD_LOGIC;
		SD_ACK	:	 IN STD_LOGIC
	);
	END COMPONENT;

begin

-- SPI

SD_DAT3<=sd_cs;
SD_CMD<=sd_mosi;
sd_miso<=SD_DAT;

vga_window<='1';


-- External devices tied to GPIOs

ps2_mouse_dat_in<=PS2_MDAT;
PS2_MDAT <= '0' when ps2_mouse_dat_out='0' else 'Z';
ps2_mouse_clk_in<=PS2_MCLK;
PS2_MCLK <= '0' when ps2_mouse_clk_out='0' else 'Z';

ps2_keyboard_dat_in<=PS2_DAT;
PS2_DAT <= '0' when ps2_keyboard_dat_out='0' else 'Z';
ps2_keyboard_clk_in<=PS2_CLK;
PS2_CLK <= '0' when ps2_keyboard_clk_out='0' else 'Z';


virtual_top : COMPONENT minimig_virtual_top
generic map
	(
		havertg => true,
		haveaudio => true,
		havec2p => true
	)
PORT map
	(
		CLK_IN => CLOCK_50,
		CLK_114 => sysclk,
		RESET_N => KEY(0),
		LED_POWER => LEDG(0),
		LED_DISK => LEDG(1),
		MENU_BUTTON => KEY(1),
		CTRL_TX => open,
		CTRL_RX => '1',
		AMIGA_TX => UART_TXD,
		AMIGA_RX => UART_RXD,
		VGA_PIXEL => vga_pixel,
		VGA_SELCS => vga_selcsync,
		VGA_CS => vga_csync,
		VGA_HS => vga_hsync,
		VGA_VS => vga_vsync,
		VGA_R	=> vga_red,
		VGA_G	=> vga_green,
		VGA_B	=> vga_blue,
	
		SDRAM_DQ	=> DRAM_DQ,
		SDRAM_A => DRAM_ADDR,
		SDRAM_DQML => DRAM_LDQM,
		SDRAM_DQMH => DRAM_UDQM,
		SDRAM_nWE => DRAM_WE_N,
		SDRAM_nCAS => DRAM_CAS_N,
		SDRAM_nRAS => DRAM_RAS_N,
		SDRAM_nCS => DRAM_CS_N,
		SDRAM_BA(1) => DRAM_BA_1,
		SDRAM_BA(0) => DRAM_BA_0,
		SDRAM_CLK => DRAM_CLK,
		SDRAM_CKE => DRAM_CKE,

		AUDIO_L => audio_l,
		AUDIO_R => audio_r,
		
		PS2_DAT_I => ps2_keyboard_dat_in,
		PS2_CLK_I => ps2_keyboard_clk_in,
		PS2_MDAT_I => ps2_mouse_dat_in,
		PS2_MCLK_I => ps2_mouse_clk_in,

		PS2_DAT_O => ps2_keyboard_dat_out,
		PS2_CLK_O => ps2_keyboard_clk_out,
		PS2_MDAT_O => ps2_mouse_dat_out,
		PS2_MCLK_O => ps2_mouse_clk_out,
		
		AMIGA_RESET_N => '1',
		AMIGA_KEY => (others=>'-'),
		AMIGA_KEY_STB => '0',
		C64_KEYS => X"FEDCBA9876543210",
		
		JOYA(6) => '1',
		JOYA(5 downto 0) => joya,
		JOYB(6) => '1',
		JOYB(5 downto 0) => joyb,
		JOYC => (others => '1'),
		JOYD => (others => '1'),
		
		SD_MISO => sd_miso,
		SD_MOSI => sd_mosi,
		SD_CLK => SD_CLK,
		SD_CS => sd_cs,
		SD_ACK => '1'
	);

--VGA_HS<=not vga_hsync;
--VGA_VS<=not vga_vsync;
--VGA_R<=unsigned(vga_red(7 downto 4));
--VGA_G<=unsigned(vga_green(7 downto 4));
--VGA_B<=unsigned(vga_blue(7 downto 4));
	
VGA_PCLK<=sysclk;
VGA_RST<='1';

process(sysclk)
begin
	if rising_edge(sysclk) then
		VGA_DEN<=vga_window;
		if vga_selcsync='1' then
			VGA_HS<=vga_csync;
			VGA_VS<='1';
		else
			VGA_HS<=vga_hsync;
			VGA_VS<=vga_vsync;		
		end if;
		VGA_R<=vga_red;
		VGA_G<=vga_green;
		VGA_B<=vga_blue;
	end if;
end process;

audiosd : COMPONENT hybrid_pwm_sd
	PORT map
	(
		clk => sysclk,
		d_l(15) => not audio_l(15),
		d_l(14 downto 0) => audio_l(14 downto 0),
		q_l => AUDIOLEFT,
		d_r(15) => not audio_r(15),
		d_r(14 downto 0) => audio_r(14 downto 0),
		q_r => AUDIORIGHT
	);

end rtl;

