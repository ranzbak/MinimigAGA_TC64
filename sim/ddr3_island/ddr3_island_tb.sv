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
// DQ / DQS SKEW MODEL (added for the read-path rework)
// ----------------------------------------------------
// The model's DQ and DQS outputs reach the FPGA through a TRANSPORT delay of
// DQS_SKEW_PS picoseconds (parameter, overridable with +SKEW_PS=<ps>).  It
// stands in for tDQSCK with the DRAM DLL disabled (the datasheet allows
// 1 ns .. 10 ns) plus board flight time.  Only the memory -> FPGA direction is
// delayed; writes reach the model undelayed so its own write timing checks
// still see a clean bus.  The direction is taken from the PHY's own DQ/DQS
// tristate control.
//
// Because the read path no longer captures with DQS (see ddr3_dfi_phy.v), the
// skew is what moves the passing RDSEL window: the bench is meant to be run at
// several values (1000 / 4000 / 8000 ps) and the module defaults chosen so that
// all of them pass.
//
// Tests
//   1  PLL locks
//   2  controller init completes
//   3  module reset defaults (no cfg write at all) are exercised and reported
//   4  alignment sweep: rdlat 3..7 x rdsel 0..15, BIST pattern 3 over 4 KB,
//      printed as GRID lines in the same format as tools/vivado/ddr3_bist.tcl;
//      some (rdlat,rdsel) must pass, and the module defaults must be within
//      one beat of a passing sample point (see SIM_RDSEL below for why it is
//      "within one beat" and not "equal")
//   5..9   BIST patterns 0..4 over 64 KB at the swept alignment, zero errors
//   10 fault injection: DQ[0] forced low for a read-only pass -> exactly one
//      error at the expected address with the expected XOR
//   11 external request port through the arbiter: 4 writes then 4 reads
//   12..15  the DM (data mask) modes, BIST patterns 5 and 6, over 4 KB:
//      masked write + verify, verify-only re-read, 16-bit word writes +
//      verify, verify-only re-read, then a negative control that forces
//      DM[0] low and checks that pattern 5 sees exactly the corruption that
//      causes.  These are the CPU-path proof: patterns 0..4 only ever write
//      whole lines with all 16 byte enables set, so before this the DDR3 DM
//      lanes were never exercised.
//
// Plusargs
//   +SKEW_PS=<n>     override DQS_SKEW_PS
//   +QUICK           skip the sweep and use 4 KB instead of 64 KB (smoke run)
//   +SWEEP_LOG2=<n>  BIST range for the sweep, log2 bytes (default 12 = 4 KB)
//   +SWEEPONLY       stop after the sweep (exploration run)
//   +MASKONLY        run ONLY the DM tests (12..15) over 4 KB and stop.  No
//                    80-point alignment grid, so it finishes in a couple of
//                    minutes; this is what produces xsim_run_masked.log.
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module ddr3_island_tb;

//-----------------------------------------------------------------
// Skew configuration
//-----------------------------------------------------------------
parameter integer DQS_SKEW_PS = 4000;

real    skew_ns = DQS_SKEW_PS / 1000.0;
integer skew_ps_arg;
integer quick = 0;
integer sweeponly = 0;
integer maskonly = 0;
integer sweep_log2 = 12;

initial
begin
    if ($value$plusargs("SKEW_PS=%d", skew_ps_arg))
        skew_ns = skew_ps_arg / 1000.0;
    if ($test$plusargs("QUICK"))
        quick = 1;
    if ($test$plusargs("SWEEPONLY"))
        sweeponly = 1;
    if ($test$plusargs("MASKONLY"))
        maskonly = 1;
    void'($value$plusargs("SWEEP_LOG2=%d", sweep_log2));
    $display("INFO: DQS_SKEW_PS = %0d ps, quick = %0d", $rtoi(skew_ns * 1000.0), quick);
end

