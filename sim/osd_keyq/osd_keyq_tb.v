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
// Run: ./run.sh

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

  reg  [7:0] osd_ctrl = 8'h00;
  reg        _scs = 1'b1, sdi = 1'b0, sck = 1'b1;
  wire       sdo;

  integer errors = 0;

  userio_osd #(.CORE_CAPS(CAPS)) dut (
    .clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
    .reset(1'b0),
    .c1(1'b0), .c3(1'b0), .sol(1'b0), .sof(1'b0),
    .varbeamen(1'b0), .rtg_ena(1'b0),
    .osd_ctrl(osd_ctrl),
    ._scs(_scs), .sdi(sdi), .sdo(sdo), .sck(sck),
    .osd_blank(), .osd_pixel(),
    .osd_enable(), .key_disable(),
    .lr_filter(), .hr_filter(),
    .memory_config(), .chipset_config(), .floppy_config(),
    .scanline(), .dither(),
    .ide_config0(), .ide_config1(),
    .cpu_config(), .autofire_config(), .cd32pad(),
    .usrrst(), .cpurst(), .cpuhlt(),
    .fifo_full(),
    .host_cs(), .host_adr(), .host_we(), .host_bs(), .host_wdat(),
    .host_rdat(16'h0000), .host_ack(1'b0)
  );

  // One SPI byte, the way the 832 clocks it: sck idles high, data out changes
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

  reg [7:0] b0, b1, b2, b3, b4, b5;

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
    spi_close;
    expect_byte("version byte 4 (magic)", b4, 8'hA4);
    expect_byte("version byte 5 (caps)",  b5, CAPS | 8'h10);

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

    if (errors == 0)
      $display("\n=== PASS: 0 failures ===");
    else
      $display("\n=== FAIL: %0d failures ===", errors);
    $finish;
  end

endmodule
