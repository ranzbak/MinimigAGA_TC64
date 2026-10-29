// The SPI path between the OSD host CPU and the Minimig SPI slaves, driven
// the way the firmware drives it, at the speed it drives it.
//
//   host bus model --> cfide.vhd (the SPI master: sck is a clk_114 register)
//                        |  SPI_SCK / SPI_DI / SPI_CS[7:0]
//                        v
//                      paula_floppy (HDF sector data, both directions)
//                      userio_osd   (OSD commands and replies)
//                      SD card model (direct mode: card -> paula, 4096 bits)
//
// The slaves are clocked by sck, the Minimig logic around them by clk_28.
// In hardware sck reaches the slaves through fabric routing some ns after
// the clk_114 edge that toggled it, and where a clk_28 edge lands relative to
// that is a per-build accident.  The bench models it with two delays:
//
//   +SCKDLY=<ns>  sck at the slaves, after the cfide register (clock insertion)
//   +C28DLY=<ns>  clk_28 after the clk_114 edge it is derived from
//
// so a crossing that only works for one ordering of the two edges shows up as
// a failure for some (SCKDLY, C28DLY) pair.
//
// The CPU side is modelled by its bus latency: +GAP=<n> is the number of
// clk_114 cycles between one access's ack and the next access's request
// (instruction fetch, cache, bridge -- everything the CPU does in between).
// Each sector is run for every gap in the GAPS list with a random extra
// 0..3 cycles per access and a random start phase, so the sck edges move
// against clk_28 / clk7_en from sector to sector.
//
// Checks, per sector:
//   wr     CMD_IDE_DATA_WR + 512 bytes (hdd.c, FakeRDB / buffered read):
//          the 256 words the gayle model received equal what was sent
//   rd     CMD_IDE_DATA_RD + 512 bytes read (hdd.c, HDF write): the bytes the
//          host read equal the gayle model's buffer
//   direct MMC_ReadMultiple's direct mode (mmc.c): EnableDMode, SPI(0xFF)
//          (4096 clocks), RDSPI, DisableDMode -- the 256 words the gayle
//          model received equal the card's sector
//   osd    OSD_CMD_VERSION + 10 reply bytes: equal a reference read done
//          with a slow host
//   xframe (+TESTS bit 16, not in the default mask) the cross-frame case: a
//          3-byte OSD_CMD_OSD_WR frame (0c 00 00), CS up and down again at
//          gap 2, then osd's VERSION read; its 10 bytes equal the reference
//
// +RDY=1: the OSD reply-ready handshake (cfide HOST_REQ 0x0fffffb4, bit 0
// OSD_RDY = cfide's count of OSD bytes started equals userio_osd's
// osd_rx_seq).  Before each OSD reply byte (osd and xframe) the bus model
// reads HOST_REQ until bit 0 is 1, each read an ordinary bus access with the
// same gap; a poll that has not ended after 100000 clk_114 cycles ends the run
// with "=== FAIL (watchdog ...)".  The firmware's way from Phase 4 Task 11 on.
// cfide's osd_rx_seq input is this bench's userio_osd output.  With RDY the
// bench prints per gap how many HOST_REQ reads it made and how many of them
// read 0, and for xframe in how many runs the OSD_WR frame's last byte was
// still not taken when the VERSION frame's command byte started (the case
// the count exists for; the bench fails if that never happens in a run with
// xframe).
//
// Result lines:  "GAP <g> <test> fail <n>/<m>" and a final "=== PASS"/"=== FAIL".
//
// +SPEED=<n> sets the SPI speed register (firmware SPI_fast() = 1).
// +OSD_MIN_GAP=<n>: gaps below this are reported for osd but not counted as
// a failure (default 40, the OSD reply latency -- see the comment at the
// plusarg).  +TESTS=<mask>, +GAPMAX=<n>, +DEBUG=1 narrow a run down.

