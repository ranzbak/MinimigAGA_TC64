`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01/02/2020 09:52:37 PM
// Design Name: 
// Module Name: signal_generator
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module signal_generator(
    input clk,

    input [7:0] i_r,        // Input RGB
    input [7:0] i_g,
    input [7:0] i_b,
    //input [6:0] i_vblank_width,
    input  i_frame_end,
    output o_hsync,         // Sync signals to the HDMI encoder
    output o_vsync,
    output [11:0] o_x,      // Output the X and Y positions of the video beam
    output [11:0] o_y,      // When not within the active range 0, 0 is returned
    output o_frame,         // Pulse
    output [7:0] o_r,       // Outgoing RGB signal
    output [7:0] o_g,
    output [7:0] o_b,
    output o_adv_clk,       // Video pixel clock
    output o_adv_de         // Data valid strobe
);

    // Video generation settings

    // Horizontal timing 720p 50Hz @ 50MHz clock
    parameter HZ_ACT_PIX = 1280;
    parameter HZ_FRONT_PORCH = 8;
    parameter HZ_SYNC_WIDTH = 32;
    parameter HZ_BACK_PORCH = 40;
    parameter HZ_TOTAL = HZ_ACT_PIX + HZ_FRONT_PORCH + HZ_SYNC_WIDTH + HZ_BACK_PORCH;

    // Vertical timing 720p
    parameter VT_ACT_LN = 720;
    parameter VT_FRONT_PORCH = 3;
    parameter VT_SYNC_WIDTH = 7;
    parameter VT_BACK_PORCH = 6;
    parameter VT_TOTAL = VT_ACT_LN + VT_FRONT_PORCH + VT_SYNC_WIDTH + VT_BACK_PORCH;
    
    // SYNC POLARITY
    parameter SYNC_POL = 1'b1; // Sync polarity 1'b1 = active high, 1'b0 is active low
    parameter DE_POL   = 1'b1; // Sync polarity 1'b1 = positive, 1'b0 is negative
    
    // Clock devider
    reg r_clock_dev = 1'b0;
    reg r_vid_enable = 1'b0;
    
    // Frame pulse
    reg r_frame = 1'b0;
    assign o_frame = r_frame;

    assign o_adv_clk = r_clock_dev;
    // assign o_adv_de = r_vid_enable;:
    

    // Video position counters
    reg [$clog2(HZ_TOTAL):0] hz_count = 0;
    reg [$clog2(VT_TOTAL):0] vt_count = 0;
    reg [$clog2(HZ_TOTAL):0] r_x = 0;
    reg [$clog2(HZ_TOTAL):0] r_y = 0;
    assign o_x = r_x;
    assign o_y = r_y;

    // Sync registers
    reg r_hsync = 0;
    reg r_vsync = 0;
    assign o_hsync = r_hsync;
    assign o_vsync = r_vsync;
    
    // video output registers
    reg [7:0] r_r;
    reg [7:0] r_g;
    reg [7:0] r_b;
    assign o_r = r_r;
    assign o_g = r_g;
    assign o_b = r_b;

    // Clock devider block
    reg [1:0] r_dev_cnt = 0;
    always @(posedge clk) begin
      r_dev_cnt <= r_dev_cnt + 1;
      
      r_vid_enable <= 1'b0;
      r_clock_dev <= r_dev_cnt[1];
      if (r_dev_cnt == 2'b00) begin
          r_vid_enable <= 1'b1;
      end

      // r_clock_dev <= 1'b0;
      // if (r_clock_dev == 1'b0) begin
      //   r_clock_dev <= 1'b1;
      // end
      // //r_clock_dev <= ~r_clock_dev;
      //
      // // enable signal
      // r_vid_enable <= 1'b0;
      // if (r_clock_dev == 1) begin
      //   r_vid_enable <= 1'b1;
      // end
    end

    // Count the horizontal and vertical positions
    reg vt_count_enable = 1'b0;
    reg hz_region_act;
    // reg hz_region_sync;
    reg vt_region_act;
    // reg vt_region_sync;
    reg r_frame_end = 1'b0;

    // Generate the HSYNC/VSYNC front back porch pattern
    //
    // Horizontal order : Front Porch   | Sync        | Back Porch | Active region
    // Vertical order   : Active region | Front Porch | Sync       | Back Porge
    
    always @(posedge clk) begin

      // Set defaults
      r_frame <= 1'b0;

      // Only connect act when the enable is high
      if(r_vid_enable == 1'b1) begin
        // Handle horizontal counter
        //vt_count_enable = 1'b0;
        
        // Next position
        hz_count <= hz_count + 1;
        // When reaching the end of the line
        if(hz_count == (HZ_TOTAL)) begin 
          hz_count <= 0;
          vt_count_enable = 1'b1;
        end
      end

      // Simple implementation to sync the frame to the pal signal
      if(i_frame_end) begin
          r_frame_end <= 1'b1;
      end

      // Act when verticle line changes
      if(vt_count_enable == 1'b1) begin
        vt_count_enable = 1'b0;
        // Next line
        vt_count <= vt_count + 1;
        // Return when we reach the END of the FRAME
        //if(vt_count == (VT_TOTAL - 32 + {4'b0, i_vblank_width})) begin
        if(vt_count == VT_TOTAL || r_frame_end) begin
          r_frame_end <= 1'b0;
          vt_count <= 0;
          r_frame <= 1'b1;
        end
      end

      // HORIZONTAL
      
      // Set Horizontal active region
      hz_region_act <= 1'b0;
      r_x <= 0;
      if (hz_count > (HZ_TOTAL - HZ_ACT_PIX) & (vt_count < VT_ACT_LN)) begin
        hz_region_act <= 1'b1;
        r_x <= hz_count - (HZ_FRONT_PORCH + HZ_SYNC_WIDTH + HZ_BACK_PORCH);
      end
      
      // Sync
      r_hsync <= !SYNC_POL;
      if (hz_count >= HZ_FRONT_PORCH & hz_count < (HZ_FRONT_PORCH + HZ_SYNC_WIDTH)) begin
      //if (hz_count >= HZ_FRONT_PORCH & hz_count < (HZ_FRONT_PORCH + {4'b0, i_vblank_width})) begin
        r_hsync <= SYNC_POL;
          // Vertical sync
          r_vsync <= !SYNC_POL;
          if ((vt_count > (VT_ACT_LN + VT_FRONT_PORCH)) & (vt_count < (VT_ACT_LN + VT_FRONT_PORCH + VT_SYNC_WIDTH))) begin
            r_vsync <= SYNC_POL;
          end
      end

      // VERTICAL

      // Set Vertical active region
      vt_region_act <= 1'b0;
      r_y <= 0;
      if (vt_count < (VT_ACT_LN)) begin
        vt_region_act <= 1'b1;
        r_y <= {1'b0, vt_count};
      end
      

      
      // Pass data through to the output
      r_r <= 8'b00;
      r_g <= 8'b00;
      r_b <= 8'b00;
      if (vt_region_act == 1'b1 & hz_region_act == 1'b1) begin
        r_r <= i_r;
        r_g <= i_g;
        r_b <= i_b;
      end

    end
    
    // generate ADV data enable signal
    assign o_adv_de = DE_POL ? (hz_region_act & vt_region_act) : !(hz_region_act & vt_region_act);
    

endmodule
