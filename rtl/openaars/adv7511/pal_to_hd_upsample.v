`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 05/13/2020 09:08:37 PM
// Design Name:
// Module Name: pal_to_hd_upsample
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


module pal_to_hd_upsample(
    input clk,
    // Pal input
    input           i_pal_hsync,
    input           i_pal_vsync,
    input  [7:0]    i_pal_r,
    input  [7:0]    i_pal_g,
    input  [7:0]    i_pal_b,
    input           i_pal_clk,
    // HD upsampled output
    output [7:0]    o_hd_r,
    output [7:0]    o_hd_g,
    output [7:0]    o_hd_b,
    output          o_hd_vsync,
    //output [6:0]    o_vblank_width,
    output          o_frame_end,
    // HD sync pulse
    input           i_hd_hsync,
    input           i_hd_vsync,
    input           i_hd_clk,
    input           i_hd_four_three     // Display content as 4:3 (1) instead of 16:9 (0)
);
    // constants
    parameter OFFSET_HZ = 0;    // Number of pixels offset to center the screen horizontally (Higher is more to the left)
    parameter OFFSET_VT = 32;   // Number of Lines to center the screen vertically (NOT IMPLEMENTED YET)
    parameter HD_H_RES  = 1360; // Resolution of the output signal
    parameter HD_H_FP   = 0;    // Horizontal front porge, move image to the right
    parameter HD_FT_BAR = 160;  // The width of the bar before and after the active area when in 4:3 mode
    parameter PAL_H_FP  = 32;

    // Output registers
    reg [7:0]   r_hd_r;
    reg [7:0]   r_hd_g;
    reg [7:0]   r_hd_b;

    reg   [1:0] r_cur_read_buf  = 2'b00;  // Number of the current read buffer
    reg   [1:0] r_cur_write_buf = 2'b00;  // Number of the current write buffer
    reg         r_next_buf      = 1'b0;  // signal when to swap buffer

    reg         r_pal_hsync_;
    reg         r_pal_vsync_;
    reg         r_hd_hsync_;

    reg         r_frame_end;

    // Buffer to hold 2 lines of data
    reg         r_ena;
    reg         r_wea;
    reg  [12:0] r_addra = 0;
    reg  [23:0] r_dina;
    reg  [12:0] r_addrb = 0;
    wire [23:0] w_doutb;

    // blk_mem_gen_1 upsample_blk_ram (
    //     .clka(clk),    // input wire clka
    //     .ena(r_ena),      // input wire ena
    //     .wea(r_wea),      // input wire [0 : 0] wea
    //     .addra(r_addra),  // input wire [11 : 0] addra
    //     .dina(r_dina),    // input wire [23 : 0] dina
    //     .clkb(clk),    // input wire clkb
    //     .addrb(r_addrb),  // input wire [11 : 0] addrb
    //     .doutb(w_doutb)  // output wire [23 : 0] doutb
    // );
    bram_tdp #(
        .DATA(24),
        .ADDR(13)
    ) upsample_blk_ram (
        .a_clk(clk),    // input wire clka
        .a_wr(r_wea),      // input wire [0 : 0] wea
        .a_addr(r_addra),  // input wire [11 : 0] addra
        .a_din(r_dina),    // input wire [23 : 0] dina
        .a_dout(),
        .b_clk(clk),    // input wire clkb
        .b_addr(r_addrb),  // input wire [11 : 0] addrb
        .b_din(),
        .b_dout(w_doutb)  // output wire [23 : 0] doutb
    );

    // count the clock cycles a line takes
    reg         r_line_active = 1'b0;
    reg         r_act_active = 1'b0;
    reg [13:0]  r_line_count = 14'b0;
    reg [5:0]   r_pix_clock_dev = 6'd0;
    reg [13:0]  r_pal_h_pos = 14'b0;
    reg [11:0]  v_div_var = 12'b0;
    always @(posedge clk) begin
        // start of the horizontal line
        if (r_pal_hsync_ == 1'b1 && i_pal_hsync == 1'b0) begin
            r_line_active <= 1'b1;
        end

        // end of the horizontal line
        if (r_pal_hsync_ == 1'b0 && i_pal_hsync == 1'b1) begin
            r_line_active   <= 1'b0; // Stop counter
            r_line_count    <= 0;  // Reset counter
            v_div_var        = (r_line_count[13:6] / (HD_H_RES>>8)) - 1; // Shift numbers to make devider circuit faster
            r_pix_clock_dev <= v_div_var[5:0]; // Get the pixel clock relative to the system clock
        end

        // when active inclease counter
        if (r_line_active == 1'b1) begin
            r_line_count <= r_line_count + 1;
            // active part of the horiz0ntal line
            if (r_line_count > 300) begin
                r_pal_h_pos <= r_pal_h_pos + 1;
                r_act_active <= 1'b1;
            end
        end else begin
            r_line_count <= 0;
            r_act_active <= 0;
        end
    end

    // Generate sample enable
    reg [5:0]   r_pix_clock_count = 6'b0;
    reg         r_pix_en = 1'b0;
    always @(posedge clk) begin
        if (r_line_active) begin
            r_pix_clock_count <= r_pix_clock_count + 3'b100;

            r_pix_en <= 1'b0;
            if (r_pix_clock_count >= r_pix_clock_dev) begin
                r_pix_clock_count <= r_pix_clock_count - r_pix_clock_dev;
                r_pix_en <= 1'b1;
            end
        end else begin
            r_pix_clock_count <= 0;
        end
    end

    // Sample PAL input stream
    reg         r_hd_clk_;
    reg [11:0]  r_h_pos = 12'b0;
    always @(posedge clk) begin
        r_pal_hsync_ <= i_pal_hsync;

        // write the pixel
        r_wea <= 1'b0;
        r_ena <= 1'b1;
        if (r_pix_en && ~i_pal_hsync) begin
            r_addra <= r_addra+1;
            r_wea <= 1'b1;
            //r_ena <= 1'b1;
            r_dina <= {i_pal_b, i_pal_g, i_pal_r};
        end

        // End of input line
        if (r_pal_hsync_ == 1'b1 && i_pal_hsync == 1'b0) begin
            r_next_buf <= 1'b1; // Switch buffer

            // Switch to next write buffer
            if (r_cur_write_buf != 2'b11) begin
                r_cur_write_buf <= (r_cur_write_buf + 1);
            end else begin
                r_cur_write_buf <= 2'd0;
            end

            // Switch the current write buffer
            case (r_cur_write_buf)
                0:
                    r_addra <= 13'b0000;
                1:
                    r_addra <= 13'h0800;
                2:
                    r_addra <= 13'h1000;
                3:
                    r_addra <= 13'h1800;
            endcase;
        end

        // read from buffer
        r_hd_clk_ <= i_hd_clk;
        if (i_hd_four_three) begin
            if (r_hd_clk_ == 1'b1 && i_hd_clk == 1'b0 && ~i_hd_hsync) begin
                r_h_pos <= r_h_pos + 1;
                if (r_h_pos > HD_FT_BAR && r_h_pos < (HD_H_RES-HD_FT_BAR)) begin
                    r_addrb <= r_addrb+1;
                    r_hd_r <= w_doutb[0 +: 8];
                    r_hd_g <= w_doutb[8 +: 8];
                    r_hd_b <= w_doutb[16 +: 8];
                end else begin
                    r_hd_r <= 8'b0;
                    r_hd_g <= 8'b0;
                    r_hd_b <= 8'b0;
                end
            end
        end else begin
            if (r_hd_clk_ == 1'b1 && i_hd_clk == 1'b0 && ~i_hd_hsync) begin
                r_h_pos <= r_h_pos + 1;
                if (r_h_pos > HD_H_FP && r_h_pos < (HD_H_RES-HD_H_FP)) begin
                    r_addrb <= r_addrb+1;
                    r_hd_r <= w_doutb[0 +: 8];
                    r_hd_g <= w_doutb[8 +: 8];
                    r_hd_b <= w_doutb[16 +: 8];
                end else begin
                    r_hd_r <= 8'b0;
                    r_hd_g <= 8'b0;
                    r_hd_b <= 8'b0;
                end
            end
        end

        // Handle next line
        r_hd_hsync_ <= i_hd_hsync;
        if (r_hd_hsync_ == 1'b0 && i_hd_hsync == 1'b1) begin
            if (r_next_buf) begin
                r_next_buf <= 1'b0;

                if (r_cur_read_buf != 2'b11) begin
                    r_cur_read_buf <= r_cur_read_buf + 1;
                end else begin
                    r_cur_read_buf <= 0;
                end
            end
            r_h_pos <= 0; // Reset horizontal counter
            case (r_cur_read_buf)
                0:
                    r_addrb <= 13'b0000 + OFFSET_HZ;
                1:
                    r_addrb <= 13'h0800 + OFFSET_HZ;
                2:
                    r_addrb <= 13'h1000 + OFFSET_HZ;
                3:
                    r_addrb <= 13'h1800 + OFFSET_HZ;
            endcase;
        end

        // Provide end of sync signal
        r_pal_vsync_ <=  i_pal_vsync;
        r_frame_end <= 1'b0;
        if (r_pal_vsync_ == 1'b1 && i_pal_vsync == 1'b0) begin
            r_frame_end <= 1'b1;
            // Reset the read and write buffer to start
            r_cur_read_buf  <= 0;
            r_cur_write_buf <= 2;
        end
    end

    // output assignments
    assign o_hd_r = r_hd_r;
    assign o_hd_g = r_hd_g;
    assign o_hd_b = r_hd_b;
    assign o_frame_end = r_frame_end;
    //assign o_vblank_width = r_vblank_width;

    // Change the Vsync timing to translate the image up N lines
    translate_vert my_translate_vert (
        .clk(clk),
        .pix_en(r_pix_en),      // Pixel clock
        .i_vsync(i_hd_vsync),   // Original Vsync signal
        .v_trans(OFFSET_VT),    // Number of lines to translate the vsync down
        .o_vsync(o_hd_vsync)    // Delayed HD vsync signal
    );
endmodule

module translate_vert(
    input clk,
    input pix_en,                               // Pixel clock
    input i_vsync,                              // Original Vsync signal
    input [8:0] v_trans,                        // Number of lines to translate the vsync down
    output o_vsync
);
    // Horizontal timing 720p 50Hz @ 50MHz clock
    parameter HZ_ACT_PIX = 1280;
    parameter HZ_FRONT_PORCH = 8;
    parameter HZ_SYNC_WIDTH = 32;
    parameter HZ_BACK_PORCH = 40;
    parameter HZ_TOTAL = HZ_ACT_PIX + HZ_FRONT_PORCH + HZ_SYNC_WIDTH + HZ_BACK_PORCH;
    parameter MAX_TRANSLATE = 128;

    reg delay_count_1_start = 0;
    reg [$clog2(MAX_TRANSLATE*HZ_TOTAL):0] delay_count_1 = 0;
    reg delay_count_0_start = 0;
    reg [$clog2(MAX_TRANSLATE*HZ_TOTAL):0] delay_count_0 = 0;
    reg vsync2;
    reg vsync_pulse;
    reg r_vsync;

    assign o_vsync = r_vsync;

    // generate hsync up/down pulse
    always @(posedge clk) begin
        vsync2 <= i_vsync;

        // Vsync delta pulse
        vsync_pulse <= 0;
        if (i_vsync != vsync2) begin
           vsync_pulse <= 1;
        end 
    end

    // Handle delay of vsync to translate the image
    // The more the vsync is delayed, the more the image moves up
    always @(posedge clk) begin
        // from 0 to 1
        if (vsync_pulse && i_vsync) begin
            delay_count_1 <= HZ_TOTAL*v_trans;
            delay_count_1_start <= 1;
        end 
        // from 1 to 0
        if (vsync_pulse && ~i_vsync) begin
            delay_count_0 <= HZ_TOTAL*v_trans;
            delay_count_0_start <= 1;
        end        

        // Decrease the counter based on the pixel clock
        if (pix_en) begin
            if (delay_count_0_start) begin
                delay_count_0 <= delay_count_0 - 1;
            end
            if (delay_count_1_start) begin
                delay_count_1 <= delay_count_1 - 1;
            end
        end

        // When the counters are done change the output signal
        if ((delay_count_1 == 0) && delay_count_1_start) begin
            delay_count_1_start <= 0;
            r_vsync <= 1;    
        end

        if ((delay_count_0 == 0) && delay_count_0_start) begin
            delay_count_0_start <= 0;
            r_vsync <= 0;    
        end
    end
endmodule
