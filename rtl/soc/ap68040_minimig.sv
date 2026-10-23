//--------------------------------------------------------------------------//
// ap68040_minimig.sv - the AP68040 `faster` core on TG68K.vhd's master port //
//                                                                          //
// Adapted from Adam Polkosnik's bridge of the same name in                 //
// Minimig-AGA_MiSTer (branch ap040, f572ed87), GPL v2 or later.            //
//                                                                          //
// The core (lib/AP68040-faster, module ap68040) presents the real 68040    //
// bus.  This module is its only slave, and every transfer becomes one      //
// request on the wrapper's 32-bit master port -- the m_* channel the       //
// pipelined core drove before (rtl/soc/TG68K.vhd, the master mux), with    //
// the free-running core's handshake:                                       //
//                                                                          //
//   mem_req   level, raised on the clock edge after TS, fields stable      //
//             while it is high; dropped on the edge that takes mem_ack     //
//   mem_ack   ONE clk pulse (TG68K.vhd pc_ack), mem_rdata valid with it   //
//   size      0 byte, 1 word, 2 long; data right-aligned by size          //
//                                                                          //
// The wrapper's own invariant -- x_* changes only where clkena_r is high   //
// (no request outstanding, or its completion edge) -- holds because        //
// mem_req is low for at least one clk edge between two transfers and the   //
// fields only move while it is low.                                        //
//                                                                          //
//  * TBI is held asserted: a line transfer runs as four long-word          //
//    transfers (MC68040UM 7.4.4), each a request here.                    //
//  * TCI (MC68040UM 4.3.2) is asserted for every transfer outside the     //
//    configured Zorro II/III fast RAM: only fast RAM enters the caches,  //
//    whatever the MMU and the TTRs say (with translation off a 68040     //
//    caches everything).  Chip RAM changes under chipset DMA, which this //
//    core does not snoop, and old programs modify code there without     //
//    flushing; device registers, the ROM and the RTG space stay out too. //
//    A TCI line is never allocated, in either cache.                      //
//  * An interrupt acknowledge (TT = 3) is answered at once with AVEC: the  //
//    Amiga autovectors every level.  A breakpoint acknowledge gets TA,     //
//    which makes BKPT an illegal instruction.                              //
//  * mem_berr (level) ends the transfer in progress with TEA; the          //
//    wrapper ties it low today (undecoded space auto-completes $FFFF).    //
//  * Byte and word write data come from the 68040's byte lanes (table     //
//    7-1); read data is replicated on every lane of its size, so the      //
//    core's own lane select finds it wherever it looks.                   //
//  * BG is held asserted and there is no other master: no snooping and no //
//    arbitration.  A locked sequence needs nothing: this slave runs one   //
//    transfer at a time.                                                  //
//--------------------------------------------------------------------------//

module ap68040_minimig
#(
	parameter logic [7:0] FPU_REVISION = 8'h41,
	parameter bit         FPU_PIPE     = 0,
	parameter bit         LOOP_PRED    = 0,
	parameter bit         EARLY_RES    = 0,
	parameter bit         DC1_ATC      = 1,      // DC1's own ATC port: off DC1's critical path
	parameter bit         SKID         = 0,
	parameter int         DIV_STEPS    = 2,
	parameter bit         DUAL         = 1,      // dual issue
	parameter bit         BTIC         = 1,      // the fetch BTB's target words
	parameter bit         PSTAT        = 1,      // debug_fe: dual-issue counters, not the core's dbg_fe
	parameter logic [2:0] S1_CLASSES   = 3'b011, // the second slot's classes {load, An, Dn}: loads off (core 6985f7d)
	parameter logic [3:0] S1_LDMASK    = 4'b1111, // ... the loads {TST, ALU, MOVEA.L, MOVE} (a debug switch)
	parameter bit         S1_LDTK      = 1       // ... a load companion at a BTB-taken target (a debug switch)
)
(
	input  logic        clk,            // the processor clock (clk_cpu)
	input  logic        nreset,

	// the cacheable window: the configured Zorro II/III fast RAM (registered
	// on clk by the wrapper; changes only while the machine configures)
	input  logic        z2ram_ena,
	input  logic  [4:0] z3ram_base0,    // 128 MB block
	input  logic        z3ram_ena0,
	input  logic  [3:0] z3ram_base1,    // 256 MB block
	input  logic        z3ram_ena1,

	// the wrapper's master port (see above)
	output logic        mem_req,
	output logic        mem_write,
	output logic        mem_instr,
	output logic  [1:0] mem_size,
	output logic [31:0] mem_addr,
	output logic [31:0] mem_wdata,
	output logic  [2:0] mem_fc,         // the transfer's TM2-TM0 (= FC for normal accesses)
	input  logic        mem_ack,
	input  logic [31:0] mem_rdata,
	input  logic        mem_berr,

	input  logic  [2:0] ipl_n,          // IPL2-IPL0, active low as the pins are

	output logic        nresetout,      // RSTO: the RESET instruction
	output logic [31:0] cacr_out,
	output logic [31:0] vbr_out,
	output logic        cache_maint,    // one-clk pulse per completed CINV/CPUSH
	output logic        debug_halted,
	output logic [31:0] debug_pc,
	output logic [383:0] debug_fe      // observation only: PSTAT ? the counters : the core's dbg_fe
);

