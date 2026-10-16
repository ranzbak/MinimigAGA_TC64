// L2 host-bridge bench: the RISC-V host CPU through the real bridge.
//
//   EightThirtyTwo_Bridge (cpu_riscv, rv_hostcpu + VexOsd, OSDBoot_rv_ROM =
//   the test program, hostcache.v)  ->  cfide (generics as host832)
//                                   ->  sdram_host_model (lanes of sdram_ctrl)
//   + an SPI byte-capture slave on sd_cs[1] / sd_clk / sd_do
//
// Clocks as sim/spi_cdc/host832/tb_832_dmode.v: clk_114 T114 = 8.8154 ns,
// clk_28 = clk_114 / 4, its edges 0.3 ns after a clk_114 edge.  cfide's
// tick_in is held at 1 (the timer counts every clk_28; TIMER = timecnt[23:8]
// steps every 1024 clk_114 cycles).
//
// Snooped at the bridge's bus (addr / q / wr / hw_req / hw_ack): a hw access
// completes at a clk_114 edge with hw_req = hw_ack = 1.
//   UART  0xFFFFFFF0 write -> character log, printed per line as "UART: ..."
//   TIME  0xFFFFFF00 write -> checkpoint <value>: test-specific pin checks
//   DONE  0xFFFFFF04 write -> end of run: "=== PASS" when the value is 0 and
//                             the bench saw no error, else "=== FAIL ..."
// Checks in every test:
//   stale ack   a hw access completed although no clk_28 edge of cfide saw
//               its hw_req (the ack belonged to the previous access)
//   SPI accept  a write to SPI DATA completed although cfide never accepted
//               it (no clk_114 edge with req, wr, SPI DATA and SD_busy = 0;
//               SD_busy read hierarchically from cfide)
//   X on the bus no X in read data the bridge returns or in written bytes
//   the SDRAM model's bus-contract checks
// Test-specific checks (+TEST=<name>): see checkpoint() and final_checks().
// t_irq: checkpoint 1 starts 20 vbl_int pulses into cfide (one clk_28 cycle
// each, 2000 clk_114 apart); checkpoint 2 checks that all 20 were sent.
//
// Plusargs: +TEST=<name> +SLAT=<n> +SJIT=<n> +SEED=<n> +SDRAM_HEX=<file>
//           +TIMEOUT=<clk_114 cycles> (default 3000000) +VERBOSE=1 (hw log),
//           +VERBOSE=2 (also every change of the bus address)
// Parameter: EXTRA_WS (xelab -generic_top EXTRA_WS=<n>), the bridge's
//           rv_extra_ws: idle cycles before every RISC-V request.
`timescale 1ns/1ps

module tb_host_bridge #(
  parameter EXTRA_WS = 0
);

  real T114 = 8.8154;

  reg clk114 = 1'b0;
  always #(T114/2.0) clk114 = ~clk114;
  reg [1:0] div = 2'd0;
  reg clk28 = 1'b0;
  always @(posedge clk114) begin
    div <= div + 2'd1;
    if (div == 2'd0) clk28 <= #(0.3) 1'b1;
    if (div == 2'd2) clk28 <= #(0.3) 1'b0;
  end

  reg n_reset = 1'b0, cpu_reset_n = 1'b0;

  // ------------------------------------------------------------ bridge
  wire [31:2] hostaddr;
  wire [31:0] hostWR;
  wire [3:0]  hostsel;
  wire        host_we;
  wire        ram_req, ram_ack;
  wire [15:0] ram_d;
  wire        hw_req, hw_ack;
  wire [15:0] hw_d;
  wire        cfide_int;
  wire        rv_tdo;

  EightThirtyTwo_Bridge #(.cpu_riscv(1'b1), .rv_extra_ws(EXTRA_WS)) hostcpu (
    .clk(clk114), .nReset(cpu_reset_n),
    .addr(hostaddr), .q(hostWR), .sel(hostsel), .wr(host_we),
    .ram_req(ram_req), .ram_ack(ram_ack), .ram_d(ram_d),
    .hw_req(hw_req), .hw_ack(hw_ack), .hw_d(hw_d),
    .interrupt(cfide_int),
    .rv_jtag_tck(1'b0), .rv_jtag_tms(1'b0), .rv_jtag_tdi(1'b0), .rv_jtag_tdo(rv_tdo)
  );

  sdram_host_model ram (
    .clk(clk114), .ram_req(ram_req), .ram_ack(ram_ack), .ram_d(ram_d),
    .addr(hostaddr), .q(hostWR), .sel(hostsel), .wr(host_we)
  );

  // ------------------------------------------------------------- cfide
  wire [7:0] sd_cs;
  wire       sd_clk, sd_do, miso;
  wire       scandoubler, audio_ena, audio_clear;
  reg        vbl_int = 1'b0;     // t_irq: pulses from checkpoint 1

  cfide #(
    .spimux(1'b0), .havespirtc(1'b0), .havei2c(1'b0), .havevpos(1'b0)
  ) mycfide (
    .sysclk(clk114), .n_reset(n_reset),
    .addr(hostaddr), .d(hostWR[15:0]), .q(hw_d), .req(hw_req), .wr(host_we), .ack(hw_ack),
    .sd_di(miso), .sd_cs(sd_cs), .sd_clk(sd_clk), .sd_do(sd_do),
    .sd_dimm(miso), .sd_ack(1'b1),
    .debugTxD(), .debugRxD(1'b1), .menu_button(1'b1),
    .xadc_temp(16'h0000),
    .scandoubler(scandoubler), .audio_ena(audio_ena), .audio_clear(audio_clear),
    .audio_buf(1'b1), .audio_amiga(1'b0), .vbl_int(vbl_int), .interrupt(cfide_int),
    .c64_keys(64'hFFFFFFFFFFFFFFFF), .amiga_key(), .amiga_key_stb(),
    .amiga_addr(8'h00), .amiga_d(16'h0000), .amiga_q(),
    .amiga_req(1'b0), .amiga_wr(1'b0), .amiga_ack(),
    .rtc_q(),
    .scl_i(1'b1), .scl_o(), .scl_t(), .sda_i(1'b1), .sda_o(), .sda_t(),
    .i2c_ext_int(1'b0),
    .pos_data_q(),
    .clk_28(clk28), .tick_in(1'b1)
  );

  // --------------------------------------------------- bench state, errors
  integer errors = 0;
  integer cyc = 0;
  always @(posedge clk114) cyc <= cyc + 1;
  reg [8*16-1:0] test;
  integer verbose = 0, timeout = 3000000;

  task bench_error(input [8*120-1:0] msg);
    begin
      $display("BENCH ERROR at cycle %0d: %0s", cyc, msg);
      errors = errors + 1;
    end
  endtask

  // ------------------------------------------------------ SPI capture slave
  // sd_clk idles high; cfide changes sd_do on its falling edge and samples
  // MISO on its rising edge.  The slave drives MISO from the falling edge and
  // samples MOSI on the rising edge, while sd_cs[1] is low.  MISO script:
  // byte n = 8'hA5 + 8'h11 * n.
  reg  [7:0] mosi_log [0:255];
  integer    mosi_n = 0, miso_n = 0, spi_bit = 0;
  reg  [7:0] mosi_sr = 8'h00, miso_cur = 8'hFF;
  reg        miso_r = 1'b1;
  assign miso = miso_r;

  function [7:0] miso_script(input integer n);
    miso_script = 8'hA5 + 8'h11 * n[7:0];
  endfunction

  always @(negedge sd_clk) if (n_reset && sd_cs[1] === 1'b0) begin
    if (spi_bit == 0) begin
      miso_cur = miso_script(miso_n);
      miso_n = miso_n + 1;
    end
    miso_r <= #2 miso_cur[7 - spi_bit];
  end
  always @(posedge sd_clk) if (n_reset && sd_cs[1] === 1'b0) begin
    mosi_sr = {mosi_sr[6:0], sd_do};
    spi_bit = spi_bit + 1;
    if (spi_bit == 8) begin
      if (verbose) $display("%0d SPI byte out %h in %h", cyc, mosi_sr, miso_cur);
      mosi_log[mosi_n & 255] = mosi_sr;
      mosi_n = mosi_n + 1;
      spi_bit = 0;
    end
  end
  always @(posedge sd_cs[1]) if (n_reset && spi_bit != 0) begin
    bench_error("sd_cs[1] rose in the middle of an SPI byte");
    spi_bit = 0;
  end

  // CS pattern log: every change of sd_cs after reset
  reg [7:0] cs_log [0:255];
  integer   cs_n = 0;
  always @(sd_cs) if (n_reset && cpu_reset_n) begin
    cs_log[cs_n & 255] = sd_cs;
    cs_n = cs_n + 1;
  end

  // pin toggles
  integer sd_tog = 0, ae_tog = 0;
  always @(scandoubler) if (cpu_reset_n) sd_tog = sd_tog + 1;
  always @(audio_ena)   if (cpu_reset_n) ae_tog = ae_tog + 1;

  // ----------------------------------------------- hw bus snoop and checks
  wire        hw_done  = hw_req && hw_ack;
  wire [31:0] hwa      = {hostaddr, 2'b00};
  wire        spi_data = hostaddr[23] && hostaddr[7:4] == 4'hE && hostaddr[3:2] == 2'b00;

  // stale ack: no clk_28 edge saw this request's hw_req
  reg c28_seen = 1'b0;
  always @(posedge hw_req) c28_seen = 1'b0;
  always @(posedge clk28) if (hw_req === 1'b1) c28_seen = 1'b1;

  // SPI DATA write accepted by cfide (its own condition, SD_busy hierarchical)
  reg spi_acc = 1'b0;
  integer spi_busy_waits = 0;     // DATA writes that found SD_busy high
  reg hw_req_d = 1'b0;
  always @(posedge hw_req) spi_acc = 1'b0;

  integer n_hw = 0, n_stale = 0, gap = 0, gap_min = 1000000, gap_max = 0, last_done = -1;
  integer b2b_on = 0;
  reg [7:0]  uart_line [0:127];
  integer    uart_n = 0;
  integer    uart_first = -1;   // first UART write: main has returned
  reg        done = 1'b0;
  reg [31:0] done_code = 32'h0;

  // X on the CPU bus: read data the bridge returns (cpu_d, read
  // hierarchically) in its ack cycle, write data on the lanes sel enables.
  // The core treats an X branch condition as "not taken", so a CHECK
  // against X data would pass: the bench fails the run instead.
  integer n_x = 0;
  wire [31:0] cpu_d = hostcpu.cpu_d;
  wire        cpu_ack = hostcpu.cpu_ack;
  wire        cpu_req = hostcpu.cpu_req;
  wire        cpu_wr = hostcpu.cpu_wr;
  wire [31:0] cpu_q = hostcpu.cpu_q;
  wire [3:0]  cpu_sel = hostcpu.cpu_sel;
  wire [31:2] cpu_addr = hostcpu.cpu_addr;
  wire [31:0] cpu_wmask = {{8{cpu_sel[0]}}, {8{cpu_sel[1]}}, {8{cpu_sel[2]}}, {8{cpu_sel[3]}}};
  wire [31:0] cpu_rmask = cpu_addr[23] ? 32'h0000FFFF : 32'hFFFFFFFF;
  always @(posedge clk114) if (cpu_reset_n && cpu_ack === 1'b1) begin
    if (!cpu_wr && ^(cpu_d & cpu_rmask) === 1'bx || cpu_wr && ^(cpu_q & cpu_wmask) === 1'bx) begin
      n_x = n_x + 1;
      if (n_x <= 10)
        $display("BENCH ERROR at cycle %0d: X on the bus: %s %h data %h sel %b", cyc,
                 cpu_wr ? "write" : "read", {cpu_addr, 2'b00}, cpu_wr ? cpu_q : cpu_d, cpu_sel);
      errors = errors + 1;
    end
  end

  // VERBOSE=2: every change of the bridge's (registered) CPU address/write
  reg [31:2] addr_d = 30'h0;
  reg        we_d = 1'b0;
  always @(posedge clk114) if (verbose >= 2 && cpu_reset_n) begin
    if (hostaddr !== addr_d || host_we !== we_d)
      $display("%0d bus %s %h q=%h sel=%b", cyc, host_we ? "W" : "R", {hostaddr, 2'b00}, hostWR, hostsel);
    addr_d <= hostaddr;
    we_d <= host_we;
  end

  always @(posedge clk114) begin
    hw_req_d <= hw_req;
    if (hw_req && host_we && spi_data && mycfide.SD_busy === 1'b0)
      spi_acc = 1'b1;
    if (hw_req && !hw_req_d) begin
      n_hw = n_hw + 1;
      if (host_we && spi_data && mycfide.SD_busy === 1'b1) spi_busy_waits = spi_busy_waits + 1;
      if (b2b_on && last_done >= 0) begin
        gap = cyc - last_done;
        if (gap < gap_min) gap_min = gap;
        if (gap > gap_max) gap_max = gap;
      end
      if (verbose) $display("%0d HW %s %h d=%h", cyc, host_we ? "W" : "R", hwa, hostWR);
    end
    if (hw_done) begin
      last_done = cyc;
      if (!c28_seen) begin
        n_stale = n_stale + 1;
        if (n_stale <= 10)
          $display("BENCH ERROR at cycle %0d: stale ack: %s %h completed, cfide never saw the request",
                   cyc, host_we ? "write" : "read", hwa);
        errors = errors + 1;
      end
      if (host_we && spi_data && !spi_acc) begin
        $display("BENCH ERROR at cycle %0d: SPI DATA write %h completed, cfide did not accept it (SD_busy high)",
                 cyc, hostWR[7:0]);
        errors = errors + 1;
      end
      if (host_we && hwa == 32'hFFFFFFF0) begin
        if (uart_first < 0) uart_first = cyc;
        if (hostWR[7:0] == 8'h0a || uart_n == 128) begin
          uart_print;
          uart_n = 0;
        end
        if (hostWR[7:0] != 8'h0a) begin
          uart_line[uart_n] = hostWR[7:0];
          uart_n = uart_n + 1;
        end
      end
      if (host_we && hwa == 32'hFFFFFF00) checkpoint(hostWR);
      if (host_we && hwa == 32'hFFFFFF04 && !done) begin
        done = 1'b1;
        done_code = hostWR;
      end
    end
  end

  task uart_print;
    integer k;
    reg [8*128-1:0] s;
    begin
      s = 0;
      for (k = 0; k < uart_n; k = k + 1) s = {s[8*127-1:0], uart_line[k]};
      $display("UART: %0s", s);
    end
  endtask

  // --------------------------------------------- test-specific checkpoints
  integer mosi_base = 0, cs_base = 0, sd_base = 0, ae_base = 0, busy_base = 0;
  reg [7:0] spibusy_bytes [0:7];
  initial begin
    spibusy_bytes[0] = 8'h01; spibusy_bytes[1] = 8'h80; spibusy_bytes[2] = 8'h55; spibusy_bytes[3] = 8'hAA;
    spibusy_bytes[4] = 8'hFF; spibusy_bytes[5] = 8'h00; spibusy_bytes[6] = 8'h3C; spibusy_bytes[7] = 8'hC3;
  end

  task expect_pin(input [8*24-1:0] name, input [7:0] got, input [7:0] want);
    begin
      if (got !== want) begin
        $display("BENCH ERROR at cycle %0d: %0s = %h, want %h", cyc, name, got, want);
        errors = errors + 1;
      end
    end
  endtask

  // t_irq pulse generator: vbl_int high for one clk_28 cycle (set after a
  // clk_28 edge, cleared after the next: exactly one edge of cfide sees it),
  // NPULSE times, PULSE_GAP clk_114 cycles apart.
  localparam NPULSE = 20, PULSE_GAP = 2000;
  integer pulses_sent = 0;
  event   pulses_go;
  always @(pulses_go) begin : pulser
    integer k;
    for (k = 0; k < NPULSE; k = k + 1) begin
      repeat (PULSE_GAP) @(posedge clk114);
      @(posedge clk28);
      vbl_int <= 1'b1;
      @(posedge clk28);
      vbl_int <= 1'b0;
      pulses_sent = pulses_sent + 1;
      if (verbose) $display("%0d vbl_int pulse %0d", cyc, pulses_sent);
    end
  end

  task checkpoint(input [31:0] v);
    integer k;
    begin
      $display("=== TIME %0d cycle %0d", v, cyc);
      if (test == "t_hwoff") begin
        case (v)
          1: expect_pin("scandoubler", scandoubler, 1'b0);
          2: expect_pin("scandoubler", scandoubler, 1'b1);
          3: expect_pin("audio_clear,audio_ena", {audio_clear, audio_ena}, 2'b01);
          4: expect_pin("audio_clear,audio_ena", {audio_clear, audio_ena}, 2'b10);
          5: expect_pin("audio_clear,audio_ena", {audio_clear, audio_ena}, 2'b00);
          6: begin expect_pin("sd_cs", sd_cs, 8'hFC); mosi_base = mosi_n; end
          7: begin
               expect_pin("SPI bytes out", mosi_n - mosi_base, 1);
               expect_pin("SPI MOSI byte", mosi_log[mosi_base & 255], 8'h5A);
             end
          8: expect_pin("sd_cs", sd_cs, 8'hFF);
          default: bench_error("t_hwoff: unknown checkpoint");
        endcase
      end else if (test == "t_b2b") begin
        case (v)
          1: begin   // PLATFORM and AUDIO at 0, CS deselected: arm counters
               expect_pin("scandoubler", scandoubler, 1'b0);
               expect_pin("audio_ena", audio_ena, 1'b0);
               expect_pin("sd_cs", sd_cs, 8'hFF);
               sd_base = sd_tog; ae_base = ae_tog;
               gap_min = 1000000; gap_max = 0; last_done = -1; b2b_on = 1;
             end
          2: begin   // 64 PLATFORM writes 1,0,1,0,...
               $display("t_b2b PLATFORM: %0d scandoubler toggles, request gap %0d..%0d cycles",
                        sd_tog - sd_base, gap_min, gap_max);
               expect_pin("scandoubler toggles", sd_tog - sd_base, 64);
               expect_pin("scandoubler", scandoubler, 1'b0);
               gap_min = 1000000; gap_max = 0; last_done = -1;
             end
          3: begin   // 64 AUDIO writes
               $display("t_b2b AUDIO: %0d audio_ena toggles, request gap %0d..%0d cycles",
                        ae_tog - ae_base, gap_min, gap_max);
               expect_pin("audio_ena toggles", ae_tog - ae_base, 64);
               expect_pin("audio_ena", audio_ena, 1'b0);
               cs_base = cs_n;
               gap_min = 1000000; gap_max = 0; last_done = -1;
             end
          4: begin   // 32 CS writes 0x02, 0x03, ...
               $display("t_b2b SPI CS: %0d sd_cs changes, request gap %0d..%0d cycles",
                        cs_n - cs_base, gap_min, gap_max);
               expect_pin("sd_cs changes", cs_n - cs_base, 32);
               for (k = 0; k < 32 && k < cs_n - cs_base; k = k + 1)
                 expect_pin("sd_cs pattern", cs_log[(cs_base + k) & 255], (k & 1) ? 8'hFF : 8'hFC);
               b2b_on = 0;
             end
          default: bench_error("t_b2b: unknown checkpoint");
        endcase
      end else if (test == "t_irq") begin
        case (v)
          1: -> pulses_go;
          2: begin
               $display("t_irq: %0d vbl_int pulses sent", pulses_sent);
               expect_pin("vbl_int pulses sent", pulses_sent, NPULSE);
             end
          default: bench_error("t_irq: unknown checkpoint");
        endcase
      end else if (test == "t_spibusy") begin
        case (v)
          1: begin expect_pin("sd_cs", sd_cs, 8'hFC); mosi_base = mosi_n; busy_base = spi_busy_waits; end
          2: begin
               $display("t_spibusy: %0d bytes out, %0d DATA writes found SD_busy high",
                        mosi_n - mosi_base, spi_busy_waits - busy_base);
               expect_pin("SPI bytes out", mosi_n - mosi_base, 8);
               for (k = 0; k < 8 && k < mosi_n - mosi_base; k = k + 1)
                 expect_pin("SPI MOSI byte", mosi_log[(mosi_base + k) & 255], spibusy_bytes[k]);
               if (spi_busy_waits - busy_base < 7)
                 bench_error("t_spibusy: fewer than 7 DATA writes waited on SD_busy (not back to back)");
             end
          3: expect_pin("sd_cs", sd_cs, 8'hFF);
          default: bench_error("t_spibusy: unknown checkpoint");
        endcase
      end
    end
  endtask

  // ---------------------------------------------------- end-of-run checks
  task final_checks;
    reg [31:0] a;
    integer k;
    reg [15:0] want [0:15];
    begin
      if (test == "t_lanes") begin
        // stores at 0x3000.. (sw/t_lanes.S STORES): byte A+0 = upper byte of
        // halfword A (sdram_ctrl's lanes)
        want[0]  = 16'h7856; want[1]  = 16'h34AB;   // sw 0x12345678; sb 0xAB @+3
        want[2]  = 16'h01FF; want[3]  = 16'hFFFF;   // sw -1; sb 0x01 @+4
        want[4]  = 16'hFF02; want[5]  = 16'hFFFF;   // sw -1; sb 0x02 @+9
        want[6]  = 16'hFFFF; want[7]  = 16'h03FF;   // sw -1; sb 0x03 @+14
        want[8]  = 16'hEFBE; want[9]  = 16'h0000;   // sw 0; sh 0xBEEF @+16
        want[10] = 16'h0000; want[11] = 16'hFECA;   // sw 0; sh 0xCAFE @+22
        want[12] = 16'hBBAA; want[13] = 16'h9988;   // sw 0x8899AABB @+24
        want[14] = 16'h1122; want[15] = 16'h3344;   // sb 11 22 33 44 @+28..31
        for (k = 0; k < 16; k = k + 1) begin
          a = 32'h3000 + 2 * k;
          if (ram.hw_at(a) !== want[k]) begin
            $display("BENCH ERROR: SDRAM halfword %h = %h, want %h", a, ram.hw_at(a), want[k]);
            errors = errors + 1;
          end
        end
        $display("t_lanes: SDRAM halfwords 0x3000..0x301F checked");
      end
    end
  endtask

  // ---------------------------------------------------------------- run
  initial begin
    if (!$value$plusargs("TEST=%s", test)) test = "none";
    if (!$value$plusargs("VERBOSE=%d", verbose)) verbose = 0;
    if (!$value$plusargs("TIMEOUT=%d", timeout)) timeout = 3000000;
    #1;
    $display("host-bridge bench: TEST=%0s SLAT=%0d SJIT=%0d EXTRA_WS=%0d", test, ram.slat, ram.sjit, EXTRA_WS);
    repeat (20) @(posedge clk114);
    n_reset = 1'b1;
    repeat (40) @(posedge clk28);
    @(posedge clk114);
    cpu_reset_n = 1'b1;
    fork : run
      begin
        wait (done);
        repeat (8) @(posedge clk114);
        disable run;
      end
      begin
        repeat (timeout) @(posedge clk114);
        bench_error("timeout, no DONE write");
        disable run;
      end
    join
    if (uart_n) uart_print;
    final_checks;
    errors = errors + ram.errors;
    $display("=== HW accesses %0d, stale acks %0d, X %0d, SDRAM reads %0d writes %0d, main done %0d, cycles %0d",
             n_hw, n_stale, n_x, ram.n_rd, ram.n_wr, uart_first, cyc);
    if (done && done_code == 0 && errors == 0) $display("=== PASS");
    else if (!done) $display("=== FAIL timeout (bench errors %0d)", errors);
    else $display("=== FAIL code %0d, bench errors %0d", done_code, errors);
    $finish;
  end

endmodule
