//--------------------------------------------------------------------------//
// kick_sys.sv - deterministic behavioural Amiga for the Kickstart bench     //
//                                                                          //
// Sits on the compat wrapper's 16-bit bus (addr_out/busstate/nwr/nuds/nlds //
// /data_write in, data_in + a one-clock ready pulse out; the bench makes   //
// clkena_in = idle | ready, exactly as lib/AP68040/tb/tb_ap040_program.v). //
//                                                                          //
//   $000000-$1FFFFF  chip RAM, 2 MB.  While OVL is high, READS of          //
//                    $000000-$07FFFF return the ROM and writes there are   //
//                    dropped (rtl/minimig/gary.v: sel_chip[0] = !ovl).     //
//   $C00000-$C7FFFF  slow RAM, only with +slow=1 (default: absent)         //
//   $BFxxxx          CIA-A (A12=0, D7-D0) / CIA-B (A13=0, D15-D8)          //
//   $DFxxxx          custom-chip stub, registers mirrored every 512 bytes  //
//   $F80000-$FFFFFF  ROM, 512 KB (a 256 KB image is mirrored)              //
//   everything else  reads $FFFF, writes ignored, the cycle completes --   //
//                    what rtl/soc/TG68K.vhd (sel_undecoded) and the        //
//                    Minimig NULL autoconfig device ($E8xxxx) return.      //
//                    A31-A24 != 0 is all unmapped (no Zorro III RAM).      //
//                                                                          //
// Wait states: fixed per region (ROM 1, chip/slow 2, CIA/custom 4, other   //
// 1 clock before ready), independent of time, identical for both cores.   //
//                                                                          //
// Device time (beam counter, CIA timers and TOD) runs on one of two        //
// timebases (+timebase=):                                                  //
//   0 (default) "access": time advances by +tpa=<n> colour clocks (default //
//     16) at every CPU DATA access to $A00000-$DFFFFF, and never otherwise.//
//     The value a core reads is then a function of the architectural I/O  //
//     access sequence only, not of its CPI, so two different cores that   //
//     execute the same program read the same VHPOSR/timer values and a    //
//     raster/timer wait loop runs the same number of iterations: the      //
//     setting for the differential comparison.                            //
//   1 "cycle": one colour clock every 8 clocks (28.37 MHz CPU clock),     //
//     each core sees its own real-time behaviour.                         //
//                                                                          //
// Interrupts (plan M9 subset).  INTREQ collects VERTB each frame,        //
// PORTS/EXTER while a CIA's enabled ICR flag is set, BLIT on every         //
// BLTSIZE/BLTSIZH write (the blitter is "done" at once; no DMA of any     //
// kind is performed) and whatever the CPU sets; the IPL level is Paula's  //
// encoding of INTENA & INTREQ with INTEN (rtl/minimig/paula_intcontroller //
// .v: 1 TBE/DSKBLK/SOFT, 2 PORTS, 3 COPER/VERTB/BLIT, 4 AUD0-3, 5 RBF/    //
// DSKSYN, 6 EXTER).  Delivery is made deterministic across cores: IPL is  //
// shown to the CPU ONLY WHILE IT IS STOPPED (the core's STOP state, SR    //
// committed), and while it is stopped with no level above its mask, device//
// time advances one colour clock per clock.  Both cores therefore stop at //
// the same architectural point with the same device state, run the device //
// clock forward to the same next event, and take the same interrupt with  //
// the same stacked PC.  An interrupt that would, on hardware, arrive while//
// the CPU runs is taken at the next STOP instead (exec idles in STOP      //
// whenever no task is ready).  +irq=0 keeps the lines idle.               //
//                                                                          //
// Floppy (DF0, +disk=1 present / 0 absent): CIA-B PRB drives /STEP, DIR,  //
// /SIDE, /SEL0-3, /MTR (latched per drive on /SELx falling); CIA-A PRA    //
// bits 2-5 read /CHNG, /WPRO, /TK0, /RDY of the selected drive (all high  //
// with none selected).  DF0: /RDY low whenever selected (drive ID        //
// $FFFFFFFF, instant spin-up), /TK0 at                                    //
// cylinder 0, /WPRO high (writable), /CHNG low from power-on until a step //
// with a disk present.  DF1-DF3 are absent (/RDY high: drive ID 0).  The  //
// run ends (dsk_start) at the first DSKLEN write with DMAEN set: the      //
// first real track read, where the board takes over (Paul, M9 subset).    //
// The CPU's RESET (RSTO) resets the CIAs and INTENA/INTREQ/DMACON.        //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

