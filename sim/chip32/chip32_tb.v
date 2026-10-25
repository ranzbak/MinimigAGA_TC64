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
// T9 (the slot schedule): with dma_auto set, every DMA CCK takes the next
// address of a 256-word ring at $080000 and writes four in every eight
// (Blitter- or disk-like); each lap reads back what the one before wrote.  Everything
// here is a function of the CCK count alone, never of the CPU, so the DMA
// trace must come out the same whatever the CPU does.
reg         dma_auto = 1'b0;
reg  [15:0] dma_k    = 16'd0;
always @(posedge clk28) begin
  cck_d <= cck;
  if (cck_d && !cck) begin               // start of the cck-low half
    dma_busy <= dma_pat[dma_i];
    dma_i    <= dma_i + 4'd1;
    if (dma_auto && dma_pat[dma_i]) begin
      dma_adr <= 20'h40000 | {12'd0, dma_k[7:0]};
      dma_we  <= dma_k[8] ^ dma_k[2];  // the next lap reads what this one wrote
      dma_wd  <= dma_k ^ 16'hA5C3;
      dma_k   <= dma_k + 16'd1;
    end
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
// AND clkena_e).  The CPU's own 2-3 clk release delay is left out of T1-T7:
// the next cycle cannot start before the next ena7WRreg either way.  T8/T9
// put it back as +lat (findings/fastslot).
//
// +fast: the wrapper's Fast chip mode (TG68K.vhd fastchip_d = '1').  A cycle
// whose dtack was seen (waitm = '0') completes on the ena7WRreg that ENDS its
// chip slot: the bridge latched the data at phase 12 of that round, so the
// strobes drop and the data is captured there (fast_cyc), and the release
// follows two clk later (fast_p1 -> fast_ready -> chipset_ready), once
// datatg68_c, one more register behind r_data in the VHDL, holds it too.
// The slot schedule is untouched: the bridge still grants the CPU only a CCK
// that DMA left free, and the next launch still waits for an ena7WRreg.
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
reg         fast       = 1'b0;
reg         fast_cyc   = 1'b0;
reg         fast_p1    = 1'b0;
reg         fast_ready = 1'b0;
wire        chipset_ready = (ena7RD && clkena_e) || fast_ready;
always @(posedge clk114) begin
  fast_p1    <= 1'b0;
  fast_ready <= fast_p1;
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
      2'b01: begin
               clkena_e <= 1'b0; S <= 2'b10;
