`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01/02/2020 06:22:06 PM
// Design Name: 
// Module Name: aars_video_top
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
module pal_to_ddr(
        input clk,
        // Pal input
        input i_pal_hsync,
        input i_pal_vsync,
        input [7:0] i_pal_r,
        input [7:0] i_pal_g,
        input [7:0] i_pal_b,

        // OUTPUT
        output o_clk_pixel,    // Output pixel clock after synchronization to clk_ddr
        output o_de,            // Data enable signal
        output o_vsync,
        output o_hsync,
        output [11:0] o_data           // DDR data stream out
);
    // Generated RGB values
    wire [7:0] w_r;
    wire [7:0] w_g;
    wire [7:0] w_b;
    wire       w_vsync;

    // Upsample routine
    wire [6:0] w_vblank_width;
    wire w_hd_hsync;
    wire w_hd_vsync;

    // Current video postion
    wire [11:0] w_x;
    wire [11:0] w_y;
    wire        w_frame_end;

    // enable to indicate the next data point is needed
    wire w_adv_de;
    wire w_adv_clk;

    // RGB signal in 720p@50Hz before DDR
    wire [7:0] w_o_r;
    wire [7:0] w_o_g;
    wire [7:0] w_o_b;


    reg _i_pal_hsync;
    reg __i_pal_hsync;
    reg _i_pal_vsync;
    reg __i_pal_vsync;
    reg [7:0] _i_pal_r;
    reg [7:0] __i_pal_r;
    reg [7:0] _i_pal_g;
    reg [7:0] __i_pal_g;
    reg [7:0] _i_pal_b;
    reg [7:0] __i_pal_b;

    // Synchronize the signal
    always @(posedge clk) begin
        // Hsync
        _i_pal_hsync  <= i_pal_hsync;
        __i_pal_hsync <= _i_pal_hsync;
        // Vsync
        _i_pal_vsync  <= i_pal_vsync;
        __i_pal_vsync <= _i_pal_vsync;
        // Red
        _i_pal_r      <= i_pal_r;
        __i_pal_r     <= _i_pal_r;
        // Green
        _i_pal_g      <= i_pal_g;
        __i_pal_g     <= _i_pal_g;
        // Blue
        _i_pal_b      <= i_pal_b;
        __i_pal_b     <= _i_pal_b;
    end

    // Upscale the video signal using a line buffer
    pal_to_hd_upsample myupsample(
        .clk(clk),
        // Pal input
        .i_pal_hsync(__i_pal_hsync),
        .i_pal_vsync(__i_pal_vsync),
        .i_pal_r(__i_pal_r),
        .i_pal_g(__i_pal_g),
        .i_pal_b(__i_pal_b),
        // HD upsampled output
        .o_hd_r(w_r),
        .o_hd_g(w_g),
        .o_hd_b(w_b),
        .o_hd_vsync(w_vsync),
        //.o_vblank_width(w_vblank_width),
        .o_frame_end(w_frame_end),
        // HD sync pulse
        .i_hd_hsync(o_hsync),
        .i_hd_vsync(w_hd_vsync),
        .i_hd_clk(w_adv_clk),
        .i_hd_four_three(1'b0)
    );

    // Generate the 720p Hsync and Vsync signals
    signal_generator hd_gen(
        .clk(clk),
        //.i_vblank_width(w_vblank_width),
        .i_frame_end(w_frame_end),
        .i_r(w_r),
        .i_g(w_g),
        .i_b(w_b),
        // Output signals
        .o_x(w_x),
        .o_y(w_y),
        .o_r(w_o_r),
        .o_g(w_o_g),
        .o_b(w_o_b),
        .o_adv_clk(w_adv_clk),
        .o_hsync(w_hd_hsync),
        .o_vsync(w_hd_vsync),
        .o_adv_de(w_adv_de)
    );
    
    // ADV DDR output
    adv_ddr myadr_ddr (
        // INPUT
        .clk_ddr(clk),            // DDR clock at 4xpixel clock
        .clk_pixel(w_adv_clk),        // Pixel clock

        .de_in(w_adv_de),       // Used to generate DE
        .hsync(w_hd_hsync),
        .vsync(w_vsync),
        .data({w_o_r, w_o_g, w_o_b}), // Pixel data in 24-bpp

        // OUTPUT
        .clk_pixel_out(o_clk_pixel),    // Output pixel clock after synchronization to clk_ddr
        .de_out(o_de),            // Data enable signal
        .vsync_out(o_vsync),
        .hsync_out(o_hsync),
        .data_out(o_data)           // DDR data stream out
    );
endmodule
