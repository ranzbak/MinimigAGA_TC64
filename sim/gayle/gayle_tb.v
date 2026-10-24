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
//
// SDC_BRIDGE: the SD card bridge (rtl/minimig/sdcard_gayle.v, plan Task 7) and
// its mux sit in front of the firmware-side data port, with a model of
// sdcard_spi's clk_114 g_* side that checks the contract.  (a) moves its
// sector data through the bridge (its trace must match golden_a.txt event for
// event), (b)-(i) run through the idle mux, and:
//   (j) t_bridge_read: READ MULTIPLE 4, two groups of 512 words, the Amiga
//       reading on the interrupt while the bridge streams
//   (k) t_bridge_write: WRITE MULTIPLE 2, one op waiting for dat_req per sector
//   (l) t_fifo_reset_mid_dma: a new command (dir 1, dir 0 before / after
//       dat_req) or an Amiga reset mid-op: g_err, no strobe after the reset
//   (m) t_two_ports: the other port's command leaves the DMA alone
//   (n) paula_floppy data strobes during a bridge op have no effect
//   (o) g_req: one-cycle ops, drops mid-op at every offset (also with long
//       g_wvalid gaps), and ops starting 1-8 clk_114 cycles after a drop:
//       each op moves exactly its own words, none written without its pop
//   (p) dir 0 right after a task file read (paula_floppy's hdd_addr sticky)
//   (q) a new command between two READ MULTIPLE groups: the next op g_err
// SDC_ASYNC: clk_114 at 112.4 MHz instead of 4 x clk.

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

// What Gayle gets on the firmware-side data port.  Without SDC_BRIDGE the
// bench's hdd_* (what paula_floppy.v would make) go straight in; with it they
// are the paula_floppy side of rtl/minimig/sdcard_gayle.v's mux, and the
// bridge is the other side (see "SD card bridge" below).
wire        gy_port, gy_data_wr, gy_data_rd;
wire [15:0] gy_data_out;
wire  [2:0] gy_addr;
`ifndef SDC_BRIDGE
assign gy_addr = hdd_addr;
assign gy_port = hdd_port;
assign gy_data_wr = hdd_data_wr;
assign gy_data_rd = hdd_data_rd;
assign gy_data_out = hdd_data_out;
`endif

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
	.hdd_port(gy_port),
	.hdd_xfer_wr(hdd_xfer_wr),
	.hdd_regs_rd(hdd_regs_rd),
`endif
	.hdd_cmd_req(hdd_cmd_req),
	.hdd_dat_req(hdd_dat_req),
	.hdd_addr(gy_addr),
	.hdd_data_out(gy_data_out),
	.hdd_data_in(hdd_data_in),
	.hdd_wr(hdd_wr),
	.hdd_status_wr(hdd_status_wr),
	.hdd_data_wr(gy_data_wr),
	.hdd_data_rd(gy_data_rd),
`ifdef SDC_BRIDGE
	.hdd_fifo_reset(gy_fifo_reset),
`endif
	.hd_fwr(hd_fwr),
	.hd_frd(hd_frd)
);

`ifdef SDC_BRIDGE
//----------------------------------------------------------------------------
// SD card bridge (findings/sdcard-engine, plan Task 7).  rtl/minimig/
// sdcard_gayle.v between a behavioural model of sdcard_spi.v's clk_114 g_*
// side and Gayle, through sdcard_gayle_mux (the same mux minimig.v uses).
//
// The model follows the g_* contract in the sdcard_spi.v header and counts
// every way the bridge could break it (m_viol), more strictly than the
// contract needs: a g_wnext without g_wvalid, in dir 0 or beyond g_words;
// g_rvalid pulses closer than 2 cycles, in dir 1 or beyond g_words; g_ack in
// the cycle of a word pulse; any pulse more than one cycle after g_req fell.
//
// clk_114 is 4 x clk, edges aligned (the openaars MMCM siblings); SDC_ASYNC
// runs it at 112.4 MHz instead, drifting against clk.

