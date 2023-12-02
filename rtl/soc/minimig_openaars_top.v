`timescale 1ns / 1ns
/********************************************/
/* minimig_mist_top.v                       */
/* MiST Board Top File                      */
/*                                          */
/* 2012-2015, rok.krajnc@gmail.com          */
/********************************************/
`include "minimig_defines.vh"


module minimig_openaars_top (
  // Crystal clock input
  input wire clk_50,
  // input wire clk_100_p,
  // input wire clk_100_n,
  // RS232
  output wire uart0_txd, // rs232 txd
  input  wire uart0_rxd, // rs232 rxd
  input  wire uart0_cts, // rs232 cts Clear to send
  output wire uart0_rts, // rs232 rts Request to send
  output wire uart1_txd, // rs232 txd
  input  wire uart1_rxd, // rs232 rxd
  // SD card (SPI)
  output wire sd_m_clk,
  output wire sd_m_cmd,
  input  wire sd_m_d0,
  output wire sd_m_d1,
  output wire sd_m_d2,
  output wire sd_m_d3,
  input  wire sd_m_cdet,
  // RTC SPI
  input  wire rtc_int_n, // Interrupt from RTC
  output wire rtc_spi_ce, // SPI chip select
  output wire rtc_spi_clk, // SPI clock
  output wire rtc_spi_cmd, // CMD or MOSI
  input  wire rtc_spi_data0, // DAT0 or MISO
  input  wire rtc_clkout, // PCF2123 programmable clock output
  // SDRAM
  output wire dr_clk,
  output wire dr_cke,
  output wire dr_cs_n,
  output wire [12:0] dr_a,
  output wire [1:0] dr_ba,
  output wire dr_ras_n,
  output wire dr_cas_n,
  output wire [1:0] dr_dqm,
  inout  wire [15:0] dr_d,
  output wire dr_we_n,
  // ADV7511 video chip
  output wire dv_clk,
  // I2C interconnect ADV7511, MAX9850
  inout  wire io_sda,
  inout  wire io_scl,
  input  wire dv_int,
  output wire dv_de,
  output wire dv_hsync,
  output wire dv_vsync,
  output wire dv_cecclk,
  output wire [11:0] dv_d,
  // Joystick ports via MCP32S17
  output wire js_mosi,
  inout  wire js_miso,
  output wire js_cs,
  output wire js_sck,
  input  wire js_inta,
  // PS2 keyboard
  inout  wire ps2_clk1,
  inout  wire ps2_data1,
  // PS2 mouse
  inout  wire ps2_clk2,
  inout  wire ps2_data2,
  // MAX 9850 i2s headphone out
  output wire max_sclk,
  output wire max_lrclk,
  output wire max_i2s,
  // LEDS
  output wire led_core,
  output wire led_hdisk,
  output wire led_user,
  output wire led_power,
  output wire led_fdisk,
  // Board button input
  // (* mark_debug = "true" *)
  input wire button_reset_n_in,
  input wire button_osd_in
);

////////////////////////////////////////
// internal signals                   //
////////////////////////////////////////

// Clock
// wire        clk_in;
wire        clk_28;
wire        clk_114;
wire        clk_148;
wire        clk_fb_main;
wire        pll_locked_main;
wire        pll_locked_minimig;

// Reset
// (* mark_debug = "true" *)
wire        reset_n;
wire        amiga_key_stb;

// LED
wire        led_fpower;
wire        led_disk;

// Serial
wire        ctrl_tx;
wire        ctrl_rx;
wire        amiga_tx;
wire        amiga_rx;
wire        amiga_rts;
wire        amiga_cts;

// Video interface
wire        vga_pixel;
wire        vga_selcs;
wire        vga_cs;
wire        vga_hs;
wire        vga_vs;
wire [7:0]  vga_r;
wire [7:0]  vga_g;
wire [7:0]  vga_b;
wire [7:0]  hoffset;
wire [7:0]  voffset;

// RTG
wire        rtg_ena;

// SDRAM
wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire        sdram_nwe;
wire        sdram_ncas;
wire        sdram_nras;
wire        sdram_ncs;
wire        sdram_clk;
wire        sdram_cke;
wire [1:0]  sdram_ba;

