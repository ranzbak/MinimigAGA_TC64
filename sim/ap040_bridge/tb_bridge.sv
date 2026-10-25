//--------------------------------------------------------------------------//
// sim/ap040_bridge -- the AP68040 faster core behind its Minimig bridge     //
// (rtl/soc/ap68040_minimig.sv), on a model of TG68K.vhd's master port.      //
//                                                                          //
// What the bridge decides on its own is under test here: which transfers   //
// may be cached (TCI), the instruction-cacheable window (ICHIP: chip RAM,  //
// slow RAM, the ROMs), and the instruction-cache invalidations it pushes   //
// into the core (the processor's own writes, the chipset's DMA writes,     //
// through the 4 KB-page filter).  findings/aga-perf/fix.md.                //
//                                                                          //
// The memory behind the port is flat (16 MB, everything readable and     //
// writable), with the Minimig's latencies: chip RAM, slow RAM and the ROM  //
// CHIPLAT clocks (a chip-slot access, ~480 ns at 56.72 MHz), fast RAM      //
// ($200000-$9FFFFF, configured) FASTLAT, the bench registers 2.            //
//                                                                          //
// Bench registers ($DE0000, device space: never cached):                   //
//   $DE0000 word  a test failed: its number (bit n of the failure mask)    //
//   $DE0002 word  $600D: the program is done                               //
//   $DE0010 long  fetch-count window start, $DE0014 its end (exclusive)    //
//   $DE0018 long  (read) instruction-fetch transfers in the window since   //
//                 the last write to it (a write clears)                    //
//   $DE001C long  (read) instruction-cache invalidations the bridge pushed  //
//                 (xinv_out; a write clears)                               //
//   $DE0020 long  DMA poke data;  $DE0024 long  DMA poke address: memory    //
//                 is written behind the processor's back and, SNDLY clocks //
//                 later, the chipset snoop (snoop_stb/snoop_addr) strobes   //
//                 for one clock, as sdram_ctrl's chip-slot write does      //
//   $DE0028 word  bit 0: ichip_ena (chip RAM is 2 MB, no overlay; 1 at    //
//                 reset)                                                    //
//   $DE002C word  (read) nonzero while a poke's snoop is on its way, and    //
//                 PKTAIL clocks after it (a chip-register poll's latency:  //
//                 the program's "is the DMA done")                          //
//                                                                          //
// +prog=<hex> (16-bit words, loaded at 0).  ICHIP and the bridge's other  //
// parameters are `defines (run.sh).                                        //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps

