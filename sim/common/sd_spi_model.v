`timescale 1ns/1ps
// SD card, SPI mode 0, SDHC (block addressing) -- simulation model.
// Verilog-2005 only; runs in iverilog and xsim.  See tools/sim/README.md.
//
// Plusargs: +SD_IMG=<raw image>   loaded at time 0 (rest of the card = 0); a
//                                 file that cannot be opened ends the run
//                                 at once ("=== FAIL ..."); paths up to
//                                 1024 characters
//           +SD_SAVE=<file>       written by the task save_image (the bench
//                                 calls it before $finish)
//           +SD_TOKEN_DLY=<n>     0xFF bytes before every data token (4)
//           +SD_BUSY=<n>          0x00 busy bytes after a write / CMD12 (8)
//           +SD_NCR=<n>           0xFF bytes between a command and its R1 (1)
//           +SD_INIT_POLLS=<n>    ACMD41 polls that answer "idle" (2)
//           +SD_LOG=1             one line per command
//           Error injection (n counts events from 1 at time 0; the n-th
//           event and the k-1 after it fail, k = +SD_ERR_<kind>_CNT, 1 by
//           default; each failing event uses up one of the k, so the
//           injection ends after k failures):
//           +SD_ERR_RDCRC=<n>     the n-th CMD17/CMD18 data block the host
//                                 receives has bit 0 of its last data byte
//                                 flipped (CRC16 of the true data: a
//                                 mismatch; the card's data unchanged).  A
//                                 block counts when its last data byte
//                                 leaves the card: one cut before that
//                                 (CMD12, CS high; e.g. the CMD18 block in
//                                 flight when CMD12 arrives) is neither
//                                 counted nor corrupted
//           +SD_ERR_WRREJ=<n>     the n-th data block written (CMD24/CMD25,
//                                 every block the card takes in, whatever
//                                 else happens to it) gets data response 0B
//                                 (CRC error), not written
//           +SD_ERR_WRFAIL=<n>    the same with 0D (write error), not written
//                                 (on a block WRREJ also hits: WRREJ wins,
//                                 WRFAIL's count is not used up)
//           +SD_ERR_NORESP=<n>    the n-th command (every 6-byte command
//                                 frame, CMD0 included) gets no response and
//                                 has no effect
//           +SD_ERR_CMDCRC=<n>    the n-th command (same count) gets R1 08
//                                 (09 while idle) and is not executed, as
//                                 for a bad CRC7, with or without CMD59
//                                 (on a command NORESP also hits: NORESP wins)
//           +SD_ERR_<kind>_CNT=<k>  (RDCRC, WRREJ, WRFAIL, NORESP, CMDCRC)
//                                 k consecutive failures (1)
//
// CRC: every data block sent (CMD17, CMD18, CMD9, ACMD22) carries its real
// CRC16 (CCITT x^16+x^12+x^5+1, init 0).  CMD59 with arg bit 0 = 1 turns
// checking on (CMD0 and CMD59 arg bit 0 = 0 turn it off; off at start, so
// benches that send dummy CRCs are unaffected): a command whose CRC7 (byte
// 5 bits 7:1) does not match gets R1 08 (| idle) and is not executed; a
// written block whose CRC16 does not match gets data response 0B and is not
// written.  Data responses: 05 (written, then +SD_BUSY busy bytes), 0B (no
// busy), 0D (busy).  In a CMD25, after a 0B/0D every further block until
// the stop token gets the same response and is not written.
// ACMD22: R1, then a data block of 4 bytes, big-endian, the number of blocks
// written with 05 by the last CMD25, and its CRC16.  CMD13: R2 = R1, 00.
// Task remove_card (call hierarchically, e.g. tb.card.remove_card): the
// card is gone for the rest of the run -- MISO stays 1, nothing it receives
// is acted on, nothing is written.
module sd_spi_model #(parameter IMG_SECTORS = 65536)
    (input cs_n, input sck, input mosi, output reg miso);

    localparam MEMSZ = IMG_SECTORS * 512;
    localparam [21:0] CSIZE = IMG_SECTORS / 1024 - 1;   // CSD v2 C_SIZE
    localparam QSZ   = 4096;            // tx queue (power of two)

    reg [7:0] mem [0:MEMSZ-1];
    reg [7:0] q   [0:QSZ-1];            // bytes still to be sent
    integer   qh, qt;                   // head (pop) / tail (push)
    reg [7:0] wbuf [0:511];

    reg       qm  [0:QSZ-1];            // 1: last data byte of a CMD17/CMD18 block
    integer tok_dly, busy_n, ncr, init_polls, log_on;
    integer err_rdcrc, err_wrrej, err_wrfail, err_noresp, err_cmdcrc;
    integer left_rdcrc, left_wrrej, left_wrfail, left_noresp, left_cmdcrc;   // failures still to come
    reg [8*1024-1:0] imgname, savename;   // plusarg paths, up to 1024 characters
    integer fd, k, nread;

    // SPI shifter
    reg [7:0] rx;
    reg [7:0] txb;
    integer   bitcnt;

    // command parser
    integer   cmdcnt;
    reg [7:0] cmdb [0:5];
    reg [5:0] cidx;
    reg [31:0] carg;
    reg       app_cmd, idle, ready;
    integer   polls;

    // read / write state
    reg       rd_multi;
    integer   rd_lba;
    integer   wstate;                   // 0 none, 1 token, 2 data, 3 crc
    reg       wmulti;
    integer   wlba, wcnt;

    // CRC, error injection, card removal
    reg       crc_on;                   // CMD59
    reg [15:0] wcrc;                    // CRC16 of the block being received
    reg [15:0] wrx;                     // its CRC bytes as received
    reg [7:0] werr;                     // CMD25: 0, or the error response that stopped it
    reg [7:0] wresp, winj;
    integer   wr_ok;                    // blocks written with 05 by the last CMD25 (ACMD22)
    integer   cmd_n, rd_blk_n, wr_blk_n;   // commands / read blocks / written blocks so far
    reg       gone;                     // remove_card

    initial begin
        tok_dly = 4; busy_n = 8; ncr = 1; init_polls = 2; log_on = 0;
        if ($value$plusargs("SD_TOKEN_DLY=%d", tok_dly)) ;
        if ($value$plusargs("SD_BUSY=%d", busy_n)) ;
        if ($value$plusargs("SD_NCR=%d", ncr)) ;
        if ($value$plusargs("SD_INIT_POLLS=%d", init_polls)) ;
        if ($value$plusargs("SD_LOG=%d", log_on)) ;
        err_rdcrc = 0; err_wrrej = 0; err_wrfail = 0; err_noresp = 0; err_cmdcrc = 0;
        left_rdcrc = 1; left_wrrej = 1; left_wrfail = 1; left_noresp = 1; left_cmdcrc = 1;
        if ($value$plusargs("SD_ERR_RDCRC=%d", err_rdcrc)) ;
        if ($value$plusargs("SD_ERR_WRREJ=%d", err_wrrej)) ;
        if ($value$plusargs("SD_ERR_WRFAIL=%d", err_wrfail)) ;
        if ($value$plusargs("SD_ERR_NORESP=%d", err_noresp)) ;
        if ($value$plusargs("SD_ERR_CMDCRC=%d", err_cmdcrc)) ;
        if ($value$plusargs("SD_ERR_RDCRC_CNT=%d", left_rdcrc)) ;
        if ($value$plusargs("SD_ERR_WRREJ_CNT=%d", left_wrrej)) ;
        if ($value$plusargs("SD_ERR_WRFAIL_CNT=%d", left_wrfail)) ;
        if ($value$plusargs("SD_ERR_NORESP_CNT=%d", left_noresp)) ;
        if ($value$plusargs("SD_ERR_CMDCRC_CNT=%d", left_cmdcrc)) ;
        nread = 0;
        if ($value$plusargs("SD_IMG=%s", imgname)) begin
            fd = $fopen(imgname, "rb");
            if (fd == 0) begin
                $display("=== FAIL SD: cannot open image +SD_IMG=%0s", imgname);
                $finish;
            end else begin
                nread = $fread(mem, fd);
                $fclose(fd);
                $display("SD: image %0s loaded (%0d bytes)", imgname, nread);
            end
        end
        for (k = nread; k < MEMSZ; k = k + 1) mem[k] = 8'h00;   // rest of the card
        qh = 0; qt = 0; bitcnt = 0; cmdcnt = 0; txb = 8'hFF; miso = 1'b1;
        app_cmd = 0; idle = 1; ready = 0; polls = 0;
        rd_multi = 0; wstate = 0; wmulti = 0; rd_lba = 0; wlba = 0; wcnt = 0;
        crc_on = 0; wcrc = 16'd0; wrx = 16'd0; werr = 8'h00; wresp = 8'h00; winj = 8'h00; wr_ok = 0;
        cmd_n = 0; rd_blk_n = 0; wr_blk_n = 0; gone = 0;
        for (k = 0; k < QSZ; k = k + 1) qm[k] = 1'b0;
    end

    // ---- CRCs (SD spec: CRC7 x^7+x^3+1, CRC16 CCITT x^16+x^12+x^5+1, init 0)
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

    // The card is pulled: MISO 1 from now on, nothing received is acted on.
    task remove_card;
        begin
            if (log_on) $display("SD: %0t card removed", $time);
            gone = 1;
            drop_q;
            rd_multi = 0; wstate = 0; cmdcnt = 0;
            txb = 8'hFF;                // MISO: the always block on gone
        end
    endtask

    // Write the card contents to +SD_SAVE=<file> (bench calls this at the end).
    task save_image;
        integer n, f;
        begin
            if ($value$plusargs("SD_SAVE=%s", savename)) begin
                f = $fopen(savename, "wb");
                if (f == 0) begin
                    $display("=== FAIL SD: cannot write +SD_SAVE=%0s", savename);
                    $finish;
                end else begin
                    for (n = 0; n < MEMSZ; n = n + 1) $fwrite(f, "%c", mem[n]);
                    $fclose(f);
                    $display("SD: image saved to %0s", savename);
                end
            end
        end
    endtask

    // ---- tx queue ----
    task push_m(input [7:0] b, input m);
        begin q[qt % QSZ] = b; qm[qt % QSZ] = m; qt = qt + 1; end
    endtask

    task push(input [7:0] b);
        begin push_m(b, 1'b0); end
    endtask

    // drop everything not yet sent
    task drop_q;
        begin qh = qt; end
    endtask

    task push_r1(input [7:0] r);
        integer n;
        begin
            for (n = 0; n < ncr; n = n + 1) push(8'hFF);
            push(r);
        end
    endtask

    task push_busy;
        integer n;
        begin
            for (n = 0; n < busy_n; n = n + 1) push(8'h00);
        end
    endtask

    // token delay, 0xFE, 512 data bytes, CRC16 (marked for +SD_ERR_RDCRC)
    task push_block(input integer lba);
        integer n;
        reg [15:0] c;
        begin
            c = 16'd0;
            for (n = 0; n < tok_dly; n = n + 1) push(8'hFF);
            push(8'hFE);
            for (n = 0; n < 512; n = n + 1) begin
                push_m(mem[lba * 512 + n], n == 511);
                c = crc16(c, mem[lba * 512 + n]);
            end
            push(c[15:8]); push(c[7:0]);
        end
    endtask

    // ---- one complete command ----
    task do_cmd;
        reg was_app;
        integer n;
        reg [7:0] b8;
        reg [15:0] c16;
        reg [6:0] c7;
        begin
            was_app = app_cmd;
            app_cmd = 0;
            cmd_n = cmd_n + 1;
            c7 = crc7(crc7(crc7(crc7(crc7(7'd0, cmdb[0]), cmdb[1]), cmdb[2]), cmdb[3]), cmdb[4]);
            if (log_on)
                $display("SD: %0t %0sCMD%0d arg=%h cs=%b", $time, was_app ? "A" : "", cidx, carg, cs_n);
            if (err_noresp > 0 && cmd_n >= err_noresp && left_noresp > 0) begin
                left_noresp = left_noresp - 1;
                if (log_on) $display("SD: %0t no response (SD_ERR_NORESP=%0d)", $time, err_noresp);
            end else if (err_cmdcrc > 0 && cmd_n >= err_cmdcrc && left_cmdcrc > 0) begin
                left_cmdcrc = left_cmdcrc - 1;
                if (log_on) $display("SD: %0t R1 CRC error (SD_ERR_CMDCRC=%0d)", $time, err_cmdcrc);
                push_r1(idle ? 8'h09 : 8'h08);
            end else if (crc_on && cmdb[5][7:1] != c7) begin
                if (log_on) $display("SD: %0t CRC7 error: got %h want %h", $time, cmdb[5][7:1], c7);
                push_r1(idle ? 8'h09 : 8'h08);
            end else
            case (cidx)
                6'd0: begin     // reset: all card state, app_cmd too (also
                                // cleared above for every command)
                    idle = 1; ready = 0; polls = 0; app_cmd = 0;
                    rd_multi = 0; wstate = 0; crc_on = 0;
                    push_r1(8'h01);
                end
                6'd8: begin
                    push_r1(idle ? 8'h01 : 8'h00);
                    push(8'h00); push(8'h00); push(8'h01); push(8'hAA);
                end
                6'd55: begin app_cmd = 1; push_r1(idle ? 8'h01 : 8'h00); end
                6'd41: begin
                    if (was_app) begin
                        if (polls >= init_polls) begin idle = 0; ready = 1; end
                        polls = polls + 1;
                        push_r1(idle ? 8'h01 : 8'h00);
                    end else push_r1(8'h05);
                end
                6'd58: begin
                    push_r1(idle ? 8'h01 : 8'h00);
                    if (ready) begin push(8'hC0); push(8'hFF); push(8'h80); push(8'h00); end
                    else       begin push(8'h00); push(8'hFF); push(8'h80); push(8'h00); end
                end
                6'd16: push_r1(8'h00);
                6'd13: begin push_r1(idle ? 8'h01 : 8'h00); push(8'h00); end   // R2
                6'd59: begin crc_on = carg[0]; push_r1(idle ? 8'h01 : 8'h00); end
                6'd22: begin
                    if (was_app) begin  // ACMD22: blocks written by the last CMD25
                        push_r1(8'h00);
                        for (n = 0; n < tok_dly; n = n + 1) push(8'hFF);
                        push(8'hFE);
                        c16 = 16'd0;
                        for (n = 3; n >= 0; n = n - 1) begin
                            b8 = wr_ok >> (n * 8);
                            push(b8); c16 = crc16(c16, b8);
                        end
                        push(c16[15:8]); push(c16[7:0]);
                    end else push_r1(8'h04);
                end
                6'd9: begin             // CSD v2.0
                    push_r1(8'h00);
                    for (n = 0; n < tok_dly; n = n + 1) push(8'hFF);
                    push(8'hFE);
                    c16 = 16'd0;
                    for (n = 0; n < 16; n = n + 1) begin
                        case (n)
                            0: b8 = 8'h40;
                            7: b8 = {2'b00, CSIZE[21:16]};
                            8: b8 = CSIZE[15:8];
                            9: b8 = CSIZE[7:0];
                            default: b8 = 8'h00;
                        endcase
                        push(b8); c16 = crc16(c16, b8);
                    end
                    push(c16[15:8]); push(c16[7:0]);
                end
                6'd17: begin
                    if (carg >= IMG_SECTORS) push_r1(8'h40);
                    else begin push_r1(8'h00); push_block(carg); end
                end
                6'd18: begin
                    if (carg >= IMG_SECTORS) push_r1(8'h40);
                    else begin
                        push_r1(8'h00); push_block(carg);
                        rd_multi = 1; rd_lba = carg + 1;
                    end
                end
                6'd12: begin
                    rd_multi = 0;
                    drop_q;             // drop the rest of the stream
                    push(8'hFF);        // stuff byte
                    push_r1(8'h00);
                    push_busy;
                end
                6'd24, 6'd25: begin
                    if (carg >= IMG_SECTORS) push_r1(8'h40);
                    else begin
                        push_r1(8'h00);
                        wstate = 1; wmulti = (cidx == 6'd25);
                        wlba = carg; werr = 8'h00;
                        if (cidx == 6'd25) wr_ok = 0;
                    end
                end
                default: push_r1(8'h04);        // illegal command
            endcase
        end
    endtask

    // ---- one received byte; sets txb for the next 8 clocks ----
    task on_byte(input [7:0] b);
        integer n;
        begin
            if (wstate != 0) begin
                case (wstate)
                    1: begin
                        if (b == 8'hFE || (wmulti && b == 8'hFC)) begin
                            wstate = 2; wcnt = 0; wcrc = 16'd0;
                        end
                        else if (wmulti && b == 8'hFD) begin
                            if (log_on) $display("SD: %0t stop tran", $time);
                            wstate = 0; push(8'hFF); push_busy;
                        end
                    end
                    2: begin
                        wbuf[wcnt] = b; wcnt = wcnt + 1; wcrc = crc16(wcrc, b);
                        if (wcnt == 512) begin wstate = 3; wcnt = 0; end
                    end
                    3: begin
                        wrx = {wrx[7:0], b};
                        wcnt = wcnt + 1;
                        if (wcnt == 2) begin
                            wr_blk_n = wr_blk_n + 1;
                            winj = 8'h00;       // injection: every block is an event
                            if (err_wrrej > 0 && wr_blk_n >= err_wrrej && left_wrrej > 0) begin
                                left_wrrej = left_wrrej - 1; winj = 8'h0B;
                            end else if (err_wrfail > 0 && wr_blk_n >= err_wrfail && left_wrfail > 0) begin
                                left_wrfail = left_wrfail - 1; winj = 8'h0D;
                            end
                            if (werr != 8'h00)                    wresp = werr;
                            else if (crc_on && wrx != wcrc)       wresp = 8'h0B;
                            else if (winj != 8'h00)               wresp = winj;
                            else                                  wresp = 8'h05;
                            if (wresp == 8'h05) begin
                                for (n = 0; n < 512; n = n + 1) mem[wlba * 512 + n] = wbuf[n];
                                if (log_on) $display("SD: %0t wrote LBA %0d", $time, wlba);
                                if (wmulti) wr_ok = wr_ok + 1;
                            end else if (log_on)
                                $display("SD: %0t LBA %0d not written, data response %h (CRC got %h want %h)",
                                         $time, wlba, wresp, wrx, wcrc);
                            push(wresp);
                            if (wresp != 8'h0B) push_busy;
                            if (wmulti) begin
                                wstate = 1; wlba = wlba + 1;
                                if (wresp != 8'h05) werr = wresp;
                            end else wstate = 0;
                        end
                    end
                endcase
            end else if (cmdcnt == 0) begin
                if (b[7:6] == 2'b01) begin cmdb[0] = b; cmdcnt = 1; end
            end else begin
                cmdb[cmdcnt] = b; cmdcnt = cmdcnt + 1;
                if (cmdcnt == 6) begin
                    cmdcnt = 0;
                    cidx = cmdb[0][5:0];
                    carg = {cmdb[1], cmdb[2], cmdb[3], cmdb[4]};
                    do_cmd;
                end
            end
            // multi-block read: keep the stream going
            if (qh == qt && rd_multi) begin
                if (rd_lba < IMG_SECTORS) begin push_block(rd_lba); rd_lba = rd_lba + 1; end
                else rd_multi = 0;
            end
            if (qh != qt) begin
                txb = q[qh % QSZ];
                if (qm[qh % QSZ]) begin                 // a read block's last data byte
                    rd_blk_n = rd_blk_n + 1;
                    if (err_rdcrc > 0 && rd_blk_n >= err_rdcrc && left_rdcrc > 0) begin
                        left_rdcrc = left_rdcrc - 1;
                        txb = txb ^ 8'h01;              // not shifted out yet
                        if (log_on) $display("SD: %0t read block %0d: bit flipped (SD_ERR_RDCRC)", $time, rd_blk_n);
                    end
                end
                qh = qh + 1;
            end else txb = 8'hFF;
        end
    endtask

    // ---- SPI mode 0: sample on rising SCK, drive on falling SCK ----
    always @(posedge sck) begin
        if (!cs_n && !gone) begin
            rx = {rx[6:0], mosi};
            bitcnt = bitcnt + 1;
            if (bitcnt == 8) begin
                bitcnt = 0;
                on_byte(rx);
            end
        end
    end

    always @(negedge sck) begin
        if (!cs_n) miso <= gone ? 1'b1 : txb[7 - bitcnt];
    end

    // remove_card: MISO high at once (here, not in the task: a bench may call
    // the task from an initial block)
    always @(posedge gone) miso <= 1'b1;

    // CS falling: card selected, first bit out; CS rising: abort, line pulled up
    always @(negedge cs_n) begin
        bitcnt = 0; cmdcnt = 0; txb = 8'hFF; rx = 8'hFF;
        miso <= 1'b1;
    end
    always @(posedge cs_n) begin
        bitcnt = 0; cmdcnt = 0; drop_q; rd_multi = 0; wstate = 0;
        miso <= 1'b1;
    end
endmodule