// Audio
wire [15:0] audio_l;
wire [15:0] audio_r;
// wire [15:0] audio_l_mx;
// wire [15:0] audio_r_mx;

// PS2
wire        ps2_dat_i;
wire        ps2_clk_i;
wire        ps2_mdat_i;
wire        ps2_mclk_i;
wire        ps2_dat_o;
wire        ps2_clk_o;
wire        ps2_mdat_o;
wire        ps2_mclk_o;

// keyboard
// wire [7:0]  amiga_key;

// Joystick/mouse input
wire [6:0]  joya;
wire [6:0]  joyb;

// SD Card
wire        sd_miso;
wire        sd_mosi;
wire        sd_clk;
wire        sd_cs;

// I2C
wire        scl_i;
wire        scl_t;
wire        scl_o;
wire        sda_i;
wire        sda_t;
wire        sda_o;
wire        dv_scl_i;
wire        dv_scl_t;
wire        dv_scl_o;
wire        dv_sda_i;
wire        dv_sda_t;
wire        dv_sda_o;

// Display scaler
wire [15:0] vpos_data;

// Floppy /HD activity
wire  floppy_frd;
wire  floppy_fwr;
wire  hd_fwr;
wire  hd_frd;

////////////////////////////////////////
// toplevel assignments               //
////////////////////////////////////////

// Reset button
//assign reset_n = !reset_28; // Only release reset when PLL is stable

// LED
assign led_power = ~led_fpower;
assign led_fdisk  = ~led_disk;
assign led_user = sd_cs;
assign led_hdisk = ~(hd_frd | hd_fwr);
assign led_core  = ~(floppy_frd | floppy_fwr | hd_fwr | hd_frd);

// PS2 ports tristate
// keyboard
assign ps2_clk1  = ps2_clk_o ? 1'bZ : 1'b0;
assign ps2_clk_i = ps2_clk1;
assign ps2_data1 = ps2_dat_o ? 1'bZ : 1'b0;
assign ps2_dat_i = ps2_data1;

// Mouse
assign ps2_clk2   = ps2_mclk_o ? 1'bZ : 1'b0;
assign ps2_mclk_i = ps2_clk2;
assign ps2_data2  = ps2_mdat_o ? 1'bZ : 1'b0;
assign ps2_mdat_i = ps2_data2;

// SDCard
assign sd_m_clk   = sd_clk;
assign sd_m_cmd   = sd_mosi;
assign sd_miso    = sd_m_d0;
assign sd_m_d1  = 1'b1;
assign sd_m_d2  = 1'b1;
assign sd_m_d3  = sd_cs;


// HDMI CEC clock
assign dv_cecclk  = clk_28;

// Sync button input to lowest clock
wire button_osd_n;
wire button_reset_n;
sync_buttons sync_buttons_i (
  .clk(clk_28),
  .sys_reset_n_in(button_reset_n_in),
  .button_osd_in(button_osd_in),
  .osd_button(button_osd_n),
  .reset_button_n(button_reset_n)
);

// UART Either Debug
assign amiga_rx = uart0_rxd;
assign uart0_txd = amiga_tx;

// UART Either Amiga
assign amiga_cts = uart0_cts;
assign uart0_rts = amiga_rts;
assign ctrl_rx = uart1_rxd;
assign uart1_txd = ctrl_tx;

////////////////////////////////////////
// HDMI Clock 74.25MHz                //
////////////////////////////////////////

// wire clk_100_l;
// wire clk_100_g;

// IBUFDS clk_100_ds (
//   .I(clk_100_p),
//   .IB(clk_100_n),
//   .O(clk_100_l)
// );

// BUFG clk_100_bufg (
//   .I(clk_100_l),
//   .O(clk_100_g)
// );

// // Test if the clock works
// reg led_user_r;

// always @(posedge clk_100_g) begin
//   if (reset_button_n == 1'b0) begin
//     led_user_r <= 1'b0;
//   end else begin
//     led_user_r <= 1'b1;
//   end
// end

// assign led_user = led_user_r;


