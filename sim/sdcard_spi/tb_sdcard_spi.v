`timescale 1ns/1ps
// Unit bench of rtl/host/sdcard_spi.v (the SD card SPI peripheral) with the
// card model sim/common/sd_spi_model.v.  The Task 5 cases run with the
// model's CRC checking off (as at its start); the Task 6 cases (t_refuse ..
// t_cardgone_midblock) turn it on with CMD59 and off again with CMD0, and
// poke the model's error-injection and busy knobs hierarchically.  A
// behavioural Gayle bridge (the g_* responder below) answers the Gayle ops.
// Run by sim/sdcard_spi/run.sh (Verilator leg + iverilog X-check leg +
// mutant legs).
//
// The bench is the CPU side of cfide (Task 8 contract, see the header of
// sdcard_spi.v): a register access lasts ACC clk_114 cycles with reg_addr /
// reg_d stable, reg_wstb / reg_rstb high in its first cycle only; a read
// samples reg_q in the cycle after the strobe and checks it stays the same
// for the rest of the access.  GAP idle cycles between accesses.
//
// Plusargs: +SD_IMG=<file>  the card image (also loaded by the bench as the
//                           expected read data); run.sh makes it
//           +TEST=<name>    run only this case (default: all, in order)
//           +XCHECK=1       no X / Z on reg_q, irq and the pins after reset
//                           (meaningful in a 4-state simulator: iverilog)
//           +SD_LOG=1       the card model's command log
//
// Every case prints "PASS <case>" or "FAIL <case>: ..." lines; the last line
// is "=== PASS tb_sdcard_spi" or "=== FAIL tb_sdcard_spi (<n> errors)".  A
// watchdog ends a hung run with "=== FAIL".
module tb_sdcard_spi;

    localparam IMG_SECTORS = 1024;
    localparam IMG_BYTES   = IMG_SECTORS * 512;
    // access shape: strobes are ACC + GAP + 1 cycles apart (default 9;
    // t_min_spacing: 3 + 0 + 1 = 4, the minimum sdcard_spi.v is built for)
    integer ACC = 4;                    // cycles per register access (clk_28 ack: >= 4)
    integer GAP = 4;                    // idle cycles between accesses
    // watchdog: a passing run takes ~1 M cycles; a mutant run that has lost its
    // state times out in every later case (mut_nointerlock: ~7.1 M)
    localparam integer WATCHDOG_CYC = 12000000;

    // register offsets (byte address - 0xFFFFFF00)
    localparam [5:0] R_DATAW = 6'h00, R_DATAB = 6'h04, R_RXLVL = 6'h08, R_TXLVL = 6'h0C,
                     R_CMD = 6'h10, R_LEN = 6'h14, R_MATCH = 6'h18, R_IRQ = 6'h1C,
                     R_CFG = 6'h20, R_TIMEOUT = 6'h24, R_IRQEN = 6'h28, R_WMARK = 6'h2C;
    localparam [15:0] OP_XFER = 16'h1, OP_WEQ = 16'h2, OP_WNE = 16'h3, OP_G2TX = 16'h4,
                      OP_RX2G = 16'h5, OP_TXRW = 16'h6, OP_TXCM = 16'h7, OP_RXFL = 16'h8,
                      OP_TXFL = 16'h9, OP_ABORT = 16'hF,
                      C_TX = 16'h10, C_RX = 16'h20, C_CRCTX = 16'h40, C_CRCRX = 16'h80,
                      C_GPORT = 16'h100;

    reg clk = 1'b0;
    always #4.386 clk = ~clk;           // 114 MHz
    reg reset = 1'b1;

    reg        reg_wstb = 1'b0, reg_rstb = 1'b0;
    reg  [5:2] reg_addr = 4'd0;
    reg [15:0] reg_d = 16'd0;
    wire [15:0] reg_q;
    wire irq, sd_sck, sd_cs_n, sd_mosi, sd_miso;
    reg  sd_cd_n = 1'b0;                // card inserted
    wire g_req, g_dir, g_port;
    wire [9:0] g_words;
    wire [15:0] g_wdata;
    wire g_wvalid;
    reg  g_ack = 1'b0, g_err = 1'b0, g_wnext = 1'b0, g_rvalid = 1'b0;   // the Gayle responder
    reg [15:0] g_rdata = 16'h0000;

    sdcard_spi #(.VERSION(16'h5D01), .CD_DEBOUNCE_LOG2(6)) dut (
        .clk(clk), .reset(reset),
        .reg_wstb(reg_wstb), .reg_rstb(reg_rstb), .reg_addr(reg_addr),
        .reg_d(reg_d), .reg_q(reg_q), .irq(irq),
        .sd_sck(sd_sck), .sd_cs_n(sd_cs_n), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .sd_cd_n(sd_cd_n),
        .g_req(g_req), .g_dir(g_dir), .g_port(g_port), .g_words(g_words),
        .g_ack(g_ack), .g_err(g_err), .g_wdata(g_wdata), .g_wvalid(g_wvalid), .g_wnext(g_wnext),
        .g_rdata(g_rdata), .g_rvalid(g_rvalid));

    sd_spi_model #(.IMG_SECTORS(IMG_SECTORS)) card (
        .cs_n(sd_cs_n), .sck(sd_sck), .mosi(sd_mosi), .miso(sd_miso));

    // ---------------------------------------------------------------- state
    integer errors = 0;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg [7:0] img [0:IMG_BYTES-1];      // expected card contents
    reg [7:0] rxbuf [0:2047];           // bytes popped by a case
    reg [7:0] expb [0:2047];
    integer rise_t [0:127];             // SCK edge cycles (measure_sck)
    integer fall_t [0:127];
    reg [8*64-1:0] testsel;
    reg        all_tests, xcheck, irq_must_be_0;
    reg [8*32-1:0] cur;                 // current case name
    integer case_err0;

    task fail(input [8*120-1:0] msg);
        begin
            $display("FAIL %0s: %0s (cycle %0d)", cur, msg, cyc);
            errors = errors + 1;
        end
    endtask

    // ---------------------------------------------------------------- monitors
    // SCK rising edges (count, cycle of the last one) and the SPI mode 0 rules
    integer sck_rises = 0;
    reg  p_sck = 1'b0, p_mosi = 1'b1, p_cs = 1'b1;
    always @(posedge sd_sck) sck_rises = sck_rises + 1;
    always @(posedge clk) if (!reset) begin
        // MOSI changes only with SCK falling or while it is low: never at its
        // rising edge or while it is high (sd_sck high after this edge)
        if (sd_mosi !== p_mosi && sd_sck !== 1'b0) begin
            $display("FAIL mode0: MOSI changed with SCK high (cycle %0d)", cyc); errors = errors + 1;
        end
        // CS does not move while SCK is high
        if (sd_cs_n !== p_cs && sd_sck !== 1'b0) begin
            $display("FAIL mode0: CS changed with SCK high (cycle %0d)", cyc); errors = errors + 1;
        end
        if (irq_must_be_0 && irq !== 1'b0) begin
            $display("FAIL %0s: irq high while IRQEN = 0 (cycle %0d)", cur, cyc); errors = errors + 1;
        end
        if (xcheck && ^{reg_q, irq, sd_sck, sd_cs_n, sd_mosi, g_req, g_dir, g_port, g_words, g_wdata} === 1'bx) begin
            $display("FAIL xcheck: X/Z on reg_q %h irq %b sck %b cs_n %b mosi %b g %b%b%b %h %h (cycle %0d)",
                     reg_q, irq, sd_sck, sd_cs_n, sd_mosi, g_req, g_dir, g_port, g_words, g_wdata, cyc);
            errors = errors + 1;
        end
        p_sck <= sd_sck; p_mosi <= sd_mosi; p_cs <= sd_cs_n;
    end

    initial begin
        #(WATCHDOG_CYC * 8.772);
        $display("FAIL watchdog: no verdict after %0d cycles (case %0s)", WATCHDOG_CYC, cur);
        $display("=== FAIL tb_sdcard_spi (watchdog)");
        $finish;
    end

    // ---------------------------------------------------------------- Gayle responder
    // A behavioural stand-in for Task 7's bridge, to the clk_114-side contract
    // in the header of sdcard_spi.v.  When g_req rises it does g_words words,
    // one every gr_space cycles (the first gr_space - 1 cycles after it saw
    // g_req): dir 1 takes g_wdata in the cycle of its one-cycle g_wnext pulse
    // (into gr_buf), with gr_usevalid = 1 only in a cycle with g_wvalid high
    // (it waits for it; 0: blind, by spacing only); dir 0 pulses g_rvalid for
    // one cycle with g_rdata = gr_src[k] (garbage otherwise).  gr_extra more
    // pulses after the g_words words (beyond the count, blind), then g_ack
    // gr_space cycles after the last pulse.  gr_err_at = k: a g_err pulse
    // instead of word k; gr_ack_at = k: a g_ack instead of word k (too
    // early); gr_stall_at = k: no word k, no ack (the case ends the op).  It
    // stops when g_req drops.  gr_errpop_at = k (one shot, cleared when
    // used): word k is taken (g_wnext / g_rvalid) with a g_err in the same
    // cycle.  gr_ack_space > 0: the g_ack comes that many cycles after the
    // last pulse instead of gr_space (1: the cycle right after it).
    integer gr_space = 4, gr_err_at = -1, gr_stall_at = -1, gr_ack_at = -1;
    integer gr_usevalid = 1, gr_extra = 0, gr_errpop_at = -1, gr_ack_space = 0, gr_sp;
    integer gr_n = 0, gr_reqs = 0, gr_words = 0, gk, gdone;
    reg     gr_dir = 1'b0, gr_port = 1'b0;
    reg [15:0] gr_buf [0:1023];
    reg [15:0] gr_src [0:1023];
    initial begin : gayle_resp
        forever begin
            @(posedge clk); #1;
            if (g_req === 1'b1) begin
                gr_reqs = gr_reqs + 1;
                gr_dir = g_dir; gr_port = g_port; gr_words = g_words; gr_n = 0;
                gdone = 0;
                while (!gdone) begin
                    gr_sp = (gr_n == gr_words + gr_extra && gr_ack_space > 0) ? gr_ack_space : gr_space;
                    for (gk = 0; gk < gr_sp - 1 && g_req === 1'b1; gk = gk + 1) begin @(posedge clk); #1; end
                    if (gr_dir && gr_usevalid && gr_n < gr_words && gr_n != gr_err_at && gr_n != gr_stall_at
                        && gr_n != gr_ack_at) begin
                        gk = 0;
                        while (g_req === 1'b1 && g_wvalid !== 1'b1 && gk < 100000) begin @(posedge clk); #1; gk = gk + 1; end
                    end
                    if (g_req !== 1'b1) gdone = 1;
                    else if (gr_n == gr_err_at) begin
                        g_err = 1'b1; @(posedge clk); #1; g_err = 1'b0; gdone = 1;
                    end else if (gr_n == gr_stall_at) gdone = 1;
                    else if (gr_n == gr_errpop_at) begin
                        gr_errpop_at = -1;
                        if (gr_dir) begin gr_buf[gr_n] = g_wdata; g_wnext = 1'b1; end
                        else begin g_rdata = gr_src[gr_n]; g_rvalid = 1'b1; end
                        g_err = 1'b1;
                        @(posedge clk); #1;
                        g_wnext = 1'b0; g_rvalid = 1'b0; g_err = 1'b0; g_rdata = 16'hDEAD;
                        gr_n = gr_n + 1;
                        gdone = 1;
                    end
                    else if (gr_n == gr_words + gr_extra || gr_n == gr_ack_at) begin
                        g_ack = 1'b1; @(posedge clk); #1; g_ack = 1'b0; gdone = 1;
                    end else begin
                        if (gr_dir) begin gr_buf[gr_n] = g_wdata; g_wnext = 1'b1; end
                        else begin g_rdata = (gr_n < gr_words) ? gr_src[gr_n] : 16'hBAD0; g_rvalid = 1'b1; end
                        @(posedge clk); #1;
                        g_wnext = 1'b0; g_rvalid = 1'b0; g_rdata = 16'hDEAD;
                        gr_n = gr_n + 1;
                    end
                end
                gk = 0;                 // until the op has ended
                while (g_req === 1'b1 && gk < 4000000) begin @(posedge clk); #1; gk = gk + 1; end
            end
        end
    end

    // g_dir, g_port, g_words stable while g_req (the bridge samples them across clocks)
    reg p_greq = 1'b0, p_gdir = 1'b0, p_gport = 1'b0;
    reg [9:0] p_gwords = 10'd0;
    always @(posedge clk) if (!reset) begin
        if (g_req === 1'b1 && p_greq === 1'b1 && {g_dir, g_port, g_words} !== {p_gdir, p_gport, p_gwords}) begin
            $display("FAIL %0s: g_dir / g_port / g_words changed while g_req (cycle %0d)", cur, cyc); errors = errors + 1;
        end
        p_greq <= g_req; p_gdir <= g_dir; p_gport <= g_port; p_gwords <= g_words;
    end

    // white box, the interlock invariant: verified bytes never exceed RXLVL
    always @(posedge clk) if (!reset && dut.verified > dut.rxlvl) begin
        $display("FAIL %0s: verified %0d > RXLVL %0d (cycle %0d)", cur, dut.verified, dut.rxlvl, cyc);
        errors = errors + 1;
    end

    // white box, g_wvalid: exactly "dir 1 Gayle op and the RX head word is
    // complete" (dut.hc == 2), and high in the first cycle of a dir 1 g_req
    // (every case has the block in RX well before it starts the op)
    always @(posedge clk) if (!reset) begin
        if (g_wvalid !== (g_req === 1'b1 && g_dir === 1'b1 && dut.hc == 2'd2)) begin
            $display("FAIL %0s: g_wvalid %b with g_req %b g_dir %b hc %0d (cycle %0d)", cur, g_wvalid, g_req, g_dir, dut.hc, cyc);
            errors = errors + 1;
        end
        if (g_req === 1'b1 && g_dir === 1'b1 && p_greq !== 1'b1 && g_wvalid !== 1'b1) begin
            $display("FAIL %0s: g_wvalid low in the first cycle of a dir 1 g_req (cycle %0d)", cur, cyc);
            errors = errors + 1;
        end
    end

    // white box, the registered flags (Task 8 timing hardening):
    //   tx_full_r == (TXLVL == 1024) in every cycle;
    //   while g_req: g_more_r == (COUNT != LEN), g_last_r == (COUNT + 2 == LEN);
    //   a Gayle pop only with hc == 2;
    //   at every CMD strobe: tx_room_r / rx_ready_r equal what TXLVL, LEN and
    //   verified give now, except in the cycle right after an op's end (fin_d),
    //   where no command but ABORT may be accepted.
    reg p_opfin = 1'b0;
    integer n_cmd_chk = 0, n_cmd_late = 0;
    always @(posedge clk) if (!reset) begin
        if (dut.tx_full_r !== (dut.txlvl == 11'd1024)) begin
            $display("FAIL %0s: tx_full_r %b with TXLVL %0d (cycle %0d)", cur, dut.tx_full_r, dut.txlvl, cyc);
            errors = errors + 1;
        end
        if (dut.g_req_r === 1'b1 && (dut.g_more_r !== (dut.cnt != dut.len_r)
                                     || dut.g_last_r !== (dut.cnt + 11'd2 == dut.len_r))) begin
            $display("FAIL %0s: g_more_r %b g_last_r %b with COUNT %0d LEN %0d (cycle %0d)",
                     cur, dut.g_more_r, dut.g_last_r, dut.cnt, dut.len_r, cyc);
            errors = errors + 1;
        end
        if (dut.g_pop === 1'b1 && dut.hc != 2'd2) begin
            $display("FAIL %0s: Gayle pop with hc %0d (cycle %0d)", cur, dut.hc, cyc);
            errors = errors + 1;
        end
        if (reg_wstb === 1'b1 && reg_addr == 4'd4) begin
            n_cmd_chk = n_cmd_chk + 1;
            if (p_opfin) n_cmd_late = n_cmd_late + 1;
            if (p_opfin && dut.cmd_accept === 1'b1) begin
                $display("FAIL %0s: CMD accepted in the cycle right after an op's end (cycle %0d)", cur, cyc);
                errors = errors + 1;
            end
            if (!p_opfin && (dut.tx_room_r !== ({1'b0, dut.txlvl} + {1'b0, dut.len_r} <= 12'd1024)
                             || dut.rx_ready_r !== (dut.verified >= dut.len_r))) begin
                $display("FAIL %0s: CMD strobe: tx_room_r / rx_ready_r stale (cycle %0d)", cur, cyc);
                errors = errors + 1;
            end
        end
        p_opfin <= dut.op_fin;
    end

    // MOSI bytes as the card would see them (sampled at SCK rising); a case
    // sets mo_n = 0, mo_bits = 0 while the shifter is idle
    integer mo_n = 0, mo_bits = 0;
    reg [7:0] mo_sh = 8'h00;
    reg [7:0] mo_log [0:2047];
    always @(posedge sd_sck) begin
        mo_sh = {mo_sh[6:0], sd_mosi};
        mo_bits = mo_bits + 1;
        if (mo_bits == 8) begin
            mo_bits = 0;
            if (mo_n < 2048) mo_log[mo_n] = mo_sh;
            mo_n = mo_n + 1;
        end
    end

    // ---------------------------------------------------------------- CPU side
    task wr(input [5:0] off, input [15:0] d);
        begin
            @(posedge clk);
            reg_addr <= off[5:2]; reg_d <= d; reg_wstb <= 1'b1;
            @(posedge clk);
            reg_wstb <= 1'b0;
            repeat (ACC - 1) @(posedge clk);
            reg_d <= 16'hA5C3;          // not the written value any more
            repeat (GAP) @(posedge clk);
        end
    endtask

    task rd(input [5:0] off, output [15:0] q);
        integer k;
        begin
            @(posedge clk);
            reg_addr <= off[5:2]; reg_rstb <= 1'b1;
            @(posedge clk);
            reg_rstb <= 1'b0;
            #1 q = reg_q;               // the cycle after the strobe
            for (k = 1; k < ACC; k = k + 1) begin
                @(posedge clk);
                #1 if (reg_q !== q) begin
                    $display("FAIL %0s: reg_q of offset %h changed during the access: %h -> %h (cycle %0d)",
                             cur, off, q, reg_q, cyc);
                    errors = errors + 1;
                end
            end
            repeat (GAP) @(posedge clk);
        end
    endtask

    task expect_rd(input [5:0] off, input [15:0] mask, input [15:0] want, input [8*64-1:0] what);
        reg [15:0] q;
        begin
            rd(off, q);
            if ((q & mask) !== want) begin
                $display("FAIL %0s: %0s: read %h (mask %h), want %h (cycle %0d)", cur, what, q, mask, want, cyc);
                errors = errors + 1;
            end
        end
    endtask

    task wait_idle(input integer maxcyc);
        reg [15:0] s;
        integer t0;
        begin
            t0 = cyc;
            rd(R_CMD, s);
            while (s[0] === 1'b1 && cyc - t0 < maxcyc) rd(R_CMD, s);
            if (s[0] !== 1'b0) fail("op still busy (wait_idle limit)");
        end
    endtask

    task wait_cycles(input integer n);
        begin repeat (n) @(posedge clk); end
    endtask

    task set_cs(input on, input [7:0] div);
        begin wr(R_CFG, {7'd0, on, div}); end
    endtask

    // CS high for a moment (the model drops its state), then low
    task cs_cycle(input [7:0] div);
        begin set_cs(1'b0, div); wait_cycles(20); set_cs(1'b1, div); end
    endtask

    // a 6-byte command through TX (XFER bit 4), RX discarded
    task send_cmd(input [5:0] idx, input [31:0] arg, input [7:0] crc);
        begin
            wr(R_DATAW, {2'b01, idx, arg[31:24]});
            wr(R_DATAW, arg[23:8]);
            wr(R_DATAW, {arg[7:0], crc});
            wr(R_LEN, 16'd6);
            wr(R_CMD, OP_XFER | C_TX);
            wait_idle(100000);
            wr(R_CMD, OP_TXCM);         // TX keeps sent bytes until TX_COMMIT
        end
    endtask

    // a command frame with its real CRC7 into TX (not sent)
    function [6:0] crc7(input [6:0] c, input [7:0] b);
        integer i;
        reg [6:0] x;
        begin
            x = c;
            for (i = 7; i >= 0; i = i - 1)
                x = {x[5:0], 1'b0} ^ ((x[6] ^ b[i]) ? 7'h09 : 7'h00);
            crc7 = x;
        end
    endfunction

    task push_cmd(input [5:0] idx, input [31:0] arg);
        reg [6:0] c;
        begin
            c = crc7(crc7(crc7(crc7(crc7(7'd0, {2'b01, idx}), arg[31:24]), arg[23:16]), arg[15:8]), arg[7:0]);
            wr(R_DATAW, {2'b01, idx, arg[31:24]});
            wr(R_DATAW, arg[23:8]);
            wr(R_DATAW, {arg[7:0], c, 1'b1});
        end
    endtask

    // a command with a valid CRC7, sent and committed (TX keeps sent bytes)
    task send_cmdc(input [5:0] idx, input [31:0] arg);
        begin
            push_cmd(idx, arg);
            wr(R_LEN, 16'd6);
            wr(R_CMD, OP_XFER | C_TX);
            wait_idle(100000);
            wr(R_CMD, OP_TXCM);
        end
    endtask

    // WAIT_EQ / WAIT_NE with MATCH m, TIMEOUT units; LAST into lastb
    reg [7:0] lastb;
    task wait_op(input [15:0] op, input [7:0] m, input [15:0] units);
        reg [15:0] q;
        begin
            wr(R_MATCH, {8'h00, m});
            wr(R_TIMEOUT, units);
            wr(R_CMD, op);
            wait_idle((units + 1) * 16384 + 20000);
            rd(R_LEN, q);
            lastb = q[7:0];
        end
    endtask

    // the R1 of the command just sent (WAIT_NE $FF)
    task expect_r1(input [7:0] want, input [8*32-1:0] what);
        begin
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== want) begin
                $display("FAIL %0s: %0s: R1 %h, want %h (cycle %0d)", cur, what, lastb, want, cyc);
                errors = errors + 1;
            end
        end
    endtask

    // model CRC checking on (CMD0, CMD59 arg 1) or off (CMD0)
    task crc_mode(input on);
        begin
            send_cmdc(6'd0, 32'd0);
            expect_r1(8'h01, "CMD0");
            if (on) begin
                send_cmdc(6'd59, 32'd1);
                expect_r1(8'h01, "CMD59");
            end
            if (card.crc_on !== on) fail("model CRC mode not as set");
        end
    endtask

    // CMD17 lba, R1, data token, then XFER 512 with the given CMD bits
    task read_block(input integer lba, input [15:0] bits);
        begin
            send_cmdc(6'd17, lba);
            expect_r1(8'h00, "CMD17");
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== 8'hFE) fail("no data token FE after CMD17");
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_XFER | bits);
            wait_idle(200000);
        end
    endtask

    // XFER 1 (the token) + XFER 512 bits 4 + 6 from TX
    task send_block;
        begin
            wr(R_LEN, 16'd1);
            wr(R_CMD, OP_XFER | C_TX);
            wait_idle(10000);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_XFER | C_TX | C_CRCTX);
            wait_idle(200000);
            expect_rd(R_MATCH, 16'hFFFF, 16'd514, "COUNT of XFER 512 + CRC16");
        end
    endtask

    // CMD24 lba (sent and committed), R1, then token FE + 512 bytes wpat(i + po)
    // pushed and sent with XFER 1 + XFER 512 bits 4 + 6 (CRC16 appended)
    task write_block(input integer lba, input integer po);
        integer i;
        begin
            send_cmdc(6'd24, lba);
            expect_r1(8'h00, "CMD24");
            wr(R_DATAB, 16'h00FE);
            for (i = 0; i < 256; i = i + 1) wr(R_DATAW, {wpat(2 * i + po), wpat(2 * i + 1 + po)});
            send_block;
        end
    endtask

    // LBA lba on the card holds wpat(i + po)
    task check_mem_pat(input integer lba, input integer po, input [8*48-1:0] what);
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < 512; i = i + 1) if (card.mem[lba * 512 + i] !== wpat(i + po)) bad = bad + 1;
            if (bad) begin $display("FAIL %0s: %0s: %0d bytes differ", cur, what, bad); errors = errors + 1; end
        end
    endtask

    // a CMD the peripheral must refuse: STATUS 6, IRQ 3 (not 0), not busy
    task expect_refused(input [15:0] cmd, input [8*64-1:0] what);
        reg [15:0] s;
        begin
            wr(R_IRQ, 16'h001F);
            wr(R_CMD, cmd);
            rd(R_CMD, s);
            if (s[6] !== 1'b1 || s[0] !== 1'b0) begin
                $display("FAIL %0s: %0s: not refused (STATUS %h) (cycle %0d)", cur, what, s, cyc); errors = errors + 1;
            end
            rd(R_IRQ, s);
            if ((s & 16'h0009) !== 16'h0008) begin
                $display("FAIL %0s: %0s: IRQPEND %h, want error and no done (cycle %0d)", cur, what, s, cyc); errors = errors + 1;
            end
            wr(R_IRQ, 16'h001F);
        end
    endtask

    // a CMD write whose strobe falls in the cycle right after the running
    // op's end (op_fin): sdcard_spi must refuse it (fin_d); then the rest of
    // an access
    task cmd_after_end(input [15:0] cmd);
        integer k;
        begin
            k = 0;
            while (p_opfin !== 1'b1 && k < 400000) begin @(posedge clk); #1; k = k + 1; end
            if (p_opfin !== 1'b1) fail("cmd_after_end: no op end seen");
            if (dut.busy !== 1'b0) fail("cmd_after_end: busy in the cycle after op_fin");
            reg_addr = 4'd4; reg_d = cmd; reg_wstb = 1'b1;
            @(posedge clk); #1;
            reg_wstb = 1'b0;
            repeat (ACC - 1 + GAP) @(posedge clk);
        end
    endtask

    // the next n bytes in RX (popped by RXW) against byte off.. of LBA lba
    task check_rx_block(input integer lba, input integer off, input integer n, input [8*48-1:0] what);
        reg [15:0] q;
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < n; i = i + 2) begin
                rd(R_DATAW, q);
                if (q !== {img[lba * 512 + off + i], img[lba * 512 + off + i + 1]}) bad = bad + 1;
            end
            if (bad) begin $display("FAIL %0s: %0s: %0d words differ", cur, what, bad); errors = errors + 1; end
        end
    endtask

    // the words the responder took (dir 1) against byte off.. of LBA lba
    task check_gr_buf(input integer lba, input integer off, input integer words, input [8*48-1:0] what);
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < words; i = i + 1)
                if (gr_buf[i] !== {img[lba * 512 + off + 2 * i], img[lba * 512 + off + 2 * i + 1]}) begin
                    if (bad < 3) $display("FAIL %0s: %0s: word %0d = %h, want %h", cur, what, i, gr_buf[i],
                                          {img[lba * 512 + off + 2 * i], img[lba * 512 + off + 2 * i + 1]});
                    bad = bad + 1;
                end
            if (bad) begin $display("FAIL %0s: %0s: %0d words differ", cur, what, bad); errors = errors + 1; end
        end
    endtask

    // n bytes of $FF out, received into RX (XFER bit 5), popped into rxbuf
    // (RXW pairs, a last odd byte by RXB)
    task recv(input integer n);
        reg [15:0] q;
        integer i;
        begin
            wr(R_LEN, n);
            wr(R_CMD, OP_XFER | C_RX);
            wait_idle(200000);
            expect_rd(R_RXLVL, 16'hFFFF, n, "RXLVL after recv");
            for (i = 0; i + 1 < n; i = i + 2) begin
                rd(R_DATAW, q); rxbuf[i] = q[15:8]; rxbuf[i + 1] = q[7:0];
            end
            if (n % 2) begin rd(R_DATAB, q); rxbuf[n - 1] = q[7:0]; end
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after the pops");
        end
    endtask

    // the R1 in rxbuf[0..n-1]: the first byte that is not $FF (-1: none)
    function integer r1_at(input integer n);
        integer i;
        begin
            r1_at = -1;
            for (i = n - 1; i >= 0; i = i - 1) if (rxbuf[i] != 8'hFF) r1_at = i;
        end
    endfunction

    // the CMD24 test block of t_min_spacing
    function [7:0] wpat(input integer i);
        begin wpat = i * 13 + 5; end
    endfunction

    function [15:0] crc16(input [15:0] c, input [7:0] b);
        integer i;
        reg [15:0] x;
        begin
            x = c;
            for (i = 7; i >= 0; i = i - 1)
                x = {x[14:0], 1'b0} ^ ((x[15] ^ b[i]) ? 16'h1021 : 16'h0000);
            crc16 = x;
        end
    endfunction

    // expected CMD18 stream from LBA lba: NCR $FF, R1 00, then per block
    // 4 x $FF (the model's token delay), $FE, 512 data bytes, CRC16
    task make_cmd18_stream(input integer lba, input integer n);
        integer i, k;
        reg [15:0] c;
        begin
            i = 0;
            expb[i] = 8'hFF; i = i + 1;
            expb[i] = 8'h00; i = i + 1;
            while (i < n) begin
                for (k = 0; k < 4; k = k + 1) begin if (i < n) expb[i] = 8'hFF; i = i + 1; end
                if (i < n) expb[i] = 8'hFE; i = i + 1;
                c = 16'd0;
                for (k = 0; k < 512; k = k + 1) begin
                    if (i < n) expb[i] = img[lba * 512 + k];
                    c = crc16(c, img[lba * 512 + k]);
                    i = i + 1;
                end
                if (i < n) expb[i] = c[15:8]; i = i + 1;
                if (i < n) expb[i] = c[7:0];  i = i + 1;
                lba = lba + 1;
            end
        end
    endtask

    task begin_case(input [8*32-1:0] name, output run);
        begin
            run = all_tests || (testsel == name);
            if (run) begin cur = name; case_err0 = errors; end
        end
    endtask

    task end_case;
        begin
            if (errors == case_err0) $display("PASS %0s", cur);
            else $display("FAIL %0s (%0d errors)", cur, errors - case_err0);
            cur = "-";
        end
    endtask

    // the clk cycles of the next n SCK rising / falling edges (rise_t / fall_t),
    // polled at clk; FAIL after maxcyc cycles without them
    task measure_sck(input integer n, input integer maxcyc);
        integer k, t, ps;
        begin
            k = 0; t = 0; ps = sd_sck;
            while (k < n && t < maxcyc) begin
                @(posedge clk); #1;
                if (sd_sck === 1'b1 && ps == 0) rise_t[k] = cyc;
                if (sd_sck === 1'b0 && ps == 1) begin fall_t[k] = cyc; k = k + 1; end
                ps = (sd_sck === 1'b1);
                t = t + 1;
            end
            if (k < n) fail("SCK edges missing (measure_sck limit)");
        end
    endtask

    // ---------------------------------------------------------------- cases
    reg run_it;
    reg [15:0] q, q2;
    integer i, n, t0, s0, r1, last_l, seen_exact, seen_lo, per, per_bad, hi_bad;
    reg [8*1024-1:0] imgname;
    integer fd, nread;

    initial begin
        cur = "-";
        irq_must_be_0 = 1'b0;
        all_tests = 1'b1; testsel = "";
        if ($value$plusargs("TEST=%s", testsel)) all_tests = 1'b0;
        xcheck = 1'b0;
        if ($test$plusargs("XCHECK")) xcheck = 1'b1;
        for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;
        if ($value$plusargs("SD_IMG=%s", imgname)) begin
            fd = $fopen(imgname, "rb");
            if (fd == 0) begin $display("=== FAIL tb_sdcard_spi: cannot open +SD_IMG"); $finish; end
            nread = $fread(img, fd);
            $fclose(fd);
        end

        repeat (10) @(posedge clk);
        reset <= 1'b0;
        @(posedge clk);
        #1;
        // ---- after reset: pins idle, nothing pending
        cur = "t_reset";
        case_err0 = errors;
        if (sd_cs_n !== 1'b1 || sd_sck !== 1'b0 || sd_mosi !== 1'b1 || irq !== 1'b0 || reg_q !== 16'h0000
            || g_req !== 1'b0)
            fail("pins / reg_q after reset not cs_n 1, sck 0, mosi 1, irq 0, reg_q 0, g_req 0");
        expect_rd(R_CMD, 16'h00FF, 16'h0008, "STATUS after reset (card present only)");
        expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after reset");
        expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after reset");
        // WMARK 0: RX >= 0 and TX (empty) <= 0 hold, so bits 1, 2 are pending
        expect_rd(R_IRQ, 16'hFFFF, 16'h0006, "IRQPEND after reset (watermark levels only)");
        end_case;

        // ---- VERSION
        begin_case("t_version", run_it);
        if (run_it) begin
            expect_rd(R_WMARK, 16'hFFFF, 16'h5D01, "VERSION");
            end_case;
        end

        // ---- XFER, TX from the FIFO: CMD0 reaches the card
        begin_case("t_xfer_tx", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            wr(R_IRQ, 16'h001F);
            s0 = card.cmd_n;
            wr(R_DATAW, 16'h4000);
            wr(R_DATAW, 16'h0000);
            wr(R_DATAW, 16'h0095);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd6, "TXLVL after 3 TXW");
            n = sck_rises;
            wr(R_LEN, 16'd6);
            wr(R_CMD, OP_XFER | C_TX);
            expect_rd(R_CMD, 16'h0001, 16'h0001, "STATUS busy during the XFER");
            wait_idle(100000);
            if (card.cmd_n != s0 + 1) fail("the card saw no command");
            if (card.cidx != 6'd0 || card.carg != 32'd0) fail("the card's command is not CMD0 arg 0");
            if (sck_rises - n != 48) fail("not 48 SCK rising edges for 6 bytes");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd6, "TXLVL after the XFER (sent bytes kept)");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after a TX-only XFER");
            expect_rd(R_MATCH, 16'hFFFF, 16'd6, "COUNT");
            expect_rd(R_IRQ, 16'h0001, 16'h0001, "IRQPEND op done");
            wr(R_CMD, OP_TXCM);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after TX_COMMIT");
            recv(4);
            r1 = r1_at(4);
            if (r1 < 0 || rxbuf[r1] != 8'h01) fail("CMD0 R1 is not 01");
            end_case;
        end

        // ---- XFER, RX into the FIFO: OCR of CMD58 after the card's init
        begin_case("t_xfer_rx", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            send_cmd(6'd0, 32'h0, 8'h95);   recv(4);
            send_cmd(6'd8, 32'h1AA, 8'h87); recv(8);
            r1 = r1_at(8);
            if (r1 < 0 || rxbuf[r1] != 8'h01 || {rxbuf[r1+3], rxbuf[r1+4]} != 16'h01AA) fail("CMD8 R7");
            n = 0;
            q = 16'h0001;
            while (q[0] && n < 10) begin
                send_cmd(6'd55, 32'h0, 8'h65);        recv(4);
                send_cmd(6'd41, 32'h40000000, 8'h77); recv(4);
                r1 = r1_at(4);
                q = (r1 < 0) ? 16'h00FF : {8'h00, rxbuf[r1]};
                n = n + 1;
            end
            if (q != 16'h0000) fail("ACMD41 never answered 00");
            send_cmd(6'd58, 32'h0, 8'hFD);
            wr(R_LEN, 16'd8);
            wr(R_CMD, OP_XFER | C_RX);
            wait_idle(100000);
            expect_rd(R_RXLVL, 16'hFFFF, 16'd8, "RXLVL after XFER 8");
            expect_rd(R_MATCH, 16'hFFFF, 16'd8, "COUNT");
            expect_rd(R_LEN, 16'h00FF, 16'h00FF, "LAST (the card's trailing $FF)");
            expect_rd(R_DATAW, 16'hFFFF, 16'hFF00, "RXW 1: NCR $FF, R1 00");
            expect_rd(R_DATAW, 16'hFFFF, 16'hC0FF, "RXW 2: OCR 31:16");
            expect_rd(R_DATAW, 16'hFFFF, 16'h8000, "RXW 3: OCR 15:0");
            expect_rd(R_DATAW, 16'hFFFF, 16'hFFFF, "RXW 4: trailing $FF $FF");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after 4 RXW");
            end_case;
        end

        // ---- SCK stops when RX is full and resumes when drained; no byte lost
        begin_case("t_sck_pause", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            send_cmd(6'd18, 32'd5, 8'hFF);
            make_cmd18_stream(5, 1500);
            s0 = sck_rises;
            wr(R_LEN, 16'd1500);
            wr(R_CMD, OP_XFER | C_RX);
            t0 = cyc;
            rd(R_RXLVL, q);
            while (q < 16'd1024 && cyc - t0 < 100000) rd(R_RXLVL, q);
            if (q != 16'd1024) fail("RXLVL did not reach 1024");
            wait_cycles(3000);
            if (sck_rises - s0 != 1024 * 8) begin
                $display("FAIL %0s: %0d SCK rising edges while RX full, want %0d", cur, sck_rises - s0, 1024 * 8);
                errors = errors + 1;
            end
            if (sd_sck !== 1'b0) fail("SCK not low in the pause");
            expect_rd(R_CMD, 16'h0001, 16'h0001, "STATUS busy in the pause");
            expect_rd(R_MATCH, 16'hFFFF, 16'd1024, "COUNT in the pause");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd1024, "RXLVL in the pause");
            // drain while the transfer goes on
            n = 0;
            t0 = cyc;
            while (n < 1500 && cyc - t0 < 400000) begin
                rd(R_RXLVL, q);
                if (q >= 2) begin rd(R_DATAW, q2); rxbuf[n] = q2[15:8]; rxbuf[n + 1] = q2[7:0]; n = n + 2; end
            end
            wait_idle(1000);
            if (n != 1500) fail("not 1500 bytes popped");
            if (sck_rises - s0 != 1500 * 8) fail("not 1500 x 8 SCK rising edges");
            expect_rd(R_MATCH, 16'hFFFF, 16'd1500, "COUNT at the end");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL at the end");
            per_bad = 0;
            for (i = 0; i < 1500; i = i + 1)
                if (rxbuf[i] !== expb[i]) begin
                    if (per_bad < 5) $display("FAIL %0s: byte %0d = %h, want %h", cur, i, rxbuf[i], expb[i]);
                    per_bad = per_bad + 1;
                end
            if (per_bad) begin errors = errors + 1; $display("FAIL %0s: %0d bytes differ from the card's CMD18 stream", cur, per_bad); end
            end_case;
        end

        // ---- watermark interrupts; irq follows IRQEN
        begin_case("t_watermark_irq", run_it);
        if (run_it) begin
            cs_cycle(8'h10);            // 272 cycles per byte: polls see every RXLVL value
            wr(R_IRQEN, 16'h0000);
            wr(R_WMARK, 16'h2000);      // RX high 32 x 16 = 512, TX low 0
            wr(R_IRQ, 16'h001F);
            irq_must_be_0 = 1'b1;
            wr(R_LEN, 16'd600);
            wr(R_CMD, OP_XFER | C_RX);
            seen_exact = 0; seen_lo = 0; last_l = 0;
            t0 = cyc;
            rd(R_RXLVL, q2);
            while (q2 < 16'd520 && cyc - t0 < 300000) begin
                rd(R_IRQ, q);
                rd(R_RXLVL, q2);        // read after IRQPEND: only higher
                if (q[1] && q2 < 16'd512) fail("IRQPEND bit 1 below 512 bytes");
                if (!q[1] && q2 > 16'd512) fail("IRQPEND bit 1 clear above 512 bytes");
                if (!q[1] && q2 == 16'd511) seen_lo = 1;
                if (q[1] && q2 == 16'd512) seen_exact = 1;
            end
            if (!seen_lo || !seen_exact) fail("IRQPEND bit 1 not seen clear at 511 and set at 512");
            irq_must_be_0 = 1'b0;
            if (irq !== 1'b0) fail("irq high with IRQEN 0");
            wr(R_IRQEN, 16'h0002);
            if (irq !== 1'b1) fail("irq not high with IRQEN bit 1");
            wr(R_IRQEN, 16'h0000);
            if (irq !== 1'b0) fail("irq not low after IRQEN 0");
            wr(R_IRQ, 16'h0002);        // still above the mark: stays pending
            expect_rd(R_IRQ, 16'h0002, 16'h0002, "IRQPEND bit 1 after IRQACK above the mark");
            wr(R_IRQEN, 16'h0002);
            wait_idle(300000);
            for (i = 0; i < 50; i = i + 1) rd(R_DATAW, q);   // 600 - 100 = 500 < 512
            if (irq !== 1'b1) fail("irq dropped before IRQACK");
            wr(R_IRQ, 16'h0002);
            expect_rd(R_IRQ, 16'h0003, 16'h0001, "IRQPEND after IRQACK below the mark (done still set)");
            if (irq !== 1'b0) fail("irq not low after IRQACK");
            wr(R_IRQEN, 16'h0001);
            if (irq !== 1'b1) fail("irq not high for op done");
            wr(R_IRQ, 16'h0001);
            if (irq !== 1'b0) fail("irq not low after acking op done");
            wr(R_CMD, OP_RXFL);
            // TX low watermark 1 x 16 bytes
            wr(R_IRQEN, 16'h0000);
            wr(R_WMARK, 16'h4001);
            wr(R_IRQ, 16'h001F);
            expect_rd(R_IRQ, 16'h0004, 16'h0004, "IRQPEND bit 2 with TX empty");
            for (i = 0; i < 9; i = i + 1) wr(R_DATAW, 16'hFFFF);    // 18 bytes
            wr(R_IRQ, 16'h0004);
            expect_rd(R_IRQ, 16'h0004, 16'h0000, "IRQPEND bit 2 with 18 bytes in TX");
            wr(R_IRQEN, 16'h0004);
            if (irq !== 1'b0) fail("irq high with TX above the low mark");
            rd(R_DATAW, q);             // RX empty: no effect on TX
            wr(R_LEN, 16'd2);
            wr(R_CMD, OP_XFER | C_TX);
            wait_idle(100000);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd18, "TXLVL after sending 2 (kept)");
            if (irq !== 1'b0) fail("irq high with 2 sent bytes still kept");
            wr(R_CMD, OP_TXCM);         // 16 left: <= the mark
            expect_rd(R_TXLVL, 16'hFFFF, 16'd16, "TXLVL after TX_COMMIT");
            if (irq !== 1'b1) fail("irq not high at TX <= low mark");
            wr(R_IRQEN, 16'h0000);
            wr(R_CMD, OP_TXFL);
            wr(R_IRQ, 16'h001F);
            wr(R_WMARK, 16'h0000);
            end_case;
        end

        // ---- SCK divider: period 2 * (div + 1), duty 50 %, also across bytes
        begin_case("t_divider", run_it);
        if (run_it) begin
            cs_cycle(8'h8A);
            wr(R_DATAW, 16'h8DB3);
            wr(R_LEN, 16'd2);
            wr(R_CMD, OP_XFER | C_TX);
            measure_sck(16, 20000);
            wait_idle(100000);
            per_bad = 0; hi_bad = 0;
            for (i = 1; i < 16; i = i + 1) begin
                per = rise_t[i] - rise_t[i - 1];
                if (per < 2 * (8'h8A + 1) - 1 || per > 2 * (8'h8A + 1) + 1) begin
                    if (per_bad < 3) $display("FAIL %0s: SCK period %0d -> %0d: %0d cycles, want %0d", cur, i - 1, i, per, 2 * (8'h8A + 1));
                    per_bad = per_bad + 1;
                end
            end
            for (i = 0; i < 16; i = i + 1) begin
                per = fall_t[i] - rise_t[i];
                if (per < 8'h8A || per > 8'h8A + 2) hi_bad = hi_bad + 1;
            end
            if (per_bad) begin errors = errors + 1; $display("FAIL %0s: %0d periods off", cur, per_bad); end
            if (hi_bad) begin errors = errors + 1; $display("FAIL %0s: %0d SCK high times not %0d", cur, hi_bad, 8'h8A + 1); end
            wr(R_CMD, OP_TXCM);
            end_case;
        end

        // ---- fastest divider (SCK = clk / 2): gapless bytes, command still arrives
        begin_case("t_gapless", run_it);
        if (run_it) begin
            cs_cycle(8'd0);
            wr(R_DATAW, {2'b01, 6'd16, 8'h00});
            wr(R_DATAW, 16'h0002);
            wr(R_DATAW, 16'h00FF);
            wr(R_DATAW, 16'hFFFF);
            wr(R_DATAW, 16'hFFFF);
            wr(R_LEN, 16'd10);
            s0 = card.cmd_n;
            fork                        // the first edges come before wr returns
                wr(R_CMD, OP_XFER | C_TX | C_RX);
                measure_sck(80, 2000);
            join
            per_bad = 0;
            for (i = 1; i < 80; i = i + 1) if (rise_t[i] - rise_t[i - 1] != 2) per_bad = per_bad + 1;
            wait_idle(10000);
            if (per_bad) begin errors = errors + 1; $display("FAIL %0s: %0d SCK periods not 2 cycles", cur, per_bad); end
            if (card.cmd_n != s0 + 1 || card.cidx != 6'd16 || card.carg != 32'h200) fail("CMD16 arg 200 not seen by the card");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd10, "RXLVL");
            for (i = 0; i < 5; i = i + 1) begin rd(R_DATAW, q); rxbuf[2*i] = q[15:8]; rxbuf[2*i+1] = q[7:0]; end
            if (rxbuf[7] != 8'h00 || rxbuf[6] != 8'hFF) fail("CMD16 R1 at byte 7 not 00");
            wr(R_CMD, OP_TXCM);
            end_case;
        end

        // ---- FIFO byte paths, flushes, full TX, pops on empty
        begin_case("t_fifo", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            wr(R_IRQ, 16'h001F);
            wr(R_DATAB, 16'hFF11);
            wr(R_DATAB, 16'h0022);
            wr(R_DATAB, 16'h0033);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd3, "TXLVL after 3 TXB");
            wr(R_CMD, OP_TXFL);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after TX_FLUSH");
            expect_rd(R_IRQ, 16'h0001, 16'h0001, "IRQPEND done after TX_FLUSH");
            expect_rd(R_CMD, 16'h0100, 16'h0000, "STATUS 8 (FIFO misuse) clear");
            for (i = 0; i < 511; i = i + 1) wr(R_DATAW, i);
            wr(R_DATAB, 16'h0055);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1023, "TXLVL after 1023 bytes pushed");
            expect_rd(R_CMD, 16'h0100, 16'h0000, "STATUS 8 clear with TX not full");
            wr(R_IRQ, 16'h001F);
            wr(R_DATAW, 16'h6677);      // 66 fits, 77 is dropped
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1024, "TXLVL after a TXW into one free place");
            expect_rd(R_CMD, 16'h0100, 16'h0100, "STATUS 8 after the dropped second TXW byte");
            expect_rd(R_IRQ, 16'h0008, 16'h0008, "IRQPEND error after the dropped byte");
            wr(R_DATAW, 16'h8899);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1024, "TXLVL after a TXW into a full TX");
            wr(R_CMD, OP_TXFL);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after TX_FLUSH of a full FIFO");
            expect_rd(R_CMD, 16'h0100, 16'h0000, "STATUS 8 cleared by the accepted TX_FLUSH");
            // the first byte pushed after the flush is the first one sent
            send_cmd(6'd8, 32'h1AA, 8'h87);
            wr(R_LEN, 16'd8);
            wr(R_CMD, OP_XFER | C_RX);
            wait_idle(100000);
            expect_rd(R_RXLVL, 16'hFFFF, 16'd8, "RXLVL after CMD8 response");
            rd(R_DATAB, q);  rxbuf[0] = q[7:0];
            if (q[15:8] != 8'h00) fail("RXB bits 15:8 not 0");
            rd(R_DATAW, q);  rxbuf[1] = q[15:8]; rxbuf[2] = q[7:0];
            rd(R_DATAB, q);  rxbuf[3] = q[7:0];
            rd(R_DATAW, q);  rxbuf[4] = q[15:8]; rxbuf[5] = q[7:0];
            if (rxbuf[0] != 8'hFF || (rxbuf[1] != 8'h00 && rxbuf[1] != 8'h01) || rxbuf[2] != 8'h00
                || rxbuf[3] != 8'h00 || rxbuf[4] != 8'h01 || rxbuf[5] != 8'hAA)
                fail("CMD8 R7 through RXB / RXW mix");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd2, "RXLVL with 2 left");
            wr(R_CMD, OP_RXFL);
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after RX_FLUSH");
            expect_rd(R_CMD, 16'h0100, 16'h0000, "STATUS 8 clear before the empty pop");
            wr(R_IRQ, 16'h001F);
            expect_rd(R_DATAW, 16'hFFFF, 16'h0000, "RXW on an empty RX");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after RXW on empty");
            expect_rd(R_CMD, 16'h0100, 16'h0100, "STATUS 8 after RXW on an empty RX");
            expect_rd(R_IRQ, 16'h0008, 16'h0008, "IRQPEND error after RXW on empty");
            // after the flush only new bytes come out (no stale prefetch)
            send_cmd(6'd8, 32'h1AA, 8'h87);
            wr(R_LEN, 16'd6);
            wr(R_CMD, OP_XFER | C_RX);
            wait_idle(100000);
            expect_rd(R_DATAW, 16'hFF00, 16'hFF00, "RXW after flush: NCR");
            expect_rd(R_DATAW, 16'hFFFF, 16'h0000, "RXW after flush: R7 00 00");
            expect_rd(R_DATAW, 16'hFFFF, 16'h01AA, "RXW after flush: R7 01 AA");
            // RXW with one byte left: the byte in 15:8, 00 in 7:0
            wr(R_LEN, 16'd1);
            wr(R_CMD, OP_XFER | C_RX);
            wait_idle(100000);
            expect_rd(R_CMD, 16'h0100, 16'h0000, "STATUS 8 cleared by the accepted XFER");
            expect_rd(R_DATAW, 16'hFFFF, 16'hFF00, "RXW with one byte in RX");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after it");
            expect_rd(R_CMD, 16'h0100, 16'h0100, "STATUS 8 after the short RXW");
            // LEN 0: done at once
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd0);
            n = sck_rises;
            wr(R_CMD, OP_XFER | C_RX);
            expect_rd(R_CMD, 16'h00C1, 16'h0000, "STATUS after XFER LEN 0");
            expect_rd(R_IRQ, 16'h0001, 16'h0001, "IRQPEND done after XFER LEN 0");
            expect_rd(R_MATCH, 16'hFFFF, 16'd0, "COUNT after XFER LEN 0");
            if (sck_rises != n) fail("SCK moved for LEN 0");
            end_case;
        end

        // ---- ops not in this core, CRC bits, CMD while busy: refused
        begin_case("t_unimpl", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            wr(R_IRQ, 16'h001F);
            wr(R_CMD, 16'h0000);
            expect_rd(R_CMD, 16'h00C1, 16'h0040, "STATUS after op 0");
            expect_rd(R_IRQ, 16'h0019, 16'h0008, "IRQPEND after op 0 (error, not done)");
            wr(R_IRQ, 16'h001F);
            wr(R_CMD, 16'h000A);
            expect_rd(R_CMD, 16'h00C1, 16'h0040, "STATUS after op 10");
            wr(R_CMD, OP_RXFL);
            expect_rd(R_CMD, 16'h00C1, 16'h0000, "STATUS after an accepted op");
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd4);
            n = sck_rises;
            wr(R_CMD, OP_XFER | C_CRCRX | C_CRCTX);
            expect_rd(R_CMD, 16'h00C1, 16'h0040, "STATUS after XFER with bits 6 and 7");
            wr(R_CMD, 16'h000C);
            expect_rd(R_CMD, 16'h00C1, 16'h0040, "STATUS after op 12");
            if (sck_rises != n) fail("SCK moved for a refused op");
            set_cs(1'b1, 8'h10);
            wr(R_LEN, 16'd40);
            wr(R_CMD, OP_XFER);
            wr(R_LEN, 16'd3);           // ignored while busy
            wr(R_CMD, OP_XFER);         // refused, the running op goes on
            expect_rd(R_CMD, 16'h00C1, 16'h0041, "STATUS: busy and refused");
            wr(R_RXLVL, 16'h0000);      // read-only register: no effect
            wr(R_CMD, OP_RXFL);         // refused while busy: STATUS 6 stays
            wr(R_IRQ, 16'h0008);
            wr(R_CFG, 16'h0005);        // refused while busy: CS and divider stay
            expect_rd(R_CFG, 16'h01FF, 16'h0110, "CFG after a refused write while busy");
            expect_rd(R_IRQ, 16'h0008, 16'h0008, "IRQPEND error after CFG while busy");
            if (sd_cs_n !== 1'b0) fail("CS released by a CFG write while busy");
            wait_idle(100000);
            expect_rd(R_MATCH, 16'hFFFF, 16'd40, "COUNT of the op that was running");
            wr(R_CFG, 16'h0005);
            expect_rd(R_CFG, 16'h01FF, 16'h0005, "CFG written when not busy");
            expect_rd(R_IRQ, 16'h0009, 16'h0009, "IRQPEND error + done");
            wr(R_CMD, OP_TXFL);
            expect_rd(R_CMD, 16'h00C1, 16'h0000, "STATUS after the next accepted op");
            wr(R_IRQ, 16'h001F);
            end_case;
        end

        // ---- card detect: synchronised, debounced (2^6 clocks here), change IRQ
        begin_case("t_card_detect", run_it);
        if (run_it) begin
            wr(R_IRQ, 16'h001F);
            expect_rd(R_CMD, 16'h0008, 16'h0008, "card present");
            sd_cd_n <= 1'b1; wait_cycles(40); sd_cd_n <= 1'b0;
            wait_cycles(200);
            expect_rd(R_CMD, 16'h0008, 16'h0008, "card present after a 40-cycle glitch");
            expect_rd(R_IRQ, 16'h0010, 16'h0000, "no change IRQ after the glitch");
            sd_cd_n <= 1'b1; wait_cycles(30);
            expect_rd(R_CMD, 16'h0008, 16'h0008, "still present 30 cycles after removal");
            wait_cycles(100);
            expect_rd(R_CMD, 16'h0008, 16'h0000, "card gone after the debounce");
            expect_rd(R_IRQ, 16'h0010, 16'h0010, "change IRQ on removal");
            wr(R_IRQEN, 16'h0010);
            if (irq !== 1'b1) fail("irq not high for card detect");
            wr(R_IRQ, 16'h0010);
            if (irq !== 1'b0) fail("irq not low after ack");
            sd_cd_n <= 1'b0; wait_cycles(150);
            expect_rd(R_CMD, 16'h0008, 16'h0008, "card present again");
            expect_rd(R_IRQ, 16'h0010, 16'h0010, "change IRQ on insertion");
            wr(R_IRQ, 16'h001F);
            wr(R_IRQEN, 16'h0000);
            end_case;
        end

        // ---- every access at the minimum strobe spacing the header promises
        // (4 cycles): RXW pops of fresh bytes and back-to-back bursts during a
        // div-0 CMD18 stream; then a CMD24 block pushed by TXW while the XFER
        // runs, interleaved with RXLVL / RXW pops.  No byte lost or short.
        begin_case("t_min_spacing", run_it);
        if (run_it) begin
            cs_cycle(8'd0);
            ACC = 3; GAP = 0;
            send_cmd(6'd18, 32'd9, 8'hFF);
            make_cmd18_stream(9, 1100);
            wr(R_CMD, OP_RXFL);
            wr(R_LEN, 16'd1100);
            wr(R_CMD, OP_XFER | C_RX);
            t0 = cyc;                   // let RX fill up first, for the bursts
            rd(R_RXLVL, q);
            while (q < 16'd400 && cyc - t0 < 100000) rd(R_RXLVL, q);
            n = 0; s0 = 0;
            t0 = cyc;
            while (n < 1100 && cyc - t0 < 200000) begin
                rd(R_RXLVL, q);
                if (q >= 64) begin       // a burst of 32 RXW, no RXLVL in between
                    for (i = 0; i < 32; i = i + 1) begin
                        rd(R_DATAW, q2); rxbuf[n] = q2[15:8]; rxbuf[n + 1] = q2[7:0]; n = n + 2;
                    end
                    s0 = s0 + 1;
                end else if (q >= 2) begin
                    rd(R_DATAW, q2); rxbuf[n] = q2[15:8]; rxbuf[n + 1] = q2[7:0]; n = n + 2;
                end
            end
            wait_idle(1000);
            if (n != 1100) fail("not 1100 bytes popped");
            if (s0 == 0) fail("no back-to-back RXW burst happened");
            per_bad = 0;
            for (i = 0; i < 1100; i = i + 1)
                if (rxbuf[i] !== expb[i]) begin
                    if (per_bad < 5) $display("FAIL %0s: byte %0d = %h, want %h", cur, i, rxbuf[i], expb[i]);
                    per_bad = per_bad + 1;
                end
            if (per_bad) begin errors = errors + 1; $display("FAIL %0s: %0d bytes differ from the CMD18 stream", cur, per_bad); end
            expect_rd(R_CMD, 16'h0100, 16'h0000, "STATUS 8: no short pop in the RX stream");
            // CMD24 to LBA 7, data pushed while the XFER runs
            cs_cycle(8'd0);
            send_cmd(6'd24, 32'd7, 8'hFF);
            recv(4);
            r1 = r1_at(4);
            if (r1 < 0 || rxbuf[r1] != 8'h00) fail("CMD24 R1 not 00");
            wr(R_LEN, 16'd515);
            wr(R_CMD, OP_XFER | C_TX | C_RX);
            wr(R_DATAB, 16'h00FE);
            n = 0; per_bad = 0;
            for (i = 0; i < 257; i = i + 1) begin
                if (i < 256) wr(R_DATAW, {wpat(2 * i), wpat(2 * i + 1)});
                else         wr(R_DATAW, 16'hFFFF);       // CRC (model CRC check off)
                rd(R_RXLVL, q);
                if (q >= 2) begin
                    rd(R_DATAW, q2); n = n + 2;
                    if (q2 !== 16'hFFFF) per_bad = per_bad + 1;
                end
            end
            wait_idle(100000);
            rd(R_RXLVL, q);
            while (q >= 2) begin
                rd(R_DATAW, q2); n = n + 2;
                if (q2 !== 16'hFFFF) per_bad = per_bad + 1;
                rd(R_RXLVL, q);
            end
            if (q == 1) begin rd(R_DATAB, q2); n = n + 1; if (q2 !== 16'h00FF) per_bad = per_bad + 1; end
            if (n != 515) begin $display("FAIL %0s: %0d RX bytes during the write, want 515", cur, n); errors = errors + 1; end
            if (per_bad) begin $display("FAIL %0s: %0d RX words not FFFF during the write", cur, per_bad); errors = errors + 1; end
            expect_rd(R_CMD, 16'h0100, 16'h0000, "STATUS 8: no overflow / short pop in the write");
            recv(12);
            r1 = r1_at(12);
            if (r1 < 0 || rxbuf[r1] != 8'h05) fail("data response not 05");
            per_bad = 0;
            for (i = 0; i < 512; i = i + 1)
                if (card.mem[7 * 512 + i] !== wpat(i)) per_bad = per_bad + 1;
            if (per_bad) begin $display("FAIL %0s: %0d bytes of LBA 7 differ from the pushed block", cur, per_bad); errors = errors + 1; end
            expect_rd(R_TXLVL, 16'hFFFF, 16'd515, "TXLVL after the write (kept)");
            wr(R_CMD, OP_TXCM);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after TX_COMMIT");
            ACC = 4; GAP = 4;
            end_case;
        end

        // ---- push strobes closer than cfide gives them (guard of the TXW
        // second-byte write): three TXW strobes in consecutive cycles, reg_d
        // changing every cycle; the card must see CMD16 arg 12345678
        begin_case("t_push_b2b", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            @(posedge clk);
            reg_addr <= R_DATAW >> 2; reg_wstb <= 1'b1; reg_d <= 16'h5012;
            @(posedge clk); reg_d <= 16'h3456;
            @(posedge clk); reg_d <= 16'h78FF;
            @(posedge clk); reg_wstb <= 1'b0; reg_d <= 16'hA5C3;
            repeat (GAP) @(posedge clk);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd6, "TXLVL after 3 back-to-back TXW");
            s0 = card.cmd_n;
            wr(R_LEN, 16'd6);
            wr(R_CMD, OP_XFER | C_TX);
            wait_idle(100000);
            if (card.cmd_n != s0 + 1 || card.cidx != 6'd16 || card.carg != 32'h12345678)
                fail("CMD16 arg 12345678 not seen by the card (byte order / lost byte)");
            recv(4);
            wr(R_CMD, OP_TXCM);
            end_case;
        end

        // ---- register read-back
        begin_case("t_regs", run_it);
        if (run_it) begin
            wr(R_CFG, 16'h01A5);
            expect_rd(R_CFG, 16'h01FF, 16'h01A5, "CFG");
            if (sd_cs_n !== 1'b0) fail("CS not asserted by CFG bit 8");
            wr(R_CFG, 16'h0002);
            if (sd_cs_n !== 1'b1) fail("CS not released by CFG bit 8 = 0");
            wr(R_TIMEOUT, 16'hBEEF);
            expect_rd(R_TIMEOUT, 16'hFFFF, 16'hBEEF, "TIMEOUT");
            wr(R_IRQEN, 16'h0015);
            expect_rd(R_IRQEN, 16'h001F, 16'h0015, "IRQEN");
            wr(R_IRQEN, 16'h0000);
            end_case;
        end

        // ============================================================ Task 6
        // ---- refusals: RX_TO_GAYLE of unverified bytes, LEN 0 / odd, CRC bits
        // 6 + 7 together, GAYLE_TO_TX without room; never a g_req for them
        begin_case("t_refuse", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            wr(R_CMD, OP_RXFL);
            wr(R_CMD, OP_TXFL);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_XFER | C_RX);  // 512 x $FF, no CRC check: unverified
            wait_idle(100000);
            expect_rd(R_RXLVL, 16'hFFFF, 16'd512, "RXLVL after a plain XFER");
            n = gr_reqs;
            expect_refused(OP_RX2G, "RX_TO_GAYLE of unverified bytes");
            wr(R_LEN, 16'd0);
            expect_refused(OP_RX2G, "RX_TO_GAYLE LEN 0");
            wr(R_LEN, 16'd511);
            expect_refused(OP_RX2G, "RX_TO_GAYLE LEN odd");
            wr(R_LEN, 16'd4);
            expect_refused(OP_XFER | C_CRCTX | C_CRCRX, "XFER with bits 6 and 7");
            wr(R_LEN, 16'd0);
            expect_refused(OP_G2TX, "GAYLE_TO_TX LEN 0");
            wr(R_LEN, 16'd3);
            expect_refused(OP_G2TX, "GAYLE_TO_TX LEN odd");
            for (i = 0; i < 300; i = i + 1) wr(R_DATAW, 16'hFFFF);    // 600 in TX, 424 free
            wr(R_LEN, 16'd426);
            expect_refused(OP_G2TX, "GAYLE_TO_TX LEN 426 with 424 free");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd600, "TXLVL unchanged by the refusals");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd512, "RXLVL unchanged by the refusals");
            if (gr_reqs != n) fail("g_req raised by a refused op");
            // exactly the free room: accepted, TX full, no overflow
            for (i = 0; i < 212; i = i + 1) gr_src[i] = i;
            wr(R_LEN, 16'd424);
            wr(R_CMD, OP_G2TX);
            wait_idle(20000);
            expect_rd(R_CMD, 16'h01FF, 16'h0008, "STATUS after GAYLE_TO_TX into the exact room");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1024, "TXLVL full after it");
            if (gr_reqs != n + 1 || gr_dir !== 1'b0 || gr_words != 212) fail("GAYLE_TO_TX 424: not one g_req, dir 0, 212 words");
            wr(R_CMD, OP_TXFL);
            wr(R_CMD, OP_RXFL);
            end_case;
        end

        // ---- CMD17 with the model's CRC check on: WAIT_NE for R1 and the token,
        // XFER 512 bits 5 + 7 -> crc_ok; RX_TO_GAYLE of the verified block;
        // a Gayle error mid-block; the rest of the block still verified
        begin_case("t_crc_read_ok", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            crc_mode(1'b1);
            wr(R_CMD, OP_RXFL);
            read_block(3, C_RX | C_CRCRX);
            expect_rd(R_CMD, 16'h01F7, 16'h0002, "STATUS after a good block (crc_ok)");
            expect_rd(R_MATCH, 16'hFFFF, 16'd514, "COUNT 512 + 2 CRC bytes");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd512, "RXLVL: the CRC bytes not stored");
            wr(R_LEN, 16'd514);
            expect_refused(OP_RX2G, "RX_TO_GAYLE LEN 514 with 512 verified");
            n = gr_reqs;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_RX2G | C_GPORT);
            wait_idle(20000);
            if (gr_reqs != n + 1 || gr_dir !== 1'b1 || gr_port !== 1'b1 || gr_words != 256 || gr_n != 256)
                fail("RX_TO_GAYLE: not one g_req, dir 1, port 1, 256 words taken");
            check_gr_buf(3, 0, 256, "RX_TO_GAYLE words");
            expect_rd(R_CMD, 16'h01FF, 16'h0008, "STATUS after RX_TO_GAYLE");
            expect_rd(R_MATCH, 16'hFFFF, 16'd512, "COUNT after RX_TO_GAYLE");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after RX_TO_GAYLE");
            expect_rd(R_IRQ, 16'h0009, 16'h0001, "IRQPEND done, no error");
            // g_err after 10 words: Gayle error, the other 492 bytes stay verified
            read_block(4, C_RX | C_CRCRX);
            expect_rd(R_CMD, 16'h0002, 16'h0002, "crc_ok of LBA 4");
            gr_err_at = 10;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_RX2G);
            wait_idle(20000);
            gr_err_at = -1;
            if (g_req !== 1'b0) fail("g_req still high after g_err");
            expect_rd(R_CMD, 16'h01FF, 16'h0088, "STATUS after g_err (Gayle error)");
            expect_rd(R_IRQ, 16'h0009, 16'h0009, "IRQPEND done + error after g_err");
            expect_rd(R_MATCH, 16'hFFFF, 16'd20, "COUNT after g_err at word 10");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd492, "RXLVL after g_err at word 10");
            wr(R_LEN, 16'd492);
            wr(R_CMD, OP_RX2G);
            wait_idle(20000);
            expect_rd(R_CMD, 16'h01FF, 16'h0008, "STATUS after RX_TO_GAYLE of the other 492");
            check_gr_buf(4, 20, 246, "RX_TO_GAYLE of the other 492");
            crc_mode(1'b0);
            end_case;
        end

        // ---- a block with a CRC error (bit 0 of byte 511 flipped by the model)
        begin_case("t_crc_read_bad", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            crc_mode(1'b1);
            wr(R_CMD, OP_RXFL);
            card.err_rdcrc = card.rd_blk_n + 1;
            card.left_rdcrc = 1;
            read_block(5, C_RX | C_CRCRX);
            expect_rd(R_CMD, 16'h01F7, 16'h0000, "STATUS after a bad block (crc_ok 0, no error)");
            expect_rd(R_MATCH, 16'hFFFF, 16'd514, "COUNT");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd512, "RXLVL");
            wr(R_LEN, 16'd512);
            expect_refused(OP_RX2G, "RX_TO_GAYLE of a block with a CRC error");
            check_rx_block(5, 0, 510, "the bad block's bytes 0-509");
            expect_rd(R_DATAW, 16'hFFFF, {img[5 * 512 + 510], img[5 * 512 + 511] ^ 8'h01}, "bytes 510-511 (bit flipped)");
            crc_mode(1'b0);
            end_case;
        end

        // ---- read-ahead: bad block A then good block B in RX; A must not go to
        // Gayle; after RX_FLUSH + a good re-read it does.  Unverified bytes ahead
        // of a verified block keep it from Gayle too
        begin_case("t_refuse_readahead", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            crc_mode(1'b1);
            wr(R_CMD, OP_RXFL);
            card.err_rdcrc = card.rd_blk_n + 1;
            card.left_rdcrc = 1;
            send_cmdc(6'd18, 32'd40);
            expect_r1(8'h00, "CMD18");
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== 8'hFE) fail("no token for block A");
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_XFER | C_RX | C_CRCRX);
            wait_idle(200000);
            expect_rd(R_CMD, 16'h0002, 16'h0000, "crc_ok 0 for block A");
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== 8'hFE) fail("no token for block B");
            wr(R_CMD, OP_XFER | C_RX | C_CRCRX);
            wait_idle(200000);
            expect_rd(R_CMD, 16'h0002, 16'h0002, "crc_ok 1 for block B");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd1024, "RXLVL: A and B");
            n = gr_reqs;
            expect_refused(OP_RX2G, "RX_TO_GAYLE: bad A at the head, good B behind");
            wr(R_LEN, 16'd2);
            expect_refused(OP_RX2G, "RX_TO_GAYLE of 2 bytes of bad A");
            if (gr_reqs != n) fail("g_req for a refused RX_TO_GAYLE");
            cs_cycle(8'd2);             // ends the CMD18 stream
            wr(R_CMD, OP_RXFL);
            read_block(40, C_RX | C_CRCRX);
            expect_rd(R_CMD, 16'h0002, 16'h0002, "crc_ok of the re-read A");
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_RX2G);
            wait_idle(20000);
            expect_rd(R_CMD, 16'h01FF, 16'h0008, "STATUS after RX_TO_GAYLE of the re-read A");
            if (gr_reqs != n + 1 || gr_n != 256) fail("re-read A: not one g_req with 256 words");
            check_gr_buf(40, 0, 256, "re-read A at Gayle");
            // unverified bytes (a plain bit-5 XFER) ahead of a verified block
            wr(R_CMD, OP_RXFL);
            wr(R_LEN, 16'd2);
            wr(R_CMD, OP_XFER | C_RX);
            wait_idle(10000);
            read_block(41, C_RX | C_CRCRX);
            expect_rd(R_CMD, 16'h0002, 16'h0002, "crc_ok of LBA 41");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd514, "RXLVL 2 + 512");
            wr(R_LEN, 16'd512);
            expect_refused(OP_RX2G, "RX_TO_GAYLE: unverified bytes ahead of the block");
            wr(R_LEN, 16'd2);
            expect_refused(OP_RX2G, "RX_TO_GAYLE of the 2 unverified bytes");
            if (gr_reqs != n + 1) fail("g_req for a refused RX_TO_GAYLE");
            // poisoned: a bad block popped away still keeps the next good one
            // from Gayle until RX_FLUSH
            wr(R_CMD, OP_RXFL);
            card.err_rdcrc = card.rd_blk_n + 1;
            card.left_rdcrc = 1;
            read_block(42, C_RX | C_CRCRX);
            expect_rd(R_CMD, 16'h0002, 16'h0000, "crc_ok 0 for LBA 42");
            for (i = 0; i < 256; i = i + 1) rd(R_DATAW, q);
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RX empty after popping the bad block");
            read_block(43, C_RX | C_CRCRX);
            expect_rd(R_CMD, 16'h0002, 16'h0002, "crc_ok of LBA 43");
            wr(R_LEN, 16'd512);
            expect_refused(OP_RX2G, "RX_TO_GAYLE of a good block after a popped bad one");
            // poisoned: a good block AHEAD of a bad one is held back too
            wr(R_CMD, OP_RXFL);
            read_block(44, C_RX | C_CRCRX);
            expect_rd(R_CMD, 16'h0002, 16'h0002, "crc_ok of LBA 44");
            card.err_rdcrc = card.rd_blk_n + 1;
            card.left_rdcrc = 1;
            read_block(45, C_RX | C_CRCRX);
            expect_rd(R_CMD, 16'h0002, 16'h0000, "crc_ok 0 for LBA 45");
            wr(R_LEN, 16'd512);
            expect_refused(OP_RX2G, "RX_TO_GAYLE of a good block with a bad one behind (poisoned)");
            if (gr_reqs != n + 1) fail("g_req for a refused RX_TO_GAYLE");
            wr(R_CMD, OP_RXFL);
            crc_mode(1'b0);
            end_case;
        end

        // ---- CRC16 append on a write: the model (CRC on) checks it and answers
        // 05; a rejected block (SD_ERR_WRREJ) answers 0B and is not written
        begin_case("t_crc_write", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            crc_mode(1'b1);
            wr(R_CMD, OP_TXFL);
            write_block(20, 0);
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== 8'h05) begin $display("FAIL %0s: data response %h, want 05", cur, lastb); errors = errors + 1; end
            wait_op(OP_WNE, 8'h00, 16'd4);
            if (lastb !== 8'hFF) fail("busy did not end with FF");
            check_mem_pat(20, 0, "LBA 20 after the write");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd513, "TXLVL: token + block kept");
            wr(R_CMD, OP_TXCM);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after TX_COMMIT");
            card.err_wrrej = card.wr_blk_n + 1;
            card.left_wrrej = 1;
            write_block(21, 77);
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== 8'h0B) begin $display("FAIL %0s: data response %h, want 0B (WRREJ)", cur, lastb); errors = errors + 1; end
            per_bad = 0;
            for (i = 0; i < 512; i = i + 1) if (card.mem[21 * 512 + i] !== img[21 * 512 + i]) per_bad = per_bad + 1;
            if (per_bad) fail("LBA 21 written although rejected");
            wr(R_CMD, OP_TXFL);
            crc_mode(1'b0);
            end_case;
        end

        // ---- WAIT_NE $00 rides out a long card busy and ends at the first $FF
        begin_case("t_busy_wait", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            crc_mode(1'b1);
            wr(R_CMD, OP_TXFL);
            card.busy_n = 1500;
            write_block(22, 5);
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== 8'h05) fail("data response not 05");
            wait_op(OP_WNE, 8'h00, 16'd20);
            if (lastb !== 8'hFF) fail("busy wait did not end with FF");
            expect_rd(R_MATCH, 16'hFFFF, 16'd1501, "COUNT: 1500 busy bytes + the FF");
            expect_rd(R_CMD, 16'h00F5, 16'h0000, "STATUS after the busy wait (no timeout)");
            card.busy_n = 8;
            check_mem_pat(22, 5, "LBA 22 after the write");
            wr(R_CMD, OP_TXFL);
            crc_mode(1'b0);
            end_case;
        end

        // ---- TX keep / rewind / commit.  (a) TX_REWIND drops the prefetched next
        // byte.  (b) A rejected block is resent from TX: the new CMD24 is pushed
        // behind the kept block and sent, TX_REWIND goes back to the token, the
        // card gets identical 514 bytes (data + CRC); TX_COMMIT frees what was sent
        begin_case("t_tx_rewind", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            wr(R_CMD, OP_TXFL);
            push_cmd(6'd16, 32'h200);
            wr(R_LEN, 16'd3);
            wr(R_CMD, OP_XFER | C_TX);
            wait_idle(10000);
            wait_cycles(20);            // byte 4 prefetched by now
            cs_cycle(8'd2);             // the model drops the half command
            s0 = card.cmd_n;
            wr(R_CMD, OP_TXRW);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd6, "TXLVL after TX_REWIND");
            wr(R_LEN, 16'd6);
            wr(R_CMD, OP_XFER | C_TX);
            wait_idle(10000);
            if (card.cmd_n != s0 + 1 || card.cidx != 6'd16 || card.carg != 32'h200)
                fail("CMD16 not resent whole after TX_REWIND");
            expect_r1(8'h00, "CMD16 after the rewind");
            wr(R_CMD, OP_TXCM);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after TX_COMMIT");
            // (b)
            crc_mode(1'b1);
            card.err_wrrej = card.wr_blk_n + 1;
            card.left_wrrej = 1;
            write_block(23, 31);
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== 8'h0B) fail("first attempt not rejected with 0B");
            for (i = 0; i < 512; i = i + 1) expb[i] = card.wbuf[i];
            expb[512] = card.wrx[15:8]; expb[513] = card.wrx[7:0];
            expect_rd(R_TXLVL, 16'hFFFF, 16'd513, "TXLVL: token + block kept");
            push_cmd(6'd24, 32'd23);    // behind the kept block
            wr(R_LEN, 16'd6);
            wr(R_CMD, OP_XFER | C_TX);
            wait_idle(10000);
            expect_r1(8'h00, "CMD24 (retry)");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd519, "TXLVL: token + block + CMD24 kept");
            wr(R_CMD, OP_TXRW);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd519, "TXLVL after TX_REWIND");
            send_block;
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== 8'h05) fail("resent block not answered 05");
            wait_op(OP_WNE, 8'h00, 16'd4);
            per_bad = 0;
            for (i = 0; i < 512; i = i + 1) if (card.wbuf[i] !== expb[i]) per_bad = per_bad + 1;
            if (card.wrx !== {expb[512], expb[513]}) per_bad = per_bad + 1;
            if (per_bad) begin $display("FAIL %0s: resent block: %0d of the 514 bytes differ", cur, per_bad); errors = errors + 1; end
            check_mem_pat(23, 31, "LBA 23 after the resend");
            wr(R_CMD, OP_TXCM);         // token + block sent: freed; the CMD24 copy is unsent
            expect_rd(R_TXLVL, 16'hFFFF, 16'd6, "TXLVL after TX_COMMIT (CMD24 copy left)");
            wr(R_CMD, OP_TXFL);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after TX_FLUSH");
            crc_mode(1'b0);
            end_case;
        end

        // ---- a full TX and TX_COMMIT (Task 8: the registered full flag):
        // a commit with nothing sent leaves TX full, one after bytes were sent
        // frees exactly those (the prefetched byte stays) and pushes fit again
        begin_case("t_full_commit", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            wr(R_CMD, OP_TXFL);
            for (i = 0; i < 512; i = i + 1) wr(R_DATAW, 16'hFFFF);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1024, "TXLVL full");
            wr(R_CMD, OP_TXCM);         // nothing sent: still full
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1024, "TXLVL after TX_COMMIT with nothing sent");
            wr(R_DATAB, 16'h00FF);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1024, "TXLVL after a TXB into the full TX");
            expect_rd(R_CMD, 16'h0100, 16'h0100, "STATUS 8 after the TXB into the full TX");
            wr(R_LEN, 16'd4);
            wr(R_CMD, OP_XFER | C_TX);
            wait_idle(10000);
            wait_cycles(20);            // byte 5 prefetched by now
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1024, "TXLVL after sending 4 (kept)");
            wr(R_CMD, OP_TXCM);         // the 4 sent bytes freed
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1020, "TXLVL after TX_COMMIT of 4 sent bytes");
            wr(R_DATAW, 16'hFFFF);
            wr(R_DATAW, 16'hFFFF);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1024, "TXLVL after 4 bytes pushed again");
            expect_rd(R_CMD, 16'h0100, 16'h0000, "STATUS 8 clear: the 4 fitted");
            wr(R_DATAB, 16'h00FF);
            expect_rd(R_CMD, 16'h0100, 16'h0100, "STATUS 8 after one more byte");
            wr(R_CMD, OP_TXFL);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after TX_FLUSH");
            end_case;
        end

        // ---- a CMD in the cycle right after an op's end (Task 8 fix round 1):
        // the end's last effects reach the command checks only a cycle later,
        // so the command is refused there (fin_d).
        // (a) RX_TO_GAYLE LEN 384 of a 512-byte verified block ends by g_err
        //     on word 64, popped in that cycle: verified 384 before, 382
        //     after.  RX_TO_GAYLE LEN 384 at once: refused (with verified
        //     still at 384 in the registers it would start on 382 bytes).
        // (b) GAYLE_TO_TX LEN 2 into TXLVL 1021, g_ack in the cycle after the
        //     word: its second byte goes in during the end cycle, TXLVL 1023
        //     a cycle later.  GAYLE_TO_TX LEN 2 at once: refused (the
        //     registers would still show 1022 + 2 <= 1024).
        // Both CMDs again later: refused for the plain reason.  Mutant
        // SDC_MUT_NOFIND (no fin_d) must fail this case.
        begin_case("t_cmd_after_end", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            crc_mode(1'b1);
            wr(R_CMD, OP_RXFL);
            wr(R_CMD, OP_TXFL);
            read_block(5, C_RX | C_CRCRX);
            expect_rd(R_CMD, 16'h0002, 16'h0002, "crc_ok of LBA 5");
            n = gr_reqs;
            gr_errpop_at = 64;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd384);
            wr(R_CMD, OP_RX2G);
            cmd_after_end(OP_RX2G);
            wait_idle(20000);
            gr_errpop_at = -1;
            if (gr_reqs != n + 1) fail("(a) the CMD in the cycle after the end started an op");
            expect_rd(R_CMD, 16'h00C1, 16'h00C0, "(a) STATUS: Gayle error, then refused");
            expect_rd(R_MATCH, 16'hFFFF, 16'd130, "(a) COUNT: 65 words, the last with g_err");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd382, "(a) RXLVL 382");
            check_gr_buf(5, 0, 65, "(a) the 65 words taken");
            expect_refused(OP_RX2G, "(a) RX_TO_GAYLE LEN 384 with 382 verified");
            wr(R_CMD, OP_RXFL);
            crc_mode(1'b0);
            // (b)
            wr(R_CMD, OP_TXFL);
            for (i = 0; i < 510; i = i + 1) wr(R_DATAW, 16'hFFFF);
            wr(R_DATAB, 16'h00FF);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1021, "(b) TXLVL 1021");
            gr_src[0] = 16'h1234;
            gr_space = 20; gr_ack_space = 1;
            n = gr_reqs;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd2);
            wr(R_CMD, OP_G2TX);
            cmd_after_end(OP_G2TX);
            wait_idle(20000);
            gr_space = 4; gr_ack_space = 0;
            if (gr_reqs != n + 1) fail("(b) the CMD in the cycle after the end started an op");
            expect_rd(R_CMD, 16'h00C1, 16'h0040, "(b) STATUS: good end, then refused");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1023, "(b) TXLVL 1023");
            expect_refused(OP_G2TX, "(b) GAYLE_TO_TX LEN 2 into TXLVL 1023");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1023, "(b) TXLVL still 1023");
            wr(R_CMD, OP_TXFL);
            end_case;
        end

        // ---- wait timeout: WAIT_EQ $00 on a card sending $FF
        begin_case("t_wait_timeout", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            wr(R_CMD, OP_RXFL);
            wr(R_IRQ, 16'h001F);
            wr(R_MATCH, 16'h0000);
            wr(R_TIMEOUT, 16'd2);
            t0 = cyc;
            wr(R_CMD, OP_WEQ);
            wr(R_TIMEOUT, 16'd9);       // ignored while busy
            expect_rd(R_TIMEOUT, 16'hFFFF, 16'd2, "TIMEOUT written while busy (ignored)");
            wait_idle(3 * 16384 + 2000);
            n = cyc - t0;
            rd(R_CMD, q);
            if (q[0]) begin wr(R_CMD, OP_ABORT); wait_idle(1000); end   // clean up after a failure
            if (n < 2 * 16384 || n > 2 * 16384 + 300) begin
                $display("FAIL %0s: TIMEOUT 2 ended after %0d cycles, want 32768..+300", cur, n); errors = errors + 1;
            end
            if ((q & 16'h00F7) !== 16'h0004) begin
                $display("FAIL %0s: STATUS %h after the timeout, want bit 2 only", cur, q); errors = errors + 1;
            end
            expect_rd(R_IRQ, 16'h0009, 16'h0009, "IRQPEND done + error after the timeout");
            expect_rd(R_LEN, 16'h00FF, 16'h00FF, "LAST FF");
            // TIMEOUT 0 = 1 unit
            wr(R_IRQ, 16'h001F);
            wr(R_TIMEOUT, 16'd0);
            t0 = cyc;
            wr(R_CMD, OP_WEQ);
            wait_idle(2 * 16384 + 2000);
            n = cyc - t0;
            rd(R_CMD, q);
            if (q[0]) begin wr(R_CMD, OP_ABORT); wait_idle(1000); end
            if (n < 16384 || n > 16384 + 300) begin
                $display("FAIL %0s: TIMEOUT 0 ended after %0d cycles, want 16384..+300", cur, n); errors = errors + 1;
            end
            if (q[2] !== 1'b1) fail("no timeout bit for TIMEOUT 0");
            // a match ends at once: WAIT_EQ $FF, one byte, no timeout
            wr(R_MATCH, 16'h00FF);
            wr(R_TIMEOUT, 16'd1);
            wr(R_CMD, OP_WEQ);
            wait_idle(1000);
            expect_rd(R_CMD, 16'h00F7, 16'h0000, "STATUS after WAIT_EQ FF");
            expect_rd(R_MATCH, 16'hFFFF, 16'd1, "COUNT after WAIT_EQ FF");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "nothing into RX while waiting");
            wr(R_IRQ, 16'h001F);
            end_case;
        end

        // ---- ABORT: a TX-sourced XFER waiting on an empty TX; a running XFER (SCK
        // stops at a byte boundary within one byte, CS untouched); a wait; idle
        begin_case("t_abort", run_it);
        if (run_it) begin
            cs_cycle(8'h10);            // 272 cycles per byte
            wr(R_CMD, OP_TXFL);
            wr(R_CMD, OP_RXFL);
            wr(R_IRQ, 16'h001F);
            s0 = sck_rises;
            wr(R_LEN, 16'd4);
            wr(R_CMD, OP_XFER | C_TX);
            wait_cycles(200);
            expect_rd(R_CMD, 16'h0001, 16'h0001, "busy waiting for TX");
            wr(R_CMD, OP_ABORT);
            wait_idle(100);
            expect_rd(R_CMD, 16'h01F7, 16'h0010, "STATUS aborted");
            expect_rd(R_MATCH, 16'hFFFF, 16'd0, "COUNT 0");
            expect_rd(R_IRQ, 16'h0009, 16'h0001, "IRQPEND done, no error");
            if (sck_rises != s0) fail("SCK moved for a paused XFER");
            // a running XFER
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd1000);
            s0 = sck_rises;
            wr(R_CMD, OP_XFER | C_RX);
            wait_cycles(2900);
            t0 = sck_rises;
            wr(R_CMD, OP_ABORT);
            wait_idle(2000);
            rd(R_MATCH, q);
            n = q;
            if (n < 5 || n > 20) begin $display("FAIL %0s: COUNT %0d after the abort, want 5..20", cur, n); errors = errors + 1; end
            if (sck_rises - s0 != n * 8) begin
                $display("FAIL %0s: %0d SCK rises for COUNT %0d: not stopped at a byte boundary", cur, sck_rises - s0, n); errors = errors + 1;
            end
            if (sck_rises - t0 > 8) begin
                $display("FAIL %0s: %0d SCK rises after ABORT, more than one byte", cur, sck_rises - t0); errors = errors + 1;
            end
            if (sd_cs_n !== 1'b0) fail("CS released by ABORT");
            expect_rd(R_CMD, 16'h01F7, 16'h0010, "STATUS aborted (running XFER)");
            expect_rd(R_RXLVL, 16'hFFFF, n, "RXLVL = COUNT");
            expect_rd(R_IRQ, 16'h0009, 16'h0001, "IRQPEND done, no error (running XFER)");
            s0 = sck_rises;
            wait_cycles(2000);
            if (sck_rises != s0) fail("SCK moved after the abort");
            // ABORT while idle: a completed no-op, STATUS and COUNT kept
            wr(R_IRQ, 16'h001F);
            wr(R_CMD, OP_ABORT);
            expect_rd(R_CMD, 16'h01F7, 16'h0010, "STATUS kept by an idle ABORT");
            expect_rd(R_MATCH, 16'hFFFF, n, "COUNT kept by an idle ABORT");
            expect_rd(R_IRQ, 16'h0009, 16'h0001, "IRQPEND done for an idle ABORT");
            // a wait
            wr(R_CMD, OP_RXFL);
            wr(R_MATCH, 16'h0000);
            wr(R_TIMEOUT, 16'd100);
            wr(R_CMD, OP_WEQ);
            wait_cycles(1000);
            expect_rd(R_CMD, 16'h0001, 16'h0001, "busy waiting");
            wr(R_CMD, OP_ABORT);
            wait_idle(400);
            expect_rd(R_CMD, 16'h01F7, 16'h0010, "STATUS aborted wait (no timeout)");
            // FIFO misuse (STATUS 8) is not cleared by ABORT
            rd(R_DATAW, q);
            wr(R_CMD, OP_ABORT);
            expect_rd(R_CMD, 16'h0100, 16'h0100, "STATUS 8 kept by ABORT");
            wr(R_CMD, OP_RXFL);
            wr(R_IRQ, 16'h001F);
            end_case;
        end

        // ---- GAYLE_TO_TX: g_err and ABORT roll TX back to its state at the op's
        // start; the CPU data port is locked during a Gayle op; a full transfer
        // then goes to the card with CRC16 (proves no stray bytes in TX)
        begin_case("t_gayle_tx", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            crc_mode(1'b1);
            wr(R_CMD, OP_TXFL);
            wr(R_CMD, OP_RXFL);
            for (i = 0; i < 256; i = i + 1) gr_src[i] = {wpat(2 * i + 9), wpat(2 * i + 10)};
            push_cmd(6'd24, 32'd30);
            wr(R_DATAB, 16'h00FE);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd7, "TXLVL: CMD24 + token");
            n = gr_reqs;
            // g_err at word 100
            gr_err_at = 100;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_G2TX);
            wait_idle(20000);
            gr_err_at = -1;
            if (gr_reqs != n + 1 || gr_dir !== 1'b0 || gr_port !== 1'b0 || gr_words != 256) fail("GAYLE_TO_TX: not dir 0 port 0 256 words");
            expect_rd(R_CMD, 16'h01FF, 16'h0088, "STATUS Gayle error");
            expect_rd(R_IRQ, 16'h0009, 16'h0009, "IRQPEND done + error after g_err");
            expect_rd(R_MATCH, 16'hFFFF, 16'd200, "COUNT 200 at g_err");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd7, "TXLVL rolled back after g_err");
            // g_ack after 10 of 256 words: a Gayle error too, rolled back
            gr_ack_at = 10;
            wr(R_IRQ, 16'h001F);
            wr(R_CMD, OP_G2TX);
            wait_idle(20000);
            gr_ack_at = -1;
            expect_rd(R_CMD, 16'h01FF, 16'h0088, "STATUS Gayle error after an early g_ack");
            expect_rd(R_IRQ, 16'h0009, 16'h0009, "IRQPEND done + error after an early g_ack");
            expect_rd(R_MATCH, 16'hFFFF, 16'd20, "COUNT 20 at the early g_ack");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd7, "TXLVL rolled back after an early g_ack");
            // ABORT while the bridge stalls
            gr_stall_at = 50;
            wr(R_IRQ, 16'h001F);
            wr(R_CMD, OP_G2TX);
            wait_cycles(400);
            expect_rd(R_CMD, 16'h0001, 16'h0001, "busy in the stalled Gayle op");
            if (g_req !== 1'b1) fail("g_req low in the stalled Gayle op");
            wr(R_CMD, OP_ABORT);
            wait_idle(100);
            gr_stall_at = -1;
            if (g_req !== 1'b0) fail("g_req not dropped by ABORT");
            expect_rd(R_CMD, 16'h01FF, 16'h0018, "STATUS aborted");
            expect_rd(R_IRQ, 16'h0009, 16'h0001, "IRQPEND done, no error after ABORT");
            expect_rd(R_MATCH, 16'hFFFF, 16'd100, "COUNT 100 at the abort");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd7, "TXLVL rolled back after ABORT");
            // CPU data port locked while the op runs
            wr(R_LEN, 16'd2);
            wr(R_CMD, OP_XFER | C_RX);  // 2 bytes in RX
            wait_idle(1000);
            gr_space = 40;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_G2TX);
            wait_cycles(200);
            wr(R_DATAW, 16'h1234);
            expect_rd(R_DATAW, 16'hFFFF, 16'h0000, "RXW during a Gayle op");
            wait_idle(20000);
            gr_space = 4;
            expect_rd(R_CMD, 16'h01FF, 16'h0108, "STATUS 8 (locked data port), op ended normally");
            expect_rd(R_IRQ, 16'h0009, 16'h0009, "IRQPEND done + error (misuse)");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd519, "TXLVL: CMD24 + token + 512, the TXW dropped");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd2, "RXLVL: the RXW popped nothing");
            wr(R_CMD, OP_RXFL);
            // the block to the card
            wr(R_LEN, 16'd6);
            wr(R_CMD, OP_XFER | C_TX);
            wait_idle(10000);
            expect_r1(8'h00, "CMD24");
            send_block;
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== 8'h05) begin $display("FAIL %0s: data response %h, want 05", cur, lastb); errors = errors + 1; end
            wait_op(OP_WNE, 8'h00, 16'd4);
            check_mem_pat(30, 9, "LBA 30 = the Gayle words");
            wr(R_CMD, OP_TXCM);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after TX_COMMIT");
            crc_mode(1'b0);
            end_case;
        end

        // ---- CRC16 known answers, independent of the model's CRC code: 512 x
        // $FF (bit 6 without bit 4) -> 7FA1; "123456789" (bits 4 + 6) -> 31C3
        // (the CRC-16/XMODEM check value).  CS high: the card ignores it all
        begin_case("t_crc_known", run_it);
        if (run_it) begin
            set_cs(1'b0, 8'd2);
            wr(R_CMD, OP_TXFL);
            mo_n = 0; mo_bits = 0;
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_XFER | C_CRCTX);
            wait_idle(100000);
            expect_rd(R_MATCH, 16'hFFFF, 16'd514, "COUNT 512 + 2");
            per_bad = 0;
            for (i = 0; i < 512; i = i + 1) if (mo_log[i] !== 8'hFF) per_bad = per_bad + 1;
            if (mo_n != 514 || per_bad) begin $display("FAIL %0s: %0d MOSI bytes, %0d not FF", cur, mo_n, per_bad); errors = errors + 1; end
            if ({mo_log[512], mo_log[513]} !== 16'h7FA1) begin
                $display("FAIL %0s: CRC16 of 512 x FF sent as %h%h, want 7FA1", cur, mo_log[512], mo_log[513]); errors = errors + 1;
            end
            wr(R_DATAW, 16'h3132); wr(R_DATAW, 16'h3334); wr(R_DATAW, 16'h3536); wr(R_DATAW, 16'h3738);
            wr(R_DATAB, 16'h0039);
            mo_n = 0; mo_bits = 0;
            wr(R_LEN, 16'd9);
            wr(R_CMD, OP_XFER | C_TX | C_CRCTX);
            wait_idle(10000);
            if (mo_n != 11 || mo_log[0] !== 8'h31 || mo_log[8] !== 8'h39 || {mo_log[9], mo_log[10]} !== 16'h31C3) begin
                $display("FAIL %0s: \"123456789\": %0d bytes, CRC sent as %h%h, want 31C3", cur, mo_n, mo_log[9], mo_log[10]); errors = errors + 1;
            end
            wr(R_CMD, OP_TXFL);
            end_case;
        end

        // ---- RX_TO_GAYLE ends: a bridge honouring g_wvalid at the fastest
        // rate; one pulsing g_wnext too fast (Gayle error, the word not taken);
        // ABORT and card gone mid-block; pulses beyond g_words ignored (both
        // directions).  Each time the rest of the block is still verified
        begin_case("t_gayle_rx_ends", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            crc_mode(1'b1);
            wr(R_CMD, OP_RXFL);
            // fastest, by g_wvalid
            read_block(60, C_RX | C_CRCRX);
            gr_space = 1;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd512);
            t0 = cyc;
            wr(R_CMD, OP_RX2G);
            wait_idle(20000);
            n = cyc - t0;
            gr_space = 4;
            expect_rd(R_CMD, 16'h01FF, 16'h0008, "STATUS after RX_TO_GAYLE by g_wvalid");
            expect_rd(R_IRQ, 16'h0009, 16'h0001, "IRQPEND done only");
            if (gr_n != 256) fail("not 256 words by g_wvalid");
            check_gr_buf(60, 0, 256, "words taken by g_wvalid");
            $display("     %0s: 256 words by g_wvalid in %0d cycles (incl. the CMD write and polling)", cur, n);
            // too fast, blind: the 2nd g_wnext finds g_wvalid low
            read_block(61, C_RX | C_CRCRX);
            gr_space = 2; gr_usevalid = 0;
            wr(R_IRQ, 16'h001F);
            wr(R_CMD, OP_RX2G);
            wait_idle(20000);
            gr_space = 4; gr_usevalid = 1;
            if (g_req !== 1'b0) fail("g_req still high after a g_wnext without g_wvalid");
            expect_rd(R_CMD, 16'h01FF, 16'h0088, "STATUS Gayle error after a g_wnext without g_wvalid");
            expect_rd(R_IRQ, 16'h0009, 16'h0009, "IRQPEND done + error");
            expect_rd(R_MATCH, 16'hFFFF, 16'd2, "COUNT 2: the early word not taken");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd510, "RXLVL 510");
            wr(R_LEN, 16'd510);
            wr(R_CMD, OP_RX2G);
            wait_idle(20000);
            expect_rd(R_CMD, 16'h01FF, 16'h0008, "STATUS: the other 510 still verified");
            check_gr_buf(61, 2, 255, "the other 510");
            // ABORT while the bridge stalls
            read_block(62, C_RX | C_CRCRX);
            gr_stall_at = 40;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_RX2G);
            wait_cycles(400);
            wr(R_CMD, OP_ABORT);
            wait_idle(100);
            wait_cycles(50);
            gr_stall_at = -1;
            if (g_req !== 1'b0) fail("g_req not dropped by ABORT (dir 1)");
            if (gr_n != 40) fail("words taken after the stall / ABORT");
            expect_rd(R_CMD, 16'h01FF, 16'h0018, "STATUS aborted (dir 1)");
            expect_rd(R_IRQ, 16'h0009, 16'h0001, "IRQPEND done only (dir 1 ABORT)");
            expect_rd(R_MATCH, 16'hFFFF, 16'd80, "COUNT 80");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd432, "RXLVL 432");
            wr(R_LEN, 16'd432);
            wr(R_CMD, OP_RX2G);
            wait_idle(20000);
            expect_rd(R_CMD, 16'h01FF, 16'h0008, "STATUS: the other 432 still verified");
            check_gr_buf(62, 80, 216, "the other 432");
            // card gone (synchronised level, shorter than the debounce)
            read_block(63, C_RX | C_CRCRX);
            gr_stall_at = 30;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_RX2G);
            wait_cycles(300);
            sd_cd_n <= 1'b1;
            wait_cycles(10);
            sd_cd_n <= 1'b0;
            wait_cycles(20);
            gr_stall_at = -1;
            if (g_req !== 1'b0) fail("g_req not dropped on card absence (dir 1)");
            if (gr_n != 30) fail("words taken after card absence");
            expect_rd(R_CMD, 16'h01FF, 16'h0028, "STATUS card gone (dir 1), card present (debounced)");
            expect_rd(R_IRQ, 16'h0019, 16'h0009, "IRQPEND done + error, no change IRQ");
            expect_rd(R_MATCH, 16'hFFFF, 16'd60, "COUNT 60");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd452, "RXLVL 452");
            wait_cycles(200);
            wr(R_LEN, 16'd452);
            wr(R_CMD, OP_RX2G);
            wait_idle(20000);
            expect_rd(R_CMD, 16'h01FF, 16'h0008, "STATUS: the other 452 still verified");
            check_gr_buf(63, 60, 226, "the other 452");
            // pulses beyond g_words: dir 1 (RX holds more than LEN)
            read_block(64, C_RX | C_CRCRX);
            gr_extra = 3;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd256);
            wr(R_CMD, OP_RX2G);
            wait_idle(20000);
            expect_rd(R_CMD, 16'h01FF, 16'h0008, "STATUS after 3 extra g_wnext");
            expect_rd(R_MATCH, 16'hFFFF, 16'd256, "COUNT 256 with 3 extra g_wnext");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd256, "RXLVL 256: extra g_wnext took nothing");
            gr_extra = 0;
            wr(R_CMD, OP_RX2G);
            wait_idle(20000);
            check_gr_buf(64, 256, 128, "the second half");
            // pulses beyond g_words: dir 0
            wr(R_CMD, OP_TXFL);
            gr_extra = 3;
            wr(R_LEN, 16'd64);
            wr(R_CMD, OP_G2TX);
            wait_idle(20000);
            gr_extra = 0;
            expect_rd(R_CMD, 16'h01FF, 16'h0008, "STATUS after 3 extra g_rvalid");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd64, "TXLVL 64: extra g_rvalid pushed nothing");
            wr(R_CMD, OP_TXFL);
            wr(R_CMD, OP_RXFL);
            crc_mode(1'b0);
            end_case;
        end

        // ---- card gone (last case: the model's card stays removed).  A Gayle
        // op ends on the synchronised level (a 10-cycle low on sd_cd_n, shorter
        // than the debounce) with TX rolled back; then the card is pulled in
        // the middle of a CRC-checked block: the op ends at once, SCK stops
        begin_case("t_cardgone_midblock", run_it);
        if (run_it) begin
            cs_cycle(8'd2);
            wr(R_CMD, OP_TXFL);
            wr(R_CMD, OP_RXFL);
            wr(R_DATAB, 16'h0055);
            gr_stall_at = 20;
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_G2TX);
            wait_cycles(150);
            sd_cd_n <= 1'b1;
            wait_cycles(10);
            sd_cd_n <= 1'b0;
            if (g_req !== 1'b0) fail("g_req not dropped on card absence");
            gr_stall_at = -1;
            expect_rd(R_CMD, 16'h01FF, 16'h0028, "STATUS card gone (Gayle op), card still present (debounced)");
            expect_rd(R_IRQ, 16'h0019, 16'h0009, "IRQPEND done + error, no card-detect change");
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1, "TXLVL rolled back");
            wr(R_CMD, OP_TXFL);
            wait_cycles(200);
            // the card pulled mid-block
            cs_cycle(8'd4);             // 80 cycles per byte
            crc_mode(1'b1);
            wr(R_CMD, OP_RXFL);
            send_cmdc(6'd17, 32'd50);
            expect_r1(8'h00, "CMD17");
            wait_op(OP_WNE, 8'hFF, 16'd1);
            if (lastb !== 8'hFE) fail("no data token");
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd512);
            wr(R_CMD, OP_XFER | C_RX | C_CRCRX);
            wait_cycles(15000);
            card.remove_card;
            sd_cd_n <= 1'b1;
            wait_cycles(6);
            s0 = sck_rises;
            wait_cycles(1000);
            if (sck_rises != s0) fail("SCK still running after the card left");
            if (sd_sck !== 1'b0) fail("SCK not low after the card left");
            expect_rd(R_CMD, 16'h01F7, 16'h0020, "STATUS card gone (not busy, crc_ok 0)");
            expect_rd(R_IRQ, 16'h0009, 16'h0009, "IRQPEND done + error");
            rd(R_MATCH, q);
            n = q;
            if (n < 100 || n > 400) begin $display("FAIL %0s: COUNT %0d at the cut, want 100..400", cur, n); errors = errors + 1; end
            expect_rd(R_RXLVL, 16'hFFFF, n, "RXLVL = COUNT");
            expect_rd(R_CMD, 16'h0008, 16'h0000, "card absent (debounced)");
            expect_rd(R_IRQ, 16'h0010, 16'h0010, "card-detect change IRQ");
            wr(R_LEN, 16'd2);
            expect_refused(OP_RX2G, "RX_TO_GAYLE of the cut block");
            // with the card absent an op ends at once
            wr(R_IRQ, 16'h001F);
            wr(R_LEN, 16'd4);
            s0 = sck_rises;
            wr(R_CMD, OP_XFER);
            wait_idle(100);
            expect_rd(R_CMD, 16'h01F7, 16'h0020, "STATUS card gone for an op started without a card");
            if (sck_rises != s0) fail("SCK ran with the card absent");
            end_case;
        end

        $display("=== CMD strobes checked against tx_room_r / rx_ready_r: %0d (%0d in the cycle right after an op's end)",
                 n_cmd_chk, n_cmd_late);
        if (errors == 0) $display("=== PASS tb_sdcard_spi");
        else $display("=== FAIL tb_sdcard_spi (%0d errors)", errors);
        $finish;
    end
endmodule
