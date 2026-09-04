//-----------------------------------------------------------------
// ddr3_island_tb - bench for rtl/ddr3/ddr3_top.v (task 2, hardware stage A gate)
//
// DUT: the whole island (ddr3_pll + ddr3_bist + ddr3_core + ddr3_dfi_phy)
// against the Micron 2Gb DDR3 model that ships with the vendored controller
// (lib/core_ddr3_controller/tb/ddr3_core_xc7/ddr3.v).  The model is
// instantiated exactly as the vendored testbench does: no `x16`/`sgNNN`
// defines, which selects the x16 organisation (14 row / 10 column bits,
// 2 DQS groups) and the sg25 / DDR3-800 timing bin - the slowest bin, hence
// the strictest set of minimum timings for a 100 MHz DLL-off controller.
//
// Caveat inherited from the vendored bench: the model prints
// "Load Mode 1 DLL off mode is not fully modeled".  This proves the command
// sequencing, the PHY gearing and the data path.  It does not prove DLL-off
// behaviour on the real part; that is hardware stage A.
//
// Tests
//   1  PLL locks
//   2  controller init completes
//   3..7  BIST patterns 0..4 over 2^12 bytes, zero errors, expected line count
//   8  fault injection: DQ[0] forced low for a read-only pass -> exactly one
//      error at the expected address with the expected XOR
//   9  external request port through the arbiter: 4 writes then 4 reads
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module ddr3_island_tb;

//-----------------------------------------------------------------
// Scoreboard
//-----------------------------------------------------------------
integer pass_cnt = 0;
integer fail_cnt = 0;

task check(input [511:0] name, input cond);
begin
    if (cond) begin pass_cnt = pass_cnt + 1; $display("PASS: %0s", name); end
    else      begin fail_cnt = fail_cnt + 1; $display("FAIL: %0s", name); end
end
endtask

//-----------------------------------------------------------------
// Board clock and reset
//-----------------------------------------------------------------
reg clk_50 = 1'b0;
always #10 clk_50 = ~clk_50;      // 50 MHz

reg reset_n = 1'b0;
initial begin
    #500;
    reset_n = 1'b1;
end

//-----------------------------------------------------------------
// DUT connections
//-----------------------------------------------------------------
wire         clk100;
wire         rst100;
wire         init_done;
wire         pll_locked;

reg          req_valid  = 1'b0;
reg  [ 15:0] req_wr     = 16'b0;
reg  [ 31:0] req_addr   = 32'b0;
reg  [127:0] req_wdata  = 128'b0;
wire         req_accept;
wire         resp_valid;
wire [127:0] resp_rdata;

reg          bist_start      = 1'b0;
reg  [  2:0] bist_pattern    = 3'b0;
reg  [  4:0] bist_range_log2 = 5'd12;
reg          bist_mode       = 1'b0;
wire         bist_busy;
wire         bist_done;
wire [ 31:0] bist_err_count;
wire [ 31:0] bist_first_err_addr;
wire [ 31:0] bist_first_err_xor;
wire [ 31:0] bist_lines_done;

reg          phy_cfg_valid = 1'b0;
reg  [  1:0] phy_dqs_inc   = 2'b0;
reg  [  1:0] phy_dqs_rst   = 2'b0;
reg  [  1:0] phy_dq_inc    = 2'b0;
reg  [  1:0] phy_dq_rst    = 2'b0;
reg  [  2:0] phy_rdlat     = 3'd5;
reg  [  3:0] phy_rdsel     = 4'd0;

wire [ 13:0] ddr3_addr;
wire [  2:0] ddr3_ba;
wire         ddr3_ras_n;
wire         ddr3_cas_n;
wire         ddr3_we_n;
wire         ddr3_cs_n;
wire         ddr3_cke;
wire         ddr3_odt;
wire         ddr3_reset_n;
wire         ddr3_ck_p;
wire         ddr3_ck_n;
wire [  1:0] ddr3_dm;
wire [ 15:0] ddr3_dq;
wire [  1:0] ddr3_dqs_p;
wire [  1:0] ddr3_dqs_n;

