// gayle_tb.v -- the two-port Gayle with ATAPI packet mode
// (findings/cdrom/plan.md 7.3, task 1.1).
//
// Drives gayle directly: the 68k side (sel_ide, address, rd/hwr/lwr on
// clk7_en) and the firmware side (the hdd_* strobes paula_floppy.v would
// make, plus the port bit).  Every case starts from a reset.
//
//   (a) port 0 ATA READ SECTORS x2, WRITE SECTORS, IDENTIFY, an abort: the
//       irq/nrdy/cmd_req/dat_req changes and every value read are printed as
//       TRACE lines, which run.sh compares with golden_a.txt -- recorded from
//       gayle.v as it was at 8208e2b, before the split
//   (b) PACKET on port 1: the 12-byte command packet (6 words) in packet mode
//   (c) data-in 18 bytes on port 1: DRQ and the interrupt only with all 9 words
//   (d) data-in 1024 words: DRQ after 256 words, nrdy when the host outruns
//   (e) the signature mux per port and device
//   (f) sticky dev_wr / rst_seen: seen by one firmware register read, then clear
//   (g) $DA3018 with port 2 on leaves port 1's tfr[6] and device select alone
//   (h) a command on one port while the other is busy, both orders
//   (i) port 2 disabled: $DA1xxx/$DA3xxx not decoded, firmware writes to
//       port 2 do not reach port 1
//
// OLD_GAYLE: compile against the one-port gayle.v (no port bit, no packet
// mode) -- (a) must still pass, that is how the golden trace is recorded.

`timescale 1ns/1ps

module gayle_tb;

reg clk = 0;
always #17.5 clk = ~clk;		// ~28 MHz

reg [1:0] div = 0;
always @(negedge clk) div <= div + 2'd1;
wire clk7_en = (div == 2'd0);

reg         reset = 1;
reg  [23:1] address_in = 0;
reg  [15:0] data_in = 0;
wire [15:0] data_out;
reg         rd = 0, hwr = 0, lwr = 0;
reg         sel_ide = 0, sel_gayle = 0;
wire        irq, nrdy;
reg   [1:0] hdd0_ena = 2'b01, hdd1_ena = 2'b00;
reg   [1:0] hdd0_atapi = 2'b00, hdd1_atapi = 2'b00;
wire        hdd_cmd_req, hdd_dat_req;
reg   [2:0] hdd_addr = 0;
reg  [15:0] hdd_data_out = 0;
wire [15:0] hdd_data_in;
reg         hdd_wr = 0, hdd_status_wr = 0, hdd_data_wr = 0, hdd_data_rd = 0;
reg         hdd_port = 0, hdd_xfer_wr = 0, hdd_regs_rd = 0;
wire        hd_fwr, hd_frd;

gayle dut
(
	.clk(clk),
	.clk7_en(clk7_en),
	.reset(reset),
	.address_in(address_in),
	.data_in(data_in),
	.data_out(data_out),
	.rd(rd),
	.hwr(hwr),
	.lwr(lwr),
	.sel_ide(sel_ide),
	.sel_gayle(sel_gayle),
	.irq(irq),
	.nrdy(nrdy),
	.hdd0_ena(hdd0_ena),
	.hdd1_ena(hdd1_ena),
`ifndef OLD_GAYLE
	.hdd0_atapi(hdd0_atapi),
	.hdd1_atapi(hdd1_atapi),
	.hdd_port(hdd_port),
	.hdd_xfer_wr(hdd_xfer_wr),
	.hdd_regs_rd(hdd_regs_rd),
