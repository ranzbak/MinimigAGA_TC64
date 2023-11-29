`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 11/23/2023 09:28:00 PM
// Design Name:
// Module Name: rtc_spi_clock_tb
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

module rtc_spi_clock_tb;

// Parameters
localparam integer CLK_PERIOD_28MHZ = 6; // Clock period for 28MHz (in ns)
localparam integer CLK_PERIOD_1MHZ = 100; // Clock period for 1MHz (in ns)
localparam integer RESET_DURATION = 200; // Reset duration for 10us (in ns)

// Testbench Signals
reg clk;
reg reset;
reg cs_n;
reg cpu_rd_n;
reg cpu_wr_n;
reg [3:0] cpu_address;
reg [3:0] rtc_data_in;
wire [3:0] rtc_data_out;
reg rtcclkout;
reg rtc_int_n;
wire rtc_spi_ce;
wire rtc_spi_clk;
wire rtc_spi_cmd;
reg rtc_spi_data0;

// Instantiate the rtc_spi_clock module
rtc_spi_clock uut (
    .clk(clk),
    .reset(reset),
    .cs_n(cs_n),
    .cpu_rd_n(cpu_rd_n),
    .cpu_wr_n(cpu_wr_n),
    .cpu_address(cpu_address),
    .rtc_data_in(rtc_data_in),
    .rtc_data_out(rtc_data_out),
    .rtc_clkout(rtcclkout),
    .rtc_int_n(rtc_int_n),
    .rtc_spi_ce(rtc_spi_ce),
    .rtc_spi_clk(rtc_spi_clk),
    .rtc_spi_cmd(rtc_spi_cmd),
    .rtc_spi_data0(rtc_spi_data0)
);

// Clock generation
always #(CLK_PERIOD_28MHZ/2) clk = ~clk;

// 1MHz rtcclkout generation
always #(CLK_PERIOD_1MHZ/2) rtcclkout = ~rtcclkout;

// Initial block for test sequence
initial begin
    // Initialize signals
    clk = 0;
    reset = 1;
    cs_n = 1;
    cpu_rd_n = 1;
    cpu_wr_n = 1;
    cpu_address = 0;
    rtc_data_in = 0;
    rtcclkout = 0;
    rtc_int_n = 1;
    rtc_spi_data0 = 0;

    // Keep the system in reset for 10us
    #(RESET_DURATION);
    reset = 0;

end



// End simulation at 1000 clock cycles
initial begin
    // Simulation run for a specific time
    #(100000 * CLK_PERIOD_28MHZ);

    // Finish simulation
    $finish;

end

endmodule
