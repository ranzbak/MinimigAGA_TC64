// L3 scenarios (+SCENARIO=<name>), `include"d by tb_l3.v after hostmon.vh.
// The scenario follows the SPI frame log: sc_frame runs at the close of
// every logged frame (hostmon.vh's frame_close -> tb_l3.v hm_frame_hook),
// with the closed frame in fr_cs / fr_n / fr_out / fr_in / fr_fpga0.
// It sets sc_started at its main-loop milestone (tb_l3.v's TICKDIV_AT) and
// sc_done at its end event; the bench then ends the run and sc_verdict
// prints the one verdict line.  Later tasks add their scenarios here.
//
//   boot        main-loop milestone: the first HandleFpga frame ("10" with six
//               00 bytes); end event: the 20th HandleFpga frame after it
//               ("=== STATS@boot" there).  TIMER: TICKDIV as given (run.sh: 1).
//               +BOOT_END=rtc2: the end event is the close of the second RTC
//               frame (cs 80) instead: HandleRTC() reads the RTC every 8192
//               main-loop passes, so only such a run measures the RTC's CS
//               high time between two transfers (mon_l3.vh item 12)
//   boot_short  the xsim cross-check: boot cut at the end of the first
//               OSD_CMD_READ frame ("20 00", ColdBoot()'s OsdGetKeyLevel()
//               after fpga_init(): boot ROM, firmware load, MMC_Init,
//               LoadConfiguration, fpga_init with the real userio_osd, the
//               BootInit() boot screen and the banner, before the kickstart
//               upload) after the OSD_CMD_VERSION frame; with
//               +SHORT_END=version at the end of the OSD_CMD_VERSION frame.
//               (The plan's cut, the 10th "20 0c" frame after the version
//               frame, does not exist on a card with a kickstart: the boot
//               sends no OSD_CMD_OSD_WR frame at all, README "boot_short".)
//               "=== STATS@boot_short" at the end event.
//   keys        the OSD key script (+KEYS=<file>, bfm_keys.v; run.sh: the
//               boot card, sim/l3/keys/menu_tour.txt): main-loop milestone
//               as boot (the first HandleFpga frame), where the script
//               starts; end event: the script's end ("=== STATS@keys").
//               TIMER: run.sh sets +TICKDIV=643 +TICKDIV_AT=scenario (the
//               firmware's key repeat, help text and message timers run at
//               the board's rate from the script's start)
//   fdd_rd      the floppy read (README "fdd_rd"; run.sh: the fdd card,
//               +KEYS=sim/l3/keys/insert_df0.txt): main-loop milestone as
//               boot, where the key script starts (drive sounds on, TEST.ADF
//               into df0, OSD closed); at its end bfm_floppy reads the
//               tracks of FDD_PLAN below (drive 0, motor on, a seek, the
//               side, one full-track DMA of FDD_WORDS words with sync
//               FDD_SYNC each, dumped to +FDD_DUMP_<cyl>_<head>.hex); end
//               event: the blckint of the last track DMA ("=== STATS@fdd_rd").
//               TIMER: run.sh sets +TICKDIV=643 +TICKDIV_AT=scenario, as
//               keys (fdd.c uses no TIMER, the drive sounds' renderer does)
//   fdd_wr      the floppy write (README "fdd_wr"; run.sh: the fdd card, the
//               key script of fdd_rd, +FDD_WFILE=<run>/fdd_wr, the files
//               sim/l3/gen/mkwrtrack.py made, +SD_SAVE): main-loop milestone
//               and key script as fdd_rd; at its end bfm_floppy writes the
//               tracks of FDD_WPLAN below (drive 0, motor on, a seek, the
//               side, one full-track write DMA of the file's words each);
//               the last one (cylinder 40 head 0) carries a sector with a
//               bad header checksum, fdd.c's FatalError path ("Bad
//               checksum", 26), after which the firmware serves the error
//               page and no more floppy requests (main.c: no HandleFpga
//               while ErrorFatal), so it is the last track; end event: the
//               first OSD row-7 frame (OSD_CMD_OSD_WR, the error page's last
//               row) after the last write's blckint, or, if no error page
//               comes, the 20th HandleFpga frame after it ("=== STATS@fdd_wr").
//               TIMER: as fdd_rd
//   hdd         the hard disk (README "hdd"; run.sh: the hdd card,
//               +IDE_DUMP=<run>/hdd +SD_SAVE=<run>/card_saved.img):
//               main-loop milestone as boot, where bfm_ide starts its plan
//               "hdd" (IDENTIFY, READ / READ MULTIPLE / WRITE / WRITE
//               MULTIPLE on SYNTH.HDF, READ MULTIPLE of RDB.HDF's block 0..15);
//               end event: the end of its last command ("=== STATS@hdd").
//               TIMER: TICKDIV 1 (hdd.c is status-driven)
//   cd          the CD-ROM data path (README "cd"; run.sh: the cd card with
//               +CDCFG=cue or iso, the disc in the drive, +IDE_DUMP=<run>/cd):
//               main-loop milestone as boot, where bfm_ide starts its plan
//               "cd" on IDE port 2 (IDENTIFY PACKET DEVICE, then ATAPI
//               packets: TEST UNIT READY, REQUEST SENSE, INQUIRY, READ
//               CAPACITY, READ TOC, READ(10), READ(12), MODE SENSE, an
//               unsupported command); end event: the end of its last command
//               ("=== STATS@cd").  TIMER: run.sh sets +TICKDIV=643
//               +TICKDIV_AT=scenario (cdrom.c's CD_TIMEOUT at the board's
//               rate; mon_l3.vh item 9)
//   cdda        CD audio (README "cdda"; run.sh: the cd card, CDCFG cue,
//               +IDE_DUMP=<run>/cdda +CDDA_DUMP=<run>/cdda_half): main-loop
//               milestone as boot, where bfm_ide starts its plan "cdda" on
//               IDE port 2 (TEST UNIT READY, PLAY AUDIO MSF of 1.5 s from
//               track 2's start, at the player's 6th flip PAUSE, READ
//               SUB-CHANNEL, RESUME, at the 7th STOP); bfm_audio copies
//               every half the player starts; mon_l3.vh times the refills
//               ("=== CDDA fill").  End event: the end of the STOP command
//               ("=== STATS@cdda").  TIMER: run.sh sets +TICKDIV=643
//               +TICKDIV_AT=scenario (the player takes one frame per tick)
//   cdda_load   cdda on the cdhdd card (the hdd card's HDFs as well), plus
//               from the player's second flip a READ MULTIPLE of 256
//               sectors of SYNTH.HDF ("=== STATS@cdda_load")
//   akiko       the Akiko request service (README "akiko"; run.sh: the fdd
//               card, +KEYS=sim/l3/keys/insert_df0.txt): main-loop milestone
//               as boot, where bfm_akiko runs block 0 (32 write + 32 read
//               requests on cfide's amiga_* window) in the idle main loop;
//               then the key script (TEST.ADF into df0), then bfm_floppy
//               reads FDD_PLAN's first AKIKO_TRACKS tracks, and block 1 starts
//               at the first track DMA's DSKLEN write; end event: block 1 and
//               the last track DMA done ("=== STATS@akiko").  TIMER as fdd_rd

  reg [8*32-1:0]  scenario;
  reg [8*16-1:0]  short_end;
  reg [8*16-1:0]  boot_end;
  reg [8*8-1:0]   cdcfg;              // cd: +CDCFG=cue|iso, the disc (logged for l3check.py)
  integer         sc_rtc = 0;         // RTC frames so far
  reg             sc_done = 1'b0;
  integer         sc_fpga = 0;        // HandleFpga frames so far
  reg             sc_ver = 1'b0;      // the OSD_CMD_VERSION frame has closed

  // fdd_rd: cylinders 0, 1, 2, 39, 40, 41, 77, 78, 79 head 0 and cylinder
  // 79 head 1, in that order (entry k in bits 8k+7..8k: bit 7 the head);
  // each a full-track read of 6,334 words (fdd.c: TRACK_SIZE 12,668 bytes)
  localparam integer FDD_N     = 10;
  localparam integer FDD_WORDS = 6334;
  localparam [15:0]  FDD_SYNC  = 16'h4489;
  localparam integer AKIKO_TRACKS = 2;       // akiko: the plan's first two tracks (cylinders 0, 1 head 0)
  localparam [127:0] FDD_PLAN  = {48'h0, 8'h80 | 8'd79, 8'd79, 8'd78, 8'd77, 8'd41, 8'd40, 8'd39, 8'd2, 8'd1, 8'd0};
  // fdd_wr: the cylinders of fdd_rd, with 40/0 (the bad-header track, see
  // the header) moved to the end: 0, 1, 2, 39, 41, 77, 78, 79 head 0, 79
  // head 1, 40 head 0 (= run.sh FDD_WR_PLAN, l3check.py FDD_WR_TRACKS)
  localparam [127:0] FDD_WPLAN = {48'h0, 8'd40, 8'h80 | 8'd79, 8'd79, 8'd78, 8'd77, 8'd41, 8'd39, 8'd2, 8'd1, 8'd0};
  integer            sc_wfpga = 0;    // fdd_wr: HandleFpga frames after the last write

  task sc_init;
    begin
      if (!$value$plusargs("SCENARIO=%s", scenario)) scenario = "boot";
      if (!$value$plusargs("SHORT_END=%s", short_end)) short_end = "";
      if (!$value$plusargs("BOOT_END=%s", boot_end)) boot_end = "";
      if (!$value$plusargs("CDCFG=%s", cdcfg)) cdcfg = "";
      if (scenario != "boot" && scenario != "boot_short" && scenario != "keys" && scenario != "fdd_rd" &&
          scenario != "fdd_wr" && scenario != "akiko" &&
          scenario != "hdd" && scenario != "cd" && scenario != "cdda" && scenario != "cdda_load")
        bench_error("unknown +SCENARIO (scenarios.vh)");
      if ((scenario == "cd") != (cdcfg == "cue" || cdcfg == "iso"))
        bench_error("scenario cd needs +CDCFG=cue or iso (and only cd takes it)");
      if (scenario == "cd") $display("=== CD config %0s", cdcfg);
      if (short_end != "" && (scenario != "boot_short" || short_end != "version"))
        bench_error("+SHORT_END=version is the only value, and only for boot_short");
      if (boot_end != "" && (scenario != "boot" || boot_end != "rtc2"))
        bench_error("+BOOT_END=rtc2 is the only value, and only for boot");
      if ((scenario == "keys" || scenario == "fdd_rd" || scenario == "fdd_wr" || scenario == "akiko") &&
          !$test$plusargs("KEYS="))
        bench_error("scenarios keys, fdd_rd, fdd_wr and akiko need +KEYS=<key script>");
      if (scenario == "akiko") begin
        fdd.plan_n = AKIKO_TRACKS;
        fdd.plan_words = FDD_WORDS;
        fdd.plan_sync = FDD_SYNC;
        fdd.plan = FDD_PLAN;
      end
      if (scenario == "fdd_rd") begin
        fdd.plan_n = FDD_N;
        fdd.plan_words = FDD_WORDS;
        fdd.plan_sync = FDD_SYNC;
        fdd.plan = FDD_PLAN;
      end
      if (scenario == "fdd_wr") begin
        if (!$test$plusargs("FDD_WFILE=")) bench_error("scenario fdd_wr needs +FDD_WFILE=<prefix of the write files>");
        fdd.plan_n = FDD_N;
        fdd.plan_write = 1'b1;
        fdd.plan = FDD_WPLAN;
      end
    end
  endtask

  // keys: the script starts at the main-loop milestone, ends the scenario
  always @(posedge sc_started) if (scenario == "keys" || scenario == "fdd_rd" || scenario == "fdd_wr") keys.go = 1'b1;
  // akiko: block 0 in the idle main loop, then the key script, the track reads,
  // block 1 from the first track DMA's start
  always @(posedge sc_started) if (scenario == "akiko") aki.go1 = 1'b1;
  always @(posedge aki.b1_done) if (scenario == "akiko") keys.go = 1'b1;
  always @(posedge fdd.dma_busy) if (scenario == "akiko") aki.go2 = 1'b1;
  always @(posedge aki.done or posedge fdd.done)
    if (scenario == "akiko" && aki.done && fdd.done) sc_end("akiko", "block 1 and the last track DMA done");
  always @(posedge keys.done) if (scenario == "keys") sc_end("keys", "the end of the key script");
  // fdd_rd: the track reads start when the key script has ended
  always @(posedge keys.done) if (scenario == "fdd_rd" || scenario == "fdd_wr" || scenario == "akiko") fdd.go = 1'b1;
  always @(posedge fdd.done) if (scenario == "fdd_rd") sc_end("fdd_rd", "the blckint of the last track DMA");
  // hdd: bfm_ide's plan from the main-loop milestone on
  always @(posedge sc_started) if (scenario == "hdd") begin ide.plan = "hdd"; ide.go = 1'b1; end
  always @(posedge ide.done) if (scenario == "hdd") sc_end("hdd", "the end of the last IDE command");
  // cd: bfm_ide's plan cd from the main-loop milestone on
  always @(posedge sc_started) if (scenario == "cd") begin ide.plan = "cd"; ide.go = 1'b1; end
  always @(posedge ide.done) if (scenario == "cd") sc_end("cd", "the end of the last ATAPI command");
  // cdda, cdda_load: bfm_ide's plan of the same name, which follows the
  // player's flips (bfm_audio n_flip, copied into the model)
  always @(posedge sc_started) if (scenario == "cdda" || scenario == "cdda_load") begin
    ide.plan = scenario[8*16-1:0];
    ide.go = 1'b1;
  end
  always @(posedge clk28) ide.cd_flips = audio.n_flip;
  always @(posedge ide.done) if (scenario == "cdda" || scenario == "cdda_load")
    sc_end(scenario[8*16-1:0], "the end of the STOP command");

  // STATS@<event>: the rv_hostcpu counters 1 ns after the end event's
  // clk_114 edge.  rv_hostcpu counts with blocking assignments on that
  // edge, so read in the edge's own time step (sc_frame runs there) they
  // are before or after the edge's increment depending on the simulator's
  // process order (xsim and Verilator differed by one busy cycle).
  reg [8*16-1:0]  sc_ev = "";
  integer         sc_ev_cyc = 0;
  event           sc_stats_go;
  // (CPU=832: no such counters, no STATS@ line)