MMCME2_ADV #(
  .BANDWIDTH("OPTIMIZED"),
  .CLKFBOUT_MULT_F(37.125), // 1000  MHz
  .CLKFBOUT_PHASE(0.000), // No offset
  .CLKIN1_PERIOD(20), // 50      MHz (20 ns)
  .CLKOUT0_DIVIDE_F(6.25), // 148.5 MHz /4 divide
  .DIVCLK_DIVIDE(2),
  .REF_JITTER1(0.002),
  .REF_JITTER2(0.010)
) clk_hdmi (
  .PWRDWN(1'b0),
  .RST(1'b0),
  .CLKIN1(clk_50),
  .CLKFBIN(clk_fb_main),
  .CLKFBOUT(clk_fb_main),
  .CLKOUT0(clk_148), //  100 MHz HDMI base clock
  .LOCKED(pll_locked_main)
);

////////////////////////////////////////
// I2C bus logic                      //
////////////////////////////////////////
assign scl_i = io_scl;
assign dv_scl_i = io_scl;
assign io_scl = (scl_t == 1'b0 | dv_scl_t == 1'b0) ? 1'b0 : 1'bZ;
assign sda_i = io_sda;
assign dv_sda_i = io_sda;
assign io_sda = (sda_t == 1'b0 | dv_sda_t == 1'b0) ? 1'b0 : 1'bZ;

////////////////////////////////////////
// Modules                            //
////////////////////////////////////////

// Synchronize reset
gen_reset #(
  .resetCycles(524284)
) myReset (
  .clk(clk_28), // Needs to be crystal clock
  .enable(1'b1),
  .button(!button_reset_n), // pin is active low, module needs active high
  .initial_reset(),
  .reset(),
  .nreset(reset_n)
);


// SPI to joystick / mouse input
// Joystick bits(5-0) = fire2,fire,up,down,left,right mapped to GPIO header
// Joystick bits(5-0) = fire2,fire,up,down,left,right mapped to GPIO header
mcp23s17_input my_joystick_ports (
  .clk(clk_28),
  .rst(!reset_n),

  .inta(js_inta),

  .mosi(js_mosi),
  .miso(js_miso),
  .cs(js_cs),
  .sck(js_sck),

  .ready(),

  .joya(joya[5:0]),
  .joyb(joyb[5:0])
);
assign joya[6] = 1'b1;
assign joyb[6] = 1'b1;

// mix_channels my_mix_channels (
//   .clk(clk_114),
//   .rst_n(reset_n),

//   .en(1'b1),

//   .left_in(audio_l),
//   .right_in(audio_r),

//   .left_out(audio_l_mx),
//   .right_out(audio_r_mx)

// );

// i2s transmittor
i2s_tx my_i2s_transmitter (
  .clk(clk_114),
  .rst(!reset_n),

  .prescaler(16),
  .sclk(max_sclk),
  .lrclk(max_lrclk),
  .sdata(max_i2s),

  .left_chan(audio_l),
  .right_chan(audio_r)
);

// Module to configure the ADV7511 and Max9850
i2c_sender myi2c_sender (
  .clk(clk_28),
  .rst(!reset_n),
  .resend(1'b0),
  .read_regs(1'b0),
  .dv_int(dv_int),
  .scl_i(dv_scl_i),
  .scl_t(dv_scl_t),
  .scl_o(dv_scl_o),
  .sda_i(dv_sda_i),
  .sda_t(dv_sda_t),
  .sda_o(dv_sda_o)
);

// Video signal to dual data rate
// To save pins on the FPGA
pal_to_ddr my_pal_to_ddr (
  .clk_148(clk_148),
  .clk_114(clk_114),
  .reset(~reset_n),
  // VGA input
  .vga_clk_pixel(vga_pixel),
  // Input PAL
  .i_pal_vsync(!vga_vs),
  .i_pal_hsync(!vga_hs),
  .i_pal_r(vga_r),
  .i_pal_g(vga_g),
  .i_pal_b(vga_b),
  // Video offset
  .i_hoffset(hoffset),
  .i_voffset(voffset),
  // RTG
  .i_rtg_enable(rtg_ena),
  //.i_pal_cs(vga_cs),
  // Output HDMI
  .o_clk_pixel(dv_clk),
  .o_de(dv_de),
  .o_vsync(dv_vsync),
  .o_hsync(dv_hsync),
  .o_data(dv_d)
);

// Instatiation of the Minimig Core
minimig_virtual_top
#(
  .debug(1'b0),
  .havertg(1'b1),
  .haveaudio(1'b1),
  .havec2p(1'b0),
  .havei2c(1'b1),
  .havevpos(1'b1),
  .havespirtc(1'b1)
) openaars_virtual_top (
  .CLK_IN(clk_50),
  .CLK_28(clk_28),
  .CLK_114(clk_114),
  .PLL_LOCKED(pll_locked_minimig),
  .RESET_N(reset_n),
  .LED_POWER(led_fpower),
  .LED_DISK(led_disk),
  .MENU_BUTTON(button_osd_n),
  .CTRL_TX(ctrl_tx),
  .CTRL_RX(ctrl_rx),
  .AMIGA_TX(amiga_tx),
  .AMIGA_RX(amiga_rx),
  .AMIGA_RTS(amiga_rts),
  .AMIGA_CTS(amiga_cts),
  .VGA_PIXEL(vga_pixel),
  .VGA_SELCS(vga_selcs),
  .VGA_CS(vga_cs),
  .VGA_HS(vga_hs),
  .VGA_VS(vga_vs),
  .VGA_R(vga_r),
  .VGA_G(vga_g),
  .VGA_B(vga_b),
  .RTG_ENABLE(rtg_ena),
  .SDRAM_DQ(dr_d),
  .SDRAM_A(dr_a),
  .SDRAM_DQML(dr_dqm[0]),
  .SDRAM_DQMH(dr_dqm[1]),
  .SDRAM_nWE(dr_we_n),
  .SDRAM_nCAS(dr_cas_n),
  .SDRAM_nRAS(dr_ras_n),
  .SDRAM_nCS(dr_cs_n),
  .SDRAM_BA(dr_ba),
  .SDRAM_CLK(dr_clk),
  .SDRAM_CKE(dr_cke),
  .AUDIO_L(audio_l),
  .AUDIO_R(audio_r),
  .PS2_DAT_I(ps2_dat_i),
  .PS2_CLK_I(ps2_clk_i),
  .PS2_MDAT_I(ps2_mdat_i),
  .PS2_MCLK_I(ps2_mclk_i),
  .PS2_DAT_O(ps2_dat_o),
  .PS2_CLK_O(ps2_clk_o),
  .PS2_MDAT_O(ps2_mdat_o),
  .PS2_MCLK_O(ps2_mclk_o),
  .AMIGA_RESET_N(reset_n),
  // .AMIGA_KEY(),
  .AMIGA_KEY_STB(amiga_key_stb),
  // .C64_KEYS(64'hFEDCBA9876543210), // What for ??
  .JOYA(joya),
  .JOYB(joyb),
  .JOYC(7'h7f),
  .JOYD(7'h7f),
// RTC SPI
  .RTC_INT_N(rtc_int_n), // Interrupt from RTC
  .RTC_SPI_CE(rtc_spi_ce), // SPI chip select
  .RTC_SPI_CLK(rtc_spi_clk), // SPI clock
  .RTC_SPI_CMD(rtc_spi_cmd), // CMD or tttI
  .RTC_SPI_DATA0(rtc_spi_data0), // DAT0 or MISO
  .RTC_CLKOUT(rtc_clkout), // PCF2123 programmable clock output
  // SDCARD
  .SD_MISO(sd_miso),
  .SD_MOSI(sd_mosi),
  .SD_CLK(sd_clk),
  .SD_CS(sd_cs),
  .SD_ACK(1'b1),
  .SCL_I(scl_i),
  .SCL_O(scl_o),
  .SCL_T(scl_t),
  .SDA_I(sda_i),
  .SDA_O(sda_o),
  .SDA_T(sda_t),
  .RTC_CS(),
  .VPOS_DATA(vpos_data),
  .floppy_frd(),
  .floppy_fwr(),
  .hd_fwr(hd_fwr),
  .hd_frd(hd_frd)
);

// Assign video position data
assign hoffset = vpos_data[7:0];
assign voffset = vpos_data[15:8];

endmodule
