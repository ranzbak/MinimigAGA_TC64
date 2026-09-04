// SDRAM read/write timing testbench
//
// Purpose: find out on which clk_114 edge SDRAM read data actually lands at
// sdata_reg, and how much setup/hold margin that edge has, using the vendor
// model with real tAC/tOH plus the FPGA/board delays from the Vivado routed
// timing report (findings/constraints/vivado-reports/32_sdram_in_AFTER.rpt).
//
// The internal flop clock (clk) is the reference: DUT registers clock on its
// rising edge.  Everything else is a delay relative to that edge:
//   DLY_CLK_PIN  dr_clk arrival at the SDRAM pin  = PHASE + clock-out path - clock insertion
//   T_CO         DUT register -> pin (clk-to-Q + OBUF), minus the #1 ns the RTL adds itself
//   T_IN         pin -> sdata_reg/D (IBUF + route)
//
// Corners:  default = slow (Vivado max numbers), -DFAST = estimated fast corner.
// Speed grade of the model: -Dsg7 (tAC3 5.4 ns) or leave default sg6 (5.0 ns).

`timescale 1ps / 1ps
`define SOC_SIM

module sdram_timing_tb;

`ifdef FAST
  localparam integer DLY_CLK_PIN = 6999;   // -2975 + 3619 - 2460 = -1816; +1 period (periodic clock, same edge set)
  localparam integer T_CO        = 200;    // 1200 - 1000 (RTL #1)
  localparam integer T_IN        = 493;    // IBUF only: capture flop is in the IOB (Vivado min)
  localparam         CORNER      = "FAST";
`else
  localparam integer DLY_CLK_PIN = 1410;   // -2975 + 9679 - 5295 (Vivado max: SCD - DCD of the routed design)
  localparam integer T_CO        = 840;    // 1840 - 1000 (RTL #1)
  localparam integer T_IN        = 1512;   // IBUF only: capture flop is in the IOB (Vivado max)
  localparam         CORNER      = "SLOW";
