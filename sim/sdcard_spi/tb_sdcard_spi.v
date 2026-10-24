`timescale 1ns/1ps
// Unit bench of rtl/host/sdcard_spi.v (the SD card SPI peripheral) with the
// card model sim/common/sd_spi_model.v (CRC checking off, as at its start).
// Run by sim/sdcard_spi/run.sh (Verilator leg + iverilog X-check leg).
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
    localparam ACC = 4;                 // cycles per register access (clk_28 ack: >= 4)
    localparam GAP = 4;                 // idle cycles between accesses
    localparam integer WATCHDOG_CYC = 3000000;

    // register offsets (byte address - 0xFFFFFF00)
    localparam [5:0] R_DATAW = 6'h00, R_DATAB = 6'h04, R_RXLVL = 6'h08, R_TXLVL = 6'h0C,
                     R_CMD = 6'h10, R_LEN = 6'h14, R_MATCH = 6'h18, R_IRQ = 6'h1C,
                     R_CFG = 6'h20, R_TIMEOUT = 6'h24, R_IRQEN = 6'h28, R_WMARK = 6'h2C;
    localparam [15:0] OP_XFER = 16'h1, OP_RXFL = 16'h8, OP_TXFL = 16'h9,
                      C_TX = 16'h10, C_RX = 16'h20, C_CRCTX = 16'h40, C_CRCRX = 16'h80;

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

    sdcard_spi #(.VERSION(16'h5D01), .CD_DEBOUNCE_LOG2(6)) dut (
        .clk(clk), .reset(reset),
        .reg_wstb(reg_wstb), .reg_rstb(reg_rstb), .reg_addr(reg_addr),
        .reg_d(reg_d), .reg_q(reg_q), .irq(irq),
        .sd_sck(sd_sck), .sd_cs_n(sd_cs_n), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .sd_cd_n(sd_cd_n),
        .g_req(g_req), .g_dir(g_dir), .g_port(g_port), .g_words(g_words),
        .g_ack(1'b0), .g_err(1'b0), .g_wdata(g_wdata), .g_wnext(1'b0),
        .g_rdata(16'h0000), .g_rvalid(1'b0));

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
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after the XFER");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after a TX-only XFER");
            expect_rd(R_MATCH, 16'hFFFF, 16'd6, "COUNT");
            expect_rd(R_IRQ, 16'h0001, 16'h0001, "IRQPEND op done");
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
            wr(R_CMD, OP_XFER | C_TX);  // 16 left: <= the mark
            wait_idle(100000);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd16, "TXLVL after sending 2");
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
            for (i = 0; i < 513; i = i + 1) wr(R_DATAW, i);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd1024, "TXLVL after 1026 bytes pushed");
            wr(R_CMD, OP_TXFL);
            expect_rd(R_TXLVL, 16'hFFFF, 16'd0, "TXLVL after TX_FLUSH of a full FIFO");
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
            expect_rd(R_DATAW, 16'hFFFF, 16'h0000, "RXW on an empty RX");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after RXW on empty");
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
            expect_rd(R_DATAW, 16'hFFFF, 16'hFF00, "RXW with one byte in RX");
            expect_rd(R_RXLVL, 16'hFFFF, 16'd0, "RXLVL after it");
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
            wr(R_CMD, OP_XFER | C_CRCRX);
            expect_rd(R_CMD, 16'h00C1, 16'h0040, "STATUS after XFER with bit 7 (CRC check, Task 6)");
            wr(R_CMD, OP_XFER | C_CRCTX);
            expect_rd(R_CMD, 16'h00C1, 16'h0040, "STATUS after XFER with bit 6 (CRC append, Task 6)");
            if (sck_rises != n) fail("SCK moved for a refused op");
            set_cs(1'b1, 8'h10);
            wr(R_LEN, 16'd40);
            wr(R_CMD, OP_XFER);
            wr(R_LEN, 16'd3);           // ignored while busy
            wr(R_CMD, OP_XFER);         // refused, the running op goes on
            expect_rd(R_CMD, 16'h00C1, 16'h0041, "STATUS: busy and refused");
            wait_idle(100000);
            expect_rd(R_MATCH, 16'hFFFF, 16'd40, "COUNT of the op that was running");
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

        if (errors == 0) $display("=== PASS tb_sdcard_spi");
        else $display("=== FAIL tb_sdcard_spi (%0d errors)", errors);
        $finish;
    end
endmodule
