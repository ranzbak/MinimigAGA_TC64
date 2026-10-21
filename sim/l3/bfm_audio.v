// bfm_audio: the CD-audio ring player's position as cfide sees it (L3 bench).
//
// rtl/soc/minimig_virtual_top.v feeds the host's audio ring (64 KB at SDRAM
// 0x6f0000) to the DAC through VideoStream: its fill address aud_addr[15:0]
// walks the ring, and cfide reads aud_addr[15] as audio_buf (which half the
// player is in, so the firmware refills the other one).  The player takes one
// stereo frame (two 16-bit samples, 4 bytes) per 44.1 kHz tick (aud_tick ->
// aud_next twice per tick).
//
// Model: aud_addr is a byte address that advances by 4 per tick while
// audio_ena is high and is 0 while audio_ena is low or audio_clear is high.
// (VideoStream itself is reset by !enable; audio_clear is the firmware's
// "start from the beginning" request and only ever comes with the ring
// stopped.)  Not modelled: VideoStream's read-ahead (it fills up to 512
// halfwords, 1 KB, in front of the sample it plays), so audio_buf flips here
// up to 256 frames later than in the hardware.
//
// tick is the bench's tick generator output (cfide's tick_in, one clk_28
// cycle per pulse; held at 1 it counts every clk_28 cycle, as L2's TIMER).
//
// Ring snapshots (scenarios cdda and cdda_load, README "cdda"), only with
// +CDDA_DUMP=<prefix>.  At every half start the model copies the 32 KB half
// that the player is about to play. A half starts:
//   - at a run's start: the player enabled (audio_ena high, audio_clear
//     low); half 0 is next
//   - at every flip: the tick that takes aud_addr into the other half
// The copy is read from the SDRAM model (tb_l3.ram.mem). The ring is at host
// 0x70000 (AUDIO_BUFFER in both firmwares' hardware.h), half h at
// 0x70000 + h * 0x8000; halfword A/2 holds byte A in its upper byte. It is
// written as the bytes in host address order to <prefix>_<n>.bin, n = 1, 2,
// ... over the run. One log line per snapshot:
//   === CDDA half <n> run <r> k <k> ring half <h> at cycle <c>: <file>
// (r = 0, 1, ... the runs; k = 0, 1, ... the halves of run r; the file
// without its directory), and per run:
//   === CDDA run <r> start at cycle <c>
//   === CDDA run <r> end at cycle <c>: <f> frames played, <k> halves
// Without +CDDA_DUMP (every other scenario: the drive sounds play through
// the ring in fdd_rd) nothing is written or logged.
// Read by the bench: n_flip (flips so far, over every run), errors.
`timescale 1ns/1ps

module bfm_audio (
  input  wire        clk28,
  input  wire        tick,
  input  wire        audio_ena,
  input  wire        audio_clear,
  input  wire [31:0] cyc,             // the bench's clk_114 cycle (log lines)
  output reg  [15:0] aud_addr = 16'h0000
);

  localparam integer RING_HW = 32'h00070000 / 2;   // halfword index of the ring
  localparam integer HALF_HW = 32'h00008000 / 2;   // halfwords per half

  always @(posedge clk28) begin
    if (audio_clear || !audio_ena)
      aud_addr <= 16'h0000;
    else if (tick)
      aud_addr <= aud_addr + 16'd4;
  end

  // ------------------------------------------------------ snapshots
  reg  [8*1024-1:0] prefix, fname;
  reg               dump_on = 1'b0;
  integer           n_half = 0;       // snapshots so far (the file number)
  integer           n_run = -1;       // the current / last run
  integer           k_run = 0;        // halves of the current run so far
  integer           frames = 0;       // frames played in the current run
  integer           n_flip = 0;       // flips so far, over every run
  integer           errors = 0;       // bench errors (tb_l3.v adds them)
  reg               playing = 1'b0;   // the player ran at the previous clk_28 edge
  reg        [15:0] a_next;
  wire              play = audio_ena === 1'b1 && audio_clear === 1'b0;

  initial dump_on = $value$plusargs("CDDA_DUMP=%s", prefix);

  // the file name without its directory (the log stays the same across run
  // directories; bfm_ide.v's basename)
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

  // the half the player is about to play: half h of the ring
  task half_start(input integer h);
    integer f, i;
    reg [15:0] w;
    begin
      n_half = n_half + 1;
      $sformat(fname, "%0s_%0d.bin", prefix, n_half);
      f = $fopen(fname, "wb");
      if (f == 0) begin
        $display("BENCH ERROR at cycle %0d: bfm_audio: cannot open the snapshot file (+CDDA_DUMP)", cyc);
        errors = errors + 1;
      end else begin
        for (i = 0; i < HALF_HW; i = i + 1) begin
          w = tb_l3.ram.mem[RING_HW + h * HALF_HW + i];
          $fwrite(f, "%c%c", w[15:8], w[7:0]);
        end
        $fclose(f);
      end
      $display("=== CDDA half %0d run %0d k %0d ring half %0d at cycle %0d: %0s",
               n_half, n_run, k_run, h, cyc, basename(fname));
      $fflush;
    end
  endtask

  // the values before this edge's update: a start when the player was off
  // at the previous edge; a flip when this edge's tick takes aud_addr into
  // the other half (that half is complete as of now: the firmware sees
  // audio_buf flip only after this edge)
  always @(posedge clk28) begin
    a_next = aud_addr + 16'd4;
    if (play && !playing) begin
      n_run = n_run + 1;
      k_run = 0;
      frames = 0;
      if (dump_on) begin
        $display("=== CDDA run %0d start at cycle %0d", n_run, cyc);
        half_start(0);
      end
      k_run = 1;
    end
    if (!play && playing && dump_on)
      $display("=== CDDA run %0d end at cycle %0d: %0d frames played, %0d halves", n_run, cyc, frames, k_run);
    if (play && tick === 1'b1) begin
      frames = frames + 1;
      if (a_next[15] != aud_addr[15]) begin
        n_flip = n_flip + 1;
        if (dump_on) half_start({31'd0, a_next[15]});
        k_run = k_run + 1;
      end
    end
    playing = play;
  end

endmodule