ddr3_top u_dut
(
     .clk_50(clk_50)
    ,.reset_n(reset_n)

    ,.clk100(clk100)
    ,.rst100(rst100)
    ,.init_done(init_done)
    ,.pll_locked(pll_locked)

    ,.req_valid(req_valid)
    ,.req_wr(req_wr)
    ,.req_addr(req_addr)
    ,.req_wdata(req_wdata)
    ,.req_accept(req_accept)
    ,.resp_valid(resp_valid)
    ,.resp_rdata(resp_rdata)

    ,.bist_start(bist_start)
    ,.bist_pattern(bist_pattern)
    ,.bist_range_log2(bist_range_log2)
    ,.bist_mode(bist_mode)
    ,.bist_busy(bist_busy)
    ,.bist_done(bist_done)
    ,.bist_err_count(bist_err_count)
    ,.bist_first_err_addr(bist_first_err_addr)
    ,.bist_first_err_xor(bist_first_err_xor)
    ,.bist_lines_done(bist_lines_done)

    ,.phy_cfg_valid(phy_cfg_valid)
    ,.phy_dqs_inc(phy_dqs_inc)
    ,.phy_dqs_rst(phy_dqs_rst)
    ,.phy_dq_inc(phy_dq_inc)
    ,.phy_dq_rst(phy_dq_rst)
    ,.phy_rdlat(phy_rdlat)
    ,.phy_rdsel(phy_rdsel)

    ,.ddr3_addr(ddr3_addr)
    ,.ddr3_ba(ddr3_ba)
    ,.ddr3_ras_n(ddr3_ras_n)
    ,.ddr3_cas_n(ddr3_cas_n)
    ,.ddr3_we_n(ddr3_we_n)
    ,.ddr3_cs_n(ddr3_cs_n)
    ,.ddr3_cke(ddr3_cke)
    ,.ddr3_odt(ddr3_odt)
    ,.ddr3_reset_n(ddr3_reset_n)
    ,.ddr3_ck_p(ddr3_ck_p)
    ,.ddr3_ck_n(ddr3_ck_n)
    ,.ddr3_dm(ddr3_dm)
    ,.ddr3_dq(ddr3_dq)
    ,.ddr3_dqs_p(ddr3_dqs_p)
    ,.ddr3_dqs_n(ddr3_dqs_n)
);

//-----------------------------------------------------------------
// Micron DDR3 model
//-----------------------------------------------------------------
ddr3 u_ram
(
     .rst_n(ddr3_reset_n)
    ,.ck(ddr3_ck_p)
    ,.ck_n(ddr3_ck_n)
    ,.cke(ddr3_cke)
    ,.cs_n(ddr3_cs_n)
    ,.ras_n(ddr3_ras_n)
    ,.cas_n(ddr3_cas_n)
    ,.we_n(ddr3_we_n)
    ,.dm_tdqs(ddr3_dm)
    ,.ba(ddr3_ba)
    ,.addr(ddr3_addr)
    ,.dq(ddr3_dq)
    ,.dqs(ddr3_dqs_p)
    ,.dqs_n(ddr3_dqs_n)
    ,.tdqs_n()
    ,.odt(ddr3_odt)
);

// Silence the model's per-command / per-column INFO stream; the bench checks
// the data, not the transcript.  Errors and warnings are still printed.
defparam u_ram.DEBUG = 0;

//-----------------------------------------------------------------
// Helpers
//-----------------------------------------------------------------
// All stimulus uses non-blocking assignment and all DUT outputs are read in
// the active region straight after @(posedge clk100), i.e. sampled AS OF the
// clock edge - the same discipline as the vendored testbench and as any
// synchronous requester.  Sampling after a #delay instead would read the value
// for the *next* cycle and drop the request one cycle too early.
task run_bist(input [2:0] pat, input [4:0] rng, input mode);
begin
    bist_pattern    <= pat;
    bist_range_log2 <= rng;
    bist_mode       <= mode;
    @(posedge clk100);
    bist_start      <= 1'b1;
    @(posedge clk100);
    @(posedge clk100);
    bist_start      <= 1'b0;
    while (!bist_busy) @(posedge clk100);
    while (bist_busy)  @(posedge clk100);
    @(posedge clk100);
end
endtask

// req_valid is held until req_accept (valid/ready), then dropped; resp_valid is
// awaited for writes as well as reads.  Exactly one request in flight.
task ext_write(input [31:0] a, input [127:0] d);
begin
    req_valid <= 1'b1;
    req_wr    <= 16'hFFFF;
    req_addr  <= a;
    req_wdata <= d;
    @(posedge clk100);
    while (!req_accept) @(posedge clk100);
    req_valid <= 1'b0;
    req_wr    <= 16'h0000;
    while (!resp_valid) @(posedge clk100);   // write ack: command issued
end
endtask

task ext_read(input [31:0] a, output [127:0] d);
begin
    req_valid <= 1'b1;
    req_wr    <= 16'h0000;
    req_addr  <= a;
    @(posedge clk100);
    while (!req_accept) @(posedge clk100);
    req_valid <= 1'b0;
    while (!resp_valid) @(posedge clk100);
    d = resp_rdata;
end
endtask

//-----------------------------------------------------------------
// Stimulus
//-----------------------------------------------------------------
integer      i;
integer      timeout;
reg  [  3:0] patnum;
integer      exp_line;
reg [127:0]  rd;
reg [127:0]  exp;
reg          ok;

