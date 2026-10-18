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

  reg [8*32-1:0]  scenario;
  reg [8*16-1:0]  short_end;
  reg             sc_done = 1'b0;
  integer         sc_fpga = 0;        // HandleFpga frames so far
  reg             sc_ver = 1'b0;      // the OSD_CMD_VERSION frame has closed

  task sc_init;
    begin
      if (!$value$plusargs("SCENARIO=%s", scenario)) scenario = "boot";
      if (!$value$plusargs("SHORT_END=%s", short_end)) short_end = "";
      if (scenario != "boot" && scenario != "boot_short")
        bench_error("unknown +SCENARIO (scenarios.vh)");
      if (short_end != "" && (scenario != "boot_short" || short_end != "version"))
        bench_error("+SHORT_END=version is the only value, and only for boot_short");
    end
  endtask

  // STATS@<event>: the rv_hostcpu counters 1 ns after the end event's
  // clk_114 edge.  rv_hostcpu counts with blocking assignments on that
  // edge, so read in the edge's own time step (sc_frame runs there) they
  // are before or after the edge's increment depending on the simulator's
  // process order (xsim and Verilator differed by one busy cycle).
  reg [8*16-1:0]  sc_ev = "";
  integer         sc_ev_cyc = 0;
  event           sc_stats_go;
  always @(sc_stats_go) begin
    #1;
    $display("=== STATS@%0s irefill %0d dread %0d dwrite %0d busy_cycles %0d (rv_hostcpu, to cycle %0d)",
             sc_ev, `HM_RV.st_irefill, `HM_RV.st_dread, `HM_RV.st_dwrite, `HM_RV.st_busy, sc_ev_cyc);
  end

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
        if (sc_fpga == 1) begin
          $display("=== MAIN first HandleFpga frame at cycle %0d", cyc);
          sc_started = 1'b1;
        end
        if (scenario == "boot" && sc_fpga == 21) sc_end("boot", "HandleFpga frame 20 after the first");
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