module kick_sys
(
	input             clk,
	input             nreset,
	input      [31:0] addr,
	input       [1:0] busstate,     // 00 ifetch, 10 read, 11 write, 01 idle
	input             nwr,
	input             nuds,
	input             nlds,
	input      [15:0] wdata,
	output reg [15:0] rdata,
	output reg        ready,
	output            ovl,
	output reg [63:0] io_count,
	output reg [63:0] cck,
	// interrupts
	input             stopped,      // the CPU is in the STOP state (SR committed)
	input       [2:0] mask,         // its SR interrupt mask
	output      [2:0] ipl_n,        // to the CPU (active low)
	output      [2:0] level,        // Paula's level (for the trace)
	input             rsto_n,       // the CPU's RESET
	output reg        dsk_start     // the first DSKLEN write with DMAEN set
);

//------------------------------------------------------------------ config
integer timebase, tpa, slow_ena, rom_words, irq_ena, disk_ena, irq_live;
string romfile;

//------------------------------------------------------------------ memory
reg [15:0] chip [0:1048575];      // 2 MB
reg [15:0] slow [0:262143];       // 512 KB
reg [15:0] rom  [0:262143];       // 512 KB

integer fd, n, i;
initial begin
	if (!$value$plusargs("timebase=%d", timebase)) timebase = 0;
	if (!$value$plusargs("tpa=%d", tpa)) tpa = 16;
	if (!$value$plusargs("slow=%d", slow_ena)) slow_ena = 0;
	if (!$value$plusargs("irq=%d", irq_ena)) irq_ena = 1;
	if (!$value$plusargs("disk=%d", disk_ena)) disk_ena = 1;
	// +irqlive=1: IPL is shown to the CPU WHILE IT RUNS, as on the board (the
	// 2026-09-23 black-screen hunt).  The two cores then take interrupts at
	// timing-dependent points and their traces are no longer comparable.
	if (!$value$plusargs("irqlive=%d", irq_live)) irq_live = 0;
	for (i = 0; i < 1048576; i = i + 1) chip[i] = 16'h0000;
	for (i = 0; i < 262144; i = i + 1) begin slow[i] = 16'h0000; rom[i] = 16'hFFFF; end
	if (!$value$plusargs("rom=%s", romfile)) begin
		$display("kick_sys: +rom=<kickstart image> is required");
		$finish;
	end
	fd = $fopen(romfile, "rb");
	if (fd == 0) begin
		$display("kick_sys: cannot open %0s", romfile);
		$finish;
	end
	n = $fread(rom, fd);          // big-endian words, as the file stores them
	$fclose(fd);
	rom_words = n / 2;
	if (rom_words == 131072)
		for (i = 0; i < 131072; i = i + 1) rom[131072 + i] = rom[i];   // 256 KB: mirror
	else if (rom_words != 262144) begin
		$display("kick_sys: %0s is %0d bytes, need 256 or 512 KB", romfile, n);
		$finish;
	end
	$display("kick_sys: ROM %0s, %0d bytes; timebase=%0s tpa=%0d slow=%0d irq=%0d disk=%0d",
	         romfile, n, timebase ? "cycle" : "access", tpa, slow_ena, irq_ena, disk_ena);
end

//------------------------------------------------------------------ custom chips
reg [15:0] dmacon, intena, intreq, adkcon;
reg [15:0] creg [0:255];          // every other write, kept for reference
reg [63:0] frame;

