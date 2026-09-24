//--------------------------------------------------------------------------//
// tb_dat_replay_pipe.v - WinUAE cputest corpus replay for the PIPELINED    //
// AP68040 core (ap040_pipe_core, Minimig plan M0.4).                        //
//                                                                          //
// Consumes the APR2 job files that apolkosnik's diff/replay_gen.py writes   //
// (one per corpus slice) and mirrors the checks of his reference-core      //
// driver tb_dat_replay.v: D0-D7, A0-A6, A7 (= USP, as the reference bench  //
// compares it), SR under the corpus' SR mask, the exception vector, the    //
// exception frame bytes under their masks (or the stacked end PC for a     //
// normally completing test), and every CT_MEMWRITE value.  Memory is      //
// ap040_pipe_l1_replay.v (module ap040_pipe_l1, compiled instead of the    //
// RTL one).                                                                //
//                                                                          //
// One round:                                                               //
//   1. patches/toggles from the record applied to the model memory         //
//   2. reset with the boot overlay: ISP <- (0) = i_ssp, PC <- (4) = SYN,  //
//      a stub of NOPs then JMP (abs.L) to the round's PC                  //
//   3. when the first stub NOP retires, all registers, SR, VBR, SFC, DFC,  //
//      CACR are poked (the NOPs and the JMP use no register; the bench      //
//      checks that no stage already holds a non-stub instruction)          //
//   4. run until the final micro-op of an exception entry reaches WB       //
//      (exe_valid && exe_o.exc).  In that clock nothing of the entry is     //
//      architectural yet except its frame stores (already in memory): the  //
//      registers and SR are the state at the exception, which is what the  //
//      native runner and the reference bench (S_EXC0 snapshot) compare.   //
//      A normally completing test ends with the ILLEGAL placed after it    //
//      (vector 4 at the end PC).                                           //
//   5. compare, restore CT_MEMWRITE locations, apply post/cleanup patches.  //
//                                                                          //
// SKIPPED and counted (never failed): trace (T1/T0 in the input or        //
// expected SR, a trace record, or vector 9), bus error (vector 2),        //
// odd-vector groups.  Interrupt rounds RUN since 2026-09-24 (IRQ=1, the   //
// round's level on the pins from the stub's JMP on).  FPU state is not     //
// checked (the integer corpus has fpu_model = 0).                          //
//                                                                          //
// Plusargs: +job= +lmem= +tmem= [+limit=N] [+start=N] [+report=N]          //
//           [+strictwrites] (writes outside CT_MEMWRITE/frame = mismatch)  //
//           [+trace_round=N] (per-clock pipeline trace of record N)        //
//           [+mutate_reg=K] (MUTATION CHECK: corrupt expected register K,  //
//                            0-15, of every executed round)                //
//--------------------------------------------------------------------------//
`timescale 1ns/1ns

module tb_dat_replay_pipe;

import ap040_pipe_pkg::*;

localparam [31:0] SYN      = 32'h7F00_0000;   // boot stub
localparam [31:0] SYN_VBR  = SYN + 32'h400;   // vector table
localparam [31:0] SYN_HAND = SYN + 32'h800;   // handlers (8 bytes each)
localparam integer STUB_NOPS = 12;
localparam [31:0] STUB_JMP = SYN + 2 * STUB_NOPS;
localparam [31:0] RND2     = 32'h524E4432;
localparam [31:0] F_FPU        = 32'h0000_0001;
localparam [31:0] F_IGNORE_EXC = 32'h0000_0002;
localparam integer EXEC_TIMEOUT = 3000;

reg clk = 0;
reg nreset = 0;
always #5 clk = ~clk;

wire        dbg_if_valid, dbg_id_valid, dbg_eac_valid, dbg_eaf_valid, dbg_ex_valid, dbg_wb_valid;
wire [31:0] dbg_if_pc, dbg_id_pc, dbg_eac_pc, dbg_eaf_pc, dbg_ex_pc, dbg_wb_pc;
wire [31:0] dbg_d0, dbg_d1, dbg_d2, dbg_d3, dbg_d4, dbg_d5, dbg_d6, dbg_d7;
wire  [4:0] dbg_ccr; wire [15:0] dbg_sr;

// (2026-09-24) the interrupt inputs are LIVE: the IRQ corpus rounds run
// (they were skipped "because the core has no such feature yet", a claim
// that stopped being true with the M9 subset -- PLAN.md's stale filter)
reg  [2:0] ipl = 3'b111;
ap040_pipe_core #(.PC_RESET(32'h0), .PROG_WORDS(32'h7FFF_FFFF), .L1_AW(31),
                  .RESET_FROM_VECTORS(1), .IRQ(1)) dut (
	.clk(clk), .nreset(nreset), .ce(1'b1), .ipl(ipl),
	.dbg_if_valid(dbg_if_valid), .dbg_if_pc(dbg_if_pc), .dbg_id_valid(dbg_id_valid), .dbg_id_pc(dbg_id_pc),
	.dbg_eac_valid(dbg_eac_valid), .dbg_eac_pc(dbg_eac_pc), .dbg_eaf_valid(dbg_eaf_valid), .dbg_eaf_pc(dbg_eaf_pc),
	.dbg_ex_valid(dbg_ex_valid), .dbg_ex_pc(dbg_ex_pc), .dbg_wb_valid(dbg_wb_valid), .dbg_wb_pc(dbg_wb_pc),
	.dbg_d0(dbg_d0), .dbg_d1(dbg_d1), .dbg_d2(dbg_d2), .dbg_d3(dbg_d3),
	.dbg_d4(dbg_d4), .dbg_d5(dbg_d5), .dbg_d6(dbg_d6), .dbg_d7(dbg_d7), .dbg_ccr(dbg_ccr), .dbg_sr(dbg_sr));

//--------------------------------------------------------------- memory helpers
function [7:0] rd8(input [31:0] a);
	rd8 = dut.u_l1.rd8(a);
endfunction

integer errors, ran, mism, bad_rounds, report_lim;
integer skip_ign, skip_trace, skip_irq, skip_berr, skip_odd;
integer extra_writes_total, extra_write_rounds;
integer round_mism;
integer timeout, trace_round, mutate_reg, dump_lim;
reg strict;

task write_byte(input [31:0] a, input [7:0] v);
	reg ok;
	begin
		dut.u_l1.wr8(a, v, ok);
		if (!ok) begin
			$display("HARNESS: patch outside corpus memory: %08x", a);
			errors = errors + 1;
		end
	end
endtask

task apply_value(input [31:0] a, input [7:0] sz, input [31:0] v);
	integer nb, bi;
	begin
		nb = (sz == 0) ? 1 : (sz == 1) ? 2 : 4;
		for (bi = 0; bi < nb; bi = bi + 1)
			write_byte(a + bi, v >> (8 * (nb - 1 - bi)));
	end
endtask

function [31:0] read_value(input [31:0] a, input [7:0] sz);
	if (sz == 0) read_value = {24'd0, rd8(a)};
	else if (sz == 1) read_value = {16'd0, rd8(a), rd8(a+1)};
	else read_value = {rd8(a), rd8(a+1), rd8(a+2), rd8(a+3)};
endfunction

//--------------------------------------------------------------- APR2 input
integer jf, jn, jr, k, n, fgot, lmfd, tmfd;
reg [2047:0] job_file, lmem_file, tmem_file;

function [7:0] jread8(input integer dummy);
	integer r;
	begin
		r = $fgetc(jf);
		if (r < 0) begin $display("FAIL: unexpected EOF"); $finish; end
		jread8 = r[7:0];
	end
endfunction
function [15:0] jread16(input integer dummy); jread16 = {jread8(0), jread8(0)}; endfunction
function [31:0] jread32(input integer dummy); jread32 = {jread16(0), jread16(0)}; endfunction

reg [31:0] flags, test_idx, round_idx;
reg [31:0] i_regs [0:15];
reg [31:0] i_sr, i_pc, i_ssp, i_msp, i_fpcr, i_fpsr, i_fpiar, dummy32;
reg [31:0] e_regs [0:15];
reg [31:0] e_sr, e_srmask, e_fpcr, e_fpsr, e_fpiar, e_pc;
reg  [7:0] e_exc, e_trace, e_group2, i_level;
reg [15:0] e_trace_sr, e_trace_srmask;
reg [31:0] e_trace_pc;
reg  [7:0] frame_b [0:255];
reg  [7:0] frame_m [0:255];
integer    frame_len;
reg [31:0] em_a [0:255]; reg [7:0] em_sz [0:255]; reg [31:0] em_v [0:255]; reg [31:0] em_old [0:255];
integer    em_cnt;
reg [31:0] post_a [0:255]; reg [15:0] post_n [0:255]; reg [15:0] post_off [0:255]; reg [7:0] post_b [0:8191];
integer    post_cnt, post_bytes;
reg [31:0] clean_a [0:255]; reg [15:0] clean_n [0:255]; reg [15:0] clean_off [0:255]; reg [7:0] clean_b [0:8191];
integer    clean_cnt, clean_bytes;
reg [31:0] odd_vector;

task read_apply_patches;
	integer pcnt, pi, pj, plen;
	reg [31:0] pa;
	begin
		pcnt = jread16(0);
		for (pi = 0; pi < pcnt; pi = pi + 1) begin
			pa = jread32(0); plen = jread16(0);
			for (pj = 0; pj < plen; pj = pj + 1) write_byte(pa + pj, jread8(0));
		end
	end
endtask

task read_post_patches;
	integer pi, pj;
	begin
		post_cnt = jread16(0); post_bytes = 0;
		for (pi = 0; pi < post_cnt; pi = pi + 1) begin
			post_a[pi] = jread32(0); post_n[pi] = jread16(0); post_off[pi] = post_bytes;
			for (pj = 0; pj < post_n[pi]; pj = pj + 1) begin
				if (post_bytes >= 8192) begin $display("FAIL: post patch overflow"); $finish; end
				post_b[post_bytes] = jread8(0); post_bytes = post_bytes + 1;
			end
		end
	end
endtask

task read_clean_patches;
	integer pi, pj;
	begin
		clean_cnt = jread16(0); clean_bytes = 0;
		for (pi = 0; pi < clean_cnt; pi = pi + 1) begin
			clean_a[pi] = jread32(0); clean_n[pi] = jread16(0); clean_off[pi] = clean_bytes;
			for (pj = 0; pj < clean_n[pi]; pj = pj + 1) begin
				if (clean_bytes >= 8192) begin $display("FAIL: cleanup patch overflow"); $finish; end
				clean_b[clean_bytes] = jread8(0); clean_bytes = clean_bytes + 1;
			end
		end
	end
endtask

task apply_deferred;
	integer pi, pj;
	begin
		for (pi = 0; pi < post_cnt; pi = pi + 1)
			for (pj = 0; pj < post_n[pi]; pj = pj + 1)
				write_byte(post_a[pi] + pj, post_b[post_off[pi] + pj]);
		for (pi = 0; pi < clean_cnt; pi = pi + 1)
			for (pj = 0; pj < clean_n[pi]; pj = pj + 1)
				write_byte(clean_a[pi] + pj, clean_b[clean_off[pi] + pj]);
	end
endtask

//--------------------------------------------------------------- synthetic area
task setup_synthetic;
	integer v;
	begin
		for (v = 0; v < STUB_NOPS; v = v + 1) apply_value(SYN + 2 * v, 1, 16'h4E71);
		apply_value(STUB_JMP, 1, 16'h4EF9);            // JMP (xxx).L, target per round
		apply_value(STUB_JMP + 2, 2, 32'h0);
		apply_value(STUB_JMP + 6, 1, 16'h60FE);         // never reached
		for (v = 0; v < 256; v = v + 1) begin
			// an odd-vector job (ODD_IRQ, ODD_EXC): every vector from 4 up
			// points at the job's odd address, as lib/AP68040's
			// tb_dat_replay.v models it
			apply_value(SYN_VBR + 4 * v, 2, (odd_vector != 0 && v >= 4) ? odd_vector : SYN_HAND + 8 * v);
			apply_value(SYN_HAND + 8 * v, 1, 16'h60FE);   // BRA.S * (never run: the bench stops at entry)
			apply_value(SYN_HAND + 8 * v + 2, 1, 16'h4E71);
		end
	end
endtask

//--------------------------------------------------------------- capture
reg        cap_armed, cap_done;
reg [31:0] cap_regs [0:15];
reg [15:0] cap_sr;
reg [31:0] cap_sp;
reg [31:0] cap_pc;          // pc of the exception entry micro-op (instruction that faulted)
integer    ci;

// An IRQ round whose recorded result is the INTERRUPT may first take a
// synchronous exception (a privileged SR move in user mode, say): the
// request is still pending, and the 68040 takes it at the handler's first
// instruction boundary (WinUAE's generator checks the IPL after the
// Exception() of the tested instruction).  So such a round is captured at
// the interrupt's entry, not at the first one.
// The same holds for an odd-vector round (ODD_IRQ): the interrupt's entry
// comes first and the recorded result is the ADDRESS ERROR its handler fetch
// takes.  So in both kinds of round an entry whose vector is not the one the
// corpus recorded is passed over; a genuinely wrong vector then shows as a
// timeout instead of a vector mismatch, which is still a failing round.
// (computed in the block, not by a continuous assignment: a function over
// the memory model would not be re-evaluated when the frame lands)
reg [15:0] entry_fw;
reg        nested_ok;
always @(negedge clk) begin
	entry_fw  = {rd8(dut.exe_o.exc_sp + 6), rd8(dut.exe_o.exc_sp + 7)};
	nested_ok = ((e_exc >= 24 && e_exc <= 31) || odd_vector != 0) && (entry_fw[11:2] != e_exc);
	if (cap_armed && !cap_done && nreset && dut.exe_valid && dut.exe_o.exc && !nested_ok) begin
		for (ci = 0; ci < 8; ci = ci + 1) begin
			cap_regs[ci] = dut.u_regfile.dreg[ci];
			cap_regs[8+ci] = (ci == 7) ? dut.u_regfile.usp : dut.u_regfile.areg[ci];
		end
		cap_sr = dut.sr;
		cap_sp = dut.exe_o.exc_sp;
		cap_pc = dut.exe_o.pc;
		cap_done = 1;
	end
end

//--------------------------------------------------------------- checks
task dump_round;
	integer di;
	begin
		$display("  ROUND j%0d t%0d r%0d  pc=%08x op=%02x%02x %02x%02x %02x%02x %02x%02x %02x%02x  in-SR=%04x ISP=%08x MSP=%08x end=%02x%02x%02x%02x",
		         jr, test_idx, round_idx, i_pc, rd8(i_pc), rd8(i_pc+1), rd8(i_pc+2), rd8(i_pc+3),
		         rd8(i_pc+4), rd8(i_pc+5), rd8(i_pc+6), rd8(i_pc+7), rd8(i_pc+8), rd8(i_pc+9),
		         i_sr[15:0], i_ssp, i_msp, rd8(e_pc), rd8(e_pc+1), rd8(e_pc+2), rd8(e_pc+3));
		for (di = 0; di < 16; di = di + 1)
			$display("    %s%0d in=%08x exp=%08x got=%08x%s", di < 8 ? "D" : "A", di % 8,
			         i_regs[di], e_regs[di], cap_regs[di], (e_regs[di] !== cap_regs[di]) ? "  <--" : "");
		$display("    SR exp=%04x mask=%04x got=%04x   exc exp=%0d  end/stacked PC exp=%08x  frame@%08x=%02x%02x %02x%02x%02x%02x %02x%02x %02x%02x%02x%02x",
		         e_sr[15:0], e_srmask[15:0], cap_sr, e_exc, e_pc, cap_sp,
		         rd8(cap_sp), rd8(cap_sp+1), rd8(cap_sp+2), rd8(cap_sp+3), rd8(cap_sp+4), rd8(cap_sp+5),
		         rd8(cap_sp+6), rd8(cap_sp+7), rd8(cap_sp+8), rd8(cap_sp+9), rd8(cap_sp+10), rd8(cap_sp+11));
		for (di = 0; di < em_cnt; di = di + 1)
			$display("    MEM %08x sz%0d exp=%08x got=%08x (was %08x)", em_a[di], em_sz[di], em_v[di],
			         read_value(em_a[di], em_sz[di]), em_old[di]);
	end
endtask

task mismatch(input [8*20:1] what, input [31:0] exp, input [31:0] got);
	begin
		mism = mism + 1;
		round_mism = round_mism + 1;
		if (mism <= report_lim)
			$display("MISMATCH j%0d t%0d r%0d %0s: expected %08x got %08x (pc=%08x op=%02x%02x%02x%02x%02x%02x)",
			         jr, test_idx, round_idx, what, exp, got, i_pc,
			         rd8(i_pc), rd8(i_pc+1), rd8(i_pc+2), rd8(i_pc+3), rd8(i_pc+4), rd8(i_pc+5));
	end
endtask

// is byte address a covered by an expected write or by the exception frame
function covered(input [31:0] a, input integer flen);
	integer ei;
	begin
		covered = (a - cap_sp) < flen;
		for (ei = 0; ei < em_cnt; ei = ei + 1)
			if ((a - em_a[ei]) < ((em_sz[ei] == 0) ? 1 : (em_sz[ei] == 1) ? 2 : 4)) covered = 1;
	end
endfunction

task check_final;
	integer fi, wi, wb, flen, nb, extra;
	reg [15:0] fword;
	reg [7:0] cap_vec;
	begin
		round_mism = 0;
		fword = read_value(cap_sp + 6, 1);
		cap_vec = fword[11:2];
		if (!(flags & F_IGNORE_EXC) && cap_vec !== e_exc)
			mismatch("exception", e_exc, cap_vec);
		for (fi = 0; fi < 16; fi = fi + 1)
			if (cap_regs[fi] !== e_regs[fi])
				mismatch(fi < 8 ? "D register" : "A register", e_regs[fi], cap_regs[fi]);
		if (((cap_sr ^ e_sr[15:0]) & e_srmask[15:0]) != 0)
			mismatch("SR", e_sr, cap_sr);
		if (frame_len != 0) begin
			for (fi = 0; fi < frame_len; fi = fi + 1)
				if ((rd8(cap_sp + fi) ^ frame_b[fi]) & frame_m[fi]) begin
					if (mism < report_lim)
						$display("  frame byte %0d at %08x mask=%02x", fi, cap_sp + fi, frame_m[fi]);
					mismatch("exception frame", frame_b[fi], rd8(cap_sp + fi));
				end
		end else if (!(flags & F_IGNORE_EXC) && e_exc == 4) begin
			if (read_value(cap_sp + 2, 2) !== e_pc)
				mismatch("end PC", e_pc, read_value(cap_sp + 2, 2));
		end
		for (fi = 0; fi < em_cnt; fi = fi + 1)
			if (read_value(em_a[fi], em_sz[fi]) !== em_v[fi])
				mismatch("memory write", em_v[fi], read_value(em_a[fi], em_sz[fi]));

		// writes the corpus does not expect (not a reference-bench check;
		// reported, and a mismatch only under +strictwrites)
		flen = (fword[15:12] == 4'h0) ? 8 : (fword[15:12] == 4'h2 || fword[15:12] == 4'h3) ? 12 :
		       (fword[15:12] == 4'h4) ? 16 : 8;
		extra = 0;
		for (wi = 0; wi < dut.u_l1.wr_cnt && wi < 256; wi = wi + 1) begin
			nb = (dut.u_l1.wr_log_sz[wi] == 0) ? 1 : (dut.u_l1.wr_log_sz[wi] == 1) ? 2 : 4;
			for (wb = 0; wb < nb; wb = wb + 1)
				// a byte rewritten with its own value is not a change the
				// generator records (it compares memory), so it is not extra
				if (!covered(dut.u_l1.wr_log_a[wi] + wb, flen) &&
				    ((dut.u_l1.wr_log_d[wi] ^ dut.u_l1.wr_log_o[wi]) >> (8 * (nb - 1 - wb))) & 32'hFF) begin
					extra = extra + 1;
					if (extra == 1 && (strict || extra_write_rounds < 5))
						$display("EXTRA-WRITE j%0d t%0d r%0d: %08x size %0d data %08x (pc=%08x)", jr, test_idx, round_idx,
						         dut.u_l1.wr_log_a[wi], dut.u_l1.wr_log_sz[wi], dut.u_l1.wr_log_d[wi], i_pc);
				end
		end
		if (extra) begin
			extra_write_rounds = extra_write_rounds + 1;
			extra_writes_total = extra_writes_total + extra;
			if (strict) mismatch("extra write", 0, extra);
		end

		if (round_mism) begin
			bad_rounds = bad_rounds + 1;
			if (bad_rounds <= dump_lim) dump_round;
		end
		// restore every expected-write location to its pre-round value
		for (fi = 0; fi < em_cnt; fi = fi + 1)
			apply_value(em_a[fi], em_sz[fi], em_old[fi]);
	end
endtask

task inject_state;
	integer ii;
	begin
		// the native runner copies the canonical test stack image to the ISP
		// before a supervisor-mode round (tb_dat_replay.v inject_state)
		if (i_sr[13])
			for (ii = 0; ii < 32; ii = ii + 1) write_byte(i_ssp + ii, rd8(i_regs[15] + ii));
		for (ii = 0; ii < 8; ii = ii + 1) begin
			dut.u_regfile.dreg[ii] = i_regs[ii];
			if (ii < 7) dut.u_regfile.areg[ii] = i_regs[8+ii];
		end
		dut.u_regfile.usp = i_regs[15];
		dut.u_regfile.isp = i_ssp;
		dut.u_regfile.msp = i_msp;
		dut.sr   = i_sr[15:0];
		dut.vbr  = SYN_VBR;
		dut.cacr = 0;
		dut.sfc  = 0;
		dut.dfc  = 0;
	end
endtask

function in_stub(input v, input [31:0] pc);
	in_stub = !v || (pc >= SYN && pc <= STUB_JMP);
endfunction

task run_round;
	begin
		apply_value(STUB_JMP + 2, 2, i_pc);
		dut.u_l1.boot_isp = i_ssp;
		dut.u_l1.boot_pc  = SYN;
		dut.u_l1.boot_ovl = 1;
		cap_armed = 0; cap_done = 0;
		ipl = 3'b111;
		nreset = 0;
		repeat (3) @(posedge clk);
		#1 nreset = 1;
		timeout = 0;
		while (!(dbg_wb_valid && dbg_wb_pc == SYN) && timeout < 400) begin
			@(posedge clk); timeout = timeout + 1;
		end
		#1;
		if (timeout >= 400) begin
			$display("HARNESS j%0d: boot stub never retired", jr);
			errors = errors + 1;
			nreset = 0;
			for (k = 0; k < em_cnt; k = k + 1) apply_value(em_a[k], em_sz[k], em_old[k]);
		end else begin
			if (!in_stub(dbg_id_valid, dbg_id_pc) || !in_stub(dbg_eac_valid, dbg_eac_pc) ||
			    !in_stub(dbg_eaf_valid, dbg_eaf_pc) || !in_stub(dbg_ex_valid, dbg_ex_pc)) begin
				$display("HARNESS j%0d: a non-stub instruction is in flight at state injection", jr);
				errors = errors + 1;
			end
			dut.u_l1.boot_ovl = 0;
			inject_state;
			dut.u_l1.wr_cnt = 0;
			cap_armed = 1;
			timeout = 0;
			while (!cap_done && timeout < EXEC_TIMEOUT) begin
				@(posedge clk); timeout = timeout + 1;
				// the round's interrupt level goes onto the pins when the
				// stub's JMP to the tested instruction is in EA-fetch: the
				// stub NOPs are past the boundary where interrupts are taken,
				// the JMP dispatches on the next edge (irq_take, which
				// holds reads back and takes the interrupt, arms one clock
				// behind the request), and the tested instruction -- whose
				// early operand read goes out while it is still entering
				// EA-calc -- sees the request armed.  That is the
				// native runner's shape: INTREQ is written before the tested
				// instruction, which is where a level above the mask is taken
				// (cputest.cpp execute_ins: check_interrupts, then
				// Exception(24 + ipl) before the first instruction); a level
				// at or below the mask waits for the tested instruction to
				// lower the mask.
				// The synchronizer is preloaded with the level: the native
				// runner's INTREQ write lies several instructions back, so the
				// pins have been stable for longer than the two samples take,
				// and the JMP resolves its target in ID -- the tested
				// instruction's early read can go out one clock after the
				// JMP is in EA-fetch, before a cold synchronizer would have
				// settled.  (One clock later -- the JMP in EX -- is too late
				// for a memory-operand instruction: its read is out, and D17
				// then rightly defers the interrupt past it.)
				if (i_level != 0 && ipl == 3'b111 && dbg_eaf_valid && dbg_eaf_pc == STUB_JMP) begin
					ipl = ~i_level[2:0];
					dut.g_irq.ipl_s1 = ~i_level[2:0];
					dut.g_irq.ipl_s2 = ~i_level[2:0];
					dut.g_irq.irq_lvl_r = i_level[2:0];
				end
				if (jr == trace_round)
					$display("T%0d id=%b:%08x eac=%b:%08x eaf=%b:%08x ex=%b:%08x wb=%b:%08x sr=%04x rd=%b:%08x wr=%b:%08x ipl=%0d irq=%b",
					         timeout, dbg_id_valid, dbg_id_pc, dbg_eac_valid, dbg_eac_pc, dbg_eaf_valid, dbg_eaf_pc,
					         dbg_ex_valid, dbg_ex_pc, dbg_wb_valid, dbg_wb_pc, dut.sr,
					         dut.u_l1.rd_req, dut.u_l1.rd_addr, dut.u_l1.wr_req, dut.u_l1.wr_addr,
					         ~ipl, dut.irq_req);
			end
			// one more edge (the entry commits), then hold reset so the handler never
			// runs; the capture already holds the pre-entry state
			@(posedge clk); #1;
			nreset = 0;
			cap_armed = 0;
			if (!cap_done) begin
				mismatch("timeout", 0, timeout);
				bad_rounds = bad_rounds + 1;
				if (bad_rounds <= dump_lim)
					$display("  ROUND j%0d t%0d r%0d pc=%08x op=%02x%02x%02x%02x in-SR=%04x: no exception entry in %0d clocks (wb pc=%08x)",
					         jr, test_idx, round_idx, i_pc, rd8(i_pc), rd8(i_pc+1), rd8(i_pc+2), rd8(i_pc+3),
					         i_sr[15:0], EXEC_TIMEOUT, dbg_wb_pc);
				for (k = 0; k < em_cnt; k = k + 1) apply_value(em_a[k], em_sz[k], em_old[k]);
			end else
				check_final;
			ran = ran + 1;
		end
	end
endtask

//--------------------------------------------------------------- main
integer limit, start_record;
reg [31:0] job_version, job_tbase, job_tsize;
reg [31:0] toggle_a, toggle_v;
reg  [7:0] toggle_kind;
reg        skip;

initial begin
	errors = 0; ran = 0; mism = 0; bad_rounds = 0;
	skip_ign = 0; skip_trace = 0; skip_irq = 0; skip_berr = 0; skip_odd = 0;
	extra_writes_total = 0; extra_write_rounds = 0;
	cap_armed = 0; cap_done = 0;
	if (!$value$plusargs("report=%d", report_lim)) report_lim = 20;
	if (!$value$plusargs("dump=%d", dump_lim)) dump_lim = 3;
	if (!$value$plusargs("trace_round=%d", trace_round)) trace_round = -1;
	if (!$value$plusargs("mutate_reg=%d", mutate_reg)) mutate_reg = -1;
	strict = $test$plusargs("strictwrites");
	if (!$value$plusargs("job=%s", job_file) || !$value$plusargs("lmem=%s", lmem_file) ||
	    !$value$plusargs("tmem=%s", tmem_file)) begin
		$display("FAIL: require +job= +lmem= +tmem="); $finish;
	end
	if (!$value$plusargs("limit=%d", limit)) limit = 32'h7fffffff;
	if (!$value$plusargs("start=%d", start_record)) start_record = 0;

	jf = $fopen(job_file, "rb");
	if (!jf) begin $display("FAIL: cannot open APR2 job"); $finish; end
	if (jread32(0) !== "APR2") begin $display("FAIL: bad job magic"); $finish; end
	job_version = jread32(0); jn = jread32(0);
	job_tbase = jread32(0); job_tsize = jread32(0); odd_vector = jread32(0);
	if (job_version != 3 || job_tsize > 32'h0020_0000) begin
		$display("FAIL: unsupported APR2 geometry/version"); $finish;
	end
	dut.u_l1.TBASE = job_tbase;
	dut.u_l1.TSIZE = job_tsize;
	lmfd = $fopen(lmem_file, "rb");
	tmfd = $fopen(tmem_file, "rb");
	if (!lmfd || !tmfd) begin $display("FAIL: cannot open corpus memory images"); $finish; end
	fgot = $fread(dut.u_l1.lmem, lmfd); $fclose(lmfd);
	fgot = $fread(dut.u_l1.tmem, tmfd); $fclose(tmfd);
	setup_synthetic;
	if (jn > limit) jn = limit;
	$display("tb_dat_replay_pipe: %0d APR2 records, test memory %08x+%08x", jn, job_tbase, job_tsize);
	if (mutate_reg >= 0) $display("MUTATION CHECK: expected register %0d corrupted in every round", mutate_reg);

	for (jr = 0; jr < jn; jr = jr + 1) begin
		if (jread32(0) !== RND2) begin $display("FAIL: record desync at %0d", jr); $finish; end
		test_idx = jread32(0); round_idx = jread32(0); flags = jread32(0);
		for (k = 0; k < 16; k = k + 1) i_regs[k] = jread32(0);
		i_sr = jread32(0); i_pc = jread32(0); i_ssp = jread32(0); i_msp = jread32(0);
		for (k = 0; k < 8 * 3; k = k + 1) dummy32 = jread32(0);   // FP0-FP7 (unused)
		i_fpcr = jread32(0); i_fpsr = jread32(0); i_fpiar = jread32(0);
		i_level = jread8(0);
		read_apply_patches;
		n = jread16(0);
		for (k = 0; k < n; k = k + 1) begin
			toggle_a = jread32(0); toggle_kind = jread8(0);
			toggle_v = read_value(toggle_a, 2);
			if (toggle_kind == 1)
				apply_value(toggle_a, 2, {toggle_v[15:0], toggle_v[31:16]});
			else if (toggle_kind == 2)
				apply_value(toggle_a, 1, toggle_v[31:16] == 16'h2048 ? 16'h4afc : 16'h2048);
		end
		for (k = 0; k < 16; k = k + 1) e_regs[k] = jread32(0);
		e_sr = jread32(0); e_srmask = jread32(0);
		for (k = 0; k < 8 * 3; k = k + 1) dummy32 = jread32(0);
		e_fpcr = jread32(0); e_fpsr = jread32(0); e_fpiar = jread32(0);
		e_exc = jread8(0); e_pc = jread32(0);
		e_trace = jread8(0); e_group2 = jread8(0);
		e_trace_sr = jread16(0); e_trace_srmask = jread16(0); e_trace_pc = jread32(0);
		frame_len = jread16(0);
		for (k = 0; k < frame_len; k = k + 1) frame_b[k] = jread8(0);
		for (k = 0; k < frame_len; k = k + 1) frame_m[k] = jread8(0);
		em_cnt = jread16(0);
		for (k = 0; k < em_cnt; k = k + 1) begin
			em_a[k] = jread32(0); em_sz[k] = jread8(0); em_v[k] = jread32(0); em_old[k] = jread32(0);
		end
		read_post_patches;
		read_clean_patches;
		if (mutate_reg >= 0 && mutate_reg < 16) e_regs[mutate_reg] = e_regs[mutate_reg] ^ 32'h0000_0100;

		skip = 1;
		if ((flags & F_IGNORE_EXC) || jr < start_record)                         skip_ign = skip_ign + 1;
		else if (i_sr[15:14] != 0 || (e_sr[15:14] & e_srmask[15:14]) != 0 ||
		         e_trace != 0 || e_exc == 9)                                     skip_trace = skip_trace + 1;
		// (interrupt rounds are no longer skipped; skip_irq stays in the
		// summary line, always 0, so the runner's parsing is unchanged)
		else if (e_exc == 2)                                                     skip_berr = skip_berr + 1;
		// odd-vector jobs RUN since 2026-09-24 (the synthetic table points
		// every vector from 4 up at the odd address); skip_odd stays 0
		else skip = 0;
		if (!skip) run_round;
		apply_deferred;
	end

	$display("dat replay: %0d rounds run, %0d failing rounds, %0d mismatches, %0d harness errors",
	         ran, bad_rounds, mism, errors);
	$display("skipped: %0d ignore/maintenance, %0d trace, %0d interrupt, %0d bus error, %0d odd-vector",
	         skip_ign, skip_trace, skip_irq, skip_berr, skip_odd);
	$display("extra writes (not in CT_MEMWRITE or frame): %0d bytes in %0d rounds%s; unmapped reads %0d writes %0d",
	         extra_writes_total, extra_write_rounds, strict ? " (strict)" : "",
	         dut.u_l1.unmapped_rd, dut.u_l1.unmapped_wr);
	if (mism == 0 && errors == 0 && ran > 0) $display("ALL TESTS PASSED");
	else if (mism == 0 && errors == 0) $display("NO ROUNDS RUN");
	else $display("TEST FAILED with %0d errors", mism + errors);
	$finish;
end

endmodule
