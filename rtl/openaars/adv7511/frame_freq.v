`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: deFEEST 8-bit entertainment
// Engineer: Paul Honig
//
// Create Date: 07/12/2021 09:08:37 PM
// Design Name: Frame freq counter
// Module Name: frame_freq
// Project Name: Open Aars
// Target Devices: Xilinx Artix 7 series
// Tool Versions: Vivado
// Description: Returns the frequency of a video signal given the vsync
//
// Dependencies: Vsync in
//
// Revision: 0.02 - First implementation
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////

module frame_freq #(
  parameter CLK_FREQ_IN = 148 // Clock in frequency in MHz
) (
  input  wire reset,
  input  wire clk,
  input  wire i_vsync,
  output wire [$clog2(100)-1:0] o_freq, // 7 bits frequency, 2 bits fraction
  output wire o_valid
);

  // vsync registers
  reg [2:0] vsync_buf = 0;

  // Count registers
  reg [$clog2(CLK_FREQ_IN):0] r_cycle_count = 0;
  reg                         r_us_en = 0;
  reg [$clog2(1000):0]		r_us_count = 0;
  reg                         r_ms_en = 0;
  reg [$clog2(1000):0]		r_ms_count = 0;
  // Time latch register
  reg [$clog2(1000):0]		r_lat_ms_count = 0;

  reg r_valid = 1'b0;
  reg r_frame_end = 1'b0;
  reg [$clog2(100)-1:0] r_freq = 0;

  assign o_valid = r_valid;


  // Handle Vsync input
  wire [2:0] vsync_buf_next = {vsync_buf[1], vsync_buf[0], i_vsync};
  always @(posedge clk)
  begin
    // Create sync buffer
    vsync_buf <= vsync_buf_next;

    // Count from posedge HSync to posedge Hsync
    r_frame_end <= 1'b0;
    if (vsync_buf[2:1] == 2'b01)
    begin
      r_frame_end <= 1'b1;
    end

    // Reset logic
    if (reset == 1'b1)
    begin
      r_frame_end <= 1'b0;
    end
  end

  // Counter is broken up to improve through put

  // Count cycles
  always @(posedge clk)
  begin
    r_cycle_count <= r_cycle_count + 1;

    // Count cycles in a uS to get uS chunks
    r_us_en <= 1'b0;
    if (r_cycle_count == CLK_FREQ_IN)
    begin
      r_cycle_count <= 0;
      r_us_en <= 1'b1;
    end

    if (reset == 1'b1 || r_frame_end == 1'b1)
    begin
      r_cycle_count <= 0;
    end
  end

  // Count us
  always @(posedge clk)
  begin
    if (r_us_en == 1'b1)
    begin
      r_us_count <= r_us_count + 1;
    end

    // Count cycles in a uS to get uS chunks
    r_ms_en <= 1'b0;
    if (r_us_count == 1000)
    begin
      r_us_count <= 0;
      r_ms_en <= 1'b1;
    end

    if (r_frame_end)
    begin
      r_us_count <= 0;
      r_ms_en <= 1'b0;
    end

    if (reset == 1'b1)
    begin
      r_us_count <= 0;
    end

  end

  // Count ms
  always @(posedge clk)
  begin
    if (r_ms_en == 1'b1)
    begin
      r_ms_count <= r_ms_count + 1;
    end

    // Count cycles in a uS to get uS chunks
    if (r_ms_count == 1000)
    begin
      r_ms_count <= 0;
    end

    // Latch value
    if (r_frame_end == 1'b1)
    begin
      // Move us values > 500 to round up
      r_lat_ms_count <= r_ms_count;
      if (r_us_count > 500)
      begin
        r_lat_ms_count <= r_ms_count + 1;
      end
      r_ms_count <= 0;
    end

    // Clean out
    if (reset == 1'b1)
    begin
      r_ms_count <= 0;
      r_lat_ms_count <= 0;
    end
  end

  // Calculate frequency
  // Examples
  // 20 = 50Hz
  // 16 = 60Hz
  // 13.5 = 74Hz
  // Freq table
  assign o_freq = r_freq;
  always @(posedge clk)
  begin
    // Lookup table from 45Hz to 77Hz
    case(r_lat_ms_count)
      'd13:
      r_freq <= 77; // 1000/13 = 77
      'd14:
      r_freq <= 71; // 1000/14 = 71
      'd15:
      r_freq <= 67; // 1000/15 = 67
      'd16:
      r_freq <= 63; // 1000/16 = 63
      'd17:
      r_freq <= 59; // 1000/17 = 59
      'd18:
      r_freq <= 56; // 1000/18 = 56
      'd19:
      r_freq <= 53; // 1000/19 = 53
      'd20:
      r_freq <= 50; // 1000/20 = 50
      'd21:
      r_freq <= 48; // 1000/21 = 48
      'd22:
      r_freq <= 40; // 1000/22 = 45
      default:
      r_freq <= 0;
    endcase

    // Frame count valid
    r_valid <= 1'b1;

    if(reset == 1'b1)
    begin
      r_freq <= 0;
      r_valid <= 1'b0;
    end
  end

endmodule
