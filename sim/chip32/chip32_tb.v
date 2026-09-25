// sim/chip32/chip32_tb.v -- a 32-bit CPU access to chip RAM through the real
// minimig bus path: minimig_m68k_bridge, gary, minimig_bankmapper,
// minimig_sram_bridge, and the real sdram_ctrl with the vendor SDRAM model.
//
// The question (findings/chip32/plan.md, Task 2): when the wrapper starts ONE
// chipset cycle with uds/lds/uds2/lds2 all low, does the minimig side move BOTH
// words in ONE chip slot -- word 2 of a read from chip48[47:32], word 2 of a
// write through chipWR2/chipU2/chipL2 -- with DMA taking slots around it, and
// without the held word 2 ever leaking into a DMA write or a CPU word write?
//
// Real: everything between the CPU bus pins and the SDRAM pins, wired as
// minimig.v and minimig_virtual_top.v wire it.  Left out, because none of them
// is in the chip-RAM path: Action Replay, Gayle, the CIAs, the custom registers.
// Modelled: the wrapper's chipset state machine (a transcription of the
// S_state process in rtl/soc/TG68K.vhd), the clock enables (a copy of
// rtl/clock/amiga_clk.v's), and Agnus (dbr/dbwe/address/data only).
//
// Usage: ./run.sh   -- pass build and two mutants, run in parallel
`timescale 1ps / 1ps
`define SOC_SIM

module chip32_tb;

// ---------------------------------------------------------------- clocks
// clk_114 and clk_28 come 4:1 off one MMCM, rising edges together.  Integer
// picoseconds so the two never drift; 8816 ps is the board's 113.4375 MHz.
localparam integer HALF114 = 4408;
reg clk114 = 1'b1;
reg clk28  = 1'b1;
always #(HALF114)   clk114 = ~clk114;
always #(4*HALF114) clk28  = ~clk28;

// SDRAM board delays, FAST corner, as sim/sdram_coherency/sdram_coherency_tb.v
localparam integer DLY_CLK_PIN = 6999;
localparam integer T_CO        = 200;
localparam integer T_IN        = 493;
reg pin_clk = 1'b0;
always @(clk114) pin_clk <= #DLY_CLK_PIN clk114;