localparam [4:0] RANGE_LOG2 = 5'd12;               // 4096 bytes
localparam       LINES      = (1 << RANGE_LOG2) / 16;

initial
begin
    $display("=== DDR3 ISLAND TB start ===");

    // ---- 1. PLL lock -------------------------------------------------
    timeout = 0;
    while ((pll_locked !== 1'b1) && (timeout < 100000)) begin #100; timeout = timeout + 1; end
    check("PLL locks", pll_locked === 1'b1);

    // ---- 2. Controller init ------------------------------------------
    timeout = 0;
    while ((init_done !== 1'b1) && (timeout < 100000)) begin #100; timeout = timeout + 1; end
    check("controller init_done", init_done === 1'b1);
    $display("INFO: init_done at %0t", $time);

    if (init_done !== 1'b1)
    begin
        $display("DDR3 ISLAND TB: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $fatal(1, "init never completed");
    end

    // ---- 3..7. BIST patterns 0..4 ------------------------------------
    for (i = 0; i <= 4; i = i + 1)
    begin
        run_bist(i[2:0], RANGE_LOG2, 1'b0);
        ok = (bist_err_count == 32'd0) &&
             (bist_done === 1'b1) &&
             (bist_lines_done == ((i == 4) ? (2*LINES) : LINES));
        patnum   = i[3:0];
        exp_line = (i == 4) ? (2*LINES) : LINES;
        $display("INFO: pattern %0d: errors=%0d lines=%0d (expected %0d) first_err_addr=%08x xor=%08x at %0t",
                 patnum, bist_err_count, bist_lines_done, exp_line,
                 bist_first_err_addr, bist_first_err_xor, $time);
        case (i)
        0: check("BIST pattern 0 (address-as-data) clean", ok);
        1: check("BIST pattern 1 (5555/AAAA) clean",       ok);
        2: check("BIST pattern 2 (walking ones) clean",    ok);
        3: check("BIST pattern 3 (LFSR-32) clean",         ok);
        4: check("BIST pattern 4 (zeros then ones) clean", ok);
        endcase
    end

    // ---- 8. Fault injection ------------------------------------------
    // Leave the memory holding pattern 1 over one line, then verify-only with
    // DQ[0] stuck low.  Line 0 of pattern 1 is 0x5555 repeated, so bit 0 of
    // every 16-bit word is a one: the stuck bit must show as a single failing
    // line at address 0 with XOR 0x00010001 in the low 32 bits.
    run_bist(3'd1, 5'd4, 1'b0);          // write + verify one line, must be clean
    check("fault injection: pre-check clean", bist_err_count == 32'd0);

    force ddr3_dq[0] = 1'b0;
    run_bist(3'd1, 5'd4, 1'b1);          // verify only, one line
    release ddr3_dq[0];
    $display("INFO: injected fault: errors=%0d addr=%08x xor=%08x lines=%0d",
             bist_err_count, bist_first_err_addr, bist_first_err_xor, bist_lines_done);
    check("fault injection: exactly one error",  bist_err_count == 32'd1);
    check("fault injection: address is 0",       bist_first_err_addr == 32'h0000_0000);
    check("fault injection: XOR is 0x00010001",  bist_first_err_xor == 32'h0001_0001);

    // ---- 9. External request port ------------------------------------
    for (i = 0; i < 4; i = i + 1)
        ext_write(32'h0000_1000 + (i * 16),
                  {32'hCAFE0000 + i, 32'hBEEF0000 + i, 32'h5A5A0000 + i, 32'hA5A50000 + i});

    ok = 1'b1;
    for (i = 0; i < 4; i = i + 1)
    begin
        exp = {32'hCAFE0000 + i, 32'hBEEF0000 + i, 32'h5A5A0000 + i, 32'hA5A50000 + i};
        ext_read(32'h0000_1000 + (i * 16), rd);
        if (rd !== exp)
        begin
            ok = 1'b0;
            $display("INFO: external port mismatch at %08x: got %032x expected %032x",
                     32'h0000_1000 + (i * 16), rd, exp);
        end
    end
    check("external port: 4 writes then 4 reads compare", ok);
    check("external port: BIST idle throughout", bist_busy === 1'b0);

    // ---- Summary -----------------------------------------------------
    #1000;
    $display("DDR3 ISLAND TB: %0d passed, %0d failed", pass_cnt, fail_cnt);
    $finish;
end

// Global watchdog
initial
begin
    #3_000_000;   // 3 ms
    $display("DDR3 ISLAND TB: %0d passed, %0d failed", pass_cnt, fail_cnt + 1);
    $fatal(1, "TIMEOUT");
end

endmodule
