// L3 bench: the host CPU, its bridge and cfide against the REAL Minimig SPI
// slaves, booting the real boot ROM and firmware from an SD card image.
// See sim/l3/README.md ("Bench") and run.sh.
//
//   host_bridge (rv_hostcpu + VexOsd, the committed boot ROM
//     fw/ctrl_boot/OSDBoot_rv_ROM.vhd, hostcache.v)
//     -> sdram_host_model (sim/host_bridge, +SLAT +SJIT +SEED)
//     -> cfide (the board's generics: spimux false, havespirtc, havei2c,
//        havevpos true; no I2C slave, SCL/SDA read 1, every transfer NACKs)
//          sd_cs[1]  sd_spi_model (sim/common), 32 MB card (+SD_IMG)
//          sd_cs[7]  rtc_model (sim/l3): the SPI RTC rtc.c reads, fixed time
//          sd_cs[4]  paula_floppy  (rtl/minimig), _scs
//          sd_cs[5]  userio_osd    (rtl/minimig), instance osd1, _scs
//          sd_cs[6]  paula_floppy direct_scs = ~sd_cs[6] (card -> paula)
//          paula_floppy <-> gayle #(.IDE_PORTS(2)) over the hdd_* bus
//     minimig_syscontrol (rtl/minimig): the chipset reset
//     bfm_audio: the CD-audio ring position (cfide audio_buf); with
//       +CDDA_DUMP=<prefix> (scenarios cdda, cdda_load) a copy of every half
//       the player starts, from this SDRAM model
//     bfm_keys: userio_osd's osd_ctrl (the OSD keys) from a key script
//       (+KEYS=<file>, scenarios keys and fdd_rd); 0 without one
//     bfm_floppy: paula_floppy's Amiga side, the CIA lines, Paula's disk
//       registers and Agnus's disk DMA slots (scenario fdd_rd; idle
//       otherwise)
//     bfm_ide: gayle's Amiga side, a 68k IDE driver on the task file, data,
//       INTENA / INTREQ registers, irq and nrdy (scenario hdd; idle
//       otherwise)
//
// Wiring as rtl/minimig/minimig.v and rtl/soc/minimig_virtual_top.v:
//   SPI_DO (cfide sd_di)   = paula_sdo | user_sdo          (minimig.v)
//   SD_MISO (cfide sd_dimm) = the card's MISO              (virtual top),
//                            the RTC's while sd_cs[7] is low (a shared line)
//   cfide samples sd_di unless sd_cs[1] or sd_cs[7] is low, then sd_dimm.
//   userio_osd CORE_CAPS = 8'hAD: minimig_virtual_top's CORE_CAPS with the
//   board's ap040_has_mmu = ap040_has_fpu = 1 (8'h2D), ORed with minimig.v's
//   CAPS_IDE2 (8'h80) as minimig.v passes it to userio; userio_osd adds
//   CAPS_KEYQ and CAPS_INDIAG itself (version byte 5 = 8'hFD).
//   floppy_config / ide_config0/1 pass one clk_28 register as in minimig.v;
//   paula floppy_drives = floppy_config[3:2], gayle hdd0/1_ena = [2:1],
//   hdd0/1_atapi = [4:3], hdc_ena (gary, a wire for later tasks) = bit 0.
//   The slaves get rtl/soc/openaars_defines.vh first (the board's global
//   include: MINIMIG_HOST_DIRECT, so userio_osd's host_cs is constant 0).
//
// The Amiga side is idle except for bfm_floppy (fdd_rd), bfm_ide (hdd) and
// bfm_keys: until bfm_floppy starts, the CIA lines deselect the floppy
// (_sel 1111, _motor 1, _step 1), no Paula register write, no disk DMA;
// until bfm_ide starts, no Gayle access (its 68k inputs all 0),
// osd_ctrl from bfm_keys (0 unless a key script runs), in_diag 0 (not
// modelled), c1 / c3 / sol 0, rtg_ena 0.  The chipset reset is minimig.v's: reset = sys_reset | ~_cpu_reset_in, sys_reset from
// minimig_syscontrol (mrst = userio_osd usrrst, cnt = sof), and the idle
// CPU's reset output follows its reset input (_cpu_reset_in = ~(cpurst |
// sys_reset)): reset = sys_reset | cpurst.  sof: one clk7 cycle per PAL
// frame, +SOF_CLK7=<n> clk7 cycles apart (default 142102 = 313 lines x 227
// colour clocks x 2).  userio_osd host_ack is 0; host_cs rising is a bench
// error (the firmware never sends OSD_CMD_WR).
//
// Clocks: clk_114 T114 = 8.8154 ns; clk_28 = clk_114 / 4, its edges
// +C28DLY=<ns> (default 0.3) after the clk_114 edge; clk7_en / clk7n_en from
// clk_28 as rtl/clock/amiga_clk.v; the slaves see sck +SCKDLY=<ns> (default
// 1.5) after cfide's pin register (sim/spi_cdc/tb_spi_cdc.v's two delays).
// Resets as sim/host_bridge/tb_host_bridge.v.
//
// TIMER: cfide tick_in from the tick generator, +TICKDIV=<n>: one clk_28
// pulse every n clk_28 cycles; n = 1 (default) holds it at 1 (L2's TIMER,
// 643x the board's); n = 643 is the board's 44.1 kHz.  +TICKDIV_AT=scenario
// runs at 1 until the scenario starts (its main-loop milestone), then at n.
//
// Monitors: sim/common/hostmon.vh (stale ack, SPI accept, X on the bus, UART
// lines, the SPI frame log +SPI_LOG=<file> (spi.txt), OSD GAP, STACK low,
// STATS, BOOT), mon_l3.vh (the "=== MARGIN" lines of plan 7.1 items 1, 3,
// 4, 5, 6, 7, 8, 9, 12, 14 and "=== KICK", +RTC_CSH_MIN=<ns>; rtc_model's "=== RTC")
// and, here:
//   +SPI_T_LOG=<file>  the frames of spi.txt with "<start> <end> " cycles in
//                      front (spi_t.txt; never compared)
//   === OSD EARLY <n> of <m> reply bytes   in OSD_CMD_VERSION (0x88) and
//                      OSD_CMD_KEYQ (0x98) frames (the SPI_reply() users, as
//                      OSD GAP), every byte after the command: userio_osd_spi
//                      loads sdo_reg from its "in" (negedge of its sck,
//                      bit_cnt 0); early when osd1.spi0.new_byte | rx_sync |
//                      rx is 1 then (the previous byte is still in the clk7
//                      synchroniser: the reply counters have not moved).
//                      n > 0 is a bench error unless +OSD_EARLY_OK=1
//   === OSD REPLY <cmd> byte <k>: gap min <g> over <n> writes, early <e> of
//                      <m> loads   per reply byte k (0 = the first after the
//                      command) of OSD_CMD_VERSION (88) and OSD_CMD_KEYQ
//                      (98): hostmon's OSD GAP and the OSD EARLY count of
//                      that byte alone (the "before" table, Task 8)
//   +FAST_HW=1         run.sh puts +SD_TOKEN_DLY=0 +SD_BUSY=1 +SD_NCR=1
//                      +SLAT=2 +SJIT=0 first; the bench checks the models
//                      took them
//   +SDRAM_DUMP=<file> the SDRAM model's 8 MB, written before the verdict
//   +SD_SAVE=<file>    the card as the run left it (the SD model)
//   +IDE_DUMP=<prefix> bfm_ide's dump files <prefix>_<k>.hex (scenario hdd)
//   +CDDA_DUMP=<prefix> bfm_audio's ring snapshots <prefix>_<n>.bin (cdda)
// Scenarios (+SCENARIO=<name>): scenarios.vh.  A scenario ends the run at
// its end event ("=== PASS" without DONE when no bench error) or the run
// ends at +TIMEOUT=<clk_114 cycles> ("=== FAIL <scenario>: ...").
// Plusargs also: +SLAT +SJIT +SEED (SDRAM model), +SD_* (card model),
// +OSD_MIN_GAP=<n> (hostmon, default 40), +VERBOSE=1.
// Parameter EXTRA_WS: the bridge's rv_extra_ws (xelab -generic_top; the
// GHDL conversion fixes it, checked below).
//
// SD_ENGINE (run.sh SD_ENGINE=1; default off, every scenario as before):
// the SD card engine as minimig_virtual_top wires it with SD_ENGINE = 1:
// rtl/host/sdcard_spi.v on cfide's ext_* port (0xFFFFFF00..2C, irq on
// irq_src(4)), the card model on its pins (card present: sd_cd_n 0) instead
// of cfide's sd_cs[1]; cfide's sd_dimm is the RTC's MISO alone and
// paula_floppy's direct_sdi is 1 (the card is not on cfide's SPI); sdcard_gayle
// + sdcard_gayle_mux (rtl/minimig/sdcard_gayle.v, CLK_RATIO 4) between
// paula_floppy's and gayle's hdd_* data port, as minimig.v.  Without it the
// hdd_* wires join paula_floppy and gayle directly.  The run.sh scenarios
// sdc_boot, sdc_boot_short and sdc_hdd (README "sdc") build with it: the
// boot ROM and the firmware reach the card through sdcard_spi only.  Lines:
//   === SDC gayle to_gayle <n> ops <w> words, from_gayle <n> ops <w> words,
//       g_err <e>, ended by g_ack <a>; irq rises <i>   (the bridge's traffic:
//       ops = g_req rises by g_dir, words = the words moved (g_wnext with
//       g_wvalid, g_rvalid), at the end of the run)
//   +SD_ERR_AT=scenario  the card model's +SD_ERR_<kind>=n count from the
//       scenario's main-loop milestone (sc_started) instead of time 0: n is
//       moved by the events (read blocks, written blocks, commands) before
//       it ("=== SD_ERR armed at the scenario start: ...")
//
// L3_GHDL (run.sh SIM=verilator): the bridge and cfide are the Verilog that
// ghdl --synth made of the VHDL (generics fixed at the conversion, lower-case
// names, generate labels folded into instance names).
`timescale 1ns/1ps

// hostmon.vh's firmware-boot monitors; RV_HOSTCPU_STATS comes from the
// command line (rv_hostcpu.v needs it too, run.sh sets it for both)
`ifndef SDCARD
`define SDCARD
`endif
`ifndef FWBOOT
`define FWBOOT
`endif
`define HM_RV      hostcpu.myrv
`ifdef L3_GHDL
`define HM_SD_BUSY mycfide.sd_busy
`else
`define HM_SD_BUSY mycfide.SD_busy
`endif
`define HM_FRAME_HOOK
`define HM_OSD_GAP_HOOK

module tb_l3 #(
  parameter EXTRA_WS = 0
);

  real T114 = 8.8154;
  real sckdly = 1.5, c28dly = 0.3;
  initial begin
    if (!$value$plusargs("SCKDLY=%f", sckdly)) sckdly = 1.5;
    if (!$value$plusargs("C28DLY=%f", c28dly)) c28dly = 0.3;
  end

  reg clk114 = 1'b0;
  always #(T114/2.0) clk114 = ~clk114;
  reg [1:0] div = 2'd0;
  reg clk28 = 1'b0;
  always @(posedge clk114) begin
    div <= div + 2'd1;
    if (div == 2'd0) clk28 <= #(c28dly) 1'b1;
    if (div == 2'd2) clk28 <= #(c28dly) 1'b0;
  end

  // clk7_en / clk7n_en as rtl/clock/amiga_clk.v makes them
  reg [1:0] clk7_cnt = 2'b10;
  reg clk7_en = 1'b1, clk7n_en = 1'b1;
  always @(posedge clk28) begin
    clk7_cnt <= clk7_cnt + 2'b01;
    clk7_en  <= #1 (clk7_cnt == 2'b00);
    clk7n_en <= #1 (clk7_cnt == 2'b10);
  end

  reg n_reset = 1'b0, cpu_reset_n = 1'b0;
  // one 1 -> 0 edge of the bridge's nReset before the first clk_114 edge
  // (tb_host_bridge.v: its reset is asynchronous on that edge)
  initial begin
    #1 cpu_reset_n = 1'b1;
    #1 cpu_reset_n = 1'b0;
  end

  // ------------------------------------------------------------ bridge
  wire [31:2] hostaddr;
  wire [31:0] hostWR;
  wire [3:0]  hostsel;
  wire        host_we;
  wire        ram_req, ram_ack;
  wire [15:0] ram_d;
  wire        hw_req, hw_ack;
  wire [15:0] hw_d;
  wire        cfide_int;
  wire        rv_tdo;

`ifdef L3_GHDL
  host_bridge hostcpu (
`else
  host_bridge #(.rv_extra_ws(EXTRA_WS)) hostcpu (
`endif
    .clk(clk114), .nReset(cpu_reset_n),
    .addr(hostaddr), .q(hostWR), .sel(hostsel), .wr(host_we),
    .ram_req(ram_req), .ram_ack(ram_ack), .ram_d(ram_d),
    .hw_req(hw_req), .hw_ack(hw_ack), .hw_d(hw_d),
    .interrupt(cfide_int),
    .rv_jtag_tck(1'b0), .rv_jtag_tms(1'b0), .rv_jtag_tdi(1'b0), .rv_jtag_tdo(rv_tdo)
  );

  sdram_host_model ram (
    .clk(clk114), .ram_req(ram_req), .ram_ack(ram_ack), .ram_d(ram_d),
    .addr(hostaddr), .q(hostWR), .sel(hostsel), .wr(host_we)
  );

  // ------------------------------------------------------------- cfide
  wire [7:0]  sd_cs;
  wire        sd_clk, sd_do;
  wire        spi_do;            // SPI_DO: the Minimig slaves' MISO (cfide sd_di)
  wire        card_miso;         // the card's MISO (paula's direct_sdi)
  wire        rtc_miso;
`ifdef SD_ENGINE
  wire        sd_miso = (sd_cs[7] === 1'b0) ? rtc_miso : 1'b1;        // SD_MISO (cfide sd_dimm): the RTC only
`else
  wire        sd_miso = (sd_cs[7] === 1'b0) ? rtc_miso : card_miso;   // SD_MISO (cfide sd_dimm)
`endif
  wire        sdc_wstb, sdc_rstb, sdc_irq;   // cfide ext_* <-> sdcard_spi (SD_ENGINE)
  wire [5:2]  sdc_addr;
  wire [15:0] sdc_d, sdc_q;
  wire        scandoubler, audio_ena, audio_clear;
  wire [15:0] aud_addr;
  reg         tick = 1'b1;       // cfide tick_in (tick generator below)
  wire [7:0]  aki_addr;          // cfide's Akiko request window, from bfm_akiko (scenario akiko; idle otherwise)
  wire [15:0] aki_d, aki_q;
  wire        aki_req, aki_wr, aki_ack;
  wire [1:0]  osd_rx_seq;        // userio_osd's reply sequence -> cfide HOST_REQ (minimig_virtual_top)

  // The generics below are the only copy: run.sh reads them from this
  // "cfide #( ... ) mycfide (" block for the GHDL conversion and stops
  // unless they are exactly the boolean generics of the cfide entity.
`ifdef L3_GHDL
  cfide mycfide (     // converted with the generics below
`else
  cfide #(
    .spimux(1'b0), .havespirtc(1'b1), .havei2c(1'b1), .havevpos(1'b1)
  ) mycfide (
`endif
    .sysclk(clk114), .n_reset(n_reset),
    .addr(hostaddr), .d(hostWR[15:0]), .q(hw_d), .req(hw_req), .wr(host_we), .ack(hw_ack),
    .sd_di(spi_do), .sd_cs(sd_cs), .sd_clk(sd_clk), .sd_do(sd_do),
    .sd_dimm(sd_miso), .sd_ack(1'b1),
    .debugTxD(), .debugRxD(1'b1), .menu_button(1'b1),
    .xadc_temp(16'h0000),
    .scandoubler(scandoubler), .audio_ena(audio_ena), .audio_clear(audio_clear),
    .audio_buf(aud_addr[15]), .audio_amiga(1'b0), .vbl_int(1'b0), .interrupt(cfide_int),
    .irq_src({11'h000, sdc_irq}),
    .c64_keys(64'hFFFFFFFFFFFFFFFF), .amiga_key(), .amiga_key_stb(),
    .amiga_addr(aki_addr), .amiga_d(aki_d), .amiga_q(aki_q),
    .amiga_req(aki_req), .amiga_wr(aki_wr), .amiga_ack(aki_ack),
    .rtc_q(),
    .scl_i(1'b1), .scl_o(), .scl_t(), .sda_i(1'b1), .sda_o(), .sda_t(),
    .i2c_ext_int(1'b0),
    .pos_data_q(),
    .osd_rx_seq(osd_rx_seq),
    .ext_wstb(sdc_wstb), .ext_rstb(sdc_rstb), .ext_addr(sdc_addr), .ext_d(sdc_d), .ext_q(sdc_q),
    .clk_28(clk28), .tick_in(tick)
  );

  // what cfide samples: the card or the RTC while sd_cs[1] or sd_cs[7] is
  // low, else the Minimig slaves (hostmon's frame log reads it)
  wire miso = (sd_cs[1] === 1'b0 || sd_cs[7] === 1'b0) ? sd_miso : spi_do;

  // --------------------------------------------------- bench state, errors
  integer errors = 0;
  integer cyc = 0;
  always @(posedge clk114) cyc <= cyc + 1;
  integer verbose = 0, timeout = 3000000;
  reg     is_boot = 1'b1;          // hostmon: a cycle line per UART line

  task bench_error(input [8*120-1:0] msg);
    begin
      $display("BENCH ERROR at cycle %0d: %0s", cyc, msg);
      errors = errors + 1;
    end
  endtask

  // --------------------------------------------------------------- SD card
`ifdef SD_ENGINE
  // the SD card engine (header): the card on sdcard_spi's pins
  wire        card_cs_n, card_sck, card_mosi;
  wire        sdc_g_req, sdc_g_dir, sdc_g_port, sdc_g_ack, sdc_g_err;
  wire        sdc_g_wvalid, sdc_g_wnext, sdc_g_rvalid;
  wire [9:0]  sdc_g_words;
  wire [15:0] sdc_g_wdata, sdc_g_rdata;
  sdcard_spi sdc (
    .clk(clk114), .reset(!n_reset),
    .reg_wstb(sdc_wstb), .reg_rstb(sdc_rstb), .reg_addr(sdc_addr), .reg_d(sdc_d), .reg_q(sdc_q),
    .irq(sdc_irq),
    .sd_sck(card_sck), .sd_cs_n(card_cs_n), .sd_mosi(card_mosi), .sd_miso(card_miso),
    .sd_cd_n(1'b0),
    .g_req(sdc_g_req), .g_dir(sdc_g_dir), .g_port(sdc_g_port), .g_words(sdc_g_words),
    .g_ack(sdc_g_ack), .g_err(sdc_g_err),
    .g_wdata(sdc_g_wdata), .g_wvalid(sdc_g_wvalid), .g_wnext(sdc_g_wnext),
    .g_rdata(sdc_g_rdata), .g_rvalid(sdc_g_rvalid)
  );
  // the bridge's traffic (header: "=== SDC gayle")
  integer sdcm_ops[0:1], sdcm_words[0:1];   // index g_dir: 1 to_gayle, 0 from_gayle
  integer sdcm_err = 0, sdcm_ack = 0, sdcm_irq = 0;
  reg     sdcm_req_d = 1'b0, sdcm_irq_d = 1'b0;
  initial begin sdcm_ops[0] = 0; sdcm_ops[1] = 0; sdcm_words[0] = 0; sdcm_words[1] = 0; end
  always @(posedge clk114) begin
    if (sdc_g_req && !sdcm_req_d) sdcm_ops[sdc_g_dir] = sdcm_ops[sdc_g_dir] + 1;
    if (sdc_g_req && sdc_g_dir && sdc_g_wnext && sdc_g_wvalid) sdcm_words[1] = sdcm_words[1] + 1;
    if (sdc_g_req && !sdc_g_dir && sdc_g_rvalid) sdcm_words[0] = sdcm_words[0] + 1;
    if (sdc_g_req && sdc_g_err) sdcm_err = sdcm_err + 1;
    if (sdc_g_req && sdc_g_ack) sdcm_ack = sdcm_ack + 1;
    if (sdc_irq && !sdcm_irq_d) sdcm_irq = sdcm_irq + 1;
    sdcm_req_d <= sdc_g_req;
    sdcm_irq_d <= sdc_irq;
  end
  task sdc_final;
    $display("=== SDC gayle to_gayle %0d ops %0d words, from_gayle %0d ops %0d words, g_err %0d, ended by g_ack %0d; irq rises %0d",
             sdcm_ops[1], sdcm_words[1], sdcm_ops[0], sdcm_words[0], sdcm_err, sdcm_ack, sdcm_irq);
  endtask
`else
  wire        card_cs_n = sd_cs[1], card_sck = sd_clk, card_mosi = sd_do;
  assign sdc_q = 16'h0000;
  assign sdc_irq = 1'b0;
  task sdc_final;
    ;
  endtask
`endif
  sd_spi_model #(.IMG_SECTORS(65536)) card (
    .cs_n(card_cs_n), .sck(card_sck), .mosi(card_mosi), .miso(card_miso)
  );

  // ------------------------------------------------------------------ RTC
  rtc_model rtc1 (
    .cs_n(sd_cs[7]), .sck(sd_clk), .mosi(sd_do), .miso(rtc_miso)
  );

  // -------------------------------------------------- Minimig: clocks, reset
  // sck at the slaves: cfide's register plus clock routing
  reg sck_slv = 1'b1;
  always @(sd_clk) sck_slv <= #(sckdly) sd_clk;

  // sof: one clk7 cycle per frame
  integer sof_clk7 = 142102, sof_cnt = 0;
  reg     sof = 1'b0;
  always @(posedge clk28) if (clk7_en) begin
    sof <= (sof_cnt == sof_clk7 - 1);
    sof_cnt <= (sof_cnt >= sof_clk7 - 1) ? 0 : sof_cnt + 1;
  end

  wire usrrst, cpurst, cpuhlt;
  wire sys_reset;
  minimig_syscontrol mm_ctl (
    .clk(clk28), .clk7_en(clk7_en), .cnt(sof), .mrst(usrrst), .reset(sys_reset)
  );
  wire mm_reset = sys_reset | cpurst;

  // minimig.v's one-clock config registers
  wire [3:0] userio_floppy_config;
  wire [4:0] userio_ide_config0, userio_ide_config1;
  reg  [3:0] floppy_config;
  reg  [4:0] ide_config0, ide_config1;
  always @(posedge clk28) begin
    floppy_config <= userio_floppy_config;
    ide_config0 <= userio_ide_config0;
    ide_config1 <= userio_ide_config1;
  end
  wire [1:0] hdc_ena = {ide_config1[0], ide_config0[0]};   // gary's Gayle decode enable

  // ------------------------------------------------------- paula_floppy
  wire        paula_sdo, user_sdo;
  assign spi_do = paula_sdo | user_sdo;
  wire        hdd_cmd_req, hdd_dat_req;
  wire [2:0]  hdd_addr;
  wire [15:0] hdd_data_out, hdd_data_in;
  wire        hdd_wr, hdd_status_wr, hdd_data_wr, hdd_data_rd, hdd_port, hdd_xfer_wr, hdd_regs_rd;
  wire [1:0]  hdd_fifo_reset, hdd_cmd_new;
  // paula_floppy's side of the data port; minimig.v's names (pf_*)
  wire [2:0]  pf_addr;
  wire [15:0] pf_data_out, pf_data_in;
  wire        pf_data_wr, pf_data_rd, pf_port;
  wire        fl_track0, fl_change, fl_ready, fl_wprot, fl_index, fl_dmal, fl_dmas;
  wire [3:0]  fl_sel;
  wire        fl_motor, fl_side, fl_step, fl_direc, fl_enable, fl_wordsync, fl_blckint;
  wire [8:1]  fl_rga;
  wire [15:0] fl_din, fl_dout;

  // the Amiga side of the floppy: CIA lines, Paula's registers, Agnus's
  // disk DMA (scenario fdd_rd; idle otherwise)
  bfm_floppy fdd (
    .clk28(clk28), .clk7_en(clk7_en), .cyc(cyc),
    ._sel(fl_sel), ._motor(fl_motor), .side(fl_side), ._step(fl_step), .direc(fl_direc),
    ._track0(fl_track0), ._ready(fl_ready),
    .reg_address_in(fl_rga), .data_in(fl_din), .data_out(fl_dout),
    .dmal(fl_dmal), .dmas(fl_dmas), .blckint(fl_blckint),
    .enable(fl_enable), .wordsync(fl_wordsync)
  );

  paula_floppy pf1 (
    .clk(clk28), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
    .reset(mm_reset), .ntsc(1'b0), .sof(sof), .enable(fl_enable),
    .reg_address_in(fl_rga), .data_in(fl_din), .data_out(fl_dout),
    .dmal(fl_dmal), .dmas(fl_dmas),
    ._step(fl_step), .direc(fl_direc), ._sel(fl_sel), .side(fl_side), ._motor(fl_motor),
    ._track0(fl_track0), ._change(fl_change), ._ready(fl_ready), ._wprot(fl_wprot), .index(fl_index),
    .blckint(fl_blckint), .syncint(), .wordsync(fl_wordsync),
    ._scs(sd_cs[4]), .sdi(sd_do), .sdo(paula_sdo), .sck(sck_slv),
    .disk_led(), .floppy_drives(floppy_config[3:2]),
`ifdef SD_ENGINE
    .direct_scs(~sd_cs[6]), .direct_sdi(1'b1),
`else
    .direct_scs(~sd_cs[6]), .direct_sdi(card_miso),
`endif
    .hdd_cmd_req(hdd_cmd_req), .hdd_dat_req(hdd_dat_req),
    .hdd_addr(pf_addr), .hdd_data_out(pf_data_out), .hdd_data_in(pf_data_in),
    .hdd_wr(hdd_wr), .hdd_status_wr(hdd_status_wr),
    .hdd_data_wr(pf_data_wr), .hdd_data_rd(pf_data_rd),
    .hdd_port(pf_port), .hdd_xfer_wr(hdd_xfer_wr), .hdd_regs_rd(hdd_regs_rd),
    .trackdisp(), .secdisp(), .floppy_fwr(), .floppy_frd()
  );

  // --------------------------------------------------------------- gayle
  wire gayle_irq, gayle_nrdy;
  wire [23:1] ide_a;
  wire [15:0] ide_din, ide_dout;
  wire        ide_rd, ide_hwr, ide_lwr, ide_sel, ide_selg;

  // the Amiga side of gayle: a 68k IDE driver (scenario hdd; idle otherwise)
  bfm_ide ide (
    .clk28(clk28), .clk7_en(clk7_en), .reset(mm_reset), .cyc(cyc),
    .address_in(ide_a), .data_in(ide_din), .data_out(ide_dout),
    .rd(ide_rd), .hwr(ide_hwr), .lwr(ide_lwr), .sel_ide(ide_sel), .sel_gayle(ide_selg),
    .irq(gayle_irq), .nrdy(gayle_nrdy)
  );

  gayle #(.IDE_PORTS(2)) gayle1 (
    .clk(clk28), .clk7_en(clk7_en), .reset(mm_reset),
    .address_in(ide_a), .data_in(ide_din), .data_out(ide_dout),
    .rd(ide_rd), .hwr(ide_hwr), .lwr(ide_lwr), .sel_ide(ide_sel), .sel_gayle(ide_selg),
    .irq(gayle_irq), .nrdy(gayle_nrdy),
    .hdd0_ena(ide_config0[2:1]), .hdd1_ena(ide_config1[2:1]),
    .hdd0_atapi(ide_config0[4:3]), .hdd1_atapi(ide_config1[4:3]),
    .hdd_cmd_req(hdd_cmd_req), .hdd_dat_req(hdd_dat_req),
    .hdd_data_in(hdd_data_in), .hdd_addr(hdd_addr), .hdd_data_out(hdd_data_out),
    .hdd_wr(hdd_wr), .hdd_status_wr(hdd_status_wr),
    .hdd_data_wr(hdd_data_wr), .hdd_data_rd(hdd_data_rd),
    .hdd_port(hdd_port), .hdd_xfer_wr(hdd_xfer_wr), .hdd_regs_rd(hdd_regs_rd),
    .hdd_fifo_reset(hdd_fifo_reset), .hdd_cmd_new(hdd_cmd_new),
    .hd_fwr(), .hd_frd()
  );

  // the data port: the SD card bridge's while it is active, else
  // paula_floppy's (minimig.v)
`ifdef SD_ENGINE
  wire        sg_active, sg_port, sg_data_wr, sg_data_rd;
  wire [15:0] sg_data_out;
  wire [1:0]  sg_cmd_seen;
  sdcard_gayle #(.CLK_RATIO(4)) sdcg (
    .clk(clk28), .clk7_en(clk7_en), .reset(mm_reset), .clk_g(clk114),
    .g_req(sdc_g_req), .g_dir(sdc_g_dir), .g_port(sdc_g_port), .g_words(sdc_g_words),
    .g_ack(sdc_g_ack), .g_err(sdc_g_err),
    .g_wdata(sdc_g_wdata), .g_wvalid(sdc_g_wvalid), .g_wnext(sdc_g_wnext),
    .g_rdata(sdc_g_rdata), .g_rvalid(sdc_g_rvalid),
    .active(sg_active), .port(sg_port), .data_wr(sg_data_wr), .data_rd(sg_data_rd),
    .data_out(sg_data_out), .data_in(hdd_data_in), .dat_req(hdd_dat_req),
    .fifo_reset_seen(hdd_fifo_reset), .cmd_new(hdd_cmd_new),
    .fw_port(pf_port), .fw_regs_rd(hdd_regs_rd), .cmd_seen(sg_cmd_seen)
  );
  sdcard_gayle_mux sdcmux (
    .sg_active(sg_active), .sg_port(sg_port), .sg_data_wr(sg_data_wr), .sg_data_rd(sg_data_rd),
    .sg_data_out(sg_data_out), .sg_cmd_seen(sg_cmd_seen),
    .pf_port(pf_port), .pf_data_wr(pf_data_wr), .pf_data_rd(pf_data_rd), .pf_data_out(pf_data_out),
    .pf_addr(pf_addr), .pf_data_in(pf_data_in), .gy_data_in(hdd_data_in),
    .hdd_port(hdd_port), .hdd_data_wr(hdd_data_wr), .hdd_data_rd(hdd_data_rd),
    .hdd_data_out(hdd_data_out), .hdd_addr(hdd_addr)
  );
`else
  assign hdd_addr = pf_addr;
  assign hdd_port = pf_port;
  assign hdd_data_wr = pf_data_wr;
  assign hdd_data_rd = pf_data_rd;
  assign hdd_data_out = pf_data_out;
  assign pf_data_in = hdd_data_in;
`endif

  // the Amiga side of the Akiko request window (scenario akiko).  ena_wr: a
  // completed write with bit 0 set to the INTERRUPT window (0xFFFFFFA0), the
  // firmware's EnableInterrupts (bfm_akiko.v)
  bfm_akiko aki (
    .clk28(clk28), .clk114(clk114), .cyc(cyc),
    .ena_wr(hw_req && hw_ack && host_we && hostaddr[23] && hostaddr[7:4] == 4'hA && hostWR[0]),
    .busy(fdd.dma_busy),
    .addr(aki_addr), .d(aki_d), .wr(aki_wr), .req(aki_req), .q(aki_q), .ack(aki_ack)
  );

  // ------------------------------------------------------------- OSD keys
  wire [7:0] osd_ctrl;
  bfm_keys keys (.clk28(clk28), .clk7_en(clk7_en), .osd_ctrl(osd_ctrl));

  // the script's events as userio_osd gets them (l3check.py keys)
  integer kev_n = 0;
  always @(osd_ctrl) if (keys.go) begin
    kev_n = kev_n + 1;
    $display("=== KEYS ev %0d %h at cycle %0d", kev_n, osd_ctrl, cyc);
  end

  // ----------------------------------------------------------- userio_osd
  wire osd_host_cs;
  userio_osd #(.CORE_CAPS(8'hAD)) osd1 (
    .clk(clk28), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
    .reset(mm_reset),
    .c1(1'b0), .c3(1'b0), .sol(1'b0), .sof(sof),
    .varbeamen(1'b0), .rtg_ena(1'b0),
    .osd_ctrl(osd_ctrl),
    .in_diag(32'h00000000), .in_diag_clr(),
    ._scs(sd_cs[5]), .sdi(sd_do), .sdo(user_sdo), .sck(sck_slv),
    .osd_rx_seq(osd_rx_seq),   // reply sequence -> cfide's HOST_REQ OSD_RDY (as minimig_virtual_top)
    .osd_blank(), .osd_pixel(),
    .osd_enable(), .key_disable(),
    .memory_config(), .chipset_config(), .floppy_config(userio_floppy_config),
    .scanline(), .dither(), .crt_fx(),
    .ide_config0(userio_ide_config0), .ide_config1(userio_ide_config1),
    .cpu_config(), .autofire_config(), .cd32pad(),
    .usrrst(usrrst), .cpurst(cpurst), .cpuhlt(cpuhlt),
    .fifo_full(),
    .host_cs(osd_host_cs), .host_adr(), .host_we(), .host_bs(), .host_wdat(),
    .host_rdat(16'h0000), .host_ack(1'b0)
  );
  always @(posedge osd_host_cs) bench_error("userio_osd host_cs rose (OSD_CMD_WR is not used by the firmware)");

  // -------------------------------------------------- audio ring, TIMER tick
  bfm_audio audio (
    .clk28(clk28), .tick(tick), .audio_ena(audio_ena), .audio_clear(audio_clear), .cyc(cyc),
    .aud_addr(aud_addr)
  );

  integer tickdiv = 1, tick_cnt = 0;
  reg     tick_at_scen = 1'b0;   // +TICKDIV_AT=scenario
  reg     sc_started = 1'b0;     // the scenario's main-loop milestone (scenarios.vh)
  wire    tick_fast = tickdiv <= 1 || (tick_at_scen && !sc_started);
  always @(posedge clk28) begin
    if (tick_fast) begin
      tick <= 1'b1;
      tick_cnt <= 0;
    end else if (tick_cnt >= tickdiv - 1) begin
      tick <= 1'b1;
      tick_cnt <= 0;
    end else begin
      tick <= 1'b0;
      tick_cnt <= tick_cnt + 1;
    end
  end

  // +SD_ERR_AT=scenario (header): the model's error counts from sc_started.
  // At 1 ns (the bench's start, before any SPI clock) the model's counts are
  // taken and set to 0 (off); at sc_started they come back, moved by the
  // events so far
  reg     sd_err_at = 1'b0;
  integer sea_rdcrc = 0, sea_wrrej = 0, sea_wrfail = 0, sea_noresp = 0, sea_cmdcrc = 0;
  task sd_err_hold;
    begin
      sea_rdcrc = card.err_rdcrc; sea_wrrej = card.err_wrrej; sea_wrfail = card.err_wrfail;
      sea_noresp = card.err_noresp; sea_cmdcrc = card.err_cmdcrc;
      card.err_rdcrc = 0; card.err_wrrej = 0; card.err_wrfail = 0; card.err_noresp = 0; card.err_cmdcrc = 0;
    end
  endtask
  always @(posedge sc_started) if (sd_err_at) begin
    if (sea_rdcrc > 0)  card.err_rdcrc  = sea_rdcrc  + card.rd_blk_n;
    if (sea_wrrej > 0)  card.err_wrrej  = sea_wrrej  + card.wr_blk_n;
    if (sea_wrfail > 0) card.err_wrfail = sea_wrfail + card.wr_blk_n;
    if (sea_noresp > 0) card.err_noresp = sea_noresp + card.cmd_n;
    if (sea_cmdcrc > 0) card.err_cmdcrc = sea_cmdcrc + card.cmd_n;
    $display("=== SD_ERR armed at the scenario start (cycle %0d): %0d read blocks, %0d written blocks, %0d commands so far; RDCRC %0d WRREJ %0d WRFAIL %0d NORESP %0d CMDCRC %0d (absolute)",
             cyc, card.rd_blk_n, card.wr_blk_n, card.cmd_n,
             card.err_rdcrc, card.err_wrrej, card.err_wrfail, card.err_noresp, card.err_cmdcrc);
  end

  // ----------------------------------------------- hw bus snoop and checks
  // (sim/common/hostmon.vh: the snoop checks, UART printer, FWBOOT monitors,
  // end-of-run counters; hm_frame_hook below)
`include "hostmon.vh"

  always @(posedge clk114) begin
    hm_hw_cycle;
    if (hw_req && !hw_req_d && verbose) $display("%0d HW %s %h d=%h", cyc, host_we ? "W" : "R", hwa, hostWR);
    if (hw_done) hm_hw_done;
  end

  // ------------------------------------------- SPI SCK after the firmware's start
  // cfide's SCK period (its sd_clk pin, rising to rising edge inside a byte:
  // a frame is a whole number of bytes, so every 8th rising edge of a frame
  // starts a byte and is not measured) in the frames after the jump to the
  // firmware (hostmon boot_seen), the RTC's (sd_cs[7] low) excepted: the
  // firmware's SPI_fast (speed 1) is 6 clk_114 a bit, the RTC frames run at
  // SPI_slow (rtc.c).  "=== SPI SCK period ..." at the end of the run
  integer sk_bit = 0, sk_last = 0, sk_min = -1, sk_max = -1, sk_n = 0;
  always @(sd_cs) sk_bit = 0;
  always @(posedge sd_clk) if (n_reset && boot_seen && sd_cs[7] !== 1'b0 && (sd_cs[6:1] & 6'h3F) !== 6'h3F) begin
    if (sk_bit % 8 != 0) begin
      sk_n = sk_n + 1;
      if (sk_min < 0 || cyc - sk_last < sk_min) sk_min = cyc - sk_last;
      if (cyc - sk_last > sk_max) sk_max = cyc - sk_last;
    end
    sk_bit = sk_bit + 1;
    sk_last = cyc;
  end
  task sk_final;
    begin
      if (sk_n == 0) $display("=== SPI SCK period after the firmware's start (no RTC frame): min none max none clk_114 over 0 bits");
      else $display("=== SPI SCK period after the firmware's start (no RTC frame): min %0d max %0d clk_114 over %0d bits",
                    sk_min, sk_max, sk_n);
    end
  endtask

  // ------------------------------------------------------ margin monitors
`include "mon_l3.vh"

  // ------------------------------------------------------------ OSD EARLY
  wire       oe_new = osd1.spi0.new_byte, oe_sync = osd1.spi0.rx_sync, oe_rx = osd1.spi0.rx;
  wire [2:0] oe_bit = osd1.spi0.bit_cnt;
  integer    oe_n = 0, oe_m = 0, oe_first_cyc = -1, oe_first_k = -1;
  reg  [7:0] oe_first_cmd = 8'h00;
  reg        osd_early_ok = 1'b0;
  // per reply byte (k = fr_n - 1, at most OR_K - 1): index 0 VERSION, 1 KEYQ
  localparam OR_K = 16;
  integer    or_e [0:1][0:OR_K-1];     // OSD EARLY loads
  integer    or_m [0:1][0:OR_K-1];     // loads
  integer    or_g [0:1][0:OR_K-1];     // OSD GAP min (hostmon's hook)
  integer    or_n [0:1][0:OR_K-1];     // OSD GAP samples
  integer    or_i = 0, or_j = 0;
  initial for (or_i = 0; or_i < 2; or_i = or_i + 1) for (or_j = 0; or_j < OR_K; or_j = or_j + 1) begin
    or_e[or_i][or_j] = 0; or_m[or_i][or_j] = 0; or_g[or_i][or_j] = 1000000; or_n[or_i][or_j] = 0;
  end
  integer    oe_c = 0, oe_k = 0;
  always @(negedge sck_slv) if (n_reset && sd_cs[5] === 1'b0 && oe_bit == 3'd0 &&
                                fr_cs == 8'h20 && fr_n >= 1 && (fr_out[0] == 8'h88 || fr_out[0] == 8'h98)) begin
    oe_m = oe_m + 1;
    oe_c = (fr_out[0] == 8'h98) ? 1 : 0;
    oe_k = (fr_n - 1 < OR_K) ? fr_n - 1 : OR_K - 1;
    or_m[oe_c][oe_k] = or_m[oe_c][oe_k] + 1;
    if ((oe_new | oe_sync | oe_rx) === 1'b1) begin
      oe_n = oe_n + 1;
      or_e[oe_c][oe_k] = or_e[oe_c][oe_k] + 1;
      if (oe_first_cyc < 0) begin oe_first_cyc = cyc; oe_first_cmd = fr_out[0]; oe_first_k = fr_n - 1; end
    end
  end

  // hostmon.vh's OSD GAP, per reply byte (HM_OSD_GAP_HOOK)
  integer og_c = 0, og_kk = 0;
  task hm_osd_gap_hook(input [7:0] cmd, input integer k, input integer gap);
    begin
      og_c = (cmd == 8'h98) ? 1 : 0;
      og_kk = (k < OR_K) ? k : OR_K - 1;
      or_n[og_c][og_kk] = or_n[og_c][og_kk] + 1;
      if (gap < or_g[og_c][og_kk]) or_g[og_c][og_kk] = gap;
    end
  endtask

  // (byte OR_K - 1 also counts every later one: "<k>+")
  task or_final;
    integer c, k;
    begin
      for (c = 0; c < 2; c = c + 1) for (k = 0; k < OR_K; k = k + 1)
        if (or_n[c][k] > 0 || or_m[c][k] > 0) begin
          if (or_n[c][k] > 0)
            $display("=== OSD REPLY %0s byte %0d%0s: gap min %0d over %0d writes, early %0d of %0d loads",
                     c ? "98" : "88", k, k == OR_K - 1 ? "+" : "", or_g[c][k], or_n[c][k], or_e[c][k], or_m[c][k]);
          else
            $display("=== OSD REPLY %0s byte %0d%0s: gap min none over 0 writes, early %0d of %0d loads",
                     c ? "98" : "88", k, k == OR_K - 1 ? "+" : "", or_e[c][k], or_m[c][k]);
        end
    end
  endtask

  // ----------------------------------------------------- spi_t.txt, scenario
  integer spi_t_fd = 0, fr_t_open = 0;
  reg [8*1024-1:0] spi_t_name;

  // bfm_keys' WAIT_OSD_IDLE: an OSD_CMD_OSD_WR frame is open
  always @(posedge clk114) keys.osdwr_open = sd_cs[5] === 1'b0 && fr_cs == 8'h20 && fr_n >= 1 && fr_out[0] == 8'h0c;

  // a level read (OSD_CMD_READ, "20 00") while the key script holds a key
  // is a bench error (hm_frame_hook): the firmware's key repeat reads that
  // level (bfm_keys.v), so the script keeps every key shorter than the time
  // to the next level read.  kb_held: osd_ctrl was not 0 while the open OSD
  // frame was selected
  reg kb_held = 1'b0;
  always @(posedge clk114) if (sd_cs[5] === 1'b0 && osd_ctrl != 8'h00) kb_held = 1'b1;

  // ------------------------------------------------- RETIRED, STATS windows
  // RV_HOSTCPU_STATS (plan 4.5, Task 20's I-cache table): rt_n
  // counts the instructions the core retires, one per cycle at most
  // (VexOsd u_core's writeBack_arbitration_isFiring), on its clock and out
  // of reset, as rv_hostcpu's st_* counters.  Every "=== STATS@<event>"
  // line is followed by "=== RETIRED <n> (STATS@<event>, to cycle <c>)"
  // (scenarios.vh and the windows below).  The windows: STATS@win_start and
  // STATS@win_end, sampled at the clk_114 edge after the event:
  //   boot    the main-loop milestone (first HandleFpga frame) to the end
  //           event (HandleFpga frame 21; not with +BOOT_END=rtc2)
  //   fdd_rd  the first track DMA's DSKLEN start to the end event (the
  //           blckint of the last track DMA)
  //   hdd     the first IDE command's start to the end event (the end of
  //           the last command)
  //   cdda    the player's flip 2 to its flip 6 (bfm_audio n_flip)
  //   keys    the first key event (osd_ctrl change) to the end event (the
  //           script's end, after the last key's redraw)
  // The core's signal comes through l3_retire, a wire run.sh's
  // l3_retire_tap adds to the run copy of rv_hostcpu.v (Verilator 5.020
  // does not resolve a reference into the g_core generate branch from here)
`ifdef RV_HOSTCPU_STATS
  integer rt_n = 0;
  always @(posedge `HM_RV.clk) if (!`HM_RV.rst && `HM_RV.l3_retire === 1'b1) rt_n = rt_n + 1;
`endif
  event           win_go;
  reg [8*16-1:0]  win_ev = "";
  integer         win_cyc = 0;
  reg             win_on = 1'b0, win_off = 1'b0;
  reg             win_start_c, win_end_c;
  task win_stats(input [8*16-1:0] ev);
    begin
      win_ev = ev;
      win_cyc = cyc;
      -> win_go;
    end
  endtask
`ifdef RV_HOSTCPU_STATS
  always @(win_go) begin
    #1;
    $display("=== STATS@%0s irefill %0d dread %0d dwrite %0d busy_cycles %0d (rv_hostcpu, to cycle %0d)",
             win_ev, `HM_RV.st_irefill, `HM_RV.st_dread, `HM_RV.st_dwrite, `HM_RV.st_busy, win_cyc);
    $display("=== RETIRED %0d (STATS@%0s, to cycle %0d)", rt_n, win_ev, win_cyc);
  end
`endif

`include "scenarios.vh"

  // frame_close's last call (hostmon.vh): spi_t.txt line, then the scenario
  task hm_frame_hook(input at_end, input logged);
    integer k;
    begin
      if (logged && spi_t_fd != 0) begin
        $fwrite(spi_t_fd, "%0d %0d %h", fr_t_open, cyc, fr_cs);
        for (k = 0; k < fr_n && k < FR_MAX; k = k + 1) $fwrite(spi_t_fd, " %h", fr_out[k]);
        $fwrite(spi_t_fd, " /");
        for (k = 0; k < fr_n && k < FR_MAX; k = k + 1) $fwrite(spi_t_fd, " %h", fr_in[k]);
        $fwrite(spi_t_fd, "\n");
      end
      fr_t_open = cyc;
      // bfm_keys' view of the frame log
      if (logged && fr_cs == 8'h20 && fr_n >= 2 && fr_out[0] == 8'h98) begin
        keys.keyq_st = fr_in[1];
        keys.n_keyq = keys.n_keyq + 1;
      end
      if (logged && fr_cs == 8'h20 && fr_n >= 1 && fr_out[0] == 8'h0c) keys.n_osdwr = keys.n_osdwr + 1;
      if (logged && fr_cs == 8'h20 && fr_n == 1 && fr_out[0] == 8'h00 && kb_held)
        bench_error("an OSD_CMD_READ frame while bfm_keys held a key (the level read saw it)");
      kb_held = 1'b0;
      if (logged && !at_end) sc_frame;
    end
  endtask

  // the STATS windows (above)
  always @(posedge clk114) if (sc_started && !win_off) begin
    win_start_c = 1'b0;
    win_end_c = 1'b0;
    if (scenario == "boot" && boot_end == "") begin win_start_c = 1'b1; win_end_c = sc_done; end
    if (scenario == "fdd_rd") begin win_start_c = fdd.dma_busy; win_end_c = sc_done; end
    if (scenario == "hdd") begin win_start_c = ide.cmd_k >= 1; win_end_c = sc_done; end
    if (scenario == "cdda") begin win_start_c = audio.n_flip >= 2; win_end_c = audio.n_flip >= 6; end
    if (scenario == "keys") begin win_start_c = keys.n_ev >= 1; win_end_c = sc_done; end
    if (!win_on && win_start_c) begin win_on = 1'b1; win_stats("win_start"); end
    else if (win_on && win_end_c) begin win_off = 1'b1; win_stats("win_end"); end
  end

  // ---------------------------------------------------------------- run
  // The run ends 8 cycles after the scenario's end event or at +TIMEOUT.
  event run_go;
  reg   run_end = 1'b0;
  always @(run_go) begin
    wait (sc_done);
    repeat (8) @(posedge clk114);
    run_end = 1'b1;
  end
  always @(run_go) begin
    repeat (timeout) @(posedge clk114);
    if (!run_end) begin
      $display("=== cycle limit %0d reached, scenario %0s did not end", timeout, scenario);
      run_end = 1'b1;
    end
  end

  reg [8*1024-1:0] dump_name;
  integer fast_hw = 0, oe_ok = 0, dump_err0 = 0;
  initial begin
    if (!$value$plusargs("VERBOSE=%d", verbose)) verbose = 0;
    if (!$value$plusargs("TIMEOUT=%d", timeout)) timeout = 3000000;
    if (!$value$plusargs("SOF_CLK7=%d", sof_clk7)) sof_clk7 = 142102;
    if (!$value$plusargs("TICKDIV=%d", tickdiv)) tickdiv = 1;
    tick_at_scen = $test$plusargs("TICKDIV_AT=scenario");
    sd_err_at = $test$plusargs("SD_ERR_AT=scenario");
    if (!$value$plusargs("FAST_HW=%d", fast_hw)) fast_hw = 0;
    if (!$value$plusargs("OSD_EARLY_OK=%d", oe_ok)) oe_ok = 0;
    osd_early_ok = oe_ok != 0;
    if ($value$plusargs("SPI_T_LOG=%s", spi_t_name)) begin
      spi_t_fd = $fopen(spi_t_name, "w");
      if (spi_t_fd == 0) bench_error("+SPI_T_LOG: cannot open the file");
    end
    hm_init;
    mon_init;
    sc_init;
    #1;
    if (sd_err_at) sd_err_hold;
    // (no empty %0s: Verilator prints a space for it, xsim nothing)
    $display("=== CPU rv");
    $display("L3 bench: CPU=rv SCENARIO=%0s SLAT=%0d SJIT=%0d EXTRA_WS=%0d TICKDIV=%0d TICKDIV_AT=%0s SCKDLY=%0.2f C28DLY=%0.2f",
             scenario, ram.slat, ram.sjit, EXTRA_WS, tickdiv, tick_at_scen ? "scenario" : "start",
             sckdly, c28dly);
`ifdef L3_GHDL
    if (`HM_RV.EXTRA_WS != EXTRA_WS)
      bench_error("the converted bridge has another rv_extra_ws than EXTRA_WS");
`endif
    if (fast_hw != 0 && (ram.slat != 2 || ram.sjit != 0 || card.tok_dly != 0 || card.busy_n != 1 || card.ncr != 1))
      bench_error("+FAST_HW=1 but the SD / SDRAM models run another timing (run.sh puts their plusargs first)");
    // resets released at a clk_114 falling edge (tb_host_bridge.v)
    repeat (19) @(posedge clk114);
    @(negedge clk114);
    n_reset = 1'b1;
    repeat (40) @(posedge clk28);
    @(negedge clk114);
    cpu_reset_n = 1'b1;
    @(posedge clk114);
    -> run_go;
    wait (run_end);
    #1;   // the end-of-run counters after the last edge's updates, in every simulator
    if (uart_n) uart_print;
    errors = errors + ram.errors + keys.errors + fdd.errors + aki.errors + ide.errors + audio.errors;
    hm_final_hw;
    card.save_image;
    sdc_final;
    sk_final;
`ifdef RV_HOSTCPU_STATS
    hm_final_stats;
    $display("=== RETIRED %0d (whole run)", rt_n);
`else
    bench_error("built without -DRV_HOSTCPU_STATS (run.sh sets it)");
`endif
    hm_final_fwboot;
    if (spi_t_fd != 0) $fclose(spi_t_fd);
    $display("=== OSD EARLY %0d of %0d reply bytes", oe_n, oe_m);
    or_final;
    if (oe_n > 0)
      $display("=== OSD EARLY (info) first at cycle %0d, command %h, reply byte %0d (0 = the first)",
               oe_first_cyc, oe_first_cmd, oe_first_k);
    if (oe_n > 0 && !osd_early_ok)
      bench_error("OSD EARLY: a reply byte was loaded before the previous one was through the synchroniser");
    if ($value$plusargs("SDRAM_DUMP=%s", dump_name)) begin
      dump_err0 = ram.errors;
      ram.dump(dump_name);
      errors = errors + ram.errors - dump_err0;
    end
    mon_final;
    sc_verdict;
    $finish;
  end

endmodule
