/********************************************/
/* minimig_mist_top.v                       */
/* MiST Board Top File                      */
/*                                          */
/* 2012-2015, rok.krajnc@gmail.com          */
/********************************************/

// board type define
`define MINIMIG_VIRTUAL
//`define HOSTONLY

`include "minimig_defines.vh"

module minimig_virtual_top #(
    parameter hostonly=0,
    parameter debug = 0,
    parameter spimux = 0,
    parameter havertg = 1,
    parameter haveaudio = 1,
    parameter havec2p = 1,
    parameter havespirtc = 1,
    parameter havei2c = 1,
    parameter havevpos = 0,
    parameter ram_64meg = 0,
    // Zorro-III fast RAM on the DDR3 island instead of the SDRAM.
    // findings/ddr3/design.md; the island itself lives in minimig_openaars_top.v.
    parameter haveddr3 = 1,
    parameter Z3RAM3_FORCE_OFF = 0, // diagnostic-only: force the leftover 3rd ZIII board off even when haveddr3=0
    // Debug build only: instantiate ila_fastram (tools/vivado/build_ila.tcl
    // sets this generic to 1) on the CPU side of the DDR3 fast RAM, so a real
    // Workbench boot can be captured.  0 in every normal build, and then not
    // one flip-flop of it exists.
    parameter DDR3_FASTRAM_ILA = 0)
(
    // clock inputs
    input wire            CLK_IN,
    output wire           CLK_114,
    output wire           CLK_28,
    output wire           PLL_LOCKED,
    input wire            RESET_N,

    // Button inputs
    input         MENU_BUTTON,

    // LED outputs
    output wire           LED_POWER, // LED green
    output wire           LED_DISK, // LED red

    // UART DEBUG
    output wire           CTRL_TX, // UART Transmitter
    input wire            CTRL_RX, // UART Receiver

    // UART AMIGA
    output wire           AMIGA_TX, // UART Transmitter
    input wire            AMIGA_RX, // UART Receiver
    input wire            AMIGA_CTS, // UART Clear to send
    output wire           AMIGA_RTS, // UART Request to send

    // VGA
    output wire           VGA_PIXEL, // high pulse for each new pixel
    output wire           VGA_SELCS, // Select CSYNC
    output wire           VGA_CS, // VGA C_SYNC
    output wire           VGA_HS, // VGA H_SYNC
    output wire           VGA_VS, // VGA V_SYNC
    output wire [  8-1:0] VGA_R, // VGA Red[5:0]
    output wire [  8-1:0] VGA_G, // VGA Green[5:0]
    output wire [  8-1:0] VGA_B, // VGA Blue[5:0]

    // RTG
    output wire           RTG_ENABLE, // True when RTG is enabled

    // SDRAM
    inout  wire [ 16-1:0] SDRAM_DQ, // SDRAM Data bus 16 Bits
    output wire [ 13-1:0] SDRAM_A, // SDRAM Address bus 13 Bits
    output wire           SDRAM_DQML, // SDRAM Low-byte Data Mask
    output wire           SDRAM_DQMH, // SDRAM High-byte Data Mask
    output wire           SDRAM_nWE, // SDRAM Write Enable
    output wire           SDRAM_nCAS, // SDRAM Column Address Strobe
    output wire           SDRAM_nRAS, // SDRAM Row Address Strobe
    output wire           SDRAM_nCS, // SDRAM Chip Select
    output wire [  2-1:0] SDRAM_BA, // SDRAM Bank Address
    output wire           SDRAM_CLK, // SDRAM Clock
    output wire           SDRAM_CKE, // SDRAM Clock Enable

    // MINIMIG specific
    output wire[15:0]     AUDIO_L, // sigma-delta DAC output left
    output wire[15:0]     AUDIO_R, // sigma-delta DAC output right

    // Keyboard / Mouse
    input                 PS2_DAT_I, // PS2 Keyboard Data
    input                 PS2_CLK_I, // PS2 Keyboard Clock
    input                 PS2_MDAT_I, // PS2 Mouse Data
    input                 PS2_MCLK_I, // PS2 Mouse Clock
    output                PS2_DAT_O, // PS2 Keyboard Data
    output                PS2_CLK_O, // PS2 Keyboard Clock
    output                PS2_MDAT_O, // PS2 Mouse Data
    output                PS2_MCLK_O, // PS2 Mouse Clock

    // Potential Amiga keyboard from docking station
    input                 AMIGA_RESET_N,
    input     [7:0]       AMIGA_KEY,
    input                 AMIGA_KEY_STB,
    input     [63:0]      C64_KEYS,
    // Joystick
    input       [  7-1:0] JOYA, // joystick port A
    input       [  7-1:0] JOYB, // joystick port B
    input       [  7-1:0] JOYC, // joystick port A
    input       [  7-1:0] JOYD, // joystick port B

`ifdef MINIMIG_I2C_BUS
    // I2C bus from the host CPU to pereferals on the board
    input                 SCL_I, // Clock in
    output                SCL_O, // Clock out
    output                SCL_T, // Clock tristate
    input                 SDA_I, // Clock in
    output                SDA_O, // Clock out
    output                SDA_T, // Clock tristate
`endif

// `ifdef MINIMIG_RTC_BUS
    // RTC SPI
    input  wire           RTC_INT_N, // Interrupt from RTC
    output wire           RTC_SPI_CE, // SPI chip select
    output wire           RTC_SPI_CLK, // SPI clock
    output wire           RTC_SPI_CMD, // CMD or MOSI
    input  wire           RTC_SPI_DATA0, // DAT0 or MISO
    input  wire           RTC_CLKOUT, // PCF2123 programmable clock output
// `endif

`ifdef MINIMIG_VPOS
    // Video scaler positions
    output    [ 16-1:0]   VPOS_DATA,
`endif

    // SPI
    input wire            SD_MISO, // inout
    output wire           SD_MOSI,
    output wire           SD_CLK,
    output wire           SD_CS,
    input wire            SD_ACK,

    output wire           RTC_CS,

    // HD and Floppy activity output
    output wire           floppy_fwr,
    output wire           floppy_frd,
    output wire           hd_fwr,
    output wire           hd_frd,

    // DDR3 island native 128-bit request port (clk_mem domain).  The island
    // (rtl/ddr3/ddr3_top.v) is instantiated one level up, in
    // minimig_openaars_top.v; only this handshake crosses between them.
    input wire            DDR3_CLK_MEM,     // island clk100
    input wire            DDR3_INIT_DONE,   // island controller init complete
    output wire           DDR3_REQ_VALID,
    output wire [ 16-1:0] DDR3_REQ_WR,      // byte enables; 0 = read
    output wire [ 32-1:0] DDR3_REQ_ADDR,
    output wire [128-1:0] DDR3_REQ_WDATA,
    input wire            DDR3_REQ_ACCEPT,
    input wire            DDR3_RESP_VALID,
    input wire [128-1:0]  DDR3_RESP_RDATA
);


