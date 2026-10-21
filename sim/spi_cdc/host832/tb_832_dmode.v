// The SD card direct-mode transfer with the real 832 doing the host side.
//
// tb_spi_cdc.v models the 832 by a bus latency `gap'.  This bench replaces
// that model with the 832 itself (EightThirtyTwo_Bridge: the CPU, its boot ROM
// port and hostcache.v) running the instruction sequence the shipped firmware
// runs for MMC_Read*'s direct mode (see gen832.py), from RAM through the host
// cache, with an SDRAM model behind the cache whose host-port latency is a
// plusarg.  It measures how long after the RDSPI ack the 832's DisableDMode()
// write arrives, and checks every sector paula_floppy hands to the gayle
// model.
//
//   +SLAT=<n>   SDRAM host-port latency, clk_114 cycles from sdram_req to ack
//   +SJIT=<n>   plus a random 0..n per access (other masters using the SDRAM)
//   +NSEC=<n>   sectors
//
// Output: one "L <cycles>" line per sector (RDSPI ack seen by the bridge ->
// DisableDMode hw_req), a histogram, and "=== PASS" / "=== FAIL" on the data.

`timescale 1ns/1ps

module tb_832_dmode;

  real    T114   = 8.8154;
  real    sckdly = 1.5;
  integer slat = 8, sjit = 0, nsec = 20, seed = 1;

  reg clk114 = 1'b0;
  always #(T114/2.0) clk114 = ~clk114;
  reg [1:0] div = 2'd0;
  reg clk28 = 1'b0;
  always @(posedge clk114) begin
    div <= div + 2'd1;
    if (div == 2'd0) clk28 <= #(0.3) 1'b1;
    if (div == 2'd2) clk28 <= #(0.3) 1'b0;
  end
  reg [1:0] clk7_cnt = 2'b10;
  reg clk7_en = 1'b1, clk7n_en = 1'b1;
  always @(posedge clk28) begin
    clk7_cnt <= clk7_cnt + 2'b01;
    clk7_en  <= #1 (clk7_cnt == 2'b00);
    clk7n_en <= #1 (clk7_cnt == 2'b10);
  end

  reg n_reset = 1'b0, mm_reset = 1'b1, cpu_reset_n = 1'b0;

  // ---------------------------------------------------------------- 832
  wire [31:2] hostaddr;
  wire [31:0] hostWR;
  wire [3:0]  hostsel;
  wire        host_we;
  wire        ram_req;
  reg         ram_ack = 1'b0;
  reg  [15:0] ram_d = 16'h0000;
  wire        hw_req, hw_ack;
  wire [15:0] hw_d;

  EightThirtyTwo_Bridge #(.debug(1'b0)) hostcpu (
    .clk(clk114), .nReset(cpu_reset_n),
    .addr(hostaddr), .q(hostWR), .sel(hostsel), .wr(host_we),
    .ram_req(ram_req), .ram_ack(ram_ack), .ram_d(ram_d),
    .hw_req(hw_req), .hw_ack(hw_ack), .hw_d(hw_d),
    .interrupt(1'b0),
    .rv_jtag_tdo()     // RISC-V debug port: unused with the 832 (cpu_riscv = false)
  );

  // SDRAM behind hostcache: halfwords, big-endian, from RAM_BASE
  localparam RAM_BASE = 32'h40000;
  reg [15:0] mem [0:65535];
  initial $readmemh("ram.hex", mem);
  integer lat_left = -1, burst = -1, b_word;
  reg [31:0] b_addr;
  reg        b_wr;
  always @(posedge clk114) begin
    ram_ack <= 1'b0;
    if (burst >= 0) begin
      // fill: word0.hi on the ack cycle, then .lo, word1.hi, ... (wrapping)
      burst = burst + 1;
      if (burst < 8)
        ram_d <= mem[(((b_addr - RAM_BASE) >> 1) & ~32'h7) + (((b_word + (burst >> 1)) & 3) << 1) + (burst & 1)];
      else
        burst = -1;
    end else if (lat_left > 0) begin
      lat_left = lat_left - 1;
    end else if (lat_left == 0) begin
      lat_left = -1;
      ram_ack <= 1'b1;
      if (b_wr) begin
        if (hostsel[3]) mem[(b_addr - RAM_BASE) >> 1][15:8] = hostWR[31:24];
        if (hostsel[2]) mem[(b_addr - RAM_BASE) >> 1][7:0]  = hostWR[23:16];
        if (hostsel[1]) mem[((b_addr - RAM_BASE) >> 1) + 1][15:8] = hostWR[15:8];
        if (hostsel[0]) mem[((b_addr - RAM_BASE) >> 1) + 1][7:0]  = hostWR[7:0];
      end else begin
        b_word = b_addr[3:2];
        burst = 0;
        ram_d <= mem[(((b_addr - RAM_BASE) >> 1) & ~32'h7) + (b_word << 1)];
      end
    end else if (ram_req && !ram_ack && burst < 0) begin
      b_addr = {hostaddr, 2'b00};
      b_wr   = host_we;
      lat_left = slat + (sjit ? ($urandom % (sjit + 1)) : 0);
    end
  end

  // ---------------------------------------------------------------- cfide
  wire [7:0]  spi_cs;
  wire        spi_sck, spi_di, spi_do, sd_miso;
  cfide #(
    .spimux(1'b0), .havespirtc(1'b0), .havei2c(1'b0), .havevpos(1'b0)
  ) mycfide (
    .sysclk(clk114), .n_reset(n_reset),
    .addr(hostaddr), .d(hostWR[15:0]), .q(hw_d), .req(hw_req), .wr(host_we), .ack(hw_ack),
    .sd_di(spi_do), .sd_cs(spi_cs), .sd_clk(spi_sck), .sd_do(spi_di),
    .sd_dimm(sd_miso), .sd_ack(1'b1),
    .debugTxD(), .debugRxD(1'b1), .menu_button(1'b1),
    .xadc_temp(16'h0000),
    .scandoubler(), .audio_ena(), .audio_clear(),
    .audio_buf(1'b0), .audio_amiga(1'b0), .vbl_int(1'b0), .interrupt(),
    .c64_keys(64'hFFFFFFFFFFFFFFFF), .amiga_key(), .amiga_key_stb(),
    .amiga_addr(8'h00), .amiga_d(16'h0000), .amiga_q(),
    .amiga_req(1'b0), .amiga_wr(1'b0), .amiga_ack(),
    .rtc_q(),
    .scl_i(1'b1), .scl_o(), .scl_t(), .sda_i(1'b1), .sda_o(), .sda_t(),
    .i2c_ext_int(1'b0),
    .pos_data_q(),
    .clk_28(clk28), .tick_in(1'b0)
  );

  reg sck_slv = 1'b1;
  always @(spi_sck) sck_slv <= #(sckdly) spi_sck;

  // ---------------------------------------------------------------- paula_floppy + gayle model
  wire [15:0] hdd_data_out;
  wire        hdd_data_wr, hdd_data_rd;
  paula_floppy pf1 (
    .clk(clk28), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
    .reset(mm_reset), .ntsc(1'b0), .sof(1'b0), .enable(1'b0),
    .reg_address_in(8'h00), .data_in(16'h0000), .data_out(),
    .dmal(), .dmas(),
    ._step(1'b1), .direc(1'b0), ._sel(4'hF), .side(1'b0), ._motor(1'b1),
    ._track0(), ._change(), ._ready(), ._wprot(), .index(),
    .blckint(), .syncint(), .wordsync(1'b0),
    ._scs(spi_cs[4]), .sdi(spi_di), .sdo(spi_do), .sck(sck_slv),
    .disk_led(), .floppy_drives(2'b00),
    .direct_scs(~spi_cs[6]), .direct_sdi(sd_miso),
    .hdd_cmd_req(1'b0), .hdd_dat_req(1'b0),
    .hdd_addr(), .hdd_data_out(hdd_data_out), .hdd_data_in(16'h0000),
    .hdd_wr(), .hdd_status_wr(),
    .hdd_data_wr(hdd_data_wr), .hdd_data_rd(hdd_data_rd),
    .trackdisp(), .secdisp(), .floppy_fwr(), .floppy_frd()
  );

  reg [15:0] g_rx [0:1023];
  integer    g_rx_n = 0;
  always @(posedge clk28) if (clk7_en && hdd_data_wr) begin
    g_rx[g_rx_n & 1023] <= hdd_data_out;
    g_rx_n <= g_rx_n + 1;
  end

  // ---------------------------------------------------------------- SD card
  real    card_dly = 12.0;
  reg [7:0] card_sec [0:513];
  reg [7:0] exp_sec  [0:511];
  integer card_bit = 0;
  reg     card_stream = 1'b0;
  reg     card_do = 1'b1;
  assign  sd_miso = card_do;
  always @(negedge spi_sck)
    if (card_stream && !spi_cs[1]) begin
      card_do <= #(sckdly + card_dly)
        ((card_bit < 514*8) ? card_sec[card_bit >> 3][7 - (card_bit & 7)] : 1'b1);
      card_bit = card_bit + 1;
    end

  // ---------------------------------------------------------------- sectors
  integer k, n0 = 0, sec = 0, bad = 0, errs = 0;
  integer cyc = 0;
  always @(posedge clk114) cyc <= cyc + 1;

  task check_sector;
    begin
      bad = 0;
      if (g_rx_n - n0 != 256) begin
        $display("  sector %0d: %0d words received, want 256", sec, g_rx_n - n0);
        bad = 1;
      end
      for (k = 0; k < 256 && !bad; k = k + 1)
        if (g_rx[(n0 + k) & 1023] !== {exp_sec[2*k], exp_sec[2*k+1]}) begin
          $display("  sector %0d: word %0d = %h, want %h", sec, k, g_rx[(n0 + k) & 1023], {exp_sec[2*k], exp_sec[2*k+1]});
          bad = 1;
        end
      errs = errs + bad;
    end
  endtask

  // EnableDMode (spi_cs[6] falls): new sector on the card; check the last one
  always @(negedge spi_cs[6]) begin
    if (sec > 0) check_sector;
    sec = sec + 1;
    for (k = 0; k < 514; k = k + 1) card_sec[k] = $urandom;
    for (k = 0; k < 512; k = k + 1) exp_sec[k] = card_sec[k];
    n0 = g_rx_n;
    card_bit = 0;
    card_stream = 1'b1;
  end
  always @(posedge spi_cs[1]) card_stream = 1'b0;   // DisableCard

  // L: RDSPI ack (a data-register read acked while DMode is selected) to the
  // DisableDMode request.
  integer t_ack = -1, L, hist [0:199];
  reg hw_req_d = 1'b0;
  always @(posedge clk114) begin
    hw_req_d <= hw_req;
    if (hw_req && hw_ack && !host_we && hostaddr[7:2] == 6'h38 && !spi_cs[6])
      t_ack = cyc;
    if (hw_req && !hw_req_d && host_we && hostaddr[7:2] == 6'h39 && hostWR[7:0] == 8'h41 && t_ack >= 0) begin
      L = cyc - t_ack;
      $display("L %0d", L);
      if (L < 200) hist[L] = hist[L] + 1;
      t_ack = -1;
    end
  end

  integer dbg = 0, ndbg = 0;
  reg ram_req_d = 1'b0;
  always @(posedge clk114) begin
    ram_req_d <= ram_req;
    if (dbg == 2 && cyc < 1200 && cpu_reset_n && (cyc % 50 == 0 || ram_req === 1'b1 || burst >= 0)) $display("%0d addr=%h ram_req=%b hw_req=%b we=%b ack=%b ram_d=%h burst=%0d", cyc, {hostaddr,2'b00}, ram_req, hw_req, host_we, ram_ack, ram_d, burst);
    if (dbg && ndbg < 80) begin
      if (hw_req && !hw_req_d) begin
        $display("%0d HW %s %h d=%h", cyc, host_we ? "W" : "R", {hostaddr, 2'b00}, hostWR);
        ndbg = ndbg + 1;
      end
      if (ram_req && !ram_req_d) begin
        $display("%0d RAM %s %h d=%h sel=%b", cyc, host_we ? "W" : "R", {hostaddr, 2'b00}, hostWR, hostsel);
        ndbg = ndbg + 1;
      end
    end
  end

  initial begin
    if (!$value$plusargs("DEBUG=%d", dbg)) dbg = 0;
    if (!$value$plusargs("SLAT=%d", slat)) slat = 8;
    if (!$value$plusargs("SJIT=%d", sjit)) sjit = 0;
    if (!$value$plusargs("NSEC=%d", nsec)) nsec = 20;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    k = $urandom(seed);
    for (k = 0; k < 200; k = k + 1) hist[k] = 0;
    $display("832 direct-mode bench: SLAT=%0d SJIT=%0d NSEC=%0d", slat, sjit, nsec);
    repeat (20) @(posedge clk114);
    n_reset = 1'b1;
    repeat (40) @(posedge clk28);
    mm_reset = 1'b0;
    repeat (8) @(posedge clk114);
    cpu_reset_n = 1'b1;
    wait (sec == nsec + 1);
    $display("L histogram (cycles: sectors):");
    for (k = 0; k < 200; k = k + 1) if (hist[k]) $display("  %0d: %0d", k, hist[k]);
    if (errs == 0) $display("=== PASS (%0d sectors)", nsec);
    else           $display("=== FAIL (%0d of %0d sectors bad)", errs, nsec);
    $finish;
  end

  initial begin
    #(nsec * 2000000.0 + 1000000.0);
    $display("=== FAIL (timeout at sector %0d)", sec);
    $finish;
  end

endmodule
