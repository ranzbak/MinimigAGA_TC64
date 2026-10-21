// The OSD key-event queue in userio_osd.v (command 0x98), and the sixth byte
// of OSD_CMD_VERSION.
//
// What is actually being checked is the byte ORDER and the pop TIMING, because
// that is where this can be wrong while looking right: the SPI shifter latches
// its output byte on the first falling edge of sck for that byte, while `rx'
// -- which is what advances the read pointer -- is two clk7 stages behind the
// byte boundary.  If the host clocked SPI faster than that latency, a byte
// would be sent before the pop landed and every event would come out twice.
// The version reply has always depended on the same race (that is how its
// byte counter advances), so a queue drain that agrees with it is safe for the
// same reason the version read is.
//
// Sections 9-13 check the reply sequence osd_rx_seq (the RTL half of the OSD
// "reply byte ready" handshake, findings/osd-riscv/phase4.md "Handshake
// design"): one increment per byte, at the clk7 edge that takes the byte, so
// a host that starts a reply byte only once the sequence has caught up with
// its own byte count reads the right byte even with no extra wait at all.
// That host is modelled the way cfide clocks SPI at SPI_fast() (speed 1):
// sck half period 3 clk_114, everything on clk_114 edges (clk114 below, four
// per clk), tx_seq its count of bytes started (cfide's osd_tx_seq, Task 10).
//
// Run (fresh Ubuntu 24.04, from the repository root, bash or zsh; iverilog
// only, no Vivado, about a second):
//
//   sudo apt install iverilog
//   bash sim/osd_keyq/run.sh            the bench: "=== PASS"
//   bash sim/osd_keyq/run.sh mutant     the queue removed: must FAIL
//   bash sim/osd_keyq/run.sh mutant_seq osd_rx_seq one clk7 period early:
//                                       check (b) must FAIL
//   bash sim/osd_keyq/run.sh mutant_cs  osd_rx_seq counts only bytes taken
//                                       under CS: check (d') must FAIL
//
// Each mode prints "<mode>: PASS|FAIL (expected ...) -- OK" and exits 0 when
// every mode did what it should; RUNTAG=<tag> names the run directory
// (sim/osd_keyq/run_<tag>).