// The module defaults, i.e. what the bitstream boots with.  These MUST match
// ddr3_dfi_phy's TPHY_RDLAT / RDSEL_INIT as instantiated by rtl/ddr3/ddr3_top.v.
// They are the values MEASURED ON THE BOARD, not the ones this bench prefers.
localparam [2:0] DEF_RDLAT = 3'd5;
localparam [3:0] DEF_RDSEL = 4'd11;

// The same physical sample point ONE BEAT (4 oversamples = 5 ns) later, which
// is where the Micron model puts the read data.  RDSEL 11 -> sel 7, RDSEL 15 ->
// sel 11.  The bench uses this for its own data-integrity runs; the difference
// between the two is the model's unrepresentative DLL-off strobe timing, see
// findings/ddr3/bringup.md, "Read-path rework".
localparam [2:0] SIM_RDLAT = 3'd5;
localparam [3:0] SIM_RDSEL = 4'd15;

// How far the module defaults may sit from the passing window in simulation
// and still be accepted: one beat, in oversamples.
localparam integer SIM_HW_TOL = 4;

// The skew the defaults are chosen for.  tDQSCK with the DDR3 DLL disabled is
// specified as 1 ns .. 10 ns, so 4 ns is the middle of the range the bench
// runs (1000 / 4000 / 8000 ps).
localparam integer NOM_SKEW_PS = 4000;

// sel() of an RDSEL code, exactly as the PHY computes it:
//   sel = RDSEL[2:0] + (RDSEL[3] ? 4 : 0)
function integer rdsel_to_sel(input integer rs);
begin
    rdsel_to_sel = (rs % 8) + ((rs >= 8) ? 4 : 0);
end
endfunction

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
reg  [  2:0] phy_rdlat     = DEF_RDLAT;
reg  [  3:0] phy_rdsel     = DEF_RDSEL;

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

// FPGA-side data nets (at the DUT pins)
wire [ 15:0] ddr3_dq;
wire [  1:0] ddr3_dqs_p;
wire [  1:0] ddr3_dqs_n;

// Memory-side data nets (at the DRAM pins)
wire [ 15:0] mem_dq;
wire [  1:0] mem_dqs_p;
wire [  1:0] mem_dqs_n;
wire [  1:0] mem_dm;

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
// DQ / DQS / DM flight model
//
// The DUT and the DRAM model no longer share a net.  Each direction is a
// separate driver, resolved in ONE always block per direction and scheduled
// with a transport delay:
//
//   memory -> FPGA   delayed by skew_ns   (the tDQSCK + flight time modelled
//                                          here; this is what moves RDSEL)
//   FPGA -> memory   delayed by WR_FLIGHT (10 ps, DQ, DQS and DM together)
//
// Two things matter and both were got wrong first time round:
//
//  * `always @(net) reg <= #d net;` is a TRANSPORT delay - every event is
//    scheduled separately.  `assign #d` is INERTIAL and silently swallows the
//    5 ns beats at an 8 ns skew.
//  * the direction gate and the data must be sampled TOGETHER, inside the
//    always block, and the ternary result scheduled.  Writing it as
//    `assign mem_dq = drv ? ddr3_dq : 16'bz;` looks equivalent but is not: the
//    tristate control and the data both come out of the same OSERDESE2 and
//    change in the same delta, so the continuous assignment evaluates
//    transiently with one operand old.  Those zero-width glitches land on DQS
//    edges and the model latches them, which shows up as WRITES THAT
//    INTERMITTENTLY DO NOT STICK - a very confusing failure, because reads and
//    the read alignment look perfect while later patterns read back whatever
//    the previous pattern left behind.
//
// The FPGA->memory delay must stay small: the DRAM only allows tDQSS of about
// +/- 0.25 tCK (2.5 ns here) between CK and the write strobe, so the write
// bus cannot be given the same flight time as the read bus without the model
// (rightly) complaining.  Only the read direction carries the big skew, which
// is what this bench is about.
//-----------------------------------------------------------------
localparam real WR_FLIGHT_NS = 0.010;

