// L2 host-bridge bench: the RISC-V host CPU through the real bridge.
//
//   EightThirtyTwo_Bridge (cpu_riscv, rv_hostcpu + VexOsd, OSDBoot_rv_ROM =
//   the test program, hostcache.v)  ->  cfide (generics as host832)
//                                   ->  sdram_host_model (lanes of sdram_ctrl)
//   + an SPI byte-capture slave on sd_cs[1] / sd_clk / sd_do, or, compiled
//     with -d SDCARD, the SD card model (sim/common/sd_spi_model.v) there
//
// Clocks as sim/spi_cdc/host832/tb_832_dmode.v: clk_114 T114 = 8.8154 ns,
// clk_28 = clk_114 / 4, its edges 0.3 ns after a clk_114 edge.  cfide's
// tick_in is held at 1 (the timer counts every clk_28; TIMER = timecnt[23:8]
// steps every 1024 clk_114 cycles).
//
// Snooped at the bridge's bus (addr / q / wr / hw_req / hw_ack): a hw access
// completes at a clk_114 edge with hw_req = hw_ack = 1.
//   UART  0xFFFFFFF0 write -> character log, printed per line as "UART: ..."
//   TIME  0xFFFFFF00 write -> checkpoint <value>: test-specific pin checks
//   DONE  0xFFFFFF04 write -> end of run: "=== PASS" when the value is 0 and
//                             the bench saw no error, else "=== FAIL ..."
// Checks in every test:
//   stale ack   a hw access completed although no clk_28 edge of cfide saw
//               its hw_req (the ack belonged to the previous access)
//   SPI accept  a write to SPI DATA completed although cfide never accepted
//               it (no clk_114 edge with req, wr, SPI DATA and SD_busy = 0;
//               SD_busy read hierarchically from cfide)
//   X on the bus no X in read data the bridge returns or in written bytes
//   the SDRAM model's bus-contract checks
// Test-specific checks (+TEST=<name>): see checkpoint() and final_checks().
// t_irq: checkpoint 1 starts 20 vbl_int pulses into cfide (one clk_28 cycle
// each, 2000 clk_114 apart); checkpoint 2 checks that all 20 were sent.
// t_irqctl: the interrupt controller (cfide 0xFFFFFF30..3C); the bench drives
// vbl_int, amiga_req, i2c_ext_int and irq_src[15:4] per checkpoint (table at the
// t_irqctl block below) and checks test 4 ("set wins") itself.
// t_osdrdy: cfide's HOST_REQ (0xFFFFFFB4, bit 0 OSD_RDY); the bench drives
// cfide's osd_rx_seq (userio_osd's reply sequence, 0 in every other test) per
// checkpoint and measures the resync (t_osdrdy block below).
//
// SDCARD (boot runs, +TEST=boot / boot_nofile; the ROM is the committed boot
// ROM fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd): sd_spi_model on sd_cs[1] with
// +SD_IMG=<8 MB card image>, MISO from the model.  Also:
//   ERRORCODE: hhll  printed when the boot ROM's ErrorCode() releases the
//                    chipset: the OSD bytes 08 00 under sd_cs[5]; hhll =
//                    the SDRAM halfword at 0x10000A (upload[10], upload[11])
//   === BOOT         the first CPU read of 0x2000 (the jump to the loaded
//                    firmware): cycle and the rv_hostcpu counters so far
//   === STATS        rv_hostcpu's counters at the end
// The counters need rv_hostcpu.v compiled with -d RV_HOSTCPU_STATS and this
// bench with -d RV_HOSTCPU_STATS too (hierarchical references to
// hostcpu.genrv.myrv.st_*, `HM_RV below); without it they are left out
// (run.sh boot sets both).
//   boot:        checkpoints 1 / 2 as t_irq; verdict as every test (DONE)
//   boot_nofile: the run must end at +TIMEOUT without DONE; "=== PASS" if
//                no DONE, no bench error and the last ErrorCode is 00F0
// A UART carriage return is printed as the two characters \r.
//
// FWBOOT (with SDCARD; run.sh fwboot / fwboot_trap / fwboot_cfg, +TEST=fwboot,
// fwboot_trap or fwboot_cfg): the committed boot ROM loads the real firmware
// (fw/ctrl_rv RV32OSDA.BIN) from a 16 MB card; minimig_spi_stub.v answers
// for the Minimig SPI slaves (FPGA sd_cs[4], OSD sd_cs[5], RTC sd_cs[7]);
// cfide's MISO is the card's while sd_cs[1] is low, else the stub's.  The
// firmware never writes DONE: the run ends at +TIMEOUT, "=== PASS" if no
// bench error.  Also:
//   +SPI_LOG=<file>  every SPI frame (a run of constant sd_cs; frames with
//                    no select are written only if bytes were clocked), one
//                    line each, no timestamps:
//                      <cs> <MOSI bytes> / <MISO bytes>
//                    <cs> = ~sd_cs without bit 0, i.e. the value of the
//                    Enable write (0x20 OSD, 0x10 FPGA, 0x02 card, 0x00
//                    none; cfide drives sd_cs[0] low with every Enable and
//                    high with every Disable write), bytes in hex as cfide
//                    shifted them (MISO as cfide sampled it)
//   === HandleUI KEYQ frame 20 at cycle <n>   the 20th OSD_CMD_KEYQ frame
//                    ("20 98 ..."): HandleUI's key-queue read, once per pass
//                    of main()'s loop (no kickstart: the fatal-error loop,
//                    which does not call HandleFpga, see README.md)
//   === SPI frames <n>, HandleFpga frames <n>, KEYQ frames <n>  at the end;
//                    a HandleFpga frame is "10" with exactly six bytes 00
//   === OSD GAP min <n> over <m> bytes     OSD reply reads (frames whose
//                    command is OSD_CMD_VERSION 0x88 or OSD_CMD_KEYQ 0x98,
//                    the firmware's SPI_reply() users): per reply byte, the
//                    idle clk_114 cycles from the end of the previous byte
//                    (the ack of its read-back: cfide holds every SPI access
//                    while SD_busy is high) to the start of this byte (the
//                    request of its DATA write), counted as
//                    sim/spi_cdc/tb_spi_cdc.v's +GAP (the clk_114 edges
//                    strictly between the ack edge and the edge that raises
//                    the next request; the TIMER reads of SPIN in between
//                    count as idle); <m> = reply bytes.  That is the
//                    interval tb_spi_cdc's OSD_MIN_GAP = 40 constrains
//                    (userio_osd loads the reply byte on the first sck edge
//                    of that byte).  A second line gives the write ->
//                    read-back gap, which userio_osd never sees; a third
//                    where the minimum was (cycle, command, reply byte).
//                    A minimum below +OSD_MIN_GAP=<n> (default 40, the
//                    reporting threshold of tb_spi_cdc; its OSD failures
//                    start below ~32, 1e135e7) is a BENCH ERROR: the run
//                    fails.  Covered: the one OSD_CMD_VERSION frame and the
//                    first reply byte of each OSD_CMD_KEYQ frame (the stub
//                    answers count 0), not the per-key loop of osd.c.
//   === STACK low <hex> (<n> bytes used)   the lowest byte address the CPU
//                    writes below 0x2000 after the first read of 0x2000
//   OSD_RDY (Phase 4 Task 11): cfide's osd_rx_seq is the stub's (the
//   userio_osd model there, +STUB_RDY_DLY=<clk_114 cycles>, default 40;
//   -1 = frozen).  For every reply byte of an OSD_CMD_VERSION / KEYQ frame
//   (the OSD GAP samples above):
//   === OSD RDY early <n> of <m> reply bytes   reply bytes whose DATA write
//                    request came while the stub still had an osd_rx_seq
//                    step due (it had not caught up with the bytes sent):
//                    the firmware read HOST_REQ too early or ignored it.
//                    A BENCH ERROR if n > 0, except with the sequence
//                    frozen (every reply byte is early there by design)
//   === OSD RDY polls <p>, reply bytes after a last poll of 0 <z>
//                    HOST_REQ reads, and the reply bytes whose last HOST_REQ
//                    read before the write returned 0 (SPI_reply() gave up
//                    at its bound: one osd_rdy_timeouts count each)
//   === OSD RDY timeouts <t> (osd_rdy_timeouts at <addr>)   the firmware's
//                    counter in the SDRAM model at the end, with
//                    +OSD_RDY_TO_ADDR=<hex> (run.sh takes the address from
//                    the firmware's .map); a BENCH ERROR if t != z
// UART lines may be up to 4095 characters (the boot ROM prints "00" per
// sector of the firmware it loads, on one line).
//
// Plusargs: +TEST=<name> +SLAT=<n> +SJIT=<n> +SEED=<n> +SDRAM_HEX=<file>
//           +SD_IMG=<file> and the model's +SD_* (SDCARD only; +SD_SAVE=<file>:
//           the card as the run left it, written before the verdict)
//           +TIMEOUT=<clk_114 cycles> (default 3000000) +VERBOSE=1 (hw log),
//           +VERBOSE=2 (also every change of the bus address)
// Parameter: EXTRA_WS (xelab -generic_top EXTRA_WS=<n>), the bridge's
//           rv_extra_ws: idle cycles before every RISC-V request.
//
// HB_GHDL (run.sh SIM=verilator): the bridge (with the ROM) and cfide are
// the Verilog that ghdl --synth made of the VHDL.  Their generics are fixed
// at the conversion (no parameters here), identifiers are lower case and a
// generate label is folded into the instance name (genrv.myrv ->
// genrv_myrv); the HM_* names below follow that.  The bench checks that the
// converted bridge has this bench's EXTRA_WS.
`timescale 1ns/1ps

`ifdef HB_GHDL
`define HM_RV      hostcpu.genrv_myrv
`define HM_SD_BUSY mycfide.sd_busy
`else
`define HM_RV      hostcpu.genrv.myrv
`define HM_SD_BUSY mycfide.SD_busy
`endif