wire [31:0] line_t = cck / 227;
wire  [8:0] hpos   = cck % 227;
wire [8:0]  vpos   = line_t % 313;
// rtl/minimig/agnus_beamcounter.v: {LOF,0,ECS,NTSC,00,AGA,AGA,LOL,0000,V10-8}
wire [15:0] vposr  = {1'b1, 1'b0, 1'b1, 1'b0, 2'b00, 2'b11, 1'b0, 4'b0000, 2'b00, vpos[8]};
wire [15:0] vhposr = {vpos[7:0], hpos[7:0]};

// Paula's interrupt level (rtl/minimig/paula_intcontroller.v)
wire [13:0] ipend = (intena[14] && irq_ena != 0) ? (intena[13:0] & intreq[13:0]) : 14'd0;
assign level = ipend[13]    ? 3'd6 :
               |ipend[12:11] ? 3'd5 :
               |ipend[10:7]  ? 3'd4 :
               |ipend[6:4]   ? 3'd3 :
               ipend[3]      ? 3'd2 :
               |ipend[2:0]   ? 3'd1 : 3'd0;
assign ipl_n = (stopped || irq_live != 0) ? ~level : 3'b111;

function [15:0] setclr(input [15:0] old, input [15:0] v);
	setclr = v[15] ? (old | {1'b0, v[14:0]}) : (old & ~{1'b0, v[14:0]});
endfunction

//------------------------------------------------------------------ CIAs
// index 0 = CIA-A ($BFE001, odd), 1 = CIA-B ($BFD000, even)
reg  [7:0] pra[0:1], prb[0:1], ddra[0:1], ddrb[0:1], sdr[0:1];
reg [15:0] ta[0:1], tb[0:1], tla[0:1], tlb[0:1];
reg  [7:0] cra[0:1], crb[0:1];
reg  [4:0] icr[0:1], icrmask[0:1];
reg [23:0] tod[0:1], alarm[0:1], todlatch[0:1];
reg        todlatched[0:1], todrun[0:1];
reg [31:0] etick_acc;

assign ovl = !(ddra[0][0] && !pra[0][0]);

// floppy: CIA-B PRB (index 1) outputs, CIA-A PRA (index 0) inputs
wire [7:0] prb_out = (prb[1] & ddrb[1]) | (8'hFF & ~ddrb[1]);
reg  [3:0] mtr;            // per drive motor latch
reg  [6:0] cyl;            // DF0 head position
reg        chng_n;         // DF0 /CHNG
reg  [7:0] prb_q;          // last PRB output (edges)
wire       sel0 = !prb_out[3];
// {/RDY, /TK0, /WPRO, /CHNG}, all active low.  /RDY: a present 3.5" DD
// drive answers the drive-ID shift with $FFFFFFFF, i.e. /RDY LOW for every
// one of the 32 bits (WinUAE disk.c DISK_status: "if (drv->idbit) st &=
// ~0x20"), and low again while the motor runs; a drive that is not there
// leaves the line high, so its ID reads as 0.  DF0 therefore holds /RDY low
// whenever it is selected (motor on or off): ID $FFFFFFFF and an instant
// spin-up.  DF1-DF3 are absent: nothing drives the line.
wire [3:0] fdd_in = !sel0 ? 4'b1111 :
                    {1'b0, cyl != 7'd0, 1'b1, chng_n};
task automatic fdd_update;
	integer d;
	begin
		for (d = 0; d < 4; d = d + 1)
			if (prb_q[3 + d] && !prb_out[3 + d]) mtr[d] = !prb_out[7];    // /SELx falling: latch /MTR
		if (sel0 && prb_q[0] && !prb_out[0]) begin                        // /STEP falling
			if (prb_out[1]) begin if (cyl != 0) cyl = cyl - 7'd1; end     // DIR high: outward
			else if (cyl != 7'd79) cyl = cyl + 7'd1;
			if (disk_ena != 0) chng_n = 1'b1;
		end
		prb_q = prb_out;
	end
endtask

task automatic cia_timer_tick(input integer c);
	reg ua;
	begin
		ua = 0;
		if (cra[c][0] && !cra[c][5]) begin
			if (ta[c] == 16'd0) begin
				ua = 1;
				ta[c] = tla[c];
				icr[c][0] = 1'b1;
				if (cra[c][3]) cra[c][0] = 1'b0;
			end
			else ta[c] = ta[c] - 16'd1;
		end
		// timer B: INMODE 00 = E clock, 10 = timer A underflows
		if (crb[c][0] && ((crb[c][6:5] == 2'b00) || (crb[c][6:5] == 2'b10 && ua))) begin
			if (tb[c] == 16'd0) begin
				tb[c] = tlb[c];
				icr[c][1] = 1'b1;
				if (crb[c][3]) crb[c][0] = 1'b0;
			end
			else tb[c] = tb[c] - 16'd1;
		end
	end
endtask

task automatic cia_tod_tick(input integer c);
	begin
		if (todrun[c]) begin
			tod[c] = tod[c] + 24'd1;
			if (tod[c] == alarm[c]) icr[c][2] = 1'b1;
		end
	end
endtask

task automatic update_irq;
	begin
		if (|(icr[0] & icrmask[0])) intreq[3] = 1'b1;    // PORTS  (INT2)
		if (|(icr[1] & icrmask[1])) intreq[13] = 1'b1;   // EXTER  (INT6)
	end
endtask

// one colour clock
task automatic tick_cck;
	begin
		cck = cck + 64'd1;
		if (cck % 227 == 0) begin
			cia_tod_tick(1);                    // CIA-B TOD counts HSYNC
			if ((cck / 227) % 313 == 0) begin
				frame = frame + 64'd1;
				intreq[5] = 1'b1;                // VERTB
				cia_tod_tick(0);                // CIA-A TOD counts VSYNC
			end
		end
		etick_acc = etick_acc + 1;
		if (etick_acc == 5) begin               // E clock = cck / 5
			etick_acc = 0;
			cia_timer_tick(0);
			cia_timer_tick(1);
		end
		update_irq;
	end
endtask

function [7:0] cia_read(input integer c, input [3:0] r);
	reg [7:0] v;
	begin
		case (r)
			4'h0: v = (pra[c] & ddra[c]) | (((c == 0) ? {2'b11, fdd_in, 2'b11} : 8'hFF) & ~ddra[c]);
			4'h1: v = (prb[c] & ddrb[c]) | (8'hFF & ~ddrb[c]);
			4'h2: v = ddra[c];
			4'h3: v = ddrb[c];
			4'h4: v = ta[c][7:0];
			4'h5: v = ta[c][15:8];
			4'h6: v = tb[c][7:0];
			4'h7: v = tb[c][15:8];
			4'h8: v = todlatched[c] ? todlatch[c][7:0]   : tod[c][7:0];
			4'h9: v = todlatched[c] ? todlatch[c][15:8]  : tod[c][15:8];
			4'hA: v = tod[c][23:16];
			4'hB: v = 8'h00;
			4'hC: v = sdr[c];
			4'hD: v = {|(icr[c] & icrmask[c]), 2'b00, icr[c]};
			4'hE: v = {cra[c][7:5], 1'b0, cra[c][3:0]};
			default: v = {crb[c][7:5], 1'b0, crb[c][3:0]};
		endcase
		cia_read = v;
	end
endfunction

// read side effects (once per bus access)
task automatic cia_read_fx(input integer c, input [3:0] r);
	begin
		if (r == 4'hA) begin todlatch[c] = tod[c]; todlatched[c] = 1; end
		if (r == 4'h8) todlatched[c] = 0;
		if (r == 4'hD) icr[c] = 5'd0;
	end
endtask

task automatic cia_write(input integer c, input [3:0] r, input [7:0] v);
	begin
		case (r)
			4'h0: pra[c] = v;
			4'h1: begin prb[c] = v; if (c == 1) fdd_update; end
			4'h2: ddra[c] = v;
			4'h3: begin ddrb[c] = v; if (c == 1) fdd_update; end
			4'h4: tla[c][7:0] = v;
			4'h5: begin
				tla[c][15:8] = v;
				if (!cra[c][0] || cra[c][3]) begin
					ta[c] = tla[c];
					if (cra[c][3]) cra[c][0] = 1'b1;
				end
			end
			4'h6: tlb[c][7:0] = v;
			4'h7: begin
				tlb[c][15:8] = v;
				if (!crb[c][0] || crb[c][3]) begin
					tb[c] = tlb[c];
					if (crb[c][3]) crb[c][0] = 1'b1;
				end
			end
			4'h8: if (crb[c][7]) alarm[c][7:0] = v;
			      else begin tod[c][7:0] = v; todrun[c] = 1; end
			4'h9: if (crb[c][7]) alarm[c][15:8] = v; else tod[c][15:8] = v;
			4'hA: if (crb[c][7]) alarm[c][23:16] = v;
			      else begin tod[c][23:16] = v; todrun[c] = 0; end
			4'hB: ;
			4'hC: begin sdr[c] = v; if (cra[c][6]) icr[c][3] = 1'b1; end
			4'hD: if (v[7]) icrmask[c] = icrmask[c] | v[4:0];
			      else      icrmask[c] = icrmask[c] & ~v[4:0];
			4'hE: begin
				cra[c] = {v[7:5], 1'b0, v[3:0]};
				if (v[4]) ta[c] = tla[c];
			end
			default: begin
				crb[c] = {v[7:5], 1'b0, v[3:0]};
				if (v[4]) tb[c] = tlb[c];
				// rtl/minimig/cia_timerd.v: a CRB write with bit 7 = 0 restarts TOD
				if (!v[7]) todrun[c] = 1;
			end
		endcase
		update_irq;
	end
endtask

//------------------------------------------------------------------ custom read/write
function [15:0] custom_read(input [8:1] r);
	case ({r, 1'b0})
		9'h002: custom_read = {1'b0, 1'b0, 1'b1, 2'b00, dmacon[10:0]};   // BZERO=1, BBUSY=0
		9'h004: custom_read = vposr;
		9'h006: custom_read = vhposr;
		9'h010: custom_read = adkcon;
		9'h016: custom_read = 16'h5500;       // POTGOR: no buttons (userio.v potcap)
		9'h018: custom_read = 16'h3800;       // SERDATR: TBE, TSRE, RXD idle
		9'h01C: custom_read = intena;
		9'h01E: custom_read = intreq;
		9'h07C: custom_read = 16'h00F8;       // DENISEID: Lisa (denise.v, aga)
		default: custom_read = 16'h0000;      // minimig ORs every unit; unselected = 0
	endcase
endfunction

task automatic custom_write(input [8:1] r, input [15:0] v);
	begin
		creg[r] = v;
		case ({r, 1'b0})
			9'h096: dmacon = setclr(dmacon, v) & 16'h07FF;
			9'h09A: intena = setclr(intena, v) & 16'h7FFF;
			9'h09C: intreq = setclr(intreq, v) & 16'h7FFF;
			9'h09E: adkcon = setclr(adkcon, v) & 16'h7FFF;
			9'h058, 9'h05E: intreq[6] = 1'b1;   // BLTSIZE/BLTSIZH: blit "done"
			9'h024: if (v[15]) dsk_start = 1'b1;   // DSKLEN with DMAEN: the first track read
			default: ;
		endcase
		update_irq;
	end
endtask

//------------------------------------------------------------------ bus
function integer latency(input [31:0] a);
	begin
		if (a[31:24] != 0)                 latency = 1;
		else if (a[23:21] == 3'b000)       latency = 2;   // chip
		else if (a[23:19] == 5'b11111)     latency = 1;   // ROM
		else if (a[23:20] == 4'hB)         latency = 4;   // CIA
		else if (a[23:16] == 8'hDF)        latency = 4;   // custom
		else if (a[23:19] == 5'b11000)     latency = 2;   // slow
		else                               latency = 1;
	end
endfunction

reg        busy;
integer    cnt;
reg [15:0] rv;
reg  [7:0] cb;

task automatic access;
	reg        wr, isdata, io;
	reg [23:0] a;
	begin
		wr = (busstate == 2'b11);
		isdata = (busstate != 2'b00);
		a = addr[23:0];
		rv = 16'hFFFF;
		io = (addr[31:24] == 0) && (a[23:21] == 3'b101 || a[23:21] == 3'b110);
		if (isdata && io) begin
			io_count = io_count + 64'd1;
			if (timebase == 0)
				for (i = 0; i < tpa; i = i + 1) tick_cck;
		end
		if (addr[31:24] != 0) ;                                // unmapped
		else if (a[23:21] == 3'b000) begin                     // chip RAM
			if (ovl && a[23:19] == 5'b00000) begin
				if (!wr) rv = rom[a[18:1]];
			end
			else if (wr) begin
				if (!nuds) chip[a[20:1]][15:8] = wdata[15:8];
				if (!nlds) chip[a[20:1]][7:0]  = wdata[7:0];
			end
			else rv = chip[a[20:1]];
		end
		else if (a[23:19] == 5'b11111) begin                   // ROM
			if (!wr) rv = rom[a[18:1]];
		end
		else if (a[23:19] == 5'b11000 && slow_ena != 0) begin  // slow RAM
			if (wr) begin
				if (!nuds) slow[a[18:1]][15:8] = wdata[15:8];
				if (!nlds) slow[a[18:1]][7:0]  = wdata[7:0];
			end
			else rv = slow[a[18:1]];
		end
		else if (a[23:20] == 4'hB) begin                       // CIAs
			if (wr) begin
				if (!a[12] && !nlds) cia_write(0, a[11:8], wdata[7:0]);
				if (!a[13] && !nuds) cia_write(1, a[11:8], wdata[15:8]);
			end
			else begin
				if (!a[12]) begin rv[7:0]  = cia_read(0, a[11:8]); cia_read_fx(0, a[11:8]); end
				if (!a[13]) begin rv[15:8] = cia_read(1, a[11:8]); cia_read_fx(1, a[11:8]); end
			end
		end
		else if (a[23:16] == 8'hDF) begin                      // custom
			if (wr) custom_write(a[8:1], wdata);
			else rv = custom_read(a[8:1]);
		end
		// else unmapped: $FFFF
	end
endtask

integer c0;
reg [2:0] clk_div = 0;
always @(posedge clk) clk_div <= nreset ? clk_div + 3'd1 : 3'd0;

always @(posedge clk) begin
	ready <= 1'b0;
	if (!nreset) begin
		busy = 0;
		cnt = 0;
		io_count = 0;
		cck = 0;
		frame = 0;
		etick_acc = 0;
		dmacon = 0; intena = 0; intreq = 0; adkcon = 0;
		dsk_start = 1'b0;
		mtr = 4'd0; cyl = 7'd10; chng_n = 1'b0; prb_q = 8'hFF;
		for (c0 = 0; c0 < 2; c0 = c0 + 1) begin
			pra[c0] = 8'hFF; prb[c0] = 8'hFF; ddra[c0] = 0; ddrb[c0] = 0; sdr[c0] = 0;
			ta[c0] = 16'hFFFF; tb[c0] = 16'hFFFF; tla[c0] = 16'hFFFF; tlb[c0] = 16'hFFFF;
			cra[c0] = 0; crb[c0] = 0; icr[c0] = 0; icrmask[c0] = 0;
			tod[c0] = 0; alarm[c0] = 24'hFFFFFF; todlatch[c0] = 0;
			todlatched[c0] = 0; todrun[c0] = 0;
		end
	end
	else begin
		if (!rsto_n) begin
			// the CPU's RESET instruction: the chipset's reset (CIAs: OVL
			// back on; Paula's enables and requests; DMA off)
			dmacon = 0; intena = 0; intreq = 0;
			for (c0 = 0; c0 < 2; c0 = c0 + 1) begin
				pra[c0] = 8'hFF; prb[c0] = 8'hFF; ddra[c0] = 0; ddrb[c0] = 0;
				cra[c0] = 0; crb[c0] = 0; icr[c0] = 0; icrmask[c0] = 0;
			end
		end
		if (timebase != 0 && clk_div == 3'd7) tick_cck;
		// stopped with nothing above the mask: run device time forward
		else if (timebase == 0 && stopped && !(level > mask)) tick_cck;
		if (busstate != 2'b01 && !ready) begin
			if (!busy) begin
				busy = 1;
				cnt = latency(addr) - 1;
				if (cnt == 0) begin access; rdata <= rv; ready <= 1'b1; busy = 0; end
			end
			else if (cnt <= 1) begin
				access; rdata <= rv; ready <= 1'b1; busy = 0;
			end
			else cnt = cnt - 1;
		end
	end
end

endmodule