// ---------------------------------------------------------------- clock enables
// rtl/clock/amiga_clk.v, "generated clocks", minus the PLL-locked reset.
reg [1:0] clk7_cnt   = 2'b10;
reg       clk7_en_r  = 1'b1;
reg       clk7n_en_r = 1'b1;
always @(posedge clk28) begin
  clk7_cnt   <= clk7_cnt + 2'b01;
  clk7_en_r  <= (clk7_cnt == 2'b00);
  clk7n_en_r <= (clk7_cnt == 2'b10);
end
wire clk7_en  = clk7_en_r;
wire clk7n_en = clk7n_en_r;
reg  c3 = 1'b0;  always @(posedge clk28) c3 <= clk7_cnt[1];
reg  c1 = 1'b0;  always @(posedge clk28) c1 <= ~c3;
reg  [3:0] e_cnt = 4'd0;
always @(posedge clk28)
  if (clk7_cnt == 2'b01) e_cnt <= (e_cnt[3] && e_cnt[0]) ? 4'd0 : e_cnt + 4'd1;
wire cck = ~e_cnt[0];
wire [9:0] eclk;
genvar gi;
generate for (gi = 0; gi < 10; gi = gi + 1) begin : g_eclk
  assign eclk[gi] = (e_cnt == gi);
end endgenerate

// ---------------------------------------------------------------- Agnus stand-in
// agnus.v's DMA engines qualify their requests with hpos[0], which is cck, so
// dbr is only ever high in the cck-high half.  dma_pat says which CCKs Agnus
// takes (bit i = the i-th CCK of a 16-CCK cycle); only the test sequence
// writes it.  DMA reads come from dma_adr; with dma_we set they are writes of
// dma_wd, which is how the Blitter and disk DMA write.
reg  [15:0] dma_pat  = 16'h0000;
reg  [3:0]  dma_i    = 4'd0;
reg         dma_busy = 1'b0;
reg         cck_d    = 1'b0;
reg  [20:1] dma_adr  = 20'h40000;        // $080000, a window nothing else uses
reg         dma_we   = 1'b0;
reg  [15:0] dma_wd   = 16'h0000;
always @(posedge clk28) begin
  cck_d <= cck;
  if (cck_d && !cck) begin               // start of the cck-low half
    dma_busy <= dma_pat[dma_i];
    dma_i    <= dma_i + 4'd1;
  end
end
wire        dbr     = cck & dma_busy;
wire        dbwe    = dbr & dma_we;
wire [15:0] dma_bus = dbr ? dma_wd : 16'h0000;   // gary's custom_data_out

// ---------------------------------------------------------------- the wrapper's chipset machine
// The S_state process of rtl/soc/TG68K.vhd, one request at a time from the
// sequence below: the strobes, address and data launched on ena7WRreg,
// dtack sampled on ena7RDreg in state 10, the data captured on ena7RDreg in
// state 11, and the release one ena7RDreg later (chipset_ready = ena7RDreg
// AND clkena_e).  The CPU's own 2-3 clk release delay is left out: the next
// cycle cannot start before the next ena7WRreg either way.
wire        ena7RD, ena7WR;              // sdram_ctrl's registered enables
wire [15:0] cpu_data, cpu_data2;         // the wrapper's data_read / data_read2
wire        dtack_n;
reg  [1:0]  S        = 2'b00;
reg         clkena_e = 1'b0;
reg         waitm    = 1'b1;
reg         as_n = 1'b1, rw = 1'b1, uds_n = 1'b1, lds_n = 1'b1, uds2_n = 1'b1, lds2_n = 1'b1;
reg  [23:0] adr = 24'd0;
reg  [15:0] dw = 16'd0, dw2 = 16'd0;     // data_write / data_write2 (held, as in the VHDL)
reg  [15:0] r_data = 16'd0, r_data2 = 16'd0;
reg         m_go = 1'b0, m_done = 1'b0, m_we = 1'b0, m_wide = 1'b0;
reg  [23:0] m_adr = 24'd0;
reg  [31:0] m_wd  = 32'd0;
always @(posedge clk114) begin
  if (!m_go) m_done <= 1'b0;
  if (ena7WR) begin
    case (S)
      2'b00: if (m_go && !m_done) begin
               as_n   <= 1'b0;
               rw     <= !m_we;
               uds_n  <= 1'b0;
               lds_n  <= 1'b0;
               uds2_n <= !m_wide;
               lds2_n <= !m_wide;
               dw     <= m_wd[31:16];
               if (m_wide) dw2 <= m_wd[15:0];
               adr    <= m_adr;
               S      <= 2'b01;
             end
      2'b01: begin clkena_e <= 1'b0; S <= 2'b10; end
      2'b10: if (!waitm) S <= 2'b11;
      default: ;
    endcase
  end else if (ena7RD) begin
    case (S)
      2'b10: waitm <= dtack_n;
      2'b11: begin
               as_n <= 1'b1; rw <= 1'b1;
               uds_n <= 1'b1; lds_n <= 1'b1; uds2_n <= 1'b1; lds2_n <= 1'b1;
               if (!clkena_e) begin r_data <= cpu_data; r_data2 <= cpu_data2; end
               clkena_e <= 1'b1;
             end
      default: ;
    endcase
  end
  // chipset_ready, last so it wins over state 11 (as in the VHDL)
  if (ena7RD && clkena_e) begin
    S <= 2'b00; clkena_e <= 1'b0; m_done <= 1'b1;
  end
end

// ---------------------------------------------------------------- DUT wiring
wire [23:1] cpu_address_out;
wire [15:0] cpu_data_out, gary_data_out;
wire        cpu_rd, cpu_hwr, cpu_lwr, cpu_hwr2, cpu_lwr2;
wire        dbs, xbs;
wire [23:1] ram_address_out;
wire [15:0] ram_data_in, ram_data_out;
wire        ram_rd, ram_hwr, ram_lwr, ram_hwr2, ram_lwr2;
wire [3:0]  sel_chip;
wire [2:0]  sel_slow;
wire        sel_kick, sel_kickext, sel_kick1mb, sel_cia;
wire [7:0]  bank;
wire        _ram_bhe, _ram_ble, _ram_bhe2, _ram_ble2, _ram_we, _ram_oe;
wire [22:1] ram_address;
wire [15:0] ram_data;
wire [15:0] chipRD;
wire [47:0] chip48;
reg         reset_in = 1'b0;
wire        reset_out;
reg  [3:0]  memcfg = 4'b0011;            // 2 MB chip, no slow RAM
reg         ovl = 1'b0;
reg         hlt = 1'b0;                  // gary's cpu_hlt: the ROM upload path

minimig_m68k_bridge CPU1 (
  .clk(clk28), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .blk(1'b0), .c1(c1), .c3(c3),
  .eclk(eclk), .vpa(sel_cia), .dbr(dbr), .dbs(dbs), .xbs(xbs), .nrdy(1'b0), .bls(),
  .cck(cck), .cpu_speed(1'b0), .memory_config(memcfg), .turbo(),
  ._as(as_n), ._lds(lds_n), ._uds(uds_n), ._lds2(lds2_n), ._uds2(uds2_n), .r_w(rw),
  ._dtack(dtack_n), .rd(cpu_rd), .hwr(cpu_hwr), .lwr(cpu_lwr), .hwr2(cpu_hwr2), .lwr2(cpu_lwr2),
  .address(adr[23:1]), .address_out(cpu_address_out),
  .data(cpu_data), .data2(cpu_data2), .cpudatain(dw), .data_out(cpu_data_out),
  .data_in(gary_data_out),               // minimig.v ORs in CIA/Gayle/cart/RTC/...: all zero here
`ifdef MUT_WORD2
  .data_in2(chip48[31:16]),              // MUTANT: the word after the right one
`else
  .data_in2(chip48[47:32]),              // minimig.v: cpu_data_in2 = chip48[47:32]
`endif
  ._cpu_reset(1'b1), .cpu_halt(1'b0), .host_cs(1'b0), .host_adr(23'd0), .host_we(1'b0),
  .host_bs(2'b00), .host_wdat(16'd0), .host_rdat(), .host_ack()
);

gary GARY1 (
  .clk(clk28), .cpu_address_in(cpu_address_out), .dma_address_in(dma_adr),
  .ram_address_out(ram_address_out), .cpu_data_out(cpu_data_out), .cpu_data_in(gary_data_out),
  .custom_data_out(dma_bus), .custom_data_in(), .ram_data_out(ram_data_out), .ram_data_in(ram_data_in),
  .a1k(1'b0), .cpu_rd(cpu_rd), .cpu_hwr(cpu_hwr), .cpu_lwr(cpu_lwr), .cpu_hwr2(cpu_hwr2), .cpu_lwr2(cpu_lwr2),
  .cpu_hlt(hlt), .ovl(ovl), .dbr(dbr), .dbwe(dbwe), .dbs(dbs), .xbs(xbs),
  .memory_config(memcfg), .ecs(1'b1), .hdc_ena(2'b00),
  .ram_rd(ram_rd), .ram_hwr(ram_hwr), .ram_lwr(ram_lwr), .ram_hwr2(ram_hwr2), .ram_lwr2(ram_lwr2),
  .sel_reg(), .sel_chip(sel_chip), .sel_slow(sel_slow), .sel_kick(sel_kick), .sel_kickext(sel_kickext),
  .sel_kick1mb(sel_kick1mb), .sel_cia(sel_cia), .sel_cia_a(), .sel_cia_b(), .sel_rtc(), .sel_toccata(),
  .sel_ide(), .sel_gayle(), .sel_autoconfig(),
  .autoconfig_done(1'b1), .autoconfig_shutup(5'd0), .autoconfig_configured(5'd0), .toccata_base_addr(8'd0)
);

minimig_bankmapper BMAP1 (
  .chip0(sel_chip[0]), .chip1(sel_chip[1]), .chip2(sel_chip[2]), .chip3(sel_chip[3]),  // ovr = 0: no cart
  .slow0(sel_slow[0]), .slow1(sel_slow[1]), .slow2(sel_slow[2]),
  .kick(sel_kick), .kickext(sel_kickext), .kick1mb(sel_kick1mb), .cart(1'b0),
  .ecs(1'b1), .memory_config(memcfg), .bank(bank)
);

minimig_sram_bridge RAM1 (
  .clk(clk28), .c1(c1), .c3(c3), .bank(bank), .address_in(ram_address_out),
  .data_in(ram_data_in), .data_out(ram_data_out), .rd(ram_rd), .hwr(ram_hwr), .lwr(ram_lwr),
  .hwr2(ram_hwr2), .lwr2(ram_lwr2), ._bhe(_ram_bhe), ._ble(_ram_ble), ._bhe2(_ram_bhe2), ._ble2(_ram_ble2),
  ._we(_ram_we), ._oe(_ram_oe), .address(ram_address), .data(ram_data), .ramdata_in(chipRD)
);

wire [12:0] sdaddr;
wire [3:0]  sd_cs;
wire [1:0]  ba, dqm;
wire        sd_we, sd_ras, sd_cas;
wire [15:0] sdata_fpga;
sdram_ctrl sdc (
  .sysclk(clk114), .clk7_en(clk7_en), .reset_in(reset_in), .cache_rst(reset_in),
  .cache_inhibit(1'b0), .cacheline_clr(1'b0), .cpu_cache_ctrl(4'b0011), .reset_out(reset_out),
  .snoop_stb_out(), .snoop_addr_out(),
  .sdaddr(sdaddr), .sd_cs(sd_cs), .ba(ba), .sd_we(sd_we), .sd_ras(sd_ras), .sd_cas(sd_cas),
  .dqm(dqm), .sdata(sdata_fpga),
  .hostWR(32'd0), .hostAddr(22'd0), .hostce(1'b0), .hostwe(1'b0), .hostbytesel(4'b0000),
  .hostRD(), .hostena(),
  // exactly minimig_virtual_top.v: chipWR2 is the wrapper's data_write2, direct
  .chipAddr({1'b0, ram_address[22:1]}), .chipL(_ram_ble), .chipU(_ram_bhe),
`ifdef MUT_NOWR2
  .chipL2(1'b1), .chipU2(1'b1),          // MUTANT: word 2 of a write never enabled
`else
  .chipL2(_ram_ble2), .chipU2(_ram_bhe2),
`endif
  .chipRW(_ram_we), .chip_dma(_ram_oe), .chipWR(ram_data), .chipWR2(dw2),
  .chipRD(chipRD), .chip48(chip48),
  .rtgAddr(26'd0), .rtgce(1'b0), .rtgfill(), .rtgRd(),
  .audAddr(23'd0), .audce(1'b0), .audfill(), .audRd(),
  .cpu_req(1'b0), .cpu_we(1'b0), .cpu_ir(1'b0), .cpu_wadr(25'd0), .cpu_bs(4'b0000),
  .cpu_wdat(32'd0), .cpu_rdat(), .enaWRreg(), .ena7RDreg(ena7RD), .ena7WRreg(ena7WR),
  .cpu_ack(), .cpu_hit()
);

// board / IOB delay model, as sim/sdram_coherency
wire [12:0] pin_addr;  assign #T_CO pin_addr = sdaddr;
wire [1:0]  pin_ba;    assign #T_CO pin_ba   = ba;
wire        pin_cs;    assign #T_CO pin_cs   = sd_cs[0];
wire        pin_ras;   assign #T_CO pin_ras  = sd_ras;
wire        pin_cas;   assign #T_CO pin_cas  = sd_cas;
wire        pin_we;    assign #T_CO pin_we   = sd_we;
wire [1:0]  pin_dqm;   assign #T_CO pin_dqm  = dqm;
wire        oe = sdc.sdata_oe;
reg         oe_d = 1'b0;      always @(oe)            oe_d     <= #T_CO oe;
reg  [15:0] dq_out_d;         always @(sdc.sdata_out) dq_out_d <= #T_CO sdc.sdata_out;
wire [15:0] dq_pin = oe_d ? dq_out_d : 16'bz;
reg  [15:0] dq_in_d = 16'bz;  always @(dq_pin)        dq_in_d  <= #T_IN dq_pin;
assign sdata_fpga = oe ? 16'bz : dq_in_d;
sdr16mx16 sdram (
  .Dq(dq_pin), .Addr(pin_addr), .Ba(pin_ba), .Clk(pin_clk), .Cke(1'b1),
  .Cs_n(pin_cs), .Ras_n(pin_ras), .Cas_n(pin_cas), .We_n(pin_we),
  .LDQM(pin_dqm[0]), .UDQM(pin_dqm[1])
);
// The vendor model prints every command; that alone made a run take half an
// hour.  +sdramdebug turns it back on.
initial if (!$test$plusargs("sdramdebug")) force sdram.Debug = 1'b0;

// ---------------------------------------------------------------- slot counter
// CPU chip slots: sdram_ctrl allocates slot 1 to CHIP at ph1; count those the
// CPU owned (dbr low when the controller sampled the chip port).
integer cpu_slots = 0;
reg     dbr_ph1   = 1'b0;
always @(posedge clk114) begin
  if (sdc.sdram_state == 4'd1) dbr_ph1 <= dbr;
  if (sdc.sdram_state == 4'd2 && sdc.slot1_type == 3'd1 && !dbr_ph1) cpu_slots = cpu_slots + 1;
end

// ---------------------------------------------------------------- scoreboard
integer    errors = 0, checks = 0;
integer    slot_hist [0:3];
integer    seed = 32'h0C32_0001;
reg [15:0] shadow [0:1048575];          // chip RAM, word index = byte address [20:1]

task check16;
  input [8*12:1] what;
  input [23:0]   a;
  input [15:0]   got;
  input [15:0]   want;
  begin
    checks = checks + 1;
    if (got !== want) begin
      errors = errors + 1;
      if (errors <= 30)
        $display("FAIL %0s @%06h got %04h want %04h at %t", what, a, got, want, $time);
    end
  end
endtask

// One CPU access.  wide: a longword, wd = {word A, word A+2}; narrow: word A = wd[31:16].
task cpu_acc;
  input        we;
  input        wide;
  input [23:0] a;
  input [31:0] wd;
  integer      n;
  begin
    @(posedge clk114);
    m_we = we; m_wide = wide; m_adr = a; m_wd = wd;
    cpu_slots = 0;
    m_go = 1'b1;
    wait (m_done === 1'b1);
    n = cpu_slots;
    @(posedge clk114);
    m_go = 1'b0;
    wait (m_done === 1'b0);
    slot_hist[n > 3 ? 3 : n] = slot_hist[n > 3 ? 3 : n] + 1;
    checks = checks + 1;
    if (n != 1) begin
      errors = errors + 1;
      if (errors <= 30)
        $display("FAIL slots @%06h %0s %0s: %0d CPU chip slots, want 1 at %t",
                 a, wide ? "wide" : "narrow", we ? "write" : "read", n, $time);
    end
    if (we && a[23:21] == 3'b000) begin
      shadow[a[20:1]] = wd[31:16];
      if (wide) shadow[a[20:1] + 20'd1] = wd[15:0];
    end
  end
endtask

task run_random;
  input [8*12:1] tag;
  input integer  n;
  integer        j;
  reg [23:0]     ra;
  reg [31:0]     rv;
  begin
    for (j = 0; j < n; j = j + 1) begin
      // banks 0 and 2-3; $080000-$0FFFFF is the DMA and T6 area
      ra = ($random(seed) & 1) ? (24'h100000 | ($random(seed) & 24'h0FFFFC))
                               : ($random(seed) & 24'h07FFFC);
      rv = $random(seed);
      cpu_acc(1, 1, ra, rv);
      cpu_acc(0, 1, ra, 32'd0);
      check16(tag, ra, r_data,  shadow[ra[20:1]]);
      check16(tag, ra, r_data2, shadow[ra[20:1] + 20'd1]);
      if (j % 4 == 0) begin                   // and word 2 once through the narrow path
        cpu_acc(0, 0, ra + 24'd2, 32'd0);
        check16(tag, ra + 24'd2, r_data, shadow[ra[20:1] + 20'd1]);
      end
    end
  end
endtask

integer i;
reg [23:0] a;
initial begin
  for (i = 0; i < 4; i = i + 1) slot_hist[i] = 0;
  repeat (40) @(posedge clk114);
  reset_in = 1'b1;
  @(posedge reset_out);
  repeat (64) @(posedge clk114);

  // T1 bench validation: narrow writes, narrow reads, no DMA.  If this fails the
  // bench is wrong, and nothing else it says means anything.
  for (i = 0; i < 64; i = i + 1) cpu_acc(1, 0, 24'h010000 + 2*i, {16'hA000 + i[15:0], 16'h0000});
  for (i = 0; i < 64; i = i + 1) begin
    a = 24'h010000 + 2*i;
    cpu_acc(0, 0, a, 32'd0);
    check16("T1 narrow", a, r_data, shadow[a[20:1]]);
  end

  // T2 wide reads of what narrow writes put there
  for (i = 0; i < 32; i = i + 1) begin
    a = 24'h010000 + 4*i;
    cpu_acc(0, 1, a, 32'd0);
    check16("T2 wide w1", a, r_data,  shadow[a[20:1]]);
    check16("T2 wide w2", a, r_data2, shadow[a[20:1] + 20'd1]);
  end

  // T3 wide writes, read back one word at a time through the narrow path
  for (i = 0; i < 32; i = i + 1) cpu_acc(1, 1, 24'h020000 + 4*i, {16'hB000 + i[15:0], 16'hC000 + i[15:0]});
  for (i = 0; i < 64; i = i + 1) begin
    a = 24'h020000 + 2*i;
    cpu_acc(0, 0, a, 32'd0);
    check16("T3 narrow", a, r_data, shadow[a[20:1]]);
  end

  // T4 random wide write / wide read over the 2 MB, no DMA
  run_random("T4 random", 100);

  // T5 the same with Agnus taking most CCKs
  dma_pat = 16'b1011_0110_1101_1010;
  run_random("T5 dma", 150);
  // T5b DMA in every other CCK: a DMA slot straight after each CPU slot, the
  // way an AGA bitplane/sprite fetch refills chip48 behind the CPU's read
  dma_pat = 16'b0101_0101_0101_0101;
  run_random("T5b nextslot", 100);
  dma_pat = 16'h0000;

  // T6a a DMA write (Blitter, disk) after a CPU longword write must not write
  //     the held data_write2 into word A+2
  cpu_acc(1, 0, 24'h0D0000, {16'h0000, 16'h0000});
  cpu_acc(1, 0, 24'h0D0002, {16'h5A5A, 16'h0000});
  cpu_acc(1, 1, 24'h0C0000, 32'hDEAD_BEEF);          // data_write2 now holds $BEEF
  @(posedge clk28);
  dma_adr = 20'h68000;                               // $0D0000
  dma_wd  = 16'h1234;
  dma_we  = 1'b1;
  dma_pat = 16'hFFFF;
  repeat (32*8) @(posedge clk28);                    // 32 CCKs
  dma_pat = 16'h0000;
  repeat (4*8) @(posedge clk28);
  dma_we  = 1'b0;
  dma_adr = 20'h40000;
  cpu_acc(0, 0, 24'h0D0000, 32'd0); check16("T6a dma", 24'h0D0000, r_data, 16'h1234);
  cpu_acc(0, 0, 24'h0D0002, 32'd0); check16("T6a word2", 24'h0D0002, r_data, 16'h5A5A);

  // T6b a CPU word write after a CPU longword write must not write word A+2
  cpu_acc(1, 0, 24'h0D0012, {16'hA5A5, 16'h0000});
  cpu_acc(1, 1, 24'h0C0010, 32'hCAFE_F00D);          // data_write2 now holds $F00D
  cpu_acc(1, 0, 24'h0D0010, {16'h7777, 16'h0000});
  cpu_acc(0, 1, 24'h0D0010, 32'd0);
  check16("T6b w1", 24'h0D0010, r_data,  16'h7777);
  check16("T6b w2", 24'h0D0010, r_data2, 16'hA5A5);

  // T7 the Kickstart ROM: uploaded as the 832 does it (gary's cpu_hlt), then
  //    read wide at $F80000 and, with the overlay on, at $000000
  hlt = 1'b1;
  for (i = 0; i < 16; i = i + 1) cpu_acc(1, 0, 24'hF80000 + 2*i, {16'hF000 + i[15:0], 16'h0000});
  hlt = 1'b0;
  for (i = 0; i < 8; i = i + 1) begin
    a = 24'hF80000 + 4*i;
    cpu_acc(0, 1, a, 32'd0);
    check16("T7 rom w1", a, r_data,  16'hF000 + 2*i);
    check16("T7 rom w2", a, r_data2, 16'hF001 + 2*i);
  end
  ovl = 1'b1;
  cpu_acc(0, 1, 24'h000000, 32'd0);
  check16("T7 ovl w1", 24'h000000, r_data,  16'hF000);
  check16("T7 ovl w2", 24'h000000, r_data2, 16'hF001);
  cpu_acc(0, 1, 24'h000004, 32'd0);
  check16("T7 ovl w1", 24'h000004, r_data,  16'hF002);
  check16("T7 ovl w2", 24'h000004, r_data2, 16'hF003);
  ovl = 1'b0;

  $display("CHIP32 slots per CPU access: 0:%0d 1:%0d 2:%0d 3+:%0d",
           slot_hist[0], slot_hist[1], slot_hist[2], slot_hist[3]);
  $display("CHIP32 TB: %0d checks, %0d errors", checks, errors);
  if (errors == 0) $display("CHIP32 TB: PASS");
  else             $display("CHIP32 TB: FAIL");
  $finish;
end

// heartbeat, so a slow run shows it is moving
always #(64'd100_000_000) begin $display("CHIP32 progress: %0t, %0d checks, %0d errors", $time, checks, errors); $fflush; end

initial begin
  #(64'd100_000_000_000);                // 100 ms of sim time
  $display("CHIP32 TB: FAIL timeout (checks %0d, errors %0d)", checks, errors);
  $finish;
end

endmodule
