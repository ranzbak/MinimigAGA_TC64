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
`timescale 1ns/1ps

module bfm_audio (
  input  wire        clk28,
  input  wire        tick,
  input  wire        audio_ena,
  input  wire        audio_clear,
  output reg  [15:0] aud_addr = 16'h0000
);

  always @(posedge clk28) begin
    if (audio_clear || !audio_ena)
      aud_addr <= 16'h0000;
    else if (tick)
      aud_addr <= aud_addr + 16'd4;
  end

endmodule
