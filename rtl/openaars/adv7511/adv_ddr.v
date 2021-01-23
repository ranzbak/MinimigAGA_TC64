// ADV video out DDR
// Paul Honig 2020
//

// When register 0x16 = 0 first byte in middle of positive
// https://www.analog.com/media/en/technical-documentation/user-guides/ADV7511_Hardware_Users_Guide.pdf
// Page 35
module adv_ddr 
(
	// INPUT
	input clk_ddr,			// DDR clock at 4xpixel clock
	input clk_pixel,        // Pixel clock
	
	input de_in,		// Used to generate DE
	input vsync, hsync,     // 
	input [23:0 ] data,     // Pixel data in 24-bpp

	// OUTPUT
	output reg clk_pixel_out,   // Output pixel clock after synchronization to clk_ddr
	output reg de_out,			// Data enable signal
	output reg vsync_out, hsync_out,
	output reg [11:0] data_out  // DDR data stream out
);

reg clk_pixel_, clk_pixel__;
reg de_in_, de_in__;

reg vsync_, vsync__;
reg hsync_, hsync__;

reg [23:0] data_, data__;


// Synchronize signal to clk_ddr
always @(posedge clk_ddr) begin
	clk_pixel_ <= clk_pixel;
	clk_pixel__ <= clk_pixel_;

	de_in_ <= de_in;
	de_in__ <= de_in_;

	vsync_ <= vsync;
	vsync__ <= vsync_;

	hsync_ <= hsync;
	hsync__ <= hsync_;

	data_ <= data;
	data__ <= data_;
end

// Generate DDR signals
reg clk_pixel_prev = 0;
reg [1:0] phase_count = 0;
always @(posedge clk_ddr) begin
	clk_pixel_prev <= clk_pixel__;

	// Next phase
	phase_count <= phase_count + 1; 

	// Handle positive pixel clock edge
	if (!clk_pixel_prev && clk_pixel__) begin
		phase_count <= 0;
	end

	// Do actions according to phases
	case (phase_count)
		2'b00: begin
			// Output the lower (1st) part
			data_out <= data__[11:0];
			// Output vsync and hsync as well
			vsync_out <= vsync__;
			hsync_out <= hsync__;
			// Generate data enable
			de_out <= de_in__;
		end
		2'b10: begin
			// Output the high (2nd) part
			data_out <= data__[23:12];
		end
	endcase

	// Output synchronized pixel clock 
	clk_pixel_out <= clk_pixel__;
end

endmodule
