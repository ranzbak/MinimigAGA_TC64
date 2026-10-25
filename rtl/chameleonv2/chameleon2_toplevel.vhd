
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- -----------------------------------------------------------------------

entity chameleon2_toplevel is
	port (
-- Clocks
		clk50m : in std_logic;
		phi2_n : in std_logic;
		dotclk_n : in std_logic;

-- Buttons
		usart_cts : in std_logic;  -- Left button
		freeze_btn : in std_logic; -- Middle button
		reset_btn : in std_logic;  -- Right

-- PS/2, IEC, LEDs
		iec_present : in std_logic;

		ps2iec_sel : out std_logic;
		ps2iec : in unsigned(3 downto 0);

		ser_out_clk : out std_logic;
		ser_out_dat : out std_logic;
		ser_out_rclk : out std_logic;

		iec_clk_out : out std_logic;
		iec_srq_out : out std_logic;
		iec_atn_out : out std_logic;
		iec_dat_out : out std_logic;

-- SPI, Flash and SD-Card
		flash_cs : out std_logic;
		rtc_cs : out std_logic;
		mmc_cs : out std_logic;
		mmc_cd : in std_logic;
		mmc_wp : in std_logic;
		spi_clk : out std_logic;
		spi_miso : in std_logic;
		spi_mosi : out std_logic;

-- Clock port
		clock_ior : out std_logic;
		clock_iow : out std_logic;

-- C64 bus
		reset_in : in std_logic;

		ioef : in std_logic;
		romlh : in std_logic;

		dma_out : out std_logic;
		game_out : out std_logic;
		exrom_out : out std_logic;

		irq_in : in std_logic;
		irq_out : out std_logic;
		nmi_in : in std_logic;
		nmi_out : out std_logic;
		ba_in : in std_logic;
		rw_in : in std_logic;
		rw_out : out std_logic;

		sa_dir : out std_logic;
		sa_oe : out std_logic;
		sa15_out : out std_logic;
		low_a : inout unsigned(15 downto 0);

		sd_dir : out std_logic;
		sd_oe : out std_logic;
		low_d : inout unsigned(7 downto 0);

-- SDRAM
		ram_clk : out std_logic;
		ram_ldqm : out std_logic;
		ram_udqm : out std_logic;
		ram_ras : out std_logic;
		ram_cas : out std_logic;
		ram_we : out std_logic;
		ram_ba : out unsigned(1 downto 0);
		ram_a : out unsigned(12 downto 0);
		ram_d : inout unsigned(15 downto 0);

-- IR eye
		ir_data : in std_logic;

-- USB micro
		usart_clk : in std_logic;
		usart_rts : in std_logic;
		usart_rx : out std_logic;
		usart_tx : in std_logic;

-- Video output
		red : out unsigned(4 downto 0);
		grn : out unsigned(4 downto 0);
		blu : out unsigned(4 downto 0);
		hsync_n : out std_logic;
		vsync_n : out std_logic;

-- Audio output
		sigma_l : out std_logic;
		sigma_r : out std_logic
	);
end entity;


architecture rtl of chameleon2_toplevel is
   constant reset_cycles : integer := 131071;
	
-- System clocks

	signal clk_28 : std_logic;
	signal clk_114 : std_logic;
	signal pll_locked : std_logic;
	signal ena_1mhz : std_logic;
	signal ena_1khz : std_logic;
	signal phi2 : std_logic;
	
-- Global signals
	signal reset : std_logic;
	signal n_reset : std_logic;

-- LEDs
	signal led_green : std_logic;
	signal led_red : std_logic;

-- Docking station
	signal no_clock : std_logic;
	signal docking_station : std_logic;
	signal docking_irq : std_logic;
	signal phi_cnt : unsigned(7 downto 0);
	signal phi_end_1 : std_logic;
	
-- PS/2 Keyboard socket - used for second mouse
	signal ps2_keyboard_clk_in : std_logic;
	signal ps2_keyboard_dat_in : std_logic;
	signal ps2_keyboard_clk_out : std_logic;
	signal ps2_keyboard_dat_out : std_logic;

