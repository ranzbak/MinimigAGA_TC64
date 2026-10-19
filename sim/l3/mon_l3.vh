// mon_l3.vh: the L3 margin monitors, plan 7.1 items 1, 3, 4, 5, 6, 12 and
// 14 (README "Monitors").  `include"d by tb_l3.v after hostmon.vh (it reads
// hostmon's hw_req_d, hw_done, hwa, spi_data, n_stale, n_hw) and after the
// rtc_model instance rtc1, paula_floppy pf1 and bfm_floppy fdd; mon_final
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
      mon_real("12", "rtc_cs_high", rtc1.n_gaps, rtc1.csh_min_ns, "ns", rtc_csh_bound, rtc_csh_bound <= 0,
               "gaps");
      mon_real("14", "kick_order", (m14_nw > 0) ? m14_nrel : 0, m14_rel - m14_w, "clk_114", 1, 1'b0,
               "releases");
    end
  endtask
