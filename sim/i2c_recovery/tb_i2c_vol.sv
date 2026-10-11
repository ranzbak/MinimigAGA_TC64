// tb_i2c_vol -- the OSD volume (audio_volume(): MAX9850 register 2) twice in a
// row through rtl/host/i2c_master_mmio.sv, with nothing in between to close
// the bus.  2026-10-11: the OSD volume value changed but the level did not;
// this bench showed the firmware's write, write, stop sequence is correct
// (two transactions, both to register 2) -- the MAX9850 itself was stuck and
// a full power cycle cured it (JTAG reloads do not reset it).
//
//   default:  write, write, stop (what audio_volume() and adv7511.c do) -> PASS
//   +fix:     i2c_write_multi with LAST_BYTE on the last byte -> FAILS: the
//             multi path sends no STOP and the next transfer is appended to the
//             open one (the bytes land in registers 3 and 4).  i2c_write_multi
//             is unused in the firmware; do not start using it without fixing
//             STATE_WRITE_MULTI's stop in i2c_master_mmio.sv.
// Derived from tb_i2c_fwseq.sv; the slave is the same register file (its
// 0x39 address stands in for the MAX9850).
//
//   xvlog -sv tb_i2c_vol.sv ../../rtl/host/i2c_master_mmio.sv ../../rtl/openaars/adv7511/i2c_master.v
//   xelab tb_i2c_vol -s vsnap && xsim vsnap -R [-testplusarg fix]
//
// was: tb_i2c_fwseq -- the 832 firmware's ADV7511 I2C sequences through
// rtl/host/i2c_master_mmio.sv against a register-file slave that logs every
// register WRITE, to see what the bus really does (Paul 2026-09-27: the OSD
// HDMI clock delay reverts to the default as soon as the menu cursor moves).
//
//   xvlog -sv tb_i2c_fwseq.sv ../../rtl/host/i2c_master_mmio.sv ../../rtl/openaars/adv7511/i2c_master.v
//   xelab tb_i2c_fwseq -s snap && xsim snap -R
`timescale 1ns / 1ps
module tb_i2c_vol;
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
    .sda_i(sda), .sda_o(sda_o), .sda_t(sda_t), .ext_int(1'b0));

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

task i2c_write_multi2(input [7:0] b0, input [7:0] b1);
    mmio_write({4'h0, 4'h3, b0});                      // WRITEMULTI
    mmio_write({4'h1, 4'h3, b1});                      // WRITEMULTI | LAST_BYTE
endtask
logic fix;
initial begin
    fix = $test$plusargs("fix");
    for (int i = 0; i < 256; i++) mem[i] = 8'h00;
    repeat (4) @(posedge clk); rst = 0;
    mmio_write({4'h0, 4'hc, 8'd16}); mmio_write({4'h0, 4'hd, 8'd0});
    repeat (8) @(posedge clk);
    $display("--- %s: volume 15 then 16 (reg 02 <= 0x59, then 0x58)", fix ? "write_multi + LAST_BYTE" : "write, write, stop");
    for (int k = 0; k < 2; k++) begin
        i2c_set_address(8'h72);
        if (fix) i2c_write_multi2(8'h02, 8'h59 - k);
        else begin i2c_write(8'h02); i2c_write(8'h59 - k); i2c_stop(); end
        wait_not_busy();
        repeat (400) @(posedge clk);
    end
    repeat (2000) @(posedge clk);
    $display("    reg 02 = %h, reg 03 = %h, reg 04 = %h, register writes %0d", mem[8'h02], mem[8'h03], mem[8'h04], nwrites);
    if (nwrites == 2 && mem[8'h02] == 8'h58 && mem[8'h03] == 8'h00 && mem[8'h04] == 8'h00)
        $display("ALL TESTS PASSED (two volume writes, both to reg 02)");
    else
        $display("TEST FAILED: %0d register writes, reg 02 = %h (expected 58), 03 = %h, 04 = %h", nwrites, mem[8'h02], mem[8'h03], mem[8'h04]);
    $finish;
end
initial begin #20000000 $display("FAIL: timeout"); $finish; end
endmodule
