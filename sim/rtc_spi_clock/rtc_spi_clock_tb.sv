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
logic clk;
logic reset;
logic cs_n;
logic cpu_rd_n;
logic cpu_wr_n;
logic [3:0] cpu_address;
logic [3:0] rtc_data_in;
wire [3:0] rtc_data_out;
logic rtc_clkout;
logic rtc_int_n;
wire rtc_spi_ce;
wire rtc_spi_clk;
wire rtc_spi_cmd;
logic rtc_spi_data0;

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
    .rtc_clkout(rtc_clkout),
    .rtc_int_n(rtc_int_n),
    .rtc_spi_ce(rtc_spi_ce),
    .rtc_spi_clk(rtc_spi_clk),
    .rtc_spi_cmd(rtc_spi_cmd),
    .rtc_spi_data0(rtc_spi_data0)
);


spi_slave my_spi_slave (
    .clk(clk),           // System clock
    .rst(reset),         // Active low reset
    .cs(rtc_spi_ce),           // Chip Select, active low
    .sclk(rtc_spi_clk),  // SPI Clock
    .mosi(rtc_spi_cmd),  // Master Out, Slave In
    .miso(rtc_spi_data0) // Master In, Slave Out
);

// Clock generation
always #(CLK_PERIOD_28MHZ/2) clk = ~clk;

// 1MHz rtcclkout generation
always #(CLK_PERIOD_1MHZ/2) rtc_clkout = ~rtc_clkout;

// Initial block for test sequence
initial begin
    // Initialize signals
    clk = 0;
    reset = 1;
    // cs_n = 1;
    // cpu_rd_n = 1;
    // cpu_wr_n = 1;
    // cpu_address = 0;
    rtc_data_in = 0;
    rtc_clkout = 0;
    rtc_int_n = 1;
    // rtc_spi_data0 = 0;

    // Keep the system in reset for 10us
    #(RESET_DURATION);
    reset = 0;
end

reg [3:0] addr_counter = 0;
always_ff @(posedge clk) begin


    if (reset) begin
        addr_counter <= 0;
        cs_n <= 1'b1;
        cpu_rd_n <= 1'b1;
        cpu_wr_n <= 1'b1;
    end else begin
        // Increase address counter
        addr_counter <= addr_counter + 1;

        // Setup port for reading
        cs_n <= 1'b0;
        cpu_rd_n <= 1'b0;
        cpu_wr_n <= 1'b1;

        if (addr_counter == 4'hf) begin
            addr_counter <= 4'h0;
        end
    end
end

assign cpu_address = addr_counter;

// End simulation at 1000 clock cycles
initial begin
    // Simulation run for a specific time
    #(500000 * CLK_PERIOD_28MHZ);

    // Finish simulation
    $finish;

end

endmodule
