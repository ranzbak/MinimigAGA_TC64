// mon_l3.vh: the L3 margin monitors, plan 7.1 items 1, 3, 4, 5, 12 and 14
// (README "Monitors").  `include"d by tb_l3.v after hostmon.vh (it reads
// hostmon's hw_req_d, hw_done, hwa, spi_data, n_stale, n_hw) and after the
// rtc_model instance rtc1; mon_final prints one line per measurement at the
// end of the run, before the verdict:
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
      mon_real("12", "rtc_cs_high", rtc1.n_gaps, rtc1.csh_min_ns, "ns", rtc_csh_bound, rtc_csh_bound <= 0,
               "gaps");
      mon_real("14", "kick_order", (m14_nw > 0) ? m14_nrel : 0, m14_rel - m14_w, "clk_114", 1, 1'b0,
               "releases");
    end
  endtask
