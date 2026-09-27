// tb_i2c_fwseq -- the 832 firmware's ADV7511 I2C sequences through
// rtl/host/i2c_master_mmio.sv against a register-file slave that logs every
// register WRITE, to see what the bus really does (Paul 2026-09-27: the OSD
// HDMI clock delay reverts to the default as soon as the menu cursor moves).
//
//   xvlog -sv tb_i2c_fwseq.sv ../../rtl/host/i2c_master_mmio.sv ../../rtl/openaars/adv7511/i2c_master.v
//   xelab tb_i2c_fwseq -s snap && xsim snap -R
`timescale 1ns / 1ps
module tb_i2c_fwseq;
logic clk = 0, rst = 1;
always #5 clk = ~clk;

logic [15:0] d = 0, q;
logic        req = 0, wr = 0, sel = 0;
logic [31:2] addr = 0;
wire scl_o, scl_t, sda_o, sda_t;
logic s_drive = 0;                       // the slave pulls SDA low
wire scl = scl_t ? 1'b1 : scl_o;
wire sda = (sda_t ? 1'b1 : sda_o) & !s_drive;

i2c_master_mmio dut (
    .clk(clk), .rst(rst), .d(d), .q(q), .interrupt(),
    .addr(addr), .i2c_select(sel), .interrupt_select(1'b0), .req(req), .wr(wr),
    .scl_i(scl), .scl_o(scl_o), .scl_t(scl_t),
    .sda_i(sda), .sda_o(sda_o), .sda_t(sda_t));

//------------------------------------------------------------ slave at 0x39
logic [7:0] mem [0:255];
logic [7:0] ptr = 0, sh = 0;
integer     bitn = 0, nwrites = 0;
typedef enum {S_IDLE, S_ADDR, S_WDATA, S_RDATA} sst;
sst   st = S_IDLE;
logic first = 0, acked = 0, scl_q = 1, sda_q = 1;
always @(posedge clk) begin
    scl_q <= scl; sda_q <= sda;
    if (scl && scl_q && sda_q && !sda) begin            // START / repeated START
        st <= S_ADDR; bitn = 0; s_drive <= 0;
        $display("%t  bus: START", $time);
    end else if (scl && scl_q && !sda_q && sda) begin   // STOP
        st <= S_IDLE; s_drive <= 0;
        $display("%t  bus: STOP (state %0d, bits %0d)", $time, st, bitn);
    end else if (!scl_q && scl) begin                   // SCL rising: sample
        if ((st == S_ADDR || st == S_WDATA) && bitn < 8) begin sh = {sh[6:0], sda}; bitn++; end
        if (st == S_RDATA && bitn == 10) acked = !sda;  // the master's ACK/NAK
    end else if (scl_q && !scl) begin                   // SCL falling: act
        if ((st == S_ADDR || st == S_WDATA) && bitn == 8) begin
            if (st == S_ADDR) begin
                if (sh[7:1] == 7'h39) begin
                    s_drive <= 1;
                    $display("%t  bus: addr %h %s", $time, sh[7:1], sh[0] ? "R" : "W");
                    if (sh[0]) begin st <= S_RDATA; bitn = 20; end
                    else begin st <= S_WDATA; first = 1; bitn = 9; end
                end else begin st <= S_IDLE; $display("%t  bus: addr byte %h (not ours)", $time, sh); end
            end else begin
                s_drive <= 1;
                if (first) begin ptr = sh; first = 0; $display("%t  bus: pointer %h", $time, sh); end
                else begin
                    $display("%t  bus: WRITE reg %h <= %h", $time, ptr, sh);
                    mem[ptr] = sh; ptr++; nwrites++;
                end
                bitn = 9;
            end
        end else if ((st == S_ADDR || st == S_WDATA) && bitn == 9) begin
            s_drive <= 0; bitn = 0;
        end else if (st == S_RDATA) begin
            if (bitn == 20) begin
                // end of the address ACK: first data bit
                sh = mem[ptr];
                $display("%t  bus: READ reg %h -> %h", $time, ptr, sh);
                s_drive <= !sh[7]; bitn = 1;
            end else if (bitn < 8) begin
                s_drive <= !sh[7 - bitn]; bitn++;
            end else if (bitn == 8) begin
                s_drive <= 0; bitn = 10;                  // the master's ACK slot
            end else if (bitn == 10) begin
                if (acked) begin ptr++; sh = mem[ptr]; s_drive <= !sh[7]; bitn = 1; end
                else begin st <= S_IDLE; ptr++; end
            end
        end
    end
end

//------------------------------------------------------------ the firmware's MMIO calls
task mmio_write(input [15:0] v);
    @(posedge clk); d <= v; wr <= 1; sel <= 1; req <= 1; addr <= 30'd0;
    @(posedge clk); req <= 0; sel <= 0; wr <= 0;
endtask
task mmio_read(input [1:0] a, output [15:0] v);
    @(posedge clk); addr <= {28'd0, a}; wr <= 0; sel <= 1; req <= 1;
    @(posedge clk); req <= 0; sel <= 0;
    @(posedge clk); v = q;
endtask
logic [15:0] st_v;
task wait_not_busy;
    integer n; n = 0;
    do begin mmio_read(2'd1, st_v); n++; end while (st_v[4] && n < 5000);
endtask
task i2c_set_address(input [7:0] a); mmio_write({4'h0, 4'hb, a}); endtask
task i2c_write(input [7:0] b);       mmio_write({4'h0, 4'h2, b}); endtask
task i2c_stop;                       mmio_write({4'h0, 4'h5, 8'h00}); endtask
task i2c_read_reg(input [7:0] r, output [7:0] v);
    logic [15:0] t; integer n;
    i2c_set_address(8'h72); i2c_write(r);
    mmio_write({4'h1, 4'h1, 8'h00});                   // READ | LAST_BYTE
    wait_not_busy();
    n = 0; do begin mmio_read(2'd1, t); n++; end while (t[2] && n < 5000);
    mmio_read(2'd0, t); v = t[7:0];
endtask

logic [7:0] v;
integer w0;
initial begin
    for (int i = 0; i < 256; i++) mem[i] = 8'h00;
    mem[8'h42] = 8'h60;                                // HPD + monitor sense
    mem[8'hba] = 8'h00;
    repeat (4) @(posedge clk); rst = 0;
    mmio_write({4'h0, 4'hc, 8'd16}); mmio_write({4'h0, 4'hd, 8'd0});
    repeat (8) @(posedge clk);

    $display("--- 1: slider: adv_write_clkdelay(3) = pointer BA, 0x60, stop");
    i2c_set_address(8'h72); i2c_write(8'hba); i2c_write(8'h60); i2c_stop(); wait_not_busy();
    repeat (200) @(posedge clk);
    $display("    reg BA = %h", mem[8'hba]);

    $display("--- 2: page redraw: adv7511_read_clkdelay()");
    w0 = nwrites;
    i2c_read_reg(8'hba, v);
    $display("    read %h, reg BA = %h, writes during the read: %0d", v, mem[8'hba], nwrites - w0);

    $display("--- 3: poll: read 42, then pointer 96 + C0, stop");
    i2c_read_reg(8'h42, v);
    $display("    status %h", v);
    i2c_set_address(8'h72); i2c_write(8'h96); i2c_write(8'hc0); i2c_stop(); wait_not_busy();
    repeat (200) @(posedge clk);

    $display("--- 4: next poll and redraw");
    w0 = nwrites;
    i2c_read_reg(8'h42, v); $display("    status %h", v);
    i2c_read_reg(8'hba, v); $display("    read BA %h", v);
    $display("    reg BA = %h, stray writes: %0d", mem[8'hba], nwrites - w0);
    // exactly the two intended register writes (BA <= 60, 96 <= C0), and the
    // reads return what the registers hold
    if (nwrites == 2 && mem[8'hba] == 8'h60 && v == 8'h60)
        $display("ALL TESTS PASSED (2 register writes, reads correct)");
    else
        $display("TEST FAILED: %0d register writes (expected 2), BA = %h, last read %h", nwrites, mem[8'hba], v);
    $finish;
end
initial begin #20000000 $display("FAIL: timeout"); $finish; end
endmodule