reg clk_g = 1;
`ifdef SDC_ASYNC
always #4.45 clk_g = ~clk_g;
`else
always #4.375 clk_g = ~clk_g;
`endif

wire        g_ack, g_err, g_wnext, g_rvalid;
wire [15:0] g_rdata;
wire        sg_active, sg_port, sg_data_wr, sg_data_rd;
wire [15:0] sg_data_out;
wire  [1:0] gy_fifo_reset;

reg         m_req = 0, m_dir = 0, m_port = 0;
reg   [9:0] m_words = 0;
reg         m_wvalid = 0;
reg  [15:0] m_src [0:1023];		// RX, dir 1: the word at the head is m_src[m_rd]
reg  [15:0] m_dst [0:1023];		// TX, dir 0
integer     m_rd = 0;			// RX head
integer     m_moved = 0;		// words moved by this op
integer     m_cool = 0;			// cycles g_wvalid stays low after a pop
integer     m_gap = 0;			// extra low cycles after each pop (bench knob)
integer     m_last = -100;		// cycle of the last word pulse
integer     m_cyc = 0;
integer     m_viol = 0;			// contract violations by the bridge
integer     m_ops = 0;			// ops ended
reg   [1:0] m_end = 0;			// how the last op ended: 1 g_ack, 2 Gayle error, 3 dropped by the bench
reg         m_req_d = 0;
wire [15:0] g_wdata = m_src[m_rd[9:0]];

// commands from the initial block (toggles, so they never race the edge)
reg         c_go = 0, c_go_s = 0, c_drop = 0, c_drop_s = 0, c_one = 0, c_one_s = 0;
reg         n_dir = 0, n_port = 0;
reg   [9:0] n_words = 0;
integer     n_rd = 0;			// RX head at the start, -1: where it is
integer     m_rd0 = 0;			// RX head at the start of the last op

task viol(input [8*48-1:0] what);
	begin
		m_viol = m_viol + 1;
		$display("  bridge contract violation at %0t: %0s", $time, what);
	end
endtask

always @(posedge clk_g) begin : model
	reg pop, word, endop;
	m_cyc = m_cyc + 1;
	m_req_d <= m_req;
	pop = 0; word = 0; endop = 0;
	if (m_req) begin
		if (g_wnext) begin
			if (!m_dir) viol("g_wnext in dir 0");
			else if (!m_wvalid) begin
				viol("g_wnext without g_wvalid");
				m_end <= 2; endop = 1;		// sdcard_spi: Gayle error, nothing taken
			end else if (m_moved >= m_words) viol("g_wnext beyond g_words");
			else begin pop = 1; word = 1; end
		end
		if (g_rvalid) begin
			if (m_dir) viol("g_rvalid in dir 1");
			else if (m_cyc - m_last < 2) viol("g_rvalid pulses closer than 2 cycles");
			else if (m_moved >= m_words) viol("g_rvalid beyond g_words");
			else begin m_dst[m_moved] = g_rdata; word = 1; end
		end
		if (word) begin
			m_moved = m_moved + 1;
			m_last = m_cyc;
		end
		if (g_err) begin
			m_end <= 2; endop = 1;
		end else if (g_ack) begin
			if (m_last == m_cyc) viol("g_ack in the cycle of a word pulse");
			m_end <= (m_moved == m_words && m_last != m_cyc) ? 2'd1 : 2'd2;
			endop = 1;
		end
	end else if (!m_req_d && (g_wnext || g_rvalid || g_ack || g_err))
		viol("pulse outside g_req");

	if (pop) m_rd = m_rd + 1;

	if (c_drop != c_drop_s) begin			// ABORT / card gone: g_req drops
		c_drop_s <= c_drop;
		if (m_req) begin m_end <= 3; endop = 1; end
	end

	if (endop) begin
		m_req <= 0; m_wvalid <= 0;
		m_ops = m_ops + 1;
	end else if (c_go != c_go_s || c_one != c_one_s) begin
		c_go_s <= c_go; c_one_s <= c_one;
		m_req <= 1; m_dir <= n_dir; m_port <= n_port; m_words <= n_words;
		if (n_rd >= 0) m_rd = n_rd;
		m_rd0 = m_rd; m_moved = 0; m_end <= 0; m_cool = 0;
		m_wvalid <= n_dir;			// high from the first cycle of g_req
		if (c_one != c_one_s) c_drop_s <= ~c_drop;	// the op ends in its first cycle
	end else if (m_req) begin
		if (pop) begin
			m_wvalid <= 0;			// low in the cycle after a g_wnext ...
			m_cool = 1 + m_gap;		// ... and the next (high from the 3rd)
		end else if (m_cool > 0) begin
			m_wvalid <= 0;
			m_cool = m_cool - 1;
		end else
			m_wvalid <= m_dir && m_rd < 1024;	// RX may hold more than g_words
	end
end

sdcard_gayle BRIDGE
(
	.clk(clk),
	.clk7_en(clk7_en),
	.reset(reset),
	.clk_g(clk_g),
	.g_req(m_req),
	.g_dir(m_dir),
	.g_port(m_port),
	.g_words(m_words),
	.g_ack(g_ack),
	.g_err(g_err),
	.g_wdata(g_wdata),
	.g_wvalid(m_wvalid),
	.g_wnext(g_wnext),
	.g_rdata(g_rdata),
	.g_rvalid(g_rvalid),
	.active(sg_active),
	.port(sg_port),
	.data_wr(sg_data_wr),
	.data_rd(sg_data_rd),
	.data_out(sg_data_out),
	.data_in(hdd_data_in),
	.dat_req(hdd_dat_req),
	.fifo_reset_seen(gy_fifo_reset),
	.fw_port(hdd_port),
	.fw_xfer_wr(hdd_xfer_wr),
	.fw_regs_rd(hdd_regs_rd)
);

sdcard_gayle_mux MUX
(
	.sg_active(sg_active),
	.sg_port(sg_port),
	.sg_data_wr(sg_data_wr),
	.sg_data_rd(sg_data_rd),
	.sg_data_out(sg_data_out),
	.pf_port(hdd_port),
	.pf_data_wr(hdd_data_wr),
	.pf_data_rd(hdd_data_rd),
	.pf_data_out(hdd_data_out),
	.pf_addr(hdd_addr),
	.hdd_addr(gy_addr),
	.hdd_port(gy_port),
	.hdd_data_wr(gy_data_wr),
	.hdd_data_rd(gy_data_rd),
	.hdd_data_out(gy_data_out)
);

// Gayle-side strobes as Gayle samples them
integer     n_sgwr = 0, n_sgrd = 0;		// bridge strobes taken
integer     t_sg_last = 0;			// time of the last one
always @(posedge clk)
	if (clk7_en) begin
		if (gy_data_wr && sg_active) begin n_sgwr = n_sgwr + 1; t_sg_last = $time; end
		if (gy_data_rd && sg_active) begin n_sgrd = n_sgrd + 1; t_sg_last = $time; end
		if ((sg_data_wr || sg_data_rd) && !sg_active) begin
			m_viol = m_viol + 1;
			$display("  bridge strobe while not active at %0t", $time);
		end
	end
`endif

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

