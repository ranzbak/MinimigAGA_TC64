//on screen display controller


module userio_osd #(
	// What this core is, for a firmware new enough to ask.  Bit 0 AP68040
	// fitted, bit 1 AP68040 selectable (a dual-core build), bit 2 FPU,
	// bit 3 MMU.  Read back as byte 5 of OSD_CMD_VERSION, behind the magic
	// byte 4; see findings/ap68040/plan-v2-with-ddr3.md, "OSD and firmware".
	// The OSD's picture is the 720p text layer (rtl/openaars/adv7511/osd_text.v)
	// on osd_txt; VERSION bytes 10-13 say so (0xB5, 2, 64, 32) and byte 14
	// is the status {7'd0, rtg_ena}.  The bitmap OSD that was here (osdbuf,
	// its beam counters and video output, the 0x0C write) went in OSD
	// redesign Phase 6; the last commit with it is osd-int bc677a44.
	parameter [7:0] CORE_CAPS = 8'h00
)
(
	input 	clk,		    	// 28MHz clock
	input	clk7_en,
  input clk7n_en,
	input	reset,				//reset
	input	rtg_ena,			//the RTG screen is on (VERSION byte 14)
	input	[7:0] osd_ctrl,		//keycode for OSD control (Amiga keyboard codes + additional keys coded as values > 80h)
	input	[31:0] in_diag,		//input-path diagnostic: bytes 6-9 of OSD_CMD_VERSION (see userio.v)
	output	reg in_diag_clr = 1'b0,	//one clk7 pulse after byte 9 was read: clear the sticky bits
	input	_scs,				//SPI enable
	input	sdi,		  		//SPI data in
	output	sdo,	 			//SPI data out
	input	sck,	  			//SPI clock
	// Reply sequence: +1 (mod 4) at the clk7 edge that takes each byte received
	// under _scs, so once it has caught up with the host's own byte count the
	// reply to the next byte is already in place.  No reset, initial value
	// only: the host compares increments, never the absolute value.  See
	// "reply sequence" below and findings/osd-riscv/phase4.md "Handshake design".
	output	reg [1:0] osd_rx_seq = 2'd0,
	// The OSD text layer's write side (commands 0x2C/0x3C/0x4C/0x5C below),
	// clk domain, every field registered; layout in "OSD text layer".
	output	wire [106:0] osd_txt,
  output  reg key_disable = 0,      // keyboard disable (the keys to the OSD)
	// bit 7 is "fast RAM: DDR3 board only" -- see minimig_autoconfig.v.  It is
	// applied under reset with the rest of the memory map, because changing
	// which boards autoconfig offers cannot take effect mid-session.
	output	reg [8-1:0] memory_config = 8'b0_0_00_01_01,
	output	reg [4:0] chipset_config = 0,
	output	reg [3:0] floppy_config = 0,
	output	reg [1:0] scanline = 0,
  output  reg [1:0] dither = 0,
  // HDMI CRT emulation {scaling[1:0], beam[1:0], bloom[1:0], mask[1:0]}:
  // the video config's second data byte.  A firmware that sends one byte
  // leaves them 0 (off; scaling 0 = line rate, the picture of before).
  output  reg [7:0] crt_fx = 0,
  output    reg    [4:0] ide_config0 = 0,        //IDE port 1: {slave ATAPI, master ATAPI, slave, master, port on}
  output    reg    [4:0] ide_config1 = 0,        //IDE port 2: same layout (command 0x58)
  output  reg [4:0] cpu_config = 0,   // [4] Chip slots Fast (findings/fastslot)
  output  reg [1:0] autofire_config = 0,
  output  reg       cd32pad = 0,
	output	reg usrrst=1'b0,
  output reg cpurst=1'b1,
  output reg cpuhlt=1'b1,
  output wire fifo_full,
  // host
  output reg            host_cs,
  output wire [ 24-1:0] host_adr,
  output reg            host_we,
  output reg  [  2-1:0] host_bs,
  output wire [ 16-1:0] host_wdat,
  input  wire [ 16-1:0] host_rdat,
  input  wire           host_ack
);


//local signals
wire	[7:0] wrdat;			//SPI data byte received

reg   [8-1:0] t_memory_config = 8'b0_0_00_01_01;
reg   [4:0] t_ide_config0 = 0;
reg   [4:0] t_ide_config1 = 0;
reg   [4:0] t_cpu_config = 0;
reg   [4:0] t_chipset_config = 0;


//--------------------------------------------------------------------------------------
// memory configuration select signal
//--------------------------------------------------------------------------------------

// configuration changes only while reset is active
always @(posedge clk)
  if (clk7_en) begin
    if (reset)
    begin
      chipset_config <= t_chipset_config;
      ide_config0 <= t_ide_config0;
      ide_config1 <= t_ide_config1;
      cpu_config[1:0] <= t_cpu_config[1:0];
      memory_config[5:0] <= t_memory_config[5:0];
      memory_config[7]   <= t_memory_config[7];
    end
