//-----------------------------------------------------------------
// ddr3_cpu_tb -- the TG68K WRAPPER driving the DDR3 Zorro-III fast RAM.
//
// Why this bench exists
// ---------------------
// sim/ddr3_full drives ddr3_fastram's CPU port directly with hand-written
// tasks.  That proves the cache backend, the CDC, the controller and the PHY,
// but it cannot see anything about how rtl/soc/TG68K.vhd DECIDES what kind of
// bus cycle a Zorro-III access is.  That decision is where the stage-B3
// hardware bug lived: chipset_cycle was derived from sel_ram alone, so with
// haveddr3 every DDR3 access was classified as a 7 MHz chipset cycle and the
// CPU was released on ena7RDreg/ena7WRreg with clkena_e/clkena_f instead of on
// the DDR3 acknowledge.  This bench closes that gap: the DUT is the real
// wrapper with the real TG68KdotC kernel inside it, running a real 68k program.
//
// What is real and what is a model
// --------------------------------
//   real : rtl/soc/TG68K.vhd (wrapper + TG68KdotC_Kernel + akiko),
//          rtl/ddr3/ddr3_fastram.v (cpu_cache_new + backend + ddr3_cdc),
//          rtl/ddr3/ddr3_top.v (PLL + vendored DLL-off core + xc7 PHY),
//          the Micron 2Gb DDR3 model.
//   model: the SDRAM side.  The wrapper's fromram/ramready port is answered by
//          a behavioural 128 kB word memory that holds the 68k program, its
//          vectors, its stack and the mailbox.  The chipset side (as/uds/lds/
//          data_read/dtack) is answered by the same array, because the very
//          first vector fetches happen before turbochip_d has been set and so
//          go out as real chipset cycles.
//
// Wiring is exactly rtl/soc/minimig_virtual_top.v:
//   * ddr3_fastram sees cpustate with bit 2 replaced by ddrcs
//     (tg68_ddrcpustate), everything else including cpuLongword passed through,
//   * cpuAddr = ddraddr = the offset inside board 3, zero-extended: the
//     board's base bits are dropped, so with a 16 MB board this is
//     cpuaddr(23 downto 1) and not the identity map it was when the DDR3
//     was board 1,
//   * fromddr / ddr_ena / ddr_ready come back from cpuRD / cpuena / ddr_ready,
//   * cpu_cache_ctrl is the wrapper's CACR_out (the program enables the caches
//     with movec, as the OS does),
//   * ena7RDreg / ena7WRreg / enaWRreg are generated with the sdram_ctrl
//     cadence: a free-running 16-phase counter on sysclk, enaWRreg at
//     ph2/6/10/14 (28.36 MHz), ena7RDreg at ph6 and ena7WRreg at ph14
//     (7.09 MHz each) -- rtl/sdram/sdram_ctrl.v lines ~344-375.
//
// Autoconfig state is the one the OS leaves behind: ziiram_active = 1 and
// ziiiram3_active = 1 with z3ram3_base = $41, so 0x41000000 is a live 16 MB
// Zorro-III board on the DDR3.  Board 1 (ziiiram_active) is left inactive:
// on hardware it is a live SDRAM board, but this bench's SDRAM model is a
// 128 kB array indexed by the low ramaddr bits, so a live board 1 would
// alias onto the program's own memory.  What matters here -- that the DDR3
// answers only inside board 3 -- is asserted directly instead, below.
// cpu = 2'b11 (32-bit address space enabled, which is what makes 0x41000000
// decodable at all).
//
// The 68k program is asm/ddr3_cpu_test.asm; see its header for the mailbox
// layout and the failure codes.  This bench
//   * polls the mailbox at 0x00001000 and prints PASS / FAIL code N together
//     with the first mismatch address, expected and got that the program left
//     there,
//   * traces the phase marker so a timeout still says how far the program got,
//   * and then checks the DDR3 contents INDEPENDENTLY through the Micron
//     model's backdoor (memory_read), so a program that "passes" by reading
//     its own cache cannot hide a DRAM that never got the data.
//
// Run with ./run.sh (real TG68K.vhd) and ./run.sh --mutant (the pre-fix copy
// in mutant/, which must FAIL).
//-----------------------------------------------------------------
`timescale 1ps / 1ps

module ddr3_cpu_tb;

//-----------------------------------------------------------------
// Program layout -- must agree with asm/ddr3_cpu_test.asm
//-----------------------------------------------------------------
// The DDR3 fast RAM is Zorro-III board 3 now, not board 1: an extra board
// whose base the OS assigns and minimig_autoconfig.v latches.  $41000000 is
// where the OS puts it once the 16 MB board 1 has taken $40000000 (see the
// bench in sim/autoconfig).  Must match Z3RAM3_BASE below and DDRBASE in
// asm/ddr3_cpu_test.asm.
localparam [31:0] DDRBASE  = 32'h4100_0000;
localparam [ 7:0] Z3RAM3_BASE = 8'h41;   // A31-A24, as the OS would write it
// Offset inside the board = what actually reaches the DDR3.  16 MB board,
// i.e. TG68K's z3ram3_size_log2 = 24.
localparam [31:0] Z3RAM3_OFFMASK = 32'h00FF_FFFF;
localparam [31:0] PATOFF   = 32'h0000_0000;
localparam [31:0] MISOFF   = 32'h0000_1000;
localparam [31:0] CNTOFF   = 32'h0000_2000;
// Region sizes.  They must agree with the .asm; run.sh passes the same numbers
// to vasm (-DPATBYTES=... ) and to xsim (+PATBYTES=...), so a small, fast debug
// run is a command-line change and not an edit in two places.
integer PATBYTES = 1024;
integer MISLINES = 16;
integer CNTN     = 64;
initial begin
  void'($value$plusargs("PATBYTES=%d", PATBYTES));
  void'($value$plusargs("MISLINES=%d", MISLINES));
  void'($value$plusargs("CNTN=%d",     CNTN));
end
localparam [31:0] VBASE    = 32'hC0DE_0000;
localparam [31:0] MBASE    = 32'hBEEF_0000;
localparam [31:0] CBASE    = 32'h5EED_0000;

localparam [31:0] MBOX     = 32'h0000_1000;   // in the bench chip RAM

// Turbo chip RAM.  With it set, sel_chipram makes sel_ram, chipset_cycle is 0
// and every chip access leaves on the SDRAM-side port.  With it clear the
// wrapper drives the 7 MHz chipset bus instead -- as/uds/lds/data_write and,
// on a TG68K, the AGA paired-word optimisation that answers one longword
// request with two words through uds2/lds2/data_read2.
//
// That second path is why this is a plusarg.  The AP68040 turns the paired
// word off (longword_pair in rtl/soc/TG68K.vhd), so a longword becomes two
// separate word cycles, and with turbochipram tied to 1 the AP040 run never
// issued a single chipset cycle -- the path the core actually uses when the
// user has Turbo set to none was never simulated.  Kickstart 46.143 gets as
// far as AllocMem and then cannot allocate a 6 kB supervisor stack, which is
// what the chipset-bus path being wrong would look like.
//
//   +TURBOCHIP=0   drive chip RAM over the chipset bus (Turbo off)
//   +TURBOCHIP=1   default, as before
reg turbochipram = 1'b1;
initial void'($value$plusargs("TURBOCHIP=%b", turbochipram));

// MemHeader values
localparam [31:0] MH_NAME  = 32'h4100_0100;
localparam [31:0] MH_FIRST = 32'h4100_0020;
localparam [31:0] MH_LOWER = 32'h4100_0000;
localparam [31:0] MH_UPPER = 32'h4200_0000;
localparam [31:0] MH_FREE  = 32'h00FF_FFE0;
localparam [15:0] MH_ATTR  = 16'h0005;
localparam [ 7:0] MH_TYPE  = 8'd10;

// Give up after this much simulated time.  At the default sizes the program
// finishes in roughly 0.8 ms of simulated time (phase 2 is instruction bound,
// about 6.7 us per cache line); this leaves a wide margin and still bounds a
// mutant run that hangs instead of reporting.
localparam time TIMEOUT = 64'd2_500_000_000;  // 2.5 ms (must be sized: an
                                              // unsized literal above 2^31 is
                                              // negative and #TIMEOUT is then 0)

//-----------------------------------------------------------------
// Clocks and reset
//-----------------------------------------------------------------
// Minimig system clock, 113.4375 MHz.
reg clk = 1'b0;
always begin #4407 clk = 1'b1; #4408 clk = 1'b0; end

// board oscillator for the DDR3 island's own PLL
reg clk_50 = 1'b0;
always #10000 clk_50 = ~clk_50;

reg board_reset_n = 1'b0;                     // = the board reset chain
reg tg68_rst      = 1'b0;                     // active low
reg sdctl_rst     = 1'b0;                     // active low

initial begin
  // Hold the CPU in reset until the DDR3 island has finished its init
  // sequence, which is what minimig_virtual_top effectively does (the OSD
  // firmware only releases the Amiga long after configuration).  ddr_ready is
  // NOT a per-access ready, so starting the CPU before it would just stall.
  board_reset_n = 1'b0; sdctl_rst = 1'b0; tg68_rst = 1'b0;
  #500_000;                                   // 500 ns
  board_reset_n = 1'b1;
  sdctl_rst     = 1'b1;
  wait (ddr_ready === 1'b1);
  repeat (20) @(posedge clk);
  tg68_rst = 1'b1;
  $display("INFO: CPU released at %t (ddr_ready=%b init_done=%b pll_locked=%b)",
           $time, ddr_ready, init_done, pll_locked);
end

//-----------------------------------------------------------------
// sdram_ctrl's enable cadence (rtl/sdram/sdram_ctrl.v ~344-375)
//-----------------------------------------------------------------
// 16 sysclk = one 7.09 MHz period.  enaWRreg at ph2/6/10/14, ena7RDreg at ph6,
// ena7WRreg at ph14, all registered exactly as the controller registers them.
reg [3:0] ph        = 4'd0;
reg       ena28     = 1'b0;                   // = enaWRreg  -> clkena_in
reg       ena7RDreg = 1'b0;
reg       ena7WRreg = 1'b0;

always @(posedge clk) begin
  if (!sdctl_rst) begin
    ph        <= 4'd0;
    ena28     <= 1'b0;
    ena7RDreg <= 1'b0;
    ena7WRreg <= 1'b0;
  end else begin
    ph        <= ph + 4'd1;
    ena28     <= (ph == 4'd2) || (ph == 4'd6) || (ph == 4'd10) || (ph == 4'd14);
    ena7RDreg <= (ph == 4'd6);
    ena7WRreg <= (ph == 4'd14);
  end
end

//-----------------------------------------------------------------
// TG68K wrapper
//-----------------------------------------------------------------
wire [31:0] tg68_adr;
wire [15:0] tg68_dat_out, tg68_dat_out2;
wire        tg68_as, tg68_uds, tg68_lds, tg68_uds2, tg68_lds2, tg68_rw;
wire [15:0] tg68_cin;                          // toram
wire        tg68_nrst_out;
wire [31:0] tg68_cad;                          // ramaddr
wire [ 6:0] tg68_cpustate;
wire        tg68_clds, tg68_cuds;
wire [ 3:0] tg68_CACR_out;
wire [31:0] tg68_VBR_out;
wire        cache_inhibit, cacheline_clr;

wire [25:1] tg68_ddraddr;
wire        tg68_ddrcs;
wire [15:0] tg68_ddrout;
wire        tg68_ddrena;
wire        tg68_ddrready;

// exactly minimig_virtual_top.v: cpustate with the chip select (bit 2)
// replaced by the DDR3 one, everything else untouched.
wire [ 6:0] tg68_ddrcpustate = {tg68_cpustate[6:3], tg68_ddrcs, tg68_cpustate[1:0]};

reg  [15:0] tg68_dat_in, tg68_dat_in2;         // chipset-side read data
reg  [15:0] fromram;                           // SDRAM-side read data
reg         ramready;

// Which kernel the wrapper builds.  run.sh --ap040 defines CPU_AP040 and adds
// the AP68040 sources; everything else in this bench is identical, which is
// the whole point of that core presenting a TG68K-shaped port set.
`ifdef CPU_AP040
TG68K #(.cpu_core("AP040")) tg68k (
`else
TG68K #(.cpu_core("TG68K")) tg68k (
`endif
    .clk            (clk              ),
    .reset          (tg68_rst         ),
    .clkena_in      (ena28            ),
    .IPL            (3'b111           ),
    .dtack          (1'b0             ),   // the chipset always acks
    .vpa            (1'b1             ),
    .ein            (1'b1             ),
    .addr           (tg68_adr         ),
    .data_read      (tg68_dat_in      ),
    .data_read2     (tg68_dat_in2     ),
    .data_write     (tg68_dat_out     ),
    .data_write2    (tg68_dat_out2    ),
    .as             (tg68_as          ),
    .uds            (tg68_uds         ),
    .lds            (tg68_lds         ),
    .uds2           (tg68_uds2        ),
    .lds2           (tg68_lds2        ),
    .rw             (tg68_rw          ),
    .vma            (                 ),
    .wrd            (                 ),
    .ena7RDreg      (ena7RDreg        ),
    .ena7WRreg      (ena7WRreg        ),
    .fromram        (fromram          ),
    .toram          (tg68_cin         ),
    .ramready       (ramready         ),
    .ddraddr        (tg68_ddraddr     ),
    .ddrcs          (tg68_ddrcs       ),
    .fromddr        (tg68_ddrout      ),
    .ddr_ready      (tg68_ddrready    ),
    .ddr_ena        (tg68_ddrena      ),
    .cpu            (2'b11            ),   // 68020 mode: 32-bit address space
    .ziiram_active  (1'b1             ),   // autoconfig done: 2 MB Zorro-II
    .ziiiram_active (1'b0             ),   // board 1: SDRAM on hardware, see header
    .ziiiram2_active(1'b0             ),
    .ziiiram3_active(1'b1             ),   // ... and the 16 MB DDR3 board
    .z3ram3_base    (Z3RAM3_BASE      ),   // where the OS put it
    // Chipset DMA write snoop.  This bench has no chipset and nothing but the
    // CPU writes memory, so there is nothing to snoop; on hardware these come
    // from sdram_ctrl.  (An AP68040 caching chip RAM would need them -- but
    // the core's own window logic leaves the low chip space uncached anyway.)
    .snoop_stb      (1'b0             ),
    .snoop_addr     (32'd0            ),
    .eth_en         (1'b0             ),
    .sel_eth        (                 ),
    .frometh        (16'h0000         ),
    .ethready       (1'b0             ),
    .slow_config    (2'b00            ),
    .aga            (1'b1             ),
    .turbochipram   (turbochipram     ),
    .turbokick      (1'b0             ),
    .cache_inhibit  (cache_inhibit    ),
    .cacheline_clr  (cacheline_clr    ),
    .ramaddr        (tg68_cad         ),
    .cpustate       (tg68_cpustate    ),
    .nResetOut      (tg68_nrst_out    ),
    .skipFetch      (                 ),
    .ramlds         (tg68_clds        ),
    .ramuds         (tg68_cuds        ),
    .CACR_out       (tg68_CACR_out    ),
    .VBR_out        (tg68_VBR_out     ),
    .rtg_addr       (                 ),
    .rtg_vbend      (                 ),
    .rtg_ext        (                 ),
    .rtg_pixelclock (                 ),
    .rtg_clut       (                 ),
    .rtg_16bit      (                 ),
    .rtg_clut_idx   (8'h00            ),
    .rtg_clut_r     (                 ),
    .rtg_clut_g     (                 ),
    .rtg_clut_b     (                 ),
    .audio_buf      (1'b0             ),
    .audio_ena      (                 ),
    .audio_int      (                 ),
    .host_req       (                 ),
    .host_ack       (1'b0             ),
    .host_q         (16'h0000         )
);

//-----------------------------------------------------------------
// Zorro-III fast RAM on the DDR3 -- wired as minimig_virtual_top.v wires it
//-----------------------------------------------------------------
wire         req_valid;
wire [ 15:0] req_wr;
wire [ 31:0] req_addr;
wire [127:0] req_wdata;
wire         req_accept;
wire         resp_valid;
wire [127:0] resp_rdata;
wire         clk100, rst100, init_done, pll_locked;
wire         ddr_ready;

assign tg68_ddrready = ddr_ready;

ddr3_fastram u_fast (
    .sysclk         (clk              ),
    .reset_in       (sdctl_rst        ),
    .cache_rst      (tg68_rst         ),
    .cacheline_clr  (cacheline_clr    ),
    .cpu_cache_ctrl (tg68_CACR_out    ),
    .ddr_ready      (ddr_ready        ),
    .cpuAddr        (tg68_ddraddr[25:1]),
    .cpustate       (tg68_ddrcpustate ),
    .cpuU           (tg68_cuds        ),
    .cpuL           (tg68_clds        ),
    .cpuWR          (tg68_cin         ),
    .cpuRD          (tg68_ddrout      ),
    .cpuena         (tg68_ddrena      ),
    .clk_mem        (clk100           ),
    .init_done      (init_done        ),
    .req_valid      (req_valid        ),
    .req_wr         (req_wr           ),
    .req_addr       (req_addr         ),
    .req_wdata      (req_wdata        ),
    .req_accept     (req_accept       ),
    .resp_valid     (resp_valid       ),
    .resp_rdata     (resp_rdata       ),
    .dbg_bstate       (),
    .dbg_cdc_ready    (),
    .dbg_cdc_req      (),
    .dbg_cdc_done     (),
    .dbg_req_rd       (),
    .dbg_req_be       (),
    .dbg_req_addr     (),
    .dbg_req_wdata    (),
    .dbg_req_tgl      (),
    .dbg_resp_rdata   (),
    .dbg_ack_tgl      (),
    .dbg_sdr_read_req (),
    .dbg_sdr_read_ack (),
    .dbg_sdr_dat_r    (),
    .dbg_sdr_write_req(),
    .dbg_sdr_write_ack(),
    .dbg_sdr_adr      (),
    .dbg_sdr_dat_w    (),
    .dbg_sdr_dqm_w    ()
);

//-----------------------------------------------------------------
// The DDR3 island and the Micron model
//-----------------------------------------------------------------
wire [ 13:0] ddr3_addr;
wire [  2:0] ddr3_ba;
wire         ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_cs_n;
wire         ddr3_cke, ddr3_odt, ddr3_reset_n, ddr3_ck_p, ddr3_ck_n;
wire [  1:0] ddr3_dm;
wire [ 15:0] ddr3_dq;
wire [  1:0] ddr3_dqs_p, ddr3_dqs_n;

// PHY read alignment: cfg_valid low, i.e. the module's own defaults
// (TPHY_RDLAT 5 / RDSEL_INIT 11, the values measured on the board).  That is
// exactly what sim/ddr3_full does and what minimig_openaars_top does in a
// non-VIO build, and it is the alignment that works against the Micron model
// with no skew inserted.  sim/ddr3_island overrides it to rdsel 15 because it
// inserts a DQ/DQS transport delay; there is none here, so overriding would
// move the sample point off the eye -- writes would still land and every read
// would come back as the wrong beat.  (That mistake cost a debug cycle here.)
ddr3_top u_isl (
   .clk_50(clk_50)
  ,.reset_n(board_reset_n)
  ,.clk100(clk100)
  ,.rst100(rst100)
  ,.init_done(init_done)
  ,.pll_locked(pll_locked)
  ,.req_valid(req_valid)
  ,.req_wr(req_wr)
  ,.req_addr(req_addr)
  ,.req_wdata(req_wdata)
  ,.req_accept(req_accept)
  ,.resp_valid(resp_valid)
  ,.resp_rdata(resp_rdata)
  ,.bist_start(1'b0)
  ,.bist_pattern(3'd0)
  ,.bist_range_log2(5'd28)
  ,.bist_mode(1'b0)
  ,.bist_busy()
  ,.bist_done()
  ,.bist_err_count()
  ,.bist_first_err_addr()
  ,.bist_first_err_xor()
  ,.bist_lines_done()
  ,.phy_cfg_valid(1'b0)
  ,.phy_dqs_inc(2'b0)
  ,.phy_dqs_rst(2'b0)
  ,.phy_dq_inc(2'b0)
  ,.phy_dq_rst(2'b0)
  ,.phy_rdlat(3'd5)
  ,.phy_rdsel(4'd0)
  ,.ddr3_addr(ddr3_addr)
  ,.ddr3_ba(ddr3_ba)
  ,.ddr3_ras_n(ddr3_ras_n)
  ,.ddr3_cas_n(ddr3_cas_n)
  ,.ddr3_we_n(ddr3_we_n)
  ,.ddr3_cs_n(ddr3_cs_n)
  ,.ddr3_cke(ddr3_cke)
  ,.ddr3_odt(ddr3_odt)
  ,.ddr3_reset_n(ddr3_reset_n)
  ,.ddr3_ck_p(ddr3_ck_p)
  ,.ddr3_ck_n(ddr3_ck_n)
  ,.ddr3_dm(ddr3_dm)
  ,.ddr3_dq(ddr3_dq)
  ,.ddr3_dqs_p(ddr3_dqs_p)
  ,.ddr3_dqs_n(ddr3_dqs_n)
);

ddr3 u_ram (
   .rst_n(ddr3_reset_n)
  ,.ck(ddr3_ck_p)
  ,.ck_n(ddr3_ck_n)
  ,.cke(ddr3_cke)
  ,.cs_n(ddr3_cs_n)
  ,.ras_n(ddr3_ras_n)
  ,.cas_n(ddr3_cas_n)
  ,.we_n(ddr3_we_n)
  ,.dm_tdqs(ddr3_dm)
  ,.ba(ddr3_ba)
  ,.addr(ddr3_addr)
  ,.dq(ddr3_dq)
  ,.dqs(ddr3_dqs_p)
  ,.dqs_n(ddr3_dqs_n)
  ,.tdqs_n()
  ,.odt(ddr3_odt)
);

defparam u_ram.DEBUG = 0;

//-----------------------------------------------------------------
// Behavioural chip RAM: 128 kB, word addressed.  Program, vectors, stack,
// mailbox.  Answered on BOTH of the wrapper's memory-side ports:
//
//   * the SDRAM port (ramaddr / cpustate[2] / ramuds / ramlds / toram ->
//     fromram / ramready).  This is where all the program's own traffic goes
//     once turbochip_d is set, i.e. sel_chipram -> sel_ram.
//   * the chipset bus (as / addr / rw / uds / lds -> data_read).  The reset
//     vector fetches happen before turbochip_d is set and go out here, and it
//     is also where a MUTANT wrapper wrongly sends the Zorro-III traffic.
//
// The two never overlap: the wrapper is in exactly one of the two paths for
// any one access.
//-----------------------------------------------------------------
localparam integer MEMW = 65536;               // 16-bit words = 128 kB
reg [15:0] chipmem [0:MEMW-1];

localparam integer MBOXW = MBOX >> 1;

integer fd, nread, i;
reg [7:0] progbytes [0:8191];
string progfile;

initial begin
  for (i = 0; i < MEMW; i = i + 1) chipmem[i] = 16'h0000;
  for (i = 0; i < 8192; i = i + 1) progbytes[i] = 8'h00;
  if (!$value$plusargs("prog=%s", progfile)) progfile = "../asm/ddr3_cpu_test.bin";
  fd = $fopen(progfile, "rb");
  if (fd == 0) begin
    $display("FATAL: cannot open program file %0s", progfile);
    $finish;
  end
  nread = $fread(progbytes, fd);
  $fclose(fd);
  $display("INFO: loaded %0d bytes of 68k program from %0s", nread, progfile);
  for (i = 0; i < nread; i = i + 1) begin
    if (i[0]) chipmem[i>>1][ 7:0] = progbytes[i];   // odd  byte = LDS
    else      chipmem[i>>1][15:8] = progbytes[i];   // even byte = UDS
  end
end

// ---- SDRAM-side port -------------------------------------------------
// cpustate[2] is ramcs, active low; [1:0] is 00 instruction read, 10 data
// read, 11 write.  ramready is a level, cleared when the select goes away,
// exactly like sdram_ctrl's cpuena.
wire        ramcs_n = tg68_cpustate[2];
wire [15:0] ramwa   = tg68_cad[16:1];

always @(posedge clk) begin
  if (!sdctl_rst) begin
    ramready <= 1'b0;
    fromram  <= 16'h0000;
  end else if (ramcs_n) begin
    ramready <= 1'b0;
  end else if (!ramready) begin
    if (tg68_cpustate[1:0] == 2'b11 && tg68_rst) begin
      if (!tg68_cuds) chipmem[ramwa][15:8] <= tg68_cin[15:8];
      if (!tg68_clds) chipmem[ramwa][ 7:0] <= tg68_cin[ 7:0];
    end else begin
      fromram <= chipmem[ramwa];
    end
    ramready <= 1'b1;
  end
end

// ---- chipset-side bus ------------------------------------------------
wire        cs_addr_ok = (tg68_adr[31:17] === 15'd0);
wire [15:0] cs_wa      = tg68_adr[16:1];

always @(*) begin
  if (cs_addr_ok) begin
    tg68_dat_in  = chipmem[cs_wa];
    tg68_dat_in2 = chipmem[cs_wa + 16'd1];
  end else begin
    tg68_dat_in  = 16'hFFFF;
    tg68_dat_in2 = 16'hFFFF;
  end
end

always @(posedge clk) begin
  if (tg68_rst && !tg68_as && !tg68_rw && cs_addr_ok) begin
    if (!tg68_uds)  chipmem[cs_wa      ][15:8] <= tg68_dat_out [15:8];
    if (!tg68_lds)  chipmem[cs_wa      ][ 7:0] <= tg68_dat_out [ 7:0];
    if (!tg68_uds2) chipmem[cs_wa + 16'd1][15:8] <= tg68_dat_out2[15:8];
    if (!tg68_lds2) chipmem[cs_wa + 16'd1][ 7:0] <= tg68_dat_out2[ 7:0];
  end
end

//-----------------------------------------------------------------
// Optional trace of the DDR3 port (+TRACE, first +TRMAX events of each kind)
//-----------------------------------------------------------------
integer trace_on = 0;
integer TRMAX    = 200;
integer tr_cpu   = 0;
integer tr_ack   = 0;
integer tr_req   = 0;
reg     ddrcs_d  = 1'b1;
reg     ddrena_d = 1'b0;

initial begin
  trace_on = $test$plusargs("TRACE");
  void'($value$plusargs("TRMAX=%d", TRMAX));
end

// The base bits must be gone from the address that reaches the backend: with
// the DDR3 moved to board 3 the OS picks the base and TG68K drops it, so
// ddraddr is the offset inside a 16 MB board and its top two bits (25:24)
// cannot be set.  Keeping a base bit here would put every access 16 MB or
// more away from where the CPU meant, silently.
//
// Only this much is checkable from the wrapper's ports.  "The DDR3 is never
// selected outside board 3" needs the CPU's current address, and the addr
// port is not it: TG68K.vhd:588 drives addr from a clocked process during
// chipset cycles only, so it is stale or X during DDR3 accesses.  That
// property is covered instead by the backdoor read below, which finds the
// data only if the base was stripped exactly right, and by sim/autoconfig,
// which checks the latched base against what the OS assigned.
integer ddr_decode_errs = 0;
always @(posedge clk) begin
  if (tg68_rst && !tg68_ddrcs && tg68_ddraddr[25:24] !== 2'b00) begin
    if (ddr_decode_errs < 20)
      $display("FAIL: ddraddr %07x has base bits set; expected an offset inside a 16 MB board",
               tg68_ddraddr);
    ddr_decode_errs = ddr_decode_errs + 1;
  end
end

always @(posedge clk) begin
  ddrcs_d  <= tg68_ddrcs;
  ddrena_d <= tg68_ddrena;
  if (trace_on && tg68_rst) begin
    if (ddrcs_d && !tg68_ddrcs && tr_cpu < TRMAX) begin
      $display("TRACE CPU  %t sel  adr=%08x st=%b lw=%b U=%b L=%b wdat=%04x",
               $time, {6'd0, tg68_ddraddr, 1'b0}, tg68_ddrcpustate[1:0],
               tg68_ddrcpustate[6], tg68_cuds, tg68_clds, tg68_cin);
      tr_cpu = tr_cpu + 1;
    end
    if (!ddrena_d && tg68_ddrena && !tg68_ddrcs && tr_ack < TRMAX) begin
      $display("TRACE CPU  %t ack  adr=%08x st=%b rdat=%04x",
               $time, {6'd0, tg68_ddraddr, 1'b0}, tg68_ddrcpustate[1:0], tg68_ddrout);
      tr_ack = tr_ack + 1;
    end
  end
end

always @(posedge clk100) begin
  if (trace_on && req_valid && req_accept && tr_req < TRMAX) begin
    $display("TRACE REQ  %t %s addr=%08x be=%04x wdata=%032x",
             $time, req_wr ? "WR" : "RD", req_addr, req_wr, req_wdata);
    tr_req = tr_req + 1;
  end
end

//-----------------------------------------------------------------
// Mailbox watcher and phase trace
//-----------------------------------------------------------------
function [31:0] mbox_l;
  input integer off;                            // byte offset from MBOX
  begin
    mbox_l = {chipmem[MBOXW + (off>>1)], chipmem[MBOXW + (off>>1) + 1]};
  end
endfunction

reg [31:0] phase_seen = 32'd0;
always @(posedge clk) begin
  if (mbox_l(16) !== phase_seen) begin
    phase_seen = mbox_l(16);
    $display("INFO: program phase %0d at %t", phase_seen, $time);
  end
end

//-----------------------------------------------------------------
// Independent DDR3 check, through the Micron model's backdoor.
//
// Address mapping is the vendored core's RBC decode (ddr3_core.sv, DDR_BRC_MODE
// = 0, COL_W 10 / BANK_W 3 / ROW_W 15):
//     bank = A[13:11]   row = A[28:14]   col = {A[10:4], 3'b000}
// and memory_read returns the whole BL8 = one 16-byte line, beat 0 in the low
// bits.  ddr3_fastram puts the 68k 16-bit word at line offset 2k in bits
// [16k+15:16k] (rtl/ddr3/ddr3_fastram.v, wr_data / sdr_dat_r), so word k of the
// returned value is the big-endian 68k word at line_base + 2k.
//-----------------------------------------------------------------
reg [127:0] bd_line;

task ddr_read_line;
  input  [31:0] a;                              // byte address, 16-byte aligned
  output [127:0] d;
  reg [2:0] bnk;
  reg [14:0] row;
  reg [9:0] col;
  reg [31:0] off;
  begin
    // The DDR3 sees the offset inside board 3, not the CPU address: TG68K
    // drops the base bits (z3ram3_size_log2).  Callers pass CPU addresses, so
    // strip the base here or the backdoor reads a part of the array the CPU
    // never wrote.
    off = a & Z3RAM3_OFFMASK;
    bnk = off[13:11];
    row = off[28:14];
    col = {off[10:4], 3'b000};
    u_ram.memory_read(bnk, row, col, d);
  end
endtask

// 16-bit 68k word at byte address a, straight out of the DRAM array
function [15:0] ddr_word;
  input [31:0] a;
  begin
    ddr_word = bd_line[{a[3:1], 4'b0000} +: 16];
  end
endfunction

integer bd_errs;
integer li, wi;
reg [31:0] la, ea, ev;
reg [15:0] gw, ew;

task bd_check_word;
  input [31:0] a;
  input [15:0] expv;
  begin
    ddr_read_line(a & ~32'hF, bd_line);
    gw = ddr_word(a);
    if (gw !== expv) begin
      if (bd_errs < 8)
        $display("       DRAM mismatch at %08x: expected %04x got %04x", a, expv, gw);
      bd_errs = bd_errs + 1;
    end
  end
endtask

task bd_check_long;
  input [31:0] a;
  input [31:0] expv;
  begin
    bd_check_word(a,        expv[31:16]);
    bd_check_word(a + 32'd2, expv[15:0]);
  end
endtask

//-----------------------------------------------------------------
// Result
//-----------------------------------------------------------------
integer nfail;

task final_report;
  input integer code;
  input [1023:0] why;
  begin
    if (ddr_decode_errs != 0) begin
      nfail = nfail + 1;
      $display("");
      $display("DDR3 CPU TB: FAIL  %0d board-3 decode errors (see FAIL lines above)",
               ddr_decode_errs);
    end
    if (code == 1) begin
      $display("");
      $display("DDR3 CPU TB: PASS  (68k program completed all phases)");
    end else if (code == 0) begin
      nfail = nfail + 1;
      $display("");
      $display("DDR3 CPU TB: FAIL  %0s", why);
      $display("       last phase reached: %0d", mbox_l(16));
    end else begin
      nfail = nfail + 1;
      $display("");
      $display("DDR3 CPU TB: FAIL code %0d  %0s", code, why);
      $display("       first mismatch address : %08x", mbox_l(4));
      $display("       expected               : %08x", mbox_l(8));
      $display("       got                    : %08x", mbox_l(12));
      $display("       last phase reached     : %0d", mbox_l(16));
    end
  end
endtask

reg [31:0] status    = 32'd0;
reg        timed_out = 1'b0;

initial begin
  #TIMEOUT;
  timed_out = 1'b1;
end

initial begin : main
  nfail     = 0;
  bd_errs   = 0;
  timed_out = 1'b0;
  status    = 32'd0;

  // Wait for the mailbox, or for the timeout process below to fire.
  // Deliberately a plain loop and not fork/join_any with a `disable`: xsim's
  // handling of `disable <named fork block>` terminated this whole initial
  // block, which looks exactly like a hung simulation.
  while (status === 32'd0 && !timed_out) begin
    @(posedge clk);
    status = mbox_l(0);
  end

  if (timed_out) begin
    final_report(0, "the 68k program never wrote the mailbox (timeout)");
  end else begin
    case (status)
      32'd1  : final_report(1, "");
      32'd2  : final_report(2,  "pattern read-back, BYTE load");
      32'd3  : final_report(3,  "pattern read-back, WORD load");
      32'd4  : final_report(4,  "pattern read-back, LONGWORD load");
      32'd5  : final_report(5,  "misaligned / line-straddling LONGWORD");
      32'd6  : final_report(6,  "MemHeader field read-back");
      32'd7  : final_report(7,  "MemHeader mh_Free read-back");
      32'd8  : final_report(8,  "counter loop, previous location");
      32'd9  : final_report(9,  "counter loop, just-written location");
      32'd10 : final_report(10, "MOVEM.L through displacement addressing, chip RAM");
      32'd11 : final_report(11, "ADDQ.L #4,(a0) longword read-modify-write, chip RAM");
      32'd12 : final_report(12, "Exec List relocation left a pointer wrong");
      32'd13 : final_report(13, "Exec List relocation left the list EMPTY -- the AllocMem symptom");
      32'd99 : final_report(99, "unexpected 68k exception (bus/address error, privilege violation, ...)");
      default: final_report(status, "unknown failure code");
    endcase
  end

  //---------------------------------------------------------------
  // Independent DRAM check.  Runs whatever the program said, so a FAIL run
  // still reports what did and did not reach the DRAM.
  //---------------------------------------------------------------
  $display("");
  $display("INFO: checking the DDR3 array through the Micron model backdoor");

  // (1) pattern region, lines 2..N-1.  Lines 0 and 1 are deliberately skipped:
  //     the MemHeader phase overwrites the first 32 bytes.
  for (li = 2; li < PATBYTES/16; li = li + 1) begin
    la = DDRBASE + PATOFF + li*16;
    ev = VBASE + li*4;
    bd_check_long(la +  0, ev);
    bd_check_long(la +  4, ev + 32'd1);
    bd_check_long(la +  8, ev + 32'd2);
    bd_check_long(la + 12, ev + 32'd3);
  end

  // (2) misaligned / straddling longwords
  for (li = 0; li < MISLINES; li = li + 1) begin
    la = DDRBASE + MISOFF + li*16;
    ev = MBASE + li*4;
    bd_check_long(la +  2, ev);
    bd_check_long(la +  6, ev + 32'd1);
    bd_check_long(la + 10, ev + 32'd2);
    bd_check_long(la + 14, ev + 32'd3);
  end

  // (3) the MemHeader at the base of the board
  bd_check_long(DDRBASE +  0, 32'd0);                       // ln_Succ
  bd_check_long(DDRBASE +  4, 32'd0);                       // ln_Pred
  bd_check_word(DDRBASE +  8, {MH_TYPE, 8'h00});            // ln_Type, ln_Pri
  bd_check_long(DDRBASE + 10, MH_NAME);                     // ln_Name
  bd_check_word(DDRBASE + 14, MH_ATTR);                     // mh_Attributes
  bd_check_long(DDRBASE + 16, MH_FIRST);
  bd_check_long(DDRBASE + 20, MH_LOWER);
  bd_check_long(DDRBASE + 24, MH_UPPER);
  bd_check_long(DDRBASE + 28, MH_FREE);

  // (4) the counter region
  for (li = 0; li < CNTN; li = li + 1)
    bd_check_long(DDRBASE + CNTOFF + li*4, CBASE + li + 32'd1);

  if (bd_errs == 0) begin
    $display("PASS: DDR3 array contents match the pattern (independent backdoor read)");
  end else begin
    $display("FAIL: DDR3 array contents wrong in %0d places (independent backdoor read)", bd_errs);
    nfail = nfail + 1;
  end

  $display("");
  if (nfail == 0) $display("DDR3 CPU TB: 2 passed, 0 failed");
  else            $display("DDR3 CPU TB: %0d checks failed", nfail);
  $display("");
  $finish;
end

endmodule
