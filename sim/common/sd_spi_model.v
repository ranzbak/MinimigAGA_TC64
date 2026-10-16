`timescale 1ns/1ps
// SD card, SPI mode 0, SDHC (block addressing) -- simulation model.
// Verilog-2005 only; runs in iverilog and xsim.  See tools/sim/README.md.
//
// Plusargs: +SD_IMG=<raw image>   loaded at time 0 (rest of the card = 0)
//           +SD_SAVE=<file>       written by the task save_image (the bench
//                                 calls it before $finish)
//           +SD_TOKEN_DLY=<n>     0xFF bytes before every data token (4)
//           +SD_BUSY=<n>          0x00 busy bytes after a write / CMD12 (8)
//           +SD_NCR=<n>           0xFF bytes between a command and its R1 (1)
//           +SD_INIT_POLLS=<n>    ACMD41 polls that answer "idle" (2)
//           +SD_LOG=1             one line per command
module sd_spi_model #(parameter IMG_SECTORS = 65536)
    (input cs_n, input sck, input mosi, output reg miso);

    localparam MEMSZ = IMG_SECTORS * 512;
    localparam [21:0] CSIZE = IMG_SECTORS / 1024 - 1;   // CSD v2 C_SIZE
    localparam QSZ   = 4096;            // tx queue (power of two)

    reg [7:0] mem [0:MEMSZ-1];
    reg [7:0] q   [0:QSZ-1];            // bytes still to be sent
    integer   qh, qt;                   // head (pop) / tail (push)
    reg [7:0] wbuf [0:511];

    integer tok_dly, busy_n, ncr, init_polls, log_on;
    reg [1023:0] imgname, savename;
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

    initial begin
        tok_dly = 4; busy_n = 8; ncr = 1; init_polls = 2; log_on = 0;
        if ($value$plusargs("SD_TOKEN_DLY=%d", tok_dly)) ;
        if ($value$plusargs("SD_BUSY=%d", busy_n)) ;
        if ($value$plusargs("SD_NCR=%d", ncr)) ;
        if ($value$plusargs("SD_INIT_POLLS=%d", init_polls)) ;
        if ($value$plusargs("SD_LOG=%d", log_on)) ;
        nread = 0;
        if ($value$plusargs("SD_IMG=%s", imgname)) begin
            fd = $fopen(imgname, "rb");
            if (fd == 0) $display("SD: cannot open image %0s", imgname);
            else begin
                nread = $fread(mem, fd);
                $fclose(fd);
                $display("SD: image %0s loaded (%0d bytes)", imgname, nread);
            end
        end
        for (k = nread; k < MEMSZ; k = k + 1) mem[k] = 8'h00;   // rest of the card
        qh = 0; qt = 0; bitcnt = 0; cmdcnt = 0; txb = 8'hFF; miso = 1'b1;
        app_cmd = 0; idle = 1; ready = 0; polls = 0;
        rd_multi = 0; wstate = 0; wmulti = 0; rd_lba = 0; wlba = 0; wcnt = 0;
    end

    // Write the card contents to +SD_SAVE=<file> (bench calls this at the end).
    task save_image;
        integer n, f;
        begin
            if ($value$plusargs("SD_SAVE=%s", savename)) begin
                f = $fopen(savename, "wb");
                for (n = 0; n < MEMSZ; n = n + 1) $fwrite(f, "%c", mem[n]);
                $fclose(f);
                $display("SD: image saved to %0s", savename);
            end
        end
    endtask

    // ---- tx queue ----
    task push(input [7:0] b);
        begin q[qt % QSZ] = b; qt = qt + 1; end
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

    // token delay, 0xFE, 512 data bytes, 2 CRC bytes
    task push_block(input integer lba);
        integer n;
        begin
            for (n = 0; n < tok_dly; n = n + 1) push(8'hFF);
            push(8'hFE);
            for (n = 0; n < 512; n = n + 1) push(mem[lba * 512 + n]);
            push(8'h00); push(8'h00);
        end
    endtask

    // ---- one complete command ----
    task do_cmd;
        reg was_app;
        integer n;
        begin
            was_app = app_cmd;
            app_cmd = 0;
            if (log_on)
                $display("SD: %0t %0sCMD%0d arg=%h cs=%b", $time, was_app ? "A" : "", cidx, carg, cs_n);
            case (cidx)
                6'd0: begin
                    idle = 1; ready = 0; polls = 0;
                    rd_multi = 0; wstate = 0;
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
                6'd9: begin             // CSD v2.0
                    push_r1(8'h00);
                    for (n = 0; n < tok_dly; n = n + 1) push(8'hFF);
                    push(8'hFE);
                    for (n = 0; n < 16; n = n + 1) begin
                        case (n)
                            0: push(8'h40);
                            7: push({2'b00, CSIZE[21:16]});
                            8: push(CSIZE[15:8]);
                            9: push(CSIZE[7:0]);
                            default: push(8'h00);
                        endcase
                    end
                    push(8'h00); push(8'h00);
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
                    qh = qt;            // drop the rest of the stream
                    push(8'hFF);        // stuff byte
                    push_r1(8'h00);
                    push_busy;
                end
                6'd24, 6'd25: begin
                    if (carg >= IMG_SECTORS) push_r1(8'h40);
                    else begin
                        push_r1(8'h00);
                        wstate = 1; wmulti = (cidx == 6'd25);
                        wlba = carg;
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
                        if (b == 8'hFE || (wmulti && b == 8'hFC)) begin wstate = 2; wcnt = 0; end
                        else if (wmulti && b == 8'hFD) begin
                            if (log_on) $display("SD: %0t stop tran", $time);
                            wstate = 0; push(8'hFF); push_busy;
                        end
                    end
                    2: begin
                        wbuf[wcnt] = b; wcnt = wcnt + 1;
                        if (wcnt == 512) begin wstate = 3; wcnt = 0; end
                    end
                    3: begin
                        wcnt = wcnt + 1;
                        if (wcnt == 2) begin
                            for (n = 0; n < 512; n = n + 1) mem[wlba * 512 + n] = wbuf[n];
                            if (log_on) $display("SD: %0t wrote LBA %0d", $time, wlba);
                            push(8'h05); push_busy;
                            if (wmulti) begin wstate = 1; wlba = wlba + 1; end
                            else wstate = 0;
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
            if (qh != qt) begin txb = q[qh % QSZ]; qh = qh + 1; end
            else txb = 8'hFF;
        end
    endtask

    // ---- SPI mode 0: sample on rising SCK, drive on falling SCK ----
    always @(posedge sck) begin
        if (!cs_n) begin
            rx = {rx[6:0], mosi};
            bitcnt = bitcnt + 1;
            if (bitcnt == 8) begin
                bitcnt = 0;
                on_byte(rx);
            end
        end
    end

    always @(negedge sck) begin
        if (!cs_n) miso <= txb[7 - bitcnt];
    end

    // CS falling: card selected, first bit out; CS rising: abort, line pulled up
    always @(negedge cs_n) begin
        bitcnt = 0; cmdcnt = 0; txb = 8'hFF; rx = 8'hFF;
        miso <= 1'b1;
    end
    always @(posedge cs_n) begin
        bitcnt = 0; cmdcnt = 0; qh = qt; rd_multi = 0; wstate = 0;
        miso <= 1'b1;
    end
endmodule