// Temporarily update memory configuration immediately.
//	 memory_config[5:0] <= t_memory_config[5:0];
  end


always @(posedge clk) begin
  if (clk7_en) begin
    cpu_config[4:2] <= t_cpu_config[4:2];   // Turbo and Chip slots: live, like Turbo always was
    memory_config[6] <= #1 t_memory_config[6];
  end
end



//--------------------------------------------------------------------------------------
//interface to host
//--------------------------------------------------------------------------------------
wire	rx;
wire	cmd;
reg   wrcmd;    // spi write command
wire  vld;
reg   vld_d;
wire  spi_invalidate;
wire [7:0] rddat;

//instantiate spi interface
userio_osd_spi spi0
(
	.clk(clk),
  .clk7_en(clk7_en),
  .clk7n_en(clk7n_en),
	._scs(_scs),
	.sdi(sdi),
	.sdo(sdo),
	.sck(sck),
	.in(rddat),
	.out(wrdat),
	.rx(rx),
	.cmd(cmd),
  .vld(vld)
);

always @ (posedge clk) begin
  if (clk7_en) begin
    vld_d <= #1 vld;
  end
end
assign spi_invalidate = ~vld && vld_d;

// reply sequence: the same clk7 edge at which cmd_dat, dat_cnt, ver_cnt and
// kq_rptr take the byte (rx is high for exactly one clk7 period per byte)
always @ (posedge clk) begin
  if (clk7_en) begin
    if (rx) osd_rx_seq <= #1 osd_rx_seq + 2'd1;
  end
end

// !!! OLD !!! OSD SPI commands:
 // 8'b00000000  NOP
 // 8'b001H0NNN  write data to osd buffer line <NNN> (H - highlight)
 // 8'b0100--KE  enable OSD display (E) and disable Amiga keyboard (K)
 // 8'b1000000B  reset Minimig (B - reset to bootloader)
 // 8'b100001AA  set autofire rate
 // 8'b1001---S  set cpu speed
 // 8'b1010--SS  set scanline mode
 // 8'b1011-SMC  set hard disk config (C - enable HDC, M - enable Master HDD, S - enable Slave HDD)
 // 8'b1100FF-S  set floppy speed and drive number
 // 8'b1101-EAN  set chipset features (N - ntsc, A - OCS A1000, E - ECS)
 // 8'b1110HHLL  set interpolation filter (H - Hires, L - Lores)
 // 8'b111100CC  set memory configuration (S - Slow, C - Chip, F - Fast)
 // 8'b111101SS  set memory configuration (S - Slow, C - Chip, F - Fast)
 // 8'b111110FF  set memory configuration (S - Slow, C - Chip, F - Fast)
 // 8'b111111TT  set cpu type TT=00-68000, 01-68010, 11-68020


// OSD SPI commands
//
// 8'b0_000_0000 NOP
// write regs
// 8'b0_000_1000 | XXXXXRBC || reset control   | R - reset, B - reset to bootloader, C - reset control block
// 8'b0_001_1000 | XXXXXXXX || clock control   | unused
// 8'b0_010_1000 | XXXXXXK0 || osd control     | K - disable Amiga keyboard (the keys to the OSD); bit 0 was E, the bitmap OSD's enable (gone, Phase 6)
// 8'b0_000_0100 | XXXXEANT || chipset config  | E - ECS, A - OCS A1000, N - NTSC, T - turbo
// 8'b0_001_0100 | XXXXXSTT || cpu config      | S - CPU speed, TT - CPU type (00=68k, 01=68k10, 10=68k20)
// 8'b0_010_0100 | XXFFSSCC || memory config   | FF - fast, CC - chip, SS - slow
// 8'b0_011_0100 | XXrrrrSS || video config    | rrrr - reserved (were HHLL, the interp. filters; ignored), SS - scanline mode
// 8'b0_100_0100 | XXXXXFFS || floppy config   | FF - drive number, S - floppy speed
// 8'b0_101_0100 | XXXBASMC || harddisk config | B/A - slave/master is ATAPI, S - enable slave HDD, M - enable master HDD, C - enable HDD controler
// 8'b0_101_1000 | XXXBASMC || harddisk config, IDE port 2 (same layout)
// 8'b0_110_0100 | XXXXXXAA || joystick config | AA - autofire rate
// (8'b0_000_1100 was the bitmap OSD buffer write: gone with the bitmap OSD, Phase 6; the text layer is 0x2C..0x5C below)
// 8'b0_001_1100 | A_A_A_A B,B,... || write system memory, A - 32 bit memory address, B - variable number of bytes
// 8'b1_000_1000 read RTL version


