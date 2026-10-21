-- -----------------------------------------------------------------------
--
-- Turbo Chameleon
--
-- Toplevel file for Turbo Chameleon 64
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

library work;

-- -----------------------------------------------------------------------

entity chameleon_toplevel is
	generic (
		resetCycles: integer := 131071
	);
	port (
-- Clocks
		clk8 : in std_logic;
		phi2_n : in std_logic;
		dotclock_n : in std_logic;

-- Bus
		romlh_n : in std_logic;
		ioef_n : in std_logic;

-- Buttons
		freeze_n : in std_logic;

-- MMC/SPI
		spi_miso : in std_logic;
		mmc_cd_n : in std_logic;
		mmc_wp : in std_logic;

-- MUX CPLD
		mux_clk : out std_logic;
		mux : out unsigned(3 downto 0);
		mux_d : out unsigned(3 downto 0);
		mux_q : in unsigned(3 downto 0);

-- USART
		usart_tx : in std_logic;
		usart_clk : in std_logic;
		usart_rts : in std_logic;
		usart_cts : in std_logic;

-- SDRam
		sd_clk : out std_logic;
		sd_data : inout std_logic_vector(15 downto 0);
		sd_addr : out std_logic_vector(12 downto 0);
		sd_we_n : out std_logic;
		sd_ras_n : out std_logic;
		sd_cas_n : out std_logic;
		sd_ba_0 : out std_logic;
		sd_ba_1 : out std_logic;
		sd_ldqm : out std_logic;
		sd_udqm : out std_logic;

-- Video
		red : out unsigned(4 downto 0);
		grn : out unsigned(4 downto 0);
		blu : out unsigned(4 downto 0);
		nHSync : buffer std_logic;
		nVSync : buffer std_logic;

-- Audio
		sigmaL : out std_logic;
		sigmaR : out std_logic
	);
end entity;

-- -----------------------------------------------------------------------

architecture rtl of chameleon_toplevel is
   constant reset_cycles : integer := 131071;
	
-- System clocks
	signal clk_28 : std_logic;
	signal clk_114 : std_logic;
	signal reset_button_n : std_logic;
	signal pll_locked : std_logic;
	
-- Global signals
	signal reset_8 : std_logic;
	signal reset_28 : std_logic;
	signal reset : std_logic;
	signal reset_n : std_logic;
	
-- MUX
	signal mux_clk_reg : std_logic := '0';
	signal mux_reg : unsigned(3 downto 0) := (others => '1');
	signal mux_d_reg : unsigned(3 downto 0) := (others => '1');
	signal mux_d_regd : unsigned(3 downto 0) := (others => '1');
	signal mux_regd : unsigned(3 downto 0) := (others => '1');

-- LEDs
	signal led_green : std_logic;
	signal led_red : std_logic;
	signal socleds : std_logic_vector(7 downto 0);

-- PS/2 Keyboard
	signal ps2_keyboard_clk_in : std_logic;
	signal ps2_keyboard_dat_in : std_logic;
	signal ps2_keyboard_clk_out : std_logic;
	signal ps2_keyboard_dat_out : std_logic;

-- PS/2 Mouse
	signal ps2_mouse_clk_in: std_logic;
	signal ps2_mouse_dat_in: std_logic;
	signal ps2_mouse_clk_out: std_logic;
	signal ps2_mouse_dat_out: std_logic;

-- SD card
	signal spi_mosi : std_logic;
	signal spi_cs : std_logic;
	signal spi_clk : std_logic;
	signal spi_raw_ack : std_logic;
	
-- RTC

	signal rtc_cs : std_logic;
	signal rtc_cs_inv : std_logic;
	
-- RS232 serial
	signal rs232_rxd : std_logic;
	signal rs232_txd : std_logic;
	signal midi_rxd : std_logic;
	signal midi_txd : std_logic;
	signal external_rxd : std_logic;

-- Sound
	signal audio_l : std_logic_vector(15 downto 0);
	signal audio_r : std_logic_vector(15 downto 0);

