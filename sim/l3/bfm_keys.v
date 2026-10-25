// bfm_keys: the OSD key input of the L3 bench (scenario keys), driving
// userio_osd's osd_ctrl as the keyboard does (rtl/minimig/ciaa*.v: the key
// code while the key is down).  userio_osd queues every CHANGE of osd_ctrl it
// sees on a clk7_en edge (its OSD_CMD_KEYQ queue); here a key release sets
// osd_ctrl back to 0, so one KEY is two events: the code, then 00.
//
// The key script (+KEYS=<file>), one step per line, run from the time the
// bench sets go (tb_l3.v: the scenario's main-loop milestone):
//   KEY <hex code> <hold>    osd_ctrl = code, after <hold> clk_114 cycles 0
//   BURST <code> <code> ...  osd_ctrl takes each code in turn, two clk7
//                            periods (32 clk_114) apart, and keeps the last:
//                            several events between two KEYQ frames, so
//                            the firmware's drain gets count > 1 (at most 15:
//                            the queue's depth)
//   WAIT_OSD_IDLE <cycles>   until no OSD_CMD_OSD_WR frame (20 0c) has been
//                            open for <cycles> clk_114 cycles, counted from
//                            the later of the step's start and the end of
//                            the last such frame (so a page the firmware has
//                            yet to start drawing is waited for, and a long
//                            frame, OsdClear's 2,048 bytes, is not idle time)
//   WAIT_KEYQ <n>            until n more OSD_CMD_KEYQ frames (20 98) closed
//   # ...                    a comment line (also after a step's arguments)
// Codes: fw/ctrl/osd.h (KEY_MENU 69, KEY_UP 4c, KEY_DOWN 4d, KEY_ENTER
// 44, KEY_ESC 45, ...).  Every value is held for at least two clk7 periods
// (KEY's hold is rounded up to whole clk7 periods), so userio_osd sees each
// change; a step that would not change osd_ctrl is a bench error (no event).
//
// What the bench writes here (tb_l3.v, hierarchical): go, n_keyq / keyq_st
// (KEYQ frames so far, the last one's status byte: MISO byte 1) and n_osdwr
// (OSD_CMD_OSD_WR frames so far), at each frame's close, and osdwr_open (an
// OSD_CMD_OSD_WR frame is open), every clk_114 cycle.  A KEY or BURST
// applied when the last KEYQ frame drained events (status != 0) is a bench
// error: the firmware hands those out one per main-loop pass, and while they
// last a level read (OSD_CMD_READ) could see the new code with no event to
// deliver, which OsdGetCtrl turns into a key repeat when its TIMER says so
// (fw/ctrl/osd.c): a result that would depend on the timing.  The script
// therefore waits for an empty KEYQ frame (WAIT_OSD_IDLE, then WAIT_KEYQ 1)
// before each key.  What it reads back: done (the script has ended), errors,
// n_ev (osd_ctrl changes made).
`timescale 1ns/1ps

module bfm_keys (
  input            clk28,
  input            clk7_en,
  output reg [7:0] osd_ctrl
);

  initial osd_ctrl = 8'h00;

  // written by the bench
  reg        go = 1'b0;
  integer    n_keyq = 0, n_osdwr = 0;
  reg        osdwr_open = 1'b0;
  reg  [7:0] keyq_st = 8'h00;
  // read by the bench
  reg        done = 1'b0;
  integer    errors = 0, n_ev = 0;

  integer    c28 = 0;                  // clk_28 cycles (4 clk_114 each)
  always @(posedge clk28) c28 <= c28 + 1;

  // the last clk_28 cycle with an OSD_CMD_OSD_WR frame open or closing
  integer    osdwr_seen = 0, osdwr_c28 = 0;
  always @(posedge clk28) if (n_osdwr != osdwr_seen || osdwr_open) begin
    osdwr_seen <= n_osdwr;
    osdwr_c28 <= c28;
  end

  reg [8*256-1:0] line;
  reg [8*32-1:0]  word;
  integer         fd = 0, lno = 0, r = 0, a1 = 0, a2 = 0, k = 0, nb = 0, w = 0;
  integer         b [0:15];
  reg [8*1024-1:0] fname;

  task kb_error(input [8*120-1:0] msg);
    begin
      $display("BENCH ERROR: bfm_keys %0s line %0d: %0s", fname, lno, msg);
      errors = errors + 1;
    end
  endtask

  // the next clk_28 edge at which userio_osd samples osd_ctrl (clk7_en)
  task clk7;
    begin
      @(posedge clk28);
      while (clk7_en !== 1'b1) @(posedge clk28);
    end
  endtask

  // osd_ctrl = v 2 ns after a clk7 edge (after the RTL's #1 updates there:
  // no race with userio_osd's sampling), then held for two clk7 periods at
  // least
  task set_key(input [7:0] v);
    begin
      if (v == osd_ctrl) kb_error("osd_ctrl would not change: no event");
      clk7;
      #2 osd_ctrl = v;
      n_ev = n_ev + 1;
      clk7;
      clk7;
    end
  endtask

  task check_empty;
    begin
      if (keyq_st != 8'h00)
        kb_error("key applied after a KEYQ frame that drained events (wait for an empty one)");
    end
  endtask

  initial begin
    if ($value$plusargs("KEYS=%s", fname)) begin
      fd = $fopen(fname, "r");
      if (fd == 0) kb_error("+KEYS: cannot open the file");
      $display("=== KEYS script %0s", fname);
      wait (go === 1'b1);
      while (fd != 0 && !$feof(fd)) begin
        line = 0;
        r = $fgets(line, fd);
        lno = lno + 1;
        // left-justify: Verilator's $sscanf takes the reg's leading NUL
        // bytes for the end of the string (iverilog skips them)
        while (line != 0 && line[8*256-1 -: 8] == 8'h00) line = line << 8;
        word = 0;
        if (r > 0) r = $sscanf(line, "%s", word);
        if (r <= 0 || word == "#") begin
          // blank or comment line
        end else if (word == "KEY") begin
          r = $sscanf(line, "KEY %h %d", a1, a2);
          if (r != 2 || a1 < 1 || a1 > 255 || a2 < 1) kb_error("KEY <hex code 01..ff> <hold clk_114 cycles>");
          else begin
            $display("=== KEYS step %0d KEY %02x %0d at clk_28 %0d", lno, a1[7:0], a2, c28);
            check_empty;
            set_key(a1[7:0]);
            // the rest of the hold: whole clk7 periods (16 clk_114) beyond the two of set_key
            for (k = 32; k < a2; k = k + 16) clk7;
            set_key(8'h00);
          end
        end else if (word == "BURST") begin
          for (k = 0; k < 16; k = k + 1) b[k] = -1;
          nb = $sscanf(line, "BURST %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                       b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                       b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
          if (nb < 2 || nb > 15) kb_error("BURST <code> <code> ...: 2 to 15 codes (the queue holds 15)");
          else begin
            $display("=== KEYS step %0d BURST of %0d at clk_28 %0d", lno, nb, c28);
            check_empty;
            for (k = 0; k < nb; k = k + 1) begin
              if (b[k] < 0 || b[k] > 255) kb_error("BURST: a code is not a byte");
              else set_key(b[k][7:0]);
            end
          end
        end else if (word == "WAIT_OSD_IDLE") begin
          r = $sscanf(line, "WAIT_OSD_IDLE %d", a1);
          if (r != 1 || a1 < 1) kb_error("WAIT_OSD_IDLE <clk_114 cycles>");
          else begin
            // (osdwr_c28 is updated one clk_28 edge after the frame's close)
            w = c28;
            @(posedge clk28);
            while ((c28 - (osdwr_c28 > w ? osdwr_c28 : w)) * 4 < a1) @(posedge clk28);
            $display("=== KEYS step %0d WAIT_OSD_IDLE %0d done at clk_28 %0d", lno, a1, c28);
          end
        end else if (word == "WAIT_KEYQ") begin
          r = $sscanf(line, "WAIT_KEYQ %d", a1);
          if (r != 1 || a1 < 1) kb_error("WAIT_KEYQ <frames>");
          else begin
            w = n_keyq + a1;
            while (n_keyq < w) @(posedge clk28);
          end
        end else
          kb_error("unknown step (KEY, BURST, WAIT_OSD_IDLE, WAIT_KEYQ)");
      end
      if (fd != 0) $fclose(fd);
      if (osd_ctrl != 8'h00) kb_error("the script ends with a key held (osd_ctrl not 0)");
      if (n_ev == 0) kb_error("the script made no event");
      $display("=== KEYS script done: %0d lines, %0d osd_ctrl changes", lno, n_ev);
      done = 1'b1;
    end
  end

endmodule
