//--------------------------------------------------------------------------//
// tb_kick.sv - a real Kickstart ROM on one AP68040 compat wrapper          //
//                                                                          //
// One build per core (the two trees share module names):                   //
//   default      lib/AP68040 rtl/ap040_tg68k_compat.v   (reference)        //
//   -DPIPE       AP68040-pipelined rtl/compat/ap040_pipe_tg68k_compat.v    //
// Both: AP040_HAS_MMU=0 AP040_ENABLE_CACHE=0, and AP040_HAS_FPU=0 unless    //
// -DKICK_FPU=1 is given.  The LC040 leg pins the parameter to 0 EXPLICITLY   //
// so the baseline cannot move when the wrapper's default changes; the        //
// KICK_FPU=1 leg exists to watch what AmigaOS does once Kickstart's          //
// `fsave -(a7)` probe answers with a real frame (PLAN.md Q17).               //
// AP040_POST_STORES=0 AP040_FILL_CHANNEL=0 AP040_BUS16=1, ipl = 111 (no    //
// interrupt), berr = 0, clkena_in = bus idle | ready (a pure bus wait).    //
// kick_sys.sv is the machine (memory map, wait states, chipset stub).      //
//                                                                          //
// +trace=<file>  one line per retired instruction, "state after it":       //
//     <n> <pc> <sr> d0..d7 a0..a6 a7          (a7 = the live stack pointer) //
//   reference: the line for instruction k is written at the DECODE of      //
//              k+1 (dut.core.state == S_DECODE), when every register write //
//              of k has landed (a write on that very edge is read through, //
//              as findings/ap040-pipelined/tests/tb_ap040_ref_trace.v)     //
//   pipelined: written one clock after the edge where WB retires the last  //
//              micro-op of k (ce && retire && exe_o.last)                   //
//   X <vec> <fmt> <sr> <pc>   exception entry, decoded from the frame in   //
//              memory (reference: at S_EXC_VEC; pipelined: one clock after //
//              the exception micro-op commits).  It precedes the line of   //
//              the instruction that took it.                               //
//   W <n> <addr> <size> <data>   every bus write (16-bit adapter,          //
//              qualified cycle), n = instructions retired so far          //
//   R <n> <addr> <data>          every DATA read of $A00000-$DFFFFF        //
// +maxinsn=<n> (default 5000000)  +maxcycles=<n> (default 400000000)       //
// +stall=<n>   stop when nothing retires for n clocks (default 200000)     //
// +regs=0      write only pc/sr per instruction (smaller trace)            //
//   I <n> <level>  the CPU leaves STOP for an interrupt of that level      //
// Interrupts reach the CPU only while it is stopped (kick_sys.sv); the run //
// ends at the first DSKLEN write with DMAEN (+disk=1) or on a budget.      //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

module tb_kick;

reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0;