-- IO
	signal ena_1mhz : std_logic;
	signal button_reset_n : std_logic;

	signal power_button : std_logic;
	signal play_button : std_logic;

	signal no_clock : std_logic;
	signal docking_station : std_logic;
	signal runstop : std_logic;
	signal c64_keys : unsigned(63 downto 0);
	signal c64_restore_key_n : std_logic;
	signal c64_nmi_n : std_logic;
	signal c64_joy1 : unsigned(6 downto 0);
	signal c64_joy2 : unsigned(6 downto 0);
	signal joystick3 : unsigned(6 downto 0);
	signal joystick4 : unsigned(6 downto 0);
	signal cdtv_joya : unsigned(5 downto 0);
	signal cdtv_joyb : unsigned(5 downto 0);
	signal joy1 : unsigned(7 downto 0);
	signal joy2 : unsigned(7 downto 0);
	signal joy3 : unsigned(7 downto 0);
	signal joy4 : unsigned(7 downto 0);
	signal usart_rx : std_logic:='1'; -- Safe default
	signal ir : std_logic;
	
	signal amiga_reset_n : std_logic;
	signal amiga_key : unsigned(7 downto 0);
	signal amiga_key_stb : std_logic;

	signal vga_pixel : std_logic;
	signal vga_window : std_logic;
	signal vga_selcsync : std_logic;
	signal vga_csync : std_logic;
	signal vga_hsync : std_logic;
	signal vga_vsync : std_logic;
	signal vga_red : std_logic_vector(7 downto 0);
	signal vga_green : std_logic_vector(7 downto 0);
	signal vga_blue : std_logic_vector(7 downto 0);
	signal HSync : std_logic;
	signal VSync : std_logic;
	
	signal red_dithered :unsigned(7 downto 0);
	signal grn_dithered :unsigned(7 downto 0);
	signal blu_dithered :unsigned(7 downto 0);
	signal hsync_n_dithered : std_logic;
	signal vsync_n_dithered : std_logic;

	
	COMPONENT amiga_clk_altera
	PORT
	(
		areset		:	 IN STD_LOGIC;
		inclk0		:	 IN STD_LOGIC;
		c0		:	 OUT STD_LOGIC;
		c1		:	 OUT STD_LOGIC;
		c2		:	 OUT STD_LOGIC;
		locked		:	 OUT STD_LOGIC
	);
	END COMPONENT;

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
	( spimux : integer := 0;
	  havespirtc : integer := 0
	);
	PORT
	(
		CLK_114		:	 out STD_LOGIC;
		CLK_28		:	 out STD_LOGIC;
		CLK_IN 		:   in std_logic;
		PLL_LOCKED  :   out std_logic;
		RESET_N 		:   in STD_LOGIC;
		MENU_BUTTON :   IN STD_LOGIC;
		LED_POWER	:	 OUT STD_LOGIC;
		LED_DISK		:	 OUT STD_LOGIC;
		CTRL_TX		:	 OUT STD_LOGIC;
		CTRL_RX		:	 IN STD_LOGIC;
		AMIGA_TX		:	 OUT STD_LOGIC;
		AMIGA_RX		:	 IN STD_LOGIC;
		VGA_PIXEL   :   OUT STD_LOGIC;
		VGA_SELCS	:	 OUT STD_LOGIC;
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
		PS2_DAT_I		:	 IN STD_LOGIC;
		PS2_CLK_I		:	 IN STD_LOGIC;
		PS2_MDAT_I		:	 IN STD_LOGIC;
		PS2_MCLK_I		:	 IN STD_LOGIC;
		PS2_DAT_O	:	 OUT STD_LOGIC;
		PS2_CLK_O	:	 OUT STD_LOGIC;
		PS2_MDAT_O	:	 OUT STD_LOGIC;
		PS2_MCLK_O	:	 OUT STD_LOGIC;
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
		SD_ACK	:	 IN STD_LOGIC;
		RTC_CS   :   OUT STD_LOGIC
	);
	END COMPONENT;

	
begin


-- -----------------------------------------------------------------------
-- Clocks and PLL
-- -----------------------------------------------------------------------


my1mhz : entity work.chameleon_1mhz
	generic map (
		-- Timer calibration. Clock speed in Mhz.
		clk_ticks_per_usec => 113
	)
	port map(
		clk => clk_114,
		ena_1mhz => ena_1mhz
	);