wire fpga_drv_dq  = (u_dut.u_phy.dq_out_en_n_w[0]  === 1'b0);
wire fpga_drv_dqs = (u_dut.u_phy.dqs_out_en_n_w[0] === 1'b0);

// FPGA -> memory
reg [15:0] mem_dq_drv    = 16'bz;
reg [ 1:0] mem_dqs_p_drv =  2'bz;
reg [ 1:0] mem_dqs_n_drv =  2'bz;
reg [ 1:0] mem_dm_drv    =  2'b0;

always @(ddr3_dq    or fpga_drv_dq)  mem_dq_drv    <= #(WR_FLIGHT_NS) (fpga_drv_dq  ? ddr3_dq    : 16'bz);
always @(ddr3_dqs_p or fpga_drv_dqs) mem_dqs_p_drv <= #(WR_FLIGHT_NS) (fpga_drv_dqs ? ddr3_dqs_p :  2'bz);
always @(ddr3_dqs_n or fpga_drv_dqs) mem_dqs_n_drv <= #(WR_FLIGHT_NS) (fpga_drv_dqs ? ddr3_dqs_n :  2'bz);
always @(ddr3_dm)                    mem_dm_drv    <= #(WR_FLIGHT_NS) ddr3_dm;

assign mem_dq    = mem_dq_drv;
assign mem_dqs_p = mem_dqs_p_drv;
assign mem_dqs_n = mem_dqs_n_drv;
assign mem_dm    = mem_dm_drv;      // dm_tdqs is an inout port, it needs a net

// memory -> FPGA, the modelled skew
reg [15:0] fpga_dq_drv    = 16'bz;
reg [ 1:0] fpga_dqs_p_drv =  2'bz;
reg [ 1:0] fpga_dqs_n_drv =  2'bz;

always @(mem_dq    or fpga_drv_dq)  fpga_dq_drv    <= #(skew_ns) (fpga_drv_dq  ? 16'bz : mem_dq);
always @(mem_dqs_p or fpga_drv_dqs) fpga_dqs_p_drv <= #(skew_ns) (fpga_drv_dqs ?  2'bz : mem_dqs_p);
always @(mem_dqs_n or fpga_drv_dqs) fpga_dqs_n_drv <= #(skew_ns) (fpga_drv_dqs ?  2'bz : mem_dqs_n);

assign ddr3_dq    = fpga_dq_drv;
assign ddr3_dqs_p = fpga_dqs_p_drv;
assign ddr3_dqs_n = fpga_dqs_n_drv;

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
    ,.dm_tdqs(mem_dm)
    ,.ba(ddr3_ba)
    ,.addr(ddr3_addr)
    ,.dq(mem_dq)
    ,.dqs(mem_dqs_p)
    ,.dqs_n(mem_dqs_n)
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

// Apply a read alignment exactly as tools/vivado/ddr3_bist.tcl does: zero the
// delay-line controls, set rdlat / rdsel, pulse cfg_valid.
task apply_align(input [2:0] rdlat_i, input [3:0] rdsel_i);
begin
    phy_dqs_inc   <= 2'b0;
    phy_dqs_rst   <= 2'b0;
    phy_dq_inc    <= 2'b0;
    phy_dq_rst    <= 2'b0;
    phy_rdlat     <= rdlat_i;
    phy_rdsel     <= rdsel_i;
    @(posedge clk100);
    phy_cfg_valid <= 1'b1;
    @(posedge clk100);
    @(posedge clk100);
    phy_cfg_valid <= 1'b0;
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

// ---- DM (byte enable) tests: BIST patterns 5 and 6 -------------------
// Run at the SIMULATION alignment, not the module defaults: the Micron model
// puts the read data one beat later than the real DLL-off part, see
// findings/ddr3/bringup.md, "Read-path rework".  SIM_RDLAT/SIM_RDSEL is the
// same physical sample point as the board's rdlat 5 / rdsel 11.
task dm_tests(input [4:0] rng);
    integer dm_lines;
begin
    dm_lines = (1 << rng) / 16;
    $display("INFO: DM tests at rdlat=%0d rdsel=%0d over 2^%0d bytes (%0d lines)",
             SIM_RDLAT, SIM_RDSEL, rng, dm_lines);
    apply_align(SIM_RDLAT, SIM_RDSEL);

    // 12. pattern 5: background, masked overwrite, verify.
    run_bist(3'd5, rng, 1'b0);
    $display("INFO: pattern 5 (masked): errors=%0d lines=%0d (expected %0d) first_err_addr=%08x xor=%08x at %0t",
             bist_err_count, bist_lines_done, dm_lines,
             bist_first_err_addr, bist_first_err_xor, $time);
    check("BIST pattern 5 (masked byte-enable write) clean",
          (bist_err_count == 32'd0) && (bist_done === 1'b1) &&
          (bist_lines_done == dm_lines));

    // 13. the same expectation re-read without rewriting: the masked write
    //     really reached the array, it was not a read-path artefact.
    run_bist(3'd5, rng, 1'b1);
    $display("INFO: pattern 5 verify-only: errors=%0d lines=%0d first_err_addr=%08x xor=%08x",
             bist_err_count, bist_lines_done, bist_first_err_addr, bist_first_err_xor);
    check("BIST pattern 5 verify-only (masked data retained) clean",
          (bist_err_count == 32'd0) && (bist_lines_done == dm_lines));

    // 14. pattern 6: background, then eight 16-bit word writes, verify.
    run_bist(3'd6, rng, 1'b0);
    $display("INFO: pattern 6 (wordwr): errors=%0d lines=%0d (expected %0d) first_err_addr=%08x xor=%08x at %0t",
             bist_err_count, bist_lines_done, dm_lines,
             bist_first_err_addr, bist_first_err_xor, $time);
    check("BIST pattern 6 (16-bit word writes) clean",
          (bist_err_count == 32'd0) && (bist_done === 1'b1) &&
          (bist_lines_done == dm_lines));

    run_bist(3'd6, rng, 1'b1);
    $display("INFO: pattern 6 verify-only: errors=%0d lines=%0d first_err_addr=%08x xor=%08x",
             bist_err_count, bist_lines_done, bist_first_err_addr, bist_first_err_xor);
    check("BIST pattern 6 verify-only (word-written data retained) clean",
          (bist_err_count == 32'd0) && (bist_lines_done == dm_lines));

    // 15. negative control.  One line at address 0: mask index c = 0, i.e.
    //     M = 0x0001, only byte 0 is overwritten with the foreground.  With
    //     DM[0] (which masks DQ[7:0], the LOW byte of every beat) forced low
    //     the DRAM writes the low byte of all eight beats, so bytes
    //     2,4,6,..,14 hold F where B was expected.  The low 32 bits of the
    //     XOR cover bytes 3..0, of which only byte 2 is wrong: 0x00FF0000.
    //     If this check fails the masked mode is not actually driving DM.
    force ddr3_dm[0] = 1'b0;
    run_bist(3'd5, 5'd4, 1'b0);
    release ddr3_dm[0];
    $display("INFO: DM[0] stuck-low control: errors=%0d addr=%08x xor=%08x lines=%0d",
             bist_err_count, bist_first_err_addr, bist_first_err_xor, bist_lines_done);
    check("DM negative control: pattern 5 flags the stuck DM lane",
          (bist_err_count == 32'd1) && (bist_first_err_addr == 32'h0000_0000) &&
          (bist_first_err_xor == 32'h00FF_0000));
end
endtask

//-----------------------------------------------------------------
// Stimulus
//-----------------------------------------------------------------
integer      i;
integer      rl;
integer      rs;
integer      timeout;
reg  [  3:0] patnum;
integer      exp_line;
reg [127:0]  rd;
reg [127:0]  exp;
reg          ok;
reg          def_ok;
integer      npass;
string       row;
string       win;
integer      pass_grid [3:7][0:15];
integer      best_rl;
integer      best_rs;
integer      best_run;
integer      run_len;
integer      k;
reg          is_nominal;
reg          near_ok;

reg [4:0]    sweep_log2_r;                          // 4096 bytes for the grid
integer      sweep_lines;

reg [4:0]    full_log2;
integer      full_lines;

initial
begin
    $display("=== DDR3 ISLAND TB start ===");

    full_log2    = $test$plusargs("QUICK") ? 5'd12 : 5'd16;   // 4 KB or 64 KB
    full_lines   = (1 << full_log2) / 16;
    sweep_log2_r = sweep_log2[4:0];
    sweep_lines  = (1 << sweep_log2_r) / 16;

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

    // ---- +MASKONLY: the DM modes only, no alignment grid ---------------
    if (maskonly)
    begin
        dm_tests(5'd12);                       // 4 KB = 256 lines
        #1000;
        $display("INFO: skew %0d ps, defaults rdlat=%0d rdsel=%0d",
                 $rtoi(skew_ns * 1000.0), DEF_RDLAT, DEF_RDSEL);
        $display("DDR3 ISLAND TB: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $finish;
    end

    // ---- 3. Module reset defaults, with no cfg write at all -----------
    // Nothing has pulsed phy_cfg_valid yet, so the PHY is running on its own
    // TPHY_RDLAT / RDSEL_INIT reset values.  This is the configuration the
    // bitstream comes up in.  It is only ASSERTED at the nominal skew: the
    // oversampled read window is one beat (4 samples = 5 ns) wide, so no
    // single RDSEL can cover the whole 1..10 ns tDQSCK(DLL off) range.  What
    // must hold at every skew is that SOME (rdlat,rdsel) in the grid passes -
    // that is what the hardware sweep looks for.
    is_nominal = ($rtoi(skew_ns * 1000.0) == NOM_SKEW_PS);

    run_bist(3'd3, sweep_log2_r, 1'b0);
    $display("INFO: reset defaults (rdlat=%0d rdsel=%0d) at %0d ps skew: errors=%0d lines=%0d",
             DEF_RDLAT, DEF_RDSEL, $rtoi(skew_ns * 1000.0), bist_err_count, bist_lines_done);
    // NOT asserted: the defaults are the board's numbers and this model wants
    // them one beat earlier.  Test 4 checks the distance instead.

    // ---- 4. Alignment sweep ------------------------------------------
    // Same shape as tools/vivado/ddr3_bist.tcl's `grid` mode: for each rdlat,
    // walk rdsel 0..15 and print the error count of one BIST run.
    def_ok   = 1'b0;
    npass    = 0;
    win      = "";
    best_rl  = DEF_RDLAT;
    best_rs  = DEF_RDSEL;
    best_run = 0;

    if (!quick)
    begin
        for (rl = 3; rl <= 7; rl = rl + 1)
        begin
            row = "";
            for (rs = 0; rs <= 15; rs = rs + 1)
            begin
                apply_align(rl[2:0], rs[3:0]);
                run_bist(3'd3, sweep_log2_r, 1'b0);
                row = {row, $sformatf(" %6d", bist_err_count)};
                pass_grid[rl][rs] = (bist_err_count == 32'd0);
                if (bist_err_count == 32'd0)
                begin
                    npass = npass + 1;
                    win   = {win, $sformatf(" (%0d,%0d)", rl, rs)};
                    if ((rl == DEF_RDLAT) && (rs == DEF_RDSEL)) def_ok = 1'b1;
                end
            end
            $display("%0s", $sformatf("GRID rdlat %0d : rdsel 0..15 errors:%0s", rl, row));
        end
        $display("INFO: passing (rdlat,rdsel), %0d of 80:%0s", npass, win);

        // Widest run of consecutive passing rdsel; its centre is the safest
        // alignment for this skew.  Only rdsel 0..7 are scanned because 8..15
        // are the same sample positions shifted by half a cycle (RDSEL bit 3),
        // so a run there is a duplicate of one here.
        for (rl = 3; rl <= 7; rl = rl + 1)
        begin
            run_len = 0;
            for (rs = 0; rs <= 7; rs = rs + 1)
            begin
                if (pass_grid[rl][rs]) run_len = run_len + 1;
                else                   run_len = 0;
                if (run_len > best_run)
                begin
                    best_run = run_len;
                    best_rl  = rl;
                    best_rs  = rs - (run_len - 1) + (run_len / 2);   // centre
                end
            end
        end
        $display("INFO: widest passing run at %0d ps skew: rdlat %0d rdsel %0d..%0d, centre rdsel %0d",
                 $rtoi(skew_ns * 1000.0), best_rl,
                 best_rs - (best_run / 2), best_rs - (best_run / 2) + best_run - 1, best_rs);

        check("alignment sweep: at least one passing (rdlat,rdsel)", npass > 0);

        // The module defaults are the board's measured alignment.  What the
        // model can honestly check is that they are no further than one beat
        // from a sample point that works here at the same rdlat - i.e. that
        // the PHY's sel arithmetic and the defaults are mutually consistent
        // and the disagreement is exactly the modelling error we expect.
        near_ok = 1'b0;
        for (rs = 0; rs <= 15; rs = rs + 1)
            if (pass_grid[DEF_RDLAT][rs])
            begin
                k = rdsel_to_sel(rs) - rdsel_to_sel(DEF_RDSEL);
                if (k < 0) k = -k;
                if (k <= SIM_HW_TOL) near_ok = 1'b1;
            end
        $display("INFO: module defaults (rdlat %0d rdsel %0d, sel %0d) %0s here; nearest passing sel at that rdlat is within %0d samples: %0s",
                 DEF_RDLAT, DEF_RDSEL, rdsel_to_sel(DEF_RDSEL),
                 def_ok ? "pass" : "do NOT pass", SIM_HW_TOL, near_ok ? "yes" : "no");
        if (is_nominal)
            check("module defaults are within one beat of a passing sample point",
                  near_ok);
    end
    else
        $display("INFO: +QUICK given, alignment sweep skipped");

    if (sweeponly)
    begin
        $display("INFO: skew %0d ps, defaults rdlat=%0d rdsel=%0d",
                 $rtoi(skew_ns * 1000.0), DEF_RDLAT, DEF_RDSEL);
        $display("DDR3 ISLAND TB: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $finish;
    end

    // ---- 5..9. BIST patterns 0..4 -------------------------------------
    // At the nominal skew this is the module default alignment; at the other
    // skews it is the centre of the window the sweep just found, which is what
    // the supervisor would program over JTAG after running `grid`.
    if (quick)
    begin
        $display("INFO: full run uses the SIM alignment rdlat=%0d rdsel=%0d (module defaults are rdlat=%0d rdsel=%0d)",
                 SIM_RDLAT, SIM_RDSEL, DEF_RDLAT, DEF_RDSEL);
        apply_align(SIM_RDLAT, SIM_RDSEL);
    end
    else
    begin
        $display("INFO: full run uses the SWEPT alignment rdlat=%0d rdsel=%0d", best_rl, best_rs);
        apply_align(best_rl[2:0], best_rs[3:0]);
    end

    for (i = 0; i <= 4; i = i + 1)
    begin
        run_bist(i[2:0], full_log2, 1'b0);
        ok = (bist_err_count == 32'd0) &&
             (bist_done === 1'b1) &&
             (bist_lines_done == ((i == 4) ? (2*full_lines) : full_lines));
        patnum   = i[3:0];
        exp_line = (i == 4) ? (2*full_lines) : full_lines;
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

    // ---- 10. Fault injection -----------------------------------------
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

    // ---- 11. External request port ------------------------------------
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

    // ---- 12..15. DM (byte enable) modes -------------------------------
    dm_tests(5'd12);                           // 4 KB = 256 lines

    // ---- Summary -----------------------------------------------------
    #1000;
    $display("INFO: skew %0d ps, defaults rdlat=%0d rdsel=%0d",
             $rtoi(skew_ns * 1000.0), DEF_RDLAT, DEF_RDSEL);
    $display("DDR3 ISLAND TB: %0d passed, %0d failed", pass_cnt, fail_cnt);
    $finish;
end

// Global watchdog
initial
begin
    #60_000_000;   // 60 ms
    $display("DDR3 ISLAND TB: %0d passed, %0d failed", pass_cnt, fail_cnt + 1);
    $fatal(1, "TIMEOUT");
end

endmodule