////////////////////////////////////////
// internal signals                   //
////////////////////////////////////////

// clock
wire           clk_sdram;
wire           clk7_en;
wire           clk7n_en;
wire           c1;
wire           c3;
wire           cck;
wire [ 10-1:0] eclk;

// reset
wire           pll_rst;
wire           sdctl_rst;
wire           rst_50;
wire           rst_minimig;

// ctrl
wire           rom_status;
wire           ram_status;
wire           reg_status;

// tg68
wire           tg68_rst;
wire [ 16-1:0] tg68_dat_in;
wire [ 16-1:0] tg68_dat_in2;
wire [ 16-1:0] tg68_dat_out;
wire [ 16-1:0] tg68_dat_out2;
wire [ 32-1:0] tg68_adr;
wire [  3-1:0] tg68_IPL;
wire           tg68_dtack;
wire           tg68_as;
wire           tg68_uds;
wire           tg68_lds;
wire           tg68_uds2;
wire           tg68_lds2;
wire           tg68_rw;
wire           tg68_ena7RD;
wire           tg68_ena7WR;
wire           tg68_ena28;
wire [ 16-1:0] tg68_cout;
wire [ 16-1:0] tg68_cin;
wire           tg68_cpuena;
wire [  4-1:0] cpu_config;
wire [4:0]     board_configured;
wire           turbochipram;
wire           turbokick;
wire [1:0]     slow_config;
wire           aga;
wire           cache_inhibit;
wire           cacheline_clr;
wire [ 32-1:0] tg68_cad;
wire [  7-1:0] tg68_cpustate;
// DDR3 Zorro-III fast RAM port (TG68K <-> ddr3_fastram)
wire [ 26-1:1] tg68_ddraddr;
wire           tg68_ddrcs;
wire [ 16-1:0] tg68_ddrout;
wire           tg68_ddrena;
wire           tg68_ddrready;
// cpustate as seen by the DDR3 backend: the wrapper's cpustate with the chip
// select (bit 2) replaced by the DDR3 one.  Everything else, cpuLongword
// (bit 6) included, is passed through untouched.
wire [  7-1:0] tg68_ddrcpustate = {tg68_cpustate[6:3], tg68_ddrcs, tg68_cpustate[1:0]};
// DDR3 fast RAM debug taps (clk_114 domain), driven by ddr3_fastram and probed
// by ila_fastram when DDR3_FASTRAM_ILA = 1.  Declared unconditionally so the
// port map below is the same in both builds; with the ILA off nothing reads
// them and synthesis prunes the lot.
wire [  2-1:0] ddr3_dbg_bstate;
wire           ddr3_dbg_cdc_ready;
wire           ddr3_dbg_cdc_req;
wire           ddr3_dbg_cdc_done;
wire           ddr3_dbg_req_rd;
wire [ 16-1:0] ddr3_dbg_req_be;
wire [ 32-1:0] ddr3_dbg_req_addr;
wire [128-1:0] ddr3_dbg_req_wdata;
wire           ddr3_dbg_req_tgl;
wire [128-1:0] ddr3_dbg_resp_rdata;
wire           ddr3_dbg_ack_tgl;
wire           ddr3_dbg_sdr_read_req;
wire           ddr3_dbg_sdr_read_ack;
wire [ 16-1:0] ddr3_dbg_sdr_dat_r;
wire           ddr3_dbg_sdr_write_req;
wire           ddr3_dbg_sdr_write_ack;
wire [ 26-1:1] ddr3_dbg_sdr_adr;
wire [ 32-1:0] ddr3_dbg_sdr_dat_w;
wire [  4-1:0] ddr3_dbg_sdr_dqm_w;
wire           tg68_nrst_out;
//wire           tg68_cdma;
wire           tg68_clds;
wire           tg68_cuds;
wire [  4-1:0] tg68_CACR_out;
wire [ 32-1:0] tg68_VBR_out;
wire           tg68_ovr;

// minimig
wire           led;
wire [ 16-1:0] ram_data; // sram data bus
wire [ 16-1:0] ram_data2; // sram data bus 2nd word
wire [ 16-1:0] ramdata_in; // sram data bus in
wire [ 48-1:0] chip48; // big chip read
wire [ 23-1:1] ram_address; // sram address bus
wire           _ram_bhe; // sram upper byte select
wire           _ram_ble; // sram lower byte select
wire           _ram_bhe2; // sram upper byte select 2nd word
wire           _ram_ble2; // sram lower byte select 2nd word
wire           _ram_we; // sram write enable
wire           _ram_oe; // sram output enable
wire           _15khz; // scandoubler disable
wire           sdo; // SPI data output
wire           vs;
wire           hs;
wire           cs;
wire [  8-1:0] red;
wire [  8-1:0] green;
wire [  8-1:0] blue;
reg            cs_reg;
reg            vs_reg;
reg            hs_reg;
wire           hsyncpol;
wire           vsyncpol;
reg  [  8-1:0] red_reg;
reg  [  8-1:0] green_reg;
reg  [  8-1:0] blue_reg;

// sdram
wire           reset_out;
wire [  4-1:0] sdram_cs;
wire [  2-1:0] sdram_dqm;
wire [  2-1:0] sdram_ba;

// mist
wire           user_io_sdo;
wire           minimig_sdo;
wire [  16-1:0] joya;
wire [  16-1:0] joyb;
wire [  16-1:0] joyc;
wire [  16-1:0] joyd;
//wire [  8-1:0] kbd_mouse_data;
//wire           kbd_mouse_strobe;
//wire           kms_level;
//wire [  2-1:0] kbd_mouse_type;
//wire [  3-1:0] mouse_buttons;

// Audio
wire [15:0] aud_amiga_left;
wire [15:0] aud_amiga_right; // sigma-delta DAC output right

// UART
wire minimig_rxd;
wire minimig_txd;
wire debug_rxd;
wire debug_txd;

// Realtime clock
wire [63:0] rtc;

////////////////////////////////////////
// toplevel assignments               //
////////////////////////////////////////

