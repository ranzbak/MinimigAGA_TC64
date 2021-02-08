/********************************************/
/* minimig_mist_top.v                       */
/* MiST Board Top File                      */
/*                                          */
/* 2012-2015, rok.krajnc@gmail.com          */
/********************************************/

`include "minimig_defines.vh"

//`define HOSTONLY


// Boolean define
`define true 1
`define false 0

module minimig_openaars_top (
  input clk_50,
  // RS232
  output uart3_txd, // rs232 txd
  input uart3_rxd, // rs232 rxd
  // SD card (SPI)
  output sd_m_clk,
  output sd_m_cmd, 
  input  sd_m_d0,
  output sd_m_d1,
  output sd_m_d2,
  output sd_m_d3,
  input  sd_m_cdet,
  // SDRAM
  output dr_clk,
  output dr_cke,
  output dr_cs_n,
  output [12:0] dr_a, 
  output [1:0] dr_ba,
  output dr_ras_n,
  output dr_cas_n,
  output [1:0] dr_dqm,
  inout  [15:0] dr_d,
  output dr_we_n,
  // ADV7511 video chip
  output dv_clk,
  inout dv_sda,
  inout dv_scl,
  // input dv_int,
  output dv_de,
  output dv_hsync,
  output dv_vsync,
  output dv_cecclk,
  output [11:0] dv_d,
  // Joystick ports via MCP32S17
  output js_mosi,
  inout  js_miso,
  output js_cs,
  output js_sck,
  input js_inta,
  // PS2 keyboard
  inout ps2_clk1,
  inout ps2_data1,
  // PS2 mouse
  inout ps2_clk2,
  inout ps2_data2,
  // max 9850 i2s headphone out
  output max_sclk,
  output max_lrclk,
  output max_i2s,
  // leds
  output led_core,
  output led_power,
  output led_fdisk,
  output led_hdisk,
  output led_user,
  // Floppy interface
  input exp_sel0,
  input exp_sel1,
  input exp_dir,
  input exp_step,
  input exp_chng,
  input exp_index,
  input exp_rdy,
  input exp_dkrd,
  input exp_trk0,
  input exp_dkwdb,
  input exp_dkweb,
  input exp_side,
  // Board button input
  input sys_reset_in,
  input button_user,
  input button_osd,
  // pmod
  output pmod_12,
  output pmod_1,
  output pmod_11,
  output pmod_2,
  output pmod_9,
  output pmod_10
);

////////////////////////////////////////
// internal signals                   //
////////////////////////////////////////

// Clock
wire        clk_in;
wire        clk_28;
wire        clk_114;
wire        clk_fb_main;
wire        pll_locked_main;
wire        pll_locked_minimig;
// Reset
wire        reset_n;
wire        amiga_reset_n;
// LED
wire        led_disk;
// Input
wire        menu_button;
// Serial
wire        ctrl_tx;
wire        ctrl_rx;
wire        amiga_tx;
wire        amiga_rx;

// Video interface
wire        vga_pixel;
wire        vga_selcs;
wire        vga_cs;
wire        vga_hs;
(* mark_debug = "true", keep = "true" *)
wire        vga_vs;
wire [7:0]  vga_r;
wire [7:0]  vga_g;
wire [7:0]  vga_b;
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
wire [7:0]  amiga_key;
// Joystick/mouse input
wire [6:0]  joya;
wire [6:0]  joyb;
// SD Card
wire        sd_miso;
wire        sd_mosi;
wire        sd_clk;
wire        sd_cs;

////////////////////////////////////////
// toplevel assignments               //
////////////////////////////////////////

// Reset button
assign reset_n = sys_reset_in & pll_locked_minimig; // Only release reset when PLL is stable
assign menu_button = button_osd;

// LED
assign led_disk  = led_fdisk;
assign led_hdisk = sdram_ncs; // Workaround for now
assign led_core  = !sd_cs;

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

// PMOD pins
assign pmod_10    = vga_vs;
assign pmod_9     = vga_hs;
assign pmod_2     = vga_cs;
assign pmod_11    = vga_pixel;

////////////////////////////////////////
// HDMI Clock                         //
////////////////////////////////////////
MMCME2_BASE #(
  .CLKIN1_PERIOD(20.0),   // 50      MHz (10 ns)
  .CLKFBOUT_MULT_F(32.0), // 1600.0  MHz *16.875 common multiply
  .DIVCLK_DIVIDE(2),      // 800     MHz /2 common divide
  .CLKOUT0_DIVIDE_F(4),   // 200     MHz /4 divide
  .BANDWIDTH("LOW")
) clk_hdmi (
  .PWRDWN(1'b0),
  .RST(1'b0),
  .CLKIN1(clk_50),
  .CLKFBIN(clk_fb_main),
  .CLKFBOUT(clk_fb_main),
  .CLKOUT0(clk_200),        //  200 MHz HDMI base clock
  .LOCKED(pll_locked_main)
);


////////////////////////////////////////
// Modules                            //
////////////////////////////////////////

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
  .sioc(dv_scl),                                        
  .siod(dv_sda)
);

// Video signal to dual data rate
// To save pins on the FPGA
pal_to_ddr my_pal_to_ddr (
  .clk(clk_200),
  // Input PAL
  .i_pal_vsync(!vga_vs),
  .i_pal_hsync(!vga_hs),
  .i_pal_r(vga_r),
  .i_pal_g(vga_g),
  .i_pal_b(vga_b),
  //.i_pal_pixel(vga_pixel),
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
#( .debug(1'b0),
  .havertg(1'b1),
  .haveaudio(1'b1),
  .havec2p(1'b1)
) openaars_virtual_top (
  .CLK_IN(clk_50),
  .CLK_28(clk_28),
  .CLK_114(clk_114),
  .PLL_LOCKED(pll_locked_minimig),
  .RESET_N(reset_n),
  .LED_POWER(led_power),
  .LED_DISK(led_disk),
  .MENU_BUTTON(menu_button),
  .CTRL_TX(uart3_txd),
  .CTRL_RX(uart3_rxd),
  .AMIGA_TX(amiga_tx),
  .AMIGA_RX(amiga_rx),
  .VGA_PIXEL(vga_pixel),
  .VGA_SELCS(vga_selcs),
  .VGA_CS(vga_cs),
  .VGA_HS(vga_hs),
  .VGA_VS(vga_vs),
  .VGA_R(vga_r),
  .VGA_G(vga_g),
  .VGA_B(vga_b),
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
  .AMIGA_RESET_N(amiga_reset_n),
  .AMIGA_KEY(),
  .AMIGA_KEY_STB(amiga_key_stb),
  .C64_KEYS(64'hFEDCBA9876543210), // What for ?? 
  .JOYA(joya),
  .JOYB(joyb),
  .JOYC(open),
  .JOYD(open),
  .SD_MISO(sd_miso),
  .SD_MOSI(sd_mosi),
  .SD_CLK(sd_clk),
  .SD_CS(sd_cs),
  .SD_ACK(1'b1)
);

endmodule
