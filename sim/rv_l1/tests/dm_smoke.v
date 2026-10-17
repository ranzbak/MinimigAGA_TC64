`timescale 1ns/1ps
// dm_smoke: RISC-V debug smoke test over the pin TAP (DEBUG=2, VexOsd_DMJ).
// Compiled into tb_rv_l1 with -DDM_SMOKE (run.sh dm_smoke), program
// tests/dm_smoke.S.  Drives the JTAG BFM tb_rv_l1.bfm; reads the memory
// model tb_rv_l1.mem; ends the run through tb_rv_l1.finish_run on a failed
// check ("=== FAIL dm <what>").  The run passes when the program reaches
// DONE 0 after the whole sequence (complete = 1) with DM_CNT = target.
//
// Sequence (each step checked):
//   1  TAP: IDCODE after Test-Logic-Reset and with IR 0x01 = 0x10002FFF
//   2  dtmcs (IR 0x10): version 1, abits 7; idle hint used between scans
//   3  dmcontrol.dmactive = 1, read back; dmstatus version 2 (0.13),
//      authenticated, allrunning; ackhavereset clears the power-on havereset
//   4  haltreq -> dmstatus.allhalted
//   5  abstract command "access register" read x10 (regno 0x100A): equals
//      DM_CNT (or DM_CNT + 1: halted between addi and sw); x12 = boots = 1
//   6  2000 cycles later x10 and DM_CNT unchanged (the hart is halted)
//   7  resumereq -> allresumeack, allrunning; halt again: x10 grew
//   8  ndmreset: dmcontrol.ndmreset = 1 holds the core in reset
//      (rv_hostcpu core_rst), cleared -> the program restarts from 0x0;
//      all/anyhavereset set again, acknowledged; halt, x12 = boots = 2,
//      DM_BOOTS = 2
//   9  abstract command write x11 = x10 + N (regno 0x100B), read back;
//      complete = 1, resumereq: the loop runs N more iterations to DONE 0
//
// DMI (IR 0x11, 41 bits {addr[6:0], data[31:0], op[1:0]}): each access is
// a request scan, `idle` TCKs in Run-Test/Idle, then a nop scan whose
// captured op is the status (0 ok, 2 failed, 3 busy) and data the read
// value.  Busy: dtmcs.dmireset, idle + 4, retry (counted in the log).
module dm_smoke;
  localparam [31:0] IDCODE   = 32'h10002FFF;
  localparam [6:0]  DATA0    = 7'h04, DMCONTROL = 7'h10, DMSTATUS = 7'h11,
                    HARTINFO = 7'h12, ABSTRACTCS = 7'h16, COMMAND = 7'h17;
  localparam [31:0] DMACTIVE = 32'h1, NDMRESET = 32'h2, HALTREQ = 32'h8000_0000,
                    RESUMEREQ = 32'h4000_0000, ACKHAVERESET = 32'h1000_0000;
  localparam integer DM_CNT_W = 32'h4000 >> 2, DM_BOOTS_W = 32'h4004 >> 2;
  localparam integer N_MORE = 1000;

  reg         complete;   // the whole sequence ran; the tb checks it at DONE
  reg  [31:0] target;     // x11 written by the debugger: DM_CNT at DONE
  integer     idle, busy_retries, drop_cycles;   // drop_cycles: rising edges of drop
  reg  [63:0] r;
  reg  [31:0] v, dmctl, x10a, x10b, x10c, x12, cnt;
  integer     i;

  initial begin complete = 1'b0; target = 32'hFFFF_FFFF; busy_retries = 0; drop_cycles = 0; end

  function [31:0] swap32(input [31:0] w);
    swap32 = {w[7:0], w[15:8], w[23:16], w[31:24]};
  endfunction

  // memory words are BE (byte A+0 in bits 31:24): the core's value is swapped
  function [31:0] memval(input integer w);
    memval = swap32(tb_rv_l1.mem.mem[w]);
  endfunction

  // rv_hostcpu's drop flag rises when a core reset hits a bus transaction
  // (step 8; logged, not required: it depends on where the reset lands)
  reg drop_q;
  initial drop_q = 1'b0;
  always @(posedge tb_rv_l1.clk) begin
    if (tb_rv_l1.dut.drop && !drop_q) drop_cycles = drop_cycles + 1;
    drop_q <= tb_rv_l1.dut.drop;
  end

  task fail_dm(input [8*48-1:0] what, input [31:0] got);
    begin
      $display("=== FAIL dm %0s (got %08x) at %t", what, got, $time);
      tb_rv_l1.finish_run;
    end
  endtask

  // n rising clock edges, then 1.001 ns off the clock grid.  Every JTAG
  // edge follows a wait_clk by a multiple of 25 ns (TCK_NS / 2); the clock
  // edges are 4.408 ns apart (#4.4077 at 1 ps precision), and 25000 and 4408
  // share the factor 8 ps, so without the offset a TCK edge (and a sample of
  // tb_rv_l1.cycles) lands on a clock edge in the same time step now and
  // then, and the simulator's order of the two events decides on which side
  // of the edge the core sees it (iverilog and Verilator chose differently:
  // dm_smoke differed by one cycle).  1001 ps is 1 mod 8: a JTAG event can
  // never coincide with a clock edge.
  task wait_clk(input integer n);
    begin repeat (n) @(posedge tb_rv_l1.clk); #1.001; end
  endtask

  task dtmcs_dmireset;
    begin
      tb_rv_l1.bfm.jtag_ir(5, 5'h10);
      tb_rv_l1.bfm.jtag_dr(32, 64'h0001_0000, r);
      tb_rv_l1.bfm.jtag_ir(5, 5'h11);
    end
  endtask

  // one DMI access; IR must be 0x11
  task dmi(input [6:0] a, input [31:0] data, input [1:0] op, output [31:0] rdata);
    reg [1:0] st;
    integer tries;
    begin
      st = 2'd3; tries = 0;
      while (st == 2'd3) begin
        tb_rv_l1.bfm.jtag_dr(41, {23'h0, a, data, op}, r);
        tb_rv_l1.bfm.jtag_idle(idle);
        tb_rv_l1.bfm.jtag_dr(41, 64'h0, r);           // nop: fetch the status
        st = r[1:0]; rdata = r[33:2];
        if (st == 2'd2) fail_dm("dmi op failed", {25'h0, a});
        if (st == 2'd3) begin
          busy_retries = busy_retries + 1;
          tries = tries + 1;
          if (tries > 8) fail_dm("dmi busy, 8 retries", {25'h0, a});
          dtmcs_dmireset;
          idle = idle + 4;
        end
      end
    end
  endtask

  task dmi_wr(input [6:0] a, input [31:0] data);
    reg [31:0] dummy;
    begin dmi(a, data, 2'd2, dummy); end
  endtask

  task dmi_rd(input [6:0] a, output [31:0] data);
    begin dmi(a, 32'h0, 2'd1, data); end
  endtask

  // poll dmstatus until (dmstatus & mask) == mask
  task wait_status(input [31:0] mask, input [8*48-1:0] what);
    integer k;
    begin
      dmi_rd(DMSTATUS, v);
      k = 0;
      while ((v & mask) != mask) begin
        k = k + 1;
        if (k > 50) fail_dm(what, v);
        dmi_rd(DMSTATUS, v);
      end
    end
  endtask

  task halt;
    begin
      dmi_wr(DMCONTROL, DMACTIVE | HALTREQ);
      wait_status(32'h0000_0200, "allhalted after haltreq");
      dmi_wr(DMCONTROL, DMACTIVE);                    // haltreq back to 0
    end
  endtask

  task resume;
    begin
      dmi_wr(DMCONTROL, DMACTIVE | RESUMEREQ);
      wait_status(32'h0002_0800, "allresumeack+allrunning after resumereq");
      dmi_wr(DMCONTROL, DMACTIVE);
    end
  endtask

  // abstract command, wait for !busy, cmderr must be 0
  task abstract_cmd(input [31:0] cmd);
    integer k;
    begin
      dmi_wr(COMMAND, cmd);
      dmi_rd(ABSTRACTCS, v);
      k = 0;
      while (v[12]) begin
        k = k + 1;
        if (k > 50) fail_dm("abstractcs.busy stuck", v);
        dmi_rd(ABSTRACTCS, v);
      end
      if (v[10:8] != 3'd0) fail_dm("abstractcs.cmderr", v);
    end
  endtask

  // access register, 32 bit, transfer: read / write GPR x<n>
  task read_x(input [4:0] n, output [31:0] val);
    begin
      abstract_cmd(32'h0022_1000 | n);
      dmi_rd(DATA0, val);
    end
  endtask

  task write_x(input [4:0] n, input [31:0] val);
    begin
      dmi_wr(DATA0, val);
      abstract_cmd(32'h0023_1000 | n);
    end
  endtask

  initial begin
    // reset released at cycle 8; let the program start
    wait_clk(200);

    // 1  IDCODE
    tb_rv_l1.bfm.jtag_reset;
    tb_rv_l1.bfm.jtag_dr(32, 64'h0, r);
    if (r[31:0] != IDCODE) fail_dm("IDCODE after TLR", r[31:0]);
    tb_rv_l1.bfm.jtag_ir(5, 5'h01);
    tb_rv_l1.bfm.jtag_dr(32, 64'h0, r);
    if (r[31:0] != IDCODE) fail_dm("IDCODE with IR 0x01", r[31:0]);
    $display("=== DM 1 IDCODE %08x", r[31:0]);

    // 2  dtmcs
    tb_rv_l1.bfm.jtag_ir(5, 5'h10);
    tb_rv_l1.bfm.jtag_dr(32, 64'h0, r);
    if (r[3:0] != 4'd1) fail_dm("dtmcs.version != 1", r[31:0]);
    if (r[9:4] != 6'd7) fail_dm("dtmcs.abits != 7", r[31:0]);
    idle = r[14:12];
    $display("=== DM 2 dtmcs %08x version %0d abits %0d idle %0d", r[31:0], r[3:0], r[9:4], r[14:12]);
    tb_rv_l1.bfm.jtag_ir(5, 5'h11);

    // 3  dmactive, dmstatus
    dmi_wr(DMCONTROL, DMACTIVE);
    dmi_rd(DMCONTROL, v);
    i = 0;
    while (!v[0]) begin
      i = i + 1;
      if (i > 20) fail_dm("dmcontrol.dmactive reads 0", v);
      dmi_rd(DMCONTROL, v);
    end
    dmctl = v;
    dmi_rd(DMSTATUS, v);
    if (v[3:0] != 4'd2) fail_dm("dmstatus.version != 2", v);
    if (!v[7])          fail_dm("dmstatus.authenticated = 0", v);
    if (!v[11])         fail_dm("dmstatus.allrunning = 0", v);
    $display("=== DM 3 dmcontrol %08x dmstatus %08x", dmctl, v);
    // havereset is set from the power-on reset: acknowledge it, so step 8
    // sees the one ndmreset causes
    dmi_wr(DMCONTROL, DMACTIVE | ACKHAVERESET);
    dmi_rd(DMSTATUS, v);
    if (v[19:18] != 2'b00) fail_dm("anyhavereset after ackhavereset", v);
    dmi_rd(ABSTRACTCS, v);
    $display("=== DM   abstractcs %08x (datacount %0d progbufsize %0d)", v, v[3:0], v[28:24]);

    // 4  halt
    halt;
    $display("=== DM 4 halted, dmstatus %08x, cycle %0d", v, tb_rv_l1.cycles);

    // 5  read x10, x12
    read_x(5'd10, x10a);
    cnt = memval(DM_CNT_W);
    if (x10a == 32'd0 || !(x10a == cnt || x10a == cnt + 1)) fail_dm("x10 vs DM_CNT", x10a);
    read_x(5'd12, x12);
    if (x12 != 32'd1) fail_dm("x12 (boots) != 1", x12);
    $display("=== DM 5 x10 %0d DM_CNT %0d x12 %0d", x10a, cnt, x12);

    // 6  still halted
    wait_clk(2000);
    read_x(5'd10, v);
    if (v != x10a) fail_dm("x10 changed while halted", v);
    if (memval(DM_CNT_W) != cnt) fail_dm("DM_CNT changed while halted", memval(DM_CNT_W));
    $display("=== DM 6 after 2000 cycles x10 %0d DM_CNT %0d (unchanged)", v, memval(DM_CNT_W));

    // 7  resume, runs on
    resume;
    $display("=== DM 7 resumed, dmstatus %08x", v);
    wait_clk(3000);
    halt;
    read_x(5'd10, x10b);
    if (x10b <= x10a) fail_dm("x10 did not grow after resume", x10b);
    $display("=== DM 7 halted again: x10 %0d (+%0d)", x10b, x10b - x10a);
    resume;

    // 8  ndmreset: core held in reset, then restarts from 0x0
    wait_clk(500);
    dmi_wr(DMCONTROL, DMACTIVE | NDMRESET);
    wait_clk(20);
    if (tb_rv_l1.dut.core_rst !== 1'b1) fail_dm("ndmreset=1 but core_rst=0", 0);
    dmi_wr(DMCONTROL, DMACTIVE);
    wait_clk(20);
    if (tb_rv_l1.dut.core_rst !== 1'b0) fail_dm("ndmreset=0 but core_rst=1", 1);
    dmi_rd(DMSTATUS, v);
    $display("=== DM 8 ndmreset pulsed, dmstatus %08x (anyhavereset %0d), rv_hostcpu drop raised %0d time(s)",
             v, v[18], drop_cycles);
    if (v[19:18] != 2'b11) fail_dm("all/anyhavereset not set by ndmreset", v);
    dmi_wr(DMCONTROL, DMACTIVE | ACKHAVERESET);
    dmi_rd(DMSTATUS, v);
    if (v[19:18] != 2'b00) fail_dm("anyhavereset after ackhavereset", v);
    wait_clk(500);
    halt;
    read_x(5'd12, x12);
    if (x12 != 32'd2) fail_dm("x12 (boots) != 2 after ndmreset", x12);
    if (memval(DM_BOOTS_W) != 32'd2) fail_dm("DM_BOOTS != 2 after ndmreset", memval(DM_BOOTS_W));
    read_x(5'd10, x10c);
    cnt = memval(DM_CNT_W);
    if (x10c == 32'd0 || !(x10c == cnt || x10c == cnt + 1)) fail_dm("x10 vs DM_CNT after ndmreset", x10c);
    $display("=== DM 8 restarted: x12 (boots) %0d, x10 %0d", x12, x10c);

    // 9  stop value, resume to DONE
    target = x10c + N_MORE;
    write_x(5'd11, target);
    read_x(5'd11, v);
    if (v != target) fail_dm("x11 read back", v);
    $display("=== DM 9 x11 = %0d written; busy retries %0d; resuming for %0d iterations",
             target, busy_retries, N_MORE);
    complete = 1'b1;
    resume;
  end
endmodule
