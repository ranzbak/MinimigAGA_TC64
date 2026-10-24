`timescale 1ns/1ps
// Bench for sd_spi_model's CRC and error-injection features (Task 4 of
// findings/sdcard-engine/plan.md).  Bit-banged SPI host, mode 0, MSB first;
// the CRC7 and CRC16 below are the bench's own (bitwise, anchored to the SD
// spec's examples).  One scenario per run, chosen by +CASE=<name>;
// `bash sim/common/run_sd_model.sh crc` runs them all with their plusargs on
// a 512 KB pseudo-random card (+SD_IMG).
//
//   basic   commands with a bad CRC7 work while CRC is off (the default);
//           CMD59(1); then a bad CRC7 gets R1 08 and is not executed; CMD17
//           of block 0 with a matching CRC16; CMD24 of block 5 with a wrong
//           CRC16 -> 0B (block unchanged), correct -> 05; 512 x FF to block 7
//           reads back with CRC 7FA1 (the SD spec's example); CMD25 x3 + stop
//           tran -> ACMD22 = 3; CMD18 x3 + CMD12 with CRCs; CMD13; CMD9 CRC16;
//           CMD59(0) turns checking off again
//   wrrej   +SD_ERR_WRREJ=2: CMD25 x3 -> 05 0B 0B, ACMD22 = 1, only the
//           first block written
//   wrfail  +SD_ERR_WRFAIL=1: CMD24 -> 0D, block unchanged; again -> 05
//   rdcrc   +SD_ERR_RDCRC=3: block 0 (1st) good; CMD18 from 1, one block
//           (2nd) then CMD12 -- the block in flight at CMD12 does not count;
//           CMD17 of block 9 (3rd) has one bit flipped and a CRC mismatch;
//           CMD17 of block 9 again is good
//   noresp  +SD_ERR_NORESP=11: the 11th command (the first CMD17 after
//           CMD0, CMD8, 3 x CMD55+ACMD41, CMD58, CMD59) gets no answer and
//           has no effect; the same CMD17 again works
//   remove  remove_card() 100 bytes into a CMD17 block and 300 bytes into a
//           CMD24 block: MISO stays 1 from then on (also across CS edges)
//           and the card is not written
//   cmdcrc  +SD_ERR_CMDCRC=11: the 11th command (CMD17) gets R1 08 and sends
//           no data; the same CMD17 again works
//   rdcnt   +SD_ERR_RDCRC=2 +SD_ERR_RDCRC_CNT=4: block 0 good, then four
//           CMD17s of block 9 bad (one bit each), the fifth good
//   nrcnt   +SD_ERR_NORESP=11 +SD_ERR_NORESP_CNT=3: three CMD17s
//           unanswered, the fourth answered
//   rdcut   +SD_ERR_RDCRC=2: a CMD18 block cut by CMD12 after 100 bytes is
//           not counted (its bytes clean); the next block (block 9, the 2nd
//           counted) has one bit flipped, block 9 again is good (no re-fire)
//   wrcnt   +SD_ERR_WRREJ=1 +SD_ERR_WRREJ_CNT=2 +SD_ERR_WRFAIL=3
//           +SD_ERR_WRFAIL_CNT=2: five CMD24s -> 0B 0B 0D 0D 05
// Every case but remove ends with a remove_card 300 bytes into a CMD24
// block: MISO 1 from then on, the block not written.
module tb_sd_model_crc;
    localparam IMG = 1024;              // 512 KB card

    reg  cs_n = 1'b1, sck = 1'b0, mosi = 1'b1;
    wire miso;

    sd_spi_model #(.IMG_SECTORS(IMG)) u_sd (
        .cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso));

    localparam HP = 25;                 // half SCK period, ns
    integer errors = 0;
    reg [7:0]  rxb;                     // last byte received
    reg [7:0]  r1;                      // last R1
    reg [7:0]  dresp;                   // last data response
    reg [7:0]  sec [0:511];             // last block read
    reg [7:0]  wb  [0:511];             // block to write
    reg [7:0]  orig [0:IMG*512-1];      // the card at time 0
    reg [15:0] rcrc, ccrc;              // received / computed CRC16 of the last block
    reg        tok_ok;
    reg [8*16-1:0] tcase;
    reg [31:0] v32;
    integer i, j, s, n, ones;

    // ---- SPI master ----
    task spi(input [7:0] t);
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                mosi = t[k];
                #HP;
                rxb[k] = miso;          // sampled just before the rising edge
                sck = 1'b1;
                #HP;
                sck = 1'b0;
            end
            mosi = 1'b1;
        end
    endtask

    task spin(input integer cnt);
        integer k;
        begin for (k = 0; k < cnt; k = k + 1) spi(8'hFF); end
    endtask

    task fail(input [8*56-1:0] what);
        begin
            errors = errors + 1;
            $display("FAIL: %0s (t=%0t)", what, $time);
        end
    endtask

    // ---- CRCs (SD spec: CRC7 x^7+x^3+1, CRC16 CCITT x^16+x^12+x^5+1, init 0)
    function [6:0] crc7(input [6:0] c, input [7:0] b);
        integer k;
        reg [6:0] x;
        reg fb;
        begin
            x = c;
            for (k = 7; k >= 0; k = k - 1) begin
                fb = x[6] ^ b[k];
                x = {x[5:0], 1'b0};
                if (fb) x = x ^ 7'h09;
            end
            crc7 = x;
        end
    endfunction

    function [15:0] crc16(input [15:0] c, input [7:0] b);
        integer k;
        reg [15:0] x;
        reg fb;
        begin
            x = c;
            for (k = 7; k >= 0; k = k - 1) begin
                fb = x[15] ^ b[k];
                x = {x[14:0], 1'b0};
                if (fb) x = x ^ 16'h1021;
            end
            crc16 = x;
        end
    endfunction

    function [7:0] cmd_crc(input [5:0] c, input [31:0] arg);
        reg [6:0] x;
        begin
            x = crc7(7'd0, {2'b01, c});
            x = crc7(x, arg[31:24]); x = crc7(x, arg[23:16]);
            x = crc7(x, arg[15:8]);  x = crc7(x, arg[7:0]);
            cmd_crc = {x, 1'b1};
        end
    endfunction

    // ---- commands: flush byte, 6 bytes, up to 16 polls for R1 ----
    task cmdx(input [5:0] c, input [31:0] arg, input [7:0] crcb);
        integer k;
        begin
            spi(8'hFF);
            spi({2'b01, c});
            spi(arg[31:24]); spi(arg[23:16]); spi(arg[15:8]); spi(arg[7:0]);
            spi(crcb);
            k = 16;
            spi(8'hFF);
            while (rxb == 8'hFF && k > 0) begin spi(8'hFF); k = k - 1; end
            r1 = rxb;
        end
    endtask

    task cmd(input [5:0] c, input [31:0] arg);
        begin cmdx(c, arg, cmd_crc(c, arg)); end
    endtask

    task cmd_badcrc(input [5:0] c, input [31:0] arg);
        begin cmdx(c, arg, cmd_crc(c, arg) ^ 8'h02); end
    endtask

    // ---- data blocks ----
    task wait_token;
        integer k;
        begin
            k = 0; spi(8'hFF);
            while (rxb == 8'hFF && k < 1000) begin spi(8'hFF); k = k + 1; end
            tok_ok = (rxb == 8'hFE);
            if (!tok_ok) begin fail("no data token"); $display("  got %h", rxb); end
        end
    endtask

    // token, len bytes into sec, CRC16 into rcrc, the bench's CRC into ccrc
    task read_block(input integer len);
        integer k;
        begin
            wait_token;
            ccrc = 16'd0;
            for (k = 0; k < len; k = k + 1) begin
                spi(8'hFF); sec[k] = rxb; ccrc = crc16(ccrc, rxb);
            end
            spi(8'hFF); rcrc[15:8] = rxb;
            spi(8'hFF); rcrc[7:0]  = rxb;
        end
    endtask

    task rd1(input [31:0] lba);
        begin
            cs_n = 1'b0;
            cmd(6'd17, lba);
            if (r1 !== 8'h00) begin fail("CMD17 R1"); $display("  R1=%h", r1); end
            read_block(512);
            spi(8'hFF);
            cs_n = 1'b1;
            spi(8'hFF);
        end
    endtask

    // compare sec with expected block (orig, or wb if from_wb)
    task check_sec(input integer lba, input from_wb, input [8*40-1:0] what);
        integer k, bad;
        begin
            bad = 0;
            for (k = 0; k < 512; k = k + 1)
                if (sec[k] !== (from_wb ? wb[k] : orig[lba*512 + k])) bad = bad + 1;
            if (bad != 0) begin fail(what); $display("  LBA %0d: %0d bytes differ", lba, bad); end
        end
    endtask

    // the card's block lba against orig (hierarchical: no read needed)
    task check_mem_orig(input integer lba, input [8*40-1:0] what);
        integer k, bad;
        begin
            bad = 0;
            for (k = 0; k < 512; k = k + 1)
                if (u_sd.mem[lba*512 + k] !== orig[lba*512 + k]) bad = bad + 1;
            if (bad != 0) begin fail(what); $display("  LBA %0d: %0d bytes changed", lba, bad); end
        end
    endtask

    // one data block (token tok) from wb, CRC good or not; data response into
    // dresp; then wait for busy to end
    task send_block(input [7:0] tok, input good_crc);
        integer k;
        reg [15:0] c;
        begin
            c = 16'd0;
            spi(8'hFF); spi(tok);
            for (k = 0; k < 512; k = k + 1) begin spi(wb[k]); c = crc16(c, wb[k]); end
            if (!good_crc) c = c ^ 16'h0100;
            spi(c[15:8]); spi(c[7:0]);
            k = 0; spi(8'hFF);
            while (rxb == 8'hFF && k < 8) begin spi(8'hFF); k = k + 1; end
            dresp = rxb;
            k = 0; spi(8'hFF);
            while (rxb == 8'h00 && k < 100000) begin spi(8'hFF); k = k + 1; end
        end
    endtask

    task wr1(input [31:0] lba, input good_crc);
        begin
            cs_n = 1'b0;
            cmd(6'd24, lba);
            if (r1 !== 8'h00) begin fail("CMD24 R1"); $display("  R1=%h", r1); end
            send_block(8'hFE, good_crc);
            cs_n = 1'b1;
            spi(8'hFF);
        end
    endtask

    task fill_wb(input integer seed);
        integer k;
        begin for (k = 0; k < 512; k = k + 1) wb[k] = (k * 13 + seed * 29 + 7) & 255; end
    endtask

    // CMD25 of nb blocks (patterns seed0.., good CRCs) + stop tran; the data
    // responses into resp[0..nb-1]
    reg [7:0] resp [0:7];
    task wr_multi(input [31:0] lba, input integer nb, input integer seed0);
        integer b, k;
        begin
            cs_n = 1'b0;
            cmd(6'd25, lba);
            if (r1 !== 8'h00) begin fail("CMD25 R1"); $display("  R1=%h", r1); end
            for (b = 0; b < nb; b = b + 1) begin
                fill_wb(seed0 + b);
                send_block(8'hFC, 1'b1);
                resp[b] = dresp;
            end
            spi(8'hFD);
            spi(8'hFF);
            k = 0; spi(8'hFF);
            while (rxb == 8'h00 && k < 100000) begin spi(8'hFF); k = k + 1; end
            cs_n = 1'b1;
            spi(8'hFF);
        end
    endtask

    // ACMD22: R1, data block of 4 bytes (big-endian count), CRC16
    task acmd22;
        begin
            cs_n = 1'b0;
            cmd(6'd55, 0);
            if (r1 !== 8'h00) begin fail("CMD55 R1 (ACMD22)"); $display("  R1=%h", r1); end
            cmd(6'd22, 0);
            if (r1 !== 8'h00) begin fail("ACMD22 R1"); $display("  R1=%h", r1); end
            read_block(4);
            v32 = {sec[0], sec[1], sec[2], sec[3]};
            if (rcrc !== ccrc) begin fail("ACMD22 CRC16"); $display("  got %h computed %h", rcrc, ccrc); end
            spi(8'hFF);
            cs_n = 1'b1;
            spi(8'hFF);
        end
    endtask

    // ---- init: CMD0, CMD8, CMD55+ACMD41 until ready, CMD58, CMD59(1) = 10
    // commands with the default +SD_INIT_POLLS=2 (noresp counts on that)
    task init_card(input crc_on);
        integer k, rdy;
        begin
            spin(10);
            cs_n = 1'b0;
            cmd(6'd0, 0);
            if (r1 !== 8'h01) begin fail("CMD0 R1"); $display("  R1=%h", r1); end
            cmd(6'd8, 32'h1AA);
            if (r1 !== 8'h01) begin fail("CMD8 R1"); $display("  R1=%h", r1); end
            v32 = 0;
            for (k = 0; k < 4; k = k + 1) begin spi(8'hFF); v32 = {v32[23:0], rxb}; end
            if (v32 !== 32'h1AA) begin fail("CMD8 R7"); $display("  R7=%h", v32); end
            rdy = 0; k = 0;
            while (!rdy && k < 10) begin
                cmd(6'd55, 0);
                cmd(6'd41, 32'h4000_0000);
                if (r1 === 8'h00) rdy = 1;
                k = k + 1;
            end
            if (!rdy) fail("ACMD41 never ready");
            cmd(6'd58, 0);
            if (r1 !== 8'h00) begin fail("CMD58 R1"); $display("  R1=%h", r1); end
            v32 = 0;
            for (k = 0; k < 4; k = k + 1) begin spi(8'hFF); v32 = {v32[23:0], rxb}; end
            if (v32[31:30] !== 2'b11) begin fail("OCR busy/CCS"); $display("  OCR=%h", v32); end
            if (crc_on) begin
                cmd(6'd59, 1);
                if (r1 !== 8'h00) begin fail("CMD59 R1"); $display("  R1=%h", r1); end
            end
            spi(8'hFF);
            cs_n = 1'b1;
            spi(8'hFF);
        end
    endtask

    initial begin
        #200_000_000 begin $display("FAIL: watchdog"); $display("=== FAIL"); $finish; end
    end

    initial begin : main
        tcase = "basic";
        if ($value$plusargs("CASE=%s", tcase)) ;
        #100;
        for (i = 0; i < IMG*512; i = i + 1) orig[i] = u_sd.mem[i];

        // the bench's CRCs against the SD spec's examples
        if (cmd_crc(6'd0, 0) !== 8'h95)       fail("bench crc7: CMD0 != 95");
        if (cmd_crc(6'd17, 0) !== 8'h55)      fail("bench crc7: CMD17 != 55");
        if (cmd_crc(6'd8, 32'h1AA) !== 8'h87) fail("bench crc7: CMD8 != 87");
        ccrc = 0;
        for (i = 0; i < 512; i = i + 1) ccrc = crc16(ccrc, 8'hFF);
        if (ccrc !== 16'h7FA1) fail("bench crc16: 512 x FF != 7FA1");
        $display("case %0s", tcase);

        if (tcase == "basic") begin
            init_card(1'b0);
            // CRC off by default: a bad CRC7 is accepted
            cs_n = 1'b0;
            cmd_badcrc(6'd58, 0);
            if (r1 !== 8'h00) begin fail("CRC off: bad CRC7 CMD58 not accepted"); $display("  R1=%h", r1); end
            spin(5);
            cmd(6'd59, 1);
            if (r1 !== 8'h00) begin fail("CMD59 R1"); $display("  R1=%h", r1); end
            // CRC on: bad CRC7 -> R1 08, not executed (no OCR bytes follow)
            cmd_badcrc(6'd58, 0);
            if (r1 !== 8'h08) begin fail("CRC on: bad CRC7 R1 != 08"); $display("  R1=%h", r1); end
            ones = 0;
            for (i = 0; i < 4; i = i + 1) begin spi(8'hFF); if (rxb == 8'hFF) ones = ones + 1; end
            if (ones != 4) fail("bad CRC7 CMD58 was executed");
            cmd_badcrc(6'd17, 0);
            if (r1 !== 8'h08) begin fail("CRC on: bad CRC7 CMD17 R1 != 08"); $display("  R1=%h", r1); end
            ones = 0;
            for (i = 0; i < 1100; i = i + 1) begin spi(8'hFF); if (rxb == 8'hFF) ones = ones + 1; end
            if (ones != 1100) fail("bad CRC7 CMD17 sent data");
            cmd(6'd58, 0);
            if (r1 !== 8'h00) begin fail("CRC on: good CMD58 R1"); $display("  R1=%h", r1); end
            spin(5);
            cs_n = 1'b1;
            spi(8'hFF);

            // read block 0, CRC16
            rd1(0);
            check_sec(0, 1'b0, "block 0 data");
            if (rcrc !== ccrc) begin fail("block 0 CRC16"); $display("  got %h computed %h", rcrc, ccrc); end
            else $display("block 0: CRC16 %h ok", rcrc);

            // write block 5: wrong CRC -> 0B, not written; right -> 05
            fill_wb(1);
            wr1(5, 1'b0);
            if ((dresp & 8'h1F) !== 8'h0B) begin fail("CMD24 bad CRC16: resp != 0B"); $display("  resp=%h", dresp); end
            check_mem_orig(5, "block 5 written despite bad CRC16");
            rd1(5);
            check_sec(5, 1'b0, "block 5 after rejected write");
            wr1(5, 1'b1);
            if ((dresp & 8'h1F) !== 8'h05) begin fail("CMD24 good CRC16: resp != 05"); $display("  resp=%h", dresp); end
            rd1(5);
            check_sec(5, 1'b1, "block 5 read back");
            if (rcrc !== ccrc) fail("block 5 read-back CRC16");
            $display("CMD24 block 5: bad CRC -> %h, good CRC -> 05, read back ok", 8'h0B);

            // SD spec example: 512 x FF has CRC16 7FA1
            for (i = 0; i < 512; i = i + 1) wb[i] = 8'hFF;
            wr1(7, 1'b1);
            if ((dresp & 8'h1F) !== 8'h05) fail("CMD24 block 7 resp != 05");
            rd1(7);
            if (rcrc !== 16'h7FA1) begin fail("512 x FF: CRC16 != 7FA1"); $display("  got %h", rcrc); end
            else $display("block 7 (512 x FF): CRC16 7fa1");

            // CMD25 x3, ACMD22 = 3
            wr_multi(10, 3, 40);
            for (i = 0; i < 3; i = i + 1)
                if ((resp[i] & 8'h1F) !== 8'h05) begin fail("CMD25 resp != 05"); $display("  block %0d resp=%h", i, resp[i]); end
            acmd22;
            if (v32 !== 32'd3) begin fail("ACMD22 != 3"); $display("  got %0d", v32); end
            else $display("CMD25 x3: ACMD22 = 3");

            // CMD18 x3 + CMD12, every block's CRC
            cs_n = 1'b0;
            cmd(6'd18, 10);
            if (r1 !== 8'h00) fail("CMD18 R1");
            for (s = 0; s < 3; s = s + 1) begin
                read_block(512);
                fill_wb(40 + s);
                check_sec(10 + s, 1'b1, "CMD18 data");
                if (rcrc !== ccrc) begin fail("CMD18 CRC16"); $display("  block %0d got %h computed %h", s, rcrc, ccrc); end
            end
            cmd(6'd12, 0);
            if (r1 !== 8'h00) begin fail("CMD12 R1"); $display("  R1=%h", r1); end
            j = 0; spi(8'hFF);
            while (rxb == 8'h00 && j < 100000) begin spi(8'hFF); j = j + 1; end
            // CMD13: R2 = 00 00
            cmd(6'd13, 0);
            spi(8'hFF);
            if (r1 !== 8'h00 || rxb !== 8'h00) begin fail("CMD13 R2 != 00 00"); $display("  %h %h", r1, rxb); end
            // CMD9: CSD with a CRC16
            cmd(6'd9, 0);
            if (r1 !== 8'h00) fail("CMD9 R1");
            read_block(16);
            if (rcrc !== ccrc) begin fail("CSD CRC16"); $display("  got %h computed %h", rcrc, ccrc); end
            if (sec[0] !== 8'h40) fail("CSD v2");
            // CMD59(0): bad CRC7 accepted again
            cmd(6'd59, 0);
            if (r1 !== 8'h00) fail("CMD59(0) R1");
            cmd_badcrc(6'd58, 0);
            if (r1 !== 8'h00) begin fail("CMD59(0): bad CRC7 not accepted"); $display("  R1=%h", r1); end
            spin(5);
            cs_n = 1'b1;
            spi(8'hFF);
            $display("CMD18 x3, CMD13, CMD9, CMD59(0) done");
        end else if (tcase == "wrrej") begin
            init_card(1'b1);
            wr_multi(20, 3, 60);
            $display("CMD25 x3 with SD_ERR_WRREJ=2: %h %h %h", resp[0], resp[1], resp[2]);
            if ((resp[0] & 8'h1F) !== 8'h05) fail("wrrej: block 1 resp != 05");
            if ((resp[1] & 8'h1F) !== 8'h0B) fail("wrrej: block 2 resp != 0B");
            if ((resp[2] & 8'h1F) !== 8'h0B) fail("wrrej: block 3 resp != 0B (after a reject)");
            acmd22;
            if (v32 !== 32'd1) begin fail("wrrej: ACMD22 != 1"); $display("  got %0d", v32); end
            else $display("ACMD22 = 1");
            rd1(20);
            fill_wb(60);
            check_sec(20, 1'b1, "wrrej: block 20 not written");
            check_mem_orig(21, "wrrej: rejected block 21 written");
            check_mem_orig(22, "wrrej: block 22 after the reject written");
        end else if (tcase == "wrfail") begin
            init_card(1'b1);
            fill_wb(3);
            wr1(5, 1'b1);
            if ((dresp & 8'h1F) !== 8'h0D) begin fail("wrfail: resp != 0D"); $display("  resp=%h", dresp); end
            check_mem_orig(5, "wrfail: block 5 written");
            wr1(5, 1'b1);
            if ((dresp & 8'h1F) !== 8'h05) begin fail("wrfail: 2nd write resp != 05"); $display("  resp=%h", dresp); end
            rd1(5);
            check_sec(5, 1'b1, "wrfail: 2nd write read back");
            $display("SD_ERR_WRFAIL=1: 0D, then 05");
        end else if (tcase == "rdcrc") begin
            init_card(1'b1);
            rd1(0);                                     // read block 1
            check_sec(0, 1'b0, "rdcrc: block 0 data");
            if (rcrc !== ccrc) fail("rdcrc: block 0 CRC (1st)");
            cs_n = 1'b0;                                // read block 2 + one in flight
            cmd(6'd18, 1);
            read_block(512);
            check_sec(1, 1'b0, "rdcrc: block 1 data");
            if (rcrc !== ccrc) fail("rdcrc: CMD18 block 1 CRC (2nd)");
            cmd(6'd12, 0);
            j = 0; spi(8'hFF);
            while (rxb == 8'h00 && j < 100000) begin spi(8'hFF); j = j + 1; end
            cs_n = 1'b1;
            spi(8'hFF);
            rd1(9);                                     // read block 3: corrupted
            if (rcrc === ccrc) fail("rdcrc: 3rd block CRC matched");
            ones = 0;
            for (i = 0; i < 512; i = i + 1)
                for (j = 0; j < 8; j = j + 1)
                    if (sec[i][j] !== orig[9*512 + i][j]) ones = ones + 1;
            if (ones != 1) begin fail("rdcrc: 3rd block not exactly one bit flipped"); $display("  %0d bits", ones); end
            check_mem_orig(9, "rdcrc: the card's block 9 changed");
            rd1(9);                                     // read block 4: good
            check_sec(9, 1'b0, "rdcrc: block 9 again");
            if (rcrc !== ccrc) fail("rdcrc: block 9 again CRC");
            $display("SD_ERR_RDCRC=3: one bit flipped in the 3rd block, then clean");
        end else if (tcase == "noresp") begin
            init_card(1'b1);
            cs_n = 1'b0;
            cmd(6'd17, 2);                              // command 11
            if (r1 !== 8'hFF) begin fail("noresp: 11th command answered"); $display("  R1=%h", r1); end
            ones = 0;
            for (i = 0; i < 1100; i = i + 1) begin spi(8'hFF); if (rxb == 8'hFF) ones = ones + 1; end
            if (ones != 1100) fail("noresp: 11th command executed");
            cs_n = 1'b1;
            spi(8'hFF);
            rd1(2);
            check_sec(2, 1'b0, "noresp: block 2 data");
            if (rcrc !== ccrc) fail("noresp: block 2 CRC");
            $display("SD_ERR_NORESP=11: no answer, then the repeat answered");
        end else if (tcase == "remove") begin
            init_card(1'b1);
            // mid-read
            cs_n = 1'b0;
            cmd(6'd17, 3);
            if (r1 !== 8'h00) fail("remove: CMD17 R1");
            wait_token;
            for (i = 0; i < 100; i = i + 1) spi(8'hFF);
            u_sd.remove_card;
            ones = 0;
            for (i = 0; i < 600; i = i + 1) begin spi(8'hFF); if (rxb == 8'hFF) ones = ones + 1; end
            if (ones != 600) begin fail("remove: MISO not 1 after remove_card"); $display("  %0d of 600", ones); end
            cs_n = 1'b1; spi(8'hFF);
            // a write after removal: no R1, nothing written
            fill_wb(9);
            cs_n = 1'b0;
            cmd(6'd24, 6);
            if (r1 !== 8'hFF) fail("remove: CMD24 answered");
            send_block(8'hFE, 1'b1);
            if (dresp !== 8'hFF) fail("remove: data response after removal");
            cs_n = 1'b1; spi(8'hFF);
            check_mem_orig(6, "remove: block 6 written after removal");
            $display("remove_card: MISO 1, nothing written");
        end else if (tcase == "cmdcrc") begin
            init_card(1'b1);
            cs_n = 1'b0;
            cmd(6'd17, 2);                              // command 11
            if (r1 !== 8'h08) begin fail("cmdcrc: 11th command R1 != 08"); $display("  R1=%h", r1); end
            ones = 0;
            for (i = 0; i < 1100; i = i + 1) begin spi(8'hFF); if (rxb == 8'hFF) ones = ones + 1; end
            if (ones != 1100) fail("cmdcrc: 11th command executed");
            cs_n = 1'b1;
            spi(8'hFF);
            rd1(2);
            check_sec(2, 1'b0, "cmdcrc: block 2 data");
            if (rcrc !== ccrc) fail("cmdcrc: block 2 CRC");
            $display("SD_ERR_CMDCRC=11: R1 08, not executed, then the repeat answered");
        end else if (tcase == "rdcnt") begin
            init_card(1'b1);
            rd1(0);
            if (rcrc !== ccrc) fail("rdcnt: block 0 (1st) CRC");
            for (s = 0; s < 5; s = s + 1) begin
                rd1(9);
                ones = 0;
                for (i = 0; i < 512; i = i + 1)
                    for (j = 0; j < 8; j = j + 1)
                        if (sec[i][j] !== orig[9*512 + i][j]) ones = ones + 1;
                if (s < 4 && (rcrc === ccrc || ones != 1)) begin
                    fail("rdcnt: read not corrupted"); $display("  read %0d: %0d bits", s + 2, ones);
                end
                if (s == 4 && (rcrc !== ccrc || ones != 0)) begin
                    fail("rdcnt: 5th read of block 9 not clean"); $display("  %0d bits", ones);
                end
            end
            $display("SD_ERR_RDCRC=2 CNT=4: four bad blocks, the fifth good");
        end else if (tcase == "nrcnt") begin
            init_card(1'b1);
            for (s = 0; s < 3; s = s + 1) begin
                cs_n = 1'b0;
                cmd(6'd17, 2);                          // commands 11, 12, 13
                if (r1 !== 8'hFF) begin fail("nrcnt: command answered"); $display("  try %0d R1=%h", s, r1); end
                ones = 0;
                for (i = 0; i < 1100; i = i + 1) begin spi(8'hFF); if (rxb == 8'hFF) ones = ones + 1; end
                if (ones != 1100) fail("nrcnt: command executed");
                cs_n = 1'b1;
                spi(8'hFF);
            end
            rd1(2);                                     // command 14
            check_sec(2, 1'b0, "nrcnt: block 2 data");
            if (rcrc !== ccrc) fail("nrcnt: block 2 CRC");
            $display("SD_ERR_NORESP=11 CNT=3: three unanswered, the fourth answered");
        end else if (tcase == "rdcut") begin
            init_card(1'b1);
            rd1(0);                                     // 1st: good
            if (rcrc !== ccrc) fail("rdcut: block 0 CRC");
            cs_n = 1'b0;
            cmd(6'd18, 1);                              // cut: not counted
            wait_token;
            ones = 0;
            for (i = 0; i < 100; i = i + 1) begin spi(8'hFF); if (rxb !== orig[512 + i]) ones = ones + 1; end
            if (ones != 0) fail("rdcut: cut block's bytes corrupted");
            cmd(6'd12, 0);
            j = 0; spi(8'hFF);
            while (rxb == 8'h00 && j < 100000) begin spi(8'hFF); j = j + 1; end
            cs_n = 1'b1;
            spi(8'hFF);
            rd1(9);                                     // 2nd counted: corrupted
            ones = 0;
            for (i = 0; i < 512; i = i + 1)
                for (j = 0; j < 8; j = j + 1)
                    if (sec[i][j] !== orig[9*512 + i][j]) ones = ones + 1;
            if (rcrc === ccrc || ones != 1) begin fail("rdcut: 2nd counted block not corrupted"); $display("  %0d bits", ones); end
            rd1(9);                                     // fired once: clean
            check_sec(9, 1'b0, "rdcut: block 9 re-corrupted");
            if (rcrc !== ccrc) fail("rdcut: block 9 again CRC");
            $display("SD_ERR_RDCRC=2: cut block not counted, one corrupted block, no re-fire");
        end else if (tcase == "wrcnt") begin
            init_card(1'b1);
            for (s = 0; s < 5; s = s + 1) begin
                fill_wb(70 + s);
                wr1(30 + s, 1'b1);
                resp[s] = dresp;
            end
            $display("WRREJ=1 CNT=2, WRFAIL=3 CNT=2: %h %h %h %h %h", resp[0], resp[1], resp[2], resp[3], resp[4]);
            if ((resp[0] & 8'h1F) !== 8'h0B || (resp[1] & 8'h1F) !== 8'h0B) fail("wrcnt: blocks 1-2 not 0B");
            if ((resp[2] & 8'h1F) !== 8'h0D || (resp[3] & 8'h1F) !== 8'h0D) fail("wrcnt: blocks 3-4 not 0D");
            if ((resp[4] & 8'h1F) !== 8'h05) fail("wrcnt: block 5 not 05");
            for (s = 0; s < 4; s = s + 1) check_mem_orig(30 + s, "wrcnt: failed block written");
            rd1(34);
            fill_wb(74);
            check_sec(34, 1'b1, "wrcnt: block 34 read back");
        end else begin
            fail("unknown +CASE");
        end

        // a mid-block removal (every case but remove ends with it)
        if (tcase != "remove") begin
            fill_wb(11);
            cs_n = 1'b0;
            cmd(6'd24, 8);
            if (r1 !== 8'h00) fail("mid-block remove: CMD24 R1");
            spi(8'hFF); spi(8'hFE);
            for (i = 0; i < 300; i = i + 1) spi(wb[i]);
            u_sd.remove_card;
            ones = 0;
            for (i = 300; i < 512; i = i + 1) begin spi(wb[i]); if (rxb == 8'hFF) ones = ones + 1; end
            spi(8'h00); spi(8'h00);
            for (i = 0; i < 16; i = i + 1) begin spi(8'hFF); if (rxb == 8'hFF) ones = ones + 1; end
            cs_n = 1'b1; spi(8'hFF);
            cs_n = 1'b0; spi(8'hFF); if (rxb == 8'hFF) ones = ones + 1;
            cs_n = 1'b1;
            if (ones != 212 + 16 + 1) begin fail("mid-block remove: MISO not 1"); $display("  %0d of 229", ones); end
            check_mem_orig(8, "mid-block remove: block 8 written");
        end

        u_sd.save_image;
        if (errors == 0) $display("=== PASS");
        else             $display("=== FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
