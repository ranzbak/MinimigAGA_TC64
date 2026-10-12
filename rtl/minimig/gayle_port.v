// One IDE port of the Gayle: task file, drive select, command state, the
// sector FIFO and the ATAPI packet mode.  gayle.v instantiates one per port
// (findings/cdrom/plan.md 7.3, ruling R-A): $DA0xxx/$DA2xxx is port 0,
// $DA1xxx/$DA3xxx port 1, as on an IDE splitter, so each port has its own
// registers and a write to one never lands in the other.
//
// The ATA behaviour is Jakub Bednarski's gayle.v (2008-2010) unchanged: with
// packet mode off, port 0 is bit-identical to the one-port Gayle (sim/gayle
// case (a), against a trace recorded from the old gayle.v).
//
// Packet mode (pkt_mode, set by the firmware's CMD_IDE_XFER_WR) replaces the
// fixed 512-byte blocks with a programmed transfer length, for ATAPI:
//   - CMD_IDE_XFER_WR {pkt, 2'b0, words[12:0]} resets the FIFO, loads the
//     length and clears the transfer direction; a status write then sets
//     pio in (bit 3) or pio out (bit 2) as for ATA.
//   - pio in: DRQ once the whole transfer is in the FIFO or 256 words are,
//     while the FIFO is not empty (nrdy stalls the 68k on an empty FIFO, so
//     long transfers can stream).  The interrupt comes with the DRQ edge, as
//     for ATA, so the host never sees it before the data.  When the host has
//     read all words: pio in ends, xfer_done.
//   - pio out: DRQ until the host has written all words; then xfer_done and
//     hdd_dat_req, and the firmware reads the FIFO.
//   - BSY stays set between phases (busy is only cleared by the firmware's
//     END), no sector counting.
//   - a status write with bit 4 (IRQ) and without bit 3 raises the interrupt
//     at once (data-out phase start, command completion).
//   - pkt_mode clears on a host command write and on reset.
//
// Signature: after reset, and after a firmware status write with bit 5, the
// host reads the ATA/ATAPI signature in registers 1-5 for the selected
// device (1,1,1,0x14,0xEB for an ATAPI device per atapi[dev], 1,1,1,0,0 for
// ATA) until it writes that register or a command.
//
// Firmware flags, bits 15:8 of every task file register read:
//   8 this port, 9 xfer_done, 10 dev_wr (host wrote drive/head), 11 rst_seen
//   (Gayle reset), 12 pkt_mode, 13 bsy of port 0, 14 bsy of port 1.
// dev_wr and rst_seen are sticky: a CMD_IDE_REGS_RD of this port captures
// them for its words and clears them, so each event is seen by exactly one
// register read (an event during the read shows in the next one).
//
// Plain Verilog: registers, comparators and the inferred FIFO RAM.

module gayle_port
#(
	parameter PORT = 0
)
(
	input	clk,
	input	clk7_en,
	input	reset,
	// 68k side
	input	sel,				// this port's task file is addressed
	input	[2:0] reg_sel,		// address_in[4:2]
	input	[15:0] data_in,
	input	rd,
	input	hwr,
	input	lwr,
	output	[15:0] host_out,	// task file / status / data read value (0 when not addressed)
	output	nrdy,				// FIFO not ready for reading
	input	[1:0] hdd_ena,		// master / slave present
	input	[1:0] atapi,		// master / slave is an ATAPI device (signature)
	// firmware side (SPI, via paula_floppy.v)
	input	hdd_sel,			// the firmware's port bit selects this port
	input	[2:0] hdd_addr,
	input	[15:0] hdd_data_out,
	output	[15:0] hdd_data_in,
	input	hdd_wr,
	input	hdd_status_wr,
	input	hdd_data_wr,
	input	hdd_data_rd,
	input	hdd_xfer_wr,
	input	hdd_regs_rd,
	input	[1:0] bsy_all,		// both ports' bsy, for the flags
	// to the shared Gayle registers
	output	irq_set,			// set the Gayle INTREQ
	output	busy_o,
	output	bsy_o,
	output	dat_req,
	output	[7:0] status_o,
	output	fifo_wr_o,
	output	fifo_rd_o
);