`ifndef L3_CPU832
  always @(sc_stats_go) begin
    #1;
    $display("=== STATS@%0s irefill %0d dread %0d dwrite %0d busy_cycles %0d (rv_hostcpu, to cycle %0d)",
             sc_ev, `HM_RV.st_irefill, `HM_RV.st_dread, `HM_RV.st_dwrite, `HM_RV.st_busy, sc_ev_cyc);
`ifdef RV_HOSTCPU_STATS
    $display("=== RETIRED %0d (STATS@%0s, to cycle %0d)", rt_n, sc_ev, sc_ev_cyc);
`endif
  end
`endif

  task sc_end(input [8*16-1:0] ev, input [8*80-1:0] what);
    begin
      if (!sc_done) begin
        $display("=== END %0s: %0s at cycle %0d", ev, what, cyc);
        sc_ev = ev;
        sc_ev_cyc = cyc;
        -> sc_stats_go;
        sc_done = 1'b1;
      end
    end
  endtask

  task sc_frame;
    begin
      if (fr_cs == 8'h10 && fr_n == 6 && fr_fpga0) begin
        sc_fpga = sc_fpga + 1;
        m_cdda_loop;
        if (sc_fpga == 1) begin
          $display("=== MAIN first HandleFpga frame at cycle %0d", cyc);
          sc_started = 1'b1;
        end
        if (scenario == "boot" && boot_end == "" && sc_fpga == 21) sc_end("boot", "HandleFpga frame 20 after the first");
        if (scenario == "fdd_wr" && fdd.done) begin
          sc_wfpga = sc_wfpga + 1;
          if (sc_wfpga == 20) sc_end("fdd_wr", "HandleFpga frame 20 after the last write (no error page)");
        end
      end
      if (scenario == "fdd_wr" && fdd.done && fr_cs == 8'h20 && fr_n > 4 && fr_out[0] == 8'h0C &&
          fr_out[1] == 8'h00 && fr_out[2] == 8'h00 && fr_out[3] == 8'h00 && fr_out[4] == 8'h07)
        sc_end("fdd_wr", "OSD row 7 after the last write (the error page)");
      if (fr_cs == 8'h80) begin
        sc_rtc = sc_rtc + 1;
        if (scenario == "boot" && boot_end == "rtc2" && sc_rtc == 2) sc_end("boot", "the second RTC frame");
      end
      if (scenario == "boot_short") begin
        if (sc_ver && fr_cs == 8'h20 && fr_n == 1 && fr_out[0] == 8'h00)
          sc_end("boot_short", "the first OSD_CMD_READ frame after OSD_CMD_VERSION");
        if (!sc_ver && fr_cs == 8'h20 && fr_n > 0 && fr_out[0] == 8'h88) begin
          sc_ver = 1'b1;
          if (short_end == "version") sc_end("boot_short", "the end of the OSD_CMD_VERSION frame");
        end
      end
    end
  endtask

  // one verdict line (after every other end-of-run line)
  task sc_verdict;
    begin
      if (sc_done && errors == 0) $display("=== PASS");
      else if (!sc_done) $display("=== FAIL %0s: end event not reached, bench errors %0d", scenario, errors);
      else $display("=== FAIL %0s: bench errors %0d", scenario, errors);
    end
  endtask