// the firmware side.  hdd_addr is sticky as paula_floppy.v makes it: a task
// file read or write leaves it at its register (cmd_hdd_rd / cmd_hdd_wr stay
// set until the next command word); a status, data or XFER_WR command word
// clears it to 0.
task fw_status(input p, input [7:0] st);
	begin
		hdd_port = p;
		hdd_addr = 0;
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
		hdd_addr = 0;
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
		hdd_addr = 0;
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


`ifdef SDC_BRIDGE
//----------------------------------------------------------------------------
// Bridge tasks (the firmware starting sdcard_spi Gayle ops)

integer n_irq = 0;			// interrupt rising edges
reg     irq_q = 0;
always @(posedge clk)
	if (clk7_en) begin
		if (irq && !irq_q) n_irq = n_irq + 1;
		irq_q <= irq;
	end

task sdc_start(input d, input p, input integer w, input integer rd);
	begin
		n_dir = d; n_port = p; n_words = w; n_rd = rd;
		c_go = ~c_go;
	end
endtask

// an op that ends in its first cycle (no card)
task sdc_one(input d, input p, input integer w);
	begin
		n_dir = d; n_port = p; n_words = w; n_rd = 0;
		c_one = ~c_one;
	end
endtask

task sdc_drop;
	begin
		c_drop = ~c_drop;
	end
endtask

// wait until more than ops0 ops have ended, then until the bridge is idle
task sdc_wait(input integer ops0, input integer limit);
	integer guard;
	begin
		guard = 0;
		while (m_ops <= ops0 && guard < limit) begin en; guard = guard + 1; end
		while (sg_active && guard < limit) begin en; guard = guard + 1; end
		check(m_ops > ops0, "the bridge op ended");
		check(!sg_active, "the bridge is idle after the op");
	end
endtask

// dir 1: nw words base+k through the bridge into port p's FIFO; RX holds
// more words after them, which must not leak
task bridge_in(input p, input integer nw, input [15:0] base);
	integer k, ops0;
	begin
		for (k = 0; k < 1024; k = k + 1)
			m_src[k] = (k < nw) ? base + k : 16'hDEAD;
		ops0 = m_ops;
		sdc_start(1, p, nw, 0);
		sdc_wait(ops0, 20000);
		check(m_end == 2'd1, "bridge op (dir 1) ends with g_ack");
		check(m_moved == nw, "bridge op (dir 1) moved every word");
	end
endtask

// dir 0: nw words from port p's FIFO through the bridge into m_dst
task bridge_out(input p, input integer nw);
	integer ops0;
	begin
		ops0 = m_ops;
		sdc_start(0, p, nw, 0);
		sdc_wait(ops0, 20000);
		check(m_end == 2'd1, "bridge op (dir 0) ends with g_ack");
		check(m_moved == nw, "bridge op (dir 0) moved every word");
	end
endtask

task wait_sg(input integer nwr, input integer nrd);	// until that many bridge strobes were taken
	integer guard;
	begin
		guard = 0;
		while (n_sgwr < nwr && n_sgrd < nrd && guard < 20000) begin en; guard = guard + 1; end
	end
endtask

task wait_irq;
	integer guard;
	begin
		guard = 0;
		while (!irq && guard < 20000) begin en; guard = guard + 1; end
		check(irq, "interrupt");
	end
endtask

// the host waits for DRQ on a port's status register
task wait_drq(input [23:0] st);
	integer guard;
	reg [15:0] sv;
	begin
		guard = 0;
		hr(st, sv);
		while (!sv[11] && guard < 5000) begin hr(st, sv); guard = guard + 1; end
		check(sv[11], "DRQ");
	end
endtask
`endif
//----------------------------------------------------------------------------

reg [15:0] v, w7;
reg ok;
integer i, n, k;
integer nv0, ops0, irq0, w0, w1, r0, r1, p0, p1;

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
`ifdef SDC_BRIDGE
		bridge_in(0, 256, n ? 16'hB000 : 16'hA000);
`else
		for (i = 0; i < 256; i = i + 1)
			fw_data_wr(0, (n ? 16'hB000 : 16'hA000) + i);
