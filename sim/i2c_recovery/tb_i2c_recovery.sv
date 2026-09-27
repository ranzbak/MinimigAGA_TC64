// tb_i2c_recovery -- CMD_RESET of rtl/host/i2c_master_mmio.sv is an I2C bus
// recovery: nine SCL clocks with SDA released, then a STOP, with the status
// register's busy bit (0x10) set until it is done.
//
//   (xsim: iverilog cannot parse i2c_master_mmio.sv's "typedef enum name {")
//   xvlog -sv tb_i2c_recovery.sv ../../rtl/host/i2c_master_mmio.sv \
//         ../../rtl/openaars/adv7511/i2c_master.v && xelab tb_i2c_recovery -s snap && xsim snap -R
`timescale 1ns / 1ps
module tb_i2c_recovery;
logic clk = 0, rst = 1;
always #5 clk = ~clk;

logic [15:0] d = 0, q;
logic        req = 0, wr = 0, sel = 0;
logic [31:2] addr = 0;
wire scl_o, scl_t, sda_o, sda_t;
// open-drain bus with pull-ups; a slave stuck mid-byte holds SDA low
logic slave_hold_sda = 1;
wire scl = scl_t ? 1'b1 : scl_o;
wire sda = (sda_t ? 1'b1 : sda_o) & !slave_hold_sda;

i2c_master_mmio dut (
    .clk(clk), .rst(rst), .d(d), .q(q), .interrupt(),
    .addr(addr), .i2c_select(sel), .interrupt_select(1'b0), .req(req), .wr(wr),
    .scl_i(scl), .scl_o(scl_o), .scl_t(scl_t),
    .sda_i(sda), .sda_o(sda_o), .sda_t(sda_t));

task mmio_write(input [15:0] v);
    @(posedge clk); d <= v; wr <= 1; sel <= 1; req <= 1;
    @(posedge clk); req <= 0; sel <= 0; wr <= 0;
endtask
task mmio_status(output [15:0] v);
    @(posedge clk); addr <= 30'd1; wr <= 0; sel <= 1; req <= 1;
    @(posedge clk); req <= 0; sel <= 0;
    @(posedge clk); v = q;
endtask

// count SCL rising edges while SDA is released by the master, and the STOP
integer rises = 0, stops = 0, errors = 0;
logic scl_q = 1, sda_q = 1;
always @(posedge clk) begin
    scl_q <= scl; sda_q <= (sda_t ? 1'b1 : sda_o);
    if (!scl_q && scl) rises = rises + 1;
    // STOP: the master releases SDA while SCL is high
    if (scl && scl_q && !sda_q && (sda_t ? 1'b1 : sda_o)) stops = stops + 1;
    // the slave lets go of SDA once it has been clocked out of its byte
    if (rises >= 3) slave_hold_sda <= 0;
end

logic [15:0] st;
integer n;
initial begin
    repeat (4) @(posedge clk); rst = 0;
    repeat (4) @(posedge clk);
    mmio_write({4'h0, 4'hc, 8'd16});   // prescale low byte = 16
    mmio_write({4'h0, 4'hd, 8'd0});    // prescale high byte
    repeat (8) @(posedge clk);
    rises = 0; stops = 0;
    mmio_write({4'h0, 4'hf, 8'd0});    // CMD_RESET
    repeat (6) @(posedge clk);
    mmio_status(st);
    if (!st[4]) begin $display("FAIL: busy not set during the recovery (status %h)", st); errors++; end
    n = 0;
    do begin mmio_status(st); n++; end while (st[4] && n < 2000);
    if (st[4]) begin $display("FAIL: busy never cleared"); errors++; end
    // nine recovery clocks, then the STOP's own SCL rise (SDA low) = 10 rising edges
    if (rises != 10) begin $display("FAIL: %0d SCL rising edges, expected 10 (9 clocks + the STOP)", rises); errors++; end
    if (stops != 1) begin $display("FAIL: %0d STOPs, expected 1", stops); errors++; end
    if (!scl || !(sda_t ? 1'b1 : sda_o)) begin $display("FAIL: bus not released at the end"); errors++; end
    if (errors == 0) $display("ALL TESTS PASSED (%0d SCL clocks, %0d STOP)", rises, stops);
    else $display("TEST FAILED (%0d)", errors);
    $finish;
end
initial begin #2000000 $display("FAIL: timeout"); $finish; end
endmodule