myReset : entity work.gen_reset
	generic map (
		resetCycles => reset_cycles
	)
	port map (
		clk => clk8,
		enable => '1',
		button => not button_reset_n,
		reset => reset_8
	);
	
	
process(clk_28,reset_8)
begin
	if rising_edge(clk_28) then
		reset_28<=reset_8;
		reset<=reset_28;
	end if;
end process;

reset_n<= not reset;
	
	myIO : entity work.chameleon_io
		generic map (
			enable_docking_station => true,
			enable_docking_irq => true,
			enable_c64_joykeyb => true,
			enable_c64_4player => true,
			enable_raw_spi => true,
			enable_iec_access =>true
		)
		port map (
		-- Clocks
			clk => clk_114,
			clk_mux => clk_114,
			ena_1mhz => ena_1mhz,
			reset => reset,
			
			no_clock => no_clock,
			docking_station => docking_station,
			
		-- Chameleon FPGA pins
			-- C64 Clocks
			phi2_n => phi2_n,
			dotclock_n => dotclock_n, 
			-- C64 cartridge control lines
			io_ef_n => ioef_n,
			rom_lh_n => romlh_n,
			-- SPI bus
			spi_miso => spi_miso,
			-- CPLD multiplexer
			mux_clk => mux_clk,
			mux => mux,
			mux_d => mux_d,
			mux_q => mux_q,
			
			to_usb_rx => usart_rx,

		-- SPI raw signals (enable_raw_spi must be set to true)
			rtc_cs => rtc_cs,
			mmc_cs_n => spi_cs,
			spi_raw_clk => spi_clk,
			spi_raw_mosi => spi_mosi,
			spi_raw_ack => spi_raw_ack,

		-- LEDs
			led_green => led_green,
			led_red => led_red,
			ir => ir,
		
		-- PS/2 Keyboard
			ps2_keyboard_clk_out => ps2_keyboard_clk_out,
			ps2_keyboard_dat_out => ps2_keyboard_dat_out,
			ps2_keyboard_clk_in => ps2_keyboard_clk_in,
			ps2_keyboard_dat_in => ps2_keyboard_dat_in,
	
		-- PS/2 Mouse
			ps2_mouse_clk_out => ps2_mouse_clk_out,
			ps2_mouse_dat_out => ps2_mouse_dat_out,
			ps2_mouse_clk_in => ps2_mouse_clk_in,
			ps2_mouse_dat_in => ps2_mouse_dat_in,

		-- Buttons
			button_reset_n => button_reset_n,

		-- Joysticks
			joystick1 => c64_joy1,
			joystick2 => c64_joy2,
			joystick3 => joystick3, 
			joystick4 => joystick4,

		-- Keyboards
			keys => c64_keys,
			restore_key_n => c64_restore_key_n,
			c64_nmi_n => c64_nmi_n,

			amiga_reset_n => amiga_reset_n,
			amiga_trigger => amiga_key_stb,
			amiga_scancode => amiga_key,

			midi_txd => midi_txd,
			midi_rxd => midi_rxd,
--
--			iec_atn_out => rs232_txd,
--			iec_clk_in => rs232_rxd
--			iec_clk_out : in std_logic := '1';
			iec_dat_out => midi_txd,
--			iec_srq_out : in std_logic := '1';
--			iec_dat_in : in std_logic := '1';
--			iec_atn_in : out std_logic;
			iec_srq_in => external_rxd
		);

	cdtv : entity work.chameleon_cdtv_remote
	port map(
		clk => clk_114,
		ena_1mhz => ena_1mhz,
		ir => ir,
		key_power => power_button,
		key_play => play_button,
		joystick_a => cdtv_joya,
		joystick_b => cdtv_joyb
	);

rtc_cs<=not rtc_cs_inv;
		
runstop<='0' when c64_keys(63)='0' and c64_joy1="1111111" else '1';
joy1<="1" & c64_joy1(6) & (c64_joy1(5 downto 0) and cdtv_joya);
joy2<="1" & c64_joy2(6) & (c64_joy2(5 downto 0) and cdtv_joyb);
joy3<="1" & joystick3;
joy4<="1" & joystick4;


virtual_top : COMPONENT minimig_virtual_top
generic map
	(
		spimux => 1,
		havespirtc => 1
	)