`endif
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
`ifdef SDC_BRIDGE
	bridge_out(0, 256);
	for (i = 0; i < 256; i = i + 1)
		if (m_dst[i] !== 16'hC000 + i) check(0, "a2 data seen by the bridge");
`else
	for (i = 0; i < 256; i = i + 1) begin
		fw_data_rd(0, v);
		if (v !== 16'hC000 + i) check(0, "a2 data seen by the firmware");
	end
`endif
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
`ifdef SDC_BRIDGE
	bridge_in(0, 256, 16'hD000);
`else
	for (i = 0; i < 256; i = i + 1)
		fw_data_wr(0, 16'hD000 + i);
`endif
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

`ifdef SDC_BRIDGE
	//======================================================================
	// (j) t_bridge_read: READ MULTIPLE 4, two groups of 2 sectors, each group
	// one 512-word bridge op; the Amiga reads on the interrupt while the
	// bridge still streams
	begin_case("j");
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	nv0 = m_viol;
	host_cmd(24'hDA2000, 8'd4, 8'd1, 8'd0, 8'd0, 8'hA0, 8'hC4);
	fw_wait_cmd(ok);
	check(ok, "cmd_req after READ MULTIPLE");
	fw_read_all(0, w7);
	check(tf[7] == 8'hC4 && tf[2] == 8'd4, "firmware sees READ MULTIPLE 4");
	for (n = 0; n < 2; n = n + 1) begin
		fw_status(0, 8'h08);			// WriteStatus(RDY)
		fw_wait_cmd(ok);
		check(ok, "cmd_req (FIFO drained) before the group");
		for (i = 0; i < 1024; i = i + 1)
			m_src[i] = (i < 512) ? 16'h6000 + n * 512 + i : 16'hDEAD;
		irq0 = n_irq;
		ops0 = m_ops;
		w0 = n_sgwr;
		sdc_start(1, 0, 512, 0);
		wait_irq;
		check(n_sgwr - w0 >= 256, "no interrupt before 256 words are in");
		hr(24'hDA201C, v);
		check(v[15:8] == 8'h08, "status DRQ with the interrupt");
		irq_clear;
		for (i = 0; i < 512; i = i + 1) begin
			hr(24'hDA2000, v);
			if (v !== 16'h6000 + n * 512 + i) check(0, "group data, first to last");
		end
		sdc_wait(ops0, 20000);
		check(m_end == 2'd1 && m_moved == 512, "group op ends with g_ack, 512 words");
		check(n_irq - irq0 == 1, "one interrupt per group");
		check(n_sgwr - w0 == 512, "512 bridge writes");
	end
	idle(2);
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h40, "DRDY after the last sector");
	check(m_viol == nv0, "g_* contract kept");
	end_case("t_bridge_read: READ MULTIPLE 4 via the bridge");

	//======================================================================
	// (k) t_bridge_write: WRITE MULTIPLE 2 in one block, one 512-word op
	// started before the Amiga writes: it waits for dat_req per sector
	begin_case("k");
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	nv0 = m_viol;
	host_cmd(24'hDA2000, 8'd2, 8'd9, 8'd0, 8'd0, 8'hA0, 8'hC5);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	check(tf[7] == 8'hC5, "firmware sees WRITE MULTIPLE");
	fw_status(0, 8'h04);			// pio out
	ops0 = m_ops;
	r0 = n_sgrd;
	for (i = 0; i < 1024; i = i + 1) m_dst[i] = 16'hxxxx;
	sdc_start(0, 0, 512, 0);
	idle(40);
	check(n_sgrd == r0, "no reads before dat_req");
	for (n = 0; n < 2; n = n + 1) begin
		wait_drq(24'hDA201C);
		for (i = 0; i < 256; i = i + 1)
			hww(24'hDA2000, 16'h7000 + n * 256 + i);
	end
	sdc_wait(ops0, 20000);
	check(m_end == 2'd1 && m_moved == 512, "op ends with g_ack, 512 words");
	for (i = 0; i < 512; i = i + 1)
		if (m_dst[i] !== 16'h7000 + i) check(0, "words to TX equal what the Amiga wrote, first to last");
	check(m_dst[512] === 16'hxxxx, "no word beyond the op");
	fw_status(0, 8'h90);
	idle(2);
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h40, "DRDY after END");
	check(m_viol == nv0, "g_* contract kept");
	end_case("t_bridge_write: WRITE MULTIPLE 2 via the bridge");

	//======================================================================
	// (l) t_fifo_reset_mid_dma: the Amiga abandons the command (a new
	// command resets the FIFO), or resets: g_err, active drops, no strobe
	// after the FIFO reset
	begin_case("l");
	// l1: dir 1, mid-group
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	nv0 = m_viol;
	host_cmd(24'hDA2000, 8'd2, 8'd1, 8'd0, 8'd0, 8'hA0, 8'hC4);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h08);
	fw_wait_cmd(ok);
	for (i = 0; i < 1024; i = i + 1) m_src[i] = 16'h5000 + i;
	m_gap = 40;
	ops0 = m_ops;
	w0 = n_sgwr;
	sdc_start(1, 0, 512, 0);
	wait_sg(w0 + 100, 1 << 30);
	hwb(24'hDA201C, 8'hEC);			// a new command: FIFO reset
	w1 = n_sgwr;
	sdc_wait(ops0, 20000);
	check(m_end == 2'd2, "l1 g_err after the FIFO reset");
	check(m_moved < 512, "l1 the op did not complete");
	idle(10);
	check(n_sgwr == w1, "l1 no bridge write after the FIFO reset");
	check(dut.PORT0.SECBUF.inptr == 0, "l1 the new command's FIFO stays empty");
	#1 check(hdd_cmd_req == 1'b1, "l1 the firmware sees the new command");
	// l2: dir 0, waiting for dat_req
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h30);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h04);
	ops0 = m_ops;
	r0 = n_sgrd;
	sdc_start(0, 0, 256, 0);
	for (i = 0; i < 100; i = i + 1)
		hww(24'hDA2000, 16'h4400 + i);
	idle(10);
	check(n_sgrd == r0, "l2 no read before dat_req");
	hwb(24'hDA201C, 8'hEC);
	sdc_wait(ops0, 20000);
	check(m_end == 2'd2 && m_moved == 0, "l2 g_err, nothing moved");
	check(n_sgrd == r0, "l2 no read at all");
	// l3: dir 0, mid-sector
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h30);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h04);
	for (i = 0; i < 256; i = i + 1)
		hww(24'hDA2000, 16'h4800 + i);
	fw_wait_dat(ok);
	ops0 = m_ops;
	r0 = n_sgrd;
	sdc_start(0, 0, 256, 0);
	wait_sg(1 << 30, r0 + 50);
	hwb(24'hDA201C, 8'hEC);
	r1 = n_sgrd;
	sdc_wait(ops0, 20000);
	check(m_end == 2'd2 && m_moved < 256, "l3 g_err mid-sector");
	idle(10);
	check(n_sgrd == r1, "l3 no bridge read after the FIFO reset");
	for (i = 0; i < m_moved; i = i + 1)
		if (m_dst[i] !== 16'h4800 + i) check(0, "l3 words moved before the reset are right");
	// l4: Amiga reset mid dir-1 op
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h20);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h08);
	fw_wait_cmd(ok);
	ops0 = m_ops;
	w0 = n_sgwr;
	sdc_start(1, 0, 256, 0);
	wait_sg(w0 + 30, 1 << 30);
	reset = 1;
	en;
	w1 = n_sgwr;
	idle(3);
	reset = 0;
	sdc_wait(ops0, 20000);
	check(m_end == 2'd2, "l4 g_err after an Amiga reset");
	idle(10);
	check(n_sgwr == w1, "l4 no bridge write after the reset");
	m_gap = 0;
	// l5: the next op runs normally
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h20);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h08);
	fw_wait_cmd(ok);
	bridge_in(0, 256, 16'h3C00);
	wait_irq;
	irq_clear;
	for (i = 0; i < 256; i = i + 1) begin
		hr(24'hDA2000, v);
		if (v !== 16'h3C00 + i) check(0, "l5 data after the aborted ops");
	end
	check(m_viol == nv0, "g_* contract kept");
	end_case("t_fifo_reset_mid_dma: new command / reset stops the DMA");

	//======================================================================
	// (m) t_two_ports: a command on the other port does not stop the DMA
	begin_case("m");
	do_reset(2'b01, 2'b01, 2'b00, 2'b01);
	nv0 = m_viol;
	// port 1 packet data-in, 512 words, through the bridge
	hwb(24'hDA3018, 8'hA0);
	hwb(24'hDA301C, 8'hA0);
	fw_wait_cmd(ok);
	fw_read_all(1, w7);
	check(tf[7] == 8'hA0, "port 1 PACKET");
	fw_xfer(1, 13'd512, 1'b1);
	fw_status(1, 8'h08);
	for (i = 0; i < 1024; i = i + 1) m_src[i] = 16'h2A00 + i;
	m_gap = 20;
	ops0 = m_ops;
	w0 = n_sgwr;
	sdc_start(1, 1, 512, 0);
	wait_sg(w0 + 64, 1 << 30);
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h20);	// port 0 READ SECTORS mid-DMA
	sdc_wait(ops0, 40000);
	m_gap = 0;
	check(m_end == 2'd1 && m_moved == 512, "port 1 op completes despite port 0's command");
	check(dut.PORT0.SECBUF.inptr == 0, "port 0's FIFO untouched by the bridge");
	for (i = 0; i < 512; i = i + 1) begin
		hr(24'hDA3000, v);
		if (v !== 16'h2A00 + i) check(0, "port 1 data");
	end
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h80, "port 0 BSY with its command");
	hdd_port = 0; #1;
	fw_status(1, 8'h90);			// port 1 done
	#1 check(hdd_cmd_req == 1'b1, "port 0's command visible to the firmware");
	fw_read_all(0, w7);
	check(tf[7] == 8'h20, "port 0 command register = 20");
	fw_status(0, 8'h91);			// end it
	irq_clear;
	// port 0 WRITE via the bridge (dir 0) while port 1 gets a command
	host_cmd(24'hDA2000, 8'd1, 8'd3, 8'd0, 8'd0, 8'hA0, 8'h30);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h04);
	for (i = 0; i < 256; i = i + 1)
		hww(24'hDA2000, 16'h8800 + i);
	fw_wait_dat(ok);
	ops0 = m_ops;
	r0 = n_sgrd;
	sdc_start(0, 0, 256, 0);
	wait_sg(1 << 30, r0 + 64);
	hwb(24'hDA3018, 8'hA0);
	hwb(24'hDA301C, 8'hEC);			// port 1 IDENTIFY mid-DMA
	sdc_wait(ops0, 20000);
	check(m_end == 2'd1 && m_moved == 256, "port 0 op completes despite port 1's command");
	for (i = 0; i < 256; i = i + 1)
		if (m_dst[i] !== 16'h8800 + i) check(0, "port 0 write data");
	check(m_viol == nv0, "g_* contract kept");
	end_case("t_two_ports: the other port's command leaves the DMA alone");

	//======================================================================
	// (n) paula_floppy data strobes while the bridge is active have no effect
	begin_case("n");
	do_reset(2'b01, 2'b01, 2'b00, 2'b00);
	nv0 = m_viol;
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h20);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h08);
	fw_wait_cmd(ok);
	for (i = 0; i < 1024; i = i + 1) m_src[i] = 16'h9000 + i;
	m_gap = 30;
	ops0 = m_ops;
	w0 = n_sgwr;
	sdc_start(1, 0, 256, 0);
	wait_sg(w0 + 20, 1 << 30);
	for (i = 0; i < 4; i = i + 1) begin
		fw_data_wr(i[0], 16'hBAD0 + i);	// a firmware slip: data writes, both ports
		fw_data_rd(i[0], v);			// and data reads
	end
	check(sg_active, "the slip came while the bridge was active");
	sdc_wait(ops0, 20000);
	m_gap = 0;
	check(m_end == 2'd1 && m_moved == 256, "dir 1 op completes");
	check(dut.PORT0.SECBUF.inptr == 256 && dut.PORT0.SECBUF.outptr == 0, "port 0 FIFO: 256 in, none taken");
	check(dut.g_port1.PORT1.SECBUF.inptr == 0, "port 1 FIFO untouched");
	hdd_port = 0;
	wait_irq;
	irq_clear;
	for (i = 0; i < 256; i = i + 1) begin
		hr(24'hDA2000, v);
		if (v !== 16'h9000 + i) check(0, "dir 1 data: only the bridge's words");
	end
	// dir 0
	fw_status(0, 8'h90);
	irq_clear;
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h30);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h04);
	for (i = 0; i < 256; i = i + 1)
		hww(24'hDA2000, 16'h9900 + i);
	fw_wait_dat(ok);
	ops0 = m_ops;
	r0 = n_sgrd;
	sdc_start(0, 0, 256, 0);
	wait_sg(1 << 30, r0 + 20);
	for (i = 0; i < 4; i = i + 1)
		fw_data_rd(0, v);
	check(sg_active, "the slip came while the bridge was active (dir 0)");
	sdc_wait(ops0, 20000);
	check(m_end == 2'd1 && m_moved == 256, "dir 0 op completes");
	for (i = 0; i < 256; i = i + 1)
		if (m_dst[i] !== 16'h9900 + i) check(0, "dir 0 data: no word stolen");
	check(dut.PORT0.SECBUF.outptr == 256, "port 0 FIFO: exactly 256 taken");
	check(m_viol == nv0, "g_* contract kept");
	end_case("paula_floppy data strobes blocked while the bridge is active");

	//======================================================================
	// (o) g_req: an op over before the bridge saw it, and drops mid-op
	begin_case("o");
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	nv0 = m_viol;
	host_cmd(24'hDA2000, 8'd8, 8'd1, 8'd0, 8'd0, 8'hA0, 8'hC4);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h08);
	fw_wait_cmd(ok);
	for (i = 0; i < 1024; i = i + 1) m_src[i] = 16'h1000 + i;
	// o1: one-cycle ops, both directions, at every clk_114 phase
	w0 = n_sgwr;
	r0 = n_sgrd;
	for (n = 0; n < 16; n = n + 1) begin
		ops0 = m_ops;
		for (i = 0; i < n; i = i + 1) @(posedge clk_g);
		sdc_one(n[0], 0, 64);
		idle(6);
		check(m_ops == ops0 + 1 && m_end == 2'd3, "o1 the one-cycle op ended");
		check(!sg_active, "o1 bridge idle");
	end
	check(n_sgwr == w0 && n_sgrd == r0, "o1 no strobe for an op over before it was seen");
	check(dut.PORT0.SECBUF.inptr == 0, "o1 FIFO untouched");
	// o2: drops mid dir-1 op at many offsets, each followed by a short op
	// that must write exactly its own words
	k = 0;
	for (n = 0; n < 12; n = n + 1) begin
		m_gap = (n % 4) * 3;
		p0 = dut.PORT0.SECBUF.inptr;
		ops0 = m_ops;
		w0 = n_sgwr;
		sdc_start(1, 0, 64, k);
		wait_sg(w0 + 3 + n, 1 << 30);
		for (i = 0; i < n; i = i + 1) @(posedge clk_g);
		sdc_drop;
		sdc_wait(ops0, 20000);
		check(m_end == 2'd3, "o2 dropped");
		w1 = n_sgwr;
		idle(6);
		check(n_sgwr == w1, "o2 no strobe once idle");
		p1 = dut.PORT0.SECBUF.inptr;
		check(p1 - p0 <= m_moved && m_moved - (p1 - p0) <= 1, "o2 words written = words taken (at most one taken and dropped)");
		for (i = 0; i < p1 - p0; i = i + 1)
			if (dut.PORT0.SECBUF.mem[(p0 + i) % 4096] !== m_src[k + i]) check(0, "o2 words written before the drop");
		k = m_rd;
		ops0 = m_ops;
		sdc_start(1, 0, 8, k);
		sdc_wait(ops0, 20000);
		check(m_end == 2'd1 && m_moved == 8, "o2 next op completes");
		for (i = 0; i < 8; i = i + 1)
			if (dut.PORT0.SECBUF.mem[(p1 + i) % 4096] !== m_src[k + i]) begin
				check(0, "o2 next op writes exactly its words (no stale word)");
`ifdef SDG_DEBUG
				$display("    n=%0d i=%0d fifo=%h want=%h k=%0d", n, i, dut.PORT0.SECBUF.mem[(p1 + i) % 4096], m_src[k + i], k);
`endif
			end
		check(dut.PORT0.SECBUF.inptr == p1 + 8, "o2 next op writes 8 words");
		k = m_rd;
	end
	m_gap = 0;
	// o3: drop mid dir-0 op, then the rest in a second op
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h30);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h04);
	for (i = 0; i < 256; i = i + 1)
		hww(24'hDA2000, 16'hE000 + i);
	fw_wait_dat(ok);
	ops0 = m_ops;
	r0 = n_sgrd;
	sdc_start(0, 0, 256, 0);
	wait_sg(1 << 30, r0 + 40);
	sdc_drop;
	sdc_wait(ops0, 20000);
	check(m_end == 2'd3, "o3 dropped");
	r1 = n_sgrd;
	idle(6);
	check(n_sgrd == r1, "o3 no strobe once idle");
	p0 = dut.PORT0.SECBUF.outptr;
	check(m_moved <= p0 && p0 - m_moved <= 2, "o3 at most two words taken from Gayle and dropped");
	for (i = 0; i < m_moved; i = i + 1)
		if (m_dst[i] !== 16'hE000 + i) check(0, "o3 words before the drop");
	ops0 = m_ops;
	sdc_start(0, 0, 256 - p0, 0);
	sdc_wait(ops0, 20000);
	check(m_end == 2'd1 && m_moved == 256 - p0, "o3 the rest in a second op");
	for (i = 0; i < 256 - p0; i = i + 1)
		if (m_dst[i] !== 16'hE000 + p0 + i) check(0, "o3 the rest, no off-by-one");
	// o4: the next op starts 1..7 clk_114 cycles after a drop at every
	// offset in the clk7 period (a request can be in flight across the fall),
	// or after a one-cycle op (dir 1): it writes exactly its own words
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	host_cmd(24'hDA2000, 8'd8, 8'd1, 8'd0, 8'd0, 8'hA0, 8'hC4);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h08);
	fw_wait_cmd(ok);
	k = 1024;
	for (n = 0; n < 72; n = n + 1) begin
		if (k > 960) begin			// fresh RX words, never seen before
			for (i = 0; i < 1024; i = i + 1) m_src[i] = 16'h4000 + n * 64 + i;
			k = 0;
		end
		p0 = dut.PORT0.SECBUF.inptr;
		ops0 = m_ops;
		if (n < 64) begin
			w0 = n_sgwr;
			m_gap = n % 3;
			sdc_start(1, 0, 64, k);
			wait_sg(w0 + 2 + n % 5, 1 << 30);
			for (i = 0; i < n % 16; i = i + 1) @(posedge clk_g);
			sdc_drop;
		end else
			sdc_one(1, 0, 64);
		@(posedge clk_g); #1;
		for (i = 0; i < (n / 16) * 2 + n % 2; i = i + 1) @(posedge clk_g);
		#1 sdc_start(1, 0, 8, -1);
		sdc_wait(ops0 + 1, 20000);
		check(m_end == 2'd1 && m_moved == 8, "o4 the close op completes");
		p1 = dut.PORT0.SECBUF.inptr;
		for (i = 0; i < 8; i = i + 1)
			if (dut.PORT0.SECBUF.mem[(p1 - 8 + i) % 4096] !== m_src[m_rd0 + i]) check(0, "o4 the close op writes exactly its words");
		for (i = 0; i < p1 - 8 - p0; i = i + 1)
			if (dut.PORT0.SECBUF.mem[(p0 + i) % 4096] !== m_src[k + i]) check(0, "o4 the dropped op's words before it");
		k = m_rd;
	end
	m_gap = 0;
	// o5: the same in dir 0
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	host_cmd(24'hDA2000, 8'd1, 8'd1, 8'd0, 8'd0, 8'hA0, 8'h30);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h04);
	for (i = 0; i < 256; i = i + 1)
		hww(24'hDA2000, 16'h6600 + i);
	fw_wait_dat(ok);
	for (n = 0; n < 20; n = n + 1) begin
		ops0 = m_ops;
		if (n < 16) begin
			r0 = n_sgrd;
			sdc_start(0, 0, 64, 0);
			wait_sg(1 << 30, r0 + 2);
			for (i = 0; i < n; i = i + 1) @(posedge clk_g);
			sdc_drop;
		end else
			sdc_one(0, 0, 64);
		@(posedge clk_g); #1;
		for (i = 0; i < n % 4; i = i + 1) @(posedge clk_g);
		#1 sdc_start(0, 0, 4, 0);
		sdc_wait(ops0 + 1, 20000);
		check(m_end == 2'd1 && m_moved == 4, "o5 the close op completes");
		p1 = dut.PORT0.SECBUF.outptr;
		for (i = 0; i < 4; i = i + 1)
			if (m_dst[i] !== 16'h6600 + p1 - 4 + i) check(0, "o5 the close op moves the 4 words it popped, in order");
	end
	// o6: g_req drops on the very edge the bridge serves a word (stimulus
	// timed from the bridge's own "owed" state), the serve swept over every
	// clk7 phase by the g_wvalid gap: a word is in Gayle's FIFO only if
	// sdcard_spi popped it
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	host_cmd(24'hDA2000, 8'd8, 8'd1, 8'd0, 8'd0, 8'hA0, 8'hC4);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h08);
	fw_wait_cmd(ok);
	for (i = 0; i < 1024; i = i + 1) m_src[i] = 16'h3300 + i;
	k = 0;
	for (n = 0; n < 48; n = n + 1) begin
		m_gap = 16 + n % 16;
		p0 = dut.PORT0.SECBUF.inptr;
		ops0 = m_ops;
		w0 = n_sgwr;
		sdc_start(1, 0, 64, k);
		wait_sg(w0 + 1 + n / 16, 1 << 30);
		i = 0;
		@(negedge clk_g);
		while (!(m_req && m_wvalid && BRIDGE.q_run1 && BRIDGE.q_owed) && i < 2000) begin
			@(negedge clk_g);
			i = i + 1;
		end
		sdc_drop;			// taken at the next edge: the serve edge
		sdc_wait(ops0, 20000);
		idle(4);
		p1 = dut.PORT0.SECBUF.inptr;
		check(p1 - p0 <= m_moved, "o6 no word written to Gayle that was not popped");
		check(m_moved - (p1 - p0) <= 1, "o6 at most one popped word not written");
		for (i = 0; i < p1 - p0; i = i + 1)
			if (dut.PORT0.SECBUF.mem[(p0 + i) % 4096] !== m_src[k + i]) check(0, "o6 the words written");
		k = m_rd;
		if (k > 960) k = 0;
	end
	m_gap = 0;
	check(m_viol == nv0, "g_* contract kept");
	end_case("g_req: one-cycle ops and drops mid-op");

	//======================================================================
	// (p) dir 0 right after a task file read: paula_floppy's hdd_addr stays
	// at the register it read; the bridge must still read the FIFO
	begin_case("p");
	do_reset(2'b01, 2'b01, 2'b00, 2'b01);
	nv0 = m_viol;
	// port 1 PACKET: the 6-word command packet, then the firmware's flags
	// read (cd_wait's ReadIDEFlags: registers 0 and 1), then the bridge
	hwb(24'hDA3018, 8'hA0);
	hwb(24'hDA301C, 8'hA0);
	fw_wait_cmd(ok);
	fw_read_all(1, w7);
	fw_tfr_wr(1, 2, 8'h01);
	fw_xfer(1, 13'd6, 1'b1);
	fw_status(1, 8'h04);
	for (i = 0; i < 6; i = i + 1)
		hww(24'hDA3000, 16'h1200 + i);
	fw_regs_rd(1);
	fw_tfr_rd(1, 3'd1, v);
	check(v[F_XDONE] == 1'b1, "packet in (xfer_done)");
	check(hdd_addr == 3'd1, "paula_floppy's hdd_addr left at 1");
	bridge_out(1, 6);
	for (i = 0; i < 6; i = i + 1)
		if (m_dst[i] !== 16'h1200 + i) check(0, "packet words through the bridge after a flags read");
	// port 0 WRITE, a whole register read just before the bridge
	host_cmd(24'hDA2000, 8'd1, 8'd2, 8'd0, 8'd0, 8'hA0, 8'h30);
	hdd_port = 0;
	fw_status(1, 8'h90);
	fw_read_all(0, w7);
	fw_status(0, 8'h04);
	for (i = 0; i < 256; i = i + 1)
		hww(24'hDA2000, 16'h5A00 + i);
	fw_wait_dat(ok);
	fw_read_all(0, w7);
	check(hdd_addr == 3'd7, "paula_floppy's hdd_addr left at 7");
	bridge_out(0, 256);
	for (i = 0; i < 256; i = i + 1)
		if (m_dst[i] !== 16'h5A00 + i) check(0, "sector words through the bridge after a register read");
	check(m_viol == nv0, "g_* contract kept");
	end_case("dir 0 after a task file read (hdd_addr 0 while active)");

	//======================================================================
	// (q) the Amiga abandons a READ MULTIPLE between two groups: its new
	// command resets the FIFO while no op runs; the firmware, still in the
	// old command's loop, starts the next group: g_err, no word, no DRQ / IRQ
	begin_case("q");
	do_reset(2'b01, 2'b00, 2'b00, 2'b00);
	nv0 = m_viol;
	host_cmd(24'hDA2000, 8'd2, 8'd1, 8'd0, 8'd0, 8'hA0, 8'hC4);
	fw_wait_cmd(ok);
	fw_read_all(0, w7);
	fw_status(0, 8'h08);
	fw_wait_cmd(ok);
	bridge_in(0, 256, 16'h1100);
	wait_irq;
	irq_clear;
	for (i = 0; i < 256; i = i + 1) begin
		hr(24'hDA2000, v);
		if (v !== 16'h1100 + i) check(0, "q group 1 data");
	end
	host_cmd(24'hDA2000, 8'd1, 8'd40, 8'd0, 8'd0, 8'hA0, 8'h20);	// a new READ SECTORS
	fw_status(0, 8'h08);			// the old loop: WriteStatus(RDY) ...
	fw_wait_cmd(ok);			// ... "drained" (the new command's bsy looks the same)
	check(ok, "q the old loop sees cmd_req");
	irq0 = n_irq;
	w0 = n_sgwr;
	for (i = 0; i < 1024; i = i + 1) m_src[i] = 16'hBAD0 + i;
	ops0 = m_ops;
	sdc_start(1, 0, 256, 0);
	sdc_wait(ops0, 20000);
	check(m_end == 2'd2 && m_moved == 0, "q g_err, no word popped");
	idle(20);
	check(n_sgwr == w0, "q no bridge write");
	check(dut.PORT0.SECBUF.inptr == 0, "q the new command's FIFO stays empty");
	check(n_irq == irq0 && !irq, "q no interrupt");
	hr(24'hDA201C, v);
	check(v[11] == 1'b0, "q no DRQ");
	// the firmware picks the new command up, then serves it normally
	fw_read_all(0, w7);			// (Gayle drops task file writes while BSY: the registers are the old ones)
	fw_status(0, 8'h08);
	fw_wait_cmd(ok);
	bridge_in(0, 256, 16'h4000);
	wait_irq;
	irq_clear;
	for (i = 0; i < 256; i = i + 1) begin
		hr(24'hDA2000, v);
		if (v !== 16'h4000 + i) check(0, "q the new command's data");
	end
	idle(2);
	hr(24'hDA201C, v);
	check(v[15:8] == 8'h40, "q DRDY after the new command");
	check(m_viol == nv0, "g_* contract kept");
	end_case("abandoned command between groups: g_err, no data");
`endif

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