-- PS/2 Mouse
	signal ps2_mouse_clk_in: std_logic;
	signal ps2_mouse_dat_in: std_logic;
	signal ps2_mouse_clk_out: std_logic;
	signal ps2_mouse_dat_out: std_logic;
	
	signal sdram_req : std_logic := '0';
	signal sdram_ack : std_logic;
	signal sdram_we : std_logic := '0';
	signal sdram_a : unsigned(24 downto 0) := (others => '0');
	signal sdram_d : unsigned(7 downto 0);
	signal sdram_q : unsigned(7 downto 0);

	-- Video
	signal vga_r: std_logic_vector(7 downto 0);
	signal vga_g: std_logic_vector(7 downto 0);
	signal vga_b: std_logic_vector(7 downto 0);
	signal vga_pixel : std_logic;
	signal vga_window : std_logic;
	signal vga_hsync : std_logic;
	signal vga_vsync : std_logic;
	signal vga_csync : std_logic;
	signal vga_selcsync : std_logic;
	
	signal red_dithered :unsigned(7 downto 0);
	signal grn_dithered :unsigned(7 downto 0);
	signal blu_dithered :unsigned(7 downto 0);
	signal hsync_n_dithered : std_logic;
	signal vsync_n_dithered : std_logic;
	
-- RS232 serial
	signal rs232_rxd : std_logic:='1';
	signal rs232_txd : std_logic;
	signal amiser_rxd : std_logic;
	signal amiser_txd : std_logic;
	signal midi_rxd : std_logic;
	signal external_rxd : std_logic;

-- Sound
	signal audio_l : std_logic_vector(15 downto 0);
	signal audio_r : std_logic_vector(15 downto 0);

-- IO
	signal button_reset_n : std_logic;
	
	signal power_button : std_logic;
	signal play_button : std_logic;
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
	signal ir : std_logic;
	signal ir_d : std_logic;

	signal amiga_reset_n : std_logic;
	signal amiga_key : unsigned(7 downto 0);
	signal amiga_key_stb : std_logic;

	
	-- Sigma Delta audio
	COMPONENT hybrid_pwm_sd
	PORT
	(
		clk	:	IN STD_LOGIC;
		d_l	:	IN STD_LOGIC_VECTOR(15 DOWNTO 0);
		q_l	:	OUT STD_LOGIC;
		d_r	:	IN STD_LOGIC_VECTOR(15 DOWNTO 0);
		q_r	:	OUT STD_LOGIC
	);
	END COMPONENT;

	COMPONENT minimig_virtual_top
	generic
	( spimux : integer := 0;
	  havespirtc : integer := 0
	);
	PORT
	(
		CLK_28		:	 out STD_LOGIC;
		CLK_114		:	 out STD_LOGIC;
		CLK_IN : in std_logic;
		RESET_N : in STD_LOGIC;
		MENU_BUTTON : IN STD_LOGIC;
		LED_POWER	:	 OUT STD_LOGIC;
		LED_DISK		:	 OUT STD_LOGIC;
		CTRL_TX		:	 OUT STD_LOGIC;
		CTRL_RX		:	 IN STD_LOGIC;
		AMIGA_TX		:	 OUT STD_LOGIC;
		AMIGA_RX		:	 IN STD_LOGIC;
		VGA_PIXEL   :   OUT STD_LOGIC;
		VGA_SELCS   :   OUT STD_LOGIC;
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
		RTC_CS	:	 OUT STD_LOGIC
	);
	END COMPONENT;

	signal rtc_cs_inv : std_logic;
	
begin
-- -----------------------------------------------------------------------
-- Unused pins
-- -----------------------------------------------------------------------
	iec_clk_out <= '0';
	iec_atn_out <= '0';
	iec_dat_out <= not amiser_txd; -- '0';
	iec_srq_out <= '0';
	nmi_out <= '0';
	usart_rx<='1';

	-- put these here?
	flash_cs <= '1';
	rtc_cs <= not rtc_cs_inv;
	
	clock_ior <='1';
	clock_iow <='1';
	irq_out <= not docking_irq;
	
-- -----------------------------------------------------------------------
-- Reset
-- -----------------------------------------------------------------------
	myReset : entity work.gen_reset
		generic map (
			resetCycles => reset_cycles
		)
		port map (
			clk => clk_114,
			enable => '1',

			button => not reset_btn,
			reset => reset,
			nreset => n_reset
		);

-- -----------------------------------------------------------------------
-- 1 Mhz and 1 Khz clocks
-- -----------------------------------------------------------------------
	my1Mhz : entity work.chameleon_1mhz
		generic map (
			clk_ticks_per_usec => 100
		)
		port map (
			clk => clk_114,
			ena_1mhz => ena_1mhz,
			ena_1mhz_2 => open
		);

	my1Khz : entity work.chameleon_1khz
		port map (
			clk => clk_114,
			ena_1mhz => ena_1mhz,
			ena_1khz => ena_1khz
		);
	