// commands
localparam [5:0]
  SPI_RESET_CTRL_ADR   = 6'b0_000_10,
  SPI_CLOCK_CTRL_ADR   = 6'b0_001_10,
  SPI_OSD_CTRL_ADR     = 6'b0_010_10,
  SPI_CHIP_CFG_ADR     = 6'b0_000_01,
  SPI_CPU_CFG_ADR      = 6'b0_001_01,
  SPI_MEMORY_CFG_ADR   = 6'b0_010_01,
  SPI_VIDEO_CFG_ADR    = 6'b0_011_01,
  SPI_FLOPPY_CFG_ADR   = 6'b0_100_01,
  SPI_HARDDISK0_CFG_ADR= 6'b0_101_01,
  SPI_HARDDISK1_CFG_ADR= 6'b0_101_10,
  SPI_JOYSTICK_CFG_ADR = 6'b0_110_01,
  SPI_MEM_WRITE_ADR    = 6'b0_001_11,
  SPI_VERSION_ADR      = 6'b1_000_10,
  // The OSD key-event QUEUE (command byte 0x98).  OSD_CMD_READ (osd_ctrl) is a
  // LEVEL: the firmware polls it and calls a change an event, so an event that
  // begins and ends between two polls is never seen.  A missed key-UP is the
  // expensive one -- menu.c keeps ctrl/lalt in statics, and a stuck modifier
  // makes F12 toggle debug mode instead of opening the OSD, for good.  This
  // queue keeps every event until it is read.
  SPI_KEYQ_ADR         = 6'b1_001_10,
  SPI_MEM_READ_ADR     = 6'b1_001_11;


// get command
reg [5:0] cmd_dat = 6'h00;
always @ (posedge clk) begin
  if (clk7_en) begin
    if (rx && cmd) cmd_dat <= #1 wrdat[7:2];
    //else if (spi_invalidate) cmd_dat <= #1 8'h00; // TODO!
  end
end


// data byte counter
reg [2:0] dat_cnt = 3'h0;
always @ (posedge clk) begin
  if (clk7_en) begin
    if (rx && cmd)
      dat_cnt <= #1 3'h0;
    else if (rx && (dat_cnt != 4))
      dat_cnt <= #1 dat_cnt + 3'h1;
  end
end


// reg selects
reg spi_reset_ctrl_sel    = 1'b0;
reg spi_clock_ctrl_sel    = 1'b0;
reg spi_osd_ctrl_sel      = 1'b0;
reg spi_chip_cfg_sel      = 1'b0;
reg spi_cpu_cfg_sel       = 1'b0;
reg spi_memory_cfg_sel    = 1'b0;
reg spi_video_cfg_sel     = 1'b0;
reg spi_floppy_cfg_sel    = 1'b0;
reg spi_harddisk0_cfg_sel = 1'b0;
reg spi_harddisk1_cfg_sel = 1'b0;
reg spi_joystick_cfg_sel  = 1'b0;
reg spi_mem_write_sel     = 1'b0;
reg spi_version_sel       = 1'b0;
reg spi_mem_read_sel      = 1'b0;
reg spi_keyq_sel          = 1'b0;
always @ (*) begin
  spi_reset_ctrl_sel   = 1'b0;
  spi_clock_ctrl_sel   = 1'b0;
  spi_osd_ctrl_sel     = 1'b0;
  spi_chip_cfg_sel     = 1'b0;
  spi_cpu_cfg_sel      = 1'b0;
  spi_memory_cfg_sel   = 1'b0;
  spi_video_cfg_sel    = 1'b0;
  spi_floppy_cfg_sel   = 1'b0;
  spi_harddisk0_cfg_sel= 1'b0;
  spi_harddisk1_cfg_sel= 1'b0;
  spi_joystick_cfg_sel = 1'b0;
  spi_mem_write_sel    = 1'b0;
  spi_version_sel      = 1'b0;
  spi_mem_read_sel     = 1'b0;
  spi_keyq_sel         = 1'b0;
  case (cmd_dat)
    SPI_RESET_CTRL_ADR   : spi_reset_ctrl_sel   = 1'b1;
    SPI_CLOCK_CTRL_ADR   : spi_clock_ctrl_sel   = 1'b1;
    SPI_OSD_CTRL_ADR     : spi_osd_ctrl_sel     = 1'b1;
    SPI_CHIP_CFG_ADR     : spi_chip_cfg_sel     = 1'b1;
    SPI_CPU_CFG_ADR      : spi_cpu_cfg_sel      = 1'b1;
    SPI_MEMORY_CFG_ADR   : spi_memory_cfg_sel   = 1'b1;
    SPI_VIDEO_CFG_ADR    : spi_video_cfg_sel    = 1'b1;
    SPI_FLOPPY_CFG_ADR   : spi_floppy_cfg_sel   = 1'b1;
    SPI_HARDDISK0_CFG_ADR: spi_harddisk0_cfg_sel= 1'b1;
    SPI_HARDDISK1_CFG_ADR: spi_harddisk1_cfg_sel= 1'b1;
    SPI_JOYSTICK_CFG_ADR : spi_joystick_cfg_sel = 1'b1;
    SPI_MEM_WRITE_ADR    : spi_mem_write_sel    = 1'b1;
    SPI_VERSION_ADR      : spi_version_sel      = 1'b1;
    SPI_KEYQ_ADR         : spi_keyq_sel         = 1'b1;
    SPI_MEM_READ_ADR     : spi_mem_read_sel     = 1'b1;
    default: begin
      spi_reset_ctrl_sel   = 1'b0;
      spi_clock_ctrl_sel   = 1'b0;
      spi_osd_ctrl_sel     = 1'b0;
      spi_chip_cfg_sel     = 1'b0;
      spi_cpu_cfg_sel      = 1'b0;
      spi_memory_cfg_sel   = 1'b0;
      spi_video_cfg_sel    = 1'b0;
      spi_floppy_cfg_sel   = 1'b0;
      spi_harddisk0_cfg_sel= 1'b0;
      spi_harddisk1_cfg_sel= 1'b0;
      spi_joystick_cfg_sel = 1'b0;
          spi_mem_write_sel    = 1'b0;
      spi_version_sel      = 1'b0;
      spi_mem_read_sel     = 1'b0;
      spi_keyq_sel         = 1'b0;
    end
  endcase
