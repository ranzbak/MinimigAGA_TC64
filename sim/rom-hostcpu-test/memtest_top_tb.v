`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02/04/2021 09:36:31 PM
// Design Name: 
// Module Name: memtest_top_tb
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


module memtest_top_tb(

    );
    
    reg clk;
    reg reset_n =0;
    reg [13:0] addr = 0;
    reg [14:0] addr_cnt = 0;
    wire [31:0] q;
    wire [31:0] q_orig;
    reg [31:0] q_reg;
    reg [31:0] q_reg_orig;
    reg [31:0] d = 0;
    reg we = 0;
    reg [3:0] bytesel = 0;
    reg [13:0] addr2 = 0;
    wire [31:0] q2;
    wire [31:0] q2_orig;
    reg [31:0] d2 = 0;
    reg [3:0] bytesel2 = 0;
    reg we2 = 0;
    
    reg [31:0] count = 0;

    // Clock generation
    initial begin
        clk_28 = 0;
        count = 0;
        reset_n = 1'b1;
    end
    always #35.71 clk_28 = ~clk_28;
    
    // Count to organize state
    always @(posedge clk) begin
        count <= count + 1;
    end
    
    // Write test data during the first cycles
    always @(posedge clk) begin
        we<=1'b0;
        bytesel <= 4'b0000;
        addr <= 0;
        addr2 <= 0;
        case(count)
            1: begin
                we<=1;
                bytesel <= 4'b1111;
                addr<= 0;
                d <= 32'hAABBCCDD;
            end
            2: begin
                we<=1;
                bytesel <= 4'b0011;
                addr<= 1;
                d <= 32'hAABBCCDD;
            end
            3: begin
                we<=1;
                bytesel <= 4'b1100;
                addr<= 2;
                d <= 32'hAABBCCDD;
            end
            4: begin
                we<=1;
                bytesel <= 4'b0000;
                addr<= 3;
                d <= 32'hAABBCCDD;
            end
            default: begin end
        endcase

        // Read memory
        if (count > 30) begin
            addr_cnt <= addr_cnt + 1;
            addr <= addr_cnt[14:1];
            addr2 <= addr_cnt[14:1] + 1;
        end
        
        q_reg <= q;
        q_reg_orig <= q_orig;
    end
    
    // OSDBOOT module
    OSDBoot_832_ROM #(
        .ADDR_WIDTH(15),    // Specify your actual ROM size to save LEs and unnecessary block RAM usage.
        .COL_WIDTH(8),      // Column width (8bit -> byte)
        .NB_COL(4)          // Number of columns in memory
    ) osdboot_832_rom (
       .clk(clk),
       .reset_n(reset_n),
       .addr(addr),
       .q(q),
       // Allow writes - defaults supplied to simplify projects that don't need to write.
       .d(d),
       .we(we),
       .bytesel(bytesel),
       // Second port
       .addr2(addr2),
       .q2(q2),
       .d2(d2),
       .we2(we2),
       .bytesel2(bytesel2)	
    );
    
    // OSDBOOT module
    OSDBoot_832_orig_ROM #(
        .maxAddrBitBRAM(15)    // Specify your actual ROM size to save LEs and unnecessary block RAM usage.
    ) osdboot_832_orig_rom (
       .clk(clk),
       .reset_n(reset_n),
       .addr(addr),
       .q(q_orig),
       // Allow writes - defaults supplied to simplify projects that don't need to write.
       .d(d),
       .we(we),
       .bytesel(bytesel),
       // Second port
       .addr2(addr2),
       .q2(q2_orig),
       .d2(d2),
       .we2(we2),
       .bytesel2(bytesel2)	
    );

    // end of simulation
    initial
    begin
    #5000;
    $display("End of simulation time is %d , expected is %d",$time, ($time/5));
    $finish;
    end

endmodule