`endif
localparam integer T        = 8815;        // clk_114 period, ps
localparam integer T_ALT    = 551;         // dedicated capture clock clk_sd_rd, +22.5 deg
localparam integer T_NEG    = T/2;         // negedge capture experiment
localparam integer TSU_FF   = 100;         // rough FDRE setup at the D pin
localparam integer TH_FF    = 200;         // rough FDRE hold

// ---------------------------------------------------------------- clocks
reg clk = 1'b0;
always begin #4407 clk = 1'b1; #4408 clk = 1'b0; end

reg pin_clk = 1'b0;
always @(clk) pin_clk <= #DLY_CLK_PIN clk;

// SDRAM read capture clock: clk_114 + 144 deg (MMCM CLKOUT3), see fix-12
localparam integer T_RDCLK = 551;
reg rdclk = 1'b0;
always @(clk) rdclk <= #T_RDCLK clk;

reg [3:0] c16 = 4'd0;
always @(posedge clk) c16 <= c16 + 4'd1;
wire clk7_en = (c16 < 4'd4);               // one 28 MHz cycle high, every 16 clk_114

// ---------------------------------------------------------------- DUT wires
reg          reset_in = 1'b0;
wire [12:0]  sdaddr;
wire [3:0]   sd_cs;
wire [1:0]   ba;
wire         sd_we, sd_ras, sd_cas;
wire [1:0]   dqm;
wire [15:0]  sdata_fpga;                   // the DUT's inout, FPGA side
wire         reset_out;

reg  [23:1]  chipAddr = 23'd0;
reg          chipL = 1'b1, chipU = 1'b1, chipL2 = 1'b1, chipU2 = 1'b1;
reg          chipRW = 1'b1, chip_dma = 1'b1;
reg  [15:0]  chipWR = 16'd0, chipWR2 = 16'd0;
wire [15:0]  chipRD;
wire [47:0]  chip48;
reg  [31:0]  hostWR = 32'd0; reg [21:0] hostAddr = 22'd0; reg hostce = 1'b0, hostwe = 1'b0; reg [3:0] hostbytesel = 4'b0000;
wire [15:0]  hostRD; wire hostena;
reg  [25:1]  cpuAddr = 25'd0;
reg  [6:0]   cpustate = 7'b0000100;   // bit2 = ramcs (1 = not selected), [1:0] = state
wire [15:0]  cpuRD;
wire         cpuena;

sdram_ctrl dut (
  .sysclk(clk), .rdclk(rdclk), .clk7_en(clk7_en), .reset_in(reset_in), .cache_rst(reset_in),
  .cache_inhibit(1'b0), .cacheline_clr(1'b0), .cpu_cache_ctrl(4'b0011), .reset_out(reset_out),
  .sdaddr(sdaddr), .sd_cs(sd_cs), .ba(ba), .sd_we(sd_we), .sd_ras(sd_ras), .sd_cas(sd_cas),
  .dqm(dqm), .sdata(sdata_fpga),
  .hostWR(hostWR), .hostAddr(hostAddr), .hostce(hostce), .hostwe(hostwe), .hostbytesel(hostbytesel), .hostRD(hostRD), .hostena(hostena),
  .chipAddr(chipAddr), .chipL(chipL), .chipU(chipU), .chipL2(chipL2), .chipU2(chipU2),
  .chipRW(chipRW), .chip_dma(chip_dma), .chipWR(chipWR), .chipWR2(chipWR2), .chipRD(chipRD), .chip48(chip48),
  .rtgAddr(26'd0), .rtgce(1'b0), .rtgfill(), .rtgRd(),
  .audAddr(23'd0), .audce(1'b0), .audfill(), .audRd(),
  .cpuAddr(cpuAddr), .cpustate(cpustate), .cpuL(1'b0), .cpuU(1'b0), .cpuWR(16'd0), .cpuRD(cpuRD),
  .enaWRreg(), .ena7RDreg(), .ena7WRreg(), .cpuena(cpuena)
);

// ---------------------------------------------------------------- board / IOB delay model
wire [12:0] pin_addr;  assign #T_CO pin_addr = sdaddr;
wire [1:0]  pin_ba;    assign #T_CO pin_ba   = ba;
wire        pin_cs;    assign #T_CO pin_cs   = sd_cs[0];
wire        pin_ras;   assign #T_CO pin_ras  = sd_ras;
wire        pin_cas;   assign #T_CO pin_cas  = sd_cas;
wire        pin_we;    assign #T_CO pin_we   = sd_we;
wire [1:0]  pin_dqm;   assign #T_CO pin_dqm  = dqm;

wire        oe = dut.sdata_oe;
reg         oe_d = 1'b0;      always @(oe)            oe_d     <= #T_CO oe;
reg  [15:0] dq_out_d;         always @(dut.sdata_out) dq_out_d <= #T_CO dut.sdata_out;
wire [15:0] dq_pin = oe_d ? dq_out_d : 16'bz;                     // at the SDRAM pins
reg  [15:0] dq_in_d = 16'bz;  always @(dq_pin)        dq_in_d  <= #T_IN dq_pin;   // at sdata_reg/D
assign sdata_fpga = oe ? 16'bz : dq_in_d;                          // tb drives when DUT does not

// ---------------------------------------------------------------- SDRAM model
sdr16mx16 sdram (
  .Dq(dq_pin), .Addr(pin_addr), .Ba(pin_ba), .Clk(pin_clk), .Cke(1'b1),
  .Cs_n(pin_cs), .Ras_n(pin_ras), .Cas_n(pin_cas), .We_n(pin_we),
  .LDQM(pin_dqm[0]), .UDQM(pin_dqm[1])
);

// ---------------------------------------------------------------- change log of the data at sdata_reg/D
integer  n_chg = 0;
time     t_chg [0:4095];
reg [15:0] v_chg [0:4095];
always @(dq_in_d) begin
  if (n_chg < 4096) begin t_chg[n_chg] = $time; v_chg[n_chg] = dq_in_d; n_chg = n_chg + 1; end
end

// setup/hold margin of the data at sample time ts (ps), relative to the change log
task margins(input time ts, output integer su, output integer hd, output reg [15:0] val);
  integer i; time tp, tn;
  begin
    tp = 0; tn = 0; val = 16'bx;
    for (i = 0; i < n_chg; i = i + 1) begin
      if (t_chg[i] <= ts) begin tp = t_chg[i]; val = v_chg[i]; end
      else if (tn == 0)   begin tn = t_chg[i]; end
    end
    su = ts - tp;
    hd = (tn == 0) ? 999999 : tn - ts;
  end
endtask

function [31:0] verdict(input integer su, input integer hd, input [15:0] v);
  begin
    if (v === 16'bx || v === 16'bz) verdict = "Z/X ";
    else if (su < TSU_FF)           verdict = "SU! ";
    else if (hd < TH_FF)            verdict = "HD! ";
    else                            verdict = "ok  ";
  end
endfunction

// ---------------------------------------------------------------- sample log during a chip read
integer  n_smp = 0;
time     t_smp [0:63];
reg [3:0] s_smp [0:63];
reg [15:0] r_smp [0:63];      // sdata_reg AFTER this edge (what the RTL will use next cycle)
reg      logging = 1'b0;
always @(posedge clk) if (logging && n_smp < 64) begin
  t_smp[n_smp] = $time; s_smp[n_smp] = dut.sdram_state;
  #1500 r_smp[n_smp] = dut.sdata_reg;          // after the RTL's #1 ns
  n_smp = n_smp + 1;
end

// ---------------------------------------------------------------- stimulus
localparam [3:0] PH0=0, PH1=1, PH2=2, PH9=9, PH12=12, PH13=13, PH15=15;

task wait_state(input [3:0] s);
  begin @(posedge clk); while (dut.sdram_state !== s) @(posedge clk); end
endtask

task chip_write(input [23:1] a, input [15:0] w0, input [15:0] w1);
  begin
    wait_state(PH15);
    chipAddr = a; chipWR = w0; chipWR2 = w1; chipRW = 1'b0; chip_dma = 1'b1;
    chipL = 1'b0; chipU = 1'b0; chipL2 = 1'b0; chipU2 = 1'b0;
    wait_state(PH2);
    chipRW = 1'b1;                                // slot latched; data inputs stay valid until ph10
    wait_state(PH12);
  end
endtask

task chip_read(input [23:1] a);
  begin
    wait_state(PH15);
    chipAddr = a; chipRW = 1'b1; chip_dma = 1'b0; chipL = 1'b0; chipU = 1'b0;
    n_smp = 0; logging = 1'b1;
    wait_state(PH2);
    chip_dma = 1'b1;
    wait_state(PH15);
    @(posedge clk); logging = 1'b0;
  end
endtask

// CPU port: instruction read of one word, wait for cpuena (level, like the TG68K wrapper does)
task cpu_read(input [25:1] a, output [15:0] d, output integer cyc);
  begin
    @(posedge clk); cpuAddr = a;                 // address one cycle before select (cpuAddr_r)
    @(posedge clk); cpustate = 7'b0000000;       // ramcs = 0, state 00 = instruction read
    cyc = 0;
    @(posedge clk); while (cpuena !== 1'b1 && cyc < 400) begin @(posedge clk); cyc = cyc + 1; end
    d = cpuRD;
    @(posedge clk); cpustate = 7'b0000100;
    repeat (3) @(posedge clk);
  end
endtask

// HOST port, hostcache protocol: hold req until ack, then drop it; read takes [31:16] at the ack cycle, [15:0] next.
task host_write(input [21:0] a, input [31:0] d);
  integer c;
  begin
    @(posedge clk); hostAddr = a; hostWR = d; hostbytesel = 4'b1111; hostwe = 1'b1; hostce = 1'b1;
    c = 0; @(posedge clk); while (hostena !== 1'b1 && c < 400) begin @(posedge clk); c = c + 1; end
    hostce = 1'b0; hostwe = 1'b0;
    while (hostena === 1'b1) @(posedge clk);
    repeat (3) @(posedge clk);
  end
endtask
task host_read(input [21:0] a, output [31:0] d, output integer cyc);
  begin
    @(posedge clk); hostAddr = a; hostwe = 1'b0; hostce = 1'b1;
    cyc = 0; @(posedge clk); while (hostena !== 1'b1 && cyc < 400) begin @(posedge clk); cyc = cyc + 1; end
    d[31:16] = hostRD; hostce = 1'b0;
    @(posedge clk); d[15:0] = hostRD;
    while (hostena === 1'b1) @(posedge clk);
    repeat (3) @(posedge clk);
  end
endtask
reg [31:0] hrd; integer hcyc, host_bad;

reg [15:0] pat [0:15];
reg [15:0] cd; integer cyc, cpu_bad, pass;
integer k, su, hd, su2, hd2, su3, hd3, first_ok, first_ok2, first_ok3;
reg [15:0] v, v2, v3;
reg [31:0] vd, vd2, vd3;

initial begin
  $timeformat(-9, 3, " ns", 10);
  for (k = 0; k < 16; k = k + 1) pat[k] = 16'hA000 + k * 16'h0111;

  repeat (20) @(posedge clk);
  reset_in = 1'b1;
  @(posedge reset_out);
  $display("[%s] init done at %t (sg7? %0d)", CORNER, $time, `ifdef sg7 1 `else 0 `endif);
  repeat (64) @(posedge clk);

  // write 8 words at an 8-aligned column, bank 0, row 0x123
  for (k = 0; k < 16; k = k + 2) chip_write(23'h123 << 9 | (23'h40 + k), pat[k], pat[k+1]);
  repeat (32) @(posedge clk);

  // read the burst back
  chip_read(23'h123 << 9 | 23'h40);
  repeat (4) @(posedge clk);

  $display("");
  $display("[%s] dr_clk at pin: +%0d ps after the internal edge; T_CO %0d ps; T_IN %0d ps; tAC3 %0d ps; tOH %0d ps",
           CORNER, DLY_CLK_PIN, T_CO, T_IN, sdram.tAC3, sdram.tOH);
  $display("[%s] chipRD = %h (expect %h)   chip48 = %h %h %h (expect %h %h %h)   %s",
           CORNER, chipRD, pat[0], chip48[47:32], chip48[31:16], chip48[15:0], pat[1], pat[2], pat[3],
           (chipRD === pat[0] && chip48 === {pat[1], pat[2], pat[3]}) ? "READ OK" : "READ WRONG");
  $display("");
  $display("           |  posedge clk_114 (as built)   |  +%0d ps (proposed clk)      |  negedge (+%0d ps)", T_ALT, T_NEG);
  $display("  ph  time |  D value  setup  hold  verdict |  D value  setup  hold  verdict |  D value  setup  hold  verdict | sdata_reg after");
  first_ok = -1; first_ok2 = -1; first_ok3 = -1;
  for (k = 0; k < n_smp; k = k + 1) begin
    margins(t_smp[k],         su,  hd,  v);   vd  = verdict(su,  hd,  v);
    margins(t_smp[k] + T_ALT, su2, hd2, v2);  vd2 = verdict(su2, hd2, v2);
    margins(t_smp[k] + T_NEG, su3, hd3, v3);  vd3 = verdict(su3, hd3, v3);
    $display("  %2d %5.1f |  %h  %6.2f %6.2f  %s   |  %h  %6.2f %6.2f  %s   |  %h  %6.2f %6.2f  %s   | %h",
             s_smp[k], t_smp[k]/1000.0,
             v,  su/1000.0,  (hd  > 99999 ? 99.0 : hd/1000.0),  vd,
             v2, su2/1000.0, (hd2 > 99999 ? 99.0 : hd2/1000.0), vd2,
             v3, su3/1000.0, (hd3 > 99999 ? 99.0 : hd3/1000.0), vd3,
             r_smp[k]);
    if (first_ok  < 0 && v  === pat[0] && vd  == "ok  ") first_ok  = s_smp[k];
    if (first_ok2 < 0 && v2 === pat[0] && vd2 == "ok  ") first_ok2 = s_smp[k];
    if (first_ok3 < 0 && v3 === pat[0] && vd3 == "ok  ") first_ok3 = s_smp[k];
  end
  $display("");
  // ---- CPU port: two lines through the cache. pass 0 = fills, pass 1 = hits, pass 2 = re-fill after a flush
  cpu_bad = 0;
  for (pass = 0; pass < 3; pass = pass + 1) begin
    if (pass == 2) begin
      // evict: read two other lines so both cached lines are replaced
      for (k = 0; k < 16; k = k + 8) cpu_read({2'b00, 23'h123 << 9 | (23'h100 + k)}, cd, cyc);
    end
    for (k = 0; k < 16; k = k + 1) begin
      cpu_read({2'b00, 23'h123 << 9 | (23'h40 + k)}, cd, cyc);
      if (cd !== pat[k] || cyc >= 400) begin
        cpu_bad = cpu_bad + 1;
        $display("[%s] CPU read pass %0d word %2d: got %h expect %h (%0d cycles)  <-- WRONG", CORNER, pass, k, cd, pat[k], cyc);
      end
    end
  end
  // ---- HOST port: 4 longword writes then reads back (two cache lines), then the same again
  host_bad = 0;
  for (k = 0; k < 8; k = k + 1) host_write(22'h001000 + k, 32'h5A000000 + k * 32'h01010101);
  for (pass = 0; pass < 2; pass = pass + 1)
    for (k = 0; k < 8; k = k + 1) begin
      host_read(22'h001000 + k, hrd, hcyc);
      if (hrd !== 32'h5A000000 + k * 32'h01010101 || hcyc >= 400) begin
        host_bad = host_bad + 1;
        $display("[%s] HOST read pass %0d word %0d: got %h expect %h (%0d cycles)  <-- WRONG", CORNER, pass, k, hrd, 32'h5A000000 + k * 32'h01010101, hcyc);
      end
    end
  $display("[%s] HOST port: 8 longword writes, 16 reads, %0d wrong   %s", CORNER, host_bad, host_bad == 0 ? "HOST OK" : "HOST WRONG");
  $display("[%s] CPU port: 48 reads (fill / hit / re-fill), %0d wrong   %s", CORNER, cpu_bad, cpu_bad == 0 ? "CPU READ OK" : "CPU READ WRONG");
  $display("");
  $display("[%s] word0 first captured cleanly at:  posedge -> ph%0d   +%0d ps -> ph%0d   negedge -> ph%0d   (RTL comment table expects ph9, i.e. edge at end of ph8)",
           CORNER, first_ok, T_ALT, first_ok2, first_ok3);
  $finish;
end

endmodule
