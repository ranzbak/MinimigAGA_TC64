`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 06/08/2023 09:43:34 PM
// Design Name:
// Module Name: i2c_sender_tb
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


module i2c_sender_tb;

    reg clk;
    reg rst;
    reg resend;
    reg read_regs;
    reg dv_int;
    wire scl_i;
    wire sda_i;

    wire out_valid;
    wire [7:0] out_addr;
    wire [7:0] out_value;
    wire scl_t;
    wire scl_o;
    wire sda_t;
    wire sda_o;

    // FSM state of i2c_sender VHDL module
    wire [4:0] send_state;
    parameter WAIT_RETRANS = 5'b00100;  // Assuming that WAIT_RETRANS state corresponds to this value


    initial begin
        clk = 0;
        rst = 1;
        resend = 1'b0;
        read_regs = 1'b0;
        dv_int = 1'b0;
    end

    always begin
        #5 clk = ~clk;
    end

    assign scl_i = scl_o & 1'b1;
    assign sda_i = sda_o & 1'b1;

    i2c_sender dut (
        .clk(clk),
        .rst(rst),
        .resend(resend),
        .read_regs(read_regs),
        .out_valid(out_valid),
        .out_addr(out_addr),
        .out_value(out_value),
        .scl_i(scl_i),
        .scl_t(scl_t),
        .scl_o(scl_o),
        .sda_i(sda_i),
        .sda_t(sda_t),
        .sda_o(sda_o),
        .dv_int(dv_int)
    );

    initial begin
        // Reset the dut
        #0 rst = 1;
        #20 rst = 0;

        // Add your stimulus here

        // Wait for the FSM to reach the WAIT_RETRANS state
         wait(send_state === WAIT_RETRANS);
        #400 $display("FSM has reached WAIT_RETRANS state at time: %t", $time);

        // Finish the simulation
        $finish;
    end


endmodule