`timescale 1ns/1ps
// Cross-check of the hand TAP model sim/rv_dbg/xc7_tap.v against Vivado's
// own simulation models (xsim): the same pseudo-random TMS/TDI stream into
//   reference  JTAG_SIME2 (PART_NAME 7A100T) + BSCANE2 JTAG_CHAIN 4 and 1
//              + glbl ($XILINX_VIVADO/data/verilog/src, compiled in place)
//   model      xc7_tap (instance xc7_jtag) + xc7_bscane2 JTAG_CHAIN 4 and 1
// Compared just before and 2 ns after every TCK edge: TDO (the model's
// tdo_oe = 0 is high-Z) and, per chain, SEL, CAPTURE, SHIFT, UPDATE, RESET,
// RUNTEST, TDI, TCK, TMS.  The USERn TDO inputs (the same signal into both)
// are LFSR bits changing on the falling (chain 4, like a falling-edge DTM)
// and on the rising (chain 1) TCK edge.
//
// Stream (from Run-Test/Idle or Update): IR scans of USER4 0x23, IDCODE
// 0x09, BYPASS 0x3F, USER3 0x22, USER1 0x02, USER2 0x03 or a random 6-bit
// value; DR scans of 1..80 random bits; both with a random Pause in the
// middle and/or at the end, ending in Run-Test/Idle or chained from Update
// straight into the next scan; idle runs; Test-Logic-Reset; random TMS
// walks (then a reset).  Until >= NCYC TCK cycles.
//
// Defines: XCHECK_TEETH (the model's USER4 = 0x22: must mismatch).
// Plusargs: +SEED=<n> (default 1), +NCYC=<n> (default 20000).
// Last line: "=== XCHECK <n> TCK cycles, <m> mismatches, ..."
module tb_xcheck;
  reg tck = 1'b0, tms = 1'b1, tdi = 1'b0;
  reg [15:0] lfsr4 = 16'hACE1, lfsr1 = 16'h1D0F;
  wire utdo4 = lfsr4[0], utdo1 = lfsr1[0];

  // ---- reference: Vivado unisims
  wire r_tdo;
  JTAG_SIME2 #(.PART_NAME("7A100T")) u_ref_tap (.TDO(r_tdo), .TCK(tck), .TDI(tdi), .TMS(tms));
  wire r4_cap, r4_drck, r4_rst, r4_rt, r4_sel, r4_sh, r4_tck, r4_tdi, r4_tms, r4_upd;
  wire r1_cap, r1_drck, r1_rst, r1_rt, r1_sel, r1_sh, r1_tck, r1_tdi, r1_tms, r1_upd;
  BSCANE2 #(.JTAG_CHAIN(4)) u_ref_b4 (
    .CAPTURE(r4_cap), .DRCK(r4_drck), .RESET(r4_rst), .RUNTEST(r4_rt), .SEL(r4_sel),
    .SHIFT(r4_sh), .TCK(r4_tck), .TDI(r4_tdi), .TMS(r4_tms), .UPDATE(r4_upd), .TDO(utdo4));
  BSCANE2 #(.JTAG_CHAIN(1)) u_ref_b1 (
    .CAPTURE(r1_cap), .DRCK(r1_drck), .RESET(r1_rst), .RUNTEST(r1_rt), .SEL(r1_sel),
    .SHIFT(r1_sh), .TCK(r1_tck), .TDI(r1_tdi), .TMS(r1_tms), .UPDATE(r1_upd), .TDO(utdo1));

  // ---- model: sim/rv_dbg/xc7_tap.v
  wire m_tdo_q, m_tdo_oe;
`ifdef XCHECK_TEETH
  xc7_tap #(.USER4(6'h22)) xc7_jtag (