//--------------------------------------------------------------------------
// the core
//--------------------------------------------------------------------------
logic [31:0] a_o, d_o, d_i;
logic        ts_n, rw_n, ciout_n, ta_n, tea_n, tci_n, rsto_n;
logic  [1:0] siz, tt;
logic  [2:0] tm;
logic  [2:0] ipl_r;
logic [383:0] core_fe;
logic  [63:0] pev;

// IPL comes from the clk_114 chipset side; one register here, the core's
// own sampling does the rest
always_ff @(posedge clk) ipl_r <= ipl_n;

ap68040 #(
	.FPU_REVISION(FPU_REVISION), .FPU_PIPE(FPU_PIPE), .LOOP_PRED(LOOP_PRED),
	.EARLY_RES(EARLY_RES), .DC1_ATC(DC1_ATC), .SKID(SKID), .DIV_STEPS(DIV_STEPS),
	.DUAL(DUAL), .BTIC(BTIC), .S1_CLASSES(S1_CLASSES), .S1_LDMASK(S1_LDMASK), .S1_LDTK(S1_LDTK)
) core (
	.clk(clk), .bclk_en(1'b1), .rsti_n(nreset),
	.a_o(a_o), .a_oe(),
	// no other master: nothing to snoop
	.a_i(32'd0), .ts_n_i(1'b1), .rw_n_i(1'b1), .siz_i(2'd0), .tt_i(2'd0), .sc(2'd0),
	.mi_n(), .ta_n_o(), .ta_oe(),
	.d_i(d_i), .d_o(d_o), .d_oe(),
	.rw_n(rw_n), .siz(siz), .tt(tt), .tm(tm), .tln(), .upa(),
	.ciout_n(ciout_n), .lock_n(), .locke_n(),
	.ts_n(ts_n), .tip_n(), .ta_n(ta_n), .tea_n(tea_n),
	.tci_n(tci_n), .tbi_n(1'b0),
	.ipl_n(ipl_r), .avec_n(1'b0),
	.br_n(), .bg_n(1'b0), .bb_n_i(1'b1), .bb_n_o(), .bb_oe(),
	.rsto_n(rsto_n), .cdis_n(1'b1), .mdis_n(1'b1), .ipend_n(), .pst(),
	.dbg_pc(debug_pc), .dbg_retire(), .dbg_halted(debug_halted),
	.dbg_vbr(vbr_out), .dbg_cacr(cacr_out), .dbg_cmaint(cache_maint),
	.dbg_fe(core_fe), .dbg_pev(pev)
);

assign nresetout = rsto_n;

//--------------------------------------------------------------------------
// the transfer to request conversion
//--------------------------------------------------------------------------
// write data by byte lane (MC68040UM table 7-1), right-aligned for the port
function automatic logic [31:0] wlane(input logic [1:0] s, input logic [1:0] a, input logic [31:0] d);
	case (s)
		2'b01:   wlane = {24'd0, a[1] ? (a[0] ? d[7:0] : d[15:8]) : (a[0] ? d[23:16] : d[31:24])};
		2'b10:   wlane = {16'd0, a[1] ? d[15:0] : d[31:16]};
		default: wlane = d;
	endcase
endfunction

// SIZ1-SIZ0 to the port's size (a line is its first long word)
function automatic logic [1:0] asz(input logic [1:0] s);
	case (s)
		2'b01:   asz = 2'd0;   // byte
		2'b10:   asz = 2'd1;   // word
		default: asz = 2'd2;   // long, line
	endcase
endfunction

// read data on every lane of its size
function automatic logic [31:0] rlane(input logic [1:0] s, input logic [31:0] d);
	case (s)
		2'd0:    rlane = {4{d[7:0]}};
		2'd1:    rlane = {2{d[15:0]}};
		default: rlane = d;
	endcase
endfunction

// the configured fast RAM, as TG68K.vhd's sel_z2ram/sel_z3ram* decode it
// (the windows are wider than the boards, as for the pipelined core's
// cacheable windows)
function automatic logic fastram(input logic [31:0] a, input logic z2, input logic [4:0] b0,
                                 input logic e0, input logic [3:0] b1, input logic e1);
	fastram = ((a[31:27] == b0) && e0) || ((a[31:28] == b1) && e1) ||
	          ((a[31:24] == 8'd0) && (a[23] ^ |a[22:21]) && z2);
endfunction

localparam logic [1:0] C_IDLE = 2'd0,   // waiting for TS
                       C_REQ  = 2'd1,   // the request is with the wrapper
                       C_ACK  = 2'd2,   // TA or TEA driven this bus clock
                       C_BERR = 2'd3;   // berr being withdrawn

logic [1:0] st;
logic       pend;       // a transfer arrived while berr was being withdrawn
logic       err_ack;    // the acknowledge being driven is TEA
logic       cach;       // the transfer's address is in the cacheable window

wire ts   = !ts_n;
wire iack = (tt == 2'd3);   // interrupt or breakpoint acknowledge

always_ff @(posedge clk) begin
	ta_n  <= 1'b1;
	tea_n <= 1'b1;
	tci_n <= 1'b1;
	if (!nreset) begin
		st        <= C_IDLE;
		pend      <= 1'b0;
		err_ack   <= 1'b0;
		mem_req   <= 1'b0;
		mem_write <= 1'b0;
		mem_instr <= 1'b0;
		mem_size  <= 2'd0;
		mem_addr  <= '0;
		mem_wdata <= '0;
		mem_fc    <= '0;
		cach      <= 1'b0;
		d_i       <= '0;
	end
	else begin
		// every memory transfer is latched as it starts (TS lasts one bus
		// clock); the core holds the address and data until TA
		if (ts && !iack) begin
			mem_write <= !rw_n;
			mem_instr <= (tm == 3'd2) || (tm == 3'd6);   // user, supervisor code
			mem_size  <= asz(siz);
			mem_addr  <= a_o;
			mem_wdata <= wlane(siz, a_o[1:0], d_o);
			mem_fc    <= tm;
			cach      <= fastram(a_o, z2ram_ena, z3ram_base0, z3ram_ena0, z3ram_base1, z3ram_ena1);
		end
		// an acknowledge cycle is answered at once, in any state
		if (ts && iack) begin
			ta_n <= 1'b0;
			d_i  <= '0;
		end

		case (st)
		C_IDLE: begin
			if (ts && !iack) begin
				if (mem_berr) begin
					pend <= 1'b1;
					st   <= C_BERR;
				end
				else begin
					mem_req <= 1'b1;
					st      <= C_REQ;
				end
			end
		end

		C_REQ: begin
			if (mem_ack) begin
				mem_req <= 1'b0;
				d_i     <= rlane(mem_size, mem_rdata);
				ta_n    <= 1'b0;
				tci_n   <= cach;      // sampled with the first TA of a line
				err_ack <= 1'b0;
				st      <= C_ACK;
			end
			else if (mem_berr) begin
				mem_req <= 1'b0;
				tea_n   <= 1'b0;
				err_ack <= 1'b1;
				st      <= C_ACK;
			end
		end

		C_ACK: st <= err_ack ? C_BERR : C_IDLE;

		C_BERR: begin
			if (ts && !iack) pend <= 1'b1;
			if (!mem_berr) begin
				if (pend || (ts && !iack)) begin
					pend    <= 1'b0;
					mem_req <= 1'b1;
					st      <= C_REQ;
				end
				else st <= C_IDLE;
			end
		end

		default: st <= C_IDLE;
		endcase
	end
end

//--------------------------------------------------------------------------
// dual-issue counters (PSTAT), for the logic analyser (ila_cpu040 dbg_phist)
//--------------------------------------------------------------------------
// Eleven free-running 32-bit counters of the core's dbg_pev strobes, read
// in two snapshots and differenced (each wraps in 75 s at 56.72 MHz):
//   [31:0] clocks          [63:32] retired      [95:64] retired, slot 2
//   [127:96] D1 starts     [159:128] slow       [191:160] next word absent
//   [223:192] next word not slot-2 class        [255:224] with a companion
//   [287:256] paired       [319:288] split: register dependency
//   [351:320] split: the first instruction may not pair
// and one in 4096 of the slow / not-slot-2 / split-first events sampled:
//   [367:352] the word (slow: the instruction; not slot 2: the word after
//   it; split: the first instruction), [380:368] the instruction before a
//   not-slot-2 word, bits 15:3, [382:381] kind (1 not slot 2, 2 slow,
//   3 split), [383] the strobe (one clock per sample)
generate
	if (PSTAT) begin : g_pstat
		logic [31:0] cnt [11];
		logic [15:0] lfsr;
		logic [31:0] samp;
		logic        sv;
		wire  [10:0] ev = {pev[55], pev[54], pev[53], pev[52], pev[51], pev[50], pev[49],
		                   pev[48], pev[57], pev[56], 1'b1};
		// (D1's pev[51] ns1, [49] slow, the sequencer's [55] s0 split)
		wire  hit = (lfsr[11:0] == 12'd0);
		always_ff @(posedge clk) begin
			lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] ^ (lfsr == 16'd0)};
			for (int i = 0; i < 11; i++) if (ev[i]) cnt[i] <= cnt[i] + 32'd1;
			sv <= 1'b0;
			if (hit && pev[51]) begin
				sv <= 1'b1; samp <= {2'd1, pev[15:3], pev[31:16]};
			end
			else if (hit && pev[49]) begin
				sv <= 1'b1; samp <= {2'd2, 13'd0, pev[15:0]};
			end
			else if (hit && pev[55]) begin
				sv <= 1'b1; samp <= {2'd3, 13'd0, pev[47:32]};
			end
		end
		always_comb begin
			for (int i = 0; i < 11; i++) debug_fe[32*i +: 32] = cnt[i];
			debug_fe[382:352] = samp[30:0];
			debug_fe[383]     = sv;
		end
	end
	else begin : g_fe
		assign debug_fe = core_fe;
	end
endgenerate

endmodule
