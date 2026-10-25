// Monitor blocks shared by the host-CPU benches (sim/host_bridge/tb_host_bridge.v,
// later sim/l3).  `include"d inside the bench module, after the bus wires,
// bench_error, errors, cyc, is_boot, verbose and the cfide / bridge /
// SDRAM-model instances are declared.  Nothing here is bench-specific: the
// including module defines
//   HM_RV        hierarchical name of the rv_hostcpu instance (counters)
//   HM_SD_BUSY   hierarchical name of cfide's SD_busy
// and may define HM_CPU (the bridge instance, default hostcpu) and HM_RAM
// (the SDRAM model, default ram) before the include.  The bench signals it
// reads: clk114 clk28 n_reset cpu_reset_n hostaddr hostWR hostsel host_we
// hw_req hw_ack ram_req ram_ack sd_cs sd_clk sd_do miso.
//
// Contents, with the bench-side hooks the bench's per-cycle hw block calls:
//   hw bus snoop checks   stale ack, SPI accept (hm_hw_cycle / hm_hw_done), X on the bus
//   uart_print            the UART line printer (hm_hw_done collects the characters)
//   boot_seen             the first read of 0x2000 (SDCARD)
//   FWBOOT                $monitor off, the SPI frame log (+SPI_LOG), the OSD reply-gap
//                         monitor, the stack low-water monitor
//   hm_init               the plusargs of the above (call in the bench's initial block)
//   hm_final_hw / hm_final_stats / hm_final_fwboot   the end-of-run counter lines
// The text of the blocks is that of tb_host_bridge.v before Phase 4 Task 2,
// moved without change.  One addition (sim/l3): a bench that defines
// HM_FRAME_HOOK provides task hm_frame_hook(input at_end, input logged),
// which frame_close calls last, with the closed frame still in fr_*; logged
// is 1 for a frame spi.txt got a line for.  The L2 bench does not define it.
// Likewise HM_OSD_GAP_HOOK: task hm_osd_gap_hook(input [7:0] cmd, input
// integer k, input integer gap), called for every OSD GAP sample of a reply
// byte's write (reply byte k of command cmd; sim/l3's per-byte table).
//
// FWBOOT, for the differential (sim/l3 "Differential", spitrace.py norm):
//   +HW_LOG=<file>   hw.txt: one line per hw-register write the CPU makes
//                    except SPI DATA / CS (0x..E0 / E4), the UART (0x..F0..FF)
//                    and the L2 bench registers (0x..00 / 04):
//                      <frames> <ev> <addr> <value16>
//                    addr = the 24 address bits cfide decodes ({hostaddr,
//                    2'b00}[23:0]: 0xFFFFFFB0 is ffffb0), value16 =
//                    hostWR[15:0] (cfide's d), for a byte write (one
//                    hostsel bit) 00 and hostWR[7:0]: the bridge puts a
//                    stored byte on every lane and cfide's byte registers
//                    take d(7 downto 0); at the end, per SDRAM
//                    region the CPU wrote
//                    (host kickstart 0x100000..0x17ffff, AUDIO_BUFFER ring
//                    0x70000..0x7ffff),
//                      MEM <region> <first host byte> <bytes>
//                    which sim/l3/l3check.py memhash turns into
//                    "MEM <region> <sha256>" from the SDRAM dump
//   +UART_LOG=<file> uart.txt: every UART line as "<frames> <ev> <text>"
//   <frames> = the SPI frames logged so far (the line comes after spi.txt
//   line <frames>), <ev> = one counter over both files (their order within
//   one gap between frames).  No cycles: the CPUs' timing does not show.
`ifndef HM_CPU
`define HM_CPU hostcpu
`endif
`ifndef HM_RAM
`define HM_RAM ram
`endif


  // ----------------------------------------------- hw bus snoop and checks
  wire        hw_done  = hw_req && hw_ack;
  wire [31:0] hwa      = {hostaddr, 2'b00};
  wire        spi_data = hostaddr[23] && hostaddr[7:4] == 4'hE && hostaddr[3:2] == 2'b00;
  // the UART transmit register as cfide decodes it (rs232_select: a write
  // anywhere in 0x..F0..FF with address bit 23 set): the firmware writes
  // the word at 0xFFFFFFF0
  wire        uart_tx  = hostaddr[23] && hostaddr[7:4] == 4'hF;

  // stale ack: no clk_28 edge saw this request's hw_req.  Re-armed when
  // hw_req rises and when an access completes (below), so a request that
  // follows a completed one with hw_req still high is checked as well.
  reg c28_seen = 1'b0;
  always @(posedge hw_req) c28_seen = 1'b0;
  always @(posedge clk28) if (hw_req === 1'b1) c28_seen = 1'b1;

  // SPI DATA write accepted by cfide (its own condition, SD_busy hierarchical)
  reg spi_acc = 1'b0;
  integer spi_busy_waits = 0;     // DATA writes that found SD_busy high
  reg hw_req_d = 1'b0;
  always @(posedge hw_req) spi_acc = 1'b0;

  integer n_hw = 0, n_stale = 0;
`ifdef FWBOOT
  localparam UART_MAX = 4096;   // characters per UART line, see the header
`else
  localparam UART_MAX = 128;
`endif
  reg [7:0]  uart_line [0:UART_MAX-1];
  integer    uart_n = 0;
  integer    uart_first = -1;   // first UART write: main has returned
  // +HW_LOG / +UART_LOG (FWBOOT, see the header)
  integer    hw_fd = 0, uart_fd = 0, hm_ev = 0;

  // X on the CPU bus: read data the bridge returns (cpu_d, read
  // hierarchically) in its ack cycle, write data on the lanes sel enables
  // (SDRAM/BRAM, addr[23] = 0) or on the 16 bits cfide takes (addr[23] = 1:
  // no byte swap, cfide's d = q[15:0] whatever sel says).
  // The core treats an X branch condition as "not taken", so a CHECK
  // against X data would pass: the bench fails the run instead.
  integer n_x = 0;
  wire [31:0] cpu_d = `HM_CPU.cpu_d;
  wire        cpu_ack = `HM_CPU.cpu_ack;
  wire        cpu_req = `HM_CPU.cpu_req;
  wire        cpu_wr = `HM_CPU.cpu_wr;
  wire [31:0] cpu_q = `HM_CPU.cpu_q;
  wire [3:0]  cpu_sel = `HM_CPU.cpu_sel;
  wire [31:2] cpu_addr = `HM_CPU.cpu_addr;
  wire [31:0] cpu_wmask = cpu_addr[23] ? 32'h0000FFFF :
                          {{8{cpu_sel[0]}}, {8{cpu_sel[1]}}, {8{cpu_sel[2]}}, {8{cpu_sel[3]}}};
  wire [31:0] cpu_rmask = cpu_addr[23] ? 32'h0000FFFF : 32'hFFFFFFFF;
  always @(posedge clk114) if (cpu_reset_n && cpu_ack === 1'b1) begin
    if (!cpu_wr && ^(cpu_d & cpu_rmask) === 1'bx || cpu_wr && ^(cpu_q & cpu_wmask) === 1'bx) begin
      n_x = n_x + 1;
      if (n_x <= 10)
        $display("BENCH ERROR at cycle %0d: X on the bus: %s %h data %h sel %b", cyc,
                 cpu_wr ? "write" : "read", {cpu_addr, 2'b00}, cpu_wr ? cpu_q : cpu_d, cpu_sel);
      errors = errors + 1;
    end
  end

`ifdef SDCARD
  // the jump to the loaded firmware: the first CPU read of 0x2000
  reg boot_seen = 1'b0;
  always @(posedge clk114) if (cpu_reset_n && !boot_seen && cpu_req === 1'b1 && cpu_wr === 1'b0 &&
                               {cpu_addr, 2'b00} == 32'h00002000) begin
    boot_seen = 1'b1;
`ifdef RV_HOSTCPU_STATS
    $display("=== BOOT first read of 0x2000 at cycle %0d, irefill %0d dread %0d dwrite %0d so far", cyc,
             `HM_RV.st_irefill, `HM_RV.st_dread, `HM_RV.st_dwrite);
`else
    $display("=== BOOT first read of 0x2000 at cycle %0d", cyc);
`endif
  end
`endif

`ifdef FWBOOT
  // i2c_master_mmio.sv (havei2c = true) starts a $monitor of r_cmd_done:
  // under Verilator it prints at every evaluation (13 M lines in 52 M cycles),
  // xsim on every change.  Off after the first time step; run.sh compare
  // drops the r_cmd_done= lines anyway.
  initial begin
    #1;
    $monitoroff;
  end

  // ------------------------------------------------ FWBOOT: SPI frame log
  // A frame is a run of constant sd_cs (see the header).  Both directions
  // are sampled on the rising sd_clk edge, where cfide samples MISO.  The
  // frame boundary is taken at the clk_114 edge after sd_cs changed (a
  // cfide register; the SPI is idle around a CS write): only edge-triggered
  // blocks write the frame state (see minimig_spi_stub.v for what a
  // level-sensitive block did under Verilator).
  localparam FR_MAX = 1 << 20;      // bytes per frame (the boot ROM's load)
  integer   spi_fd = 0;
  reg [8*1024-1:0] spi_log_name;
  reg [7:0] fr_cs = 8'h00;          // ~sd_cs[7:1] of the open frame, bit 0 = 0
  integer   fr_n = 0, fr_bit = 0, n_frames = 0, n_fpga6 = 0, n_keyq = 0, fr_over = 0;
  reg [7:0] fr_out [0:FR_MAX-1];
  reg [7:0] fr_in  [0:FR_MAX-1];
  reg [7:0] fr_osr = 8'h00, fr_isr = 8'h00;
  reg       fr_fpga0 = 1'b0;        // every MOSI byte of the frame is 00

  // at_end: the run ends, the frame is cut wherever the transfer is
  task frame_close(input at_end);
    integer k;
    begin
      if (fr_bit != 0 && !at_end) bench_error("SPI frame ended in the middle of a byte");
      if (fr_cs != 8'h00 || fr_n > 0) begin
        n_frames = n_frames + 1;
        if (spi_fd != 0) begin
          $fwrite(spi_fd, "%h", fr_cs);
          for (k = 0; k < fr_n && k < FR_MAX; k = k + 1) $fwrite(spi_fd, " %h", fr_out[k]);
          $fwrite(spi_fd, " /");
          for (k = 0; k < fr_n && k < FR_MAX; k = k + 1) $fwrite(spi_fd, " %h", fr_in[k]);
          $fwrite(spi_fd, "\n");
        end
      end
      if (fr_cs == 8'h10 && fr_n == 6 && fr_fpga0) n_fpga6 = n_fpga6 + 1;
      if (fr_cs == 8'h20 && fr_n > 0 && fr_out[0] == 8'h98) begin
        n_keyq = n_keyq + 1;
        if (n_keyq == 20) $display("=== HandleUI KEYQ frame 20 at cycle %0d", cyc);
      end
`ifdef HM_FRAME_HOOK
      hm_frame_hook(at_end, fr_cs != 8'h00 || fr_n > 0);
`endif
    end
  endtask

  reg [7:0] fr_sdcs = 8'hFF;        // sd_cs of the open frame
  always @(posedge clk114) if (n_reset && sd_cs !== fr_sdcs) begin
    frame_close(1'b0);
    fr_sdcs = sd_cs;
    fr_cs = ~sd_cs & 8'hFE;
    fr_n = 0;
    fr_bit = 0;
    fr_fpga0 = 1'b1;
  end

  always @(posedge sd_clk) if (n_reset) begin
    fr_osr = {fr_osr[6:0], sd_do};
    fr_isr = {fr_isr[6:0], miso};
    fr_bit = fr_bit + 1;
    if (fr_bit == 8) begin
      if (fr_n < FR_MAX) begin
        fr_out[fr_n] = fr_osr;
        fr_in[fr_n] = fr_isr;
      end else if (fr_over == 0) begin
        bench_error("SPI frame longer than FR_MAX bytes (not logged beyond)");
        fr_over = 1;
      end
      if (fr_osr != 8'h00) fr_fpga0 = 1'b0;
      fr_n = fr_n + 1;
      fr_bit = 0;
    end
  end

  // ------------------------------------------------ FWBOOT: OSD reply gap
  // SPI DATA accesses while sd_cs[5] is low, numbered from the frame start
  // (og_i): 0 the command write, then per reply byte a write and a read,
  // as SPI(OSD_CMD_x) and SPI_reply() do; between them the command's
  // read-back, which the firmware does (its result is unused).  So a read
  // is the read-back of the write just before it (two reads in a row, or a
  // read first, is a bench error), and every write after the first is a
  // reply byte's.  For frames of
  // OSD_CMD_VERSION / OSD_CMD_KEYQ, every access from 1 on except the
  // command's read-back gives one gap: the clk_114 edges strictly between
  // the previous SPI DATA access's ack edge (cycle og_done) and the edge
  // that raised this request (one before the edge that sees hw_req high
  // first): cyc - og_done - 2.  A reply byte's write (after the previous
  // byte's read-back, or the command's: the constrained interval) goes to
  // og_rw_min, the headline; a read (write -> its own read-back, which
  // cfide holds until the transfer has ended) to og_wr_min.  The RV's
  // accesses alternate from the start, so for it this is "even og_i >= 2:
  // og_rw_min, odd og_i >= 3: og_wr_min".
  integer og_i = 0, og_done = -1, og_rw_min = 1000000, og_wr_min = 1000000;
  integer og_bytes = 0, og_frames = 0, og_g = 0, og_k = 0;
  reg     og_we = 1'b1;              // the previous SPI DATA access was a write
  integer og_min_cyc = -1, og_min_k = -1;   // where og_rw_min was seen first
  integer osd_min_gap = 40;                 // +OSD_MIN_GAP: the check's bound
  reg [7:0] og_cmd = 8'h00, og_min_cmd = 8'h00;
  reg       og_cs5 = 1'b1;          // sd_cs[5] at the last clk_114 edge
  always @(posedge clk114) if (cpu_reset_n) begin
    if (sd_cs[5] !== og_cs5) begin og_cs5 = sd_cs[5]; og_i = 0; og_done = -1; og_k = 0; end
    if (sd_cs[5] === 1'b0 && spi_data && hw_req && !hw_req_d) begin
      if (og_i == 0) og_cmd = hostWR[7:0];
      if ((og_cmd == 8'h88 || og_cmd == 8'h98) && host_we !== 1'b1 && (og_i == 0 || !og_we))
        bench_error("OSD reply frame: SPI DATA accesses are not write/read pairs");
      if (og_i >= 1 && (og_cmd == 8'h88 || og_cmd == 8'h98) && !(og_i == 1 && host_we !== 1'b1)) begin
        og_g = cyc - og_done - 2;
        if (host_we === 1'b1) begin
          og_bytes = og_bytes + 1;
          if (og_k == 0) og_frames = og_frames + 1;
          if (og_g < og_rw_min) begin
            og_rw_min = og_g; og_min_cyc = cyc; og_min_cmd = og_cmd; og_min_k = og_k;
          end
`ifdef HM_OSD_GAP_HOOK
          hm_osd_gap_hook(og_cmd, og_k, og_g);
`endif
          og_k = og_k + 1;
        end else if (og_g < og_wr_min) og_wr_min = og_g;
      end
    end
    if (sd_cs[5] === 1'b0 && spi_data && hw_done) begin
      og_done = cyc;
      og_we = host_we === 1'b1;
      og_i = og_i + 1;
    end
  end

  // ------------------------------------------------ FWBOOT: stack low-water
  // CPU writes below 0x2000 (the boot BRAM, the bridge's rom state) after
  // the jump: the lowest byte written (sel[i] = byte A+i).  Full-word writes
  // of 5A5AA5A5 (cpu_q is byte-swapped, the bus is big-endian) are not counted: that is StackFill() (fw/ctrl/stackcheck.c)
  // painting [0x1400, sp-64), not a stack store.
  integer stack_low = 32'h2000;
  integer sl_b = 0;
  always @(posedge clk114) if (cpu_reset_n && boot_seen && cpu_ack === 1'b1 && cpu_wr === 1'b1 &&
                               cpu_addr[31:13] == 19'h0 &&
                               !(cpu_sel == 4'hF && cpu_q == 32'hA5A55A5A)) begin
    sl_b = cpu_sel[0] ? 0 : cpu_sel[1] ? 1 : cpu_sel[2] ? 2 : 3;
    if ({cpu_addr, 2'b00} + sl_b < stack_low) stack_low = {cpu_addr, 2'b00} + sl_b;
  end

  // ------------------------------------------------ FWBOOT: hw.txt, uart.txt
  // SDRAM writes into the regions of the MEM lines (see the header)
  reg hm_mem_kick = 1'b0, hm_mem_audio = 1'b0;
  always @(posedge clk114) if (ram_req === 1'b1 && ram_ack === 1'b1 && host_we === 1'b1) begin
    if (hwa >= 32'h00100000 && hwa < 32'h00180000) hm_mem_kick = 1'b1;
    if (hwa >= 32'h00070000 && hwa < 32'h00080000) hm_mem_audio = 1'b1;
  end

  // a completed hw write (hm_hw_done): its hw.txt line
  task hm_hw_log;
    begin
      if (hw_fd != 0 && host_we && !(hostaddr[23] && hostaddr[7:4] == 4'hE && hostaddr[3:2] <= 2'b01) &&
          !uart_tx && !(hostaddr[23] && hostaddr[7:3] == 5'b00000)) begin
        $fwrite(hw_fd, "%0d %0d %h %h\n", n_frames, hm_ev, hwa[23:0],
                (hostsel == 4'b0001 || hostsel == 4'b0010 || hostsel == 4'b0100 || hostsel == 4'b1000) ?
                {8'h00, hostWR[7:0]} : hostWR[15:0]);
        hm_ev = hm_ev + 1;
      end
    end
  endtask
`endif

  task uart_print;
    integer k;
`ifdef FWBOOT
    // character by character: Verilator takes at most 8192 bits of
    // $display arguments (1024 characters)
    begin
      $write("UART: ");
      for (k = 0; k < uart_n; k = k + 1) $write("%c", uart_line[k]);
      $write("\n");
      if (uart_fd != 0) begin
        $fwrite(uart_fd, "%0d %0d ", n_frames, hm_ev);
        for (k = 0; k < uart_n; k = k + 1) $fwrite(uart_fd, "%c", uart_line[k]);
        $fwrite(uart_fd, "\n");
        hm_ev = hm_ev + 1;
      end
`else
    reg [8*UART_MAX-1:0] s;
    begin
      s = 0;
      for (k = 0; k < uart_n; k = k + 1) s = {s[8*(UART_MAX-1)-1:0], uart_line[k]};
      if (uart_n == 0) $display("UART: ");   // %0s of an empty string: xsim
      else $display("UART: %0s", s);        // prints nothing, Verilator a space
`endif
      if (is_boot) $display("=== UART line at cycle %0d", cyc);
    end
  endtask

  // The monitor part of the bench's per-clk_114 hw block, first statements
  // (hw_req_d is the previous cycle's hw_req)
  task hm_hw_cycle;
    begin
      hw_req_d <= hw_req;
      if (hw_req && host_we && spi_data && `HM_SD_BUSY === 1'b0)
        spi_acc = 1'b1;
      if (hw_req && !hw_req_d) begin
        n_hw = n_hw + 1;
        if (host_we && spi_data && `HM_SD_BUSY === 1'b1) spi_busy_waits = spi_busy_waits + 1;
      end
    end
  endtask

  // An access completed (hw_req && hw_ack): stale ack, SPI accept, UART
  task hm_hw_done;
    begin

    if (!c28_seen) begin
      n_stale = n_stale + 1;
      if (n_stale <= 10)
        $display("BENCH ERROR at cycle %0d: stale ack: %s %h completed, cfide never saw the request",
                 cyc, host_we ? "write" : "read", hwa);
      errors = errors + 1;
    end
    c28_seen = 1'b0;     // re-arm for the next request
`ifdef FWBOOT
    hm_hw_log;
`endif
    if (host_we && spi_data && !spi_acc) begin
      $display("BENCH ERROR at cycle %0d: SPI DATA write %h completed, cfide did not accept it (SD_busy high)",
               cyc, hostWR[7:0]);
      errors = errors + 1;
    end
    if (host_we && uart_tx) begin
      if (uart_first < 0) uart_first = cyc;
      if (hostWR[7:0] == 8'h0a || uart_n >= UART_MAX - 1) begin
        uart_print;
        uart_n = 0;
      end
      if (hostWR[7:0] == 8'h0d) begin     // printed as \r
        uart_line[uart_n] = "\\";
        uart_line[uart_n + 1] = "r";
        uart_n = uart_n + 2;
      end else if (hostWR[7:0] != 8'h0a) begin
        uart_line[uart_n] = hostWR[7:0];
        uart_n = uart_n + 1;
      end
    end
    end
  endtask

  // plusargs of the FWBOOT monitors
  task hm_init;
    begin
`ifdef FWBOOT
      if (!$value$plusargs("OSD_MIN_GAP=%d", osd_min_gap)) osd_min_gap = 40;
      if ($value$plusargs("SPI_LOG=%s", spi_log_name)) begin
        spi_fd = $fopen(spi_log_name, "w");
        if (spi_fd == 0) bench_error("+SPI_LOG: cannot open the file");
      end
      if ($value$plusargs("HW_LOG=%s", spi_log_name)) begin
        hw_fd = $fopen(spi_log_name, "w");
        if (hw_fd == 0) bench_error("+HW_LOG: cannot open the file");
      end
      if ($value$plusargs("UART_LOG=%s", spi_log_name)) begin
        uart_fd = $fopen(spi_log_name, "w");
        if (uart_fd == 0) bench_error("+UART_LOG: cannot open the file");
      end
`endif
    end
  endtask

  // end of run, after errors += ram.errors
  task hm_final_hw;
    begin
      $display("=== HW accesses %0d, stale acks %0d, X %0d, SDRAM reads %0d writes %0d, main done %0d, cycles %0d",
               n_hw, n_stale, n_x, `HM_RAM.n_rd, `HM_RAM.n_wr, uart_first, cyc);
    end
  endtask

`ifdef SDCARD
`ifdef RV_HOSTCPU_STATS
  task hm_final_stats;
    begin
      $display("=== STATS irefill %0d dread %0d dwrite %0d busy_cycles %0d (rv_hostcpu, whole run)",
               `HM_RV.st_irefill, `HM_RV.st_dread,
               `HM_RV.st_dwrite, `HM_RV.st_busy);
    end
  endtask
`endif
`ifdef FWBOOT
  task hm_final_fwboot;
    begin
      if (spi_fd != 0) begin
        frame_close(1'b1);   // the frame still open at the end (its whole bytes)
        $fclose(spi_fd);
      end
      if (hw_fd != 0) begin
        if (hm_mem_kick) $fwrite(hw_fd, "MEM kickstart 00100000 00080000\n");
        if (hm_mem_audio) $fwrite(hw_fd, "MEM audio_ring 00070000 00010000\n");
        $fclose(hw_fd);
      end
      if (uart_fd != 0) $fclose(uart_fd);
      $display("=== SPI frames %0d, HandleFpga frames %0d, KEYQ frames %0d", n_frames, n_fpga6, n_keyq);
      if (og_bytes > 0)
        $display("=== OSD GAP min %0d over %0d bytes", og_rw_min, og_bytes);
      else
        $display("=== OSD GAP min none over 0 bytes");
      if (og_bytes > 0)
        $display("=== OSD GAP (info) write->read-back min %0d (not seen by userio_osd), %0d reply frames",
                 og_wr_min, og_frames);
      if (og_bytes > 0)
        $display("=== OSD GAP (info) min first at cycle %0d, command %h, reply byte %0d (0 = the first)",
                 og_min_cyc, og_min_cmd, og_min_k);
      if (og_bytes > 0 && og_rw_min < osd_min_gap)
        bench_error("OSD GAP min below OSD_MIN_GAP (sim/host_bridge/README.md, OSD reply gap)");
      $display("=== STACK low %h (%0d bytes used)", stack_low, 32'h2000 - stack_low);
    end
  endtask
`endif
`endif