end

// 8'b0_000_1000 | XXXXHRBC || reset control   | H - CPU halt, R - reset, B - reset to bootloader, C - reset control block
// 8'b0_001_1000 | XXXXXXXX || clock control   | unused
// 8'b0_010_1000 | XXXXXXK0 || osd control     | K - disable Amiga keyboard (the keys to the OSD); bit 0 was E, the bitmap OSD's enable (gone, Phase 6)
// 8'b0_000_0100 | XXXGEANT || chipset config  | G - AGA, E - ECS, A - OCS A1000, N - NTSC, T - turbo
// 8'b0_001_0100 | XXXXKCTT || cpu config      | K - fast kickstart enable, C - CPU cache enable, TT - CPU type (00=68k, 01=68k10, 10=68k20)
// 8'b0_010_0100 | XHFFSSCC || memory config   | H - HRTmon, FF - fast, SS - slow, CC - chip
// 8'b0_011_0100 | DDrrrrSS || video config    | DD - dither, rrrr - reserved (were HH LL, the hires / lowres interp.
//                |          ||                 | filters, removed 2026-10-26; ignored, firmware sends 0), SS - scanline mode
//               | XXWWBBMM    (optional second byte) WW - HDMI beam width (0 off, 1 sharp, 2 medium, 3 soft), BB - HDMI bloom (0 off, 1 low, 2 high), MM - HDMI CRT mask (0 off, 1 grille, 2 grille strong, 3 shadow)
// 8'b0_100_0100 | XXXXXFFS || floppy config   | FF - drive number, S - floppy speed
// 8'b0_101_0100 | XXXXXSMC || harddisk config | S - enable slave HDD, M - enable master HDD, C - enable HDD controler
// 8'b0_110_0100 | XXXXXCAA || joystick config | C - CD32pad mode, AA - autofire rate
// (8'b0_000_1100 was the bitmap OSD buffer write: gone with the bitmap OSD, Phase 6; the text layer is 0x2C..0x5C below)
// 8'b0_001_1100 | A_A_A_A B,B,... || write system memory, A - 32 bit memory address, B - variable number of bytes
// 8'b1_000_1000 read RTL version


// write regs
always @ (posedge clk) begin
  if (clk7_en) begin
    if (rx && !cmd) begin
      if (spi_reset_ctrl_sel)   begin if (dat_cnt == 0) {cpuhlt, cpurst, usrrst} <= #1 wrdat[2:0]; end
  //    if (spi_clock_ctrl_sel)   begin if (dat_cnt == 0) end
      if (spi_osd_ctrl_sel)     begin if (dat_cnt == 0) key_disable <= #1 wrdat[1]; end
      if (spi_chip_cfg_sel)     begin if (dat_cnt == 0) t_chipset_config <= #1 wrdat[4:0]; end
      if (spi_cpu_cfg_sel)      begin if (dat_cnt == 0) t_cpu_config <= #1 wrdat[4:0]; end
      if (spi_memory_cfg_sel)   begin if (dat_cnt == 0) t_memory_config <= #1 wrdat[7:0]; end
      if (spi_video_cfg_sel)    begin if (dat_cnt == 0) {dither, scanline} <= #1 {wrdat[7:6], wrdat[1:0]};
                                      if (dat_cnt == 1) crt_fx <= #1 wrdat[7:0]; end
      if (spi_floppy_cfg_sel)   begin if (dat_cnt == 0) floppy_config <= #1 wrdat[3:0]; end
      if (spi_harddisk0_cfg_sel)begin if (dat_cnt == 0) t_ide_config0 <= #1 wrdat[4:0]; end
      if (spi_harddisk1_cfg_sel)begin if (dat_cnt == 0) t_ide_config1 <= #1 wrdat[4:0]; end
      if (spi_joystick_cfg_sel) begin if (dat_cnt == 0) {cd32pad, autofire_config} <= #1 wrdat[2:0]; end
      //if (spi_joystick_cfg_sel) begin if (dat_cnt == 0) {autofire_config} <= #1 wrdat[1:0]; end
  //    if (spi_mem_write_sel)    begin if (dat_cnt == 0) end
  //    if (spi_version_sel)      begin if (dat_cnt == 0) end
  //    if (spi_mem_read_sel)     begin if (dat_cnt == 0) end
    end
  end