wire [15:0] data_in;
wire [31:0] addr_out;
wire [15:0] data_write;
wire        nwr, nuds, nlds;
wire  [1:0] busstate;
wire        longword, nresetout;
wire  [2:0] fc;
wire [31:0] cacr_out, vbr_out;
wire        debug_busy, debug_fault, debug_halted;
wire [255:0] debug_status;
wire        ready;
wire        clkena_in = (busstate == 2'b01) | ready;
wire  [2:0] ipl_n, irq_level;
wire        cpu_stopped, dsk_start;

`ifdef PIPE
ap040_pipe_tg68k_compat
`else
ap040_tg68k_compat
`endif
`ifndef KICK_FPU
 `define KICK_FPU 0
`endif
// KICK_ALLOW=1: everything cacheable (cache_allow_all), so the board leg's
// internal caches -- and the M14 read paths -- serve the ROM and chip RAM
`ifndef KICK_ALLOW
 `define KICK_ALLOW 1'b0
`endif
`ifdef KICK_BOARD
// the board's wrapper parameters (TG68K.vhd, AP040_PIPE_MMU=1): MMU, caches
// and posted stores on -- the 2026-09-23 black-screen hunt
#(
	.AP040_HAS_MMU(1), .AP040_HAS_FPU(`KICK_FPU), .AP040_ENABLE_CACHE(1),
	.AP040_FAST_SIM(0), .AP040_POST_STORES(1), .AP040_FILL_CHANNEL(0), .AP040_BUS16(1)
)
`else
#(
	.AP040_HAS_MMU(0), .AP040_HAS_FPU(`KICK_FPU), .AP040_ENABLE_CACHE(0),
	.AP040_FAST_SIM(0), .AP040_POST_STORES(0), .AP040_FILL_CHANNEL(0), .AP040_BUS16(1)
)
`endif dut (
	.clk(clk), .nreset(nreset), .clkena_in(clkena_in),
	.cache_allow_all(`KICK_ALLOW),
	.cache_snoop_stb(1'b0), .cache_snoop_addr(32'd0),
	.cache_z2_ena(1'b0), .cache_z3_base0(5'd0), .cache_z3_ena0(1'b0),
	.cache_z3_base1(4'd0), .cache_z3_ena1(1'b0),
	.data_in(data_in), .ipl(ipl_n), .ipl_autovector(1'b1), .berr(1'b0),
	.addr_out(addr_out), .data_write(data_write),
	.nwr(nwr), .nuds(nuds), .nlds(nlds), .busstate(busstate),
	.longword(longword), .nresetout(nresetout), .fc(fc),
	.nmi_ack_toggle(),
	.fill_ena_zorro(1'b0), .fill_ena_chip(1'b0), .fill_req(), .fill_addr(),
	.fill_data(128'd0), .fill_ack(1'b0), .fill_err(1'b0),
	.cache_maint_req(), .cache_maint_ic(), .cache_maint_dc(),
	.mmu_addr_log(), .mmu_addr_phys(), .mmu_cache_inhibit(),
	.walker_req(), .walker_we(), .walker_addr(), .walker_wdat(),
	.walker_ack(1'b0), .walker_data(32'd0), .walker_berr(1'b0),
	.cache_req(), .cache_addr(), .cache_data(16'd0), .cache_ack(1'b0),
	.cache_burst(), .cache_burst_len(), .cache_ramaddr(),
	.cacr_out(cacr_out), .vbr_out(vbr_out),
	.debug_busy(debug_busy), .debug_fault(debug_fault), .debug_halted(debug_halted),
	.debug_status(debug_status), .debug_status2(),
	.m_req(), .m_write(), .m_instr(), .m_size(), .m_addr(), .m_wdata(), .m_fc(),
	.m_ack(1'b0), .m_rdata(32'd0)
);

wire        ovl;
wire [63:0] io_count, cck;
kick_sys sys (
	.clk(clk), .nreset(nreset),
	.addr(addr_out), .busstate(busstate), .nwr(nwr), .nuds(nuds), .nlds(nlds),
	.wdata(data_write), .rdata(data_in), .ready(ready),
	.ovl(ovl), .io_count(io_count), .cck(cck),
	.stopped(cpu_stopped), .mask(dbg_sr[10:8]), .ipl_n(ipl_n), .level(irq_level),
	.rsto_n(nresetout), .dsk_start(dsk_start)
);

wire [31:0] dbg_pc = debug_status[31:0];
wire [15:0] dbg_sr = debug_status[47:32];
wire [31:0] dbg_a7 = debug_status[95:64];

// memory view for exception frames (supervisor stack is in chip RAM)
function [15:0] mw(input [31:0] a);
	mw = (a[31:21] == 0) ? sys.chip[a[20:1]] : 16'hFFFF;
endfunction

string tracef;
integer fd, k, want_regs;
longint max_insn, max_cycles, stall_lim, cycles, n_ret, last_ret_cycle;
reg done = 0;
reg [31:0] r_val [0:15];
reg [15:0] r_sr;

task automatic put_insn(input [31:0] pc);
	begin
		$fwrite(fd, "%0d %08x %04x", n_ret, pc, r_sr);
		if (want_regs != 0)
			for (k = 0; k < 16; k = k + 1) $fwrite(fd, " %08x", r_val[k]);
		$fwrite(fd, "\n");
		n_ret = n_ret + 1;
		last_ret_cycle = cycles;
	end
endtask

task automatic put_exc(input [31:0] sp);
	reg [15:0] fv;
	begin
		fv = mw(sp + 6);
		$fwrite(fd, "X %02x %1x %04x %08x\n", fv[9:2], fv[15:12], mw(sp), {mw(sp + 2), mw(sp + 4)});
	end
endtask

// the STOP state, with the SR the STOP loaded committed
`ifdef PIPE
assign cpu_stopped = dut.core.eaf_stopped && !dut.core.older_busy;
`else
assign cpu_stopped = (dut.core.state == 8'd7);      // S_STOPPED
`endif

`ifdef PIPE
//------------------------------------------------------------ pipelined probes
reg        ev_q = 0, ev_exc = 0;
reg [31:0] ev_pc, ev_sp;
wire [15:0] p_sr = dut.core.sr;
wire [31:0] p_a7 = !p_sr[13] ? dut.core.u_regfile.usp :
                    p_sr[12] ? dut.core.u_regfile.msp : dut.core.u_regfile.isp;
always @(posedge clk) begin
	if (nreset && !done && ev_q) begin
		// the edge that retired ev_pc has passed: registers hold its result
		for (k = 0; k < 8; k = k + 1) r_val[k] = dut.core.u_regfile.dreg[k];
		for (k = 0; k < 7; k = k + 1) r_val[8 + k] = dut.core.u_regfile.areg[k];
		r_val[15] = p_a7;
		r_sr = p_sr;
		if (ev_exc) put_exc(ev_sp);
		if (ev_pc != 32'hFFFF_FFFF) put_insn(ev_pc);     // the reset micro-op
	end
	ev_q   <= nreset && dut.core.ce && dut.core.retire && dut.core.exe_o.last;
	ev_pc  <= dut.core.exe_o.pc;
	ev_exc <= dut.core.exe_o.exc;
	ev_sp  <= dut.core.exe_o.exc_sp;
end
`else
//------------------------------------------------------------ reference probes
localparam S_DECODE  = 8'd4;
localparam S_EXC_VEC = 8'd41;
localparam S_AERR_WR = 8'd111;
reg  [7:0] last_state = 8'hFF;
reg        have_prev = 0;
reg [31:0] prev_pc;
function [31:0] rreg(input [3:0] r);
	begin
		if (dut.core.regfile.ce && dut.core.regfile.we && dut.core.regfile.waddr == r)
			rreg = dut.core.regfile.wdata;
		else if (r == 4'd15) rreg = dbg_a7;
		else if (!r[3]) rreg = dut.core.regfile.dreg[r[2:0]];
		else            rreg = dut.core.regfile.areg[r[2:0]];
	end
endfunction
always @(posedge clk) begin
	if (nreset && !done && dut.core.ce) begin
		if (dut.core.state == S_EXC_VEC && last_state != S_EXC_VEC)
			put_exc((last_state == S_AERR_WR) ? dut.core.aer_sp : dut.core.exc_sp);
		if (dut.core.state == S_DECODE) begin
			if (have_prev) begin
				for (k = 0; k < 16; k = k + 1) r_val[k] = rreg(k[3:0]);
				r_sr = dbg_sr;
				put_insn(prev_pc);
			end
			have_prev = 1;
			prev_pc = dut.core.pc_i;
		end
		last_state = dut.core.state;
	end
end
`endif

//------------------------------------------------------------ bus writes / IO reads
reg stopped_q = 0;
always @(posedge clk) begin
	stopped_q <= cpu_stopped;
	if (nreset && !done && stopped_q && !cpu_stopped)
		$fwrite(fd, "I %0d %0d\n", n_ret, irq_level);
end
always @(posedge clk) begin
	if (nreset && !done && ready) begin
		if (busstate == 2'b11) begin
			if (!nuds && !nlds)
				$fwrite(fd, "W %0d %08x 2 %04x\n", n_ret, {addr_out[31:1], 1'b0}, data_write);
			else if (!nuds)
				$fwrite(fd, "W %0d %08x 1 %02x\n", n_ret, {addr_out[31:1], 1'b0}, data_write[15:8]);
			else if (!nlds)
				$fwrite(fd, "W %0d %08x 1 %02x\n", n_ret, {addr_out[31:1], 1'b1}, data_write[7:0]);
		end
		else if (busstate == 2'b10 && addr_out[31:24] == 0 &&
		         (addr_out[23:21] == 3'b101 || addr_out[23:21] == 3'b110))
			$fwrite(fd, "R %0d %08x %04x\n", n_ret, addr_out, data_in);
	end
end

// a CPU stopped with no level above its mask can only be woken by device
// time, which the stub then runs forward; if that does not produce an
// interrupt within +stopidle= colour clocks (default ~10 frames), the run is
// over rather than spinning to the cycle budget
longint stop_idle, stop_idle_lim, cck_q;
always @(posedge clk) begin
	if (!nreset) begin stop_idle <= 0; cck_q <= 0; end
	else begin
		cck_q <= cck;
		if (!cpu_stopped || irq_level > dbg_sr[10:8]) stop_idle <= 0;
		else if (cck != cck_q) stop_idle <= stop_idle + 1;
	end
end

`ifdef PIPE
// +hangdump=N: when nothing has retired for N clocks (and the core is not
// stopped), print the pipeline's state once per 64 clocks, 16 times
// (2026-09-23 black-screen hunt: an interrupt entry that never starts)
longint hang_n;
integer hang_k = 0;
initial if (!$value$plusargs("hangdump=%d", hang_n)) hang_n = 0;
always @(posedge clk) if (cycles - last_ret_cycle <= hang_n || cpu_stopped) hang_k = 0;
always @(posedge clk) if (nreset && !done && hang_n != 0 && hang_k < 16 && !cpu_stopped &&
                          cycles - last_ret_cycle > hang_n + 64 * hang_k) begin
	hang_k = hang_k + 1;
	$display("HANG c=%0d stopped_tb=%b ph=%0d eac_valid=%b eac_pc=%08x eaf_valid=%b exe_valid=%b sb_busy=%b older_busy=%b id_valid=%b q_v0=%b q_pc0=%08x",
	         cycles, cpu_stopped, dut.core.u_eaf.ph, dut.core.eac_valid, dut.core.eac_o.i.pc,
	         dut.core.eaf_valid, dut.core.exe_valid, dut.core.sb_busy, dut.core.older_busy,
	         dut.core.id_valid, dut.core.q_v0, dut.core.q_pc0);
	$display("     irq_req=%b irq_lvl=%0d irq_take=%b rst_pending=%b x_step=%0d stopped=%b f_req=%b mem_req=%b ce=%b sr=%04x ea_stall=%b eaf_stall=%b",
	         dut.core.irq_req, dut.core.irq_lvl, dut.core.u_eaf.irq_take,
	         dut.core.u_eaf.rst_pending, dut.core.u_eaf.x_step, dut.core.eaf_stopped,
	         dut.core.f_req, dut.core.mem_req, dut.core.ce, dut.core.sr,
	         dut.core.ea_stall, dut.core.eaf_stall);
end
`endif

//------------------------------------------------------------ run
always @(posedge clk) if (nreset && !done) begin
	cycles = cycles + 1;
	// a stopped CPU is not stalled: count the stall from the wake-up (with
	// +irqlive=1 a STOP can outlast +stall=, and the run then ended the
	// instant the CPU woke -- 2026-09-23)
	if (cpu_stopped) last_ret_cycle = cycles;
	if (n_ret >= max_insn) begin done = 1; $display("STOP: instruction budget reached"); end
	else if (cycles >= max_cycles) begin done = 1; $display("STOP: cycle budget reached"); end
	else if (cycles - last_ret_cycle > stall_lim && !cpu_stopped) begin
		done = 1;
		$display("STOP: nothing retired for %0d clocks (busstate=%b addr=%08x)", stall_lim, busstate, addr_out);
	end
	else if (debug_halted) begin done = 1; $display("STOP: core halted (double fault)"); end
	else if (dsk_start) begin done = 1; $display("STOP: first DSKLEN write with DMAEN (trackdisk's first track read)"); end
	else if (stop_idle > stop_idle_lim) begin
		done = 1;
		$display("STOP: the CPU has been stopped for %0d colour clocks with nothing above its mask (sr=%04x intena=%04x intreq=%04x)",
		         stop_idle, dbg_sr, sys.intena, sys.intreq);
	end
end

initial begin
	if (!$value$plusargs("trace=%s", tracef)) tracef = "kick_trace.txt";
	if (!$value$plusargs("maxinsn=%d", max_insn)) max_insn = 5000000;
	if (!$value$plusargs("maxcycles=%d", max_cycles)) max_cycles = 400000000;
	if (!$value$plusargs("stall=%d", stall_lim)) stall_lim = 200000;
	if (!$value$plusargs("stopidle=%d", stop_idle_lim)) stop_idle_lim = 227 * 313 * 10;
	if (!$value$plusargs("regs=%d", want_regs)) want_regs = 1;
	fd = $fopen(tracef, "w");
`ifdef PIPE
	$fwrite(fd, "# core: pipelined (ap040_pipe_tg68k_compat)\n");
`else
	$fwrite(fd, "# core: reference (lib/AP68040 ap040_tg68k_compat)\n");
`endif
	$fwrite(fd, "# n pc sr d0 d1 d2 d3 d4 d5 d6 d7 a0 a1 a2 a3 a4 a5 a6 a7 (state after the instruction)\n");
	n_ret = 0; cycles = 0; last_ret_cycle = 0;
	repeat (4) @(posedge clk);
	nreset = 1;
	wait (done);
	@(posedge clk);
	$fclose(fd);
	$display("SUMMARY instructions=%0d cycles=%0d io_accesses=%0d colour_clocks=%0d frames=%0d",
	         n_ret, cycles, io_count, cck, sys.frame);
	$display("SUMMARY last_pc=%08x sr=%04x a7=%08x vbr=%08x cacr=%08x ovl=%0d",
	         dbg_pc, dbg_sr, dbg_a7, vbr_out, cacr_out, ovl);
	$display("SUMMARY intena=%04x intreq=%04x dmacon=%04x ciaa_icrmask=%02x ciab_icrmask=%02x",
	         sys.intena, sys.intreq, sys.dmacon, sys.icrmask[0], sys.icrmask[1]);
	$display("SUMMARY df0 cyl=%0d motor=%b chng_n=%0d dsk_start=%0d",
	         sys.cyl, sys.mtr, sys.chng_n, dsk_start);
	$finish;
end

`ifdef KICK_DBG
// M14 debug: every fast instruction answer against the ROM / chip RAM image
reg [31:0] dbg_a, dbg_e;
`ifdef KICK_DBG_IFP
always @(posedge clk) if (dut.ce_core && dut.core.g_bus.g_ifp.fast) begin
	dbg_a = {dut.core.g_bus.g_ifp.ifp_a[31:2], 2'b00};
	if (dbg_a >= 32'h00F80000 && dbg_a < 32'h01000000)
		dbg_e = {sys.rom[(dbg_a - 32'h00F80000) >> 1], sys.rom[((dbg_a - 32'h00F80000) >> 1) + 1]};
	else
		dbg_e = {sys.chip[dbg_a[20:1]], sys.chip[dbg_a[20:1] + 1]};
	if (dut.ifp_data !== dbg_e)
		$display("IFPBAD t=%0t a=%h got=%h mem=%h", $time, dut.core.g_bus.g_ifp.ifp_a, dut.ifp_data, dbg_e);
end
`endif
// every answer IF takes, against the image (ROM only: RAM may be stale by design)
reg [31:0] dbg_fa, dbg_fe;
always @(posedge clk) if (dut.ce_core && dut.core.u_if.infl && dut.core.f_ack && !dut.core.f_err) begin
	dbg_fa = dut.core.u_if.f_fa;
	if (dbg_fa >= 32'h00F80000 && dbg_fa < 32'h01000000) begin
		dbg_fe = (dut.core.u_if.infl_n == 2'd2) ?
		         {sys.rom[(dbg_fa - 32'h00F80000) >> 1], sys.rom[((dbg_fa - 32'h00F80000) >> 1) + 1]} :
		         {sys.rom[(dbg_fa - 32'h00F80000) >> 1], 16'h4E71};
		if (dut.core.f_data !== dbg_fe)
			$display("IFBAD t=%0t fa=%h n=%0d got=%h rom=%h", $time, dbg_fa, dut.core.u_if.infl_n, dut.core.f_data, dbg_fe);
	end
end
`ifdef KICK_DBG_T0
always @(posedge clk) if ($time >= 64'd`KICK_DBG_T0 && $time <= 64'd`KICK_DBG_T1)
	$display("T %0t rd=%b %h early=%b a0=%h wbpc=%h wbv=%b | ce=%b rv=%b rpc=%h soon=%b | freq=%b fa=%h gnt=%b infl=%b fdrop=%b ack=%b fd=%h look=%b hit=%b try=%b mreq=%b minfl=%b | qcnt=%0d qpc=%h cons=%0d | id=%b %h eac=%b %h eaf=%b %h ex=%b %h",
		$time, dut.core.d_rd_req, dut.core.d_rd_addr, dut.core.early_v, dut.core.dbg_a0, dut.core.wb_pc, dut.core.wb_valid, dut.ce_core, dut.core.redirect_valid, dut.core.redirect_pc, dut.core.eaf_redir_soon,
		dut.core.f_req, dut.core.f_addr, dut.core.f_gnt, dut.core.u_if.infl, dut.core.u_if.fdrop, dut.core.f_ack, dut.core.f_data,
		dut.core.g_bus.g_ifp.ifp_look, dut.ifp_hit, 1'b0, dut.core.g_bus.g_ifp.ifp_mreq, dut.core.g_bus.g_ifp.ifp_minfl,
		dut.core.u_if.qcnt, dut.core.u_if.qpc, dut.core.id_consume,
		dut.core.id_valid, dut.core.dbg_id_pc, dut.core.eac_valid, dut.core.dbg_eac_pc, dut.core.eaf_valid, dut.core.dbg_eaf_pc, dut.core.exe_valid, dut.core.dbg_ex_pc);
`endif
reg [31:0] dbg_ra;
always @(posedge clk) if (dut.ce_core) begin
	if (dut.core.d_rd_req) dbg_ra = dut.core.d_rd_addr;
	if (dut.core.d_rd_ack && dbg_ra[31:8] == 24'h000046)
		$display("RD t=%0t a=%h data=%h mem=%h", $time, dbg_ra, dut.core.d_rd_data, sys.chip[dbg_ra[20:1]]);
end
`endif
endmodule