`ifndef ICHIP
`define ICHIP 1
`endif

module tb_bridge;

localparam int CHIPLAT = 26;
localparam int FASTLAT = 4;
localparam int SNDLY   = 6;
localparam int PKTAIL  = 24;

logic clk = 1'b0;
always #8.8 clk = ~clk;          // 56.8 MHz
logic nreset = 1'b0;

logic        mem_req, mem_write, mem_instr, mem_ack, mem_cach, xinv_out;
logic  [1:0] mem_size;
logic [31:0] mem_addr, mem_wdata, mem_rdata;
logic  [2:0] mem_fc;
logic        ichip_ena = 1'b1;
logic        snoop_stb;
logic [31:0] snoop_addr;
logic [31:0] dbg_pc;
logic        halted;

ap68040_minimig #(.ICHIP(`ICHIP)) dut (
	.clk(clk), .nreset(nreset),
	.z2ram_ena(1'b1), .z3ram_base0(5'b01000), .z3ram_ena0(1'b0), .z3ram_base1(4'd0), .z3ram_ena1(1'b0),
	.ichip_ena(ichip_ena), .slow_cfg(2'b01),
	.snoop_stb(snoop_stb), .snoop_addr(snoop_addr),
	.mem_req(mem_req), .mem_write(mem_write), .mem_instr(mem_instr), .mem_size(mem_size),
	.mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_fc(mem_fc), .mem_ack(mem_ack),
	.mem_rdata(mem_rdata), .mem_berr(1'b0), .ipl_n(3'b111),
	.nresetout(), .cacr_out(), .vbr_out(), .cache_maint(), .mem_cach(mem_cach), .xinv_out(xinv_out),
	.debug_halted(halted), .debug_pc(dbg_pc), .debug_fe()
);

//--------------------------------------------------------------------------
// memory and the bench registers
//--------------------------------------------------------------------------
logic [31:0] mem [0:(1 << 22) - 1];
logic [15:0] img [0:65535];
string       prog;

function automatic int lat(input logic [31:0] a);
	if (a[31:24] != 8'd0)                       lat = 2;        // (nothing up there)
	else if (a[23:16] == 8'hDE)                 lat = 2;        // bench registers
	else if (a[23:21] >= 3'd1 && a[23:21] <= 3'd4) lat = FASTLAT;  // Zorro II fast RAM
	else                                        lat = CHIPLAT;  // chip bus: chip, slow, ROM, the rest
endfunction

int          cnt;
logic        busy;
logic [31:0] w_lo, w_hi, fetches, xinvs, pk_data, pk_addr;
int          pk_dly, pk_tail;
// (public: Verilator 5.020 otherwise loses the always_ff updates the initial
// loop polls -- as tb_ap68040.sv's result)
logic        done  /*verilator public_flat_rw*/ = 1'b0;
logic [31:0] fails /*verilator public_flat_rw*/ = 32'd0;
int          cycles = 0;

always_ff @(posedge clk) begin
	mem_ack   <= 1'b0;
	snoop_stb <= 1'b0;
	cycles    <= cycles + 1;
	if (xinv_out) xinvs <= xinvs + 32'd1;
	if (pk_tail > 0) pk_tail <= pk_tail - 1;
	if (pk_dly > 0) begin
		pk_dly <= pk_dly - 1;
		if (pk_dly == 1) begin
			snoop_stb  <= 1'b1;
			snoop_addr <= {pk_addr[31:1], 1'b0};
			pk_tail    <= PKTAIL;
		end
	end
	if (!nreset) begin
		busy <= 1'b0;
	end
	else if (mem_req && !busy && !mem_ack) begin
		busy <= 1'b1;
		cnt  <= lat(mem_addr);
	end
	else if (busy) begin
		if (cnt > 1) cnt <= cnt - 1;
		else begin
			logic [31:0] a, w, r;
			a = mem_addr;
			w = mem[a[23:2]];
			busy    <= 1'b0;
			mem_ack <= 1'b1;
			if (mem_instr && !mem_write && a >= w_lo && a < w_hi) fetches <= fetches + 32'd1;
			if (a[31:16] == 16'h00DE) begin
				// bench registers
				r = 32'd0;
				case (a[7:0])
					8'h18: begin
						r = fetches;
						if (!mem_write) $display("  fetch transfers [%h, %h): %0d (cycle %0d, a %h size %0d fc %0d pc %h)", w_lo, w_hi, fetches, cycles, a, mem_size, mem_fc, dbg_pc);
					end
					8'h1C: r = xinvs;
					8'h2C: r = {16'd0, 16'(pk_dly != 0 || pk_tail != 0)};
					default: ;
				endcase
				if (mem_write) begin
					case (a[7:0])
						8'h00: begin
							fails <= fails | (32'd1 << mem_wdata[4:0]);
							$display("test %0d FAILED (pc %h, cycle %0d)", mem_wdata[15:0], dbg_pc, cycles);
						end
						8'h02: if (mem_wdata[15:0] == 16'h600D) done <= 1'b1;
						8'h10: w_lo <= mem_wdata;
						8'h14: w_hi <= mem_wdata;
						8'h18: fetches <= 32'd0;
						8'h1C: xinvs <= 32'd0;
						8'h20: pk_data <= mem_wdata;
						8'h24: begin
							mem[mem_wdata[23:2]] <= pk_data;
							pk_addr <= mem_wdata;
							pk_dly  <= SNDLY;
						end
						8'h28: ichip_ena <= mem_wdata[0];
						default: ;
					endcase
				end
				mem_rdata <= (mem_size == 2'd2) ? r : (mem_size == 2'd1) ? {16'd0, a[1] ? r[15:0] : r[31:16]} : 32'd0;
			end
			else if (mem_write) begin
				case (mem_size)
					2'd0: case (a[1:0])
						2'd0: mem[a[23:2]] <= {mem_wdata[7:0], w[23:0]};
						2'd1: mem[a[23:2]] <= {w[31:24], mem_wdata[7:0], w[15:0]};
						2'd2: mem[a[23:2]] <= {w[31:16], mem_wdata[7:0], w[7:0]};
						2'd3: mem[a[23:2]] <= {w[31:8], mem_wdata[7:0]};
					endcase
					2'd1: mem[a[23:2]] <= a[1] ? {w[31:16], mem_wdata[15:0]} : {mem_wdata[15:0], w[15:0]};
					default: mem[a[23:2]] <= mem_wdata;
				endcase
			end
			else begin
				case (mem_size)
					2'd0: mem_rdata <= {24'd0, w[8 * (3 - a[1:0]) +: 8]};
					2'd1: mem_rdata <= {16'd0, a[1] ? w[15:0] : w[31:16]};
					default: mem_rdata <= w;
				endcase
			end
		end
	end
end

// a write must never be cached-allowed, nor any transfer outside the windows
always_ff @(posedge clk)
	if (nreset && mem_ack && mem_cach) begin
		logic [31:0] a;
		a = mem_addr;
		if (!mem_instr && !(a[31:24] == 8'd0 && a[23:21] >= 3'd1 && a[23:21] <= 3'd4)) begin
			$display("FAIL: a data transfer outside fast RAM may be cached: %h", a);
			fails <= fails | 32'h8000_0000;
		end
		if (a[31:16] == 16'h00DE) begin
			$display("FAIL: a device register transfer may be cached: %h", a);
			fails <= fails | 32'h8000_0000;
		end
	end

initial begin
	int n;
	for (int i = 0; i < (1 << 22); i++) mem[i] = 32'd0;
	for (int i = 0; i < 65536; i++) img[i] = 16'd0;
	if (!$value$plusargs("prog=%s", prog)) begin
		$display("FAIL: +prog=<hex>");
		$finish;
	end
	$readmemh(prog, img);
	for (int i = 0; i < 32768; i++) mem[i] = {img[2 * i], img[2 * i + 1]};
	w_lo = 32'd0; w_hi = 32'd0; fetches = 32'd0; xinvs = 32'd0; pk_dly = 0; pk_tail = 0;
	snoop_addr = 32'd0; mem_rdata = 32'd0;
	repeat (20) @(posedge clk);
	nreset = 1'b1;
	n = 0;
	while (!done && !halted && n < 3000000) begin
		@(posedge clk);
		n++;
	end
	if (done && fails == 32'd0) $display("PASS %s cycles=%0d", prog, cycles);
	else $display("FAIL %s mask=%h done=%0d halted=%0d cycles=%0d pc=%h", prog, fails, done, halted, cycles, dbg_pc);
	$finish;
end

endmodule
