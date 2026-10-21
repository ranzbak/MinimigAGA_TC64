// bfm_ide: the Amiga side of gayle in the L3 bench (scenarios hdd, cd, cdda
// and cdda_load):
// a 68k IDE driver on gayle's 68k ports
// (address_in, data_in, data_out, rd, hwr, lwr, sel_ide, sel_gayle, irq,
// nrdy).
//
// Bus timing: the bus tasks of sim/gayle/gayle_tb.v, copied (en, set_addr,
// bus_off, hwb, hww, hr) and changed only where this bench differs: the
// clock is clk_28 with the bench's clk7_en (gayle samples its 68k inputs
// on a clk_28 edge with clk7_en; "en" returns 2 ns after such an edge, so
// what is set then is sampled at the next one), a read waits out nrdy
// without gayle_tb's 2,000-cycle guard (an IDE read waits for the
// firmware: the guard is WAIT_MAX here, a bench error), and every nrdy
// stall is recorded as a wait.  A read is one clk7 cycle of address setup,
// the nrdy stall if any, one with rd (gayle pops its FIFO at that edge); a
// write is one clk7 cycle with hwr (byte, task file registers) or hwr and
// lwr (word: the data register, the Gayle registers).
//
// Registers: port 0 at $DA2000, port 1 at $DA3000 (gayle.v: address bit 12
// selects the port), register r at base + 4r (0 data, 1 error / features,
// 2 sector count / interrupt reason, 3 sector, 4 / 5 cylinder low / high =
// ATAPI byte count, 6 device / head, 7 status / command); INTENA $DAA000
// and INTREQ $DA9000 (bit 15; writing 0 clears the request).
//
// ATA protocol (the host side of ATA-2 PIO, as gayle_port.v and
// fw/ctrl_rv/hdd.c implement the device side):
//   PIO in (IDENTIFY, READ SECTORS, READ MULTIPLE): per DRQ block, wait for
//     the interrupt, read the status (BSY 0, DRQ 1), clear INTREQ, read the
//     block (one sector; READ MULTIPLE: the SET MULTIPLE count, the last
//     block what is left); a read of an empty FIFO is held by nrdy
//   PIO out (WRITE SECTORS, WRITE MULTIPLE): the first block after polling
//     the status for BSY 0 / DRQ 1 (no interrupt, ATA), each later block
//     and the end after an interrupt (DRQ 1: the next block; DRQ 0: done)
//   no data (SET MULTIPLE): wait for the interrupt, BSY 0, DRQ 0
//   every command ends with ata_end: the status polled until BSY and DRQ
//     are 0 (DRDY 0x40, no ERR; 0x41 for a PACKET command that must end in
//     CHECK CONDITION; else a bench error), then the task file
//     read back (error, count, sector, cylinder low / high, device / head)
//     for the log.  The firmware ignores the LBA bit (hdd.c chs2lba), so
//     addresses are CHS: ata_cmd converts an LBA with the geometry set for
//     the drive (g_heads, g_spt: from IDENTIFY's words 3 and 6, checked by
//     l3check.py)
//
// Waits (plan 7.1 item 8, mon_l3.vh): a wait is time the 68k side spent
// on the firmware, in clk_114 cycles (the bench's cyc), recorded only when
// it waited at all: "irq" from the start of an ata_wait (the command's or
// the block's start) to the interrupt, when it was not already pending;
// "poll" from the start of a BSY poll (ata_wait without interrupt,
// ata_end) to the status read that met it, when an earlier read had seen
// BSY (or DRQ at the end); "nrdy" the stall of a data read held by nrdy.
// A status read that finds the drive ready at once is no wait.  Per command: "=== IDE end
// <k> ... waits <n> (irq <a>, poll <b>, nrdy <c>) min/median/max
// <x>/<y>/<z> clk_114, total <t>" (median: the lower one); over the run
// w_all_n, w_all_min for the MARGIN line.
//
// Tasks:
//   ata_cmd(port, dev, cmd, lba, count)      task file and command (count 0 = 256)
//   ata_cmd_chs(port, dev, cmd, c, h, s, count)
//   ata_wait(with_irq, drq)                  as above; BSY must be 0 and DRQ = drq
//   ata_pio_in(words, fd)                    data register reads, words to fd
//   ata_pio_out(fd, words)                   data register writes of the write
//                                            pattern (wr_kind, wr_lba), to fd
//   ata_identify(port, dev)                  IDENTIFY DEVICE, the 256 words to the dump
//   ata_identify_cmd(port, dev, cmd)         the same with another command
//                                            (A1 IDENTIFY PACKET DEVICE)
//   ata_read(port, dev, cmd, lba, count), ata_read_chs(...), ata_write(...),
//   ata_setmult(port, dev, n)                one whole command each (log, dump)
//   atapi_packet(port, dev, pkt, bytecount, chk)
//                                            PACKET (A0) with the 12 bytes of
//                                            pkt (byte 0 in bits 95:88) and the
//                                            byte count limit; each data-in phase
//                                            (interrupt reason IO, the device's
//                                            byte count) to the command's dump
//                                            file, one "=== IDE phase <k> <n>"
//                                            line each; the status phase ends it,
//                                            status 0x41 (CHECK CONDITION) when
//                                            chk, else 0x40
// Each whole command writes "=== IDE cmd <k> ..." at its start and "=== IDE
// end <k> ..." at its end, and its data to <+IDE_DUMP>_<k>.hex (16 words
// per line, the first word first: xxd -r -p reads it back as the bytes in
// the 68k's memory order).
//
// Slow host (+IDE_HOST_DELAY=<n>, default 0): before reading each PIO-in
// block of ata_read (READ SECTORS / READ MULTIPLE), wait n clk_114 more
// after the block's interrupt, as an Amiga busy elsewhere does (the OS, a CD
// player program).  The FIFO then stays full when the firmware polls for
// "drained", so its drain-wait loop runs (hdd.c ATA_ReadSectors).  Without
// the delay this bench drains each block while the firmware is still
// sending it, and that loop never runs (sim/l3/README.md "cdda", slow host:
// the board deadlock of 2026-10-20).
//
// The write pattern of a sector at drive LBA L (68k memory order, byte j):
// 'W', kind ('S' WRITE SECTORS, 'M' WRITE MULTIPLE), L >> 8, L & 255, then
// (L * 29 + j * 7 + 0x5A) & 255 for j = 4..511 (l3check.py wpattern).
//
// The bench (scenarios.vh) sets plan ("hdd", "cd", "cdda" or "cdda_load"; the
// cdda plans also read cd_flips, which the bench keeps equal to bfm_audio's
// flip count) and go; the plan starts when
// the chipset reset is low as well (minimig_syscontrol holds it for four
// frames after userio_osd's usrrst falls, so at the main-loop milestone the
// Amiga side is still in reset: writes then are lost, as on the Amiga);
// the reset rising again during the plan is a bench error.  done when the
// plan has ended.  Read by the bench and mon_l3.vh: done, errors, w_all_n, w_all_min.
// Idle outputs (before go and between accesses): all 0, the values the
// bench tied gayle's 68k inputs to before this model.
`timescale 1ns/1ps

module bfm_ide (
  input             clk28,
  input             clk7_en,
  input             reset,          // the chipset reset (gayle's): the plan starts after it
  input      [31:0] cyc,            // the bench's clk_114 cycle (waits, log lines)
  output reg [23:1] address_in,
  output reg [15:0] data_in,
  input      [15:0] data_out,
  output reg        rd,
  output reg        hwr,
  output reg        lwr,
  output reg        sel_ide,
  output reg        sel_gayle,
  input             irq,
  input             nrdy
);

  localparam [23:0] BASE0  = 24'hDA2000, BASE1 = 24'hDA3000;
  localparam [23:0] INTREQ = 24'hDA9000, INTENA = 24'hDAA000;
  localparam [7:0]  ST_BSY = 8'h80, ST_DRDY = 8'h40, ST_DRQ = 8'h08, ST_ERR = 8'h01;
  localparam [7:0]  C_IDENTIFY = 8'hEC, C_READ = 8'h20, C_WRITE = 8'h30, C_READM = 8'hC4,
                    C_WRITEM = 8'hC5, C_SETMULT = 8'hC6, C_PACKET = 8'hA0, C_IDPACKET = 8'hA1;
  localparam integer WAIT_MAX = 40000000;    // clk_114 cycles, one wait (a bench error beyond)
  localparam integer WMAX = 65536;           // waits kept per command (for the median)

  initial begin
    address_in = 23'h000000; data_in = 16'h0000;
    rd = 1'b0; hwr = 1'b0; lwr = 1'b0; sel_ide = 1'b0; sel_gayle = 1'b0;
  end

  // written by the bench
  reg               go = 1'b0;
  reg  [8*16-1:0]   plan = "";
  // read by the bench
  reg               done = 1'b0;
  integer           errors = 0;
  integer           w_all_n = 0, w_all_min = 0;
  integer           host_delay = 0;            // +IDE_HOST_DELAY (clk_114 cycles)

  task ide_error(input [8*100-1:0] msg);
    begin
      $display("BENCH ERROR at cycle %0d: bfm_ide: %0s", cyc, msg);
      errors = errors + 1;
    end
  endtask

  // ------------------------------------------- bus tasks (sim/gayle/gayle_tb.v)
  // returns 2 ns after a clk_28 edge with clk7_en; inputs set then are
  // sampled at the next one
  task en;
    begin
      @(posedge clk28);
      while (clk7_en !== 1'b1) @(posedge clk28);
      #2;
    end
  endtask

  task set_addr(input [23:0] a);
    begin
      address_in = a[23:1];
      sel_ide = (a[23:16] == 8'hDA);
      sel_gayle = (a[23:12] == 12'hDE1);
    end
  endtask

  task bus_off;
    begin
      rd = 1'b0; hwr = 1'b0; lwr = 1'b0; sel_ide = 1'b0; sel_gayle = 1'b0;
      address_in = 23'h000000; data_in = 16'h0000;
    end
  endtask

  // byte write to an even address (task file registers)
  task hwb(input [23:0] a, input [7:0] d);
    begin
      set_addr(a);
      data_in = {d, d};
      hwr = 1'b1;
      en;
      bus_off;
    end
  endtask

  // word write
  task hww(input [23:0] a, input [15:0] d);
    begin
      set_addr(a);
      data_in = d;
      hwr = 1'b1; lwr = 1'b1;
      en;
      bus_off;
    end
  endtask

  // word read; waits out nrdy like the m68k bridge does (no cycle until it
  // drops); a stall is one "nrdy" wait
  integer hr_t0 = 0;
  task hr(input [23:0] a, output [15:0] d);
    begin
      set_addr(a);
      en;                 // address setup: a 68k cycle is several clk7 long
      hr_t0 = cyc;
      while (nrdy === 1'b1 && cyc - hr_t0 < WAIT_MAX) en;
      if (nrdy === 1'b1) ide_error("a read held by nrdy for WAIT_MAX cycles");
      if (cyc != hr_t0) add_wait(cyc - hr_t0, 2);
      rd = 1'b1;
      #1 d = data_out;
      en;
      bus_off;
    end
  endtask

  // ---------------------------------------------------------- waits
  integer wv [0:WMAX-1];
  integer w_n = 0, w_irq = 0, w_poll = 0, w_nrdy = 0, w_min = 0, w_max = 0, w_tot = 0;

  // kind 0 irq, 1 poll, 2 nrdy
  task add_wait(input integer v, input integer kind);
    begin
      if (w_n < WMAX) wv[w_n] = v;
      if (w_n == 0 || v < w_min) w_min = v;
      if (w_n == 0 || v > w_max) w_max = v;
      w_n = w_n + 1;
      w_tot = w_tot + v;
      if (kind == 0) w_irq = w_irq + 1;
      else if (kind == 1) w_poll = w_poll + 1;
      else w_nrdy = w_nrdy + 1;
      if (w_all_n == 0 || v < w_all_min) w_all_min = v;
      w_all_n = w_all_n + 1;
    end
  endtask

  // the lower median of the kept waits: the smallest m with at least
  // (n + 1) / 2 waits <= m (binary search between min and max)
  function integer w_median(input integer dummy);
    integer lo, hi, mid, c, i, n;
    begin
      n = (w_n < WMAX) ? w_n : WMAX;
      lo = w_min; hi = w_max;
      while (lo < hi) begin
        mid = lo + (hi - lo) / 2;
        c = 0;
        for (i = 0; i < n; i = i + 1) if (wv[i] <= mid) c = c + 1;
        if (c >= (n + 1) / 2) hi = mid; else lo = mid + 1;
      end
      w_median = lo;
    end
  endfunction

  // ---------------------------------------------------------- ATA
  integer    g_heads [0:3];        // geometry per slot (port * 2 + dev) for ata_cmd
  integer    g_spt   [0:3];
  integer    cmd_k = 0;            // commands so far (the dump file number)
  integer    c_port = 0, c_dev = 0, c_lba = 0, c_count = 0, c_c = 0, c_h = 0, c_s = 0;
  integer    c_t0 = 0, c_win = 0, c_wout = 0;
  reg  [7:0] c_cmd = 8'h00;
  reg  [7:0] c_st_want = 8'h40;    // the status ata_end expects (ST_DRDY; | ST_ERR: CHECK CONDITION)
  reg [8*12-1:0] c_name = "";
  integer    fd = 0;
  reg  [8*1024-1:0] prefix, fname;
  reg [15:0] v;
  reg  [7:0] wr_kind = 8'h53;      // the write pattern's kind byte
  integer    wr_lba = 0;           // the LBA of the sector ata_pio_out writes next

  initial begin : geo_init
    integer i;
    for (i = 0; i < 4; i = i + 1) begin g_heads[i] = 16; g_spt[i] = 63; end
  end

  function [23:0] tf(input integer port, input integer r);
    tf = ((port != 0) ? BASE1 : BASE0) + 24'd4 * r[23:0];
  endfunction

  function [8*12-1:0] cmd_name(input [7:0] c);
    case (c)
      C_IDENTIFY: cmd_name = "IDENTIFY";
      C_READ:     cmd_name = "READ";
      C_WRITE:    cmd_name = "WRITE";
      C_READM:    cmd_name = "READ_MULT";
      C_WRITEM:   cmd_name = "WRITE_MULT";
      C_SETMULT:  cmd_name = "SET_MULT";
      C_PACKET:   cmd_name = "PACKET";
      C_IDPACKET: cmd_name = "ID_PACKET";
      default:    cmd_name = "OTHER";
    endcase
  endfunction

  // the write pattern, word i (bytes 2i, 2i+1) of the sector at LBA lba
  function [7:0] wbyte(input integer lba, input integer j, input [7:0] kind);
    integer x;
    case (j)
      0: wbyte = 8'h57;
      1: wbyte = kind;
      2: wbyte = lba[15:8];
      3: wbyte = lba[7:0];
      default: begin x = lba * 29 + j * 7 + 32'h5A; wbyte = x[7:0]; end
    endcase
  endfunction

  // task file and command (no wait); count 0 = 256 sectors
  task ata_cmd_chs(input integer port, input integer dev, input [7:0] cmd,
                   input integer c, input integer h, input integer s, input integer count);
    integer slot;
    begin
      hr(tf(port, 7), v);
      if (v[15] !== 1'b0) ide_error("a command while BSY is set");
      slot = port * 2 + dev;
      c_port = port; c_dev = dev; c_cmd = cmd; c_name = cmd_name(cmd);
      c_c = c; c_h = h; c_s = s; c_count = count; c_st_want = ST_DRDY;
      c_lba = (c * g_heads[slot] + h) * g_spt[slot] + s - 1;
      c_win = 0; c_wout = 0;
      w_n = 0; w_irq = 0; w_poll = 0; w_nrdy = 0; w_min = 0; w_max = 0; w_tot = 0;
      cmd_k = cmd_k + 1;
      c_t0 = cyc;
      $display("=== IDE cmd %0d %0s port %0d dev %0d chs %0d/%0d/%0d lba %0d count %0d at cycle %0d",
               cmd_k, c_name, port, dev, c, h, s, c_lba, count, cyc);
      $fflush;
      hwb(tf(port, 2), count[7:0]);
      hwb(tf(port, 3), s[7:0]);
      hwb(tf(port, 4), c[7:0]);
      hwb(tf(port, 5), c[15:8]);
      hwb(tf(port, 6), 8'hA0 | ((dev != 0) ? 8'h10 : 8'h00) | {4'h0, h[3:0]});
      hwb(tf(port, 7), cmd);
    end
  endtask

  task ata_cmd(input integer port, input integer dev, input [7:0] cmd, input integer lba, input integer count);
    integer slot, cyl, hd, sc;
    begin
      slot = port * 2 + dev;
      sc  = lba % g_spt[slot] + 1;
      hd  = (lba / g_spt[slot]) % g_heads[slot];
      cyl = lba / (g_spt[slot] * g_heads[slot]);
      ata_cmd_chs(port, dev, cmd, cyl, hd, sc, count);
    end
  endtask

  // wait for the interrupt (with_irq) or poll until BSY is 0; then BSY 0
  // and DRQ = drq, no ERR; INTREQ cleared after an interrupt
  task ata_wait(input with_irq, input drq);
    integer t0, tl;
    begin
      t0 = cyc;
      if (with_irq) begin
        while (irq !== 1'b1 && cyc - t0 < WAIT_MAX) en;
        if (irq !== 1'b1) ide_error("no interrupt within WAIT_MAX cycles");
        if (cyc != t0) add_wait(cyc - t0, 0);
        hr(tf(c_port, 7), v);
        hww(INTREQ, 16'h0000);
      end else begin
        tl = cyc;
        hr(tf(c_port, 7), v);
        while (v[15] === 1'b1 && cyc - t0 < WAIT_MAX) begin tl = cyc; hr(tf(c_port, 7), v); end
        if (tl != t0) add_wait(tl - t0, 1);
      end
      if (v[15] !== 1'b0) ide_error("BSY still set after the wait");
      if (v[11] !== drq) ide_error(drq ? "DRQ not set after the wait" : "DRQ set after the wait");
      if (v[8] !== 1'b0) ide_error("ERR set in the status");
    end
  endtask

  task ata_pio_in(input integer words, input integer f);
    integer i;
    begin
      for (i = 0; i < words; i = i + 1) begin
        hr(tf(c_port, 0), v);
        if (f != 0) begin
          $fwrite(f, "%h", v);
          if (i % 16 == 15 || i == words - 1) $fwrite(f, "\n");
        end
      end
      c_win = c_win + words;
    end
  endtask

  // words of the write pattern from sector wr_lba on
  task ata_pio_out(input integer f, input integer words);
    integer i, j;
    reg [15:0] w;
    begin
      for (i = 0; i < words; i = i + 1) begin
        j = (i % 256) * 2;
        w = {wbyte(wr_lba, j, wr_kind), wbyte(wr_lba, j + 1, wr_kind)};
        hww(tf(c_port, 0), w);
        if (f != 0) begin
          $fwrite(f, "%h", w);
          if (i % 16 == 15 || i == words - 1) $fwrite(f, "\n");
        end
        if (i % 256 == 255) wr_lba = wr_lba + 1;
      end
      c_wout = c_wout + words;
    end
  endtask

  task dump_open;
    begin
      $sformat(fname, "%0s_%0d.hex", prefix, cmd_k);
      fd = $fopen(fname, "w");
      if (fd == 0) ide_error("cannot open the dump file (+IDE_DUMP)");
    end
  endtask

  // the end of a command: BSY and DRQ 0, DRDY, no ERR; the task file read
  // back; the log line with the waits
  reg [7:0] t_st, t_err, t_cnt, t_sec, t_cl, t_ch, t_dh;
  task ata_end;
    integer t0, tl;
    begin
      t0 = cyc;
      tl = cyc;
      hr(tf(c_port, 7), v);
      while ((v[15] === 1'b1 || v[11] === 1'b1) && cyc - t0 < WAIT_MAX) begin tl = cyc; hr(tf(c_port, 7), v); end
      if (tl != t0) add_wait(tl - t0, 1);
      t_st = v[15:8];
      if (t_st !== c_st_want)
        ide_error((c_st_want == ST_DRDY) ? "the status at the end of a command is not DRDY (0x40)"
                                         : "the status at the end of a command is not DRDY | ERR (0x41, CHECK CONDITION)");
      hr(tf(c_port, 1), v); t_err = v[15:8];
      hr(tf(c_port, 2), v); t_cnt = v[15:8];
      hr(tf(c_port, 3), v); t_sec = v[15:8];
      hr(tf(c_port, 4), v); t_cl = v[15:8];
      hr(tf(c_port, 5), v); t_ch = v[15:8];
      hr(tf(c_port, 6), v); t_dh = v[15:8];
      if (fd != 0) begin $fclose(fd); fd = 0; end
      if (w_n > WMAX) ide_error("more waits than WMAX in one command (median of the first WMAX)");
      $display("=== IDE end %0d %0s: status %h error %h tf %h %h %h %h %h, %0d words in, %0d out, file %0s, waits %0d (irq %0d, poll %0d, nrdy %0d) min/median/max %0d/%0d/%0d clk_114, total %0d, %0d cycles, at cycle %0d",
               cmd_k, c_name, t_st, t_err, t_cnt, t_sec, t_cl, t_ch, t_dh, c_win, c_wout,
               (c_win + c_wout > 0) ? basename(fname) : "-", w_n, w_irq, w_poll, w_nrdy,
               w_min, w_median(0), w_max, w_tot, cyc - c_t0, cyc);
      $fflush;
    end
  endtask

  // the file name without its directory (the log stays the same across run
  // directories)
  function [8*1024-1:0] basename(input [8*1024-1:0] p);
    integer i, k;
    begin
      basename = p;
      k = -1;
      for (i = 0; i < 1024; i = i + 1) if (p[8 * i +: 8] == "/" && k < 0) k = i;
      if (k >= 0) begin
        basename = 0;
        for (i = 0; i < k; i = i + 1) basename[8 * i +: 8] = p[8 * i +: 8];
      end
    end
  endfunction

  // ------------------------------------------------- whole commands
  task ata_identify(input integer port, input integer dev);
    ata_identify_cmd(port, dev, C_IDENTIFY);
  endtask

  // IDENTIFY DEVICE (EC) or IDENTIFY PACKET DEVICE (A1): one PIO-in block
  task ata_identify_cmd(input integer port, input integer dev, input [7:0] cmd);
    begin
      ata_cmd_chs(port, dev, cmd, 0, 0, 0, 0);
      dump_open;
      ata_wait(1'b1, 1'b1);
      ata_pio_in(256, fd);
      ata_end;
    end
  endtask

  task ata_read_chs(input integer port, input integer dev, input [7:0] cmd,
                    input integer c, input integer h, input integer s, input integer count, input integer mult);
    integer left, blk, t0;
    begin
      ata_cmd_chs(port, dev, cmd, c, h, s, count);
      dump_open;
      left = (count == 0) ? 256 : count;
      while (left > 0) begin
        blk = (cmd == C_READM && mult > 1) ? ((left < mult) ? left : mult) : 1;
        ata_wait(1'b1, 1'b1);
        t0 = cyc;
        while (cyc - t0 < host_delay) en;	// the slow host (+IDE_HOST_DELAY)
        ata_pio_in(256 * blk, fd);
        left = left - blk;
      end
      ata_end;
    end
  endtask

  task ata_read(input integer port, input integer dev, input [7:0] cmd, input integer lba,
                input integer count, input integer mult);
    integer slot;
    begin
      slot = port * 2 + dev;
      ata_read_chs(port, dev, cmd, lba / (g_spt[slot] * g_heads[slot]), (lba / g_spt[slot]) % g_heads[slot],
                   lba % g_spt[slot] + 1, count, mult);
    end
  endtask

  task ata_write(input integer port, input integer dev, input [7:0] cmd, input integer lba,
                 input integer count, input integer mult);
    integer left, blk, first;
    begin
      ata_cmd(port, dev, cmd, lba, count);
      dump_open;
      wr_kind = (cmd == C_WRITEM) ? 8'h4D : 8'h53;
      wr_lba = lba;
      left = (count == 0) ? 256 : count;
      first = 1;
      while (left > 0) begin
        blk = (cmd == C_WRITEM && mult > 1) ? ((left < mult) ? left : mult) : 1;
        ata_wait((first != 0) ? 1'b0 : 1'b1, 1'b1);
        first = 0;
        ata_pio_out(fd, 256 * blk);
        left = left - blk;
      end
      ata_wait(1'b1, 1'b0);
      ata_end;
    end
  endtask

  task ata_setmult(input integer port, input integer dev, input integer n);
    begin
      ata_cmd_chs(port, dev, C_SETMULT, 0, 0, 0, n);
      ata_wait(1'b1, 1'b0);
      ata_end;
    end
  endtask

  // ATAPI PACKET: byte count limit in cylinder low / high, the command,
  // then (no interrupt, gayle_port.v) DRQ with interrupt reason CoD for the
  // 6 packet words; then phases until one without DRQ: each data-in phase
  // (reason IO) reads the device's byte count into the dump file, a
  // data-out phase is a bench error (no ATAPI write is modelled).  chk: the
  // command must end in CHECK CONDITION (status 0x41 at the end)
  task atapi_packet(input integer port, input integer dev, input [95:0] pkt, input integer bytecount,
                    input chk);
    integer i, n, ph, t0;
    reg [7:0] reason;
    begin
      hr(tf(port, 7), v);
      if (v[15] !== 1'b0) ide_error("PACKET while BSY is set");
      c_port = port; c_dev = dev; c_cmd = C_PACKET; c_name = cmd_name(C_PACKET);
      c_c = 0; c_h = 0; c_s = 0; c_count = bytecount; c_lba = 0;
      c_st_want = chk ? (ST_DRDY | ST_ERR) : ST_DRDY;
      c_win = 0; c_wout = 0;
      w_n = 0; w_irq = 0; w_poll = 0; w_nrdy = 0; w_min = 0; w_max = 0; w_tot = 0;
      cmd_k = cmd_k + 1;
      c_t0 = cyc;
      $display("=== IDE cmd %0d PACKET port %0d dev %0d packet %h bytecount %0d want %h at cycle %0d",
               cmd_k, port, dev, pkt, bytecount, c_st_want, cyc);
      $fflush;
      dump_open;
      hwb(tf(port, 1), 8'h00);
      hwb(tf(port, 4), bytecount[7:0]);
      hwb(tf(port, 5), bytecount[15:8]);
      hwb(tf(port, 6), 8'hA0 | ((dev != 0) ? 8'h10 : 8'h00));
      hwb(tf(port, 7), C_PACKET);
      ata_wait(1'b0, 1'b1);
      hr(tf(port, 2), v);
      if (v[9:8] !== 2'b01) ide_error("PACKET: the interrupt reason of the packet phase is not CoD");
      for (i = 0; i < 6; i = i + 1) hww(tf(port, 0), pkt[95 - 16 * i -: 16]);
      c_wout = 6;
      ph = 0;
      t0 = cyc;
      v = 16'h0800;
      while (v[11] === 1'b1 && ph < 4096) begin
        while (irq !== 1'b1 && cyc - t0 < WAIT_MAX) en;
        if (irq !== 1'b1) ide_error("PACKET: no interrupt within WAIT_MAX cycles");
        if (cyc != t0) add_wait(cyc - t0, 0);
        hr(tf(port, 7), v);
        hww(INTREQ, 16'h0000);
        if (v[15] !== 1'b0) ide_error("PACKET: BSY set at an interrupt");
        if (v[11] === 1'b1) begin
          hr(tf(port, 2), v); reason = v[15:8];
          hr(tf(port, 4), v); n = {24'd0, v[15:8]};
          hr(tf(port, 5), v); n = n + 256 * {24'd0, v[15:8]};
          if (reason[1:0] !== 2'b10) ide_error("PACKET: a DRQ phase that is not data in (IO, not CoD)");
          $display("=== IDE phase %0d %0d: reason %h, %0d bytes at cycle %0d", cmd_k, ph, reason, n, cyc);
          ata_pio_in((n + 1) / 2, fd);
          v = 16'h0800;
          ph = ph + 1;
          t0 = cyc;
        end
      end
      ata_end;
    end
  endtask

  // ------------------------------------------------------- plan hdd
  // (sim/l3/README.md "hdd"; l3check.py hdd holds the same list).  The card
  // (sim/l3/card hdd, configs from gen/mkcfg.py): hardfile[0] = RDB.HDF
  // (unit 0 = port 0 master: a plain HDF with its own RDB, 4,096 blocks,
  // CHS 16.4.63), hardfile[1] = SYNTH.HDF (unit 1 = port 0 slave: the
  // firmware synthesises its RDB, 8,192 blocks, CHS 257.1.32, drive LBA =
  // file block + 32)
  task plan_hdd;
    begin
      g_heads[0] = 4; g_spt[0] = 63;      // RDB.HDF
      g_heads[1] = 1; g_spt[1] = 32;      // SYNTH.HDF
      // unit 1, SYNTH.HDF
      ata_identify(0, 1);
      ata_read(0, 1, C_READ, 0, 2, 1);            // the synthesised RDSK and PART
      ata_read(0, 1, C_READ, 100, 64, 1);
      ata_setmult(0, 1, 16);
      // 64 sectors from cylinder 255 into 256 (the last cylinder: 64 cannot
      // start there), then 32 from cylinder 256 (cylinder high = 1)
      ata_read_chs(0, 1, C_READM, 255, 0, 1, 64, 16);
      ata_read_chs(0, 1, C_READM, 256, 0, 1, 32, 16);
      ata_write(0, 1, C_WRITE, 2000, 64, 1);
      ata_write(0, 1, C_WRITEM, 3000, 32, 16);
      ata_read(0, 1, C_READ, 2000, 64, 1);         // read back
      ata_read(0, 1, C_READM, 3000, 32, 16);
      // unit 0, RDB.HDF: block 0 as hdd.c patches it (unit 0, plain HDF)
      ata_setmult(0, 0, 16);
      ata_read(0, 0, C_READM, 0, 16, 16);
    end
  endtask

  // -------------------------------------------------------- plan cd
  // (sim/l3/README.md "cd"; l3check.py cd holds the same list).  The card
  // (sim/l3/card cd, configs from gen/mkcfg.py): secondaryhardfile[0] = the
  // ATAPI CD on IDE port 2 (gayle port 1, $DA3000) master, with TEST.CUE
  // (CDCFG=cue) or TEST.ISO (CDCFG=iso) in it.  The same packets for both
  // discs; l3check.py knows the answers.  Byte count limit 0xFFFE (the most
  // a driver may ask for) except the READ(12): 0x0400, so that every data
  // phase is split below a sector (cdrom.c cd_send_sectors / cd_send_buffer)
  localparam integer CD_PORT = 1, CD_DEV = 0, CD_LIM = 65534, CD_LIM12 = 1024;   // 0xFFFE, 0x0400
  task plan_cd;
    begin
      ata_identify_cmd(CD_PORT, CD_DEV, C_IDPACKET);
      // TEST UNIT READY: the pending UNIT ATTENTION (CHECK CONDITION)
      atapi_packet(CD_PORT, CD_DEV, 96'h00_00_00_00_00_00_00_00_00_00_00_00, CD_LIM, 1'b1);
      // REQUEST SENSE, allocation length 18: that UNIT ATTENTION
      atapi_packet(CD_PORT, CD_DEV, 96'h03_00_00_00_12_00_00_00_00_00_00_00, CD_LIM, 1'b0);
      // TEST UNIT READY again: GOOD
      atapi_packet(CD_PORT, CD_DEV, 96'h00_00_00_00_00_00_00_00_00_00_00_00, CD_LIM, 1'b0);
      // INQUIRY, allocation length 36
      atapi_packet(CD_PORT, CD_DEV, 96'h12_00_00_00_24_00_00_00_00_00_00_00, CD_LIM, 1'b0);
      // READ CAPACITY
      atapi_packet(CD_PORT, CD_DEV, 96'h25_00_00_00_00_00_00_00_00_00_00_00, CD_LIM, 1'b0);
      // READ TOC, format 0, LBA addresses, from track 0 (all), allocation 804
      atapi_packet(CD_PORT, CD_DEV, 96'h43_00_00_00_00_00_00_03_24_00_00_00, CD_LIM, 1'b0);
      // READ(10): 32 sectors from LBA 16
      atapi_packet(CD_PORT, CD_DEV, 96'h28_00_00_00_00_10_00_00_20_00_00_00, CD_LIM, 1'b0);
      // READ(12): 8 sectors from LBA 56 (CUE: the last 8 of the data track)
      atapi_packet(CD_PORT, CD_DEV, 96'hA8_00_00_00_00_38_00_00_00_08_00_00, CD_LIM12, 1'b0);
      // MODE SENSE(10), all pages (3F), allocation 256
      atapi_packet(CD_PORT, CD_DEV, 96'h5A_00_3F_00_00_00_00_01_00_00_00_00, CD_LIM, 1'b0);
      // READ CD MSF (B9), which atapi.c does not support: CHECK CONDITION
      atapi_packet(CD_PORT, CD_DEV, 96'hB9_00_00_00_02_00_00_00_03_00_10_00, CD_LIM, 1'b1);
      // REQUEST SENSE: its sense
      atapi_packet(CD_PORT, CD_DEV, 96'h03_00_00_00_12_00_00_00_00_00_00_00, CD_LIM, 1'b0);
    end
  endtask

  // ------------------------------------------------ plans cdda, cdda_load
  // (sim/l3/README.md "cdda"; l3check.py cdda holds the same list).  The
  // card: cd (CDCFG=cue) for cdda, cdhdd for cdda_load (the same configs:
  // TEST.CUE in the CD drive on IDE port 2 master; cdhdd also has the HDFs
  // of "hdd").  Run at the board's TIMER rate (TICKDIV 643): the player
  // takes one frame per tick, one half (8,192 frames) per ~21.1 M clk_114.
  // The bench copies bfm_audio's flip count into cd_flips.  After a flip the
  // plan waits CDDA_D clk_114 more before its next command, so that the
  // firmware has seen the flip and started the refill first (its main loop
  // calls CD_AudioPoll before HandleFpga): the command is then served after
  // the refill on both CPUs.
  //   TEST UNIT READY (the reset's UNIT ATTENTION: CHECK CONDITION)
  //   PLAY AUDIO MSF 00:04:64 .. 00:06:27 (LBA 214 .. 326: track 2 from its
  //     INDEX 01, 113 sectors = 66,444 frames, 1.5 s)
  //   cdda_load: at flip 2 SET MULTIPLE 16 and READ MULTIPLE 256 sectors of
  //     SYNTH.HDF (port 0 slave, LBA 1000; the 7.4 "HDF copy with CD audio")
  //   at flip 6: PAUSE, READ SUB-CHANNEL (current position, LBA), RESUME
  //   at flip 7 (the resumed run's first): STOP
  localparam integer CDDA_D = 500000;               // clk_114, 4.4 ms
  localparam integer CDDA_FLIP_MAX = 30000000;      // clk_114 per flip waited for (a half: ~21.1 M)
  integer cd_flips = 0;                             // written by the bench: bfm_audio's n_flip

  task wait_flips(input integer n);
    integer t0, lim;
    begin
      t0 = cyc;
      lim = (n - cd_flips) * CDDA_FLIP_MAX;
      while (cd_flips < n && cyc - t0 < lim) en;
      if (cd_flips < n) ide_error("cdda: the player did not reach the flip the plan waits for");
      $display("=== IDE cdda: flip %0d at cycle %0d", n, cyc);
      t0 = cyc;
      while (cyc - t0 < CDDA_D) en;
    end
  endtask

  task plan_cdda(input load);
    begin
      // TEST UNIT READY: the pending UNIT ATTENTION (CHECK CONDITION)
      atapi_packet(CD_PORT, CD_DEV, 96'h00_00_00_00_00_00_00_00_00_00_00_00, CD_LIM, 1'b1);
      // PLAY AUDIO MSF from 00:04:64 (LBA 214) to 00:06:27 (LBA 327, not played)
      atapi_packet(CD_PORT, CD_DEV, 96'h47_00_00_00_04_40_00_06_1B_00_00_00, CD_LIM, 1'b0);
      if (load) begin
        wait_flips(2);
        g_heads[1] = 1; g_spt[1] = 32;              // SYNTH.HDF (plan hdd)
        ata_setmult(0, 1, 16);
        ata_read(0, 1, C_READM, 1000, 0, 16);       // count 0 = 256 sectors
      end
      wait_flips(6);
      // PAUSE (byte 8 bit 0 = 0)
      atapi_packet(CD_PORT, CD_DEV, 96'h4B_00_00_00_00_00_00_00_00_00_00_00, CD_LIM, 1'b0);
      // READ SUB-CHANNEL: LBA addresses, SubQ, format 1 (current position), allocation 16
      atapi_packet(CD_PORT, CD_DEV, 96'h42_00_40_01_00_00_00_00_10_00_00_00, CD_LIM, 1'b0);
      // RESUME (byte 8 bit 0 = 1)
      atapi_packet(CD_PORT, CD_DEV, 96'h4B_00_00_00_00_00_00_00_01_00_00_00, CD_LIM, 1'b0);
      wait_flips(7);
      // STOP PLAY / SCAN
      atapi_packet(CD_PORT, CD_DEV, 96'h4E_00_00_00_00_00_00_00_00_00_00_00, CD_LIM, 1'b0);
    end
  endtask

  always @(posedge reset) if (go === 1'b1 && done !== 1'b1) ide_error("the chipset reset rose during the plan");

  // ------------------------------------------------------------- sequencer
  initial begin
    if (!$value$plusargs("IDE_DUMP=%s", prefix)) prefix = "ide";
    if (!$value$plusargs("IDE_HOST_DELAY=%d", host_delay)) host_delay = 0;
    wait (go === 1'b1);
    wait (reset === 1'b0);
    $display("=== IDE start: plan %0s at cycle %0d (the chipset reset low)", plan, cyc);
    if (host_delay != 0) $display("=== IDE host delay %0d clk_114 before each PIO-in block", host_delay);
    en;
    hww(INTENA, 16'h8000);
    hww(INTREQ, 16'h0000);
    if (plan == "hdd") plan_hdd;
    else if (plan == "cd") plan_cd;
    else if (plan == "cdda") plan_cdda(1'b0);
    else if (plan == "cdda_load") plan_cdda(1'b1);
    else ide_error("unknown plan");
    $display("=== IDE done: %0d commands, %0d waits at cycle %0d", cmd_k, w_all_n, cyc);
    done = 1'b1;
  end

endmodule
