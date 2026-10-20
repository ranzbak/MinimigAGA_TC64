// mon_l3.vh: the L3 margin monitors, plan 7.1 items 1, 3, 4, 5, 6, 8, 9,
// 12 and 14 (README "Monitors").  `include"d by tb_l3.v after hostmon.vh (it
// reads hostmon's hw_req_d, hw_done, hwa, spi_data, n_stale, n_hw) and after
// the rtc_model instance rtc1, paula_floppy pf1, bfm_floppy fdd, bfm_ide
// ide, gayle gayle1, bfm_audio audio and the tick generator's tickdiv; the
// CD audio ring timing ("=== CDDA" lines, scenarios cdda and cdda_load) is
// the last block before the report; mon_final
// prints one line per measurement at the end of the run, before the
// verdict:
//
//   === MARGIN <item> <name> min <value> <unit> (bound <b>, <verdict>) over <n> <events>
//
// <value> is the smallest one seen.  For the two counts (items 1 and 5) the
// value is the count and LOW means above the bound.  <verdict>:
//   ok    events seen, a bound the value can violate, and it holds
//   LOW   events seen and the bound is violated: a bench error (run FAILS)
//   n/a   no such event in this run (<value> "none"); run.sh fails a
//         scenario that must have the event (MARGIN_REQ_<scenario>)
//   rec   events seen, record only: the value cannot violate its bound
//         (dmode_L: the request always follows the ack; rtc_cs_high with
//         the default bound 0: a gap is never negative)
// Times measured at the slave pins: an sck edge reaches the slaves +SCKDLY
// ns after cfide's pin (tb_l3.v sck_slv); sd_cs reaches them undelayed.
//
//   1  stale_acks          hostmon's stale-ack count (bound 0)
//   3  dmode_release       a direct-mode transfer (sd_cs[6] low): its last
//                          (4096th) sck rising edge at paula to the release
//                          of direct_scs (sd_cs[6] rising), clk_114 cycles;
//                          bound 0 (202e077 latches the word on that edge:
//                          any value >= 0 passes, the figure is recorded)
//      dmode_L             the RDSPI ack (an SPI DATA read acked while sd_cs[6]
//                          is low) to the DisableDMode request (CS write 41),
//                          clk_114 cycles (tb_832_dmode.v's L); rec
//   4  paula_cs_release    per slave: the last sck rising edge of a frame at
//      userio_cs_release   the slave to its select rising (sd_cs[4] paula,
//                          sd_cs[5] userio_osd), clk_114 cycles; bound 0:
//                          neither slave clears anything the last byte /
//                          word needs when its select rises (README)
//      paula_word_spacing  the completion of one received word (paula, its
//      userio_byte_spacing 16th sck edge, sd_cs[4] or [6]) / byte (userio,
//                          8th) to the next one: the clk7 synchroniser
//                          consumes a word up to 40 clk_114 after its last
//                          edge (README), so bound 40
//   5  spi_write_busy      SPI DATA writes acknowledged without starting a
//                          transfer of their own (no SD_busy rise from the
//                          request to the cycle after its ack): the write
//                          was taken while the shifter was busy (bound 0)
//   6  fdd_fifo_empty_dma  floppy read DMA (bfm_floppy): the Agnus disk slots
//                          (one clk_28 cycle each: the clk7_en cycle Agnus
//                          samples dmal in) with paula_floppy's dmaon = 1 and
//                          its FIFO empty, counted per track from the first
//                          slot at which the FIFO has reached the firmware's
//                          working level (fifo_cnt >= 1024, where paula masks
//                          the read request: fdd.c stops sending) to the
//                          track's last word (lenzero); bound 0.  Before that
//                          level the FIFO is filling: the wait for the
//                          firmware's first word and the first lines, where
//                          the three slots of a line come faster than the
//                          SPI delivers (README "fdd_rd").  Per track an
//                          "=== MARGIN (info) 6 fdd track" line: the minimum
//                          fill at the slots of that window, the ramp, and
//                          the brief's literal count (dmaon and empty at a
//                          slot from the starting DSKLEN write on); a track
//                          whose FIFO never reaches 1024 is a bench error
//   8  ide_wait            IDE PIO flow control (bfm_ide): the time the
//                          68k side spent waiting on the firmware, clk_114
//                          cycles, only when it waited: an interrupt not
//                          yet pending, a BSY poll that saw BSY, a data
//                          register read held by nrdy.  Status-driven, no
//                          margin (plan 7.1: latency only costs throughput),
//                          so rec; per command bfm_ide's "=== IDE end" line
//                          has min / median / max (README "hdd")
//   9  cd_timeout_left     ATAPI data phases (scenario cd): each phase window
//                          of gayle's port 1 (IDE port 2, the CD drive's)
//                          runs from the firmware's CMD_IDE_XFER_WR (the
//                          phase set up: hdd_xfer_wr_p) to the end of the
//                          transfer (xfer_done), clk_114 cycles.  cdrom.c's
//                          cd_wait() polls inside it (it starts after the
//                          set-up and, for ISO sectors, after FileReadEx
//                          has filled the FIFO; it sees xfer_done at its
//                          next flag read) and gives up after CD_TIMEOUT =
//                          10000 TIMER counts; one count = 1024 x TICKDIV
//                          clk_114 (58 s at the board's TICKDIV 643).  The
//                          value is that timeout minus the longest window,
//                          bound 0; an "(info) 9" line has the longest
//                          window, in TIMER counts too
//  12  rtc_cs_high         rtc_model: CS-inactive time between two RTC
//                          transfers, ns; bound +RTC_CSH_MIN=<ns>; with the
//                          default 0 (the PCF2123 datasheet is not in
//                          doc/rtc) rec
//  14  kick_order          the last cpurst fall (userio_osd: the Amiga CPU
//                          released) minus the last SDRAM write into the
//                          kickstart region (host 0x100000..0x17ffff),
//                          clk_114 cycles; bound 1 (the write lands first).
//                          Also "=== KICK ..." lines for l3check.py order

  // ------------------------------------------------ request start, shared
  // a new hw request: hw_req rising, or hw_req still high in the cycle after
  // an ack (back to back; hostmon's c28_seen re-arm)
  reg  mn_done_d = 1'b0;
  wire mn_req_start = hw_req && (!hw_req_d || mn_done_d);
  wire spi_csreg = hostaddr[23] && hostaddr[7:4] == 4'hE && hostaddr[3:2] == 2'b01;

  // ------------------------------------------------- item 3: direct mode
  integer m3_edges = 0, m3_n = 0, m3_odd = 0;
  real    m3_t = 0.0, m3_min = 0.0, m3_d = 0.0;
  always @(negedge sd_cs[6]) if (n_reset) m3_edges = 0;
  always @(posedge sd_clk) if (n_reset && sd_cs[6] === 1'b0) begin
    m3_edges = m3_edges + 1;
    m3_t = $realtime;
  end
  always @(posedge sd_cs[6]) if (n_reset && m3_edges > 0) begin
    m3_d = ($realtime - (m3_t + sckdly)) / T114;
    if (m3_n == 0 || m3_d < m3_min) m3_min = m3_d;
    m3_n = m3_n + 1;
    if (m3_edges != 4096) begin
      m3_odd = m3_odd + 1;
      if (m3_odd <= 5)
        $display("=== MARGIN (info) 3 a direct-mode transfer with %0d sck edges (not 4096) at cycle %0d", m3_edges, cyc);
    end
  end

  integer m3_tack = -1, m3_L = 0, m3_Lmin = 0, m3_Ln = 0;
  always @(posedge clk114) if (cpu_reset_n) begin
    if (hw_done && !host_we && spi_data && sd_cs[6] === 1'b0) m3_tack = cyc;
    if (mn_req_start && host_we && spi_csreg && hostWR[7:0] == 8'h41 && m3_tack >= 0) begin
      m3_L = cyc - m3_tack;
      if (m3_Ln == 0 || m3_L < m3_Lmin) m3_Lmin = m3_L;
      m3_Ln = m3_Ln + 1;
      m3_tack = -1;
    end
  end

  // ------------------------------------------- item 4: per-slave CS release
  integer m4p_edges = 0, m4u_edges = 0, m4p_n = 0, m4u_n = 0;
  real    m4p_t = 0.0, m4u_t = 0.0, m4p_min = 0.0, m4u_min = 0.0, m4_d = 0.0;
  always @(negedge sd_cs[4]) if (n_reset) m4p_edges = 0;
  always @(negedge sd_cs[5]) if (n_reset) m4u_edges = 0;
  always @(posedge sd_clk) if (n_reset) begin
    if (sd_cs[4] === 1'b0) begin m4p_edges = m4p_edges + 1; m4p_t = $realtime; end
    if (sd_cs[5] === 1'b0) begin m4u_edges = m4u_edges + 1; m4u_t = $realtime; end
  end
  always @(posedge sd_cs[4]) if (n_reset && m4p_edges > 0) begin
    m4_d = ($realtime - (m4p_t + sckdly)) / T114;
    if (m4p_n == 0 || m4_d < m4p_min) m4p_min = m4_d;
    m4p_n = m4p_n + 1;
  end
  always @(posedge sd_cs[5]) if (n_reset && m4u_edges > 0) begin
    m4_d = ($realtime - (m4u_t + sckdly)) / T114;
    if (m4u_n == 0 || m4_d < m4u_min) m4u_min = m4_d;
    m4u_n = m4u_n + 1;
  end

  // item 4: word / byte completion spacing at the slave (the delays cancel).
  // paula counts the bits of _scs (sd_cs[4]) and direct_scs (sd_cs[6])
  // frames in one counter (its spi_bit_cnt, reset while neither is
  // selected); the frame numbers below restart the counts.
  integer m4p_fid = 0, m4u_fid = 0, m4p_bid = -1, m4u_bid = -1;
  integer m4p_bits = 0, m4u_bits = 0, m4p_wn = 0, m4u_wn = 0;
  real    m4p_wt = -1.0, m4u_wt = -1.0, m4p_wmin = 0.0, m4u_wmin = 0.0, m4_s = 0.0;
  always @(negedge sd_cs[4] or negedge sd_cs[6]) if (n_reset) m4p_fid = m4p_fid + 1;
  always @(negedge sd_cs[5]) if (n_reset) m4u_fid = m4u_fid + 1;
  always @(posedge sd_clk) if (n_reset) begin
    if (sd_cs[4] === 1'b0 || sd_cs[6] === 1'b0) begin
      if (m4p_bid != m4p_fid) begin m4p_bid = m4p_fid; m4p_bits = 0; end
      m4p_bits = m4p_bits + 1;
      if (m4p_bits % 16 == 0) begin
        if (m4p_wt >= 0.0) begin
          m4_s = ($realtime - m4p_wt) / T114;
          if (m4p_wn == 0 || m4_s < m4p_wmin) m4p_wmin = m4_s;
          m4p_wn = m4p_wn + 1;
        end
        m4p_wt = $realtime;
      end
    end
    if (sd_cs[5] === 1'b0) begin
      if (m4u_bid != m4u_fid) begin m4u_bid = m4u_fid; m4u_bits = 0; end
      m4u_bits = m4u_bits + 1;
      if (m4u_bits % 8 == 0) begin
        if (m4u_wt >= 0.0) begin
          m4_s = ($realtime - m4u_wt) / T114;
          if (m4u_wn == 0 || m4_s < m4u_wmin) m4u_wmin = m4_s;
          m4u_wn = m4u_wn + 1;
        end
        m4u_wt = $realtime;
      end
    end
  end

  // ------------------------------------- item 5: DATA write while SD_busy
  reg     m5_open = 1'b0, m5_rose = 1'b0, m5_chk = 1'b0, m5_busy_d = 1'b0, m5_rise = 1'b0;
  integer m5_n = 0, m5_w = 0;
  always @(posedge clk114) if (cpu_reset_n) begin
    m5_rise = `HM_SD_BUSY === 1'b1 && m5_busy_d !== 1'b1;
    if (m5_chk) begin          // the cycle after a DATA write's ack
      if (m5_rise) m5_rose = 1'b1;
      if (!m5_rose) begin
        m5_n = m5_n + 1;
        if (m5_n <= 5)
          $display("=== MARGIN (info) 5 an SPI DATA write acknowledged at cycle %0d started no transfer", cyc - 1);
      end
      m5_chk = 1'b0;
    end
    if (mn_req_start && host_we && spi_data) begin m5_open = 1'b1; m5_rose = 1'b0; end
    if (m5_open && m5_rise) m5_rose = 1'b1;
    if (m5_open && hw_done) begin m5_open = 1'b0; m5_chk = 1'b1; m5_w = m5_w + 1; end
    m5_busy_d = `HM_SD_BUSY;
    mn_done_d <= hw_done;      // non-blocking: every block of this edge sees the old value
  end

  // ------------------------------------------------- item 6: floppy FIFO
  // sampled in the middle of the clk_28 cycle before the clk7 edge (the
  // slot's cycle, clk7_en = 1): paula_floppy's state is stable there.  The
  // slot is checked before this cycle's first FIFO write is noted, so the
  // window starts with the next slot.
  integer m6_n = 0, m6_slots = 0, m6_lit_all = 0, m6_seen = 0, m6_min_all = 4096, m6_tracks = 0;
  integer m6_tn = 0, m6_tslots = 0, m6_tmin = 4096, m6_ramp = 0, m6_ramp_e = 0, m6_lit = 0;
  integer m6_c_first = 0, m6_c_full = 0;
  reg     m6_open = 1'b0, m6_first = 1'b0, m6_full = 1'b0;
  always @(negedge clk28) if (n_reset && clk7_en === 1'b1) begin
    if (fdd.n_dma != m6_seen) begin              // a track DMA has started
      m6_seen = fdd.n_dma;
      m6_open = 1'b1; m6_first = 1'b0; m6_full = 1'b0;
      m6_tn = 0; m6_tslots = 0; m6_tmin = 4096; m6_ramp = 0; m6_ramp_e = 0; m6_lit = 0;
    end
    if (m6_open && fdd.slot) begin
      if (pf1.dmaon === 1'b1 && pf1.fifo_empty === 1'b1) m6_lit = m6_lit + 1;
      if (m6_full) begin
        m6_tslots = m6_tslots + 1;
        if ({20'd0, pf1.fifo_cnt} < m6_tmin) m6_tmin = {20'd0, pf1.fifo_cnt};
        if (pf1.dmaon === 1'b1 && pf1.fifo_empty === 1'b1) m6_tn = m6_tn + 1;
      end else if (m6_first) begin
        m6_ramp = m6_ramp + 1;
        if (pf1.fifo_empty === 1'b1) m6_ramp_e = m6_ramp_e + 1;
      end
    end
    if (m6_open && !m6_first && pf1.fifo_wr === 1'b1) begin m6_first = 1'b1; m6_c_first = cyc; end
    if (m6_open && m6_first && !m6_full && pf1.fifo_cnt >= 12'd1024) begin m6_full = 1'b1; m6_c_full = cyc; end
    if (m6_open && m6_first && pf1.lenzero === 1'b1) begin
      m6_open = 1'b0;
      m6_tracks = m6_tracks + 1;
      m6_n = m6_n + m6_tn;
      m6_slots = m6_slots + m6_tslots;
      m6_lit_all = m6_lit_all + m6_lit;
      if (m6_full && m6_tmin < m6_min_all) m6_min_all = m6_tmin;
      if (m6_full)
        $display("=== MARGIN (info) 6 fdd track %0d/%0d: fifo min %0d words over %0d slots from cycle %0d, %0d empty; ramp from the first word (cycle %0d) %0d slots, %0d empty; literal count %0d",
                 fdd.cur_cyl, fdd.cur_head, m6_tmin, m6_tslots, m6_c_full, m6_tn, m6_c_first, m6_ramp, m6_ramp_e, m6_lit);
      else begin
        $display("=== MARGIN (info) 6 fdd track %0d/%0d: the FIFO never reached 1024 words (ramp from cycle %0d: %0d slots, %0d empty)",
                 fdd.cur_cyl, fdd.cur_head, m6_c_first, m6_ramp, m6_ramp_e);
        bench_error("MARGIN 6: a track's FIFO never reached the firmware's working level (1024 words)");
      end
    end
  end

  // ----------------------------------------------- item 14: kickstart order
  integer m14_w = -1, m14_nw = 0, m14_rel = -1, m14_nrel = 0;
  reg [31:0] m14_a = 32'h0;
  reg        m14_hi = 1'b0;        // cpurst has been 1
  always @(posedge clk114) if (ram_req === 1'b1 && ram_ack === 1'b1 && host_we === 1'b1 &&
                               hwa >= 32'h00100000 && hwa < 32'h00180000) begin
    m14_w = cyc;
    m14_a = hwa;
    m14_nw = m14_nw + 1;
  end
  always @(posedge cpurst) if (n_reset && cpurst === 1'b1) m14_hi = 1'b1;
  always @(negedge cpurst) if (n_reset && cpurst === 1'b0 && m14_hi) begin
    m14_rel = cyc;
    m14_nrel = m14_nrel + 1;
    $display("=== KICK cpurst falls at cycle %0d (last kickstart-region SDRAM write so far: cycle %0d)", cyc, m14_w);
  end

  // ------------------------------------------------- item 9: CD phases
  // sampled on the falling clk_28 edge before the rising one where gayle
  // samples (clk7_en): the values gayle_port.v acts on
  localparam integer CD_TIMEOUT = 10000;   // fw/ctrl_rv/cdrom.c (and fw/ctrl_832): TIMER counts
  integer m9_n = 0, m9_t0 = 0, m9_max = 0, m9_maxat = 0;
  reg     m9_open = 1'b0;
  always @(negedge clk28) if (clk7_en === 1'b1) begin
    if (gayle1.g_port1.PORT1.hdd_xfer_wr_p === 1'b1) begin
      m9_t0 = cyc;
      m9_open = 1'b1;
    end else if (m9_open && gayle1.g_port1.PORT1.xfer_done === 1'b1) begin
      if (m9_n == 0 || cyc - m9_t0 > m9_max) begin
        m9_max = cyc - m9_t0;
        m9_maxat = cyc;
      end
      m9_n = m9_n + 1;
      m9_open = 1'b0;
    end
  end

  // ---------------------------------------- CD audio ring timing (cdda)
  // Only with bfm_audio's +CDDA_DUMP (scenarios cdda, cdda_load; README
  // "cdda").  An SDRAM write into the ring is a write acknowledged at host
  // 0x70000..0x7ffff (as item 14); its half is address bit 15.
  //   fill <n>   from flip n (bfm_audio n_flip; seen here up to 4 clk_114
  //              after the clk_28 edge) to the firmware's last write into
  //              the half that is now free (the other one than the player's),
  //              before the next flip or the player's stop (PAUSE, STOP: the
  //              AUDIO write that takes audio_ena low or audio_clear high);
  //              one line when the window closes:
  //   === CDDA fill <n> start <cycle> done <cycle> (<ms> ms at 113.4375 MHz), <w> writes into ring half <h>, until the <next flip|stop>
  //              ("done none" when the firmware wrote nothing into it)
  //   start fill a run's own fill (cdaudio.c run(): CLEAR, both halves,
  //              ENA): the ring writes from the CLEAR to the player's start
  //   === CDDA start fill run <r>: <w> ring writes from cycle <a> to <b> (<ms> ms), the player starts at cycle <c>
  //   main loop  the time between two HandleFpga frames (scenarios.vh's
  //              main-loop frame: cs 10, six 00 bytes) while the player
  //              runs: one pass of main()'s loop, refills and served IDE
  //              commands included
  //   writes into the playing half: the firmware's underrun response
  //              (cdaudio.c cda_poll: the late half is zeroed) or a defect;
  //              0 when every refill was in time
  // mon_final prints min / median (the lower one) / max of the fills and of
  // the main-loop gaps.
  localparam [31:0]  MC_RING = 32'h00070000;
  localparam integer MC_FMAX = 256;          // fills kept
  localparam integer MC_LMAX = 262144;       // main-loop gaps kept
  real    MC_MHZ = 113.4375;                 // clk_114 (T114 = 8.8154 ns)
  integer mc_fill [0:MC_FMAX-1];
  integer mc_gap  [0:MC_LMAX-1];
  integer mc_n = 0, mc_none = 0, mc_flip = 0, mc_t0 = 0, mc_last = -1, mc_w = 0, mc_pw = 0;
  integer mc_s_t0 = -1, mc_s_last = -1, mc_s_w = 0, mc_run = 0;
  integer ml_n = 0, ml_prev = -1, ml_max = 0, ml_maxat = 0;
  reg     mc_open = 1'b0, mc_free = 1'b0, mc_play_d = 1'b0, mc_clear_d = 1'b0;
  wire    mc_play = audio_ena === 1'b1 && audio_clear === 1'b0;
  wire    mc_ringw = ram_req === 1'b1 && ram_ack === 1'b1 && host_we === 1'b1 &&
                     hwa >= MC_RING && hwa < MC_RING + 32'h00010000;

  task mc_close(input stop);
    begin
      mc_open = 1'b0;
      if (mc_last >= 0) begin
        if (mc_n < MC_FMAX) mc_fill[mc_n] = mc_last - mc_t0;
        mc_n = mc_n + 1;
        $display("=== CDDA fill %0d start %0d done %0d (%0.3f ms at 113.4375 MHz), %0d writes into ring half %0d, until the %0s",
                 mc_flip, mc_t0, mc_last, (mc_last - mc_t0) / (MC_MHZ * 1000.0), mc_w, mc_free, stop ? "stop" : "next flip");
      end else begin
        mc_none = mc_none + 1;
        $display("=== CDDA fill %0d start %0d done none (no write into ring half %0d), until the %0s",
                 mc_flip, mc_t0, mc_free, stop ? "stop" : "next flip");
      end
    end
  endtask

  always @(posedge clk114) if (cpu_reset_n && audio.dump_on) begin
    if (mc_open && !mc_play) mc_close(1'b1);
    if (mc_open && audio.n_flip != mc_flip) mc_close(1'b0);
    if (mc_play && audio.n_flip != mc_flip) begin
      mc_flip = audio.n_flip;
      mc_open = 1'b1;
      mc_t0 = cyc;
      mc_last = -1;
      mc_w = 0;
      mc_free = !aud_addr[15];
    end
    if (audio_clear === 1'b1 && !mc_clear_d) begin mc_s_t0 = -1; mc_s_last = -1; mc_s_w = 0; end
    if (mc_ringw) begin
      if (mc_open && hwa[15] == mc_free) begin
        mc_last = cyc;
        mc_w = mc_w + 1;
      end else if (mc_play) begin
        mc_pw = mc_pw + 1;
        if (mc_pw <= 5)
          $display("=== CDDA (info) a write into the playing half %0d at cycle %0d (host %h)", aud_addr[15], cyc, hwa);
      end else begin
        if (mc_s_t0 < 0) mc_s_t0 = cyc;
        mc_s_last = cyc;
        mc_s_w = mc_s_w + 1;
      end
    end
    if (mc_play && !mc_play_d) begin
      if (mc_s_t0 >= 0)
        $display("=== CDDA start fill run %0d: %0d ring writes from cycle %0d to %0d (%0.3f ms), the player starts at cycle %0d",
                 mc_run, mc_s_w, mc_s_t0, mc_s_last, (mc_s_last - mc_s_t0) / (MC_MHZ * 1000.0), cyc);
      else
        $display("=== CDDA start fill run %0d: no ring write since the CLEAR, the player starts at cycle %0d", mc_run, cyc);
      mc_run = mc_run + 1;
      mc_s_t0 = -1; mc_s_last = -1; mc_s_w = 0;
    end
    mc_play_d = mc_play;
    mc_clear_d = audio_clear === 1'b1;
  end

  // scenarios.vh sc_frame, at the close of every main-loop frame
  task m_cdda_loop;
    begin
      if (audio.dump_on && mc_play) begin
        if (ml_prev >= 0) begin
          if (ml_n < MC_LMAX) mc_gap[ml_n] = cyc - ml_prev;
          if (ml_n == 0 || cyc - ml_prev > ml_max) begin ml_max = cyc - ml_prev; ml_maxat = cyc; end
          ml_n = ml_n + 1;
        end
        ml_prev = cyc;
      end else
        ml_prev = -1;
    end
  endtask

  // min / lower median / max of the first n kept values of mc_fill (which 0)
  // or mc_gap (which 1), the median by binary search as bfm_ide.v's
  integer mc_r_min, mc_r_med, mc_r_max;
  task mc_stats(input which, input integer n_all);
    integer lo, hi, mid, c, i, n, x;
    begin
      n = which ? ((n_all < MC_LMAX) ? n_all : MC_LMAX) : ((n_all < MC_FMAX) ? n_all : MC_FMAX);
      mc_r_min = 0; mc_r_max = 0;
      for (i = 0; i < n; i = i + 1) begin
        x = which ? mc_gap[i] : mc_fill[i];
        if (i == 0 || x < mc_r_min) mc_r_min = x;
        if (i == 0 || x > mc_r_max) mc_r_max = x;
      end
      lo = mc_r_min; hi = mc_r_max;
      while (lo < hi) begin
        mid = lo + (hi - lo) / 2;
        c = 0;
        for (i = 0; i < n; i = i + 1) if ((which ? mc_gap[i] : mc_fill[i]) <= mid) c = c + 1;
        if (c >= (n + 1) / 2) hi = mid; else lo = mid + 1;
      end
      mc_r_med = lo;
    end
  endtask

  task mc_final;
    begin
      if (audio.dump_on) begin
        if (mc_open) mc_close(1'b1);
        if (mc_n > 0) begin
          mc_stats(1'b0, mc_n);
          $display("=== CDDA fills %0d (%0d without a write): min/median/max %0.3f/%0.3f/%0.3f ms = %0d/%0d/%0d clk_114",
                   mc_n, mc_none, mc_r_min / (MC_MHZ * 1000.0), mc_r_med / (MC_MHZ * 1000.0), mc_r_max / (MC_MHZ * 1000.0),
                   mc_r_min, mc_r_med, mc_r_max);
        end else
          $display("=== CDDA fills 0 (%0d without a write)", mc_none);
        if (ml_n > 0) begin
          mc_stats(1'b1, ml_n);
          $display("=== CDDA main loop while playing: %0d gaps, min/median/max %0.3f/%0.3f/%0.3f ms = %0d/%0d/%0d clk_114, the longest ending at cycle %0d",
                   ml_n, mc_r_min / (MC_MHZ * 1000.0), mc_r_med / (MC_MHZ * 1000.0), mc_r_max / (MC_MHZ * 1000.0),
                   mc_r_min, mc_r_med, mc_r_max, ml_maxat);
        end else
          $display("=== CDDA main loop while playing: 0 gaps");
        if (ml_n > MC_LMAX) bench_error("CDDA: more main-loop gaps than MC_LMAX (the median is of the first MC_LMAX)");
        if (mc_n > MC_FMAX) bench_error("CDDA: more fills than MC_FMAX (the median is of the first MC_FMAX)");
        $display("=== CDDA writes into the playing half: %0d", mc_pw);
      end
    end
  endtask

  // ------------------------------------------------------------- report
  integer rtc_csh_bound = 0;       // +RTC_CSH_MIN=<ns>

  // the verdict of a line with n events (see the header); LOW is a bench error
  function [8*3-1:0] mon_verdict(input integer n, input rec, input low);
    mon_verdict = (n == 0) ? "n/a" : rec ? "rec" : low ? "LOW" : "ok";
  endfunction

  task mon_real(input [8*4-1:0] item, input [8*24-1:0] name, input integer n, input real v,
                input [8*8-1:0] unit, input integer bound, input rec, input [8*24-1:0] what);
    begin
      if (n == 0)
        $display("=== MARGIN %0s %0s min none %0s (bound %0d, n/a) over 0 %0s", item, name, unit, bound, what);
      else
        $display("=== MARGIN %0s %0s min %0.1f %0s (bound %0d, %0s) over %0d %0s", item, name, v, unit, bound,
                 mon_verdict(n, rec, v < bound), n, what);
      if (n > 0 && !rec && v < bound) bench_error("MARGIN below its bound (the LOW line)");
    end
  endtask

  task mon_count(input [8*4-1:0] item, input [8*24-1:0] name, input integer v, input integer bound,
                 input integer n, input [8*24-1:0] what);
    begin
      $display("=== MARGIN %0s %0s min %0d count (bound %0d, %0s) over %0d %0s", item, name, v, bound,
               mon_verdict(n, 1'b0, v > bound), n, what);
      if (n > 0 && v > bound) bench_error("MARGIN count above its bound (the LOW line)");
    end
  endtask

  task mon_init;
    begin
      if (!$value$plusargs("RTC_CSH_MIN=%d", rtc_csh_bound)) rtc_csh_bound = 0;
    end
  endtask

  task mon_final;
    begin
      mc_final;
      rtc1.report;
      if (m14_nw > 0)
        $display("=== KICK last SDRAM write into the kickstart region at cycle %0d (host %h), %0d writes", m14_w, m14_a, m14_nw);
      else
        $display("=== KICK last SDRAM write into the kickstart region at cycle none, 0 writes");
      mon_count("1", "stale_acks", n_stale, 0, n_hw, "hw accesses");
      mon_real("3", "dmode_release", m3_n, m3_min, "clk_114", 0, 1'b0, "direct transfers");
      mon_real("3", "dmode_L", m3_Ln, m3_Lmin, "clk_114", 0, 1'b1, "direct transfers");
      mon_real("4", "paula_cs_release", m4p_n, m4p_min, "clk_114", 0, 1'b0, "frames");
      mon_real("4", "userio_cs_release", m4u_n, m4u_min, "clk_114", 0, 1'b0, "frames");
      mon_real("4", "paula_word_spacing", m4p_wn, m4p_wmin, "clk_114", 40, 1'b0, "words");
      mon_real("4", "userio_byte_spacing", m4u_wn, m4u_wmin, "clk_114", 40, 1'b0, "bytes");
      mon_count("5", "spi_write_busy", m5_n, 0, m5_w, "DATA writes");
      mon_count("6", "fdd_fifo_empty_dma", m6_n, 0, m6_slots, "DMA slots");
      if (m6_tracks > 0)
        $display("=== MARGIN (info) 6 fdd %0d tracks: fifo min %0d words at the working level; literal count %0d slots (dmaon and empty from the starting DSKLEN write)",
                 m6_tracks, m6_min_all, m6_lit_all);
      mon_real("8", "ide_wait", ide.w_all_n, ide.w_all_min, "clk_114", 0, 1'b1, "waits");
      if (m9_n > 0)
        $display("=== MARGIN (info) 9 cd longest phase window %0d clk_114 = %0.3f TIMER counts at TICKDIV %0d (CD_TIMEOUT %0d counts = %0.0f clk_114), ended at cycle %0d, over %0d phases%0s",
                 m9_max, m9_max / (1024.0 * tickdiv), tickdiv, CD_TIMEOUT, CD_TIMEOUT * 1024.0 * tickdiv, m9_maxat,
                 m9_n, m9_open ? "; one window still open at the end" : "");
      mon_real("9", "cd_timeout_left", m9_n, CD_TIMEOUT * 1024.0 * tickdiv - m9_max, "clk_114", 0, 1'b0, "phases");
      mon_real("12", "rtc_cs_high", rtc1.n_gaps, rtc1.csh_min_ns, "ns", rtc_csh_bound, rtc_csh_bound <= 0,
               "gaps");
      mon_real("14", "kick_order", (m14_nw > 0) ? m14_nrel : 0, m14_rel - m14_w, "clk_114", 1, 1'b0,
               "releases");
    end
  endtask