`endif
	.hdd_cmd_req(hdd_cmd_req),
	.hdd_dat_req(hdd_dat_req),
	.hdd_addr(hdd_addr),
	.hdd_data_out(hdd_data_out),
	.hdd_data_in(hdd_data_in),
	.hdd_wr(hdd_wr),
	.hdd_status_wr(hdd_status_wr),
	.hdd_data_wr(hdd_data_wr),
	.hdd_data_rd(hdd_data_rd),
	.hd_fwr(hd_fwr),
	.hd_frd(hd_frd)
);

//----------------------------------------------------------------------------
// Bookkeeping

integer errors = 0;		// all cases
integer cerr = 0;		// this case
reg [8*4-1:0] cname;

task check(input cond, input [8*64-1:0] what);
	begin
		if (cond !== 1'b1) begin
			cerr = cerr + 1;
			$display("  mismatch (%0s): %0s", cname, what);
		end
	end
endtask

task begin_case(input [8*4-1:0] n);
	begin
		cname = n;
		cerr = 0;
		$display("--- case %0s", n);
	end
endtask

task end_case(input [8*64-1:0] what);
	begin
		if (cerr == 0)
			$display("  ok   %0s %0s", cname, what);
		else begin
			$display("FAIL   %0s %0s (%0d mismatches)", cname, what, cerr);
			errors = errors + 1;
		end
	end
endtask

// firmware flag bits in hdd_data_in[15:8] of a task file register read
localparam F_PORT = 8, F_XDONE = 9, F_DEVWR = 10, F_RST = 11, F_PKT = 12, F_BSY0 = 13, F_BSY1 = 14;

//----------------------------------------------------------------------------
// Golden trace (case a)

reg tracing = 0;
integer tcyc = 0;
reg [3:0] tlast = 4'bxxxx;
always @(posedge clk)
	if (clk7_en && tracing) begin
		if ({irq, nrdy, hdd_cmd_req, hdd_dat_req} !== tlast)
			$display("TRACE %0d irq=%b nrdy=%b cmd=%b dat=%b", tcyc, irq, nrdy, hdd_cmd_req, hdd_dat_req);
		tlast = {irq, nrdy, hdd_cmd_req, hdd_dat_req};
		tcyc = tcyc + 1;
	end

//----------------------------------------------------------------------------
// Bus tasks.  "en" returns 2 ns after a clk7_en edge; inputs set then are
// sampled by the next clk7_en edge.

task en;
	begin
		@(posedge clk);
		while (!clk7_en) @(posedge clk);
		#2;
	end
endtask

task idle(input integer n);
	integer k;
	begin
		for (k = 0; k < n; k = k + 1) en;
	end
endtask

task set_addr(input [23:0] a);
	begin
		address_in = a[23:1];
		sel_ide = (a[23:16] == 8'hDA);
		sel_gayle = (a[23:12] == 12'hDE1);
	end
endtask

task bus_off;
	begin
		rd = 0; hwr = 0; lwr = 0; sel_ide = 0; sel_gayle = 0;
	end
endtask

// byte write to an even address (task file registers)
task hwb(input [23:0] a, input [7:0] d);
	begin
		set_addr(a);
		data_in = {d, d};
		hwr = 1;
		en;
		bus_off;
	end
endtask

// word write
task hww(input [23:0] a, input [15:0] d);
	begin
		set_addr(a);
		data_in = d;
		hwr = 1; lwr = 1;
		en;
		bus_off;
	end
endtask

// word read; waits out nrdy like the m68k bridge does (no cycle until it drops)
task hr(input [23:0] a, output [15:0] d);
	integer guard;
	begin
		set_addr(a);
		en;				// address setup: a 68k cycle is several clk7 long
		guard = 0;
		while (nrdy && guard < 2000) begin
			en;
			guard = guard + 1;
		end
		rd = 1;
		#1 d = data_out;
		en;
		bus_off;
		if (tracing) $display("TRACE %0d host rd %h = %h", tcyc, a, d);
	end
endtask

// the firmware side
task fw_status(input p, input [7:0] st);
	begin
		hdd_port = p;
		hdd_data_out = {7'b1111000, p, st};
		hdd_status_wr = 1;
		en;
		hdd_status_wr = 0;
	end
endtask

task fw_tfr_wr(input p, input [2:0] r, input [7:0] v);
	begin
		hdd_port = p;
		hdd_addr = r;
		hdd_data_out = {8'h00, v};
		hdd_wr = 1;
		en;
		hdd_wr = 0;
		hdd_addr = 0;
	end
endtask

// CMD_IDE_REGS_RD: the command word (port bit latched, regs_rd strobe)
task fw_regs_rd(input p);
	begin
		hdd_port = p;
		hdd_regs_rd = 1;
		en;
		hdd_regs_rd = 0;
	end
endtask

task fw_tfr_rd(input p, input [2:0] r, output [15:0] v);
	begin
		hdd_port = p;
		hdd_addr = r;
		#1 v = hdd_data_in;
		en;
		hdd_addr = 0;
		if (tracing) $display("TRACE %0d fw tfr %0d = %h", tcyc, r, v[7:0]);
	end
endtask

// a whole register read; returns the register-7 word (flags in 15:8)
reg [7:0] tf [0:7];
task fw_read_all(input p, output [15:0] w7);
	integer k;
	reg [15:0] v;
	begin
		fw_regs_rd(p);
		for (k = 1; k < 8; k = k + 1) begin
			fw_tfr_rd(p, k, v);
			tf[k] = v[7:0];
		end
		w7 = v;
	end
endtask

task fw_data_wr(input p, input [15:0] w);
	begin
		hdd_port = p;
		hdd_data_out = w;
		hdd_data_wr = 1;
		en;
		hdd_data_wr = 0;
	end
endtask

task fw_data_rd(input p, output [15:0] w);
	begin
		hdd_port = p;
		hdd_addr = 0;
		#1 w = hdd_data_in;
		hdd_data_rd = 1;
		en;
		hdd_data_rd = 0;
		en;
	end
endtask

// CMD_IDE_XFER_WR: {pkt, 2'b0, words[12:0]}
task fw_xfer(input p, input [12:0] words, input pkt);
	begin
		hdd_port = p;
		hdd_data_out = {pkt, 2'b00, words};
		hdd_xfer_wr = 1;
		en;
		hdd_xfer_wr = 0;
	end
endtask

task fw_wait_cmd(output ok);
	integer guard;
	begin
		guard = 0;
		#1;
		while (!hdd_cmd_req && guard < 200) begin
			en; #1;
			guard = guard + 1;
		end
		ok = hdd_cmd_req;
		if (tracing) $display("TRACE %0d fw saw cmd_req=%b", tcyc, hdd_cmd_req);
	end
endtask

task fw_wait_dat(output ok);
	integer guard;
	begin
		guard = 0;
		#1;
		while (!hdd_dat_req && guard < 200) begin
			en; #1;
			guard = guard + 1;
		end
		ok = hdd_dat_req;
		if (tracing) $display("TRACE %0d fw saw dat_req=%b", tcyc, hdd_dat_req);
	end
endtask

task do_reset(input [1:0] e0, input [1:0] e1, input [1:0] a0, input [1:0] a1);
	begin
		bus_off;
		hdd_wr = 0; hdd_status_wr = 0; hdd_data_wr = 0; hdd_data_rd = 0;
		hdd_xfer_wr = 0; hdd_regs_rd = 0; hdd_port = 0; hdd_addr = 0;
		hdd0_ena = e0; hdd1_ena = e1; hdd0_atapi = a0; hdd1_atapi = a1;
		reset = 1;
		idle(4);
		reset = 0;
		idle(2);
		hww(24'hDAA000, 16'h8000);	// INTENA
	end
endtask

// the host side of starting a command: registers, then the command byte
task host_cmd(input [23:0] base, input [7:0] cnt, input [7:0] sec, input [7:0] cl, input [7:0] ch, input [7:0] dh, input [7:0] c);
	begin
		hwb(base + 24'h08, cnt);
		hwb(base + 24'h0C, sec);
		hwb(base + 24'h10, cl);
		hwb(base + 24'h14, ch);
		hwb(base + 24'h18, dh);
		hwb(base + 24'h1C, c);
	end
endtask

task irq_clear;
	begin
		hww(24'hDA9000, 16'h0000);
	end
endtask

//----------------------------------------------------------------------------

reg [15:0] v, w7;
reg ok;
integer i, n;

initial begin
	idle(2);

	//======================================================================
	// (a) port 0, ATA, packet mode never used: the golden trace
	begin_case("a");
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	tracing = 1; tcyc = 0;

	// a1: READ SECTORS, 2 sectors
	host_cmd(24'hDA2000, 8'd2, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h20);
	fw_wait_cmd(ok);
	check(ok, "a1 cmd_req after the command");
	fw_read_all(0, w7);
	check(tf[7] == 8'h20 && tf[2] == 8'd2, "a1 firmware sees the command and count");
	fw_tfr_wr(0, 1, 8'h00); fw_tfr_wr(0, 2, 8'd2); fw_tfr_wr(0, 3, 8'd2);
	fw_tfr_wr(0, 4, 8'h00); fw_tfr_wr(0, 5, 8'h00); fw_tfr_wr(0, 6, 8'hA0);
	for (n = 0; n < 2; n = n + 1) begin
		fw_status(0, 8'h08);
		fw_wait_cmd(ok);
		check(ok, "a1 cmd_req (FIFO drained) before the block");
		for (i = 0; i < 256; i = i + 1)
			fw_data_wr(0, (n ? 16'hB000 : 16'hA000) + i);
		hr(24'hDA201C, v);
		check(v[15:8] == 8'h08, "a1 status DRQ");
		irq_clear;
		for (i = 0; i < 256; i = i + 1) begin
			hr(24'hDA2000, v);
			if (v !== (n ? 16'hB000 : 16'hA000) + i) check(0, "a1 sector data");
		end
	end
	idle(2);
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h40, "a1 status after the last word: DRDY");
	hr(24'hDA2004, v);

	// a2: WRITE SECTORS, 1 sector
	host_cmd(24'hDA2000, 8'd1, 8'd5, 8'd0, 8'd0, 8'hA0, 8'h30);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	check(tf[7] == 8'h30, "a2 command");
	fw_tfr_wr(0, 1, 8'h00); fw_tfr_wr(0, 2, 8'd1); fw_tfr_wr(0, 3, 8'd5);
	fw_tfr_wr(0, 4, 8'h00); fw_tfr_wr(0, 5, 8'h00); fw_tfr_wr(0, 6, 8'hA0);
	fw_status(0, 8'h04);
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h08, "a2 status DRQ for the data");
	for (i = 0; i < 256; i = i + 1)
		hww(24'hDA2000, 16'hC000 + i);
	fw_wait_dat(ok);
	check(ok, "a2 dat_req with a full block");
	for (i = 0; i < 256; i = i + 1) begin
		fw_data_rd(0, v);
		if (v !== 16'hC000 + i) check(0, "a2 data seen by the firmware");
	end
	fw_status(0, 8'h90);
	idle(2);
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h40, "a2 status after END");
	hr(24'hDA9000, v);
	irq_clear;

	// a3: IDENTIFY DEVICE
	host_cmd(24'hDA2000, 8'd0, 8'd0, 8'd0, 8'd0, 8'hA0, 8'hEC);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	check(tf[7] == 8'hEC, "a3 command");
	fw_status(0, 8'h08);
	for (i = 0; i < 256; i = i + 1)
		fw_data_wr(0, 16'hD000 + i);
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h08, "a3 status DRQ");
	irq_clear;
	for (i = 0; i < 256; i = i + 1) begin
		hr(24'hDA2000, v);
		if (v !== 16'hD000 + i) check(0, "a3 identify data");
	end
	fw_status(0, 8'h90);
	idle(2);
	hr(24'hDA201C, v);

	// a4: an unknown command, aborted
	host_cmd(24'hDA2000, 8'd0, 8'd0, 8'd0, 8'd0, 8'hA0, 8'hE5);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_tfr_wr(0, 1, 8'h04);
	fw_status(0, 8'h91);
	idle(2);
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h41, "a4 status ERR");
	hr(24'hDA2004, v);
	check(v[15:8] == 8'h04, "a4 error ABRT");
	hr(24'hDA9000, v);
	check(v[15] == 1'b1, "a4 intreq");
	irq_clear;
	tracing = 0;
	end_case("port 0 ATA, golden trace");

	//======================================================================
	// (b) PACKET on port 1: command packet phase
	begin_case("b");
	do_reset(2'b01, 2'b01, 2'b00, 2'b01);
	host_cmd(24'hDA3000, 8'd0, 8'd0, 8'h00, 8'h08, 8'hA0, 8'hA0);	// byte count limit 0x0800
	fw_wait_cmd(ok);
	check(ok, "cmd_req for the PACKET command");
	fw_read_all(1, w7);
	check(tf[7] == 8'hA0, "port 1 command register = A0");
	check(w7[F_PORT] == 1'b1, "flag: port 1");
	check(w7[F_BSY1] == 1'b1 && w7[F_BSY0] == 1'b0, "flags: bsy[1] set, bsy[0] clear");
	fw_tfr_wr(1, 2, 8'h01);			// interrupt reason CoD
	fw_xfer(1, 13'd6, 1'b1);
	fw_status(1, 8'h04);			// pio out, no IRQ
	idle(1);
	hr(24'hDA301C, v);
	check(v[15:8] == 8'h08, "status DRQ, not BSY");
	hr(24'hDA3008, v);
	check(v[15:8] == 8'h01, "interrupt reason readable while the command runs");
	check(irq == 1'b0, "no interrupt for the packet phase");
	for (i = 0; i < 5; i = i + 1)
		hww(24'hDA3000, 16'h1200 + i);
	hr(24'hDA301C, v);
	check(v[11] == 1'b1, "DRQ still set after 5 of 6 words");
	check(hdd_dat_req == 1'b0, "no dat_req before the 6th word");
	hww(24'hDA3000, 16'h1205);
	idle(1);
	hr(24'hDA301C, v);
	check(v[15:8] == 8'h80, "after 6 words: DRQ clear, BSY set");
	hdd_port = 1; #1;
	check(hdd_dat_req == 1'b1, "dat_req after the 6th word");
	fw_read_all(1, w7);
	check(w7[F_XDONE] == 1'b1, "flag: xfer_done");
	check(w7[F_PKT] == 1'b1, "flag: pkt_mode");
	for (i = 0; i < 6; i = i + 1) begin
		fw_data_rd(1, v);
		if (v !== 16'h1200 + i) check(0, "packet bytes seen by the firmware");
	end
	end_case("PACKET command phase on port 1");

	//======================================================================
	// (c) data-in 18 bytes on port 1 (continues b)
	begin_case("c");
	irq_clear;
	fw_tfr_wr(1, 2, 8'h02); fw_tfr_wr(1, 4, 8'd18); fw_tfr_wr(1, 5, 8'd0);
	fw_xfer(1, 13'd9, 1'b1);
	fw_status(1, 8'h08);			// pio in
	for (i = 0; i < 8; i = i + 1)
		fw_data_wr(1, 16'h3300 + i);
	idle(2);
	hr(24'hDA301C, v);
	check(v[11] == 1'b0, "no DRQ with 8 of 9 words");
	check(irq == 1'b0, "no interrupt with 8 of 9 words");
	fw_data_wr(1, 16'h3308);
	idle(2);
	check(irq == 1'b1, "interrupt with the 9th word");
	hr(24'hDA301C, v);
	check(v[15:8] == 8'h08, "DRQ with the 9th word");
	hr(24'hDA3010, v);
	check(v[15:8] == 8'd18, "byte count 18");
	irq_clear;
	for (i = 0; i < 9; i = i + 1) begin
		hr(24'hDA3000, v);
		if (v !== 16'h3300 + i) check(0, "response data");
	end
	idle(1);
	hr(24'hDA301C, v);
	check(v[15:8] == 8'h80, "after 9 words: BSY between phases, no DRQ");
	fw_read_all(1, w7);
	check(w7[F_XDONE] == 1'b1, "flag: xfer_done after the host drained");
	// status phase
	fw_tfr_wr(1, 2, 8'h03);
	fw_status(1, 8'h90);
	idle(1);
	check(irq == 1'b1, "interrupt for the status phase");
	hr(24'hDA301C, v);
	check(v[15:8] == 8'h40, "status phase: DRDY, no BSY/DRQ");
	hr(24'hDA3008, v);
	check(v[15:8] == 8'h03, "interrupt reason IO|CoD");
	end_case("18-byte data-in on port 1");

	//======================================================================
	// (d) data-in 1024 words, streaming
	begin_case("d");
	do_reset(2'b01, 2'b01, 2'b00, 2'b01);
	host_cmd(24'hDA3000, 8'd1, 8'd0, 8'hFE, 8'hFF, 8'hA0, 8'hA0);
	fw_wait_cmd(ok);
	fw_read_all(1, w7);
	fw_tfr_wr(1, 2, 8'h01);
	fw_xfer(1, 13'd6, 1'b1);
	fw_status(1, 8'h04);
	for (i = 0; i < 6; i = i + 1)
		hww(24'hDA3000, 16'h2800 + i);
	fw_wait_dat(ok);
	for (i = 0; i < 6; i = i + 1)
		fw_data_rd(1, v);
	fw_tfr_wr(1, 2, 8'h02); fw_tfr_wr(1, 4, 8'h00); fw_tfr_wr(1, 5, 8'h08);
	fw_xfer(1, 13'd1024, 1'b1);
	fw_status(1, 8'h08);
	for (i = 0; i < 255; i = i + 1)
		fw_data_wr(1, i);
	idle(1);
	hr(24'hDA301C, v);
	check(v[11] == 1'b0, "no DRQ with 255 words");
	fw_data_wr(1, 255);
	idle(1);
	hr(24'hDA301C, v);
	check(v[11] == 1'b1, "DRQ with 256 words");
	for (i = 0; i < 256; i = i + 1) begin
		hr(24'hDA3000, v);
		if (v !== i) check(0, "stream data, block 1");
	end
	set_addr(24'hDA3000); #1;
	check(nrdy == 1'b1, "nrdy when the host outruns the writer");
	bus_off;
	n = 256;
	for (i = 256; i < 1024; i = i + 1)
		fw_data_wr(1, i);
	for (i = 256; i < 1024; i = i + 1) begin
		hr(24'hDA3000, v);
		if (v !== i) check(0, "stream data, rest");
	end
	idle(1);
	hr(24'hDA301C, v);
	check(v[15:8] == 8'h80, "after 1024 words: BSY, no DRQ (no ATA sector-count end)");
	set_addr(24'hDA3000); #1;
	check(nrdy == 1'b0, "no nrdy once the transfer is over");
	bus_off;
	fw_read_all(1, w7);
	check(w7[F_XDONE] == 1'b1, "flag: xfer_done");
	end_case("1024-word data-in, streaming");

	//======================================================================
	// (e) signature per port and device
	begin_case("e");
	do_reset(2'b11, 2'b11, 2'b00, 2'b01);	// port 1: master ATAPI, slave ATA
	hr(24'hDA2004, v); check(v[15:8] == 8'h01, "port 0 master error 01");
	hr(24'hDA2008, v); check(v[15:8] == 8'h01, "port 0 master count 01");
	hr(24'hDA200C, v); check(v[15:8] == 8'h01, "port 0 master sector 01");
	hr(24'hDA2010, v); check(v[15:8] == 8'h00, "port 0 master cyl low 00");
	hr(24'hDA2014, v); check(v[15:8] == 8'h00, "port 0 master cyl high 00");
	hwb(24'hDA3018, 8'hA0);
	hr(24'hDA3004, v); check(v[15:8] == 8'h01, "port 1 master error 01");
	hr(24'hDA3008, v); check(v[15:8] == 8'h01, "port 1 master count 01");
	hr(24'hDA300C, v); check(v[15:8] == 8'h01, "port 1 master sector 01");
	hr(24'hDA3010, v); check(v[15:8] == 8'h14, "port 1 master (ATAPI) cyl low 14");
	hr(24'hDA3014, v); check(v[15:8] == 8'hEB, "port 1 master (ATAPI) cyl high EB");
	hwb(24'hDA3018, 8'hB0);
	hr(24'hDA3010, v); check(v[15:8] == 8'h00, "port 1 slave (ATA) cyl low 00");
	hr(24'hDA3014, v); check(v[15:8] == 8'h00, "port 1 slave (ATA) cyl high 00");
	hwb(24'hDA3018, 8'hA0);
	hwb(24'hDA3008, 8'h55);
	hr(24'hDA3008, v); check(v[15:8] == 8'h55, "a host write replaces that register's signature");
	hr(24'hDA3014, v); check(v[15:8] == 8'hEB, "... and only that register's");
	// DEVICE RESET: the firmware re-arms the signature with status bit 5
	hwb(24'hDA301C, 8'h08);
	fw_wait_cmd(ok);
	fw_read_all(1, w7);
	fw_status(1, 8'hB0);			// END | IRQ | signature
	idle(1);
	hr(24'hDA3008, v); check(v[15:8] == 8'h01, "signature re-armed: count 01");
	hr(24'hDA3010, v); check(v[15:8] == 8'h14, "signature re-armed: cyl low 14");
	hr(24'hDA2010, v); check(v[15:8] == 8'h00, "port 0 unaffected");
	end_case("signature mux");

	//======================================================================
	// (f) sticky flags
	begin_case("f");
	do_reset(2'b01, 2'b01, 2'b00, 2'b01);
	fw_read_all(1, w7);
	check(w7[F_RST] == 1'b1, "port 1 rst_seen after a reset");
	check(w7[F_DEVWR] == 1'b0, "port 1 dev_wr clear");
	fw_read_all(1, w7);
	check(w7[F_RST] == 1'b0, "rst_seen read once, then clear");
	hwb(24'hDA3018, 8'hB0);
	fw_read_all(1, w7);
	check(w7[F_DEVWR] == 1'b1, "dev_wr after a drive/head write");
	fw_read_all(1, w7);
	check(w7[F_DEVWR] == 1'b0, "dev_wr read once, then clear");
	fw_read_all(0, w7);
	check(w7[F_RST] == 1'b1, "port 0 keeps its own rst_seen");
	check(w7[F_PORT] == 1'b0, "flag: port 0");
	end_case("sticky dev_wr / rst_seen");

	//======================================================================
	// (g) $DA3018 does not touch port 1
	begin_case("g");
	do_reset(2'b01, 2'b10, 2'b00, 2'b00);	// port 0 master only, port 1 slave only
	hwb(24'hDA2018, 8'hE0);
	hwb(24'hDA3018, 8'h02);			// A1200 device control
	hr(24'hDA2018, v);
	check(v[15:8] == 8'hE0, "port 0 drive/head unchanged");
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h40, "port 0 status still the master's");
	hwb(24'hDA201C, 8'hEC);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	check(tf[6] == 8'hE0, "firmware sees port 0 drive/head E0");
	end_case("$DA3018 isolation");

	//======================================================================
	// (h) a command on one port while the other is busy
	begin_case("h");
	do_reset(2'b01, 2'b01, 2'b00, 2'b01);
	// order 1: port 1 (packet) first
	hwb(24'hDA3018, 8'hA0);
	hwb(24'hDA301C, 8'hA0);
	hdd_port = 0; #1;
	check(hdd_cmd_req == 1'b1, "1: port 1's command visible while port 0 is idle");
	fw_read_all(1, w7);
	fw_tfr_wr(1, 2, 8'h01);
	fw_xfer(1, 13'd6, 1'b1);
	fw_status(1, 8'h04);
	#1 check(hdd_cmd_req == 1'b0, "1: no cmd_req while port 1 waits for the packet");
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h20);
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h80, "1: port 0 accepted the command (BSY)");
	hdd_port = 1; #1;
	check(hdd_cmd_req == 1'b0, "1: port 0's command hidden while port 1 is served");
	for (i = 0; i < 6; i = i + 1)
		hww(24'hDA3000, 16'h4400 + i);
	fw_wait_dat(ok);
	check(ok, "1: port 1 packet received");
	fw_status(1, 8'h90);			// port 1 done
	#1 check(hdd_cmd_req == 1'b1, "1: port 0's command visible once port 1 is idle");
	fw_read_all(0, w7);
	check(tf[7] == 8'h20, "1: port 0 command register = 20");
	check(w7[F_BSY0] == 1'b1 && w7[F_BSY1] == 1'b0, "1: flags bsy[0] only");
	fw_status(0, 8'h90);
	idle(1);
	irq_clear;
	// order 2: port 0 (ATA read) first
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h20);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h08);
	for (i = 0; i < 256; i = i + 1)
		fw_data_wr(0, i);
	hwb(24'hDA301C, 8'hA0);			// port 1 command while port 0 has DRQ
	hdd_port = 0; #1;
	check(hdd_cmd_req == 1'b0, "2: port 1's command does not release port 0's read loop");
	for (i = 0; i < 128; i = i + 1)
		hr(24'hDA2000, v);
	hdd_port = 0; #1;
	check(hdd_cmd_req == 1'b0, "2: still hidden with half a block read");
	for (i = 128; i < 256; i = i + 1)
		hr(24'hDA2000, v);
	idle(1);
	hdd_port = 0; #1;
	check(hdd_cmd_req == 1'b1, "2: cmd_req once port 0 is idle (port 1's command)");
	fw_read_all(0, w7);
	check(w7[F_BSY1] == 1'b1 && w7[F_BSY0] == 1'b0, "2: flags bsy[1] only");
	fw_read_all(1, w7);
	check(tf[7] == 8'hA0, "2: port 1 command register = A0");
	end_case("one port busy, the other gets a command");

	//======================================================================
	// (i) port 2 disabled
	begin_case("i");
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	hwb(24'hDA2018, 8'hA0);
	hwb(24'hDA3018, 8'hB0);
	hr(24'hDA2018, v);
	check(v[15:8] == 8'hA0, "port 0 drive/head unchanged");
	hr(24'hDA301C, v);
	check(v == 16'h0000, "$DA301C reads 0");
	hwb(24'hDA301C, 8'hA0);
	idle(1); #1;
	check(hdd_cmd_req == 1'b0, "no command from $DA301C");
	set_addr(24'hDA3000); #1;
	check(nrdy == 1'b0, "no nrdy from $DA3000");
	bus_off;
	// firmware writes addressed to port 2 must not reach port 1
	hwb(24'hDA201C, 8'hEC);
	fw_wait_cmd(ok);
	fw_status(1, 8'h80);			// END to port 2
	idle(1);
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h80, "port 0 still BSY after an END for port 2");
	fw_tfr_wr(1, 6, 8'h5A);
	fw_read_all(0, w7);
	check(tf[6] == 8'hA0, "port 0 drive/head untouched by a port 2 register write");
	end_case("port 2 disabled");

	//======================================================================
	if (errors == 0)
		$display("=== PASS");
	else
		$display("=== FAIL (%0d cases)", errors);
	$finish;
end

initial begin
	#200000000;
	$display("=== FAIL (timeout)");
	$finish;
end

endmodule