module tb_host_bridge #(
  parameter EXTRA_WS = 0
);

  real T114 = 8.8154;

  reg clk114 = 1'b0;
  always #(T114/2.0) clk114 = ~clk114;
  reg [1:0] div = 2'd0;
  reg clk28 = 1'b0;
  always @(posedge clk114) begin
    div <= div + 2'd1;
    if (div == 2'd0) clk28 <= #(0.3) 1'b1;
    if (div == 2'd2) clk28 <= #(0.3) 1'b0;
  end

  reg n_reset = 1'b0, cpu_reset_n = 1'b0;
  // The bridge asserts its reset asynchronously on a falling edge of nReset
  // (rv_hostcpu.v: always @(posedge clk or negedge reset_n)); a level that is
  // low from time 0 gives it none, so until the first clk_114 edge its state
  // is whatever the simulator starts with (random with XRAND=1: a phantom hw
  // access and a counted busy cycle at cycle 0).  One 1 -> 0 edge, before the
  // first clk_114 edge (4.4 ns).  Nothing that reads cpu_reset_n can see it:
  // the DUT's outputs change on clock edges only.
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

`ifdef HB_GHDL
  EightThirtyTwo_Bridge hostcpu (
`else
  EightThirtyTwo_Bridge #(.cpu_riscv(1'b1), .rv_extra_ws(EXTRA_WS)) hostcpu (
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
  wire [7:0] sd_cs;
  wire       sd_clk, sd_do, miso;
  wire       scandoubler, audio_ena, audio_clear;
  reg        vbl_int = 1'b0;     // t_irq: pulses from checkpoint 1
  reg        amiga_req = 1'b0;   // t_irqctl: controller source 2
  reg        i2c_ext_int = 1'b0; // t_irqctl: controller source 3 (ADV7511 INT)
  reg [15:4] irq_src = 12'h0;    // t_irqctl: controller sources 4..15
  reg [1:0]  osd_rx_seq = 2'd0;  // t_osdrdy: userio_osd's reply sequence
  wire [1:0] cfide_rx_seq;       // cfide's: the stub's under FWBOOT, else osd_rx_seq

  // The generics below are the only copy: run.sh (cfide_generics) reads them
  // from this "cfide #( ... ) mycfide (" block for the GHDL conversion and
  // stops if they are not exactly the boolean generics of the cfide entity.
  // havei2c is HB_HAVEI2C: true under FWBOOT, where the firmware polls the
  // I2C status register (0xFFFFFF64) and cfide without the master returns X
  // there (xsim; 0 in Verilator); the real i2c_master_mmio with no slave
  // answers every transfer with a NACK.  run.sh takes the two values from
  // the two define lines.
`ifdef FWBOOT
`define HB_HAVEI2C 1'b1   // FWBOOT
`else
`define HB_HAVEI2C 1'b0   // other runs
`endif
`ifdef HB_GHDL
  cfide mycfide (     // converted with the generics below
`else
  cfide #(
    .spimux(1'b0), .havespirtc(1'b0), .havei2c(`HB_HAVEI2C), .havevpos(1'b0)
  ) mycfide (
`endif
    .sysclk(clk114), .n_reset(n_reset),
    .addr(hostaddr), .d(hostWR[15:0]), .q(hw_d), .req(hw_req), .wr(host_we), .ack(hw_ack),
    .sd_di(miso), .sd_cs(sd_cs), .sd_clk(sd_clk), .sd_do(sd_do),
    .sd_dimm(miso), .sd_ack(1'b1),
    .debugTxD(), .debugRxD(1'b1), .menu_button(1'b1),
    .xadc_temp(16'h0000),
    .scandoubler(scandoubler), .audio_ena(audio_ena), .audio_clear(audio_clear),
    .audio_buf(1'b1), .audio_amiga(1'b0), .vbl_int(vbl_int), .interrupt(cfide_int),
    .irq_src(irq_src),
    .c64_keys(64'hFFFFFFFFFFFFFFFF), .amiga_key(), .amiga_key_stb(),
    .amiga_addr(8'h00), .amiga_d(16'h0000), .amiga_q(),
    .amiga_req(amiga_req), .amiga_wr(1'b0), .amiga_ack(),
    .rtc_q(),
    .scl_i(1'b1), .scl_o(), .scl_t(), .sda_i(1'b1), .sda_o(), .sda_t(),
    .i2c_ext_int(i2c_ext_int),
    .pos_data_q(),
    .osd_rx_seq(cfide_rx_seq),
    .clk_28(clk28), .tick_in(1'b1)
  );

  // --------------------------------------------------- bench state, errors
  integer errors = 0;
  integer cyc = 0;
  always @(posedge clk114) cyc <= cyc + 1;
  reg [8*16-1:0] test;
  integer verbose = 0, timeout = 3000000;
  reg     is_boot = 1'b0;          // +TEST=boot or boot_nofile

  task bench_error(input [8*120-1:0] msg);
    begin
      $display("BENCH ERROR at cycle %0d: %0s", cyc, msg);
      errors = errors + 1;
    end
  endtask

  // ------------------------------------------------------ SPI capture slave
  // sd_clk idles high; cfide changes sd_do on its falling edge and samples
  // MISO on its rising edge.  The slave drives MISO from the falling edge and
  // samples MOSI on the rising edge, while sd_cs[1] is low.  MISO script:
  // byte n = 8'hA5 + 8'h11 * n.
  reg  [7:0] mosi_log [0:255];
  integer    mosi_n = 0, miso_n = 0, spi_bit = 0;
  reg  [7:0] mosi_sr = 8'h00, miso_cur = 8'hFF;
  reg        miso_r = 1'b1;
`ifdef SDCARD
  // The 8 MB card of tools/sim/mkcard.sh: IMG_SECTORS = 16384 (the model's
  // default 65536 costs about a minute and 0.5 GB in the simulator).
  // FWBOOT: the 16 MB card of fwboot/Makefile.
`ifdef FWBOOT
  localparam CARD_SECTORS = 32768;
`else
  localparam CARD_SECTORS = 16384;
`endif
  wire       card_miso;
  sd_spi_model #(.IMG_SECTORS(CARD_SECTORS)) card (
    .cs_n(sd_cs[1]), .sck(sd_clk), .mosi(sd_do), .miso(card_miso)
  );
`ifdef FWBOOT
  wire       stub_miso;
  wire [1:0] stub_rx_seq;
  minimig_spi_stub stub (
    .clk(clk114), .n_reset(n_reset), .cs(sd_cs), .sck(sd_clk), .mosi(sd_do), .miso(stub_miso),
    .osd_rx_seq(stub_rx_seq)
  );
  assign miso = sd_cs[1] === 1'b0 ? card_miso : stub_miso;
  assign cfide_rx_seq = stub_rx_seq;
`else
  assign miso = card_miso;
  assign cfide_rx_seq = osd_rx_seq;
`endif
`else
  assign miso = miso_r;
  assign cfide_rx_seq = osd_rx_seq;
`endif

  function [7:0] miso_script(input integer n);
    miso_script = 8'hA5 + 8'h11 * n[7:0];
  endfunction

  always @(negedge sd_clk) if (n_reset && sd_cs[1] === 1'b0) begin
    if (spi_bit == 0) begin
      miso_cur = miso_script(miso_n);
      miso_n = miso_n + 1;
    end
    miso_r <= #2 miso_cur[7 - spi_bit];
  end
  always @(posedge sd_clk) if (n_reset && sd_cs[1] === 1'b0) begin
    mosi_sr = {mosi_sr[6:0], sd_do};
    spi_bit = spi_bit + 1;
    if (spi_bit == 8) begin
      if (verbose) $display("%0d SPI byte out %h in %h", cyc, mosi_sr, miso_cur);
      mosi_log[mosi_n & 255] = mosi_sr;
      mosi_n = mosi_n + 1;
      spi_bit = 0;
    end
  end
  always @(posedge sd_cs[1]) if (n_reset && spi_bit != 0) begin
    bench_error("sd_cs[1] rose in the middle of an SPI byte");
    spi_bit = 0;
  end

  // CS pattern log: every change of sd_cs after reset
  reg [7:0] cs_log [0:255];
  integer   cs_n = 0;
  always @(sd_cs) if (n_reset && cpu_reset_n) begin
    cs_log[cs_n & 255] = sd_cs;
    cs_n = cs_n + 1;
  end

`ifdef SDCARD
  // ErrorCode(): OSD command bytes under sd_cs[5]; "08 00" (OSD_CMD_RST,
  // release) ends every ErrorCode() call and nothing else in the boot ROM
  integer   osd_n = 0, osd_bit = 0;
  reg [7:0] osd_sr = 8'h00, osd_b0 = 8'h00, osd_b1 = 8'h00;
  reg [15:0] errcode = 16'hFFFF;   // last reported
  integer   n_errcode = 0;
  always @(negedge sd_cs[5]) begin osd_n = 0; osd_bit = 0; end
  always @(posedge sd_clk) if (n_reset && sd_cs[5] === 1'b0) begin
    osd_sr = {osd_sr[6:0], sd_do};
    osd_bit = osd_bit + 1;
    if (osd_bit == 8) begin
      if (osd_n == 0) osd_b0 = osd_sr;
      if (osd_n == 1) osd_b1 = osd_sr;
      osd_n = osd_n + 1;
      osd_bit = 0;
    end
  end
  // 1 ns after the sd_cs edge (a cfide register: it changes on a clk_114
  // edge), when cyc has counted that edge in every simulator.  Not under
  // FWBOOT: the firmware sends 08 00 frames of its own.
`ifndef FWBOOT
  always @(posedge sd_cs[5]) begin
    #1;
    if (n_reset && cpu_reset_n && osd_n == 2 && osd_b0 == 8'h08 && osd_b1 == 8'h00) begin
      errcode = ram.hw_at(32'h0010000A);
      n_errcode = n_errcode + 1;
      $display("ERRORCODE: %h", errcode);
      $display("=== ErrorCode at cycle %0d", cyc);
    end
  end
`endif

`endif

  // pin toggles
  integer sd_tog = 0, ae_tog = 0;
  always @(scandoubler) if (cpu_reset_n) sd_tog = sd_tog + 1;
  always @(audio_ena)   if (cpu_reset_n) ae_tog = ae_tog + 1;

  // ----------------------------------------------- hw bus snoop and checks
  // (sim/common/hostmon.vh: the snoop checks, UART printer, FWBOOT monitors, end-of-run counters)
`ifdef FWBOOT
`define HM_OSD_GAP_HOOK   // hm_osd_gap_hook below: the OSD RDY monitor
`endif
`include "hostmon.vh"

`ifdef FWBOOT
  // ------------------------------------------------ FWBOOT: OSD RDY (header)
  // hm_osd_gap_hook runs at the clk_114 edge that first sees a reply byte's
  // DATA write request; the stub's rdy_pending and the HOST_REQ read below
  // are from before that edge (non-blocking in the stub; a read completes
  // at least two edges before the next request, hostmon's OSD GAP).
  integer rdy_early = 0, rdy_early_cyc = -1, rdy_polls = 0, rdy_zero_last = 0;
  integer rdy_to_addr = -1;          // +OSD_RDY_TO_ADDR
  reg     rdy_last_valid = 1'b0, rdy_last = 1'b0;   // the last HOST_REQ read since the previous reply write
  always @(posedge clk114) if (cpu_reset_n && hw_done && !host_we && hwa == 32'hFFFFFFB4) begin
    rdy_polls = rdy_polls + 1;
    rdy_last_valid = 1'b1;
    rdy_last = hw_d[0];
  end
  task hm_osd_gap_hook(input [7:0] cmd, input integer k, input integer gap);
    begin
      if (stub.rdy_pending) begin
        rdy_early = rdy_early + 1;
        if (rdy_early_cyc < 0) rdy_early_cyc = cyc;
      end
      if (rdy_last_valid && !rdy_last) rdy_zero_last = rdy_zero_last + 1;
      rdy_last_valid = 1'b0;
    end
  endtask

  // the firmware's osd_rdy_timeouts (a little-endian long at rdy_to_addr:
  // byte A+0 is the upper byte of halfword A, as t_lanes checks)
  task rdy_final;
    reg [15:0] h0, h2;
    reg [31:0] v;
    begin
      if (stub.rdy_dly < 0)
        $display("=== OSD RDY early %0d of %0d reply bytes (stub sequence frozen: not an error)", rdy_early, og_bytes);
      else
        $display("=== OSD RDY early %0d of %0d reply bytes (stub delay %0d clk_114)", rdy_early, og_bytes, stub.rdy_dly);
      if (rdy_early_cyc >= 0) $display("=== OSD RDY (info) first early reply byte at cycle %0d", rdy_early_cyc);
      $display("=== OSD RDY polls %0d, reply bytes after a last poll of 0 %0d", rdy_polls, rdy_zero_last);
      if (rdy_early > 0 && stub.rdy_dly >= 0)
        bench_error("OSD RDY early: a reply byte started before the stub's osd_rx_seq caught up");
      if (rdy_to_addr >= 0) begin
        h0 = ram.hw_at(rdy_to_addr);       // bytes A+0, A+1
        h2 = ram.hw_at(rdy_to_addr + 2);   // bytes A+2, A+3
        v = {h2[7:0], h2[15:8], h0[7:0], h0[15:8]};
        $display("=== OSD RDY timeouts %0d (osd_rdy_timeouts at %h)", v, rdy_to_addr);
        if (v != rdy_zero_last)
          bench_error("OSD RDY timeouts: the firmware's count is not the reply bytes after a last poll of 0");
      end else
        $display("=== OSD RDY timeouts unknown (no +OSD_RDY_TO_ADDR)");
    end
  endtask
`endif

  integer gap = 0, gap_min = 1000000, gap_max = 0, last_done = -1;
  integer b2b_on = 0;
  reg        done = 1'b0;
  reg [31:0] done_code = 32'h0;

  // VERBOSE=2: every change of the bridge's (registered) CPU address/write
  reg [31:2] addr_d = 30'h0;
  reg        we_d = 1'b0;
  always @(posedge clk114) if (verbose >= 2 && cpu_reset_n) begin
    if (hostaddr !== addr_d || host_we !== we_d)
      $display("%0d bus %s %h q=%h sel=%b", cyc, host_we ? "W" : "R", {hostaddr, 2'b00}, hostWR, hostsel);
    addr_d <= hostaddr;
    we_d <= host_we;
  end

  always @(posedge clk114) begin
    hm_hw_cycle;
    if (hw_req && !hw_req_d) begin
      if (b2b_on && last_done >= 0) begin
        gap = cyc - last_done;
        if (gap < gap_min) gap_min = gap;
        if (gap > gap_max) gap_max = gap;
      end
      if (verbose) $display("%0d HW %s %h d=%h", cyc, host_we ? "W" : "R", hwa, hostWR);
    end
    if (hw_done) begin
      last_done = cyc;
      hm_hw_done;
      if (host_we && hwa == 32'hFFFFFF00) checkpoint(hostWR);
      if (host_we && hwa == 32'hFFFFFF04 && !done) begin
        done = 1'b1;
        done_code = hostWR;
      end
    end
  end

  // --------------------------------------------- test-specific checkpoints
  integer mosi_base = 0, cs_base = 0, sd_base = 0, ae_base = 0, busy_base = 0;
  reg [7:0] spibusy_bytes [0:7];
  initial begin
    spibusy_bytes[0] = 8'h01; spibusy_bytes[1] = 8'h80; spibusy_bytes[2] = 8'h55; spibusy_bytes[3] = 8'hAA;
    spibusy_bytes[4] = 8'hFF; spibusy_bytes[5] = 8'h00; spibusy_bytes[6] = 8'h3C; spibusy_bytes[7] = 8'hC3;
  end

  task expect_pin(input [8*24-1:0] name, input [7:0] got, input [7:0] want);
    begin
      if (got !== want) begin
        $display("BENCH ERROR at cycle %0d: %0s = %h, want %h", cyc, name, got, want);
        errors = errors + 1;
      end
    end
  endtask

  // c28_step: 1 ns after the next clk_28 rising edge.  The bench changes
  // cfide's clk_28-sampled inputs there, never in the time step of a clk_28
  // edge: a change made by a process that resumes on the edge races with
  // cfide's clk_28 processes on that edge (the simulators order it
  // differently).
  task c28_step;
    begin
      @(posedge clk28);
      #1;
    end
  endtask

  // t_irq pulse generator: vbl_int high for one clk_28 cycle (set after a
  // clk_28 edge, cleared after the next: exactly one edge of cfide sees it),
  // NPULSE times, PULSE_GAP clk_114 cycles apart.
  localparam NPULSE = 20, PULSE_GAP = 2000;
  integer pulses_sent = 0;
  event   pulses_go;
  always @(pulses_go) begin : pulser
    integer k;
    for (k = 0; k < NPULSE; k = k + 1) begin
      repeat (PULSE_GAP) @(posedge clk114);
      c28_step;
      vbl_int <= 1'b1;
      c28_step;
      vbl_int <= 1'b0;
      pulses_sent = pulses_sent + 1;
      if (verbose) $display("%0d vbl_int pulse %0d", cyc, pulses_sent);
    end
  end

  // ---------------------------------------------------------- t_irqctl
  // Checkpoints (TIME <n>) of sw/t_irqctl.c; a pulse is high for one clk_28
  // cycle (exactly one clk_28 edge of cfide sees it), as the t_irq pulser.
  //   10  one vbl_int pulse                  20  8 vbl_int pulses, 2000 apart
  //   30  vbl_int + irq_src[5] in the same clk_28 cycle, amiga_req rises one
  //       clk_28 later (high for 4 clk_28)
  //   40  test 4 iteration: irq_src[6] pulse (8 clk_114) at once, a second
  //       one placed against the iteration's IRQ_PENDING read (below)
  //   41  end of the test 4 sweep: coverage check
  //   50  irq_src[7] pulse                   70  irq_src[9] pulse
  //   60 / 61  irq_src[8] high / low (held)  90 / 91  irq_src[9] high / low
  //   92 / 93  cfide's interrupt output must be 1 / 0
  //   100 / 101  irq_src[10] high / low      102  irq_src[10] pulse
  //   120 / 121  i2c_ext_int (source 3) high / low
  //   99  end: every action was taken
  // Test 4 ("set wins"): a bit returned by an IRQ_PENDING read whose source
  // rises again in the clk_28 cycle of that read's clear stays pending.  Per
  // iteration the CPU (interrupts off, MASK = bit 6) does STAMP 40, four
  // IRQ_RAW reads, read r1 of IRQ_PENDING, a wait, reads r2 and r3.  The
  // first pulse sets bit 6 before r1.  The bench measures, at clk_28 edges,
  // the edge of r1's clear (cfide's irq_seen rising on that read) and the
  // edges where bit 6's edge detector fired (irq_prev[6] rising); iteration 1
  // raises the second pulse late (STAMP + 300) and measures the distance d
  // from STAMP to the clear; iterations 2..25 raise it at STAMP + d - 10 +
  // (-6..5), which moves the second edge from before r1's clear through the
  // clear cycle (4 of every 12) to after it.  Snooped read data must be
  // r1 = 0x0040, r2 = 0x0040 if the second edge is at or after the clear
  // cycle else 0, r3 = 0; at least 2 iterations must hit the clear cycle and
  // at least one each before and after it.
  // vbl_int pulses per run: t_irqctl IC_PULSES, t_irqapi IA_PULSES (one per
  // STAMP 10 in tests 1, 8 and 10, 8 for STAMP 20 in test 2, one for STAMP 30
  // in test 3)
  localparam IC_PULSES = 10, IA_PULSES = 12, T4_ITER = 25;
  integer ic_cmd = 0, ic_busy = 0, ic_vbl = 0, ic_end = 0;
  event   ic_go;
  integer t4_iter = 0, t4_c0 = 0, t4_d = 0, t4_clr = -1, t4_set1 = -1, t4_set2 = -1;
  integer t4_nrd = 0, t4_raise = 0, t4_early = 0, t4_coinc = 0, t4_late = 0;
  reg     t4_on = 1'b0;
  reg [15:0] t4_r0 = 16'h0, t4_r1 = 16'h0, t4_r2 = 16'h0;
  // cfide internals, copied to bench wires first (xsim: a select taken
  // straight on a hierarchical VHDL signal is not reliable)
  wire [15:0] ic_prev = mycfide.irq_prev;
  wire        ic_seen = mycfide.irq_seen;
  wire        ic_p6 = ic_prev[6];
  reg         ic_seen_d = 1'b0, ic_p6_d = 1'b0;

  task ic_vbl_pulse;
    begin
      c28_step; vbl_int <= 1'b1;
      c28_step; vbl_int <= 1'b0;
      ic_vbl = ic_vbl + 1;
    end
  endtask

  task ic_src_pulse(input integer b);
    begin
      c28_step; irq_src[b] <= 1'b1;
      c28_step; irq_src[b] <= 1'b0;
    end
  endtask

  always @(ic_go) begin : ic_proc
    integer k, tgt;
    ic_busy = 1;
    case (ic_cmd)
      10: ic_vbl_pulse;
      20: for (k = 0; k < 8; k = k + 1) begin
            repeat (2000) @(posedge clk114);
            ic_vbl_pulse;
          end
      30: begin
            c28_step; vbl_int <= 1'b1; irq_src[5] <= 1'b1;
            c28_step; vbl_int <= 1'b0; irq_src[5] <= 1'b0; amiga_req <= 1'b1;
            ic_vbl = ic_vbl + 1;
            repeat (4) c28_step; amiga_req <= 1'b0;
          end
      40: begin
            @(posedge clk114); irq_src[6] <= 1'b1;
            repeat (8) @(posedge clk114); irq_src[6] <= 1'b0;
            if (t4_iter == 1) tgt = t4_c0 + 300;
            else tgt = t4_c0 + t4_d - 10 + ((t4_iter - 2) % 12) - 6;
            if (tgt < cyc + 8) begin
              bench_error("t_irqctl test 4: the IRQ_PENDING read follows STAMP 40 too closely for the sweep");
              tgt = cyc + 8;
            end
            while (cyc < tgt) @(posedge clk114);
            irq_src[6] <= 1'b1;
            t4_raise = cyc;
            repeat (8) @(posedge clk114); irq_src[6] <= 1'b0;
          end
      50: ic_src_pulse(7);
      70: ic_src_pulse(9);
      102: ic_src_pulse(10);
      default: bench_error("t_irqctl: unknown pulse command");
    endcase
    ic_busy = 0;
  end

  // test 4 probes, sampled 1 ns after each clk_28 edge
  always @(posedge clk28) begin
    #1;
    if (t4_on) begin
      if (ic_seen === 1'b1 && ic_seen_d === 1'b0 && hw_req === 1'b1 && host_we === 1'b0 &&
          hwa == 32'hFFFFFF30 && t4_clr < 0)
        t4_clr = cyc;
      if (ic_p6 === 1'b1 && ic_p6_d === 1'b0) begin
        if (t4_set1 < 0) t4_set1 = cyc;
        else if (t4_set2 < 0) t4_set2 = cyc;
        else bench_error("t_irqctl test 4: a third bit-6 edge in one iteration");
      end
    end
    ic_seen_d = ic_seen;
    ic_p6_d = ic_p6;
  end

  // test 4 read data (IRQ_PENDING reads of the iteration)
  always @(posedge clk114) if (t4_on && hw_done && !host_we && hwa == 32'hFFFFFF30) begin
    if (t4_nrd == 0) t4_r0 = hw_d;
    if (t4_nrd == 1) t4_r1 = hw_d;
    if (t4_nrd == 2) t4_r2 = hw_d;
    t4_nrd = t4_nrd + 1;
  end

  task t4_finish;
    reg [15:0] exp1;
    begin
      if (t4_iter > 0) begin
        if (t4_clr < 0 || t4_set1 < 0 || t4_set2 < 0 || t4_nrd != 3) begin
          $display("BENCH ERROR at cycle %0d: t_irqctl test 4 iteration %0d incomplete: clear %0d, edges %0d %0d, %0d IRQ_PENDING reads",
                   cyc, t4_iter, t4_clr, t4_set1, t4_set2, t4_nrd);
          errors = errors + 1;
        end else begin
          if (t4_set1 >= t4_clr) bench_error("t_irqctl test 4: the first bit-6 edge is not before the read");
          exp1 = t4_set2 >= t4_clr ? 16'h0040 : 16'h0000;
          if (t4_set2 < t4_clr) t4_early = t4_early + 1;
          else if (t4_set2 == t4_clr) t4_coinc = t4_coinc + 1;
          else t4_late = t4_late + 1;
          $display("t_irqctl test 4 iteration %0d: second pulse at STAMP+%0d, clear at STAMP+%0d, its edge at STAMP+%0d (%0s), reads %h %h %h",
                   t4_iter, t4_raise - t4_c0, t4_clr - t4_c0, t4_set2 - t4_c0,
                   t4_set2 < t4_clr ? "before" : t4_set2 == t4_clr ? "SAME CYCLE" : "after", t4_r0, t4_r1, t4_r2);
          if (t4_r0 !== 16'h0040 || t4_r1 !== exp1 || t4_r2 !== 16'h0000) begin
            $display("BENCH ERROR at cycle %0d: t_irqctl test 4 (set wins) iteration %0d: reads %h %h %h, want 0040 %h 0000",
                     cyc, t4_iter, t4_r0, t4_r1, t4_r2, exp1);
            errors = errors + 1;
          end
          t4_d = t4_clr - t4_c0;
        end
      end
    end
  endtask

  task t_irqctl_checkpoint(input [31:0] v);
    begin
      case (v)
        10, 20, 30, 50, 70, 102: begin
             if (ic_busy) bench_error("t_irqctl: a pulse command while the previous one runs");
             ic_cmd = v;
             -> ic_go;
           end
        40: begin
             if (ic_busy) bench_error("t_irqctl: STAMP 40 while the previous pulse runs");
             t4_finish;
             t4_iter = t4_iter + 1;
             t4_c0 = cyc;
             t4_clr = -1; t4_set1 = -1; t4_set2 = -1; t4_nrd = 0;
             t4_on = 1'b1;
             ic_cmd = 40;
             -> ic_go;
           end
        41: begin
             t4_finish;
             t4_on = 1'b0;
             $display("t_irqctl test 4: %0d iterations, second edge before / in / after the clear cycle: %0d / %0d / %0d",
                      t4_iter, t4_early, t4_coinc, t4_late);
             if (t4_coinc < 2) bench_error("t_irqctl test 4: the sweep hit the clear cycle fewer than 2 times");
             if (t4_early < 1 || t4_late < 1) bench_error("t_irqctl test 4: the sweep missed one side of the clear cycle");
           end
        60:  irq_src[8] <= 1'b1;
        61:  irq_src[8] <= 1'b0;
        90:  irq_src[9] <= 1'b1;
        91:  irq_src[9] <= 1'b0;
        92:  expect_pin("cfide interrupt", cfide_int, 1'b1);
        93:  expect_pin("cfide interrupt", cfide_int, 1'b0);
        100: irq_src[10] <= 1'b1;
        101: irq_src[10] <= 1'b0;
        120: i2c_ext_int <= 1'b1;
        121: i2c_ext_int <= 1'b0;
        99: begin
             ic_end = 1;
             $display("t_irqctl: %0d vbl_int pulses, %0d test 4 iterations", ic_vbl, t4_iter);
             expect_pin("t_irqctl vbl_int pulses", ic_vbl, test == "t_irqctl" ? IC_PULSES : IA_PULSES);
             if (test == "t_irqctl") expect_pin("t_irqctl test 4 iterations", t4_iter, T4_ITER);
             if (ic_busy) bench_error("t_irqctl: a pulse still running at the end");
           end
        default: bench_error("t_irqctl: unknown checkpoint");
      endcase
    end
  endtask

  // ---------------------------------------------------------- t_osdrdy
  // Checkpoints (TIME <n>) of sw/t_osdrdy.S:
  //   10..13  osd_rx_seq <= n - 10 (set at the clk_114 edge of the TIME
  //           write's completion, 0.3 ns before any clk_28 edge, so the
  //           CPU's next HOST_REQ read sees it)
  //   20      arm the resync measurement: the cycle sd_cs[5] rises (the OSD
  //           deselected), then every HOST_REQ read that completes after it
  //   21      the resync: at least one read after the deselect returned 0,
  //           and the first that returned 1 completed at least 64 cycles
  //           after the deselect (cfide resyncs after 64 idle sysclk cycles)
  //   99      end: STAMP 21 was checked
  reg     or_on = 1'b0, or_end = 1'b0;
  integer or_desel = -1, or_zero = 0, or_ready = -1;

  always @(posedge sd_cs[5]) begin
    #1;   // when cyc has counted the edge (see the ErrorCode monitor)
    if (or_on && or_desel < 0) or_desel = cyc;
  end
  always @(posedge clk114) if (or_on && or_desel >= 0 && hw_done && !host_we && hwa == 32'hFFFFFFB4) begin
    if (hw_d[0] === 1'b0 && or_ready < 0) or_zero = or_zero + 1;
    if (hw_d[0] === 1'b1 && or_ready < 0) or_ready = cyc;
  end

  task t_osdrdy_checkpoint(input [31:0] v);
    begin
      case (v)
        10: osd_rx_seq <= 2'd0;
        11: osd_rx_seq <= 2'd1;
        12: osd_rx_seq <= 2'd2;
        13: osd_rx_seq <= 2'd3;
        20: begin or_on = 1'b1; or_desel = -1; or_zero = 0; or_ready = -1; end
        21: begin
              $display("t_osdrdy resync: OSD deselected at cycle %0d, %0d HOST_REQ reads 0 after it, the first 1 at cycle %0d (+%0d)",
                       or_desel, or_zero, or_ready, or_ready - or_desel);
              if (or_desel < 0) bench_error("t_osdrdy: the OSD select did not rise after STAMP 20");
              else if (or_zero < 1) bench_error("t_osdrdy: no HOST_REQ read returned 0 after the deselect");
              else if (or_ready < 0) bench_error("t_osdrdy: no HOST_REQ read returned 1 after the deselect");
              else if (or_ready - or_desel < 64) bench_error("t_osdrdy: OSD_RDY came back less than 64 cycles after the deselect");
              or_on = 1'b0;
            end
        99: or_end = 1'b1;
        default: bench_error("t_osdrdy: unknown checkpoint");
      endcase
    end
  endtask

  task checkpoint(input [31:0] v);
    integer k;
    begin
      $display("=== TIME %0d cycle %0d", v, cyc);
      if (test == "t_osdrdy") begin
        t_osdrdy_checkpoint(v);
      end else if (test == "t_hwoff") begin
        case (v)
          1: expect_pin("scandoubler", scandoubler, 1'b0);
          2: expect_pin("scandoubler", scandoubler, 1'b1);
          3: expect_pin("audio_clear,audio_ena", {audio_clear, audio_ena}, 2'b01);
          4: expect_pin("audio_clear,audio_ena", {audio_clear, audio_ena}, 2'b10);
          5: expect_pin("audio_clear,audio_ena", {audio_clear, audio_ena}, 2'b00);
          6: begin expect_pin("sd_cs", sd_cs, 8'hFC); mosi_base = mosi_n; end
          7: begin
               expect_pin("SPI bytes out", mosi_n - mosi_base, 1);
               expect_pin("SPI MOSI byte", mosi_log[mosi_base & 255], 8'h5A);
             end
          8: expect_pin("sd_cs", sd_cs, 8'hFF);
          default: bench_error("t_hwoff: unknown checkpoint");
        endcase
      end else if (test == "t_b2b") begin
        case (v)
          1: begin   // PLATFORM and AUDIO at 0, CS deselected: arm counters
               expect_pin("scandoubler", scandoubler, 1'b0);
               expect_pin("audio_ena", audio_ena, 1'b0);
               expect_pin("sd_cs", sd_cs, 8'hFF);
               sd_base = sd_tog; ae_base = ae_tog;
               gap_min = 1000000; gap_max = 0; last_done = -1; b2b_on = 1;
             end
          2: begin   // 64 PLATFORM writes 1,0,1,0,...
               $display("t_b2b PLATFORM: %0d scandoubler toggles, request gap %0d..%0d cycles",
                        sd_tog - sd_base, gap_min, gap_max);
               expect_pin("scandoubler toggles", sd_tog - sd_base, 64);
               expect_pin("scandoubler", scandoubler, 1'b0);
               gap_min = 1000000; gap_max = 0; last_done = -1;
             end
          3: begin   // 64 AUDIO writes
               $display("t_b2b AUDIO: %0d audio_ena toggles, request gap %0d..%0d cycles",
                        ae_tog - ae_base, gap_min, gap_max);
               expect_pin("audio_ena toggles", ae_tog - ae_base, 64);
               expect_pin("audio_ena", audio_ena, 1'b0);
               cs_base = cs_n;
               gap_min = 1000000; gap_max = 0; last_done = -1;
             end
          4: begin   // 32 CS writes 0x02, 0x03, ...
               $display("t_b2b SPI CS: %0d sd_cs changes, request gap %0d..%0d cycles",
                        cs_n - cs_base, gap_min, gap_max);
               expect_pin("sd_cs changes", cs_n - cs_base, 32);
               for (k = 0; k < 32 && k < cs_n - cs_base; k = k + 1)
                 expect_pin("sd_cs pattern", cs_log[(cs_base + k) & 255], (k & 1) ? 8'hFF : 8'hFC);
               b2b_on = 0;
             end
          default: bench_error("t_b2b: unknown checkpoint");
        endcase
      end else if (test == "t_irq" || test == "boot") begin
        case (v)
          1: -> pulses_go;
          2: begin
               $display("t_irq: %0d vbl_int pulses sent", pulses_sent);
               expect_pin("vbl_int pulses sent", pulses_sent, NPULSE);
             end
          default: bench_error("t_irq/boot: unknown checkpoint");
        endcase
      end else if (test == "t_irqctl" || test == "t_irqapi") begin
        t_irqctl_checkpoint(v);
      end else if (test == "t_spibusy") begin
        case (v)
          1: begin expect_pin("sd_cs", sd_cs, 8'hFC); mosi_base = mosi_n; busy_base = spi_busy_waits; end
          2: begin
               $display("t_spibusy: %0d bytes out, %0d DATA writes found SD_busy high",
                        mosi_n - mosi_base, spi_busy_waits - busy_base);
               expect_pin("SPI bytes out", mosi_n - mosi_base, 8);
               for (k = 0; k < 8 && k < mosi_n - mosi_base; k = k + 1)
                 expect_pin("SPI MOSI byte", mosi_log[(mosi_base + k) & 255], spibusy_bytes[k]);
               if (spi_busy_waits - busy_base < 7)
                 bench_error("t_spibusy: fewer than 7 DATA writes waited on SD_busy (not back to back)");
             end
          3: expect_pin("sd_cs", sd_cs, 8'hFF);
          default: bench_error("t_spibusy: unknown checkpoint");
        endcase
      end
    end
  endtask

  // ---------------------------------------------------- end-of-run checks
  task final_checks;
    reg [31:0] a;
    integer k;
    reg [15:0] want [0:15];
    begin
      if (test == "t_lanes") begin
        // stores at 0x3000.. (sw/t_lanes.S STORES): byte A+0 = upper byte of
        // halfword A (sdram_ctrl's lanes)
        want[0]  = 16'h7856; want[1]  = 16'h34AB;   // sw 0x12345678; sb 0xAB @+3
        want[2]  = 16'h01FF; want[3]  = 16'hFFFF;   // sw -1; sb 0x01 @+4
        want[4]  = 16'hFF02; want[5]  = 16'hFFFF;   // sw -1; sb 0x02 @+9
        want[6]  = 16'hFFFF; want[7]  = 16'h03FF;   // sw -1; sb 0x03 @+14
        want[8]  = 16'hEFBE; want[9]  = 16'h0000;   // sw 0; sh 0xBEEF @+16
        want[10] = 16'h0000; want[11] = 16'hFECA;   // sw 0; sh 0xCAFE @+22
        want[12] = 16'hBBAA; want[13] = 16'h9988;   // sw 0x8899AABB @+24
        want[14] = 16'h1122; want[15] = 16'h3344;   // sb 11 22 33 44 @+28..31
        for (k = 0; k < 16; k = k + 1) begin
          a = 32'h3000 + 2 * k;
          if (ram.hw_at(a) !== want[k]) begin
            $display("BENCH ERROR: SDRAM halfword %h = %h, want %h", a, ram.hw_at(a), want[k]);
            errors = errors + 1;
          end
        end
        $display("t_lanes: SDRAM halfwords 0x3000..0x301F checked");
      end
      if (test == "t_irqctl" && !ic_end) bench_error("t_irqctl: no STAMP 99 (the program stopped early)");
      if (test == "t_irqapi" && !ic_end) bench_error("t_irqapi: no STAMP 99 (the program stopped early)");
      if (test == "t_osdrdy" && !or_end) bench_error("t_osdrdy: no STAMP 99 (the program stopped early)");
    end
  endtask

  // ---------------------------------------------------------------- run
  // The run ends 8 cycles after DONE or at +TIMEOUT cycles, whichever comes
  // first: two watchers started at the reset release (no disable of a
  // named fork, which Verilator does not support).
  event run_go;
  reg   run_end = 1'b0;
  always @(run_go) begin
    wait (done);
    repeat (8) @(posedge clk114);
    run_end = 1'b1;
  end
  always @(run_go) begin
    repeat (timeout) @(posedge clk114);
    if (!run_end) begin
      if (test == "boot_nofile" || test == "fwboot" || test == "fwboot_trap" || test == "fwboot_cfg")
        $display("=== cycle limit %0d reached, no DONE", timeout);
      else bench_error("timeout, no DONE write");
      run_end = 1'b1;
    end
  end

  initial begin
    if (!$value$plusargs("TEST=%s", test)) test = "none";
    if (!$value$plusargs("VERBOSE=%d", verbose)) verbose = 0;
    if (!$value$plusargs("TIMEOUT=%d", timeout)) timeout = 3000000;
`ifdef FWBOOT
    if (!$value$plusargs("OSD_RDY_TO_ADDR=%h", rdy_to_addr)) rdy_to_addr = -1;
`endif
    is_boot = test == "boot" || test == "boot_nofile" || test == "fwboot" || test == "fwboot_trap"
              || test == "fwboot_cfg";
    hm_init;
    #1;
    $display("host-bridge bench: TEST=%0s SLAT=%0d SJIT=%0d EXTRA_WS=%0d", test, ram.slat, ram.sjit, EXTRA_WS);
`ifdef HB_GHDL
    if (`HM_RV.EXTRA_WS != EXTRA_WS)
      bench_error("the converted bridge has another rv_extra_ws than EXTRA_WS");
`endif
    // The resets are released at a clk_114 falling edge: the next rising
    // edge (the 20th, and the first after the 40th clk_28 edge) is the first
    // that sees them high, in every simulator.  A release in the time step of
    // a rising edge races with the clocked processes on that edge.
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
    final_checks;
    errors = errors + ram.errors;
    hm_final_hw;
`ifdef SDCARD
    card.save_image;   // the card as the run left it, to +SD_SAVE=<file> (fwboot_cfg); nothing without it
`ifdef RV_HOSTCPU_STATS
    hm_final_stats;
`endif
`ifdef FWBOOT
    hm_final_fwboot;
    rdy_final;
    if (test == "fwboot" || test == "fwboot_trap" || test == "fwboot_cfg") begin
      if (!done && errors == 0) $display("=== PASS");
      else $display("=== FAIL %0s: DONE %0d, bench errors %0d", test, done, errors);
    end else
`else
    $display("=== SD card: %0d ErrorCode calls, last %h", n_errcode, errcode);
`endif
    // one verdict line: Verilator's $finish ends the run only after the
    // block has gone on, so no verdict may follow a $finish
    if (test == "boot_nofile") begin
      if (!done && errors == 0 && n_errcode > 0 && errcode == 16'h00F0) $display("=== PASS");
      else $display("=== FAIL boot_nofile: DONE %0d, bench errors %0d, last ErrorCode %h", done, errors, errcode);
    end else
`endif
    if (done && done_code == 0 && errors == 0) $display("=== PASS");
    else if (!done) $display("=== FAIL timeout (bench errors %0d)", errors);
    else $display("=== FAIL code %0d, bench errors %0d", done_code, errors);
    $finish;
  end

endmodule