// SDRAM
assign SDRAM_CKE        = 1'b1;
assign SDRAM_CLK        = clk_sdram;
assign SDRAM_nCS        = sdram_cs[0];
assign SDRAM_DQML       = sdram_dqm[0];
assign SDRAM_DQMH       = sdram_dqm[1];
assign SDRAM_BA         = sdram_ba;

// reset
assign pll_rst          = 1'b0;
assign sdctl_rst        = PLL_LOCKED & RESET_N;

// RTG support...

wire rtg_ena; // RTG screen on/off
wire rtg_ena_mm; // RTG screen on/off
wire rtg_clut; // Are we in high-colour or 8-bit CLUT mode?
wire rtg_16bit; // Is high-colour mode 15- or 16-bit?
reg [3:0] rtg_pixelctr; // Counter, compared against rtg_pixelwidth
wire [3:0] rtg_pixelwidth; // Number of clocks per fetch - 1
wire [7:0] rtg_clut_idx; // The currently selected colour in indexed mode
wire rtg_pixel; // Strobe the next pixel from the FIFO

wire hblank_out;
wire vblank_out;
reg rtg_vblank;
wire rtg_blank;
reg rtg_blank_d;
reg rtg_blank_d2;
reg rtg_blank_d3;
reg [6:0] rtg_vbcounter; // Vvbco counter
wire [6:0] rtg_vbend; // Size of VBlank area


wire [7:0] rtg_r; // 16-bit mode RGB data
wire [7:0] rtg_g;
wire [7:0] rtg_b;
reg rtg_clut_in_sel; // Select first or second byte of 16-bit word as CLUT index
reg rtg_clut_in_sel_d;
wire rtg_ext; // Extend the active area by one clock.
wire [7:0] rtg_clut_r; // RGB data from CLUT
wire [7:0] rtg_clut_g;
wire [7:0] rtg_clut_b;


// RTG data fetch strobe
assign rtg_pixel=(rtg_ena && (!rtg_blank || (!rtg_blank_d && rtg_ext)) &&
        rtg_pixelctr==rtg_pixelwidth) ? 1'b1 : 1'b0;

wire rtg_clut_pixel;
assign rtg_clut_pixel = rtg_clut_in_sel & !rtg_clut_in_sel_d; // Detect rising edge;
reg rtg_pixel_d;

reg [2:0] vga_strobe_ctr;
wire vga_strobe;
assign vga_strobe = vga_strobe_ctr==3'b000 ? 1'b1 : 1'b0;

// Export a VGA pixel strobe for the dither module.
assign VGA_PIXEL=rtg_ena ? (rtg_pixel_d | (rtg_clut_pixel & rtg_clut)) : vga_strobe;

assign rtg_blank = rtg_vblank | hblank_out;