`timescale 1ns/1ps

module tb_spi_cdc;

  // ---------------------------------------------------------------- params
  real    T114    = 8.8154;          // 113.4375 MHz
  real    sckdly  = 1.5;
  real    c28dly  = 0.3;
  integer speed   = 1;
  integer seed    = 1;
  integer reps    = 3;
  integer osd_min_gap = 0;
  integer tests_mask = 15;           // 1 wr, 2 rd, 4 direct, 8 osd, 16 xframe
  integer rdy = 0;                   // +RDY=1: poll HOST_REQ before each OSD reply byte
  integer gapmax = 1000;
  integer debug = 0;

  // ---------------------------------------------------------------- clocks
  reg clk114 = 1'b0;
  always #(T114/2.0) clk114 = ~clk114;

  reg [1:0] div = 2'd0;
  reg clk28 = 1'b0;
  always @(posedge clk114) begin
    div <= div + 2'd1;
    if (div == 2'd0) clk28 <= #(c28dly) 1'b1;
    if (div == 2'd2) clk28 <= #(c28dly) 1'b0;
  end

  // clk7_en / clk7n_en exactly as rtl/clock/amiga_clk.v makes them
  reg [1:0] clk7_cnt = 2'b10;
  reg clk7_en = 1'b1, clk7n_en = 1'b1;
  always @(posedge clk28) begin
    clk7_cnt <= clk7_cnt + 2'b01;
    clk7_en  <= #1 (clk7_cnt == 2'b00);
    clk7n_en <= #1 (clk7_cnt == 2'b10);
  end

  reg n_reset = 1'b0;
  reg mm_reset = 1'b1;

  integer cyc = 0;                   // clk_114 cycles (the RDY watchdog)
  always @(posedge clk114) cyc <= cyc + 1;

  // ---------------------------------------------------------------- cfide
  reg  [31:2] addr = 30'd0;
  reg  [15:0] d    = 16'd0;
  reg         req  = 1'b0;
  reg         wr   = 1'b0;
  wire [15:0] q;
  wire        ack;

  wire [7:0]  spi_cs;
  wire        spi_sck;      // cfide sd_clk (= NOT its sck register)
  wire        spi_di;       // MOSI
  wire        spi_do;       // MISO from the Minimig slaves
  wire        sd_miso;      // the card's DO pin
  wire [1:0]  osd_rx_seq;   // userio_osd's reply sequence (clk_28) -> cfide

  cfide #(
    .spimux(1'b0), .havespirtc(1'b0), .havei2c(1'b0), .havevpos(1'b0)
  ) mycfide (
    .sysclk(clk114), .n_reset(n_reset),
    .addr(addr), .d(d), .q(q), .req(req), .wr(wr), .ack(ack),
    .sd_di(spi_do), .sd_cs(spi_cs), .sd_clk(spi_sck), .sd_do(spi_di),
    .sd_dimm(sd_miso), .sd_ack(1'b1),
    .debugTxD(), .debugRxD(1'b1), .menu_button(1'b1),
    .xadc_temp(16'h0000),
    .scandoubler(), .audio_ena(), .audio_clear(),
    .audio_buf(1'b0), .audio_amiga(1'b0), .vbl_int(1'b0), .interrupt(),
    .c64_keys(64'hFFFFFFFFFFFFFFFF), .amiga_key(), .amiga_key_stb(),
    .amiga_addr(8'h00), .amiga_d(16'h0000), .amiga_q(),
    .amiga_req(1'b0), .amiga_wr(1'b0), .amiga_ack(),
    .rtc_q(),
    .scl_i(1'b1), .scl_o(), .scl_t(), .sda_i(1'b1), .sda_o(), .sda_t(),
    .i2c_ext_int(1'b0),
    .pos_data_q(),
    .osd_rx_seq(osd_rx_seq),
    .clk_28(clk28), .tick_in(1'b0)
  );

  // sck as the slaves see it: the cfide register plus clock routing
  reg sck_slv = 1'b1;
  always @(spi_sck) sck_slv <= #(sckdly) spi_sck;

  // minimig_virtual_top: _scs = {SPI_CS[6], SPI_CS[5], SPI_CS[4]}
  wire paula_sdo, user_sdo;
  assign spi_do = paula_sdo | user_sdo;

  // ---------------------------------------------------------------- paula_floppy
  wire [15:0] hdd_data_out;
  wire [15:0] hdd_data_in;
  wire        hdd_data_wr, hdd_data_rd, hdd_wr, hdd_status_wr;
  wire [2:0]  hdd_addr;

  paula_floppy pf1 (
    .clk(clk28), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
    .reset(mm_reset), .ntsc(1'b0), .sof(1'b0), .enable(1'b0),
    .reg_address_in(8'h00), .data_in(16'h0000), .data_out(),
    .dmal(), .dmas(),
    ._step(1'b1), .direc(1'b0), ._sel(4'hF), .side(1'b0), ._motor(1'b1),
    ._track0(), ._change(), ._ready(), ._wprot(), .index(),
    .blckint(), .syncint(), .wordsync(1'b0),
    ._scs(spi_cs[4]), .sdi(spi_di), .sdo(paula_sdo), .sck(sck_slv),
    .disk_led(), .floppy_drives(2'b00),
    .direct_scs(~spi_cs[6]), .direct_sdi(sd_miso),
    .hdd_cmd_req(1'b0), .hdd_dat_req(1'b0),
    .hdd_addr(hdd_addr), .hdd_data_out(hdd_data_out), .hdd_data_in(hdd_data_in),
    .hdd_wr(hdd_wr), .hdd_status_wr(hdd_status_wr),
    .hdd_data_wr(hdd_data_wr), .hdd_data_rd(hdd_data_rd),
    .trackdisp(), .secdisp(), .floppy_fwr(), .floppy_frd()
  );

  // ---------------------------------------------------------------- gayle model
  // The sector FIFO side of gayle.v / gayle_fifo.v: words are written and the
  // read pointer advanced on clk7_en, data_out is registered from the OLD
  // read pointer, exactly as gayle_fifo does it.
  reg [15:0] g_rx [0:1023];
  integer    g_rx_n = 0;
  reg [15:0] g_tx [0:1023];
  integer    g_tx_ptr = 0;
  reg [15:0] g_tx_out = 16'h0000;
  assign hdd_data_in = g_tx_out;
  always @(posedge clk28) if (clk7_en) begin
    if (hdd_data_wr) begin
      g_rx[g_rx_n & 1023] <= hdd_data_out;
      g_rx_n <= g_rx_n + 1;
    end
    g_tx_out <= g_tx[g_tx_ptr & 1023];
    if (hdd_data_rd) g_tx_ptr <= g_tx_ptr + 1;
  end

  // ---------------------------------------------------------------- userio_osd
  userio_osd #(.CORE_CAPS(8'h0d)) osd1 (
    .clk(clk28), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
    .reset(mm_reset),
    .rtg_ena(1'b0),
    .osd_ctrl(8'h00),
    .in_diag(32'h9A785634), .in_diag_clr(),
    ._scs(spi_cs[5]), .sdi(spi_di), .sdo(user_sdo), .sck(sck_slv),
    .osd_rx_seq(osd_rx_seq),
    .key_disable(),
    .memory_config(), .chipset_config(), .floppy_config(),
    .scanline(), .dither(),
    .ide_config0(), .ide_config1(),
    .cpu_config(), .autofire_config(), .cd32pad(),
    .usrrst(), .cpurst(), .cpuhlt(),
    .fifo_full(),
    .host_cs(), .host_adr(), .host_we(), .host_bs(), .host_wdat(),
    .host_rdat(16'h0000), .host_ack(1'b0)
  );

  // ---------------------------------------------------------------- SD card
  // SPI mode 3 as cfide clocks it: the card changes DO after a falling edge
  // of its CLK pin and the host samples on the rising one.  Pin path: sck
  // routing + OBUF out, card output delay, IBUF back.
  real    card_dly = 12.0;
  reg     card_stream = 1'b0;
  reg [7:0] card_sec [0:513];       // 512 data bytes + 2 CRC bytes
  integer card_bit = 0;
  reg     card_do = 1'b1;
  assign  sd_miso = card_do;
  always @(negedge spi_sck) begin
    if (card_stream && !spi_cs[1]) begin
      card_do <= #(sckdly + card_dly)
        ((card_bit < 514*8) ? card_sec[card_bit >> 3][7 - (card_bit & 7)] : 1'b1);
      card_bit = card_bit + 1;
    end
  end

  // --------------------------------------------------------------- host bus model
  // host_bridge.vhd: hw_req rises at a clk edge, stays up until hw_ack is seen
  // at a clk edge, and drops at that edge.  The CPU then takes `gap' cycles
  // before the next request.
  integer gap = 8;
  integer jitter;
  localparam [31:0] HW_SPI = 32'h0fffffe0;
  localparam [31:0] HW_HOST_REQ = 32'h0fffffb4;

  task bus(input [31:0] a, input w, input [7:0] data, output [7:0] rd);
    begin
      @(posedge clk114);
      addr <= a[31:2];
      d    <= {data, data};
      wr   <= w;
      req  <= 1'b1;
      @(posedge clk114);
      while (!ack) @(posedge clk114);
      rd = q[7:0];
      req <= 1'b0;
      wr  <= 1'b0;
      jitter = $urandom % 4;
      repeat (gap + jitter) @(posedge clk114);
    end
  endtask

  reg [7:0] dummy;
  task cs_w(input [7:0] v);      begin bus(HW_SPI + 7, 1'b1, v, dummy); end endtask
  task spd_w(input [7:0] v);     begin bus(HW_SPI + 11, 1'b1, v, dummy); end endtask
  task spi_w(input [7:0] v);     begin bus(HW_SPI + 3, 1'b1, v, dummy); end endtask
  task spi_r(output [7:0] v);    begin bus(HW_SPI + 3, 1'b0, 8'h00, v); end endtask
  // SPI(x): write, then read back (the read waits for the transfer to end)
  task spi(input [7:0] tx, output [7:0] rx); begin spi_w(tx); spi_r(rx); end endtask

  task settle; begin repeat (400) @(posedge clk114); end endtask   // ~3.5 us

  // +RDY=1: before an OSD reply byte, read HOST_REQ until OSD_RDY (bit 0)
  integer rdy_reads = 0, rdy_zero = 0;
  task osd_wait_rdy;
    integer t0;
    reg [7:0] v;
    begin
      if (rdy) begin
        t0 = cyc;
        v = 8'h00;
        while (!v[0]) begin
          bus(HW_HOST_REQ, 1'b0, 8'h00, v);
          rdy_reads = rdy_reads + 1;
          if (!v[0]) rdy_zero = rdy_zero + 1;
          if (!v[0] && cyc - t0 > 100000) begin
            $display("=== FAIL (watchdog: HOST_REQ read %h for 100000 cycles, gap %0d, cycle %0d)", v, gap, cyc);
            $finish;
          end
        end
      end
    end
  endtask

  task rnd_phase; begin repeat ($urandom % 16) @(posedge clk114); end endtask

  // ---------------------------------------------------------------- tests
  reg [7:0] buf8 [0:511];
  reg [7:0] rb;
  integer i, errs, t_fail, t_runs;

  // GetFPGAStatus(): six bytes, so the slave's word counter ends at 2 and the
  // direct-mode words that follow are not decoded as command words.
  task fpga_status;
    integer k;
    begin
      cs_w(8'h10);
      for (k = 0; k < 6; k = k + 1) spi(8'h00, rb);
      cs_w(8'h11);
    end
  endtask

  task t_wr(output integer bad);
    integer k, n0;
    begin
      for (k = 0; k < 512; k = k + 1) buf8[k] = $urandom;
      rnd_phase;
      n0 = g_rx_n;
      cs_w(8'h10);
      spi(8'hA0, rb);
      for (k = 0; k < 5; k = k + 1) spi(8'h00, rb);
      for (k = 0; k < 512; k = k + 1) spi(buf8[k], rb);
      cs_w(8'h11);
      settle;
      bad = 0;
      if (g_rx_n - n0 != 256) begin
        $display("  wr: %0d words received, want 256", g_rx_n - n0);
        bad = 1;
      end
      for (k = 0; k < 256 && !bad; k = k + 1)
        if (g_rx[(n0 + k) & 1023] !== {buf8[2*k], buf8[2*k+1]}) begin
          $display("  wr: word %0d = %h, want %h", k, g_rx[(n0 + k) & 1023], {buf8[2*k], buf8[2*k+1]});
          bad = 1;
        end
    end
  endtask

  task t_rd(output integer bad);
    integer k;
    reg [7:0] got [0:511];
    begin
      for (k = 0; k < 1024; k = k + 1) g_tx[k] = $urandom;
      @(posedge clk28); g_tx_ptr = 0;
      repeat (16) @(posedge clk28);
      rnd_phase;
      cs_w(8'h10);
      spi(8'hB0, rb);
      for (k = 0; k < 5; k = k + 1) spi(8'h00, rb);
      for (k = 0; k < 512; k = k + 1) spi(8'hFF, got[k]);
      cs_w(8'h11);
      settle;
      bad = 0;
      for (k = 0; k < 256 && !bad; k = k + 1)
        if ({got[2*k], got[2*k+1]} !== g_tx[k]) begin
          $display("  rd: word %0d = %h, want %h", k, {got[2*k], got[2*k+1]}, g_tx[k]);
          bad = 1;
        end
    end
  endtask

  task t_direct(output integer bad);
    integer k, n0;
    begin
      for (k = 0; k < 514; k = k + 1) card_sec[k] = $urandom;
      fpga_status;
      rnd_phase;
      cs_w(8'h02);                 // EnableCard (CMD18 + data token not modelled)
      n0 = g_rx_n;
      card_bit = 0;
      card_stream = 1'b1;
      // The firmware's direct mode (mmc.c, MMC_Read*): EnableDMode(),
      // SPI(0xFF), i = RDSPI, DisableDMode().  The model writes the dummy
      // byte, then makes one read, which stalls until the 4096 bits are
      // done, and drops the chip select `gap' cycles after its ack.  The
      // firmware's SPI(0xFF) also reads back (the read that stalls), so its
      // DisableDMode() comes one access later: the model is the tighter
      // case (the sequence of the retired 832 firmware, whose compiler
      // dropped that read-back).
      cs_w(8'h40);                 // EnableDMode
      spi_w(8'hFF);                // dummy write for 4096 clocks
      spi_r(rb);                   // i = RDSPI
      cs_w(8'h41);                 // DisableDMode
      spi(8'hFF, rb);              // CRC lo
      spi(8'hFF, rb);              // CRC hi
      cs_w(8'h03);                 // DisableCard
      card_stream = 1'b0;
      settle;
      bad = 0;
      if (g_rx_n - n0 != 256) begin
        $display("  direct: %0d words received, want 256", g_rx_n - n0);
        bad = 1;
      end
      for (k = 0; k < 256 && !bad; k = k + 1)
        if (g_rx[(n0 + k) & 1023] !== {card_sec[2*k], card_sec[2*k+1]}) begin
          $display("  direct: word %0d = %h, want %h", k, g_rx[(n0 + k) & 1023], {card_sec[2*k], card_sec[2*k+1]});
          bad = 1;
        end
    end
  endtask

  reg [7:0] osd_ref [0:9];
  task osd_version(output integer bad, input integer keep_ref);
    integer k;
    reg [7:0] got [0:9];
    begin
      rnd_phase;
      cs_w(8'h20);
      spi(8'h88, rb);
      for (k = 0; k < 10; k = k + 1) begin osd_wait_rdy; spi(8'hFF, got[k]); end
      cs_w(8'h21);
      settle;
      bad = 0;
      for (k = 0; k < 10; k = k + 1) begin
        if (keep_ref) osd_ref[k] = got[k];
        else if (got[k] !== osd_ref[k] && !bad) begin
          $display("  osd: byte %0d = %h, want %h", k, got[k], osd_ref[k]);
          bad = 1;
        end
      end
    end
  endtask

  // xframe: OSD_CMD_OSD_WR as OsdWriteOffset starts it (0c 00 00), CS up and
  // at once down again (both writes at gap 2), then the VERSION read.  The
  // OSD_WR frame's last byte can still be in userio_osd's synchroniser (up to
  // ~40 clk_114 after its last sck edge) when the new frame's command byte
  // starts; `live' says whether it was (osd_rx_seq short of the frame's 3
  // bytes after the second CS write, just before the command byte).
  task t_xframe(output integer bad, output integer live);
    integer k, g0;
    reg [1:0] rx3;
    reg [7:0] got [0:9];
    begin
      rnd_phase;
      rx3 = osd_rx_seq + 2'd3;       // settled now (every earlier byte taken); +3 = OSD_WR taken
      cs_w(8'h20);
      spi(8'h0c, rb);
      spi(8'h00, rb);
      spi(8'h00, rb);
      g0 = gap;
      gap = 2;
      cs_w(8'h21);
      cs_w(8'h20);
      live = (osd_rx_seq != rx3);
      gap = g0;
      spi(8'h88, rb);
      for (k = 0; k < 10; k = k + 1) begin osd_wait_rdy; spi(8'hFF, got[k]); end
      cs_w(8'h21);
      settle;
      bad = 0;
      for (k = 0; k < 10; k = k + 1)
        if (got[k] !== osd_ref[k] && !bad) begin
          $display("  xframe: byte %0d = %h, want %h", k, got[k], osd_ref[k]);
          bad = 1;
        end
    end
  endtask

  // ---------------------------------------------------------------- debug trace
  always @(negedge sck_slv) if (debug && !spi_cs[4] && pf1.spi_bit_cnt == 4'd0)
    $display("%t LOAD word: tx_cnt=%0d data=%h g_tx_out=%h ptr=%0d", $time, pf1.spi_tx_cnt, pf1.spi_tx_data, g_tx_out, g_tx_ptr);
  always @(posedge clk28) if (debug && clk7_en && hdd_data_rd)
    $display("%t POP ptr=%0d", $time, g_tx_ptr);
  always @(posedge clk114) if (debug && req && ack && !wr && addr[3:2] == 2'b00)
    $display("%t READ %h", $time, q[7:0]);
  always @(posedge clk114) if (debug && req && wr && addr[3:2] == 2'b00 && !mycfide.SD_busy)
    $display("%t WRITE %h", $time, d[7:0]);

  // ---------------------------------------------------------------- main
  integer gaps [0:63];
  integer ngaps = 16;
  integer sweep = 0;
  integer g, r, bad, total_fail, osd_fail_low;
  integer f_wr, f_rd, f_dir, f_osd, f_xf, live, n_live, n_live_all;

  initial begin
    if (!$value$plusargs("SCKDLY=%f", sckdly)) sckdly = 1.5;
    if (!$value$plusargs("C28DLY=%f", c28dly)) c28dly = 0.3;
    if (!$value$plusargs("SPEED=%d", speed)) speed = 1;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    if (!$value$plusargs("REPS=%d", reps)) reps = 3;
    // The OSD reply needs a slow host: userio_osd loads a reply byte on the
    // first sck edge of that byte, and the byte counter it comes from only
    // moves when the previous byte's rx has been through the clk7 synchroniser
    // and the clk7 logic (up to ~350 ns after its last bit).  A host that
    // starts the next byte sooner gets a stale reply.  The firmware is slow
    // enough (fpga_init's version read sees the 0xA4 magic on the board; it
    // also waits for OSD_RDY, +RDY), so the bench reports osd below 40
    // cycles but does not fail on it.
    if (!$value$plusargs("OSD_MIN_GAP=%d", osd_min_gap)) osd_min_gap = 40;
    if (!$value$plusargs("TESTS=%d", tests_mask)) tests_mask = 15;
    if (!$value$plusargs("GAPMAX=%d", gapmax)) gapmax = 1000;
    if (!$value$plusargs("DEBUG=%d", debug)) debug = 0;
    if (!$value$plusargs("RDY=%d", rdy)) rdy = 0;
    dummy = $urandom(seed);

    // From 2: host_bridge.vhd cannot raise the next hw_req less than two
    // cycles after it saw hw_ack (cpu_ack, then the waiting state).  Faster
    // than that the bus model would take cfide's previous ack, which is a
    // clk_28 register and stays up until the next clk_28 edge, for the new
    // request -- a host-bus matter, not the SPI one.
    gaps[0] = 2;  gaps[1] = 3;  gaps[2] = 4;  gaps[3] = 5;
    gaps[4] = 6;  gaps[5] = 8;  gaps[6] = 10; gaps[7] = 12;
    gaps[8] = 16; gaps[9] = 20; gaps[10] = 24; gaps[11] = 28;
    gaps[12] = 32; gaps[13] = 40; gaps[14] = 48; gaps[15] = 64;
    // +SWEEP=1: every even gap from 2 to 80, for the direct-mode threshold
    if ($value$plusargs("SWEEP=%d", sweep) && sweep) begin
      ngaps = 40;
      for (g = 0; g < 40; g = g + 1) gaps[g] = 2 + 2*g;
    end

    $display("SPI CDC bench: SCKDLY=%0.2f ns C28DLY=%0.2f ns SPEED=%0d SEED=%0d REPS=%0d",
             sckdly, c28dly, speed, seed, reps);
    if (rdy) $display("RDY=1: HOST_REQ poll before each OSD reply byte");

    repeat (20) @(posedge clk114);
    n_reset = 1'b1;
    repeat (40) @(posedge clk28);
    mm_reset = 1'b0;
    repeat (40) @(posedge clk28);

    gap = 100;
    spd_w(speed);
    // the slaves' first transaction after reset
    fpga_status;
    osd_version(bad, 1);            // reference reply, slow host
    $display("OSD reference: %h %h %h %h %h %h %h %h %h %h",
             osd_ref[0], osd_ref[1], osd_ref[2], osd_ref[3], osd_ref[4],
             osd_ref[5], osd_ref[6], osd_ref[7], osd_ref[8], osd_ref[9]);

    total_fail = 0;
    osd_fail_low = 0;
    n_live_all = 0;
    for (g = 0; g < ngaps && gaps[g] <= gapmax; g = g + 1) begin
      gap = gaps[g];
      f_wr = 0; f_rd = 0; f_dir = 0; f_osd = 0; f_xf = 0; n_live = 0;
      rdy_reads = 0; rdy_zero = 0;
      for (r = 0; r < reps; r = r + 1) begin
        if (tests_mask & 1) begin t_wr(bad);     f_wr  = f_wr + bad; end
        if (tests_mask & 2) begin t_rd(bad);     f_rd  = f_rd + bad; end
        if (tests_mask & 4) begin t_direct(bad); f_dir = f_dir + bad; end
        if (tests_mask & 8) begin osd_version(bad, 0); f_osd = f_osd + bad; end
        if (tests_mask & 16) begin t_xframe(bad, live); f_xf = f_xf + bad; n_live = n_live + live; end
      end
      $display("GAP %0d wr fail %0d/%0d", gap, f_wr, reps);
      $display("GAP %0d rd fail %0d/%0d", gap, f_rd, reps);
      $display("GAP %0d direct fail %0d/%0d", gap, f_dir, reps);
      $display("GAP %0d osd fail %0d/%0d", gap, f_osd, reps);
      if (tests_mask & 16)
        $display("GAP %0d xframe fail %0d/%0d (OSD_WR byte not yet taken at the VERSION command in %0d)", gap, f_xf, reps, n_live);
      if (rdy)
        $display("GAP %0d HOST_REQ reads %0d, of them OSD_RDY 0: %0d", gap, rdy_reads, rdy_zero);
      total_fail = total_fail + f_wr + f_rd + f_dir + f_xf;
      n_live_all = n_live_all + n_live;
      if (gap >= osd_min_gap) total_fail = total_fail + f_osd;
      else osd_fail_low = osd_fail_low + f_osd;
    end

    if (osd_fail_low)
      $display("NOTE: %0d osd failures below OSD_MIN_GAP=%0d (not counted)", osd_fail_low, osd_min_gap);
    if ((tests_mask & 16) && n_live_all == 0) begin
      $display("xframe: the OSD_WR frame's last byte was taken before the VERSION command in every run: the case was not exercised");
      total_fail = total_fail + 1;
    end
    if (total_fail == 0) $display("=== PASS");
    else                 $display("=== FAIL (%0d failing sectors)", total_fail);
    $finish;
  end

endmodule
