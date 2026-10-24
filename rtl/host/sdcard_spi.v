// sdcard_spi -- SD card SPI peripheral of the OSD CPU (clk = clk_114).
//
// Protocol-agnostic SPI master for the SD card (the card stays in SPI mode):
// TX and RX FIFOs with watermark interrupts, a byte shifter and a register
// window.  The firmware runs the SD protocol on it.  Design:
// findings/sdcard-engine/design.md section 4; plan Task 5.  Bench:
// sim/sdcard_spi (run.sh).  Plain Verilog-2005, no vendor primitives.
//
// Register map (16 bit; reg_addr = byte address bits 5:2 of 0xFFFFFF00..2C)
//   idx addr  write                            read
//    0  00    TXW  push 2 bytes (15:8 first)   RXW  pop 2 bytes (first in 15:8)
//    1  04    TXB  push 1 byte (7:0)           RXB  pop 1 byte (7:0; 15:8 = 0)
//    2  08    -                                RXLVL bytes in RX (10:0)
//    3  0C    -                                TXLVL bytes in TX (10:0)
//    4  10    CMD  start an op                 STATUS
//    5  14    LEN  byte count (10:0)           LAST  last received byte (7:0)
//    6  18    MATCH byte for wait ops (7:0)    COUNT bytes moved by the last op (10:0)
//    7  1C    IRQACK write 1 to clear          IRQPEND
//    8  20    CFG  7:0 divider, 8 CS asserted  CFG
//    9  24    TIMEOUT (units of 16384 clk)     TIMEOUT
//   10  28    IRQEN                            IRQEN
//   11  2C    WMARK 15:8 RX high, 7:0 TX low   VERSION
//             (units of 16 bytes)
//   12-15     ignored                          0
//   LEN and MATCH writes are ignored while an op is busy.
//
// CMD: 3:0 op -- 1 XFER, 8 RX_FLUSH, 9 TX_FLUSH in this core (Task 6 adds
//   2 WAIT_EQ, 3 WAIT_NE, 6 TX_REWIND, 7 TX_COMMIT, 15 ABORT; Task 7 adds
//   4 GAYLE_TO_TX, 5 RX_TO_GAYLE).  Bit 4: TX from the FIFO (else $FF);
//   bit 5: RX into the FIFO (else discarded); bits 6 / 7 (CRC16 append /
//   check, Task 6) and bit 8 (Gayle port, Task 7).
//   Accepted (STATUS 7:1 cleared, COUNT 0): XFER, RX_FLUSH, TX_FLUSH while
//   not busy and with bits 7:6 = 0.  Everything else is REFUSED: STATUS bit
//   6 and IRQ bit 3 (error) set, nothing else changes (a running op goes
//   on; no op-done IRQ).  Task 6/7 extend cmd_known / cmd_bits_ok below.
//   XFER LEN 0 and the flushes complete at once (IRQ bit 0).  The flushes
//   empty the FIFO, including its prefetch registers.
// STATUS: 0 busy, 1 crc_ok, 2 timeout, 3 card present, 4 aborted, 5 card
//   gone during the op, 6 refused, 7 Gayle error (1, 2, 4, 5, 7: always 0
//   in this core; their registers are cleared by every accepted op).
// IRQPEND / IRQEN / IRQACK: 0 op done, 1 RX >= high watermark, 2 TX <= low
//   watermark, 3 error, 4 card-detect change.  irq = |(IRQPEND & IRQEN),
//   registered.  Bits 1 and 2 are set every cycle their condition holds
//   (an IRQACK only clears them once the level has moved past the mark);
//   the others are events.  RX high mark 0 is always true.
//
// Register timing contract (Task 8, cfide):
//   - reg_wstb / reg_rstb: one clk cycle, the first cycle of an access;
//     reg_addr / reg_d are sampled in that cycle only.
//   - reg_q is a register (rdq), loaded at the end of the strobe cycle with
//     the value the register had in that cycle: valid from the cycle after
//     the strobe until the next read strobe.  A pop (RXW / RXB) returns the
//     bytes before the pop; the pop itself takes effect at the same edge.
//   - Pops come from two prefetch registers (h0, h1) that refill from the
//     RAM by themselves (one byte per 2 cycles).  A byte counted in RXLVL is
//     poppable at most 3 cycles later (5 if a TXW is being written): with
//     cfide's accesses at least 4 cycles apart, a pop after an RXLVL read
//     or an op-done IRQ always finds its bytes.  A pop finding fewer bytes
//     prefetched than it asks for returns 00 for the missing ones and pops
//     only what it returned (on an empty RX: 0000, nothing popped).
//   - TXW writes its first byte in the strobe cycle and the second one in
//     the next.  Push strobes are assumed >= 2 cycles apart (cfide: >= 4);
//     guard: a push strobe in the cycle of a pending second byte is latched
//     (dfr_*) and written after it.  A push into a full TX is dropped
//     (TXLVL stays 1024).
//
// FIFOs: one inferred 2048 x 8 RAM, RX at 0-1023, TX at 1024-2047; true
// dual port, one clock, registered read, no reset (one RAMB18 on Xilinx,
// M9K/M10K pairs on Intel).
//   port A: CPU side -- TX pushes (write), RX prefetch (read); Task 7's
//           Gayle DMA belongs here too (TX writes, RX reads through the
//           prefetch registers like the CPU pops)
//   port B: shifter -- TX next-byte prefetch (read, txn), RX byte (write)
// Each side holds 1024 bytes including its prefetch registers.  TX bytes
// are freed as they are sent (Task 6 adds keep / rewind / commit).
//
// Shifter: SPI mode 0, MSB first, SCK idles low; SCK = clk / (2 * (div + 1)),
// a register (generated clock in Task 8's XDC).  MISO is sampled at the clk
// edge that raises SCK, MOSI changes with SCK falling.  Bytes follow each
// other without a gap; SCK stays low (pause) while TX is empty for a
// TX-sourced op or RX is full for an RX-sinking op.  MOSI idles high.
// CS: CFG bit 8 = 1 drives sd_cs_n low (a register).
//
// Card detect: sd_cd_n (low = inserted) through 2 flops, debounced: a new
// level counts after 2^CD_DEBOUNCE_LOG2 clocks (20: 9.2 ms); its change
// sets IRQ bit 4.  Reset loads the synchronised level (reset must last >= 3
// clocks), so a card present at reset gives no change IRQ.
//
// Gayle ports (g_*): Task 7.  Outputs tied to idle here.
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

    localparam [3:0] OP_XFER = 4'd1, OP_RX_FLUSH = 4'd8, OP_TX_FLUSH = 4'd9;

    // ------------------------------------------------------------ registers
    reg  [7:0] cfg_div;
    reg        cs_n_r;
    reg [15:0] timeout_r;               // Task 6
    reg  [4:0] irq_en, irq_pend;
    reg        irq_r;
    reg  [7:0] wm_rx, wm_tx;
    reg [10:0] len_r;
    reg  [7:0] match_r;                 // Task 6
    reg  [7:0] last_r;
    reg [10:0] cnt;                     // COUNT
    reg        busy;
    reg        st_crc_ok, st_timeout, st_aborted, st_gone, st_refused, st_gerr;
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
        a_dout <= ram[a_addr];
    end
    always @(posedge clk) begin
        if (b_we) ram[b_addr] <= b_din;
        b_dout <= ram[b_addr];
    end

    // FIFO pointers (11 bits: 10 address + wrap) and levels (0..1024)
    reg [10:0] tx_wr, tx_rd, rx_wr, rx_rd;
    reg [10:0] txlvl, rxlvl;

    // ------------------------------------------------------------ op decode
    wire [3:0] cmd_op      = reg_d[3:0];
    wire       cmd_known   = cmd_op == OP_XFER || cmd_op == OP_RX_FLUSH || cmd_op == OP_TX_FLUSH;
    wire       cmd_bits_ok = reg_d[7:6] == 2'b00;      // CRC16 bits: Task 6
    wire       cmd_accept  = w_cmd && !busy && cmd_known && cmd_bits_ok;
    wire       cmd_refuse  = w_cmd && !cmd_accept;
    wire       rx_flush    = cmd_accept && cmd_op == OP_RX_FLUSH;
    wire       tx_flush    = cmd_accept && cmd_op == OP_TX_FLUSH;
    wire       xfer_go     = cmd_accept && cmd_op == OP_XFER && len_r != 11'd0;

    // ------------------------------------------------------------ TX push (port A)
    reg        pend_v;                  // second byte of a TXW still to write
    reg  [7:0] pend_b;
    reg        dfr_v, dfr_w;            // guard: a push strobe that met pend_v
    reg [15:0] dfr_d;
    wire push_new  = w_txw | w_txb;
    wire src_dfr   = !pend_v && dfr_v;
    wire src_new   = !pend_v && !dfr_v && push_new;
    wire push_go   = pend_v | src_dfr | src_new;
    wire push_word = src_dfr ? dfr_w : w_txw;
    wire [7:0] push_byte = pend_v  ? pend_b :
                           src_dfr ? (dfr_w ? dfr_d[15:8] : dfr_d[7:0]) :
                                     (w_txw ? reg_d[15:8] : reg_d[7:0]);
    wire push_we   = push_go && !txlvl[10];

    always @(posedge clk) begin
        if (reset) begin
            pend_v <= 1'b0; dfr_v <= 1'b0;
        end else begin
            if (pend_v)
                pend_v <= 1'b0;
            else if ((src_dfr | src_new) && push_word) begin
                pend_v <= 1'b1;
                pend_b <= src_dfr ? dfr_d[7:0] : reg_d[7:0];
            end
            if (push_new && (pend_v || dfr_v)) begin
                dfr_v <= 1'b1; dfr_w <= w_txw; dfr_d <= reg_d;
            end else if (src_dfr)
                dfr_v <= 1'b0;
        end
    end

    // ------------------------------------------------------------ RX prefetch (port A)
    reg  [7:0] h0, h1;                  // RX head bytes for the CPU pops
    reg  [1:0] hc;                      // how many of them are valid
    reg        rf_v;                    // a read of RX is in flight (a_dout next cycle)
    wire rf_issue = !rf_v && hc != 2'd2 && rx_wr != rx_rd && !push_we && !rx_flush;
    wire [1:0] pop_want = r_rxw ? 2'd2 : r_rxb ? 2'd1 : 2'd0;
    wire [1:0] npop = (pop_want > hc) ? hc : pop_want;

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
    reg        op_tx, op_rx;            // CMD bits 4, 5 of the running XFER
    reg  [7:0] hcnt;                    // half-period counter
    reg  [2:0] bitn;
    reg  [6:0] txsh;                    // TX byte bits 6:0 (bit 7 goes straight to MOSI)
    reg  [7:0] rxsh;
    reg  [7:0] txn;                     // next TX byte (prefetched from the RAM)
    reg        txn_v, tf_v;             // txn valid / its read in flight

    wire [10:0] cnt_inc   = cnt + 11'd1;
    wire        tick      = run && hcnt == 8'd0;
    wire        byte_done = tick && sck_r && bitn == 3'd7;
    wire        last_byte = cnt_inc == len_r;
    wire        tx_ok     = !op_tx || txn_v;
    // at a byte boundary the byte being finished takes one more RX place
    wire        next_ok   = tx_ok && (!op_rx || rxlvl < 11'd1023);
    wire        start_ok  = busy && !run && tx_ok && (!op_rx || !rxlvl[10]);
    wire        load      = start_ok || (byte_done && !last_byte && next_ok);
    wire        tx_take   = load && op_tx;
    wire  [7:0] load_byte = op_tx ? txn : 8'hFF;
    wire        rx_commit = byte_done && op_rx;
    wire        op_end    = byte_done && last_byte;
    wire        tf_issue  = !txn_v && !tf_v && tx_wr != tx_rd && !b_we && !tx_flush;

    assign b_we   = rx_commit;
    assign b_addr = b_we ? {1'b0, rx_wr[9:0]} : {1'b1, tx_rd[9:0]};
    assign b_din  = rxsh;

    always @(posedge clk) begin
        if (reset) begin
            run <= 1'b0; sck_r <= 1'b0; mosi_r <= 1'b1; hcnt <= 8'd0; bitn <= 3'd0;
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
    always @(posedge clk) begin
        if (reset) begin
            tx_wr <= 11'd0; tx_rd <= 11'd0; rx_wr <= 11'd0; rx_rd <= 11'd0;
            txlvl <= 11'd0; rxlvl <= 11'd0;
            txn_v <= 1'b0; tf_v <= 1'b0; hc <= 2'd0; rf_v <= 1'b0;
        end else begin
            // TX
            tx_wr <= tx_wr + {10'd0, push_we};
            if (tx_flush) begin
                tx_rd <= tx_wr;
                txn_v <= 1'b0; tf_v <= 1'b0;
                txlvl <= {10'd0, push_we};
            end else begin
                tx_rd <= tx_rd + {10'd0, tf_issue};
                tf_v  <= tf_issue;
                if (tf_v) begin txn <= b_dout; txn_v <= 1'b1; end
                else if (tx_take) txn_v <= 1'b0;
                txlvl <= txlvl + {10'd0, push_we} - {10'd0, tx_take};
            end
            // RX
            rx_wr <= rx_wr + {10'd0, rx_commit};
            if (rx_flush) begin
                rx_rd <= rx_wr;
                hc <= 2'd0; rf_v <= 1'b0;
                rxlvl <= 11'd0;
            end else begin
                rx_rd <= rx_rd + {10'd0, rf_issue};
                rf_v  <= rf_issue;
                h0 <= h0_n; h1 <= h1_n; hc <= hc_n;
                rxlvl <= rxlvl + {10'd0, rx_commit} - {9'd0, npop};
            end
        end
    end

    // ------------------------------------------------------------ op state
    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0; op_tx <= 1'b0; op_rx <= 1'b0; cnt <= 11'd0; last_r <= 8'd0;
            st_crc_ok <= 1'b0; st_timeout <= 1'b0; st_aborted <= 1'b0;
            st_gone <= 1'b0; st_refused <= 1'b0; st_gerr <= 1'b0;
        end else begin
            if (xfer_go) begin
                busy <= 1'b1; op_tx <= reg_d[4]; op_rx <= reg_d[5];
            end else if (op_end)
                busy <= 1'b0;
            if (cmd_accept) cnt <= 11'd0;
            else if (byte_done) cnt <= cnt_inc;
            if (byte_done) last_r <= rxsh;
            if (cmd_accept) begin
                st_crc_ok <= 1'b0; st_timeout <= 1'b0; st_aborted <= 1'b0;
                st_gone <= 1'b0; st_refused <= 1'b0; st_gerr <= 1'b0;
            end else if (cmd_refuse)
                st_refused <= 1'b1;
        end
    end

    // ------------------------------------------------------------ card detect
    reg cd_s1, cd_s2, cd_n_stable;
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
    wire       done_evt = op_end || (cmd_accept && !xfer_go);
    wire       rx_high  = {1'b0, rxlvl[10:4]} >= wm_rx;
    wire       tx_low   = {1'b0, txlvl} <= {wm_tx, 4'h0};
    wire [4:0] irq_set  = {cd_evt, cmd_refuse, tx_low, rx_high, done_evt};
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
                4'd8:  begin cs_n_r <= ~reg_d[8]; cfg_div <= reg_d[7:0]; end
                4'd9:  timeout_r <= reg_d;
                4'd10: irq_en <= reg_d[4:0];
                4'd11: begin wm_rx <= reg_d[15:8]; wm_tx <= reg_d[7:0]; end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------ register reads
    always @(posedge clk) begin
        if (reset)
            rdq <= 16'd0;
        else if (reg_rstb) begin
            case (ra)
                4'd0:  rdq <= {(hc != 2'd0) ? h0 : 8'h00, hc[1] ? h1 : 8'h00};
                4'd1:  rdq <= {8'h00, (hc != 2'd0) ? h0 : 8'h00};
                4'd2:  rdq <= {5'd0, rxlvl};
                4'd3:  rdq <= {5'd0, txlvl};
                4'd4:  rdq <= {8'h00, st_gerr, st_refused, st_gone, st_aborted,
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

    // Gayle DMA: Task 7
    assign g_req   = 1'b0;
    assign g_dir   = 1'b0;
    assign g_port  = 1'b0;
    assign g_words = 10'd0;
    assign g_wdata = 16'd0;

endmodule