always @(posedge CLK_114) begin
    rtg_pixel_d<=rtg_pixel;
    vga_strobe_ctr<=_15khz ? {vga_strobe_ctr[2:1],1'b0}+3'b010 : vga_strobe_ctr+3'b001;

    // Delayed copies of signals
    rtg_blank_d<=rtg_blank;
    rtg_blank_d2<=rtg_blank_d;
    rtg_clut_in_sel_d<=rtg_clut_in_sel;

    // Alternate colour index at twice the fetch clock.
    if(rtg_pixelctr=={1'b0,rtg_pixelwidth[3:1]})
        rtg_clut_in_sel<=1'b1;

    // Increment the fetch clock, reset during blank.
    if(rtg_blank || rtg_pixel) begin
        rtg_pixelctr<=3'b0;
        rtg_clut_in_sel<=1'b0;
    end
    else begin
        rtg_pixelctr<=rtg_pixelctr+1;
    end
end

always @(posedge CLK_28) begin
    // Handle vblank manually, since the OS makes it awkward to use the chipset for this.
    cs_reg    <= #1 cs;
    vs_reg    <= #1 vs;
    hs_reg    <= #1 hs;
    if(vblank_out) begin
        rtg_vblank<=1'b1;
        rtg_vbcounter<=5'b0;
    end
    else if(rtg_vbcounter==rtg_vbend) begin
        rtg_vblank<=1'b0;
    end
    else if(hs & !hs_reg) begin
        rtg_vbcounter<=rtg_vbcounter+1;
    end
end

wire [25:4] rtg_baseaddr;
wire [25:0] rtg_addr;
wire [15:0] rtg_dat;

assign rtg_clut_idx = rtg_clut_in_sel_d ? rtg_dat[7:0] : rtg_dat[15:8];
assign rtg_r=rtg_16bit ? {rtg_dat[15:11],rtg_dat[15:13]} : {rtg_dat[14:10],rtg_dat[14:12]};
assign rtg_g=rtg_16bit ? {rtg_dat[10:5],rtg_dat[10:9]} : {rtg_dat[9:5],rtg_dat[9:7]};
assign rtg_b={rtg_dat[4:0],rtg_dat[4:2]};

wire rtg_ramreq;
wire [15:0] rtg_fromram;
wire rtg_fill;

// Replicate the CPU's address mangling.
wire [25:0] rtg_addr_mangled;
assign rtg_addr_mangled[25:24]=rtg_addr[25:24];
assign rtg_addr_mangled[23]=rtg_addr[23]^(rtg_addr[22]|rtg_addr[21]);
assign rtg_addr_mangled[22:0]=rtg_addr[22:0];

VideoStream myvs
(
    .clk(CLK_114),
    .reset_n((!vblank_out) & rtg_ena),
    .enable(rtg_ena),
    .baseaddr({rtg_baseaddr[24:4],4'b0}),
    // SDRAM interface
    .a(rtg_addr),
    .req(rtg_ramreq),
    .d(rtg_fromram),
    .fill(rtg_fill & havertg),
    // Display interface
    .rdreq(rtg_pixel & havertg),
    .q(rtg_dat)
);

always @ (posedge CLK_114) begin
    red_reg   <= #1 rtg_ena && !rtg_blank_d2 ? rtg_clut ? rtg_clut_r : rtg_r : red;
    green_reg <= #1 rtg_ena && !rtg_blank_d2 ? rtg_clut ? rtg_clut_g : rtg_g : green;
    blue_reg  <= #1 rtg_ena && !rtg_blank_d2 ? rtg_clut ? rtg_clut_b : rtg_b : blue;
end


// OSD glue
wire osd_window;
wire osd_pixel;
wire [1:0] osd_r;
wire [1:0] osd_g;
wire [1:0] osd_b;
assign osd_r = osd_pixel ? 2'b11 : 2'b00;
assign osd_g = osd_pixel ? 2'b11 : 2'b00;
assign osd_b = osd_pixel ? 2'b11 : 2'b10;
assign VGA_CS           = cs_reg;
assign VGA_VS           = vsyncpol ^ vs_reg;
assign VGA_HS           = hsyncpol ^ hs_reg;
//assign VGA_R[7:0]       = osd_window ? {osd_r,red_reg[7:2]} : red_reg[7:0];
assign VGA_G[7:0]       = osd_window ? {osd_g,green_reg[7:2]} : green_reg[7:0];
assign VGA_B[7:0]       = osd_window ? {osd_b,blue_reg[7:2]} : blue_reg[7:0];
// The lengths we go to in order to make an otherwise unused signal visible in signaltap!
assign VGA_R[7:0]       = osd_window ? {osd_r,red_reg[7:2]} : red_reg[7:0];



// Audio for CD images
wire aud_int;
reg [15:0] aud_left;
reg [15:0] aud_right; // sigma-delta DAC output right

reg aud_tick;
reg aud_tick_d;
reg aud_next;

wire [24:0] aud_addr;
wire [15:0] aud_sample;

wire aud_ramreq;
wire [15:0] aud_fromram;
wire aud_fill;
wire aud_ena_host;
wire aud_ena_cpu;
wire aud_clear;

wire [22:0] aud_ramaddr;
assign aud_ramaddr[15:0]=aud_addr;
assign aud_ramaddr[22:16]=7'b1101111; // 0x6f0000 in SDRAM, 0x040000 to host, 0xec0000 to Amiga

reg [9:0] aud_ctr;
always @(posedge CLK_28) begin
    aud_ctr<=aud_ctr+1;
    if (aud_ctr==10'd642) begin
        aud_tick<=1'b1;
        aud_ctr<=10'b0;
    end
    else
        aud_tick<=1'b0;
end

//  tick:   0 0 1 1 1 1 0 0
//  tick_d: 0 0 0 1 1 1 1 0
// tick^tick_d  1 0 0 0 1 0
always @(posedge CLK_114) begin
    aud_tick_d<=aud_tick;
    aud_next<=aud_tick ^ aud_tick_d;
    if (aud_tick_d==1)
        aud_left<={aud_sample[7:0],aud_sample[15:8]};
    else
        aud_right<={aud_sample[7:0],aud_sample[15:8]};
end

//assign AUDIO_L={aud_left[7:0],aud_left[15:9]};
//assign AUDIO_R={aud_right[7:0],aud_right[15:9]};

// We can use the same type of FIFO as we use for video.
VideoStream myaudiostream
(
    .clk(CLK_114),
    .reset_n(aud_ena_host | aud_ena_cpu), // !aud_clear),
    .enable(aud_ena_host | aud_ena_cpu),
    .baseaddr(25'b0),
    // SDRAM interface
    .a(aud_addr),
    .req(aud_ramreq),
    .d(aud_fromram),
    .fill(aud_fill & haveaudio),
    // Display interface
    .rdreq(aud_next & haveaudio),
    .q(aud_sample)
);


//// amiga clocks ////
amiga_clk amiga_clk (
    .rst          (1'b0             ), // async reset input
    .clk_in       (CLK_IN           ), // input clock     ( 50.000000MHz)
    .clk_114      (CLK_114          ), // output clock c0 (114.750000MHz)
    .clk_sdram    (clk_sdram        ), // output clock c2 (114.750000MHz, -146.25 deg)
    .clk_28       (CLK_28           ), // output clock c1 ( 28.687500MHz)
    .clk7_en      (clk7_en          ), // output clock 7 enable (on 28MHz clock domain)
    .clk7n_en     (clk7n_en         ), // 7MHz negedge output clock enable (on 28MHz clock domain)
    .c1           (c1               ), // clk28m clock domain signal synchronous with clk signal
    .c3           (c3               ), // clk28m clock domain signal synchronous with clk signal delayed by 90 degrees
    .cck          (cck              ), // colour clock output (3.54 MHz)
    .eclk         (eclk             ), // 0.709379 MHz clock enable output (clk domain pulse)
    .locked       (PLL_LOCKED       ), // pll locked output
    .ntsc         (                 )
);

wire amigahost_req;
wire amigahost_ack;
wire [15:0] amigahost_q;

//// TG68K main CPU ////
`ifdef HOSTONLY

assign tg68_cpustate=2'b01;
assign tg68_nrst_out=1'b1;
assign tg68_ddraddr = 25'd0;
assign tg68_ddrcs   = 1'b1;
`else

TG68K #(
    .havertg(havertg ? "true" : "false"),
    .haveaudio(haveaudio ? "true" : "false"),
    .havec2p(havec2p ? "true" : "false"),
    .haveddr3(haveddr3 ? "true" : "false")
) tg68k (
    .clk          (CLK_114          ),
    .reset        (tg68_rst         ),
    .clkena_in    (tg68_ena28       ),
    .IPL          (tg68_IPL         ),
    .dtack        (tg68_dtack       ),
    .vpa          (1'b1             ),
    .ein          (1'b1             ),
    .addr         (tg68_adr         ),
    .data_read    (tg68_dat_in      ),
    .data_read2   (tg68_dat_in2     ),
    .data_write   (tg68_dat_out     ),
    .data_write2  (tg68_dat_out2    ),
    .as           (tg68_as          ),
    .uds          (tg68_uds         ),
    .lds          (tg68_lds         ),
    .uds2         (tg68_uds2        ),
    .lds2         (tg68_lds2        ),
    .rw           (tg68_rw          ),
    .vma          (                 ),
    .wrd          (                 ),
    .ena7RDreg    (tg68_ena7RD      ),
    .ena7WRreg    (tg68_ena7WR      ),
    .fromram      (tg68_cout        ),
    .toram        (tg68_cin         ),
    .ramready     (tg68_cpuena      ),
    .ddraddr      (tg68_ddraddr     ),
    .ddrcs        (tg68_ddrcs       ),
    .fromddr      (tg68_ddrout      ),
    .ddr_ready    (tg68_ddrready    ),
    .ddr_ena      (tg68_ddrena      ),
    .cpu          (cpu_config[1:0]  ),
    .turbochipram (turbochipram     ),
    .turbokick    (turbokick        ),
    .slow_config  (slow_config      ),
    .aga          (aga              ),
    .cache_inhibit(cache_inhibit    ),
    .cacheline_clr(cacheline_clr    ),
    .ziiram_active(board_configured[0]),
    .ziiiram_active(board_configured[1]),
    .ziiiram2_active(board_configured[2]),
    .ziiiram3_active(board_configured[3]),
    //  .fastramcfg   ({&memcfg[5:4],memcfg[5:4]}),
    .eth_en       (1'b1), // TODO
    .sel_eth      (),
    .frometh      (16'd0),
    .ethready     (1'b0),
    .ramaddr      (tg68_cad         ),
    .cpustate     (tg68_cpustate    ),
    .nResetOut    (tg68_nrst_out    ),
    .skipFetch    (                 ),
    .ramlds       (tg68_clds        ),
    .ramuds       (tg68_cuds        ),
    .CACR_out     (tg68_CACR_out    ),
    .VBR_out      (tg68_VBR_out     ),
    // RTG signals
    .rtg_addr(rtg_baseaddr),
    .rtg_vbend(rtg_vbend),
    .rtg_ext(rtg_ext),
    .rtg_pixelclock(rtg_pixelwidth),
    .rtg_clut(rtg_clut),
    .rtg_16bit(rtg_16bit),
    .rtg_clut_idx(rtg_clut_idx),
    .rtg_clut_r(rtg_clut_r),
    .rtg_clut_g(rtg_clut_g),
    .rtg_clut_b(rtg_clut_b),
    .audio_buf(aud_addr[15]),
    .audio_ena(aud_ena_cpu),
    .audio_int(aud_int),
    // Amiga to host signals
    .host_req(amigahost_req),
    .host_ack(amigahost_ack),
    .host_q(amigahost_q)
);

`endif

wire [ 32-1:0] hostRD;
wire [ 32-1:0] hostWR;
wire [ 32-1:2] hostaddr;
wire [  3-1:0] hostState;
wire [3:0]     hostbytesel;
wire  [ 16-1:0] host_ramdata;
wire           host_ramack;
wire           host_ramreq;
wire  [ 16-1:0] host_hwdata;
wire           host_hwack;
wire           host_hwreq;
wire           host_we;
wire           hostreq;
wire           hostack;
wire           hostce;

//sdram sdram (
sdram_ctrl sdram (
    .cache_rst    (tg68_rst         ),
    .cache_inhibit(cache_inhibit    ),
    .cacheline_clr(cacheline_clr    ),
    .cpu_cache_ctrl (tg68_CACR_out    ),

    // Interface to SDRam
    .sdata        (SDRAM_DQ         ),
    .sdaddr       (SDRAM_A[12:0]    ),
    .dqm          (sdram_dqm        ),
    .sd_cs        (sdram_cs         ),
    .ba           (sdram_ba         ),
    .sd_we        (SDRAM_nWE        ),
    .sd_ras       (SDRAM_nRAS       ),
    .sd_cas       (SDRAM_nCAS       ),
    .sysclk       (CLK_114          ),
    .reset_in     (sdctl_rst        ),

    // Host CPU
    .hostWR       (hostWR           ),
    .hostAddr     (hostaddr         ),
    .hostwe       (host_we           ),
    .hostce       (host_ramreq      ),
    .hostbytesel  (hostbytesel      ),
    .hostRD       (host_ramdata     ),
    .hostena      (host_ramack      ),

    // Amiga CPU
    .cpuWR        (tg68_cin         ),
    .cpuAddr      (tg68_cad[25:1]   ),
    .cpuU         (tg68_cuds        ),
    .cpuL         (tg68_clds        ),
    .cpustate     (tg68_cpustate    ),
    .cpuRD        (tg68_cout        ),
    .cpuena       (tg68_cpuena      ),

    // Amiga chip ram
    //  .cpu_dma      (tg68_cdma        ),
    .chipWR       (ram_data         ),
    .chipWR2      (tg68_dat_out2    ),
    .chipAddr     ({1'b0, ram_address[22:1]}),
    .chipU        (_ram_bhe         ),
    .chipL        (_ram_ble         ),
    .chipU2       (_ram_bhe2        ),
    .chipL2       (_ram_ble2        ),
    .chipRW       (_ram_we          ),
    .chip_dma     (_ram_oe          ),
    .clk7_en      (clk7_en          ),
    .chipRD       (ramdata_in       ),
    .chip48       (chip48           ),

    // RTG memory
    .rtgAddr      (rtg_addr_mangled ),
    .rtgce        (rtg_ramreq       ),
    .rtgfill      (rtg_fill         ),
    .rtgRd        (rtg_fromram      ),

    // Audio memory
    .audAddr      (aud_ramaddr      ),
    .audce        (aud_ramreq       ),
    .audfill      (aud_fill         ),
    .audRd        (aud_fromram      ),

    .reset_out    (reset_out        ),
    .enaWRreg     (tg68_ena28       ),
    .ena7RDreg    (tg68_ena7RD      ),
    .ena7WRreg    (tg68_ena7WR      )
);


////////////////////////////////////////
// Zorro-III fast RAM on the DDR3     //
////////////////////////////////////////
// Same front end as the SDRAM path (rtl/sdram/cpu_cache_new.v) with a DDR3
// backend; see rtl/ddr3/ddr3_fastram.v.  The CPU port is wired exactly like
// the SDRAM's, except that the address comes straight from the CPU
// (identity map, design.md D6) instead of through the SDRAM remap, and the
// chip select is the DDR3 one.
generate
if (haveddr3) begin : g_ddr3_fastram

ddr3_fastram ddr3_fastram_i (
    .sysclk         (CLK_114          ),
    .reset_in       (sdctl_rst        ),
    .cache_rst      (tg68_rst         ),
    .cacheline_clr  (cacheline_clr    ),
    .cpu_cache_ctrl (tg68_CACR_out    ),
    .ddr_ready      (tg68_ddrready    ),

    // Amiga CPU
    .cpuAddr        (tg68_ddraddr[25:1]),
    .cpustate       (tg68_ddrcpustate ),
    .cpuU           (tg68_cuds        ),
    .cpuL           (tg68_clds        ),
    .cpuWR          (tg68_cin         ),
    .cpuRD          (tg68_ddrout      ),
    .cpuena         (tg68_ddrena      ),

    // DDR3 island, 100 MHz domain
    .clk_mem        (DDR3_CLK_MEM     ),
    .init_done      (DDR3_INIT_DONE   ),
    .req_valid      (DDR3_REQ_VALID   ),
    .req_wr         (DDR3_REQ_WR      ),
    .req_addr       (DDR3_REQ_ADDR    ),
    .req_wdata      (DDR3_REQ_WDATA   ),
    .req_accept     (DDR3_REQ_ACCEPT  ),
    .resp_valid     (DDR3_RESP_VALID  ),
    .resp_rdata     (DDR3_RESP_RDATA  ),

    // clk_114-side debug taps, see ila_fastram below
    .dbg_bstate       (ddr3_dbg_bstate       ),
    .dbg_cdc_ready    (ddr3_dbg_cdc_ready    ),
    .dbg_cdc_req      (ddr3_dbg_cdc_req      ),
    .dbg_cdc_done     (ddr3_dbg_cdc_done     ),
    .dbg_req_rd       (ddr3_dbg_req_rd       ),
    .dbg_req_be       (ddr3_dbg_req_be       ),
    .dbg_req_addr     (ddr3_dbg_req_addr     ),
    .dbg_req_wdata    (ddr3_dbg_req_wdata    ),
    .dbg_req_tgl      (ddr3_dbg_req_tgl      ),
    .dbg_resp_rdata   (ddr3_dbg_resp_rdata   ),
    .dbg_ack_tgl      (ddr3_dbg_ack_tgl      ),
    .dbg_sdr_read_req (ddr3_dbg_sdr_read_req ),
    .dbg_sdr_read_ack (ddr3_dbg_sdr_read_ack ),
    .dbg_sdr_dat_r    (ddr3_dbg_sdr_dat_r    ),
    .dbg_sdr_write_req(ddr3_dbg_sdr_write_req),
    .dbg_sdr_write_ack(ddr3_dbg_sdr_write_ack),
    .dbg_sdr_adr      (ddr3_dbg_sdr_adr      ),
    .dbg_sdr_dat_w    (ddr3_dbg_sdr_dat_w    ),
    .dbg_sdr_dqm_w    (ddr3_dbg_sdr_dqm_w    )
);

end
else begin : g_no_ddr3_fastram

assign tg68_ddrout    = 16'h0000;
assign tg68_ddrena    = 1'b0;
assign tg68_ddrready  = 1'b0;
assign DDR3_REQ_VALID = 1'b0;
assign DDR3_REQ_WR    = 16'h0000;
assign DDR3_REQ_ADDR  = 32'h00000000;
assign DDR3_REQ_WDATA = 128'd0;

end
endgenerate


////////////////////////////////////////
// DDR3 fast RAM ILA (debug builds)   //
////////////////////////////////////////
// tools/vivado/build_ila.tcl creates ila_fastram (depth 8192, storage
// qualification on) and sets the sources_1 generic DDR3_FASTRAM_ILA=1; every
// other build leaves the parameter at 0 and this block does not exist.
//
// Everything probed is a register in the CLK_114 domain -- the CPU port of
// ddr3_fastram and the clk_114 side of its CDC (ddr3_cdc.v exports the
// SYNCHRONISED ack toggle, never the island's own register).  So the ILA adds
// no clock-domain crossing of its own, which is the point: it must not
// perturb the thing it is measuring.
//
// probe0  cpuAddr[25:1]        probe12 dbg_resp_rdata[127:0]
// probe1  cpustate[6:0]        probe13 dbg_ack_tgl
// probe2  cpuU                 probe14 dbg_bstate[1:0]
// probe3  cpuL                 probe15 dbg_sdr_read_req
// probe4  cpuWR[15:0]          probe16 dbg_sdr_read_ack
// probe5  cpuRD[15:0]          probe17 dbg_sdr_dat_r[15:0]
// probe6  cpuena               probe18 dbg_sdr_write_req
// probe7  ddr_ready            probe19 dbg_sdr_write_ack
// probe8  dbg_req_rd           probe20 dbg_sdr_adr[25:1]
// probe9  dbg_req_be[15:0]     probe21 dbg_sdr_dat_w[31:0]
// probe10 dbg_req_addr[31:0]   probe22 dbg_sdr_dqm_w[3:0]
// probe11 dbg_req_wdata[127:0] probe23 {cdc_ready,cdc_req,cdc_done,req_tgl}
generate
if (haveddr3 && DDR3_FASTRAM_ILA) begin : g_ddr3_fastram_ila

wire [4-1:0] ddr3_dbg_cdc_state = {ddr3_dbg_cdc_ready, ddr3_dbg_cdc_req,
                                   ddr3_dbg_cdc_done,  ddr3_dbg_req_tgl};

ila_fastram ila_fastram_i (
    .clk     (CLK_114                ),
    .probe0  (tg68_ddraddr[25:1]     ),
    .probe1  (tg68_ddrcpustate       ),
    .probe2  (tg68_cuds              ),
    .probe3  (tg68_clds              ),
    .probe4  (tg68_cin               ),
    .probe5  (tg68_ddrout            ),
    .probe6  (tg68_ddrena            ),
    .probe7  (tg68_ddrready          ),
    .probe8  (ddr3_dbg_req_rd        ),
    .probe9  (ddr3_dbg_req_be        ),
    .probe10 (ddr3_dbg_req_addr      ),
    .probe11 (ddr3_dbg_req_wdata     ),
    .probe12 (ddr3_dbg_resp_rdata    ),
    .probe13 (ddr3_dbg_ack_tgl       ),
    .probe14 (ddr3_dbg_bstate        ),
    .probe15 (ddr3_dbg_sdr_read_req  ),
    .probe16 (ddr3_dbg_sdr_read_ack  ),
    .probe17 (ddr3_dbg_sdr_dat_r     ),
    .probe18 (ddr3_dbg_sdr_write_req ),
    .probe19 (ddr3_dbg_sdr_write_ack ),
    .probe20 (ddr3_dbg_sdr_adr       ),
    .probe21 (ddr3_dbg_sdr_dat_w     ),
    .probe22 (ddr3_dbg_sdr_dqm_w     ),
    .probe23 (ddr3_dbg_cdc_state     )
);

end
endgenerate


// multiplex spi_do, drive it from user_io if that's selected, drive
// it from minimig if it's selected and leave it open else (also
// to be able to monitor sd card data directly)

wire [8-1 : 0] SPI_CS;
wire SPI_DO;
wire SPI_DI;
wire SPI_SCK;
wire SPI_SS;
wire SPI_SS2;
wire SPI_SS3;
wire SPI_SS4;
wire CONF_DATA0;

//assign SPI_DO = (CONF_DATA0 == 1'b0)?user_io_sdo:
//    (((SPI_SS2 == 1'b0)|| (SPI_SS3 == 1'b0))?minimig_sdo:1'bZ);

assign SD_CLK = SPI_SCK;
assign SD_CS = SPI_CS[1];
assign SD_MOSI = SPI_DI;
assign SPI_SS4 = SPI_CS[6];
assign SPI_SS3 = SPI_CS[5];
assign SPI_SS2 = SPI_CS[4];
assign RTC_CS = SPI_CS[7];

// Keyboard-related signals

wire  [7:0] c64_translated_key;
wire  c64_translated_key_stb;
reg [7:0] kbd_mouse_data;
wire  kbd_reset_n;
reg kbd_mouse_stb;
reg kbd_mouse_stb_r;
reg clk7_en_d;

assign kbd_reset_n = AMIGA_RESET_N;

always @(posedge CLK_114) begin
    clk7_en_d<=clk7_en;
    if(clk7_en && !clk7_en_d) begin // Detect rising edge of clk7_en which is on clk28
        kbd_mouse_stb<=kbd_mouse_stb_r;
        kbd_mouse_stb_r<=1'b0;
    end
    if(c64_translated_key_stb || AMIGA_KEY_STB) begin
        // kbd_mouse_data <= c64_translated_key_stb ? c64_translated_key : AMIGA_KEY;
        kbd_mouse_data <= AMIGA_KEY;
        kbd_mouse_stb_r<=1'b1;
    end
end


//// minimig top ////
`ifdef HOSTONLY
assign SPI_DO=1'b1;
assign _ram_oe=1'b1;
assign _ram_we=1'b1;
`else

minimig #(
    .NTSC(1'b0),
    // The "leftover" third Zorro-III board is SDRAM scraps; it does not exist
    // once the Zorro-III fast RAM is on the DDR3 (design.md D8), so it must not
    // be autoconfigured either or the OS would add memory that is not there.
    .Z3RAM3((haveddr3 || Z3RAM3_FORCE_OFF) ? 1'b0 : 1'b1)
) minimig (
    //m68k pins
    .cpu_address  (tg68_adr[23:1]   ), // M68K address bus
    .cpu_data     (tg68_dat_in      ), // M68K data bus
    .cpu_data2    (tg68_dat_in2     ), // M68K data bus 2nd word
    .cpudata_in   (tg68_dat_out     ), // M68K data in
    ._cpu_ipl     (tg68_IPL         ), // M68K interrupt request
    ._cpu_as      (tg68_as          ), // M68K address strobe
    ._cpu_uds     (tg68_uds         ), // M68K upper data strobe
    ._cpu_lds     (tg68_lds         ), // M68K lower data strobe
    ._cpu_uds2    (tg68_uds2        ), // M68K upper data strobe 2nd word
    ._cpu_lds2    (tg68_lds2        ), // M68K lower data strobe 2nd word
    .cpu_r_w      (tg68_rw          ), // M68K read / write
    ._cpu_dtack   (tg68_dtack       ), // M68K data acknowledge
    ._cpu_reset   (tg68_rst         ), // M68K reset
    ._cpu_reset_in(tg68_nrst_out    ), // M68K reset out
    .cpu_vbr      (tg68_VBR_out     ), // M68K VBR
    .ovr          (tg68_ovr         ), // NMI override address decoding
    //sram pins
    .ram_data     (ram_data         ), // SRAM data bus
    .ramdata_in   (ramdata_in       ), // SRAM data bus in
    .ram_address  (ram_address[22:1]), // SRAM address bus
    ._ram_bhe     (_ram_bhe         ), // SRAM upper byte select
    ._ram_ble     (_ram_ble         ), // SRAM lower byte select
    ._ram_bhe2    (_ram_bhe2        ), // SRAM upper byte select 2nd word
    ._ram_ble2    (_ram_ble2        ), // SRAM lower byte select 2nd word
    ._ram_we      (_ram_we          ), // SRAM write enable
    ._ram_oe      (_ram_oe          ), // SRAM output enable
    .chip48       (chip48           ), // big chipram read
    //system  pins
    .rst_ext      (!RESET_N         ), // reset from ctrl block
    .rst_out      (                 ), // minimig reset status
    .clk          (CLK_28           ), // output clock c1 ( 28.687500MHz)
    .clk7_en      (clk7_en          ), // 7MHz clock enable
    .clk7n_en     (clk7n_en         ), // 7MHz negedge clock enable
    .c1           (c1               ), // clk28m clock domain signal synchronous with clk signal
    .c3           (c3               ), // clk28m clock domain signal synchronous with clk signal delayed by 90 degrees
    .cck          (cck              ), // colour clock output (3.54 MHz)
    .eclk         (eclk             ), // 0.709379 MHz clock enable output (clk domain pulse)
    //rs232 pins
    .rxd          (AMIGA_RX         ), // RS232 receive
    .txd          (AMIGA_TX         ), // RS232 send
    .cts          (AMIGA_CTS        ), // RS232 clear to send
    .rts          (AMIGA_RTS        ), // RS232 request to send
    //I/O
    ._joy1        (JOYA             ), // joystick 1 [fire7:fire,up,down,left,right] (default mouse port)
    ._joy2        (JOYB             ), // joystick 2 [fire7:fire,up,down,left,right] (default joystick port)
    ._joy3        (JOYC             ), // joystick 3 [fire7:fire,up,down,left,right]
    ._joy4        (JOYD             ), // joystick 4 [fire7:fire,up,down,left,right]
    .mouse_btn1   (1'b1             ), // mouse button 1
    .mouse_btn2   (1'b1             ), // mouse button 2
    //  .mouse_btn    (mouse_buttons    ),  // mouse buttons
    .mouse0_btn   (3'b000           ),
    .mouse1_btn   (3'b000           ),
    .kbd_reset_n  (kbd_reset_n),
    .kbd_mouse_data (kbd_mouse_data ), // mouse direction data, keycodes
    //  .kbd_mouse_type (kbd_mouse_type ),  // type of data
    .kbd_mouse_strobe (kbd_mouse_stb), // kbd/mouse data strobe
    .kms_level    (1'b0             ), // kms_level        ),
    ._15khz       (_15khz           ), // scandoubler disable
    .rtc          (rtc              ), // real-time clock
    .pwr_led      (LED_POWER        ), // power led
    .disk_led     (LED_DISK         ), // power led
    .msdat_i      (PS2_MDAT_I       ), // PS2 mouse data
    .msclk_i      (PS2_MCLK_I       ), // PS2 mouse clk
    .kbddat_i     (PS2_DAT_I        ), // PS2 keyboard data
    .kbdclk_i     (PS2_CLK_I        ), // PS2 keyboard clk
    .msdat_o      (PS2_MDAT_O       ), // PS2 mouse data
    .msclk_o      (PS2_MCLK_O       ), // PS2 mouse clk
    .kbddat_o     (PS2_DAT_O        ), // PS2 keyboard data
    .kbdclk_o     (PS2_CLK_O        ), // PS2 keyboard clk
    //host controller interface (SPI)
    ._scs         ( {SPI_SS4,SPI_SS3,SPI_SS2}  ), // SPI chip select spi_chipselect(6 downto 4),
    .direct_sdi   (SD_MISO          ), // SD Card direct in  SPI_SDO
    .sdi          (SPI_DI           ), // SPI data input
    .sdo          (SPI_DO           ), // SPI data output
    .sck          (SPI_SCK          ), // SPI clock
    //video
    .selcsync     (VGA_SELCS        ), // composite sync
    ._csync       (cs               ), // horizontal sync
    ._hsync       (hs               ), // horizontal sync
    .hsyncpol     (hsyncpol         ),
    ._vsync       (vs               ), // vertical sync
    .vsyncpol     (vsyncpol         ),
    .red          (red              ), // red
    .green        (green            ), // green
    .blue         (blue             ), // blue
    //audio
    .left         (                 ), // audio bitstream left
    .right        (                 ), // audio bitstream right
    .ldata        (aud_amiga_left   ), // left DAC data
    .rdata        (aud_amiga_right  ), // right DAC data
    //user i/o
    .cpu_config   (cpu_config       ), // CPU config
    .board_configured(board_configured),
    .turbochipram (turbochipram     ), // turbo chipRAM
    .turbokick    (turbokick        ), // turbo kickstart
    .slow_config  (slow_config      ),
    .aga          (aga              ),
    .init_b       (                 ), // vertical sync for MCU (sync OSD update)
    .fifo_full    (                 ),
    // RTC SPI
    .rtc_int_n    (RTC_INT_N        ), //
    .rtc_spi_ce   (RTC_SPI_CE       ), //
    .rtc_spi_clk  (RTC_SPI_CLK      ), //
    .rtc_spi_cmd  (RTC_SPI_CMD      ), //
    .rtc_spi_data0(RTC_SPI_DATA0    ),
    .rtc_clkout   (RTC_CLKOUT       ),
    // fifo / track display
    .trackdisp    (                 ), // floppy track number
    .secdisp      (                 ), // sector
    .floppy_fwr   (floppy_fwr       ), // floppy fifo writing
    .floppy_frd   (floppy_frd       ), // floppy fifo reading
    .hd_fwr       (hd_fwr           ), // hd fifo writing
    .hd_frd       (hd_frd           ), // hd fifo reading
    .hblank_out   (hblank_out       ),
    .vblank_out   (vblank_out       ),
    .osd_blank_out(osd_window       ), // Let the toplevel dither module handle drawing the OSD.
    .osd_pixel_out(osd_pixel        ),
    .rtg_ena      (rtg_ena_mm       ),
    .ext_int2     (1'b0             ),
    .ext_int6     (aud_int          ),
    .ram_64meg    (ram_64meg        )
);

assign rtg_ena = havertg && rtg_ena_mm;
assign RTG_ENABLE = rtg_ena;

`endif

wire host_interrupt;

EightThirtyTwo_Bridge #( debug ? 1'b1 : 1'b0) hostcpu
(
    .clk(CLK_114),
    .nReset(reset_out), // (nReset)
    .addr(hostaddr), // Address bus (addr)
    .q(hostWR), // Data out (hostWR)
    .sel(hostbytesel), // Byte select ah (0, 0, nUDS, nLDS)
    .wr(host_we), // Write enable ah (data_write)

    // To CFIDE Floppy hardware emulation
    .hw_d(host_hwdata), // Hardware data in (hostData switched via cfide)
    .hw_req(host_hwreq), // Hardware request (hw_select <= cpu_addr(23))
    .hw_ack(host_hwack), // Hardware acknowledge (clkena_in)

    // To SDRAM
    .ram_d(host_ramdata), // ram in from SDRAM  (hostData)
    .ram_req(host_ramreq), // Ram request (To SDRAM when ram request)
    .ram_ack(host_ramack), // Ram acknowledge (clkena_in)

    .interrupt(host_interrupt) // TODO find out
);


cfide #(
    .spimux(spimux ? 1'b1 : 1'b0),
    .havespirtc(havespirtc ? 1'b1 : 1'b0),
    .havei2c(havei2c ? 1'b1 : 1'b0),
    .havevpos(havevpos ? 1'b1 : 1'b0)
) mycfide (
    .sysclk(CLK_114),
    .n_reset(reset_out),

    .addr(hostaddr),
    .d(hostWR[15:0]),
    .req(host_hwreq),
    .wr(host_we),
    .ack(host_hwack),
    .q(host_hwdata),

    .sd_di(SPI_DO),
    .sd_cs(SPI_CS),
    .sd_clk(SPI_SCK),
    .sd_do(SPI_DI),
    .sd_dimm(SD_MISO),
    .sd_ack(SD_ACK),

    .debugTxD(CTRL_TX),
    .debugRxD(CTRL_RX),
    .menu_button(MENU_BUTTON),
    .scandoubler(_15khz),

    .audio_ena(aud_ena_host),
    .audio_clear(aud_clear),
    .audio_buf(aud_addr[15]),
    .audio_amiga(aud_ena_cpu),
    .vbl_int(vblank_out),
    .interrupt(host_interrupt),

    .amiga_addr(tg68_cad[8:1]),
    .amiga_d(tg68_cin),
    .amiga_q(amigahost_q),
    .amiga_req(amigahost_req),
    .amiga_wr(tg68_cpustate[0]),
    .amiga_ack(amigahost_ack),

    .rtc_q(rtc),
// .c64_keys(C64_KEYS),
// .amiga_key(c64_translated_key),
// .amiga_key_stb(c64_translated_key_stb),

`ifdef MINIMIG_I2C_BUS
    // I2C interface
    .scl_i(SCL_I),
    .scl_o(SCL_O),
    .scl_t(SCL_T),
    .sda_i(SDA_I),
    .sda_o(SDA_O),
    .sda_t(SDA_T),
`endif

`ifdef MINIMIG_VPOS
    // Video v and h offset
    .pos_data_q(VPOS_DATA),
`endif

    .clk_28(CLK_28),
    .tick_in(aud_tick)
);

AudioMix myaudiomix
(
    .clk(CLK_28),
    .reset_n(reset_out),
    .audio_in_l1(aud_amiga_left),
    .audio_in_l2(aud_left),
    .audio_in_r1(aud_amiga_right),
    .audio_in_r2(aud_right),
    .audio_l(AUDIO_L),
    .audio_r(AUDIO_R)
);


endmodule