end


//// resets - temporary TODO!
//assign usrrst  = rx && !cmd && spi_reset_ctrl_sel && (dat_cnt == 0);
//assign bootrst = rx && !cmd && spi_reset_ctrl_sel && wrdat[0] && (dat_cnt == 0);


`ifdef MINIMIG_HOST_DIRECT  // Does the host CPU have direct access to the Minimig's memory?

always @(*) begin
	host_cs = 1'b0;
	host_we = 1'b0;
	host_bs = 2'b00;
end

`else

// memory write
reg mem_toggle = 1'b0, mem_toggle_d = 1'b0;
always @ (posedge clk) begin
  if (clk7_en) begin
    if (cmd) begin
      mem_toggle <= #1 1'b0;
      mem_toggle_d <= #1 1'b0;
    end else if (rx && !cmd && spi_mem_write_sel && (dat_cnt == 4)) begin
      mem_toggle <= #1 ~mem_toggle;
      mem_toggle_d <= #1 mem_toggle;
    end
  end
end

reg  [ 8-1:0] mem_dat_r;
always @ (posedge clk) begin
  if (clk7_en) begin
    if (rx && !cmd && spi_mem_write_sel && !mem_toggle) mem_dat_r <= #1 wrdat[7:0];
  end
end

wire wr_fifo_empty;
wire wr_fifo_full;
assign fifo_full = wr_fifo_full;
reg  wr_fifo_rd_en;
sync_fifo #(
  .FD (4),
  .DW (16)
) wr_fifo (
  .clk          (clk),
  .clk7_en      (clk7_en),
  .rst          (reset/* || cmd*/), // TODO possible problem (cmd)!
  .fifo_in      ({mem_dat_r, wrdat}),
  .fifo_out     (host_wdat),
  .fifo_wr_en   (rx && !cmd && mem_toggle),
  .fifo_rd_en   (wr_fifo_rd_en),
  .fifo_full    (wr_fifo_full),
  .fifo_empty   (wr_fifo_empty)
);

reg  [2-1:0] wr_state = 2'b00;
localparam ST_WR_IDLE = 2'b00;
localparam ST_WR_WRITE = 2'b10;
localparam ST_WR_WAIT = 2'b11;

always @ (posedge clk) begin
  if (clk7_en) begin
    if (reset || cmd)
      wr_state <= #1 ST_WR_IDLE;
    else begin
      case (wr_state)
        ST_WR_IDLE: begin
          wr_fifo_rd_en <= #1 1'b0;
          host_cs <= #1 1'b0;
          host_we <= #1 1'b0;
          host_bs <= #1 2'b00;
          wr_fifo_rd_en <= #1 1'b0;
          if (!wr_fifo_empty && !wr_fifo_rd_en) wr_state <= #1 ST_WR_WRITE;
        end
        ST_WR_WRITE: begin
          host_cs <= #1 1'b1;
          host_we <= #1 1'b1;
          host_bs <= #1 2'b11;
          if (host_ack) begin
            wr_fifo_rd_en <= #1 1'b1;
            wr_state <= #1 ST_WR_IDLE;
          end
        end
        ST_WR_WAIT: begin
          host_cs <= #1 1'b0;
          host_we <= #1 1'b0;
          host_bs <= #1 2'b00;
          wr_state <= #1 ST_WR_IDLE;
          wr_fifo_rd_en <= #1 1'b0;
        end
      endcase
    end
  end
end

reg  [ 8-1:0] mem_page;
reg  [24-1:0] mem_cnt;
wire [32-1:0] mem_adr;
always @ (posedge clk) begin
  if (clk7_en) begin
    if (rx && !cmd && spi_mem_write_sel) begin
      case (dat_cnt)
        0 : mem_cnt [ 7: 0] <= #1 wrdat[7:0];
        1 : mem_cnt [15: 8] <= #1 wrdat[7:0];
        2 : mem_cnt [23:16] <= #1 wrdat[7:0];
        3 : mem_page[ 7: 0] <= #1 wrdat[7:0];
      endcase
    end else if (wr_fifo_rd_en) mem_cnt [23:0] <= #1 mem_cnt + 24'd2;
  end