`else
  xc7_tap xc7_jtag (
`endif
    .tck(tck), .tms(tms), .tdi(tdi), .tdo(m_tdo_q), .tdo_oe(m_tdo_oe));
  wire m_tdo = m_tdo_oe ? m_tdo_q : 1'bz;
  wire m4_cap, m4_drck, m4_rst, m4_rt, m4_sel, m4_sh, m4_tck, m4_tdi, m4_tms, m4_upd;
  wire m1_cap, m1_drck, m1_rst, m1_rt, m1_sel, m1_sh, m1_tck, m1_tdi, m1_tms, m1_upd;
  xc7_bscane2 #(.JTAG_CHAIN(4)) u_m_b4 (
    .CAPTURE(m4_cap), .DRCK(m4_drck), .RESET(m4_rst), .RUNTEST(m4_rt), .SEL(m4_sel),
    .SHIFT(m4_sh), .TCK(m4_tck), .TDI(m4_tdi), .TMS(m4_tms), .UPDATE(m4_upd), .TDO(utdo4));
  xc7_bscane2 #(.JTAG_CHAIN(1)) u_m_b1 (
    .CAPTURE(m1_cap), .DRCK(m1_drck), .RESET(m1_rst), .RUNTEST(m1_rt), .SEL(m1_sel),
    .SHIFT(m1_sh), .TCK(m1_tck), .TDI(m1_tdi), .TMS(m1_tms), .UPDATE(m1_upd), .TDO(utdo1));

  // USERn TDO stimulus
  always @(negedge tck) lfsr4 <= {lfsr4[0] ^ lfsr4[2] ^ lfsr4[3] ^ lfsr4[5], lfsr4[15:1]};
  always @(posedge tck) lfsr1 <= {lfsr1[0] ^ lfsr1[2] ^ lfsr1[3] ^ lfsr1[5], lfsr1[15:1]};

  // ---- compare
  wire [18:0] ref_v = {r_tdo, r4_sel, r4_cap, r4_sh, r4_upd, r4_rst, r4_rt, r4_tdi, r4_tck, r4_tms,
                       r1_sel, r1_cap, r1_sh, r1_upd, r1_rst, r1_rt, r1_tdi, r1_tck, r1_tms};
  wire [18:0] mod_v = {m_tdo, m4_sel, m4_cap, m4_sh, m4_upd, m4_rst, m4_rt, m4_tdi, m4_tck, m4_tms,
                       m1_sel, m1_cap, m1_sh, m1_upd, m1_rst, m1_rt, m1_tdi, m1_tck, m1_tms};

  integer ncyc = 0, nmis = 0, ncmp = 0, seed, ncyc_max;
  reg     cmp_on = 1'b0;
  integer n_ir_user4 = 0, n_ir_idcode = 0, n_ir_bypass = 0, n_ir_other = 0;
  integer n_dr = 0, n_dr_user4 = 0, n_pause = 0, n_reset = 0, n_walk = 0, n_chain = 0;
  integer sel4_high = 0, tdo_driven = 0;
  reg [5:0] cur_ir = 6'h09;

  task compare(input [8*10-1:0] where);
    begin
      if (cmp_on) begin
        ncmp = ncmp + 1;
        if (ref_v !== mod_v) begin
          nmis = nmis + 1;
          if (nmis <= 20)
            $display("=== MISMATCH cycle %0d %0s: ref %b model %b (TDO,SEL4,CAP4,SH4,UPD4,RST4,RT4,TDI4,TCK4,TMS4,SEL1,...)",
                     ncyc, where, ref_v, mod_v);
        end
      end
    end
  endtask

  // one TCK cycle; TMS/TDI change mid low phase
  task step(input m, input d);
    begin
      tms = m; tdi = d;
      #24 compare("pre-rise");
      #1  tck = 1'b1;
      #2  compare("post-rise");
      #47 compare("pre-fall");
      #1  tck = 1'b0;
      #2  compare("post-fall");
      #23;
      ncyc = ncyc + 1;
      if (r4_sel === 1'b1) sel4_high = sel4_high + 1;
      if (r_tdo === 1'b0 || r_tdo === 1'b1) tdo_driven = tdo_driven + 1;
    end
  endtask

  reg at_update;   // the stream is in Update-IR/DR (else Run-Test/Idle)

  task reset_tap;
    integer k;
    begin
      for (k = 0; k < 5 + ($unsigned($random(seed)) % 3); k = k + 1) step(1'b1, 1'b0);
      step(1'b0, 1'b0);
      at_update = 1'b0;
      cur_ir = 6'h09;
      n_reset = n_reset + 1;
    end
  endtask

  task to_idle;
    begin
      if (at_update) step(1'b0, 1'b0);
      at_update = 1'b0;
    end
  endtask

  // pause from Exit1 for k cycles, back to Exit2
  task pause(input integer k);
    integer j;
    begin
      step(1'b0, $random(seed));               // Exit1 -> Pause
      for (j = 0; j < k; j = j + 1) step(1'b0, $random(seed));
      step(1'b1, $random(seed));               // Pause -> Exit2
      n_pause = n_pause + 1;
    end
  endtask

  // one IR or DR scan of n bits, from Run-Test/Idle or Update
  task scan(input is_ir, input [79:0] data, input integer n);
    integer i, pause_at;
    begin
      step(1'b1, 1'b0);                        // -> Select-DR
      if (is_ir) step(1'b1, 1'b0);             // -> Select-IR
      step(1'b0, 1'b0);                        // -> Capture
      step(1'b0, 1'b0);                        // -> Shift
      pause_at = ($unsigned($random(seed)) % 4 == 0 && n > 1) ? $unsigned($random(seed)) % (n - 1) : -1;
      for (i = 0; i < n; i = i + 1) begin
        if (i == n - 1) step(1'b1, data[i]);   // last bit -> Exit1
        else if (i == pause_at) begin
          step(1'b1, data[i]);                 // -> Exit1
          pause($unsigned($random(seed)) % 4);
          step(1'b0, 1'b0);                    // Exit2 -> Shift (no shift on this edge)
        end else step(1'b0, data[i]);
      end
      if ($unsigned($random(seed)) % 4 == 0) begin
        pause($unsigned($random(seed)) % 3);
        step(1'b1, 1'b0);                      // Exit2 -> Update
      end else
        step(1'b1, 1'b0);                      // Exit1 -> Update
      at_update = 1'b1;
      if ($unsigned($random(seed)) % 2) begin
        step(1'b0, 1'b0);                      // Update -> Run-Test/Idle
        at_update = 1'b0;
      end else
        n_chain = n_chain + 1;                 // the next scan starts from Update
    end
  endtask

  integer act, k, n;
  reg [79:0] data;
  reg [5:0]  irv;
  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    if (!$value$plusargs("NCYC=%d", ncyc_max)) ncyc_max = 20000;
    $display("=== XCHECK seed %0d, >= %0d TCK cycles%s", seed, ncyc_max,
`ifdef XCHECK_TEETH
             ", TEETH: model USER4 = 0x22"
`else
             ""
`endif
             );
    // leave and re-enter Test-Logic-Reset: the reference IR becomes IDCODE
    // (its IR is X until the first update or reset entry), then compare
    #10;
    step(1'b1, 1'b0); step(1'b0, 1'b0);
    at_update = 1'b0;
    reset_tap;
    cmp_on = 1'b1;

    while (ncyc < ncyc_max) begin
      act = $unsigned($random(seed)) % 100;
      if (act < 30) begin                      // IR scan
        k = $unsigned($random(seed)) % 7;
        irv = (k == 0) ? 6'h23 : (k == 1) ? 6'h09 : (k == 2) ? 6'h3F : (k == 3) ? 6'h22 :
              (k == 4) ? 6'h02 : (k == 5) ? 6'h03 : $random(seed);
        // USER4 twice as often: the tunnel's instruction
        if ($unsigned($random(seed)) % 4 == 0) irv = 6'h23;
        scan(1'b1, {74'h0, irv}, 6);
        cur_ir = irv;
        if (irv == 6'h23) n_ir_user4 = n_ir_user4 + 1;
        else if (irv == 6'h09) n_ir_idcode = n_ir_idcode + 1;
        else if (irv == 6'h3F) n_ir_bypass = n_ir_bypass + 1;
        else n_ir_other = n_ir_other + 1;
      end else if (act < 80) begin             // DR scan
        n = 1 + $unsigned($random(seed)) % 80;
        data = {$random(seed), $random(seed), $random(seed)};
        scan(1'b0, data, n);
        n_dr = n_dr + 1;
        if (cur_ir == 6'h23) n_dr_user4 = n_dr_user4 + 1;
      end else if (act < 90) begin             // idle
        to_idle;
        n = $unsigned($random(seed)) % 12;
        for (k = 0; k < n; k = k + 1) step(1'b0, $random(seed));
      end else if (act < 95) begin             // Test-Logic-Reset
        reset_tap;
      end else begin                           // random TMS walk, then reset
        n = 1 + $unsigned($random(seed)) % 24;
        for (k = 0; k < n; k = k + 1) step($random(seed), $random(seed));
        n_walk = n_walk + 1;
        reset_tap;
      end
    end
    $display("=== XCHECK coverage: IR loads USER4 %0d, IDCODE %0d, BYPASS %0d, other %0d; DR scans %0d (%0d with USER4), pauses %0d, chained scans %0d, resets %0d, random walks %0d; cycles with SEL4 = 1: %0d, with TDO driven: %0d",
             n_ir_user4, n_ir_idcode, n_ir_bypass, n_ir_other, n_dr, n_dr_user4, n_pause, n_chain,
             n_reset, n_walk, sel4_high, tdo_driven);
    $display("=== XCHECK %0d TCK cycles, %0d comparisons, %0d mismatches", ncyc, ncmp, nmis);
    $finish;
  end
endmodule