`timescale 1ns/1ps

module osd_keyq_tb;

  localparam [7:0] CAPS = 8'h0d;   // AP040 + FPU + MMU, as the QMTech build sets it

  reg clk = 0;
  always #17.8 clk = ~clk;         // 28.375 MHz

  // clk7_en / clk7n_en: one clk in four, the two phases apart
  reg [1:0] ph = 0;
  always @(posedge clk) ph <= ph + 2'd1;
  wire clk7_en  = (ph == 2'd0);
  wire clk7n_en = (ph == 2'd2);

  // clk_114 for the fast host: four periods per clk, its rising edges half
  // way between two clk edges (so the host never samples a clk-domain
  // register in the time step it changes)
  reg clk114 = 0;
  always #4.45 clk114 = ~clk114;

  reg  [7:0] osd_ctrl = 8'h00;
  reg        _scs = 1'b1, sdi = 1'b0, sck = 1'b1;
  wire       sdo;

  integer errors = 0;
  wire [4:0] cpu_cfg;              // [4] Chip slots Fast (findings/fastslot)
  wire [4:0] ide_cfg0, ide_cfg1;   // IDE port 1 / 2 config (findings/cdrom/plan.md 7.3)
  reg        osd_reset = 1'b0;
  wire       diag_clr;
  integer    diag_clrs = 0;
  always @(posedge diag_clr) diag_clrs = diag_clrs + 1;   // one clk7-long pulse

  // osd_rx_seq: every change must be +1 (mod 4); seq_incs counts them
  wire [1:0] rx_seq;
  reg  [1:0] seq_prev = 2'd0;
  integer    seq_incs = 0;
  always @(posedge clk) begin
    if (rx_seq !== seq_prev) begin
      if (rx_seq !== seq_prev + 2'd1) begin
        $display("FAIL: (a) osd_rx_seq stepped %0d -> %0d", seq_prev, rx_seq);
        errors = errors + 1;
      end
      seq_incs = seq_incs + 1;
    end
    seq_prev <= rx_seq;
  end

  userio_osd #(.CORE_CAPS(CAPS)) dut (
    .clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
    .reset(osd_reset),
    .c1(1'b0), .c3(1'b0), .sol(1'b0), .sof(1'b0),
    .varbeamen(1'b0), .rtg_ena(1'b0),
    .osd_ctrl(osd_ctrl),
    .in_diag(32'h9A785634), .in_diag_clr(diag_clr),
    ._scs(_scs), .sdi(sdi), .sdo(sdo), .sck(sck),
    .osd_blank(), .osd_pixel(),
    .osd_enable(), .key_disable(),
    .lr_filter(), .hr_filter(),
    .memory_config(), .chipset_config(), .floppy_config(),
    .scanline(), .dither(),
    .osd_rx_seq(rx_seq),
    .ide_config0(ide_cfg0), .ide_config1(ide_cfg1),
    .cpu_config(cpu_cfg), .autofire_config(), .cd32pad(),
    .usrrst(), .cpurst(), .cpuhlt(),
    .fifo_full(),
    .host_cs(), .host_adr(), .host_we(), .host_bs(), .host_wdat(),
    .host_rdat(16'h0000), .host_ack(1'b0)
  );

  // One SPI byte, the way cfide clocks it: sck idles high, data out changes
  // on the falling edge, data in is sampled on the rising one.  The half
  // period is deliberately generous -- the point of the bench is the queue,
  // not how fast the link can be pushed.
  task spi_byte(input [7:0] tx, output [7:0] rx_b);
    integer i;
    begin
      for (i = 7; i >= 0; i = i - 1) begin
        sck = 1'b0;  sdi = tx[i];  #500;
        rx_b[i] = sdo;
        sck = 1'b1;  #500;
      end
    end
  endtask

  task spi_open(input [7:0] cmd);
    reg [7:0] dummy;
    begin
      _scs = 1'b0;  #200;
      spi_byte(cmd, dummy);
    end
  endtask

  task spi_close;
    begin
      #200;  _scs = 1'b1;  #500;
    end
  endtask

  // A key event as the keyboard makes one: osd_ctrl simply changes.  The queue
  // records changes, so the hold only has to outlast the clk7 enable.
  task key(input [7:0] code);
    begin
      osd_ctrl = code;
      #2000;
    end
  endtask

  task expect_byte(input [8*24:1] what, input [7:0] got, input [7:0] want);
    begin
      if (got !== want) begin
        $display("FAIL: %0s = %02h, expected %02h", what, got, want);
        errors = errors + 1;
      end else
        $display("  ok: %0s = %02h", what, got);
    end
  endtask

  // ---- the fast host (sections 10-13) -------------------------------------
  localparam HALF = 3;             // sck half period, clk_114 (cfide, speed 1)
  reg [1:0] tx_seq = 2'd0;         // bytes started, mod 4 (cfide's osd_tx_seq)

  // One byte at full speed.  poll = 1: first wait until osd_rx_seq has caught
  // up with tx_seq (every byte before this one has been taken), then start at
  // that very clk_114 edge -- a gap of 0 extra cycles.  poll = 0: start at
  // once.  Called on a clk_114 edge, returns on one.
  task fbyte(input [8*12:1] tag, input poll, input [7:0] tx, output [7:0] rx_b);
    integer i, w;
    begin
      if (poll) begin
        w = 0;
        while (rx_seq !== tx_seq && w < 200) begin
          @(posedge clk114);  w = w + 1;
        end
        if (rx_seq !== tx_seq) begin
          $display("FAIL: %0s osd_rx_seq %0d never reached tx_seq %0d", tag, rx_seq, tx_seq);
          errors = errors + 1;
        end
      end
      tx_seq = tx_seq + 2'd1;
      for (i = 7; i >= 0; i = i - 1) begin
        sck = 1'b0;  sdi = tx[i];  repeat (HALF) @(posedge clk114);
        rx_b[i] = sdo;
        sck = 1'b1;  repeat (HALF) @(posedge clk114);
      end
    end
  endtask

  // Open a frame at full speed after an idle bus: tx_seq takes osd_rx_seq
  // (cfide resyncs after 64 idle cycles, Task 10), CS falls, and the command
  // byte starts one clk_114 later.
  task fopen(input [7:0] cmd);
    reg [7:0] dummy;
    begin
      @(posedge clk114);
      tx_seq = rx_seq;
      _scs = 1'b0;  @(posedge clk114);
      fbyte("cmd", 1'b0, cmd, dummy);
    end
  endtask

  task fclose;
    begin
      _scs = 1'b1;  #2000;
    end
  endtask

  // Drain the key queue at the slow rate: read the count, pop that many.
  task drain;
    reg [7:0] n, d;
    integer i;
    begin
      spi_open(8'h98);
      spi_byte(8'hff, n);
      for (i = 0; i < n[3:0]; i = i + 1) spi_byte(8'hff, d);
      spi_close;
    end
  endtask

  task expect_int(input [8*48:1] what, input integer got, input integer want);
    begin
      if (got !== want) begin
        $display("FAIL: %0s = %0d, expected %0d", what, got, want);
        errors = errors + 1;
      end else
        $display("  ok: %0s = %0d", what, got);
    end
  endtask

  reg [7:0] b0, b1, b2, b3, b4, b5, b6, b7, b8, b9;
  reg [7:0] ver_ref [0:9];         // the version reply, read at the slow rate
  reg [7:0] kq_ev   [0:5];         // six key events (sections 9-11)
  reg [7:0] rb;
  integer   k, n0, wrong;

  initial begin
    $dumpfile("osd_keyq.vcd");
    $dumpvars(0, osd_keyq_tb);

    #20000;

    // ---- 1. the version reply, byte 5 --------------------------------------
    // Byte 4 is the magic the firmware checks; byte 5 is CORE_CAPS, which the
    // saturating dat_cnt used to make unreachable.  Bit 4 is added by the OSD
    // itself to say the queue below exists.
    $display("--- OSD_CMD_VERSION ---");
    spi_open(8'h88);
    spi_byte(8'hff, b0);
    spi_byte(8'hff, b1);
    spi_byte(8'hff, b2);
    spi_byte(8'hff, b3);
    spi_byte(8'hff, b4);
    spi_byte(8'hff, b5);
    spi_byte(8'hff, b6);
    spi_byte(8'hff, b7);
    spi_byte(8'hff, b8);
    spi_byte(8'hff, b9);
    spi_close;
    expect_byte("version byte 4 (magic)", b4, 8'hA4);
    // bit 4: the key queue; bit 6: bytes 6-9 are the input-path diagnostic
    expect_byte("version byte 5 (caps)",  b5, CAPS | 8'h50);
    expect_byte("version byte 6 (in_diag[7:0])",   b6, 8'h34);
    expect_byte("version byte 7 (in_diag[15:8])",  b7, 8'h56);
    expect_byte("version byte 8 (in_diag[23:16])", b8, 8'h78);
    expect_byte("version byte 9 (in_diag[31:24])", b9, 8'h9A);
    if (diag_clrs != 1) begin
      errors = errors + 1;
      $display("FAIL: reading byte 9 raised in_diag_clr %0d times, expected 1", diag_clrs);
    end else
      $display("  ok: reading byte 9 cleared the sticky diagnostic once");

    // ---- 2. an empty queue -------------------------------------------------
    $display("--- empty queue ---");
    spi_open(8'h98);
    spi_byte(8'hff, b0);
    spi_byte(8'hff, b1);
    spi_close;
    expect_byte("count when empty", b0, 8'h00);
    expect_byte("event when empty", b1, 8'h00);

    // ---- 3. press and release, both delivered ------------------------------
    // This is the case the old level-compare lost when both happened between
    // two polls, and a lost key-UP is what leaves a modifier stuck.
    $display("--- down then up between two polls ---");
    key(8'h63);        // CTRL down
    key(8'he3);        // CTRL up
    key(8'h00);        // back to idle
    spi_open(8'h98);
    spi_byte(8'hff, b0);
    spi_byte(8'hff, b1);
    spi_byte(8'hff, b2);
    spi_byte(8'hff, b3);
    spi_byte(8'hff, b4);
    spi_close;
    expect_byte("count", b0, 8'h03);
    expect_byte("event 0 (ctrl down)", b1, 8'h63);
    expect_byte("event 1 (ctrl up)",   b2, 8'he3);
    expect_byte("event 2 (idle)",      b3, 8'h00);
    expect_byte("past the end",        b4, 8'h00);

    // ---- 4. the queue really emptied ---------------------------------------
    $display("--- drained ---");
    spi_open(8'h98);
    spi_byte(8'hff, b0);
    spi_close;
    expect_byte("count after drain", b0, 8'h00);

    // ---- 5. overflow drops the NEWEST and says so --------------------------
    // Sixteen events into a fifteen-deep queue.  Dropping the oldest would
    // lose a key-up, which is the failure this exists to remove, so the newest
    // goes and the flag tells the firmware to forget its modifiers.
    $display("--- overflow ---");
    begin : fill
      integer i;
      for (i = 0; i < 16; i = i + 1)
        key(8'h40 + i[7:0]);
    end
    spi_open(8'h98);
    spi_byte(8'hff, b0);
    spi_byte(8'hff, b1);
    spi_close;
    expect_byte("count + overflow flag", b0, 8'h8f);
    expect_byte("oldest event kept",     b1, 8'h40);

    // The flag is cleared by reading the count, not by the drain.
    spi_open(8'h98);
    spi_byte(8'hff, b0);
    spi_close;
    if (b0[7] !== 1'b0) begin
      $display("FAIL: overflow flag still set after being read");
      errors = errors + 1;
    end else
      $display("  ok: overflow flag cleared by the read");

    // ---- 6. OSD_CMD_READ still answers the level ---------------------------
    // The firmware's auto-repeat asks whether a key is HELD, so this path must
    // keep working exactly as it did.
    $display("--- OSD_CMD_READ level ---");
    key(8'h4c);
    spi_open(8'h00);
    spi_byte(8'hff, b0);
    spi_close;
    expect_byte("level", b0, 8'h4c);

    // ---- 7. OSD_CMD_CPU: Chip slots in bit 4 --------------------------------
    // The firmware sends config.cpu & 0x1f: [1:0] CPU (taken only in reset,
    // which this bench never asserts), [3:2] Turbo and [4] Chip slots Fast,
    // both live.  An old firmware sends & 0x0f, so bit 4 arrives clear and the
    // core stays Standard -- the behaviour an old config was saved with.
    $display("--- OSD_CMD_CPU ---");
    expect_byte("cpu_cfg at power-up", {3'b000, cpu_cfg}, 8'h00);
    spi_open(8'h14);
    spi_byte(8'h1d, b0);           // CPU 1, Turbo BOTH, Chip slots Fast
    spi_close;
    #2000;
    expect_byte("cpu_cfg[4:2] after 0x1d", {5'b00000, cpu_cfg[4:2]}, 8'h07);
    spi_open(8'h14);
    spi_byte(8'h0d, b0);           // the same from an old firmware (& 0x0f)
    spi_close;
    #2000;
    expect_byte("cpu_cfg[4:2] after 0x0d", {5'b00000, cpu_cfg[4:2]}, 8'h03);
    spi_open(8'h14);
    spi_byte(8'h10, b0);           // Chip slots Fast alone
    spi_close;
    #2000;
    expect_byte("cpu_cfg[4:2] after 0x10", {5'b00000, cpu_cfg[4:2]}, 8'h04);

    // ---- 8. OSD_CMD_HDD / OSD_CMD_HDD1: five bits per IDE port ---------------
    // {slave ATAPI, master ATAPI, slave, master, port on}; 0x54 is port 1,
    // 0x58 port 2.  Both are taken only while the Amiga is in reset.
    $display("--- OSD_CMD_HDD / HDD1 ---");
    spi_open(8'h54);
    spi_byte(8'h17, b0);           // port 1: on, master + slave, slave ATAPI
    spi_close;
    spi_open(8'h58);
    spi_byte(8'h0b, b0);           // port 2: on, master, master ATAPI
    spi_close;
    #2000;
    expect_byte("ide_config0 before reset", {3'b000, ide_cfg0}, 8'h00);
    osd_reset = 1'b1;  #2000;  osd_reset = 1'b0;  #2000;
    expect_byte("ide_config0 (0x54)", {3'b000, ide_cfg0}, 8'h17);
    expect_byte("ide_config1 (0x58)", {3'b000, ide_cfg1}, 8'h0b);

    // ---- 9. (a) osd_rx_seq: exactly one step per byte ----------------------
    // Slow frames, so every byte has long been taken when the count is read.
    $display("--- (a) osd_rx_seq per byte ---");
    drain;                         // sections 5-6 left the queue full
    #2000;
    n0 = seq_incs;
    spi_open(8'h88);
    for (k = 0; k < 10; k = k + 1) begin
      spi_byte(8'hff, rb);
      ver_ref[k] = rb;
    end
    spi_close;  #2000;
    expect_int("(a) steps, VERSION (command + 10)", seq_incs - n0, 11);

    for (k = 0; k < 6; k = k + 1) begin
      kq_ev[k] = 8'h50 + k[7:0];
      key(kq_ev[k]);
    end
    n0 = seq_incs;
    spi_open(8'h98);
    spi_byte(8'hff, b0);
    for (k = 0; k < 6; k = k + 1) begin
      spi_byte(8'hff, rb);
      expect_byte("(a) KEYQ event", rb, kq_ev[k]);
    end
    spi_close;  #2000;
    expect_byte("(a) KEYQ count", b0, 8'h06);
    expect_int("(a) steps, KEYQ (command + count + 6)", seq_incs - n0, 8);

    // OSD_CMD_OSD_WR as OsdWriteOffset sends it: 0x0c, 00 00 00 <line>, text
    n0 = seq_incs;
    spi_open(8'h0c);
    spi_byte(8'h00, rb);  spi_byte(8'h00, rb);  spi_byte(8'h00, rb);  spi_byte(8'h02, rb);
    for (k = 0; k < 35; k = k + 1) spi_byte(8'h41 + k[7:0], rb);
    spi_close;  #2000;
    expect_int("(a) steps, OSD_WR (40 bytes)", seq_incs - n0, 40);

    // ---- 10. (b) polling the sequence, gap 0: every reply byte right --------
    $display("--- (b) fast host, polls osd_rx_seq, gap 0 ---");
    fopen(8'h88);
    for (k = 0; k < 10; k = k + 1) begin
      fbyte("(b) VERSION", 1'b1, 8'hff, rb);
      expect_byte("(b) VERSION byte", rb, ver_ref[k]);
    end
    fclose;

    for (k = 0; k < 6; k = k + 1) begin
      kq_ev[k] = 8'h58 + k[7:0];
      key(kq_ev[k]);
    end
    fopen(8'h98);
    fbyte("(b) KEYQ", 1'b1, 8'hff, rb);
    expect_byte("(b) KEYQ count", rb, 8'h06);
    for (k = 0; k < 6; k = k + 1) begin
      fbyte("(b) KEYQ", 1'b1, 8'hff, rb);
      expect_byte("(b) KEYQ event", rb, kq_ev[k]);
    end
    fbyte("(b) KEYQ", 1'b1, 8'hff, rb);
    expect_byte("(b) KEYQ past the end", rb, 8'h00);
    fclose;

    // ---- 11. (c) the same host ignoring the sequence: wrong bytes -----------
    // Proves (b) bites: at gap 0 the next byte is loaded three clk_114 after
    // the previous one's last edge, long before the clk7 edge that takes it.
    $display("--- (c) fast host, ignores osd_rx_seq, gap 0 ---");
    wrong = 0;
    fopen(8'h88);
    for (k = 0; k < 10; k = k + 1) begin
      fbyte("(c) VERSION", 1'b0, 8'hff, rb);
      if (rb !== ver_ref[k]) wrong = wrong + 1;
    end
    fclose;
    for (k = 0; k < 6; k = k + 1) key(8'h60 + k[7:0]);
    fopen(8'h98);
    fbyte("(c) KEYQ", 1'b0, 8'hff, rb);
    if (rb !== 8'h06) wrong = wrong + 1;
    for (k = 0; k < 6; k = k + 1) begin
      fbyte("(c) KEYQ", 1'b0, 8'hff, rb);
      if (rb !== 8'h60 + k[7:0]) wrong = wrong + 1;
    end
    fclose;
    if (wrong == 0) begin
      $display("FAIL: (c) ignoring osd_rx_seq read every byte right: (b) proves nothing");
      errors = errors + 1;
    end else
      $display("  ok: (c) ignoring osd_rx_seq read %0d of 17 bytes wrong (expected > 0)", wrong);
    drain;                         // (c) may leave events behind

    // ---- 12. (d) cross-frame: the previous frame's last byte is late --------
    // An OSD_WR frame of 3 bytes at full speed (no poll: a write), CS up, and
    // the KEYQ frame's first sck edge 8 clk_114 after CS rose.  The OSD_WR
    // frame's last byte is taken up to ~40 clk_114 after its last edge, i.e.
    // inside the KEYQ frame: a "byte done" flag would say the KEYQ command
    // has been taken when it has not.  The sequence cannot be fooled that way.
    $display("--- (d) OSD_WR, CS up, KEYQ 8 clk_114 later ---");
    key(8'h71);  key(8'h72);
    fopen(8'h0c);
    fbyte("(d) OSD_WR", 1'b0, 8'h00, rb);
    fbyte("(d) OSD_WR", 1'b0, 8'h00, rb);
    _scs = 1'b1;
    repeat (7) @(posedge clk114);
    _scs = 1'b0;
    if (rx_seq !== tx_seq - 2'd1) begin
      $display("FAIL: (d) at the KEYQ frame's CS osd_rx_seq = %0d, tx_seq = %0d: the case is not exercised",
               rx_seq, tx_seq);
      errors = errors + 1;
    end else
      $display("  ok: (d) the OSD_WR frame's last byte is still in the synchroniser when the KEYQ frame starts");
    @(posedge clk114);
    fbyte("(d) KEYQ cmd", 1'b0, 8'h98, rb);
    fbyte("(d) KEYQ", 1'b1, 8'hff, rb);
    expect_byte("(d) KEYQ count", rb, 8'h02);
    fbyte("(d) KEYQ", 1'b1, 8'hff, rb);
    expect_byte("(d) KEYQ event 0", rb, 8'h71);
    fbyte("(d) KEYQ", 1'b1, 8'hff, rb);
    expect_byte("(d) KEYQ event 1", rb, 8'h72);
    fbyte("(d) KEYQ", 1'b1, 8'hff, rb);
    expect_byte("(d) KEYQ past the end", rb, 8'h00);
    fclose;

    // ---- 13. (d') cross-frame, the late byte taken while CS is high ---------
    // As (d), but CS stays high 45 clk_114 (less than cfide's 64-cycle
    // resync, so tx_seq is kept): the OSD_WR frame's last byte is still in
    // the synchroniser when CS rises and is taken before CS falls again, i.e.
    // with _scs high.  It must be counted all the same: a sequence that
    // counts only bytes taken under CS (mutant_cs: rx && !_scs) stays one
    // short, and the KEYQ frame's polls never see it catch up.
    $display("--- (d') OSD_WR, CS up, KEYQ 45 clk_114 later ---");
    key(8'h73);  key(8'h74);
    fopen(8'h0c);
    fbyte("(d') OSD_WR", 1'b0, 8'h00, rb);
    fbyte("(d') OSD_WR", 1'b0, 8'h00, rb);
    _scs = 1'b1;
    if (rx_seq !== tx_seq - 2'd1) begin
      $display("FAIL: (d') at CS high osd_rx_seq = %0d, tx_seq = %0d: the last byte is not late, the case is not exercised",
               rx_seq, tx_seq);
      errors = errors + 1;
    end
    repeat (45) @(posedge clk114);
    _scs = 1'b0;
    if (rx_seq !== tx_seq) begin
      $display("FAIL: (d') at the KEYQ frame's CS osd_rx_seq = %0d, tx_seq = %0d: the byte taken while CS was high is not counted",
               rx_seq, tx_seq);
      errors = errors + 1;
    end else
      $display("  ok: (d') the OSD_WR frame's last byte, late at CS high, is counted before the KEYQ frame starts");
    @(posedge clk114);
    fbyte("(d') KEYQ cmd", 1'b0, 8'h98, rb);
    fbyte("(d') KEYQ", 1'b1, 8'hff, rb);
    expect_byte("(d') KEYQ count", rb, 8'h02);
    fbyte("(d') KEYQ", 1'b1, 8'hff, rb);
    expect_byte("(d') KEYQ event 0", rb, 8'h73);
    fbyte("(d') KEYQ", 1'b1, 8'hff, rb);
    expect_byte("(d') KEYQ event 1", rb, 8'h74);
    fbyte("(d') KEYQ", 1'b1, 8'hff, rb);
    expect_byte("(d') KEYQ past the end", rb, 8'h00);
    fclose;

    if (errors == 0)
      $display("\n=== PASS: 0 failures ===");
    else
      $display("\n=== FAIL: %0d failures ===", errors);
    $finish;
  end

endmodule
