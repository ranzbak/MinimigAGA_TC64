/********************************************/
/* minimig_mist_top.v                       */
/* MiST Board Top File                      */
/*                                          */
/* 2012-2015, rok.krajnc@gmail.com          */
/********************************************/

`include "minimig_defines.vh"
`include "openaars_defines.vh"

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
  // DDRAM
  output ddr3_ck_p_o,
  output ddr3_ck_n_o,
  output ddr3_cke_o,
  output ddr3_reset_n_o,
  output ddr3_ras_n_o,
  output ddr3_cas_n_o,
  output ddr3_we_n_o,
  // output ddr3_cs_n_o,
  output [2:0]  ddr3_ba_o,
  output [13:0] ddr3_addr_o,
  output ddr3_odt_o,
  output [1:0] ddr3_dm_o,
  inout [1:0] ddr3_dqs_p_io,
  inout [1:0] ddr3_dqs_n_io,
  inout [15:0] ddr3_dq_io,

  // ADV7511 video chip
  output dv_clk,
  // I2C interconnect ADV7511, MAX9850
  inout io_sda,
  inout io_scl,
  (* mark_debug = "true" *)
  input dv_int,
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
  (* mark_debug = "true" *)
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
  wire        clk_148;
  wire        clk_fb_main;
  wire        pll_locked_main;
  wire        pll_locked_minimig;

  // Reset
  wire        reset_n;
  wire        amiga_reset_n;
  wire        amiga_key_stb;

  // LED
  wire        led_fpower;
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

  ////////////////////////////////////////
  // toplevel assignments               //
  ////////////////////////////////////////

  // Reset button
  //assign reset_n = !reset_28; // Only release reset when PLL is stable
  assign amiga_reset_n = reset_n;
  assign menu_button = button_osd;

  // LED
  assign led_power = ~led_fpower;
  assign led_fdisk  = ~led_disk;
  assign led_hdisk = sd_cs; // Should be replaced with the actual HD LED later
  assign led_core  = 1'b1;

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
  // TODO: remove debug when done with video
  assign pmod_10    = vga_vs;
  assign pmod_9     = vga_hs;
  assign pmod_2     = vga_cs;
  assign pmod_11    = vga_pixel;

  // UART Either Amiga or Debug
  //assign ctrl_rx = uart3_rxd;
  //assign uart3_txd = ctrl_tx;
  assign amiga_rx = uart3_rxd;
  assign uart3_txd = amiga_tx;

  ////////////////////////////////////////
  // HDMI Clock                         //
  ////////////////////////////////////////
  MMCME2_ADV #(
  .BANDWIDTH("OPTIMIZED"),
  .CLKFBOUT_MULT_F(23.0), // 1000  MHz
  .CLKFBOUT_PHASE(0.000), // No offset
  .CLKIN1_PERIOD(20), // 50      MHz (20 ns)
  .CLKOUT0_DIVIDE_F(7.75), // 148    MHz /4 divide
  .DIVCLK_DIVIDE(1),
  .REF_JITTER1(0.010)
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
  wire reset_n_50;
  gen_reset #(
  .resetCycles(524284)
  ) myReset (
    .clk(clk_50),
    .enable(1'b1),
    .button(!sys_reset_in),
    .nreset(reset_n_50)
  );
  reg [1:0] r_reset_sync;
  //wire r_reset_n_;
  always @(posedge clk_28)
  begin
    r_reset_sync <= { r_reset_sync[0], reset_n_50 };
  end
  assign reset_n = r_reset_sync[1];

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
    .dv_int(dv_int | ~button_user),
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
    .clk(clk_148),
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
  #( .debug(1'b0),
  .havertg(1'b1),
  .haveaudio(1'b1),
  .havec2p(1'b0),
  .havei2c(1'b1),
  .havevpos(1'b1),
  .ram_64meg(1'b1)
  ) openaars_virtual_top (
    .CLK_IN(clk_50),
    .CLK_28(clk_28),
    .CLK_114(clk_114),
    .PLL_LOCKED(pll_locked_minimig),
    .RESET_N(reset_n),
    // LED's
    .LED_POWER(led_fpower),
    .LED_DISK(led_disk),
    // Hardware button to enable endponit
    .MENU_BUTTON(menu_button),
    // Host CPU serial port
    .CTRL_TX(ctrl_tx),
    .CTRL_RX(ctrl_rx),
    // Serial port
    .AMIGA_TX(amiga_tx),
    .AMIGA_RX(amiga_rx),
    // Video output
    .VGA_PIXEL(vga_pixel),
    .VGA_SELCS(vga_selcs),
    .VGA_CS(vga_cs),
    .VGA_HS(vga_hs),
    .VGA_VS(vga_vs),
    .VGA_R(vga_r),
    .VGA_G(vga_g),
    .VGA_B(vga_b),
    .RTG_ENABLE(rtg_ena),
    // SDRAM
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
    // DDRAM
    .DDR3_CK_P_O(ddr3_ck_p_o),
    .DDR3_CK_N_O(ddr3_ck_n_o),
    .DDR3_CKE_O(ddr3_cke_o),
    .DDR3_RESET_N_O(ddr3_reset_n_o),
    .DDR3_RAS_N_O(ddr3_ras_n_o),
    .DDR3_CAS_N_O(ddr3_cas_n_o),
    .DDR3_WE_N_O(ddr3_we_n_o),
    .DDR3_CS_N_O(ddr3_cs_n_o),
    .DDR3_BA_O(ddr3_ba_o),
    .DDR3_ADDR_O(ddr3_addr_o),
    .DDR3_ODT_O(ddr3_odt_o),
    .DDR3_DM_O(ddr3_dm_o),
    .DDR3_DQS_P_IO(ddr3_dqs_p_io),
    .DDR3_DQS_N_IO(ddr3_dqs_n_io),
    .DDR3_DQ_IO(ddr3_dq_io),
    // Audio out
    .AUDIO_L(audio_l),
    .AUDIO_R(audio_r),
    // Mouse an keyboard IO
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
    // C64 keys not used
    .C64_KEYS(64'hFEDCBA9876543210), // What for ??
    // Joystick
    .JOYA(joya),
    .JOYB(joyb),
    .JOYC(),
    .JOYD(),
    // SPI SD card
    .SD_MISO(sd_miso),
    .SD_MOSI(sd_mosi),
    .SD_CLK(sd_clk),
    .SD_CS(sd_cs),
    .SD_ACK(1'b1),
    // RTC clock
    .RTC_CS(),
    .SCL_I(scl_i),
    .SCL_O(scl_o),
    .SCL_T(scl_t),
    .SDA_I(sda_i),
    .SDA_O(sda_o),
    .SDA_T(sda_t),
    .VPOS_DATA(vpos_data)
  );

  // Assign video position data
  assign hoffset = vpos_data[7:0];
  assign voffset = vpos_data[15:8];

endmodule
