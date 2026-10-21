`timescale 1ns/1ps
// Bench for sd_spi_model.  The master below talks to the model the way
// fw/ctrl_boot_832/spi.c (init, CMD17) and fw/ctrl_832/mmc.c (CMD18+CMD12,
// CMD24, CMD25) do, reads the MBR and the FAT16 volume that
// tools/sim/mkcard.sh made, compares a 4 KB file (+HEX=<1 byte/line hex>)
// and does write + read-back.  Run it with sim/common/run_sd_model.sh.
module tb_sd_spi_model;
    localparam IMG = 16384;             // 8 MB card

    reg  cs_n = 1'b1, sck = 1'b0, mosi = 1'b1;
    wire miso;

    sd_spi_model #(.IMG_SECTORS(IMG)) u_sd (
        .cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso));

    localparam HP = 25;                 // half SCK period, ns
    integer errors = 0;
    reg [7:0] rxb;                      // last byte received
    reg [7:0] r1;                       // last R1
    reg [7:0] sec [0:511];
    reg [7:0] expd [0:4095];
    reg [8*1024-1:0] hexname;
    integer i, j, fat_ok;

    // ---- SPI master, mode 0, MSB first ----
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

    task fail(input [8*40-1:0] what);
        begin
            errors = errors + 1;
            $display("FAIL: %0s (t=%0t)", what, $time);
        end
    endtask

    // mmc.c MMC_Command: flush byte, 6 command bytes, up to 100 polls for R1
    task cmd(input [5:0] c, input [31:0] arg, input [7:0] crc);
        integer n;
        begin
            spi(8'hFF);
            spi({2'b01, c});
            spi(arg[31:24]); spi(arg[23:16]); spi(arg[15:8]); spi(arg[7:0]);
            spi(crc);
            n = 100;
            spi(8'hFF);
            while (rxb == 8'hFF && n > 0) begin spi(8'hFF); n = n - 1; end
            r1 = rxb;
        end
    endtask

    task spin(input integer n);
        integer k;
        begin for (k = 0; k < n; k = k + 1) spi(8'hFF); end
    endtask

    // wait for the data token (mmc.c: while (SPI(0xFF) != 0xFE))
    task wait_token(input [7:0] tok);
        integer n;
        begin
            n = 0; spi(8'hFF);
            while (rxb != tok && n < 100000) begin spi(8'hFF); n = n + 1; end
            if (rxb != tok) fail("no data token");
        end
    endtask

    task read_data_into_buf;
        integer k;
        begin
            for (k = 0; k < 512; k = k + 1) begin spi(8'hFF); sec[k] = rxb; end
            spi(8'hFF); spi(8'hFF);     // CRC
        end
    endtask

    // CMD17, one sector into sec
    task rd1(input [31:0] lba);
        begin
            cs_n = 1'b0;
            cmd(6'd17, lba, 8'hFF);
            if (r1 !== 8'h00) fail("CMD17 R1");
            wait_token(8'hFE);
            read_data_into_buf;
            spi(8'hFF);
            cs_n = 1'b1;
        end
    endtask

    function [31:0] le32(input integer o);
        le32 = {sec[o+3], sec[o+2], sec[o+1], sec[o]};
    endfunction
    function [15:0] le16(input integer o);
        le16 = {sec[o+1], sec[o]};
    endfunction

    // ---- test body ----
    reg [31:0] part, fat_lba, root_lba, data_lba, clus, fsize, ocr;
    reg [23:0] csz;
    integer busy_n;
    integer spc, nfat, fatsz, rsvd, rootents, found, s;
    reg [8*11-1:0] nm;
    reg [7:0] pat [0:1023];

    initial begin
        // watchdog
        #400_000_000 begin $display("FAIL: watchdog"); $display("=== FAIL"); $finish; end
    end

    initial begin : main
        if (!$value$plusargs("HEX=%s", hexname)) begin
            $display("FAIL: +HEX= missing"); $display("=== FAIL"); $finish;
        end
        busy_n = 8;
        if ($value$plusargs("SD_BUSY=%d", busy_n)) ;
        $readmemh(hexname, expd);
        #100;

        // ---- CMD0 ends an application command: CMD55, CMD0, CMD41 is a plain
        // CMD41 (illegal in SPI mode: R1 = 05), not ACMD41 (idle: R1 = 01)
        cs_n = 1'b0;
        cmd(6'd0, 32'd0, 8'h95);
        if (r1 !== 8'h01) fail("app_cmd case: CMD0 R1 != 01");
        cmd(6'd55, 32'd0, 8'hFF);
        if (r1 !== 8'h01) fail("app_cmd case: CMD55 R1 != 01");
        cmd(6'd0, 32'd0, 8'h95);
        if (r1 !== 8'h01) fail("app_cmd case: 2nd CMD0 R1 != 01");
        cmd(6'd41, 32'h4000_0000, 8'h87);
        if (r1 !== 8'h05) begin fail("CMD55,CMD0,CMD41 not plain CMD41"); $display("  R1=%h", r1); end
        else $display("CMD55, CMD0, CMD41: plain CMD41 (R1=05)");
        cs_n = 1'b1;
        spi(8'hFF);

        // ---- spi.c spi_init(): clocks with CS high, CMD0, CMD8, ACMD41, CMD58
        spin(200);
        cs_n = 1'b0;
        spi(8'hFF);
        cmd(6'd0, 32'd0, 8'h95);
        if (r1 !== 8'h01) fail("CMD0 R1 != 01");
        spin(200);
        cmd(6'd8, 32'h1AA, 8'h87);
        if (r1 !== 8'h01) fail("CMD8 R1 != 01");
        ocr = 0;
        for (i = 0; i < 4; i = i + 1) begin spi(8'hFF); ocr = {ocr[23:0], rxb}; end
        if (ocr !== 32'h000001AA) begin fail("CMD8 R7 != 000001AA"); $display("  R7=%h", ocr); end
        spi(8'hFF);
        s = 0; found = 0;
        while (!found && s < 50) begin
            spin(200);
            cmd(6'd55, 32'd0, 8'hFF);
            if (r1 !== 8'h01) fail("CMD55 R1 != 01");
            spi(8'hFF);
            cmd(6'd41, 32'h4000_0000, 8'h87);
            spi(8'hFF);
            if (r1 === 8'h00) found = 1;
            s = s + 1;
        end
        if (!found) fail("ACMD41 never ready");
        $display("ACMD41 ready after %0d polls", s);
        cmd(6'd58, 32'd0, 8'hFF);
        if (r1 !== 8'h00) fail("CMD58 R1");
        ocr = 0;
        for (i = 0; i < 4; i = i + 1) begin spi(8'hFF); ocr = {ocr[23:0], rxb}; end
        if (ocr[31:30] !== 2'b11) begin fail("OCR busy/CCS bits"); $display("  OCR=%h", ocr); end
        spi(8'hFF);
        cs_n = 1'b1;
        spi(8'hFF);

        // ---- MBR
        rd1(0);
        if ({sec[511], sec[510]} !== 16'hAA55) fail("MBR signature");
        part = le32(446 + 8);
        if (part !== 32'd2048) fail("partition start != 2048");
        if (sec[446+4] !== 8'h06) fail("partition type != 06");
        $display("MBR ok, partition at LBA %0d", part);

        // ---- FAT16 boot sector
        rd1(part);
        if (le16(11) !== 16'd512) fail("bytes/sector");
        spc = sec[13]; rsvd = le16(14); nfat = sec[16]; rootents = le16(17);
        fatsz = le16(22);
        if ({sec[511], sec[510]} !== 16'hAA55) fail("BPB signature");
        if (sec[54] !== "F" || sec[55] !== "A" || sec[56] !== "T" || sec[57] !== "1" || sec[58] !== "6")
            fail("FAT16 type string");
        fat_lba  = part + rsvd;
        root_lba = fat_lba + nfat * fatsz;
        data_lba = root_lba + (rootents * 32) / 512;
        $display("BPB: spc=%0d rsvd=%0d fats=%0d fatsz=%0d root@%0d data@%0d",
                 spc, rsvd, nfat, fatsz, root_lba, data_lba);

        // ---- root directory: TEST4K.BIN
        found = 0;
        rd1(root_lba);
        for (i = 0; i < 16 && !found; i = i + 1) begin
            nm = {sec[i*32+0], sec[i*32+1], sec[i*32+2], sec[i*32+3], sec[i*32+4],
                  sec[i*32+5], sec[i*32+6], sec[i*32+7], sec[i*32+8], sec[i*32+9],
                  sec[i*32+10]};
            if (nm == "TEST4K  BIN") begin
                found = 1; clus = le16(i*32+26); fsize = le32(i*32+28);
            end
        end
        if (!found) fail("TEST4K.BIN not in root dir");
        if (fsize !== 32'd4096) fail("file size != 4096");
        $display("TEST4K.BIN cluster %0d size %0d", clus, fsize);

        // ---- file by CMD18 + CMD12 (mmc.c MMC_ReadMultiple); fresh image: contiguous
        cs_n = 1'b0;
        cmd(6'd18, data_lba + (clus - 2) * spc, 8'hFF);
        if (r1 !== 8'h00) fail("CMD18 R1");
        for (s = 0; s < 8; s = s + 1) begin
            wait_token(8'hFE);
            read_data_into_buf;
            for (j = 0; j < 512; j = j + 1)
                if (sec[j] !== expd[s*512 + j]) begin
                    errors = errors + 1;
                    if (errors < 10) $display("FAIL: file byte %0d: got %h expd %h", s*512+j, sec[j], expd[s*512+j]);
                end
        end
        // MMC_CMD12: command (no flush), stuff byte, R1, busy
        spi({2'b01, 6'd12}); spi(0); spi(0); spi(0); spi(0); spi(0); spi(8'hFF);
        j = 100; spi(8'hFF);
        while (rxb == 8'hFF && j > 0) begin spi(8'hFF); j = j - 1; end
        if (rxb !== 8'h00) fail("CMD12 R1");
        j = 0; spi(8'hFF);
        while (rxb == 8'h00 && j < 100000) begin spi(8'hFF); j = j + 1; end
        if (rxb !== 8'hFF) fail("CMD12 busy end");
        cs_n = 1'b1;
        spi(8'hFF);
        $display("file compare (CMD18 x8 + CMD12) done, errors=%0d", errors);

        // ---- CMD9 / capacity
        cs_n = 1'b0;
        cmd(6'd9, 32'd0, 8'hFF);
        if (r1 !== 8'h00) fail("CMD9 R1");
        wait_token(8'hFE);
        read_data_into_buf;
        cs_n = 1'b1;
        csz = {sec[7], sec[8], sec[9]} & 24'h3FFFFF;
        if (csz !== (IMG / 1024 - 1)) fail("CSD C_SIZE");

        // ---- CMD24 write + CMD17 read back
        for (i = 0; i < 512; i = i + 1) pat[i] = (i * 7 + 3) & 255;
        cs_n = 1'b0;
        cmd(6'd24, 32'd100, 8'hFF);
        if (r1 !== 8'h00) fail("CMD24 R1");
        spi(8'hFF); spi(8'hFE);
        for (i = 0; i < 512; i = i + 1) spi(pat[i]);
        spi(8'hFF); spi(8'hFF);
        spi(8'hFF);
        if ((rxb & 8'h1F) !== 8'h05) fail("CMD24 data response");
        j = 0; spi(8'hFF);
        while (rxb == 8'h00 && j < 100000) begin spi(8'hFF); j = j + 1; end
        if (j == 0 && busy_n != 0) fail("CMD24 no busy seen");
        cs_n = 1'b1;
        spi(8'hFF);
        rd1(100);
        for (i = 0; i < 512; i = i + 1)
            if (sec[i] !== pat[i]) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL: CMD24 readback byte %0d: %h vs %h", i, sec[i], pat[i]);
            end
        $display("CMD24 write + CMD17 read-back done, errors=%0d", errors);

        // ---- CMD25 two blocks + stop token, CMD18 read back
        cs_n = 1'b0;
        cmd(6'd25, 32'd200, 8'hFF);
        if (r1 !== 8'h00) fail("CMD25 R1");
        for (s = 0; s < 2; s = s + 1) begin
            spi(8'hFF); spi(8'hFC);
            for (i = 0; i < 512; i = i + 1) spi((i + s * 91) & 255);
            spi(8'hFF); spi(8'hFF);
            spi(8'hFF);
            if ((rxb & 8'h1F) !== 8'h05) fail("CMD25 data response");
            j = 0; spi(8'hFF);
            while (rxb == 8'h00 && j < 100000) begin spi(8'hFF); j = j + 1; end
        end
        spi(8'hFD);                     // stop tran
        spi(8'hFF);
        j = 0; spi(8'hFF);
        while (rxb == 8'h00 && j < 100000) begin spi(8'hFF); j = j + 1; end
        cs_n = 1'b1;
        spi(8'hFF);
        cs_n = 1'b0;
        cmd(6'd18, 32'd200, 8'hFF);
        if (r1 !== 8'h00) fail("CMD18 R1 (readback)");
        for (s = 0; s < 2; s = s + 1) begin
            wait_token(8'hFE);
            read_data_into_buf;
            for (i = 0; i < 512; i = i + 1)
                if (sec[i] !== ((i + s * 91) & 255)) begin
                    errors = errors + 1;
                    if (errors < 10) $display("FAIL: CMD25 readback s=%0d byte %0d: %h", s, i, sec[i]);
                end
        end
        spi({2'b01, 6'd12}); spi(0); spi(0); spi(0); spi(0); spi(0); spi(8'hFF);
        j = 100; spi(8'hFF);
        while (rxb == 8'hFF && j > 0) begin spi(8'hFF); j = j - 1; end
        j = 0; spi(8'hFF);
        while (rxb == 8'h00 && j < 100000) begin spi(8'hFF); j = j + 1; end
        cs_n = 1'b1;
        spi(8'hFF);
        $display("CMD25 + CMD18 read-back done, errors=%0d", errors);

        u_sd.save_image;
        if (errors == 0) $display("=== PASS");
        else             $display("=== FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