-- -----------------------------------------------------------------------
-- PS2IEC multiplexer
-- -----------------------------------------------------------------------
	io_ps2iec_inst : entity work.chameleon2_io_ps2iec
		port map (
			clk => clk_114,

			ps2iec_sel => ps2iec_sel,
			ps2iec => ps2iec,

			ps2_mouse_clk => ps2_mouse_clk_in,
			ps2_mouse_dat => ps2_mouse_dat_in,
			ps2_keyboard_clk => ps2_keyboard_clk_in,
			ps2_keyboard_dat => ps2_keyboard_dat_in,

			iec_clk => open, -- iec_clk_in,
			iec_srq => external_rxd, -- iec_srq_in,
			iec_atn => open, -- iec_atn_in,
			iec_dat => open  -- iec_dat_in
		);

-- -----------------------------------------------------------------------
-- LED, PS2 and reset shiftregister
-- -----------------------------------------------------------------------
	io_shiftreg_inst : entity work.chameleon2_io_shiftreg
		port map (
			clk => clk_114,

			ser_out_clk => ser_out_clk,
			ser_out_dat => ser_out_dat,
			ser_out_rclk => ser_out_rclk,

			reset_c64 => reset,
			reset_iec => reset,
			ps2_mouse_clk => ps2_mouse_clk_out,
			ps2_mouse_dat => ps2_mouse_dat_out,
			ps2_keyboard_clk => ps2_keyboard_clk_out,
			ps2_keyboard_dat => ps2_keyboard_dat_out,
			led_green => led_green,
			led_red => led_red
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


-- -----------------------------------------------------------------------
-- Chameleon IO, docking station and cartridge port
-- -----------------------------------------------------------------------
	chameleon2_io_blk : block
	begin
		chameleon2_io_inst : entity work.chameleon2_io
			generic map (
				enable_docking_station => true,
				enable_cdtv_remote => false,
				enable_c64_joykeyb => true,
				enable_c64_4player => true
			)
			port map (
				clk => clk_114,
				ena_1mhz => ena_1mhz,
				phi2_n => phi2_n,
				dotclock_n => dotclk_n,

				reset => reset,

				ir_data => ir,
				ioef => ioef,
				romlh => romlh,

				dma_out => dma_out,
				game_out => game_out,
				exrom_out => exrom_out,

				ba_in => ba_in,
--				rw_in => rw_in,
				rw_out => rw_out,

				sa_dir => sa_dir,
				sa_oe => sa_oe,
				sa15_out => sa15_out,
				low_a => low_a,

				sd_dir => sd_dir,
				sd_oe => sd_oe,
				low_d => low_d,

				no_clock => no_clock,
				docking_station => docking_station,
				docking_irq => docking_irq,

				phi_cnt => phi_cnt,
				phi_end_1 => phi_end_1,

				joystick1 => c64_joy1,
				joystick2 => c64_joy2,
				joystick3 => joystick3,
				joystick4 => joystick4,
				keys => c64_keys,
--				restore_key_n => restore_n
				restore_key_n => open,
				amiga_power_led => led_green,
				amiga_drive_led => led_red,
				amiga_reset_n => amiga_reset_n,
				amiga_trigger => amiga_key_stb,
				amiga_scancode => amiga_key,
				midi_rxd => midi_rxd,
				midi_txd => amiser_txd
			);
	end block;

-- Synchronise IR signal
process (clk_114)
begin
	if rising_edge(clk_114) then
		ir_d<=ir_data;
		ir<=ir_d;
	end if;
end process;


--joy1<=not gp1_run & not gp1_select & (c64_joy1 and cdtv_joy1);
--runstop<='0' when c64_keys(63)='0' and c64_joy1="1111111" else '1';
-- gp1_run<=c64_keys(11) and c64_keys(56) when c64_joy1="111111" else '1';
-- gp1_select<=c64_keys(60) when c64_joy1="111111" else '1';
joy1<='1' & c64_joy1(6) & (c64_joy1(5 downto 0) and cdtv_joya);
joy2<="1" & c64_joy2(6) & (c64_joy2(5 downto 0) and cdtv_joyb);
joy3<="1" & joystick3;
joy4<="1" & joystick4;
	

vga_window<='1';

amiser_rxd <= midi_rxd and external_rxd;

virtual_top : COMPONENT minimig_virtual_top
generic map
	(
		spimux => 0,
		havespirtc => 1
	)
PORT map
	(
		CLK_IN => clk50m,
		CLK_28 => clk_28,
		CLK_114 => clk_114,
		RESET_N => n_reset,
		MENU_BUTTON => (not power_button) and usart_cts,
		LED_POWER => led_green,
		LED_DISK => led_red,
		CTRL_TX => rs232_txd,
		CTRL_RX => rs232_rxd,
		AMIGA_TX => amiser_txd,
		AMIGA_RX => amiser_rxd,
		VGA_PIXEL => vga_pixel,
		VGA_SELCS => vga_selcsync,
		VGA_CS => vga_csync,
		VGA_HS => vga_hsync,
		VGA_VS => vga_vsync,
		VGA_R	=> vga_r,
		VGA_G	=> vga_g,
		VGA_B	=> vga_b,
	
		SDRAM_DQ	=> std_logic_vector(ram_d),
		unsigned(SDRAM_A) => ram_a,
		SDRAM_DQML => ram_ldqm,
		SDRAM_DQMH => ram_udqm,
		SDRAM_nWE => ram_we,
		SDRAM_nCAS => ram_cas,
		SDRAM_nRAS => ram_ras,
--		SDRAM_nCS => sd_cs,
		SDRAM_BA(1) => ram_ba(1),
		SDRAM_BA(0) => ram_ba(0),
		SDRAM_CLK => ram_clk,
--		SDRAM_CKE => sd_CKE,

		AUDIO_L => audio_l(15 downto 0),
		AUDIO_R => audio_r(15 downto 0),
		
		PS2_DAT_I => ps2_keyboard_dat_in,
		PS2_CLK_I => ps2_keyboard_clk_in,
		PS2_MDAT_I => ps2_mouse_dat_in,
		PS2_MCLK_I => ps2_mouse_clk_in,
		PS2_DAT_O => ps2_keyboard_dat_out,
		PS2_CLK_O => ps2_keyboard_clk_out,
		PS2_MDAT_O => ps2_mouse_dat_out,
		PS2_MCLK_O => ps2_mouse_clk_out,

		AMIGA_RESET_N => '1', -- amiga_reset_n,
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
		SD_CS => mmc_cs,
		SD_ACK => '1',
		RTC_CS => rtc_cs_inv
	);
	
-- Dither the video down to 5 bits per gun.
	vga_window<='1';
--	hsync_n<= not vga_hsync;
--	vsync_n<= not vga_vsync;
--	red<=unsigned(vga_r(7 downto 3));
--	grn<=unsigned(vga_g(7 downto 3));
--	blu<=unsigned(vga_b(7 downto 3));
	
	mydither : entity work.video_vga_dither
		generic map(
			outbits => 5
		)
		port map(
			clk=>clk_114,
			pixel=>vga_pixel,
--			invertSync=>'1',
			iSelcsync=>vga_selcsync,
			iCsync=>vga_csync,
			iHsync=>vga_hsync,
			iVsync=>vga_vsync,
			vidEna=>vga_window,
			iRed => unsigned(vga_r),
			iGreen => unsigned(vga_g),
			iBlue => unsigned(vga_b),
			oHsync=>hsync_n_dithered,
			oVsync=>vsync_n_dithered,
			oRed(7 downto 0) => red_dithered,
			oGreen(7 downto 0) => grn_dithered,
			oBlue(7 downto 0) => blu_dithered
		);
		
process(clk_114)
begin
	if rising_edge(clk_114) then
		red<=red_dithered(7 downto 3);
		grn<=grn_dithered(7 downto 3);
		blu<=blu_dithered(7 downto 3);
		hsync_n<=hsync_n_dithered;
		vsync_n<=vsync_n_dithered;
	end if;
end process;

sdaudio: component hybrid_pwm_sd
	port map
	(
		clk => clk_114,
		d_l(15) => not audio_l(15),
		d_l(14 downto 0) => std_logic_vector(audio_l(14 downto 0)),
		q_l => sigma_l,
		d_r(15) => not audio_r(15),
		d_r(14 downto 0) => std_logic_vector(audio_r(14 downto 0)),
		q_r => sigma_r
	);

end architecture;