end

assign mem_adr = {mem_page, mem_cnt};
assign host_adr  = mem_adr[23:0];

`endif // MINIMIG_HOST_DIRECT

//----------------------------------------------------------------------------
// OSD text layer (findings/osd-redesign/plan.md 4.1): the write side of the
// 720p text layer osd_text.v, which sits in the HDMI chain (clk_148) and
// takes these registers on its own write port (clk).
//
//   0x2C TXT_WR   d0 mode (0 char,attr pairs; 1 chars only; 2 attrs only;
//                 3 writes nothing), d1 cell[10:8], d2 cell[7:0], d3..
//                 data: one cell per pair (written at its second byte, both
//                 lanes) or per byte (one lane); the cell +1 each, mod 2048
//   0x3C FONT_WR  d0 adr[11:8], d1 adr[7:0], d2.. bytes, adr +1 each
//   0x4C PAL_WR   d0 the first entry (0..15), then 4 bytes per entry {mode
//                 in bits 7:6, r, g, b} into the layer's staging palette
//   0x5C TXT_CFG  d0..d4 = txt_cfg bytes 0..4 {ctrl (bit 0 enable, bit 1
//                 scale 2), x0/8, y0/8, cols, rows}; the 5th byte toggles
//                 txt_commit (the layer copies palette and cfg at its next
//                 frame); bytes after the 5th are ignored
// dat_cnt stops at 4, so the streams run on their own "on" flags (set by
// the last header byte) and TXT_CFG on its own count.
// The write enables are one clk pulse at the clk7 edge that takes the byte.
// osd_txt = {txt_commit, txt_cfg[39:0], pal_we, pal_adr[5:0], pal_dat[7:0],
//            font_we, font_adr[11:0], font_dat[7:0],
//            txt_we, txt_lane[1:0], txt_adr[10:0], txt_dat[15:0]}
// (107 bits; pal_to_ddr.sv unpacks it).  Lane 0 = char [7:0], 1 = attr [15:8].
//----------------------------------------------------------------------------
localparam [5:0]
  SPI_TXT_WR_ADR  = 6'b0_010_11,   // 0x2C
  SPI_FONT_WR_ADR = 6'b0_011_11,   // 0x3C
  SPI_PAL_WR_ADR  = 6'b0_100_11,   // 0x4C
  SPI_TXT_CFG_ADR = 6'b0_101_11;   // 0x5C
wire spi_txt_wr_sel  = (cmd_dat == SPI_TXT_WR_ADR);
wire spi_font_wr_sel = (cmd_dat == SPI_FONT_WR_ADR);
wire spi_pal_wr_sel  = (cmd_dat == SPI_PAL_WR_ADR);
wire spi_txt_cfg_sel = (cmd_dat == SPI_TXT_CFG_ADR);

reg        txt_we = 1'b0, font_we = 1'b0, pal_we = 1'b0, txt_commit = 1'b0;
reg [1:0]  txt_lane = 2'b00;
reg [10:0] txt_adr = 11'd0;
reg [15:0] txt_dat = 16'd0;
reg [11:0] font_adr = 12'd0;
reg [7:0]  font_dat = 8'd0;
reg [5:0]  pal_adr = 6'd0;
reg [7:0]  pal_dat = 8'd0;
reg [39:0] txt_cfg = 40'd0;
// stream state
reg        txt_on = 1'b0, txt_ph = 1'b0, font_on = 1'b0, pal_on = 1'b0;
reg [1:0]  txt_mode = 2'd0;
reg [10:0] txt_ptr = 11'd0;
reg [7:0]  txt_chr = 8'd0;
reg [11:0] font_ptr = 12'd0;
reg [5:0]  pal_ptr = 6'd0;
reg [2:0]  cfg_cnt = 3'd0;

always @(posedge clk) begin
  txt_we  <= 1'b0;
  font_we <= 1'b0;
  pal_we  <= 1'b0;
  if (clk7_en) begin
    if (rx && cmd) begin
      txt_on  <= 1'b0;
      txt_ph  <= 1'b0;
      font_on <= 1'b0;
      pal_on  <= 1'b0;
      cfg_cnt <= 3'd0;
    end else if (rx) begin
      // 0x2C
      if (spi_txt_wr_sel) begin
        if (txt_on) begin
          case (txt_mode)
            2'd0: if (!txt_ph) begin
                    txt_chr <= wrdat;
                    txt_ph  <= 1'b1;
                  end else begin
                    txt_we   <= 1'b1;
                    txt_lane <= 2'b11;
                    txt_adr  <= txt_ptr;
                    txt_dat  <= {wrdat, txt_chr};
                    txt_ptr  <= txt_ptr + 11'd1;
                    txt_ph   <= 1'b0;
                  end
            2'd1: begin
                    txt_we   <= 1'b1;
                    txt_lane <= 2'b01;
                    txt_adr  <= txt_ptr;
                    txt_dat  <= {8'h00, wrdat};
                    txt_ptr  <= txt_ptr + 11'd1;
                  end
            2'd2: begin
                    txt_we   <= 1'b1;
                    txt_lane <= 2'b10;
                    txt_adr  <= txt_ptr;
                    txt_dat  <= {wrdat, 8'h00};
                    txt_ptr  <= txt_ptr + 11'd1;
                  end
            default: ;
          endcase
        end else begin
          if (dat_cnt == 3'd0) txt_mode <= wrdat[1:0];
          if (dat_cnt == 3'd1) txt_ptr[10:8] <= wrdat[2:0];
          if (dat_cnt == 3'd2) begin
            txt_ptr[7:0] <= wrdat;
            txt_on <= 1'b1;
          end
        end
      end
      // 0x3C
      if (spi_font_wr_sel) begin
        if (font_on) begin
          font_we  <= 1'b1;
          font_adr <= font_ptr;
          font_dat <= wrdat;
          font_ptr <= font_ptr + 12'd1;
        end else begin
          if (dat_cnt == 3'd0) font_ptr[11:8] <= wrdat[3:0];
          if (dat_cnt == 3'd1) begin
            font_ptr[7:0] <= wrdat;
            font_on <= 1'b1;
          end
        end
      end
      // 0x4C
      if (spi_pal_wr_sel) begin
        if (pal_on) begin
          pal_we  <= 1'b1;
          pal_adr <= pal_ptr;
          pal_dat <= wrdat;
          pal_ptr <= pal_ptr + 6'd1;
        end else begin
          pal_ptr <= {wrdat[3:0], 2'b00};
          pal_on  <= 1'b1;
        end
      end
      // 0x5C
      if (spi_txt_cfg_sel && cfg_cnt != 3'd5) begin
        case (cfg_cnt)
          3'd0: txt_cfg[7:0]   <= wrdat;
          3'd1: txt_cfg[15:8]  <= wrdat;
          3'd2: txt_cfg[23:16] <= wrdat;
          3'd3: txt_cfg[31:24] <= wrdat;
          default: txt_cfg[39:32] <= wrdat;
        endcase
        cfg_cnt <= cfg_cnt + 3'd1;
`ifndef OSD_TXT_MUTANT_COMMIT
        if (cfg_cnt == 3'd4)
          txt_commit <= ~txt_commit;
`endif
      end
    end
  end
end

`ifdef OSD_TXT_MUTANT_LANE
// bench mutant (sim/hdmi_upsample/tb_osd_text_spi.v): char and attr lanes swapped
assign osd_txt = {txt_commit, txt_cfg, pal_we, pal_adr, pal_dat, font_we, font_adr, font_dat,
                  txt_we, txt_lane[0], txt_lane[1], txt_adr, txt_dat[7:0], txt_dat[15:8]};
`else
assign osd_txt = {txt_commit, txt_cfg, pal_we, pal_adr, pal_dat, font_we, font_adr, font_dat,
                  txt_we, txt_lane, txt_adr, txt_dat};
`endif

// rtl version
//`ifndef MINIMIG_XILINX
`include "minimig_version.vh"
//`endif
// Bytes 0-3 are the version and are untouched, so old firmware sees exactly
// what it saw before.  Bytes 4 and 5 are new: 4 is a magic value, 5 the core's
// capabilities.  An older core answers MINION_VER to both, so a firmware that
// does not find 0xA4 in byte 4 knows there is nothing here to read and must
// fall back to its old behaviour -- which is why the magic byte exists at all.
// dat_cnt STOPS at 4 -- the memory-write path relies on that, it is how a
// stream of bytes after the address keeps triggering at "dat_cnt == 4" -- so
// byte 5 of this reply could not be told apart from byte 4 and CORE_CAPS was
// unreachable: the firmware read the magic twice, took 0xA4 for the capability
// byte, found no AP040 bit in it and fell back to the old CPU menu, which is
// the "020 alpha" the OSD showed.  This counter belongs to the version reply
// alone and simply keeps counting.
// Bit 4 of the capability byte is this module's own to answer: the key queue
// below lives here, so this is what knows whether it is there.  Bits 0-3 come
// in from the top, which is what knows which CPU was built.  Bit 7 comes from
// minimig.v: the Gayle has two IDE ports with ATAPI packet mode.
localparam [7:0] CAPS_KEYQ = 8'h10;
// Bit 6: bytes 6-9 of this reply are the input-path diagnostic (in_diag, see
// userio.v) -- what the mouse, the joystick expander and the button lines
// into CIA-A / POTGOR are doing, read by the firmware's Chipset menu.  Reading
// byte 9 clears the sticky half (bytes 8 and 9).
localparam [7:0] CAPS_INDIAG = 8'h40;

reg  [3:0] ver_cnt = 4'h0;
always @ (posedge clk) begin
  if (clk7_en) begin
    in_diag_clr <= #1 1'b0;
    if (rx && cmd)
      ver_cnt <= #1 4'h0;
    else if (rx && (ver_cnt != 4'hf))
      ver_cnt <= #1 ver_cnt + 4'h1;
    if (rx && !cmd && spi_version_sel && (ver_cnt == 4'd9))
      in_diag_clr <= #1 1'b1;
  end
end

reg  [8-1:0] rtl_ver;
always @ (*) begin
  case (ver_cnt)
    4'd0    : rtl_ver = BETA_FLAG;
    4'd1    : rtl_ver = MAJOR_VER;
    4'd2    : rtl_ver = MINOR_VER;
    4'd4    : rtl_ver = 8'hA4;
    4'd5    : rtl_ver = CORE_CAPS | CAPS_KEYQ | CAPS_INDIAG;
    4'd6    : rtl_ver = in_diag[7:0];
    4'd7    : rtl_ver = in_diag[15:8];
    4'd8    : rtl_ver = in_diag[23:16];
    4'd9    : rtl_ver = in_diag[31:24];
    // the OSD text layer (see above): bytes 10/11 are what the boot ROM's
    // lock-step checks against the firmware's OSD2_REQUIRED
    // (fw/ctrl_boot/lockstep.c).  Byte 11, the layer version: 2 since byte 14 is the status byte and
    // cfide has the RTG screen's Video Pos register (0x0fffff54); the
    // firmware reads byte 14 only from version 2 on (fw/ctrl/osd2.h
    // OSD2_V_STATUS), a version-1 core answers MINION_VER there.
    4'd10   : rtl_ver = 8'hB5;
    4'd11   : rtl_ver = 8'd2;
    4'd12   : rtl_ver = 8'd64;
    4'd13   : rtl_ver = 8'd32;
    // byte 14, the status: bit 0 the RTG screen is on (agnus' rtg_ena; clk
    // domain, no synchroniser needed)
    4'd14   : rtl_ver = {7'd0, rtg_ena};
    default : rtl_ver = MINION_VER;
  endcase
end


//----------------------------------------------------------------------------
// The OSD key-event queue.  Sixteen events deep, written on every CHANGE of
// osd_ctrl (which is how the firmware defined an event anyway) and drained by
// SPI_KEYQ_ADR:
//
//   data byte 0 : {overflow, 3'b000, count[3:0]}   -- how many are waiting
//   data byte n : the n-th event, oldest first, popped as it is shifted out
//
// Empty reads return 0x00, so a firmware that asks for more than `count` gets
// nothing rather than a stale repeat.  A full queue DROPS THE NEWEST event and
// sets the overflow flag: dropping the oldest would lose a key-up and leave a
// modifier stuck, the very failure this exists to remove.  The flag clears
// when the count byte is read.
//
// osd_ctrl keeps its OSD_CMD_READ path unchanged: it is still the level the
// firmware's auto-repeat watches.
//----------------------------------------------------------------------------
reg  [7:0] kq_mem [0:15];
reg  [3:0] kq_wptr = 4'd0;
reg  [3:0] kq_rptr = 4'd0;
reg        kq_ovf  = 1'b0;
reg  [7:0] osd_ctrl_d = 8'd0;
wire [3:0] kq_count = kq_wptr - kq_rptr;
wire       kq_full  = (kq_count == 4'd15);
`ifdef KEYQ_MUTANT
// sim/osd_keyq's teeth check: nothing is ever queued.  If the bench still
// passes with this defined, it is not testing what it claims to.
wire       kq_event = 1'b0;
`else
wire       kq_event = (osd_ctrl != osd_ctrl_d);
`endif

always @ (posedge clk) begin
  if (clk7_en) begin
    osd_ctrl_d <= #1 osd_ctrl;
    if (kq_event) begin
      if (kq_full) kq_ovf <= #1 1'b1;
      else begin
        kq_mem[kq_wptr] <= #1 osd_ctrl;
        kq_wptr <= #1 kq_wptr + 4'd1;
      end
    end
    // a byte has been shifted out: byte 0 is the status, every later one pops
    if (rx && !cmd && spi_keyq_sel) begin
      if (dat_cnt == 3'd0) kq_ovf <= #1 1'b0;
      else if (kq_count != 4'd0) kq_rptr <= #1 kq_rptr + 4'd1;
    end
  end
end

wire [7:0] kq_rddat = (dat_cnt == 3'd0) ? {kq_ovf, 3'b000, kq_count}
                    : (kq_count != 4'd0) ? kq_mem[kq_rptr] : 8'h00;

// read data
assign rddat =  (spi_version_sel)  ? rtl_ver :
                (spi_keyq_sel)     ? kq_rddat :
                (spi_mem_read_sel) ? 8'd00  : osd_ctrl;


endmodule