PORT map
	(
		CLK_IN => clk8,
		CLK_28 => clk_28,
		CLK_114 => clk_114,
		PLL_LOCKED => pll_locked,
		LED_DISK => led_red,
		LED_POWER => led_green,
		RESET_N => reset_n,
		MENU_BUTTON => (not power_button) and usart_cts,
		CTRL_TX => rs232_txd,
		CTRL_RX => rs232_rxd,
		AMIGA_TX => midi_txd,
		AMIGA_RX => midi_rxd and external_rxd,
		VGA_PIXEL => vga_pixel,
		VGA_SELCS => vga_selcsync,
		VGA_CS => vga_csync,
		VGA_HS => vga_hsync,
		VGA_VS => vga_vsync,
		VGA_R	=> vga_red,
		VGA_G	=> vga_green,
		VGA_B	=> vga_blue,
	
		SDRAM_DQ	=> sd_data,
		SDRAM_A => sd_addr,
		SDRAM_DQML => sd_ldqm,
		SDRAM_DQMH => sd_udqm,
		SDRAM_nWE => sd_we_n,
		SDRAM_nCAS => sd_cas_n,
		SDRAM_nRAS => sd_ras_n,
--		SDRAM_nCS => sd_cs,
		SDRAM_BA(1) => sd_ba_1,
		SDRAM_BA(0) => sd_ba_0,
		SDRAM_CLK => sd_clk,
--		SDRAM_CKE => sd_CKE,

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

		AMIGA_RESET_N => '1', -- fix problem with V1 docking station -- amiga_reset_n,
		AMIGA_KEY => std_logic_vector(amiga_key),
		AMIGA_KEY_STB => amiga_key_stb,
		C64_KEYS => std_logic_vector(c64_keys),

		JOYA => std_logic_vector(joy1(6 downto 4))&joy1(0)&joy1(1)&joy1(2)&joy1(3),
		JOYB => std_logic_vector(joy2(6 downto 4))&joy2(0)&joy2(1)&joy2(2)&joy2(3),
		JOYC => std_logic_vector(joy3(6 downto 4))&joy3(0)&joy3(1)&joy3(2)&joy3(3),
		JOYD => std_logic_vector(joy4(6 downto 4))&joy4(0)&joy4(1)&joy4(2)&joy4(3),

		SD_MISO => spi_miso,
		SD_MOSI => spi_mosi,
		SD_CLK => spi_clk,
		SD_CS => spi_cs,
		SD_ACK => spi_raw_ack,
		RTC_CS => rtc_cs_inv
	);

vga_window<='1';
--nHSync<=vga_hsync;
--nVSync<=vga_vsync;
--red<=unsigned(vga_red(7 downto 3));
--grn<=unsigned(vga_green(7 downto 3));
--blu<=unsigned(vga_blue(7 downto 3));

	mydither : entity work.video_vga_dither
		generic map(
			outbits => 5
		)
		port map(
			clk=>clk_114,
--			invertSync=>'1',
			iSelcsync=>vga_selcsync,
			iCsync=>vga_csync,
			iHsync=>vga_hsync,
			iVsync=>vga_vsync,
			pixel=>vga_pixel,
			vidEna=>vga_window,
			iRed => unsigned(vga_red),
			iGreen => unsigned(vga_green),
			iBlue => unsigned(vga_blue),
			oHsync=>hsync_n_dithered,
			oVsync=>vsync_n_dithered,
			oRed => red_dithered,
			oGreen => grn_dithered,
			oBlue => blu_dithered
		);


process(clk_114)
begin
	if rising_edge(clk_114) then
		red<=red_dithered(7 downto 3);
		grn<=grn_dithered(7 downto 3);
		blu<=blu_dithered(7 downto 3);
		nHSync<=not hsync_n_dithered;
		nVSync<=not vsync_n_dithered;
	end if;
end process;

audio_sd : COMPONENT hybrid_pwm_sd
	PORT map
	(
		clk => clk_114,
		d_l(15) => not audio_l(15),
		d_l(14 downto 0) => audio_l(14 downto 0),
		q_l => sigmaL,
		d_r(15) => not audio_r(15),
		d_r(14 downto 0) => audio_r(14 downto 0),
		q_r => sigmaR
	);

end architecture;