`ifdef MUT_EARLY
               // MUTANT: Fast completion one round early, before the slot
               if (fast) begin
                 as_n <= 1'b1; rw <= 1'b1;
                 uds_n <= 1'b1; lds_n <= 1'b1; uds2_n <= 1'b1; lds2_n <= 1'b1;
                 r_data <= cpu_data; r_data2 <= cpu_data2;
                 fast_cyc <= 1'b1; fast_p1 <= 1'b1; S <= 2'b11;
               end
`endif
             end
      2'b10: if (!waitm) begin
               if (fast) begin
                 as_n <= 1'b1; rw <= 1'b1;
                 uds_n <= 1'b1; lds_n <= 1'b1; uds2_n <= 1'b1; lds2_n <= 1'b1;
                 r_data <= cpu_data; r_data2 <= cpu_data2;
                 fast_cyc <= 1'b1; fast_p1 <= 1'b1;
               end
               S <= 2'b11;
             end
      default: ;
    endcase
  end else if (ena7RD) begin
    case (S)
      2'b10: waitm <= dtack_n;
      2'b11: if (!fast_cyc) begin
               as_n <= 1'b1; rw <= 1'b1;
               uds_n <= 1'b1; lds_n <= 1'b1; uds2_n <= 1'b1; lds2_n <= 1'b1;
               if (!clkena_e) begin r_data <= cpu_data; r_data2 <= cpu_data2; end
               clkena_e <= 1'b1;
             end
      default: ;
    endcase
  end
  // chipset_ready, last so it wins over state 11 (as in the VHDL)
  if (chipset_ready) begin
    S <= 2'b00; clkena_e <= 1'b0; fast_cyc <= 1'b0; m_done <= 1'b1;
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
`ifdef MUT_STEAL
  .eclk(eclk), .vpa(sel_cia), .dbr(1'b0), .dbs(dbs), .xbs(xbs), .nrdy(1'b0), .bls(),   // MUTANT: the CPU never sees DMA
`else
  .eclk(eclk), .vpa(sel_cia), .dbr(dbr), .dbs(dbs), .xbs(xbs), .nrdy(1'b0), .bls(),
`endif
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

// ---------------------------------------------------------------- CCK accounting
// (findings/fastslot)  sdram_ctrl runs one chip slot per 7 MHz round, two per
// CCK: the cck-high round is Agnus's (dbr is only ever high there) and the
// cck-low round is the CPU's (the bridge's enable needs cck low), which the
// bridge grants only when the cck-high half of the SAME CCK had no DMA.  So a
// CCK is one memory cycle, as on the real chip bus, and the rules are:
//   steal  -- a CPU chip-RAM slot in a CCK whose DMA half was used: MUST be 0
//   b2b    -- CPU chip-RAM slots in two consecutive CCKs: MUST be 0.  On AGA
//             the CPU gets at most one chip cycle in two CCKs (WinUAE
//             wait_cpu_cycle_read_ce020: 1 CCK before, a free slot, 1 CCK
//             after; Jens Schoenfeld: "the CPU only gets every other time slot").
// Only chip RAM counts: the Kickstart ROM is not on the chip bus (dbs = 0).
integer    errors = 0, checks = 0;
integer    cck_idx = 0;              // CCKs since time 0, ++ at every rising cck
reg        cck_q = 1'b0;
reg        cck_ph1 = 1'b0;
reg        cc_dma = 1'b0, cc_cpu = 1'b0, cc_cpu_prev = 1'b0;
integer    cc_n = 0, cc_dma_n = 0, cc_cpu_n = 0, cc_rom_n = 0, cc_steal = 0, cc_b2b = 0;
// T8 stream: CCKs between consecutive CPU chip slots
reg        t8_on = 1'b0;
integer    t8_li;
integer    t8_last = -1, t8_n = 0, t8_sum = 0;
integer    t8_hist [0:4];            // 0..3 CCK, 4 = 4 or more
// T10 P2C: a DMA read in the CCK right after the CPU's write must see it
localparam [22:1] T10_A = 22'h048800;    // byte $091000, nothing else uses it
reg        t10_on = 1'b0, t10_valid = 1'b0, t10_rec = 1'b0;
reg [15:0] t10_exp = 16'd0, t10_exp_q = 16'd0;
integer    t10_n = 0, t10_bad = 0;
// T9 DMA trace
reg        t9_on = 1'b0;
integer    t9_start = 0, t9_fd = 0;
reg        t9_rec = 1'b0;
reg [22:1] t9_a;
reg        t9_we;
reg [15:0] t9_wd;
integer    t9_cck;
always @(posedge clk114) begin
  cck_q <= cck;
  if (cck && !cck_q) begin
    // a CCK ended: judge it
    if (cc_dma && cc_cpu) begin
      cc_steal = cc_steal + 1;
      errors   = errors + 1;
      if (errors <= 30) $display("FAIL steal: CPU chip slot in DMA CCK %0d at %t", cck_idx, $time);
    end
    if (cc_cpu && cc_cpu_prev) begin
      cc_b2b = cc_b2b + 1;
      errors = errors + 1;
      if (errors <= 30) $display("FAIL b2b: CPU chip slots in CCKs %0d and %0d at %t", cck_idx - 1, cck_idx, $time);
    end
    cc_n        = cc_n + 1;
    cc_cpu_prev = cc_cpu;
    cc_dma      = 1'b0;
    cc_cpu      = 1'b0;
    cck_idx     = cck_idx + 1;
  end
  if (sdc.sdram_state == 4'd1) cck_ph1 <= cck;
  if (sdc.sdram_state == 4'd2 && sdc.slot1_type == 3'd1) begin
    if (dbr_ph1) begin
      cc_dma   = 1'b1;
      cc_dma_n = cc_dma_n + 1;
      if (t10_on && t10_valid && !sdc.slot1_write && sdc.slot1_addr[22:1] == T10_A) begin
        t10_rec   = 1'b1;
        t10_exp_q = t10_exp;
      end
      if (t9_on) begin
        t9_rec = 1'b1;
        t9_a   = sdc.slot1_addr[22:1];
        t9_we  = sdc.slot1_write;
        t9_wd  = ram_data;
        t9_cck = cck_idx - t9_start;
      end
    end else if (sdc.slot1_addr[22:21] == 2'b00) begin      // chip RAM
      cc_cpu   = 1'b1;
      cc_cpu_n = cc_cpu_n + 1;
      if (t10_on && sdc.slot1_write && sdc.slot1_addr[22:1] == T10_A) begin
        t10_exp   = ram_data;            // what the CPU's slot writes (chipWR)
        t10_valid = 1'b1;
      end
      if (t8_on) begin
        if (t8_last >= 0) begin
          t8_hist[(cck_idx - t8_last) > 4 ? 4 : (cck_idx - t8_last)] =
            t8_hist[(cck_idx - t8_last) > 4 ? 4 : (cck_idx - t8_last)] + 1;
          t8_sum = t8_sum + (cck_idx - t8_last);
          t8_n   = t8_n + 1;
        end
        t8_last = cck_idx;
      end
    end else
      cc_rom_n = cc_rom_n + 1;
  end
  if (sdc.sdram_state == 4'd11 && t10_rec) begin
    t10_n = t10_n + 1;
    if (chipRD !== t10_exp_q) begin
      t10_bad = t10_bad + 1;
      errors  = errors + 1;
      if (errors <= 30) $display("FAIL T10 P2C: DMA read %04h, the CPU's last write was %04h at %t", chipRD, t10_exp_q, $time);
    end
    t10_rec = 1'b0;
  end
  // a DMA read's data is in chipRD from phase 10 (sdram_ctrl ph9 register)
  if (sdc.sdram_state == 4'd11 && t9_rec) begin
    $fdisplay(t9_fd, "%0d %06h %s %04h", t9_cck, {t9_a, 1'b0}, t9_we ? "W" : "R", t9_we ? t9_wd : chipRD);
    t9_rec = 1'b0;
  end
end

// ---------------------------------------------------------------- trace checksum
// Every SDRAM pin and the CPU bus strobes, folded once per clk, printed at the
// end of T7: a bench change that is meant to leave T1-T7 alone (the Standard
// master) must leave this number alone too.
reg [63:0] tr_sum = 64'd0;
function [63:0] nx64;                    // X/Z -> 0, so an idle DQ bus folds in as zeros
  input [63:0] v;
  integer b;
  for (b = 0; b < 64; b = b + 1) nx64[b] = (v[b] === 1'b1);
endfunction
always @(posedge clk114)
  tr_sum <= {tr_sum[62:0], tr_sum[63]}
          ^ nx64({sdaddr, ba, sd_we, sd_ras, sd_cas, sd_cs[0], dqm,
                  sdc.sdata_oe, sdc.sdata_oe ? sdc.sdata_out : 16'h0000,
                  as_n, dtack_n, rw, uds_n, lds_n, uds2_n, lds2_n, 19'd0})
          ^ nx64({48'd0, chipRD});

// ---------------------------------------------------------------- scoreboard
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
// +lat=N: clk cycles from a release to the CPU's next request, on top of the
// two this task always spends; T8/T9 only (lat_now), so T1-T7 are unchanged.
integer lat = 0, lat_now = 0;
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
    repeat (lat_now) @(posedge clk114);  // the CPU's release -> next request (T8/T9)
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

// T9's CPU side: random wide writes and reads (and a narrow read in four),
// checked against the shadow, for as long as t9_cpu is set.
reg t9_cpu = 1'b0;
integer t9_acc = 0;
task run_random_while_t9;
  reg [23:0] ra;
  reg [31:0] rv;
  integer    j;
  begin
    j = 0;
    while (t9_cpu) begin
      ra = ($random(seed) & 1) ? (24'h100000 | ($random(seed) & 24'h0FFFFC))
                               : ($random(seed) & 24'h07FFFC);
      rv = $random(seed);
      cpu_acc(1, 1, ra, rv);
      cpu_acc(0, 1, ra, 32'd0);
      check16("T9 sched", ra, r_data,  shadow[ra[20:1]]);
      check16("T9 sched", ra, r_data2, shadow[ra[20:1] + 20'd1]);
      t9_acc = t9_acc + 2;
      if (j % 4 == 0) begin
        cpu_acc(0, 0, ra + 24'd2, 32'd0);
        check16("T9 sched", ra + 24'd2, r_data, shadow[ra[20:1] + 20'd1]);
        t9_acc = t9_acc + 1;
      end
      j = j + 1;
    end
  end
endtask

// T9's DMA side: eight patterns of 256 CCKs each, switched on the CCK count
// since the window opened, so both modes see them in the same CCKs.
reg [15:0] t9_pats [0:7];
initial begin
  t9_pats[0] = 16'hFFFF; t9_pats[1] = 16'h5555; t9_pats[2] = 16'hAAAA; t9_pats[3] = 16'hB6DA;
  t9_pats[4] = 16'h0F0F; t9_pats[5] = 16'h7777; t9_pats[6] = 16'h8001; t9_pats[7] = 16'hFFFE;
end
always @(posedge clk114)
  if (t9_on && dma_auto) begin
    if (cck_idx - t9_start < 2048) dma_pat <= t9_pats[(cck_idx - t9_start) / 256];
    else                           dma_pat <= 16'h0000;
  end

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
reg        gate_fast = 1'b0;
reg        stopfail  = 1'b0;
reg [8*256:1] t9_file;
initial begin
  for (i = 0; i < 4; i = i + 1) slot_hist[i] = 0;
  for (i = 0; i < 5; i = i + 1) t8_hist[i] = 0;
  fast      = $test$plusargs("fast");
  gate_fast = $test$plusargs("gate_fast");
  stopfail  = $test$plusargs("stopfail");
  if (!$value$plusargs("lat=%d", lat)) lat = 0;
  if (!$value$plusargs("t9file=%s", t9_file)) t9_file = "build/t9_dma.txt";
  t9_fd = $fopen(t9_file, "w");
  repeat (40) @(posedge clk114);
  reset_in = 1'b1;
  @(posedge reset_out);
  repeat (64) @(posedge clk114);

  // +only8: skip T1-T7 (a quick look at T8-T10 while working on them)
  if (!$test$plusargs("only8")) begin
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

  // T7 the Kickstart ROM: uploaded as the OSD firmware does it (gary's cpu_hlt), then
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
  end

  // Everything above is T1-T7 exactly as before findings/fastslot: these two
  // lines and the checksum are what a Standard run is compared on.
  $display("CHIP32 T1-T7 slots per CPU access: 0:%0d 1:%0d 2:%0d 3+:%0d, %0d checks, %0d errors",
           slot_hist[0], slot_hist[1], slot_hist[2], slot_hist[3], checks, errors);
  $display("CHIP32 trace checksum through T7: %016h", tr_sum);

  // T8 the CPU's rate with no DMA: 64 wide writes and 64 wide reads back to
  // back, at four CPU latencies (release to next request; sim/ddr3_cpu's
  // CHIPBUS cadence line measures the real one: mostly 10-15 clk, which is
  // lat 8-13 here, the task itself spending two).  The authentic AGA rate is
  // one chip cycle in two CCKs, so with +gate_fast every period must be
  // exactly 2 CCK at every latency up to 24.
  dma_pat = 16'h0000;
  for (t8_li = 0; t8_li < 4; t8_li = t8_li + 1) begin
    lat_now = (t8_li == 0) ? 0 : (t8_li == 1) ? 6 : (t8_li == 2) ? 12 : 24;
    for (i = 0; i < 5; i = i + 1) t8_hist[i] = 0;
    t8_n = 0; t8_sum = 0; t8_last = -1;
    t8_on = 1'b1;
    for (i = 0; i < 64; i = i + 1)
      cpu_acc(1, 1, 24'h030000 + 256*t8_li + 4*i, {16'h3000 + i[15:0], 16'h4000 + t8_li[15:0]});
    for (i = 0; i < 64; i = i + 1) begin
      a = 24'h030000 + 256*t8_li + 4*i;
      cpu_acc(0, 1, a, 32'd0);
      check16("T8 stream", a, r_data,  shadow[a[20:1]]);
      check16("T8 stream", a, r_data2, shadow[a[20:1] + 20'd1]);
    end
    t8_on = 1'b0;
    $display("CHIP32 T8 stream (%0s, lat=%0d): %0d periods, CCK 1:%0d 2:%0d 3:%0d 4+:%0d, avg %0d.%02d CCK",
             fast ? "Fast" : "Standard", lat_now, t8_n, t8_hist[1], t8_hist[2], t8_hist[3], t8_hist[4],
             t8_n ? t8_sum / t8_n : 0, t8_n ? (t8_sum * 100 / t8_n) % 100 : 0);
    if (gate_fast) begin
      checks = checks + 1;
      if (t8_n < 127 || t8_hist[2] != t8_n) begin
        errors = errors + 1;
        $display("FAIL T8 rate (lat=%0d): want every CPU chip cycle 2 CCK after the last (%0d of %0d were)",
                 lat_now, t8_hist[2], t8_n);
      end
    end
  end
  lat_now = lat;

  // T9 the slot schedule: heavy, CPU-independent DMA for 2048 CCKs while the
  // CPU runs checked random accesses.  Every DMA slot is written to +t9file;
  // run.sh compares the Standard and Fast files, which must be identical.
  // (the DMA ring filled first, so its first lap reads defined words)
  for (i = 0; i < 128; i = i + 1) cpu_acc(1, 1, 24'h080000 + 4*i, {16'h9000 + {i[14:0], 1'b0}, 16'h9001 + {i[14:0], 1'b0}});
  repeat (2) @(posedge clk114);
  while (cck_idx % 16 != 0) @(posedge clk114);
  t9_start = cck_idx;
  dma_k    = 16'd0;
  dma_auto = 1'b1;
  t9_on    = 1'b1;
  t9_cpu   = 1'b1;
  fork
    run_random_while_t9;
    begin
      while (cck_idx - t9_start < 2048 + 4) @(posedge clk114);
      t9_cpu = 1'b0;
    end
  join
  dma_auto = 1'b0;
  dma_pat  = 16'h0000;
  repeat (64) @(posedge clk114);
  t9_on    = 1'b0;
  dma_we   = 1'b0;
  dma_adr  = 20'h40000;
  $fclose(t9_fd);
  $display("CHIP32 T9 slot schedule: 2048 CCKs, %0d CPU accesses, DMA trace in %0s", t9_acc, t9_file);

  // T10 P2C coherency through the chip slot: DMA reads one word every other
  // CCK while the CPU writes it (and reads it back) in the CCKs between, so
  // most CPU writes are followed by a DMA read of the same word in the very
  // next CCK -- the case a Fast cycle, which drops its strobes at the end of
  // its slot, could get wrong.  Every DMA read after the CPU's first write
  // must return the CPU's most recent write.
  @(posedge clk28);
  dma_adr = {T10_A[20:1]};
  dma_we  = 1'b0;
  dma_pat = 16'h5555;
  t10_on  = 1'b1;
  for (i = 0; i < 160; i = i + 1) begin
    lat_now = (i % 4) * 4;
    a = {1'b0, T10_A, 1'b0};
    cpu_acc(1, 0, a, {16'hC000 + i[15:0], 16'h0000});
    cpu_acc(0, 0, a, 32'd0);
    check16("T10 rdback", a, r_data, shadow[a[20:1]]);
  end
  lat_now = lat;
  repeat (64) @(posedge clk114);
  t10_on  = 1'b0;
  dma_pat = 16'h0000;
  repeat (64) @(posedge clk114);
  dma_adr = 20'h40000;
  $display("CHIP32 T10 P2C: %0d DMA reads checked against the CPU's last write, %0d wrong", t10_n, t10_bad);
  checks = checks + 1;
  if (t10_n < 100) begin
    errors = errors + 1;
    $display("FAIL T10 P2C: only %0d DMA reads checked", t10_n);
  end

  $display("CHIP32 CCK accounting: %0d CCKs, DMA %0d, CPU chip %0d, CPU ROM %0d, steal %0d, b2b %0d",
           cc_n, cc_dma_n, cc_cpu_n, cc_rom_n, cc_steal, cc_b2b);
  $display("CHIP32 slots per CPU access: 0:%0d 1:%0d 2:%0d 3+:%0d",
           slot_hist[0], slot_hist[1], slot_hist[2], slot_hist[3]);
  $display("CHIP32 TB: %0d checks, %0d errors", checks, errors);
  if (errors == 0) $display("CHIP32 TB: PASS");
  else             $display("CHIP32 TB: FAIL");
  $finish;
end

// +stopfail: a mutant has made its point after 30 failures
always @(posedge clk114)
  if (stopfail && errors >= 30) begin
    $display("CHIP32 TB: FAIL (stopped after %0d errors)", errors);
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
