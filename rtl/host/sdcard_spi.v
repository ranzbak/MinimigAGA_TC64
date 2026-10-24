// sdcard_spi -- SD card SPI peripheral of the OSD CPU (clk = clk_114).
//
// Protocol-agnostic SPI master for the SD card (the card stays in SPI mode):
// TX and RX FIFOs with watermark interrupts, a byte shifter with CRC16,
// wait-for-byte with a timeout, the clk_114 side of the Gayle block DMA and
// a register window.  The firmware runs the SD protocol on it.  Design:
// findings/sdcard-engine/design.md sections 4 and 11; plan Tasks 5, 6.
// Bench: sim/sdcard_spi (run.sh).  Plain Verilog-2005, no vendor primitives.
//
// Register map (16 bit; reg_addr = byte address bits 5:2 of 0xFFFFFF00..2C)
//   idx addr  write                            read
//    0  00    TXW  push 2 bytes (15:8 first)   RXW  pop 2 bytes (first in 15:8)
//    1  04    TXB  push 1 byte (7:0)           RXB  pop 1 byte (7:0; 15:8 = 0)
//    2  08    -                                RXLVL bytes in RX (10:0)
//    3  0C    -                                TXLVL bytes in TX incl. kept (10:0)
//    4  10    CMD  start an op                 STATUS
//    5  14    LEN  byte count (10:0)           LAST  last received byte (7:0)
//    6  18    MATCH byte for wait ops (7:0)    COUNT bytes moved by the last op (10:0)
//    7  1C    IRQACK write 1 to clear          IRQPEND
//    8  20    CFG  7:0 divider, 8 CS asserted  CFG
//    9  24    TIMEOUT (units of 16384 clk,     TIMEOUT
//             0 = 1 unit)
//   10  28    IRQEN                            IRQEN
//   11  2C    WMARK 15:8 RX high, 7:0 TX low   VERSION
//             (units of 16 bytes)
//   12-15     ignored                          0
//   LEN, MATCH and TIMEOUT writes are ignored while an op is busy.  CFG writes
//   while busy are refused (STATUS bit 6 + IRQ bit 3, CFG unchanged): CS
//   and the divider never change in the middle of a byte.
//
// CMD 3:0 op, bits 4-8 per op:
//    1 XFER        LEN bytes.  Bit 4: TX from the FIFO (else $FF); bit 5: RX
//                  into the FIFO (else discarded); bit 6: then 2 more bytes,
//                  the CRC16 of the LEN bytes sent (bits 6 + 7 together are
//                  refused); bit 7: then 2 more bytes received and checked
//                  as the CRC16 of the LEN bytes received (not stored):
//                  STATUS 1.  COUNT counts the CRC bytes too.  LEN 0
//                  completes at once (no CRC bytes either).
//    2 WAIT_EQ     clock $FF until the byte received equals MATCH (3
//    3 WAIT_NE     WAIT_NE: differs from MATCH); nothing enters RX; LAST =
//                  that byte; COUNT = bytes clocked (mod 2048).  Bounded by
//                  TIMEOUT: when it runs out the op ends at the next byte
//                  boundary with STATUS 2.  LEN and bits 4-8 are ignored.
//    4 GAYLE_TO_TX LEN bytes (LEN/2 words) from the Gayle bridge into TX
//    5 RX_TO_GAYLE LEN bytes from RX to the Gayle bridge; bit 8: g_port.
//                  LEN even and > 0, else refused.  GAYLE_TO_TX is refused
//                  unless TX has room for LEN bytes; RX_TO_GAYLE unless the
//                  first LEN bytes of RX are verified (the interlock below).
//                  Not bounded by TIMEOUT (the Amiga sets the pace; ABORT).
//    6 TX_REWIND   TX sends again from the oldest kept byte (the commit
//                  point); the prefetched next byte is dropped
//    7 TX_COMMIT   frees the bytes sent so far (the commit point moves to
//                  the next unsent byte)
//    8 RX_FLUSH    RX empty (prefetch included); verified 0, not poisoned
//    9 TX_FLUSH    TX empty, kept bytes included
//   15 ABORT       accepted at any time, see below
//   Ops 1-9 are accepted only while not busy (with the checks above):
//   accepting clears STATUS 7:1 and COUNT; 6-9 and XFER LEN 0 complete at
//   once (IRQ bit 0).  Everything else is REFUSED: STATUS 6 and IRQ bit 3
//   set, nothing else changes (a running op goes on; no op-done IRQ).
//
// TX keep: TX holds every byte from the commit point on, sent or not;
//   TXLVL counts them all and pushes find room only behind them.  A write
//   retry: the block (token + data) stays kept; the firmware pushes the new
//   command behind it and sends it, then TX_REWIND goes back to the token
//   and the block is sent again byte for byte (XFER 1 + XFER 512 bits 4 + 6);
//   afterwards TX_FLUSH (or TX_COMMIT, which leaves the unsent copy of the
//   command) frees it.  The firmware commits after every command it does
//   not want to resend.
//
// Interlock (no unverified byte reaches Gayle): `verified` counts the bytes
//   at the RX head that come from CRC-checked blocks, `poisoned` is set by a
//   CRC failure.  An XFER with bits 5 + 7 that completes with CRC ok adds its
//   bytes (everything then in RX) only if RX held nothing but verified bytes
//   when it started and RX is not poisoned; one that completes with a CRC
//   mismatch poisons RX.  Every RX pop (CPU or Gayle) takes one off
//   (saturating at 0).  RX_FLUSH clears both.  RX_TO_GAYLE needs !poisoned
//   and verified >= LEN (so RXLVL >= LEN: verified never exceeds RXLVL).
//   While poisoned every RX_TO_GAYLE is refused, also of good bytes ahead
//   of the bad block: the firmware flushes and reads again.
//
// Op ends (busy -> 0; IRQ bit 0 always; STATUS / IRQ bit 3 per reason):
//   - normal: LEN (+ CRC) bytes / the wait condition / g_ack with LEN bytes
//     moved.  XFER bit 7: STATUS 1 = CRC ok (a mismatch is a result, not an
//     error: no IRQ bit 3).
//   - ABORT while busy: XFER / wait ops stop at the next byte boundary (SCK
//     stops within one byte; CS untouched), at once when no byte is being
//     shifted (paused) and for Gayle ops (g_req drops).  STATUS 4; COUNT =
//     bytes moved; IRQ bit 0 only.  ABORT while idle: no change, IRQ bit 0.
//     ABORT does not clear STATUS 8.
//   - timeout (wait ops): STATUS 2 + IRQ bit 3.
//   - card gone: the synchronised card-detect level shows no card (not the
//     debounced one): the op ends at once, mid-byte too (SCK low, MOSI
//     high), STATUS 5 + IRQ bit 3.  An op started without a card ends so
//     in its first cycle.
//   - Gayle error: g_err, or g_ack with fewer than LEN bytes moved: STATUS
//     7 + IRQ bit 3.
//   GAYLE_TO_TX ending any way but normally removes every byte it put in
//   TX (TX back to its state at the op's start): no partial block.
//
// STATUS: 0 busy, 1 crc_ok, 2 timeout, 3 card present (debounced), 4
//   aborted, 5 card gone during the op, 6 refused, 7 Gayle error, 8 FIFO
//   misuse: a byte pushed into a full TX (dropped; also the second byte of a
//   TXW), a pop that found fewer bytes than it asked for (00 returned for
//   each missing byte), or a TXW / TXB / RXW / RXB during a Gayle op (the
//   data port is locked then: pushes dropped, pops return 0000 and take
//   nothing).  Sticky; IRQ bit 3 with it; cleared by the next accepted CMD.
// IRQPEND / IRQEN / IRQACK: 0 op done, 1 RX >= high watermark, 2 TX <= low
//   watermark (TXLVL, kept bytes included), 3 error (refused CMD / CFG, FIFO
//   misuse, op ended by timeout / card gone / Gayle error), 4 card-detect
//   change.  irq = |(IRQPEND & IRQEN), registered.  Bits 1 and 2 are set
//   every cycle their condition holds (an IRQACK only clears them once the
//   level has moved past the mark); the others are events.  RX high mark 0
//   is always true.
//
// Gayle handshake (clk_114 side; Task 7's bridge sdcard_gayle.v honours it):
//   - g_req: a register, high from the cycle after the op is accepted until
//     the op ends (done, error, abort, card gone).  g_dir (1: RX -> Gayle,
//     0: Gayle -> TX), g_port (CMD bit 8) and g_words (LEN / 2, 1..512) are
//     registers, stable while g_req is high.  The bridge stops at once when
//     g_req drops (it may do so in any cycle).
//   - dir 1: g_wdata = the word at the RX head {first byte, second byte},
//     valid from the first cycle of g_req.  The bridge pulses g_wnext for one
//     cycle when it has taken the word (it samples g_wdata in that cycle);
//     the next word is valid from the 3rd cycle after the g_wnext cycle, so
//     g_wnext pulses are at least 4 cycles apart (3 works; 4 leaves a
//     cycle).  Pulses beyond g_words are ignored.  An early g_wnext breaks
//     the contract: it pops what is there and sets STATUS 8.
//   - dir 0: the bridge pulses g_rvalid for one cycle with g_rdata = {first
//     byte, second byte}; pulses at least 2 cycles apart.  The 2 bytes go
//     into TX.  Pulses beyond g_words are ignored.
//   - g_ack (one cycle, at least 1 cycle after the last word's pulse): the
//     bridge is done.  With g_words words moved the op ends normally; with
//     fewer it is a Gayle error.
//   - g_err (one cycle, any time while g_req): the bridge gave up (the Amiga
//     abandoned the command, FIFO reset): the op ends with STATUS 7.
//   - g_ack / g_err / g_wnext / g_rvalid outside g_req are ignored.
//
// Register timing contract (Task 8, cfide):
//   - reg_wstb / reg_rstb: one clk cycle, the first cycle of an access;
//     reg_addr / reg_d are sampled in that cycle only.
//   - reg_q is a register (rdq), loaded at the end of the strobe cycle with
//     the value the register had in that cycle: valid from the cycle after
//     the strobe until the next read strobe.  A pop (RXW / RXB) returns the
//     bytes before the pop; the pop itself takes effect at the same edge.
//   - Pops come from two prefetch registers (h0, h1) that refill from the
//     RAM by themselves, one byte per cycle: after a pop they are full
//     again 2 cycles later, and a byte counted in RXLVL is in them 2 cycles
//     after it is counted (4 if a TXW is being written then).  So with
//     strobes at least 4 cycles apart (the minimum this block is built
//     for; cfide's clk_28 ack gives more), back-to-back RXW pops, and a pop
//     after an RXLVL read or an op-done IRQ, always find their bytes.  A
//     pop finding fewer bytes than it asks for returns 00 for the missing
//     ones, pops only what it returned and sets STATUS 8 (on an empty RX:
//     0000, nothing popped).
//   - TXW writes its first byte in the strobe cycle and the second one in
//     the next.  Push strobes are assumed >= 2 cycles apart (cfide: >= 4);
//     guard: a push strobe in the cycle of a pending second byte is latched
//     (dfr_*) and written after it.  A push into a full TX is dropped
//     (TXLVL stays 1024) and sets STATUS 8.
//
// FIFOs: one inferred 2048 x 8 RAM, RX at 0-1023, TX at 1024-2047; true
// dual port, one clock, registered read, no reset; per port "write, else
// read" (the output holds on a write cycle, so simulators and the Xilinx
// and Intel mappings agree; no port reads in a cycle it writes).  One
// RAMB18 on Xilinx, M9K/M10K pairs on Intel.
//   port A: CPU side -- TX pushes and GAYLE_TO_TX words (write), RX
//           prefetch (read; RX_TO_GAYLE pops through it like the CPU)
//   port B: shifter -- TX next-byte prefetch (read, txn), RX byte (write)
// Each side holds 1024 bytes including its prefetch registers.  TX
// pointers: tx_wr (push), tx_rd (prefetch read), tx_cm (commit point);
// TXLVL = tx_wr - tx_cm.
//
// Shifter: SPI mode 0, MSB first, SCK idles low; SCK = clk / (2 * (div + 1)),
// a register (generated clock in Task 8's XDC).  MISO is sampled at the clk
// edge that raises SCK, MOSI changes with SCK falling.  Bytes follow each
// other without a gap; SCK stays low (pause) while TX is empty for a
// TX-sourced op or RX is full for an RX-sinking op (never during the CRC
// bytes or a wait op).  MOSI idles high.  CS: CFG bit 8 = 1 drives sd_cs_n
// low (a register).
//
// CRC16: CCITT x^16 + x^12 + x^5 + 1, init 0, one byte per update (SD's data
// CRC).  On RX the 2 received CRC bytes go through it too: zero = match.
//
// Card detect: sd_cd_n (low = inserted) through 2 flops, debounced: a new
// level counts after 2^CD_DEBOUNCE_LOG2 clocks (20: 9.2 ms); its change
// sets IRQ bit 4.  Reset loads the synchronised level (reset must last >= 3
// clocks), so a card present at reset gives no change IRQ.
//
// Bench mutants (sim/sdcard_spi/run.sh): SDC_MUT_NOCRC (CRC check always
// ok), SDC_MUT_NOINTERLOCK (RX_TO_GAYLE checks only LEN), SDC_MUT_NOTIMEOUT.
module sdcard_spi #(
    parameter VERSION = 16'h5D01,
    parameter CD_DEBOUNCE_LOG2 = 20
) (
    input  wire        clk, input wire reset,
    input  wire        reg_wstb, input wire reg_rstb,  // one-cycle strobes, first cycle of an access
    input  wire [5:2]  reg_addr,                        // {window[1:0], sub[1:0]}, windows 0..2
    input  wire [15:0] reg_d,  output wire [15:0] reg_q,
    output wire        irq,                             // level, to cfide irq_src(4)
    output wire        sd_sck, output wire sd_cs_n, output wire sd_mosi, input wire sd_miso,
    input  wire        sd_cd_n,                         // card detect, low = inserted, unsynchronised
    output wire        g_req, output wire g_dir,        // dir 1: RX FIFO -> Gayle; 0: Gayle -> TX FIFO
    output wire        g_port, output wire [9:0] g_words,
    input  wire        g_ack, input wire g_err,
    output wire [15:0] g_wdata, input wire g_wnext,
    input  wire [15:0] g_rdata, input wire g_rvalid
);

    localparam [3:0] OP_XFER = 4'd1, OP_WAIT_EQ = 4'd2, OP_WAIT_NE = 4'd3,
                     OP_G2TX = 4'd4, OP_RX2G = 4'd5, OP_TX_REWIND = 4'd6,
                     OP_TX_COMMIT = 4'd7, OP_RX_FLUSH = 4'd8, OP_TX_FLUSH = 4'd9,
                     OP_ABORT = 4'd15;

    // CRC16 CCITT, one byte (MSB first)
    function [15:0] crc16_byte(input [15:0] c, input [7:0] b);
        integer i;
        reg [15:0] x;
        begin
            x = c;
            for (i = 7; i >= 0; i = i - 1)
                x = {x[14:0], 1'b0} ^ ((x[15] ^ b[i]) ? 16'h1021 : 16'h0000);
            crc16_byte = x;
        end
    endfunction

    // ------------------------------------------------------------ registers
    reg  [7:0] cfg_div;
    reg        cs_n_r;
    reg [15:0] timeout_r;
    reg  [4:0] irq_en, irq_pend;
    reg        irq_r;
    reg  [7:0] wm_rx, wm_tx;
    reg [10:0] len_r;
    reg  [7:0] match_r;
    reg  [7:0] last_r;
    reg [10:0] cnt;                     // COUNT
    reg        busy;
    reg        st_crc_ok, st_timeout, st_aborted, st_gone, st_refused, st_gerr;
    reg        st_misuse;               // STATUS 8: FIFO misuse since the last accepted CMD
    reg [15:0] rdq;

    wire [3:0] ra = reg_addr;
    wire w_txw = reg_wstb && ra == 4'd0;
    wire w_txb = reg_wstb && ra == 4'd1;
    wire w_cmd = reg_wstb && ra == 4'd4;
    wire w_ack = reg_wstb && ra == 4'd7;
    wire r_rxw = reg_rstb && ra == 4'd0;
    wire r_rxb = reg_rstb && ra == 4'd1;

    // ------------------------------------------------------------ RAM
    reg  [7:0] ram [0:2047];
    wire [10:0] a_addr, b_addr;
    wire        a_we, b_we;
    wire  [7:0] a_din, b_din;
    reg   [7:0] a_dout, b_dout;

    always @(posedge clk) begin
        if (a_we) ram[a_addr] <= a_din;
        else      a_dout <= ram[a_addr];
    end
    always @(posedge clk) begin
        if (b_we) ram[b_addr] <= b_din;
        else      b_dout <= ram[b_addr];
    end

    // FIFO pointers (11 bits: 10 address + wrap) and levels (0..1024)
    reg  [10:0] tx_wr, tx_rd, tx_cm, rx_wr, rx_rd;
    reg  [10:0] rxlvl;
    wire [10:0] txlvl = tx_wr - tx_cm;  // kept bytes included
    reg  [10:0] tx_wr0;                 // tx_wr at the start of a GAYLE_TO_TX (rollback)
    reg  [10:0] verified;               // verified bytes at the RX head
    reg         poisoned;               // a CRC-checked block failed since RX_FLUSH

    // op state
    reg        op_tx, op_rx;            // XFER bits 4, 5
    reg        op_ctx, op_crx;          // XFER bits 6, 7
    reg        op_wait, op_ne;          // WAIT_EQ / WAIT_NE
    reg        g_req_r, g_dir_r, g_port_r;   // a Gayle op runs (= busy && Gayle op)
    reg  [1:0] cph;                     // the byte being shifted: 0 data, 1 / 2 CRC byte 1 / 2
    reg [15:0] crc;
    reg        ahead_ok;                // at XFER start: RX all verified, not poisoned
    reg        abort_pend;
    reg [13:0] tmo_pre;
    reg [15:0] tmo_u;                   // whole units elapsed
    wire [15:0] tmo_u_inc = tmo_u + 16'd1;
    reg        tmo_pend;

    // ------------------------------------------------------------ op decode
    wire [3:0] cmd_op   = reg_d[3:0];
    wire       len_ok   = len_r != 11'd0 && !len_r[0];       // Gayle ops: even, > 0
    wire       tx_room  = {1'b0, txlvl} + {1'b0, len_r} <= 12'd1024;
`ifdef SDC_MUT_NOINTERLOCK
    wire       rx_ready = 1'b1;
`else
    // RXLVL >= LEN follows: verified <= RXLVL always (set to RXLVL at most,
    // both lowered by every pop; the bench checks it every cycle)
    wire       rx_ready = !poisoned && verified >= len_r;
`endif
    reg        cmd_ok;
    always @* begin
        case (cmd_op)
            OP_XFER:      cmd_ok = !(reg_d[6] && reg_d[7]);
            OP_WAIT_EQ, OP_WAIT_NE, OP_TX_REWIND, OP_TX_COMMIT, OP_RX_FLUSH, OP_TX_FLUSH:
                          cmd_ok = 1'b1;
            OP_G2TX:      cmd_ok = len_ok && tx_room;
            OP_RX2G:      cmd_ok = len_ok && rx_ready;
            default:      cmd_ok = 1'b0;
        endcase
    end
    wire       w_abort     = w_cmd && cmd_op == OP_ABORT;
    wire       cmd_accept  = w_cmd && !busy && cmd_ok;
    wire       cmd_refuse  = w_cmd && !cmd_accept && !w_abort;
    wire       cfg_refuse  = reg_wstb && ra == 4'd8 && busy;   // CS / divider fixed during an op
    wire       refuse_evt  = cmd_refuse | cfg_refuse;
    wire       is_xfer     = cmd_op == OP_XFER;
    wire       is_wait     = cmd_op[3:1] == 3'b001;             // 2, 3
    wire       is_gayle    = cmd_op[3:1] == 3'b010;             // 4, 5
    wire       go          = cmd_accept && ((is_xfer && len_r != 11'd0) || is_wait || is_gayle);
    wire       rx_flush    = cmd_accept && cmd_op == OP_RX_FLUSH;
    wire       tx_flush    = cmd_accept && cmd_op == OP_TX_FLUSH;
    wire       tx_rewind   = cmd_accept && cmd_op == OP_TX_REWIND;
    wire       tx_commit   = cmd_accept && cmd_op == OP_TX_COMMIT;

    // ------------------------------------------------------------ Gayle words
    wire       cpu_lock = g_req_r;                    // CPU data port locked during a Gayle op
    wire       g_more   = cnt != len_r;               // LEN even, words of 2: an exact compare
    wire       g_pop    = g_req_r && g_dir_r && g_wnext && g_more;
    wire       g_push   = g_req_r && !g_dir_r && g_rvalid && g_more;
    wire       g_word   = g_pop | g_push;
    wire       g_end    = g_req_r && (g_ack || g_err);
    wire       g_good   = g_ack && !g_err && !g_more;

    // ------------------------------------------------------------ TX push (port A)
    reg        pend_v;                  // second byte of a TXW still to write
    reg  [7:0] pend_b;
    reg        dfr_v, dfr_w;            // guard: a push strobe that met pend_v
    reg [15:0] dfr_d;
    wire cpu_push  = (w_txw | w_txb) && !cpu_lock;
    wire push_new  = cpu_push | g_push;
    wire pn_word   = g_push | w_txw;    // the new push is a word
    wire [15:0] pn_d = g_push ? g_rdata : reg_d;
    wire src_dfr   = !pend_v && dfr_v;
    wire src_new   = !pend_v && !dfr_v && push_new;
    wire push_go   = pend_v | src_dfr | src_new;
    wire push_word = src_dfr ? dfr_w : pn_word;
    wire [7:0] push_byte = pend_v  ? pend_b :
                           src_dfr ? (dfr_w ? dfr_d[15:8] : dfr_d[7:0]) :
                                     (pn_word ? pn_d[15:8] : pn_d[7:0]);
    wire push_we   = push_go && !txlvl[10];
    wire tx_over   = push_go && txlvl[10];      // a byte pushed into a full TX: dropped
    wire rollback;                              // GAYLE_TO_TX ends abnormally (below)

    always @(posedge clk) begin
        if (reset || rollback) begin
            pend_v <= 1'b0; dfr_v <= 1'b0;
        end else begin
            if (pend_v)
                pend_v <= 1'b0;
            else if ((src_dfr | src_new) && push_word) begin
                pend_v <= 1'b1;
                pend_b <= src_dfr ? dfr_d[7:0] : pn_d[7:0];
            end
            if (push_new && (pend_v || dfr_v)) begin
                dfr_v <= 1'b1; dfr_w <= pn_word; dfr_d <= pn_d;
            end else if (src_dfr)
                dfr_v <= 1'b0;
        end
    end

    // ------------------------------------------------------------ RX prefetch (port A)
    reg  [7:0] h0, h1;                  // RX head bytes for the CPU pops and g_wdata
    reg  [1:0] hc;                      // how many of them are valid
    reg        rf_v;                    // a read of RX is in flight (a_dout next cycle)
    wire [1:0] cpu_want = cpu_lock ? 2'd0 : r_rxw ? 2'd2 : r_rxb ? 2'd1 : 2'd0;
    wire [1:0] pop_want = g_pop ? 2'd2 : cpu_want;
    wire [1:0] npop = (pop_want > hc) ? hc : pop_want;
    wire       rx_short = pop_want > hc;           // a pop finds fewer bytes than it asks for
    wire       lock_evt = cpu_lock && (w_txw | w_txb | r_rxw | r_rxb);
    wire       misuse_evt = tx_over | rx_short | lock_evt;   // STATUS 8 + IRQ bit 3
    // room after this cycle's pop and arrival: hc - npop + rf_v < 2.  One
    // read per cycle (latency 1), so h0/h1 are full again 2 cycles after a
    // 2-byte pop (invariant hc + rf_v <= 2)
    wire [1:0] hc_post = hc - npop;
    wire rf_issue = (rf_v ? hc_post == 2'd0 : hc_post != 2'd2)
                    && rx_wr != rx_rd && !push_we && !rx_flush;

    assign a_we   = push_we;
    assign a_addr = push_we ? {1'b1, tx_wr[9:0]} : {1'b0, rx_rd[9:0]};
    assign a_din  = push_byte;

    reg  [7:0] h0_n, h1_n;
    reg  [1:0] hc_n;
    always @* begin
        h0_n = h0; h1_n = h1; hc_n = hc;
        if (npop == 2'd1) begin h0_n = h1; hc_n = hc - 2'd1; end
        else if (npop == 2'd2) hc_n = 2'd0;
        if (rf_v) begin
            if (hc_n == 2'd0) h0_n = a_dout; else h1_n = a_dout;
            hc_n = hc_n + 2'd1;
        end
    end

    // ------------------------------------------------------------ shifter (port B)
    reg        run;                     // a byte is being shifted
    reg        sck_r, mosi_r;
    reg  [7:0] hcnt;                    // half-period counter
    reg  [2:0] bitn;
    reg  [6:0] txsh;                    // TX byte bits 6:0 (bit 7 goes straight to MOSI)
    reg  [7:0] rxsh;
    reg  [7:0] txn;                     // next TX byte (prefetched from the RAM)
    reg        txn_v, tf_v;             // txn valid / its read in flight
    reg        cd_s1, cd_s2;            // card detect, synchronised (1: no card)

    wire [10:0] cnt_inc   = cnt + 11'd1;
    wire        op_crc    = op_ctx | op_crx;
    wire        tick      = run && hcnt == 8'd0;
    wire        byte_done = tick && sck_r && bitn == 3'd7;
    wire        data_last = cnt_inc == len_r;
    // at byte_done: the next byte is a CRC byte
    wire        crc_next  = op_crc && (cph != 2'd0 || data_last);
    wire        wait_hit  = (rxsh == match_r) ^ op_ne;
    wire        nat_end   = byte_done && (op_wait ? wait_hit : op_crc ? cph == 2'd2 : data_last);
    wire        stop_req  = abort_pend | tmo_pend;
    wire        stop_bd   = byte_done && !nat_end && stop_req;      // abort / timeout at a byte boundary
    wire        stop_idle = busy && !run && abort_pend;             // abort with no byte being shifted
    wire        gone_now  = busy && cd_s2;                          // card gone: at once
    wire        tx_ok     = !op_tx || txn_v;
    // at a byte boundary the byte being finished takes one more RX place
    wire        next_ok   = crc_next || (tx_ok && (!op_rx || rxlvl < 11'd1023));
    wire        start_ok  = busy && !g_req_r && !run && !abort_pend && tx_ok && (!op_rx || !rxlvl[10]);
    wire        load      = !gone_now && (start_ok || (byte_done && !nat_end && !stop_req && next_ok));
    wire        load_crc  = load && byte_done && crc_next;
    wire        tx_take   = load && op_tx && !load_crc;
    wire  [7:0] tx_byte   = op_tx ? txn : 8'hFF;       // a data byte to send
    wire  [7:0] load_byte = load_crc ? (op_ctx ? crc[15:8] : 8'hFF) : tx_byte;
    wire        rx_commit = byte_done && op_rx && cph == 2'd0;
    wire        tf_issue  = !txn_v && !tf_v && tx_wr != tx_rd && !b_we && !tx_flush && !tx_rewind && !cpu_lock;

    // CRC16: TX data bytes as they are loaded, RX bytes (CRC bytes too) as they end
    wire  [7:0] crc_in    = op_ctx ? tx_byte : rxsh;
    wire [15:0] crc_nx    = crc16_byte(crc, crc_in);
`ifdef SDC_MUT_NOCRC
    wire        crc_good  = 1'b1;
`else
    wire        crc_good  = crc_nx == 16'h0000;   // at the last RX CRC byte: data + CRC = 0
`endif

    // op end and its reason
    wire op_fin   = busy && (gone_now || nat_end || stop_bd || stop_idle || g_end);
    wire e_gerr   = !gone_now && g_end && !g_good;
    wire e_abort  = !gone_now && !g_end && abort_pend && (stop_bd || stop_idle);
    wire e_tmo    = !gone_now && stop_bd && !abort_pend;
    wire e_crcok  = !gone_now && nat_end && op_crx && crc_good;
    wire e_crcbad = !gone_now && nat_end && op_crx && !crc_good;
    wire op_err   = gone_now | e_gerr | e_tmo;
    assign rollback = op_fin && g_req_r && !g_dir_r && !(g_end && g_good && !gone_now);

    assign b_we   = rx_commit;
    assign b_addr = b_we ? {1'b0, rx_wr[9:0]} : {1'b1, tx_rd[9:0]};
    assign b_din  = rxsh;

    always @(posedge clk) begin
        if (reset) begin
            run <= 1'b0; sck_r <= 1'b0; mosi_r <= 1'b1; hcnt <= 8'd0; bitn <= 3'd0;
        end else if (gone_now) begin            // card gone: stop at once, lines idle
            run <= 1'b0; sck_r <= 1'b0; mosi_r <= 1'b1;
        end else if (load) begin
            run <= 1'b1; sck_r <= 1'b0; bitn <= 3'd0; hcnt <= cfg_div;
            txsh <= load_byte[6:0]; mosi_r <= load_byte[7];
        end else if (tick) begin
            hcnt <= cfg_div;
            if (!sck_r) begin
                sck_r <= 1'b1;
                rxsh <= {rxsh[6:0], sd_miso};
            end else begin
                sck_r <= 1'b0;
                if (bitn != 3'd7) begin
                    bitn <= bitn + 3'd1;
                    mosi_r <= txsh[6];
                    txsh <= {txsh[5:0], 1'b1};
                end else begin          // byte done, no next byte now: pause or end
                    run <= 1'b0;
                    mosi_r <= 1'b1;
                end
            end
        end else if (run)
            hcnt <= hcnt - 8'd1;
    end

    // ------------------------------------------------------------ FIFO state
    wire [10:0] tx_wr_n = rollback ? tx_wr0 : tx_wr + {10'd0, push_we};
    wire [10:0] rxlvl_n = rxlvl + {10'd0, rx_commit} - {9'd0, npop};
    wire [11:0] ver_sub = {1'b0, verified} - {10'd0, npop};
    always @(posedge clk) begin
        if (reset) begin
            tx_wr <= 11'd0; tx_rd <= 11'd0; tx_cm <= 11'd0; rx_wr <= 11'd0; rx_rd <= 11'd0;
            rxlvl <= 11'd0;
            txn_v <= 1'b0; tf_v <= 1'b0; hc <= 2'd0; rf_v <= 1'b0;
            h0 <= 8'h00; h1 <= 8'h00;
            verified <= 11'd0; poisoned <= 1'b0;
        end else begin
            // TX
            tx_wr <= tx_wr_n;
            if (go && cmd_op == OP_G2TX) tx_wr0 <= tx_wr_n;
            if (tx_flush) begin
                tx_rd <= tx_wr; tx_cm <= tx_wr;
                txn_v <= 1'b0; tf_v <= 1'b0;
            end else if (tx_rewind) begin
                tx_rd <= tx_cm;
                txn_v <= 1'b0; tf_v <= 1'b0;
            end else begin
                if (tx_commit) tx_cm <= tx_rd - {10'd0, txn_v | tf_v};   // the next unsent byte
                tx_rd <= tx_rd + {10'd0, tf_issue};
                tf_v  <= tf_issue;
                if (tf_v) begin txn <= b_dout; txn_v <= 1'b1; end
                else if (tx_take) txn_v <= 1'b0;
            end
            // RX
            rx_wr <= rx_wr + {10'd0, rx_commit};
            if (rx_flush) begin
                rx_rd <= rx_wr;
                hc <= 2'd0; rf_v <= 1'b0;
                rxlvl <= 11'd0;
                verified <= 11'd0; poisoned <= 1'b0;
            end else begin
                rx_rd <= rx_rd + {10'd0, rf_issue};
                rf_v  <= rf_issue;
                h0 <= h0_n; h1 <= h1_n; hc <= hc_n;
                rxlvl <= rxlvl_n;
                if (e_crcok && op_rx && ahead_ok) verified <= rxlvl_n;   // all of RX now verified
                else verified <= ver_sub[11] ? 11'd0 : ver_sub[10:0];
                if (e_crcbad && op_rx) poisoned <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------ op state
    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0; op_tx <= 1'b0; op_rx <= 1'b0; op_ctx <= 1'b0; op_crx <= 1'b0;
            op_wait <= 1'b0; op_ne <= 1'b0; g_req_r <= 1'b0; g_dir_r <= 1'b0; g_port_r <= 1'b0;
            cph <= 2'd0; ahead_ok <= 1'b0; abort_pend <= 1'b0; tmo_pend <= 1'b0;
            cnt <= 11'd0; last_r <= 8'd0;
            st_crc_ok <= 1'b0; st_timeout <= 1'b0; st_aborted <= 1'b0;
            st_gone <= 1'b0; st_refused <= 1'b0; st_gerr <= 1'b0; st_misuse <= 1'b0;
        end else begin
            if (go) busy <= 1'b1;
            else if (op_fin) busy <= 1'b0;
            if (cmd_accept) begin
                op_tx  <= is_xfer && reg_d[4]; op_rx  <= is_xfer && reg_d[5];
                op_ctx <= is_xfer && reg_d[6]; op_crx <= is_xfer && reg_d[7];
                op_wait <= is_wait; op_ne <= cmd_op[0];
                g_dir_r <= cmd_op[0]; g_port_r <= reg_d[8];
                ahead_ok <= !poisoned && rxlvl == verified;
            end
            if (go && is_gayle) g_req_r <= 1'b1;
            else if (op_fin) g_req_r <= 1'b0;
            if (cmd_accept) cph <= 2'd0;
            else if (load_crc) cph <= cph + 2'd1;
            if (!busy || op_fin) abort_pend <= 1'b0;
            else if (w_abort) abort_pend <= 1'b1;
            if (cmd_accept) cnt <= 11'd0;
            else if (byte_done) cnt <= cnt_inc;
            else if (g_word) cnt <= cnt + 11'd2;
            if (byte_done) last_r <= rxsh;
            if (cmd_accept) begin
                st_crc_ok <= 1'b0; st_timeout <= 1'b0; st_aborted <= 1'b0;
                st_gone <= 1'b0; st_refused <= 1'b0; st_gerr <= 1'b0;
            end else begin
                if (refuse_evt) st_refused <= 1'b1;
                if (op_fin) begin
                    st_gone <= gone_now; st_gerr <= e_gerr; st_aborted <= e_abort;
                    st_timeout <= e_tmo; st_crc_ok <= e_crcok;
                end
            end
            if (cmd_accept) st_misuse <= 1'b0;
            if (misuse_evt) st_misuse <= 1'b1;   // after the clear: an event wins
            // wait timeout: TIMEOUT units of 16384 clocks from the op's start (0 = 1)
            // (units counted up and compared with TIMEOUT, which is fixed while busy)
            if (cmd_accept) begin
                tmo_pre <= 14'd0; tmo_u <= 16'd0; tmo_pend <= 1'b0;
            end else if (busy && op_wait && !tmo_pend) begin
                tmo_pre <= tmo_pre + 14'd1;
                if (&tmo_pre) begin
                    tmo_u <= tmo_u_inc;
`ifndef SDC_MUT_NOTIMEOUT
                    if (tmo_u_inc == {timeout_r[15:1], timeout_r[0] | ~|timeout_r}) tmo_pend <= 1'b1;
`endif
                end
            end
        end
    end

    // CRC16 accumulator
    always @(posedge clk) begin
        if (cmd_accept) crc <= 16'h0000;
        else if (load_crc && op_ctx) crc <= {crc[7:0], 8'h00};      // CRC bytes out, high first
        else if ((load && !load_crc && op_ctx) || (byte_done && op_crx)) crc <= crc_nx;
    end

    // ------------------------------------------------------------ card detect
    reg cd_n_stable;
    reg [CD_DEBOUNCE_LOG2-1:0] cd_cnt;
    reg cd_evt;
    always @(posedge clk) begin
        cd_s1 <= sd_cd_n;
        cd_s2 <= cd_s1;
        cd_evt <= 1'b0;
        if (reset) begin
            cd_n_stable <= cd_s2;
            cd_cnt <= {CD_DEBOUNCE_LOG2{1'b0}};
        end else if (cd_s2 == cd_n_stable)
            cd_cnt <= {CD_DEBOUNCE_LOG2{1'b0}};
        else if (&cd_cnt) begin
            cd_n_stable <= cd_s2;
            cd_cnt <= {CD_DEBOUNCE_LOG2{1'b0}};
            cd_evt <= 1'b1;
        end else
            cd_cnt <= cd_cnt + 1'b1;
    end
    wire cd_present = !cd_n_stable;

    // ------------------------------------------------------------ interrupts
    wire       done_evt = op_fin || (cmd_accept && !go) || (w_abort && !busy);
    wire       err_evt  = refuse_evt || misuse_evt || (op_fin && op_err);
    wire       rx_high  = {1'b0, rxlvl[10:4]} >= wm_rx;
    wire       tx_low   = {1'b0, txlvl} <= {wm_tx, 4'h0};
    wire [4:0] irq_set  = {cd_evt, err_evt, tx_low, rx_high, done_evt};
    always @(posedge clk) begin
        if (reset) begin
            irq_pend <= 5'd0; irq_r <= 1'b0;
        end else begin
            irq_pend <= (irq_pend & ~(w_ack ? reg_d[4:0] : 5'd0)) | irq_set;
            irq_r <= |(irq_pend & irq_en);
        end
    end

    // ------------------------------------------------------------ register writes
    always @(posedge clk) begin
        if (reset) begin
            cfg_div <= 8'hFF; cs_n_r <= 1'b1; timeout_r <= 16'd0; irq_en <= 5'd0;
            wm_rx <= 8'd0; wm_tx <= 8'd0; len_r <= 11'd0; match_r <= 8'd0;
        end else if (reg_wstb) begin
            case (ra)
                4'd5:  if (!busy) len_r <= reg_d[10:0];
                4'd6:  if (!busy) match_r <= reg_d[7:0];
                4'd8:  if (!busy) begin cs_n_r <= ~reg_d[8]; cfg_div <= reg_d[7:0]; end
                4'd9:  if (!busy) timeout_r <= reg_d;
                4'd10: irq_en <= reg_d[4:0];
                4'd11: begin wm_rx <= reg_d[15:8]; wm_tx <= reg_d[7:0]; end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------ register reads
    wire [1:0] hv = cpu_lock ? 2'd0 : hc;   // locked: pops read 0000
    always @(posedge clk) begin
        if (reset)
            rdq <= 16'd0;
        else if (reg_rstb) begin
            case (ra)
                4'd0:  rdq <= {(hv != 2'd0) ? h0 : 8'h00, hv[1] ? h1 : 8'h00};
                4'd1:  rdq <= {8'h00, (hv != 2'd0) ? h0 : 8'h00};
                4'd2:  rdq <= {5'd0, rxlvl};
                4'd3:  rdq <= {5'd0, txlvl};
                4'd4:  rdq <= {7'd0, st_misuse, st_gerr, st_refused, st_gone, st_aborted,
                               cd_present, st_timeout, st_crc_ok, busy};
                4'd5:  rdq <= {8'h00, last_r};
                4'd6:  rdq <= {5'd0, cnt};
                4'd7:  rdq <= {11'd0, irq_pend};
                4'd8:  rdq <= {7'd0, ~cs_n_r, cfg_div};
                4'd9:  rdq <= timeout_r;
                4'd10: rdq <= {11'd0, irq_en};
                4'd11: rdq <= VERSION;
                default: rdq <= 16'd0;
            endcase
        end
    end

    // ------------------------------------------------------------ outputs
    assign reg_q   = rdq;
    assign irq     = irq_r;
    assign sd_sck  = sck_r;
    assign sd_cs_n = cs_n_r;
    assign sd_mosi = mosi_r;
    assign g_req   = g_req_r;
    assign g_dir   = g_dir_r;
    assign g_port  = g_port_r;
    assign g_words = len_r[10:1];
    assign g_wdata = {h0, h1};

endmodule
