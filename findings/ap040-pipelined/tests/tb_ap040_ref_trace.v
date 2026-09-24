//--------------------------------------------------------------------------//
// tb_ap040_ref_trace.v - retire-trace dumper for the REFERENCE AP68040      //
//                                                                          //
// Runs against either reference:                                           //
//   default         lib/AP68040 (MinimigAGA_TC64 e2-fixes, the core that    //
//                   ships): no bus_clkena_in/tick_in/post_drain, has the     //
//                   fill_*/m_*/debug_status2 ports                          //
//   +define+REF_UPSTREAM   apolkosnik/AP68040 main (bus_clkena_in, tick_in, //
//                   post_drain, debug_exception*)                           //
// run_all.sh picks the define by looking for bus_clkena_in in the compat   //
// file.  REF_HAS_MMU / REF_HAS_FPU (defines, default 1 / 0) choose the      //
// generics; ENABLE_CACHE and POST_STORES are 0 as in the Minimig build, so //
// every store reaches the bus in program order.                            //
//                                                                          //
// Flat 32K-word 16-bit memory with zero wait states (idle | ready pulse    //
// one clock after the request), no interrupts, no berr.                    //
//                                                                          //
// Streams written to +trace=<file>:                                        //
//   <pc> <sr> d0..d7 a0..a7    one line per instruction DECODE (state       //
//                              S_DECODE, pc_i = its address), i.e. the      //
//                              state after every earlier instruction.       //
//                              All sixteen registers are read               //
//                              hierarchically from the core's regfile       //
//                              (lib: plain dreg/areg arrays; upstream: the  //
//                              mirrored bank with its written-vector and    //
//                              held write, inverted here, not in RTL).      //
//   W <addr> <size> <data>     every bus write, at the qualified cycle      //
//                              (busstate==11 && mem_ready); size 1 or 2,    //
//                              byte lanes from nUDS/nLDS                    //
//   X <vec> <fmt> <sr> <pc> [<word>...]  exception entry, taken when the    //
//                              core reaches S_EXC_VEC (A7 already points    //
//                              at the finished frame), decoded from memory  //
//                              at A7; words past the first 8 bytes are      //
//                              printed as 16-bit hex (format $2/$3: 2,      //
//                              $4: 4, $7: 26)                               //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

`ifndef REF_HAS_MMU
`define REF_HAS_MMU 1
`endif
`ifndef REF_HAS_FPU
`define REF_HAS_FPU 0
`endif

module tb_ap040_ref_trace;

reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0;

wire [15:0] data_in;
wire [31:0] addr_out;
wire [15:0] data_write;
wire        nwr, nuds, nlds;
wire  [1:0] busstate;
wire        longword;
wire        nresetout;
wire  [2:0] fc;
wire [31:0] cacr_out, vbr_out;
wire        debug_busy, debug_fault, debug_halted;
wire [255:0] debug_status;