localparam VCC = 1'b1;
localparam GND = 1'b0;

// address decoding
wire	sel_fifo    = sel && reg_sel==3'b000;
wire	sel_status  = rd && sel && reg_sel==3'b111;
wire	sel_command = hwr && sel && reg_sel==3'b111;

// firmware strobes for this port
wire	hdd_wr_p        = hdd_wr & hdd_sel;
wire	hdd_status_wr_p = hdd_status_wr & hdd_sel;
wire	hdd_data_wr_p   = hdd_data_wr & hdd_sel;
wire	hdd_data_rd_p   = hdd_data_rd & hdd_sel;
wire	hdd_xfer_wr_p   = hdd_xfer_wr & hdd_sel;
wire	hdd_regs_rd_p   = hdd_regs_rd & hdd_sel;

reg		busy;			// busy status (command processing state)
reg		pio_in;			// pio in command type is being processed
reg		pio_out;		// pio out command type is being processed
reg		error;			// error status (command processing failed)
reg		block_mark;		// multiple block start flag
reg		dev;			// drive select (master/slave)
wire	bsy;
wire	drdy;
wire	drq;
reg		drq_d;
wire	[7:0] status;

// packet mode
reg		pkt_mode_r = 1'b0;
reg		[12:0] xfer_words = 13'd0;
reg		xfer_done = 1'b0;
`ifdef GAYLE_MUT_NOPKT
wire	pkt_mode = 1'b0;		// bench teeth check (sim/gayle): packet mode forced off
`else
wire	pkt_mode = pkt_mode_r;
`endif

// FIFO control
wire	fifo_reset;
wire	[15:0] fifo_data_in;
wire	[15:0] fifo_data_out;
wire	fifo_rd;
wire	fifo_wr;
wire	fifo_full;
wire	fifo_empty;
wire	fifo_last_out;
wire	fifo_last_in;
wire	[12:0] fifo_in_ptr;		// words written since the FIFO reset
wire	[12:0] fifo_out_ptr;	// words read since the FIFO reset

assign fifo_wr_o = fifo_wr;
assign fifo_rd_o = fifo_rd;

// HDD status register
assign status = {bsy,drdy,2'b00,drq,2'b00,err};
assign status_o = status;
assign bsy = busy & ~drq;
assign drdy = ~(bsy|drq);
wire   err = error;
assign busy_o = busy;
assign bsy_o = bsy;

//-----------------------------------------------------------------------------
// task file registers
reg		[7:0] tfr [7:0];
wire	[2:0] tfr_sel;
wire	[7:0] tfr_in;
wire	tfr_we;

reg		[7:0] sector_count;	// sector counter
wire	sector_count_dec_in;
wire	sector_count_dec_out;

always @(posedge clk)
  if (clk7_en) begin
  	if (hwr && sel && reg_sel == 3'b010) // sector count register loaded by the host
  		sector_count <= data_in[15:8];
  	else if (sector_count_dec_in || sector_count_dec_out)
  		sector_count <= sector_count - 8'd1;
  end

assign sector_count_dec_in  = pio_in & fifo_last_out & sel_fifo & rd & ~pkt_mode;
assign sector_count_dec_out = pio_out & fifo_last_in & sel_fifo & hwr & lwr & ~pkt_mode;

assign tfr_we = busy ? hdd_wr_p : sel & hwr;
assign tfr_sel = busy ? hdd_addr : reg_sel;
assign tfr_in = busy ? hdd_data_out[7:0] : data_in[15:8];

always @(posedge clk)
  if (clk7_en) begin
  	if (tfr_we)
  		tfr[tfr_sel] <= tfr_in;
  end

// The host reads the register it addresses.  While an ATA command runs the
// read address follows the firmware's, as it always did (an ATA host reads
// only status and data then); a packet command's host reads the interrupt
// reason and byte count between phases, so packet mode uses the bus address.
wire	[2:0] host_rsel = (busy & ~pkt_mode) ? hdd_addr : reg_sel;

// signature
reg		[5:1] sig_valid = 5'b00000;
always @(posedge clk)
  if (clk7_en) begin
  	if (reset)
  		sig_valid <= 5'b11111;
  	else if (sel_command)
  		sig_valid <= 5'b00000;
  	else if (busy && hdd_status_wr_p && hdd_data_out[5])
  		sig_valid <= 5'b11111;
  	else if (sel && hwr && !busy && reg_sel >= 3'd1 && reg_sel <= 3'd5)
  		sig_valid[reg_sel] <= 1'b0;
  end

wire	sig_hit = (reg_sel >= 3'd1 && reg_sel <= 3'd5) ? sig_valid[reg_sel] : 1'b0;
reg		[7:0] sig_val;
always @(*)
	case (reg_sel)
		3'd4:    sig_val = atapi[dev] ? 8'h14 : 8'h00;
		3'd5:    sig_val = atapi[dev] ? 8'hEB : 8'h00;
		default: sig_val = 8'h01;
	endcase

wire	[7:0] host_tfr = sig_hit ? sig_val : tfr[host_rsel];

// master/slave drive select
reg		dev_wr = 1'b0;			// sticky: host wrote drive/head
reg		rst_seen = 1'b0;		// sticky: reset
reg		snap_dev_wr = 1'b0;		// as captured by the last register read
reg		snap_rst_seen = 1'b0;
wire	dev_write = sel && reg_sel==3'd6 && hwr;

always @(posedge clk)
  if (clk7_en) begin
  	if (reset)
  		dev <= 0;
  	else if (dev_write)
  		dev <= data_in[12];
  end

always @(posedge clk)
  if (clk7_en) begin
  	if (hdd_regs_rd_p) begin
  		snap_dev_wr <= dev_wr;
  		snap_rst_seen <= rst_seen;
  	end
  	dev_wr <= dev_write | (dev_wr & ~hdd_regs_rd_p);
  	rst_seen <= reset | (rst_seen & ~hdd_regs_rd_p);
  end

// input multiplexer for the firmware.  It reads the register it addresses,
// busy or not: the one-port Gayle used tfr_sel, which follows the 68k's bus
// address while the port is idle -- harmless when the firmware only read a
// busy port, but the flags are read from idle ports too (which port has the
// command, rst_seen).  While busy, hdd_addr == tfr_sel, as before.
assign hdd_data_in = hdd_addr==0 ? fifo_data_out
                   : {1'b0, bsy_all[1], bsy_all[0], pkt_mode, snap_rst_seen, snap_dev_wr, xfer_done, (PORT != 0) ? 1'b1 : 1'b0, tfr[hdd_addr]};

//-----------------------------------------------------------------------------
// status register (written by the firmware)
// 7 - END: clear busy (command processing done)
// 5 - re-arm the signature (EXECUTE DEVICE DIAGNOSTIC, DEVICE RESET)
// 4 - intreq
// 3 - drq enable for pio in (PI) command type
// 2 - drq enable for pio out (PO) command type
// 0 - error flag (remember about setting error task file register)

// command busy status
always @(posedge clk)
  if (clk7_en) begin
  	if (reset)
  		busy <= GND;
  	else if (hdd_status_wr_p && hdd_data_out[7] || (sector_count_dec_in && sector_count == 8'h01))
  		busy <= GND;
  	else if (sel_command)
  		busy <= VCC;
  end

// interrupt request: the conditions are the old Gayle's, per port; the
// Gayle INTREQ register itself is shared (gayle.v)
always @(posedge clk)
  if (clk7_en) begin
  	drq_d <= drq;

  	if (reset) begin
  		block_mark <= GND;
  	end else begin
		if (busy && hdd_status_wr_p && hdd_data_out[3])
			block_mark <= VCC; // to handle IDENTIFY

		if (pio_in) begin // reads
			if (hdd_status_wr_p && hdd_data_out[4])
				block_mark <= VCC;
			if (!drq_d & drq & block_mark)
				block_mark <= GND;
		end
	end
  end

wire	irq_ata = pio_in  ? (!drq_d & drq & block_mark)
                : pio_out ? (hdd_status_wr_p & hdd_data_out[4])
                :           (hdd_status_wr_p & hdd_data_out[7]);
wire	irq_pkt = pkt_mode & hdd_status_wr_p & hdd_data_out[4] & ~hdd_data_out[3];
assign irq_set = ~reset & (irq_ata | irq_pkt);

// end of a packet-mode transfer
wire	xfer_end_in  = pkt_mode & pio_in  & (fifo_out_ptr == xfer_words);
wire	xfer_end_out = pkt_mode & pio_out & (fifo_in_ptr == xfer_words);

// pio in command type
always @(posedge clk)
  if (clk7_en) begin
  	if (reset)
  		pio_in <= GND;
  	else if (drdy) // reset when processing of the current command ends
  		pio_in <= GND;
  	else if (hdd_xfer_wr_p || xfer_end_in) // a new data phase, or this one is over
  		pio_in <= GND;
  	else if (busy && hdd_status_wr_p && hdd_data_out[3])
  		pio_in <= VCC;
  end

// pio out command type
always @(posedge clk)
  if (clk7_en) begin
  	if (reset)
  		pio_out <= GND;
  	else if (busy && hdd_status_wr_p && hdd_data_out[7])
  		pio_out <= GND;
  	else if (hdd_xfer_wr_p)
  		pio_out <= GND;
  	else if (busy && hdd_status_wr_p && hdd_data_out[2])
  		pio_out <= VCC;
  end

// packet mode registers
always @(posedge clk)
  if (clk7_en) begin
  	if (reset || sel_command)
  		pkt_mode_r <= GND;
  	else if (hdd_xfer_wr_p)
  		pkt_mode_r <= hdd_data_out[15];

  	if (hdd_xfer_wr_p)
  		xfer_words <= hdd_data_out[12:0];

  	if (reset || sel_command || hdd_xfer_wr_p)
  		xfer_done <= GND;
  	else if (xfer_end_in || xfer_end_out)
  		xfer_done <= VCC;
  end

wire	drq_ata = (fifo_full & pio_in) | (~fifo_full & pio_out & sector_count != 0);
wire	drq_pkt = pio_in ? ((fifo_full | fifo_in_ptr == xfer_words) & ~fifo_empty)
                         : (pio_out & (fifo_in_ptr < xfer_words));
assign drq = pkt_mode ? drq_pkt : drq_ata;

// error status
always @(posedge clk)
  if (clk7_en) begin
  	if (reset)
  		error <= GND;
  	else if (sel_command) // reset by the CPU when command register is written
  		error <= GND;
  	else if (busy && hdd_status_wr_p && hdd_data_out[0]) // set by SPI host
  		error <= VCC;
  end

assign dat_req = pkt_mode ? (pio_out & xfer_done) : (fifo_full & pio_out);

//-----------------------------------------------------------------------------
// FIFO in/out multiplexer
assign fifo_reset = reset | sel_command | hdd_xfer_wr_p;
assign fifo_data_in = pio_in ? hdd_data_out : data_in;
assign fifo_rd = pio_out ? hdd_data_rd_p : sel_fifo & rd;
assign fifo_wr = pio_in ? hdd_data_wr_p : sel_fifo & hwr & lwr;

gayle_fifo SECBUF
(
	.clk(clk),
	.clk7_en(clk7_en),
	.reset(fifo_reset),
	.data_in(fifo_data_in),
	.data_out(fifo_data_out),
	.rd(fifo_rd),
	.wr(fifo_wr),
	.full(fifo_full),
	.empty(fifo_empty),
	.last_out(fifo_last_out),
	.last_in(fifo_last_in),
	.in_ptr(fifo_in_ptr),
	.out_ptr(fifo_out_ptr)
);

// fifo is not ready for reading
assign nrdy = pio_in & sel_fifo & fifo_empty;

assign host_out = sel_fifo && rd ? fifo_data_out :
                  sel_status ? (hdd_ena[dev] ? {status,8'h00} : 16'h00_00) :
                  sel && rd ? {host_tfr,8'h00} : 16'h00_00;

endmodule
