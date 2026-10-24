// sdcard_gayle -- the Gayle side of the SD card block DMA (findings/
// sdcard-engine/design.md sections 4 and 11; plan Task 7).
//
// rtl/host/sdcard_spi.v (clk_114) moves 512-byte blocks between its FIFOs and
// the g_* handshake; this bridge carries the words to and from Gayle's sector
// FIFO through the firmware-side data port that paula_floppy.v drives today
// (hdd_data_out/in, hdd_data_wr/rd, hdd_port), via sdcard_gayle_mux below,
// which minimig.v puts between PAULA1 and GAYLE1.  What the Amiga sees of
// Gayle does not change: the bridge only makes the data strobes the firmware
// made over SPI, one word per strobe, and the firmware still does every
// status / task file write itself (WriteStatus(RDY) before a read group,
// END after the last).
//
// g_* contract: the sdcard_spi.v header.  In short: g_req a level for the op
// (may last 1 clk_114 cycle); g_dir / g_port / g_words stable with it; dir 1
// (RX -> Gayle): take g_wdata and pulse g_wnext only while g_wvalid; dir 0
// (Gayle -> TX): g_rvalid + g_rdata pulses >= 2 cycles apart; g_ack (>= 1
// cycle after the last word's pulse) ends the op, g_err aborts it; when g_req
// drops the bridge stops at once.  Word = {first byte, second byte}, the
// order paula_floppy.v builds hdd_data_out in; the bridge passes words whole.
//
// Two clocks: clk_g (clk_114, the g_* side) and clk (clk_28) with clk7_en
// (the Gayle side).  Everything that crosses goes through a 2-flop
// synchroniser as a Gray count or a toggle; a data word crosses as a register
// that stays put from the cycle its toggle flips until the other side has
// answered (dir 1) or for >= 2 clk7 periods (dir 0).  On the openaars board
// the two clocks are phase-aligned MMCM siblings (clk_114 = 4 x clk), timed
// as synchronous: the crossings are short register-to-register paths.  The
// scheme does not depend on that (sim/gayle bridge_async runs them apart).
//
//   op start / g_req drop: q_gray, a 3-bit Gray count of g_req edges (odd =
//     an op is live), and the op's dir / port / words latched on its rising
//     edge.  The Gayle side keeps `seen`, the count it has acted on.  When
//     the count moves, the op the bridge ran (if any) is over -- a drop if
//     the bridge had not ended it -- and if the new count is odd the latest
//     op is live and starts (any op in between is over: a 1-cycle g_req
//     whose two edges pass between two looks is skipped, it already ended at
//     the sdcard_spi end).  The count wraps only if 4 ops start within one
//     look (~28 clk_114 cycles; each start needs a CMD write through cfide).
//   young op: for its first YOUNG = 4 x CLK_RATIO clk_g cycles (q_age) the
//     clk_g side ignores every event from the Gayle side and owes no word.
//     With r = f(clk_g) / f(clk) = CLK_RATIO, anything the Gayle side sent
//     for the previous op before it saw that op end is decided on at most
//     ~2r+4 cycles after that op's g_req fell, and the Gayle side's first
//     event for a new op comes >= ~5r+3 cycles after its rise, so the window
//     must lie between: 2r+3 < YOUNG <= 5r+2 (r = 4, openaars: 16; 4r fits
//     for r = 2..16).  No word, end or error of one op can reach another,
//     however close the next op starts.  CLK_RATIO must match the clocks: a
//     wrong one fails silently.
//   dir 1 words: request / deliver.  The Gayle side flips breq to ask for a
//     word; the clk_g side, while it owes one (q_req_s != q_wtog) in a live,
//     not young dir-1 op with g_wvalid, pulses g_wnext and in that same cycle
//     takes g_wdata into q_wbuf and flips q_wtog.  g_wnext is combinational
//     from clk_g registers only (g_req, g_wvalid and the bridge's own), so a
//     word is in q_wbuf exactly when sdcard_spi popped it: no word can be
//     written to Gayle without being popped, whatever cycle g_req falls in.
//     Anywhere else it
//     absorbs an owed request (q_wtog follows it, nothing is popped), so a
//     request never outlives its op.  Exactly one word is popped per request:
//     g_words in a normal op, never one beyond it.  The Gayle side asks for
//     the first word one sample after the op starts (once the flags agree, so
//     an old request has been absorbed) and for the next one with the strobe
//     of this one (data_out is a copy): a word per clk7_en sample when the
//     clocks are aligned.  A word delivered for an earlier op is never used
//     (need is cleared at the start).
//   dir 0 words: rbuf (= g_rdata) is loaded and rtog flips when Gayle takes
//     a read strobe; the clk_g side pulses g_rvalid on the flip.
//   g_ack / g_err: atog / etog flip; the clk_g side pulses them in a live op
//     (an end that crosses a drop is not sent).  g_ack goes one clk7 period
//     after the last word (dir 0: after its g_rvalid).
//
// Gayle side (clk7_en): data_wr / data_rd are registers, high for exactly one
//   clk7_en sample per word, as paula_floppy.v makes them (its rx_flag /
//   tx_flag strobes).
//   - dir 1: a write strobe per delivered word, back to back; Gayle's FIFO
//     state is not looked at (the firmware starts the op once the FIFO is
//     drained: WriteStatus(RDY), then hdd_cmd_req).
//   - dir 0: a read strobe every other sample while hdd_dat_req (the FIFO
//     holds a whole block / the packet): the strobe pops the word that is on
//     hdd_data_in during it, which the bridge takes in the same sample
//     (paula_floppy.v loads its SPI word from hdd_data_in before its
//     hdd_data_rd pops it); gayle_fifo.v's registered output shows the next
//     word one sample later, hence every other sample.
//   - The first strobe comes one sample after `active` rises, so hdd_port,
//     hdd_dat_req and hdd_data_in already belong to the op's port.
//   - fifo_reset_seen[port] (Gayle reset, the Amiga's new command, the
//     firmware's CMD_IDE_XFER_WR) or `reset` in any sample of an op, its
//     first included: g_err, `active` drops, no further strobe (a strobe in
//     that same sample meets the FIFO reset and is lost with the rest).  In
//     the first sample it is held and sent one sample later (young op).
//   - g_req drop seen: no further strobe, `active` drops, nothing is sent.
//     Words already taken from one side may not reach the other (dir 1: at
//     most one popped from RX; dir 0: up to two from Gayle's FIFO): the op
//     ended early, sdcard_spi rolls TX back, the firmware fails the command.
//   - `reset` (the Amiga reset) only aborts: the crossing registers are never
//     reset (their power-up values match), or the two sides would disagree.
//
// Abandoned command (cmd_since): a new Amiga command (or Gayle reset) on a
// port while no op runs resets that port's FIFO too, and the next op would
// fill the new command's FIFO with the old command's data (pio in and the
// block mark survive a command write: DRQ and the interrupt would follow).
// So cmd_since[p] is set by a FIFO reset of port p that is not the
// firmware's own CMD_IDE_XFER_WR, and cleared by the firmware's
// CMD_IDE_REGS_RD of port p (set wins; Gayle's dev_wr / rst_seen rule).  An
// op that starts with it set ends in g_err (STATUS 7) without a strobe.
// Firmware rule: a REGS_RD of a port means "I have seen this port's command":
// fw/ctrl issues one at the command pickup (HandleHDD), in cd_wait (which
// checks IDEF_PKT for a new command) and outside commands (CD_AudioPoll,
// CD_Locked), never inside a transfer loop; keep it so.  After a Gayle error
// the firmware picks the new command up (REGS_RD), which clears the flag.
//
// Timing constraints (Task 8): the crossings are q_gray -> s_gray1 (a Gray
// bus), q_wtog -> s_wtog, breq -> q_req_s, rtog / atog / etog -> q_rs / q_as
// / q_es, and the held words q_wbuf -> dout, q_dir / q_port / q_words -> the
// Gayle side, rbuf -> sdcard_spi (g_rdata).  On openaars the clocks are
// synchronous MMCM siblings and these paths are timed as such, which is
// enough.  With unrelated clocks they need set_max_delay -datapath_only of
// about one clk_114 period (or set_bus_skew on the Gray bus), not a false
// path: the held words must arrive before their toggle is seen.
//
// The latched dir / port / words are read by the Gayle side in the sample it
// starts an op.  Should the next op already have started by then (two op
// starts within ~28 clk_114), they may be that op's: harmless, the count has
// moved too and the next sample restarts with the new op before any strobe
// or request goes out.
//
// Plain Verilog-2005, no vendor primitives.  Bench: sim/gayle (run.sh
// bridge, bridge_async).  SDG_MUT_*: bench teeth only (run.sh bridge_mut_*).
module sdcard_gayle #(
    parameter CLK_RATIO = 4             // f(clk_g) / f(clk), rounded, 2..16: sizes the young-op window
) (
    input  wire        clk,             // clk_28
    input  wire        clk7_en,
    input  wire        reset,           // the Amiga reset: aborts an op (g_err)
    input  wire        clk_g,           // clk_114, sdcard_spi's clock
    input  wire        g_req, input wire g_dir, input wire g_port, input wire [9:0] g_words,
    output wire        g_ack, output wire g_err,
    input  wire [15:0] g_wdata, input wire g_wvalid, output wire g_wnext,
    output wire [15:0] g_rdata, output wire g_rvalid,
    output wire        active,          // the bridge owns Gayle's data port (sdcard_gayle_mux)
    output wire        port,            // the op's IDE port
    output wire        data_wr, output wire data_rd,      // high for exactly one clk7_en sample
    output wire [15:0] data_out, input wire [15:0] data_in,
    input  wire        dat_req,         // Gayle's hdd_dat_req (of `port` while active)
    input  wire  [1:0] fifo_reset_seen, // Gayle's hdd_fifo_reset, per port
    input  wire        fw_port,         // paula_floppy's hdd_port, hdd_xfer_wr, hdd_regs_rd
    input  wire        fw_xfer_wr,
    input  wire        fw_regs_rd
);

    // 3-bit Gray code <-> binary
    function [2:0] g2b(input [2:0] g);
        g2b = {g[2], g[2] ^ g[1], g[2] ^ g[1] ^ g[0]};
    endfunction
    function [2:0] b2g(input [2:0] b);
        b2g = b ^ {1'b0, b[2:1]};
    endfunction

    //------------------------------------------------------------------------
    // clk_g side

    reg  [2:0] q_gray = 3'b000;         // Gray count of g_req edges
    wire       q_live = ^q_gray;        // odd: g_req was high last cycle
    localparam integer YOUNG_I = 4 * CLK_RATIO - 1;   // last young cycle (CLK_RATIO 2..16)
    localparam [5:0] YOUNG = YOUNG_I[5:0];
    reg  [5:0] q_age = 6'd0;            // cycles since the rise, saturating
`ifdef SDG_MUT_NOYOUNG
    wire       q_old = q_live;
`else
    wire       q_old = q_live && q_age == YOUNG;    // live and not young
`endif
    reg        q_dir = 1'b0, q_port = 1'b0;
    reg  [9:0] q_words = 10'd0;
    reg  [1:0] q_req_s = 2'b00;         // breq, synchronised
    reg        q_wtog = 1'b0;           // flips per word delivered (or request absorbed)
    reg [15:0] q_wbuf = 16'h0000;
`ifdef SDG_MUT_REGWNEXT
    reg        q_wnext = 1'b0;
`endif
    reg  [2:0] q_rs = 3'b000, q_as = 3'b000, q_es = 3'b000;   // rtog / atog / etog: 2 sync + 1
    reg        q_rvalid = 1'b0, q_ack = 1'b0, q_err = 1'b0;

    reg        breq = 1'b0;             // Gayle side, below
    reg        rtog = 1'b0, atog = 1'b0, etog = 1'b0;

    wire       q_run1 = g_req && q_old && q_dir;   // a live dir-1 op may pop words
    wire       q_owed = q_req_s[1] != q_wtog;
    wire       q_serve = q_run1 && q_owed && g_wvalid;    // = g_wnext: pop and take in one cycle

    always @(posedge clk_g) begin
        if (g_req != q_live)
            q_gray <= b2g(g2b(q_gray) + 3'd1);
        if (g_req && !q_live) begin
            q_dir <= g_dir;
            q_port <= g_port;
            q_words <= g_words;
            q_age <= 6'd0;
        end else if (q_age != YOUNG)
            q_age <= q_age + 6'd1;
        q_req_s <= {q_req_s[0], breq};
`ifdef SDG_MUT_REGWNEXT
        q_wnext <= q_serve;
`endif
`ifdef SDG_MUT_NOABSORB
        if (!q_run1)
            ;
`else
        if (!q_run1)
            q_wtog <= q_req_s[1];       // absorb: no word is owed outside a dir-1 op
`endif
        else if (q_serve) begin
            q_wbuf <= g_wdata;
            q_wtog <= ~q_wtog;
        end
        q_rs <= {q_rs[1:0], rtog};
        q_as <= {q_as[1:0], atog};
        q_es <= {q_es[1:0], etog};
        q_rvalid <= g_req && q_old && !q_dir && (q_rs[2] != q_rs[1]);
        q_ack <= g_req && q_old && (q_as[2] != q_as[1]);
        q_err <= g_req && q_old && (q_es[2] != q_es[1]);
    end

`ifdef SDG_MUT_REGWNEXT
    assign g_wnext  = q_wnext;          // bench teeth: the pulse a cycle after the take
`else
    assign g_wnext  = q_serve;
`endif
    assign g_rvalid = q_rvalid;
    assign g_ack    = q_ack;
    assign g_err    = q_err;

    //------------------------------------------------------------------------
    // Gayle side

    reg  [2:0] s_gray1 = 3'b000, s_gray2 = 3'b000; // q_gray, synchronised
    reg  [1:0] s_wtog = 2'b00;                     // q_wtog, synchronised
    reg  [2:0] seen = 3'b000;           // binary count of g_req edges acted on
    reg        act = 1'b0, b_dir = 1'b0, b_port = 1'b0;
    reg        b_rst = 1'b0;            // FIFO reset in the op's first sample
    reg  [9:0] cnt = 10'd0;             // words still to strobe
    reg        need = 1'b0;             // dir 1: a word asked for in this op and not used yet
    reg        wr_r = 1'b0, rd_r = 1'b0;
    reg [15:0] dout = 16'h0000, rbuf = 16'h0000;
    reg  [1:0] cmd_since = 2'b00;       // per port: a command since the firmware's last REGS_RD
    wire [1:0] fw_sel = {fw_port, ~fw_port};
    wire [1:0] cmd_set = fifo_reset_seen & ~({2{fw_xfer_wr}} & fw_sel);
    wire [1:0] cmd_clr = {2{fw_regs_rd}} & fw_sel;

    wire [2:0] gcnt = g2b(s_gray2);
    wire       w_even = s_wtog[1] == breq;  // every request answered
    wire       w_have = need && w_even;     // the word asked for is in q_wbuf
`ifdef SDG_MUT_NORST
    wire       abort_new = 1'b0;
    wire       abort_run = 1'b0;
`elsif SDG_MUT_NOSINCE
    wire       abort_new = reset || fifo_reset_seen[q_port];
    wire       abort_run = reset || fifo_reset_seen[b_port] || b_rst;
`else
    wire       abort_new = reset || fifo_reset_seen[q_port] || cmd_since[q_port];   // q_port: see above
    wire       abort_run = reset || fifo_reset_seen[b_port] || b_rst;
`endif

    always @(posedge clk) begin
        s_gray1 <= q_gray;
        s_gray2 <= s_gray1;
        s_wtog <= {s_wtog[0], q_wtog};
        if (clk7_en) begin
            cmd_since <= cmd_set | (cmd_since & ~cmd_clr);
            if (gcnt != seen) begin             // an op ended and / or the latest started
                seen <= gcnt;
                act <= gcnt[0];
                wr_r <= 1'b0;
                rd_r <= 1'b0;
                b_dir <= q_dir;
                b_port <= q_port;
                b_rst <= abort_new;
                cnt <= q_words;
                need <= 1'b0;
            end else if (!act) begin
                wr_r <= 1'b0;
                rd_r <= 1'b0;
            end else if (abort_run) begin       // FIFO reset: give up
                act <= 1'b0;
                wr_r <= 1'b0;
                rd_r <= 1'b0;
                etog <= ~etog;
            end else if (cnt == 10'd0 && !wr_r && !rd_r) begin
                act <= 1'b0;                    // the last strobe was taken a sample ago
                atog <= ~atog;
            end else if (b_dir) begin
                if (w_have) begin
                    dout <= q_wbuf;
                    wr_r <= 1'b1;
                    cnt <= cnt - 10'd1;
                    if (cnt != 10'd1)
                        breq <= ~breq;          // ask for the next one
                    else
                        need <= 1'b0;
                end else begin
                    wr_r <= 1'b0;
                    if (!need && cnt != 10'd0 && w_even) begin
                        breq <= ~breq;          // ask for the first one
                        need <= 1'b1;
                    end
                end
            end else begin
                if (rd_r) begin                 // Gayle pops this sample: take its word
                    rbuf <= data_in;
                    rtog <= ~rtog;
                    rd_r <= 1'b0;
                end else if (dat_req && cnt != 10'd0) begin
                    rd_r <= 1'b1;
                    cnt <= cnt - 10'd1;
                end
            end
        end
    end

    assign g_rdata  = rbuf;
    assign active   = act;
    assign port     = b_port;
    assign data_wr  = wr_r;
    assign data_rd  = rd_r;
    assign data_out = dout;

endmodule

// The firmware-side data port of Gayle: the bridge's while it is active,
// paula_floppy's otherwise.  paula_floppy's data strobes are blocked while the
// bridge is active, so a firmware slip (an IDE data command over SPI during a
// DMA) can neither add nor take a word.  hdd_addr is 0 while the bridge is
// active, as paula_floppy presents it during its own data commands (after a
// task file command it stays at that command's register count, and Gayle's
// hdd_data_in would show a register instead of the FIFO).  paula_floppy's
// other strobes (task file and status writes, CMD_IDE_XFER_WR,
// CMD_IDE_REGS_RD) pass unchanged; they use hdd_port and hdd_data_out too,
// so the firmware sends no HDD command while a Gayle op runs.  Gayle's host
// register reads during a busy ATA command follow hdd_addr as well; they see
// what they see during today's SPI data commands.  minimig.v instantiates
// this between PAULA1 and GAYLE1.
/* verilator lint_off DECLFILENAME */
module sdcard_gayle_mux (
    input  wire        sg_active, input wire sg_port,
    input  wire        sg_data_wr, input wire sg_data_rd,
    input  wire [15:0] sg_data_out,
    input  wire        pf_port,
    input  wire        pf_data_wr, input wire pf_data_rd,
    input  wire [15:0] pf_data_out,
    input  wire  [2:0] pf_addr,
    output wire        hdd_port,
    output wire        hdd_data_wr, output wire hdd_data_rd,
    output wire [15:0] hdd_data_out,
    output wire  [2:0] hdd_addr
);
`ifdef SDG_MUT_NOGATE
    assign hdd_data_wr  = pf_data_wr | (sg_active & sg_data_wr);
    assign hdd_data_rd  = pf_data_rd | (sg_active & sg_data_rd);
`else
    assign hdd_data_wr  = sg_active ? sg_data_wr : pf_data_wr;
    assign hdd_data_rd  = sg_active ? sg_data_rd : pf_data_rd;
`endif
    assign hdd_data_out = sg_active ? sg_data_out : pf_data_out;
    assign hdd_port     = sg_active ? sg_port : pf_port;
`ifdef SDG_MUT_NOADDR
    assign hdd_addr     = pf_addr;
`else
    assign hdd_addr     = sg_active ? 3'd0 : pf_addr;
`endif
endmodule
/* verilator lint_on DECLFILENAME */