reg  mem_ready;
reg  [2:0] ipl = 3'b111;
wire clkena_in = (busstate == 2'b01) | mem_ready;

ap040_tg68k_compat #(
	.AP040_HAS_MMU(`REF_HAS_MMU), .AP040_HAS_FPU(`REF_HAS_FPU),
	.AP040_ENABLE_CACHE(0), .AP040_POST_STORES(0)
`ifndef REF_UPSTREAM
	, .AP040_FILL_CHANNEL(0), .AP040_BUS16(1)
`endif
) dut (
	.clk(clk), .nreset(nreset),
	.cache_allow_all(1'b1),
	.cache_snoop_stb(1'b0), .cache_snoop_addr(32'd0),
	.cache_z2_ena(1'b0), .cache_z3_base0(5'd0), .cache_z3_ena0(1'b0),
	.cache_z3_base1(4'd0), .cache_z3_ena1(1'b0),
	.clkena_in(clkena_in),
`ifdef REF_UPSTREAM
	.bus_clkena_in(clkena_in), .tick_in(1'b1), .post_drain(),
	.debug_exception_valid(), .debug_exception(),
`else
	.fill_ena_zorro(1'b0), .fill_ena_chip(1'b0), .fill_req(), .fill_addr(),
	.fill_data(128'd0), .fill_ack(1'b0), .fill_err(1'b0),
	.debug_status2(),
	.m_req(), .m_write(), .m_instr(), .m_size(), .m_addr(), .m_wdata(), .m_fc(),
	.m_ack(1'b0), .m_rdata(32'd0),
`endif
	.data_in(data_in), .ipl(ipl), .ipl_autovector(1'b1), .berr(1'b0),
	.addr_out(addr_out), .data_write(data_write),
	.nwr(nwr), .nuds(nuds), .nlds(nlds), .busstate(busstate),
	.longword(longword), .nresetout(nresetout), .fc(fc),
	.nmi_ack_toggle(),
	.cache_maint_req(), .cache_maint_ic(), .cache_maint_dc(),
	.mmu_addr_log(), .mmu_addr_phys(), .mmu_cache_inhibit(),
	.walker_req(), .walker_we(), .walker_addr(), .walker_wdat(),
	.walker_ack(1'b0), .walker_data(32'd0), .walker_berr(1'b0),
	.cache_req(), .cache_addr(), .cache_data(16'd0), .cache_ack(1'b0),
	.cache_burst(), .cache_burst_len(), .cache_ramaddr(),
	.cacr_out(cacr_out), .vbr_out(vbr_out),
	.debug_busy(debug_busy), .debug_fault(debug_fault), .debug_halted(debug_halted),
	.debug_status(debug_status)
);

wire [31:0] dbg_pc = debug_status[31:0];
wire [15:0] dbg_sr = debug_status[47:32];
wire [31:0] dbg_a7 = debug_status[95:64];

// all sixteen registers, read out of the core's regfile
function [31:0] rreg(input [3:0] r);
	begin
		// a write committing on this very edge is part of the state after
		// the previous instruction (the reference writes in its last state)
		if (dut.core.regfile.ce && dut.core.regfile.we && dut.core.regfile.waddr == r)
			rreg = dut.core.regfile.wdata;
		else if (r == 4'd15) rreg = dbg_a7;
`ifdef REF_UPSTREAM
		else if (dut.core.regfile.pend_we && dut.core.regfile.pend_waddr == r)
			rreg = dut.core.regfile.pend_wdata;
		else if (dut.core.regfile.rf_written[r])
			rreg = dut.core.regfile.bank_a[r];
		else
			rreg = 32'd0;
`else
		else if (!r[3]) rreg = dut.core.regfile.dreg[r[2:0]];
		else            rreg = dut.core.regfile.areg[r[2:0]];
`endif
	end
endfunction

//--------------------------------------------------------------- memory
reg [15:0] mem [0:32767];
assign data_in = mem[addr_out[15:1]];

always @(posedge clk) begin
	mem_ready <= 0;
	if (nreset && busstate != 2'b01 && !mem_ready) mem_ready <= 1;
end

always @(posedge clk) if (nreset && mem_ready && busstate == 2'b11) begin
	if (!nuds) mem[addr_out[15:1]][15:8] = data_write[15:8];
	if (!nlds) mem[addr_out[15:1]][7:0]  = data_write[7:0];
end

function [15:0] mw(input [31:0] a); mw = mem[a[15:1]]; endfunction

//--------------------------------------------------------------- trace
localparam S_DECODE  = 8'd4;
localparam S_EXC_VEC = 8'd41;   // same values in upstream and lib/AP68040
localparam S_AERR_WR = 8'd111;

string progf, tracef;      // SV string: a fixed reg truncates long paths silently
integer i, k, fd, max_cycles, cycles, n_ret, nwords;
reg [31:0] halt_pc, sp;
reg [15:0] fv;
reg        have_halt, done;
reg  [7:0] last_state;

always @(posedge clk) begin
	if (nreset && !done) begin
		// W: qualified bus write
		if (mem_ready && busstate == 2'b11) begin
			if (!nuds && !nlds)
				$fwrite(fd, "W %08x 2 %04x\n", {addr_out[31:1], 1'b0}, data_write);
			else if (!nuds)
				$fwrite(fd, "W %08x 1 %02x\n", {addr_out[31:1], 1'b0}, data_write[15:8]);
			else if (!nlds)
				$fwrite(fd, "W %08x 1 %02x\n", {addr_out[31:1], 1'b1}, data_write[7:0]);
		end
		// X: first enabled cycle in S_EXC_VEC
		if (dut.core.ce && dut.core.state == S_EXC_VEC && last_state != S_EXC_VEC) begin
			// the frame base the core just built: the S_AERR path ($7) keeps
			// it in aer_sp, every other exception in exc_sp
			sp = (last_state == S_AERR_WR) ? dut.core.aer_sp : dut.core.exc_sp;
			case (mw(sp + 6) >> 12)
				4'd2, 4'd3: nwords = 2;
				4'd4:       nwords = 4;
				4'd7:       nwords = 26;
				default:    nwords = 0;
			endcase
			fv = mw(sp + 6);
			$fwrite(fd, "X %02x %1x %04x %08x", fv[9:2], fv[15:12],
			        mw(sp), {mw(sp + 2), mw(sp + 4)});
			for (k = 0; k < nwords; k = k + 1) $fwrite(fd, " %04x", mw(sp + 8 + 2 * k));
			$fwrite(fd, "\n");
		end
		if (dut.core.ce) last_state = dut.core.state;
		// state line at decode
		if (dut.core.ce && dut.core.state == S_DECODE) begin
			n_ret = n_ret + 1;
			$fwrite(fd, "%08x %04x", dut.core.pc_i, dbg_sr);
			for (k = 0; k < 16; k = k + 1) $fwrite(fd, " %08x", rreg(k));
			$fwrite(fd, "\n");
			if (have_halt && dut.core.pc_i == halt_pc) done = 1;
		end
	end
end

initial begin
	if (!$value$plusargs("prog=%s", progf)) begin
		$display("usage: +prog=<image.hex> [+trace=<out>] [+cycles=<n>] [+halt_pc=<hex>]");
		$finish;
	end
	if (!$value$plusargs("trace=%s", tracef)) tracef = "ref_trace.txt";
	if (!$value$plusargs("cycles=%d", max_cycles)) max_cycles = 20000;
	have_halt = $value$plusargs("halt_pc=%h", halt_pc);
	done = 0; n_ret = 0; last_state = 8'hFF;
	for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h4E71;
	$readmemh(progf, mem);
	fd = $fopen(tracef, "w");
`ifdef REF_UPSTREAM
	$fwrite(fd, "# reference (apolkosnik main), sampled at decode; W = bus writes; X = exception frames\n");
`else
	$fwrite(fd, "# reference (lib/AP68040), sampled at decode; W = bus writes; X = exception frames\n");
`endif
	$fwrite(fd, "# pc sr d0 d1 d2 d3 d4 d5 d6 d7 a0 a1 a2 a3 a4 a5 a6 a7\n");
	mem_ready = 0;
	repeat (3) @(posedge clk);
	nreset = 1;
	for (cycles = 0; cycles < max_cycles && !done; cycles = cycles + 1) @(posedge clk);
	$fclose(fd);
	$display("tb_ap040_ref_trace: %0d instructions decoded in %0d cycles (%s), trace in %0s",
	         n_ret, cycles, done ? "halt_pc reached" : "cycle budget exhausted", tracef);
	$display("  final: pc=%08x sr=%04x d0=%08x d1=%08x d2=%08x a0=%08x a7=%08x",
	         dbg_pc, dbg_sr, rreg(0), rreg(1), rreg(2), rreg(8), dbg_a7);
	$finish;
end

endmodule
