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
// 16 sysclk = one 7.09 MHz period.  This bench does NOT compile sdram_ctrl --
// it models that side itself -- so this cadence has to be kept in step with
// the controller by hand.  It was out of step once already: D1 moved enaWRreg
// to five phases in sdram_ctrl.v and the bench happily went on pulsing four,
// so three green runs said nothing about the change they were meant to test.
// If the phases move again, they move here too.
//
// enaWRreg at ph2/5/8/11/14 (spacing 3-3-3-3-4, findings/ap68040/performance.md
// option 1a), ena7RDreg at ph6, ena7WRreg at ph14, all registered exactly as
// the controller registers them.  Note that enaWRreg no longer coincides with
// ena7RDreg -- that is the whole reason TG68K.vhd latches the chipset answer.
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
    ena28     <= (ph == 4'd2) || (ph == 4'd5) || (ph == 4'd8) ||
                 (ph == 4'd11) || (ph == 4'd14);
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
//
// cpustate[6] is the 32-bit-write flag, and it is NOT decoration.  sdram_ctrl
// turns it into cpuLongword; cpu_cache_new answers a set bit on a write by
// acknowledging at once and entering CPU_SM_WAIT_LOWORD, where it takes the
// next write cycle as a continuation of THE SAME request: one address, latched
// from the first cycle, two words banked together at A and A+2.  A core whose
// adapter instead issues two fully independent word cycles leaves the
// controller holding a half-written longword -- that is the AllocMem failure of
// 2026-09-07, and this model was blind to it because it read only cpustate[2:0].
// It is not blind any more: the paired protocol is modelled, a violation of it
// is reported, and under CPU_AP040 the bit is asserted never to be set at all
// (the AP68040's bus16 adapter cannot speak the protocol, so TG68K.vhd gates
// longword_pair to 0 for that core).
wire        ramcs_n = tg68_cpustate[2];
wire [15:0] ramwa   = tg68_cad[16:1];
wire        ram_wr  = (tg68_cpustate[1:0] == 2'b11);

reg         lw_pend;                 // a paired 32-bit write awaits its low word
reg  [15:0] lw_addr;                 // word address latched on the high-word cycle
reg  [15:0] lw_dat;                  // the high word itself
reg  [ 1:0] lw_bs;                   // its {uds,lds}, active low
integer     lw_errs;                 // protocol violations seen on this port

initial lw_errs = 0;

always @(posedge clk) begin
  if (!sdctl_rst) begin
    ramready <= 1'b0;
    fromram  <= 16'h0000;
    lw_pend  <= 1'b0;
  end else if (ramcs_n) begin
    ramready <= 1'b0;
  end else if (!ramready) begin
    if (ram_wr && tg68_rst) begin
      if (lw_pend) begin
        // Low word of a paired write.  The controller ignores this cycle's
        // address and uses the latched one, so the words land at A and A+2
        // whatever the core presents here -- but a core that has wandered
        // somewhere else entirely is a protocol violation, not a write.
        if (ramwa !== lw_addr && ramwa !== lw_addr + 16'd1) begin
          $display("FAIL: paired 32-bit write: high word at %08x, low word cycle at %08x",
                   {16'd0, lw_addr, 1'b0}, {16'd0, ramwa, 1'b0});
          lw_errs = lw_errs + 1;
        end
        if (!lw_bs[1])   chipmem[lw_addr][15:8] <= lw_dat[15:8];
        if (!lw_bs[0])   chipmem[lw_addr][ 7:0] <= lw_dat[ 7:0];
        if (!tg68_cuds)  chipmem[lw_addr + 16'd1][15:8] <= tg68_cin[15:8];
        if (!tg68_clds)  chipmem[lw_addr + 16'd1][ 7:0] <= tg68_cin[ 7:0];
        lw_pend <= 1'b0;
      end else if (tg68_cpustate[6]) begin
        // High word of a paired write: acknowledged now, committed with its
        // partner.  Nothing reaches memory yet, exactly as in the controller.
        lw_addr <= ramwa;
        lw_dat  <= tg68_cin;
        lw_bs   <= {tg68_cuds, tg68_clds};
        lw_pend <= 1'b1;
      end else begin
        if (!tg68_cuds) chipmem[ramwa][15:8] <= tg68_cin[15:8];
        if (!tg68_clds) chipmem[ramwa][ 7:0] <= tg68_cin[ 7:0];
      end
    end else begin
      if (lw_pend) begin
        $display("FAIL: a read at %08x split a paired 32-bit write started at %08x",
                 {16'd0, ramwa, 1'b0}, {16'd0, lw_addr, 1'b0});
        lw_errs = lw_errs + 1;
        lw_pend <= 1'b0;
      end
      fromram <= chipmem[ramwa];
    end
    ramready <= 1'b1;
  end
end

`ifdef CPU_AP040
// The AP68040 issues two independent word cycles for a longword, so it must
// never claim the paired protocol -- on EITHER memory port; bit 6 is the same
// bit in cpustate and in the DDR3 port's tg68_ddrcpustate.  Revert the
// longword_pair gate in TG68K.vhd and this fires.
always @(posedge clk) begin
  if (tg68_rst && sdctl_rst && tg68_cpustate[6] && tg68_cpustate[1:0] == 2'b11
      && (!tg68_cpustate[2] || !tg68_ddrcs)) begin
    if (lw_errs < 8)
      $display("FAIL: cpustate[6] set with the AP68040 as the core (%s port, addr %08x)",
               !tg68_cpustate[2] ? "SDRAM" : "DDR3",
               !tg68_cpustate[2] ? {16'd0, ramwa, 1'b0} : {6'd0, tg68_ddraddr, 1'b0});
    lw_errs = lw_errs + 1;
  end
end
`endif

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
// The MMU walker program (run.sh --mmu) writes no pattern into the DDR3, so
// the backdoor comparison below has nothing to check; its own phases are the
// test.
integer mmutest  = 0;
integer trace_on = 0;
integer TRMAX    = 200;
integer tr_cpu   = 0;
integer tr_ack   = 0;
integer tr_req   = 0;
reg     ddrcs_d  = 1'b1;
reg     ddrena_d = 1'b0;

initial begin
  mmutest  = $test$plusargs("MMUTEST");
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
// The memory port's address/select contract, on BOTH ports.
//
// sdram_ctrl.v:226 and ddr3_fastram.v:20 say the same thing: "cpuAddr must be
// stable ONE CYCLE BEFORE cpustate[2] goes low", because each registers
// cpuAddr into cpuAddr_r and it is cpuAddr_r -- not the live address -- that
// addresses the memory.  Break it and the controller fetches the previous
// access's line; on a hit inside cpu_cache_new's line buffer it still answers,
// with the wrong word, which is exactly the kind of failure that reads as
// random corruption.  Nothing checked it before: the plan's D1 note
// (findings/ap68040/plan-v2-with-ddr3.md) lists it as an untested hypothesis
// for a wrapper variant that did not boot, and says to teach this bench the
// rule first.  The line-fill router (stage D) opens the select itself, so this
// is also the check on it.
//-----------------------------------------------------------------
integer    port_setup_errs = 0;
reg [25:1] ramaddr_d, ddraddr_d;
reg        ramcsn_d = 1'b1, ddrcsn_d = 1'b1;

always @(posedge clk) begin
  if (tg68_rst && sdctl_rst) begin
    if (ramcsn_d && !tg68_cpustate[2] && tg68_cad[25:1] !== ramaddr_d) begin
      if (port_setup_errs < 8)
        $display("FAIL: SDRAM select opened at %08x with the address changing in the same cycle (was %08x)",
                 {6'd0, tg68_cad[25:1], 1'b0}, {6'd0, ramaddr_d, 1'b0});
      port_setup_errs = port_setup_errs + 1;
    end
    if (ddrcsn_d && !tg68_ddrcs && tg68_ddraddr !== ddraddr_d) begin
      if (port_setup_errs < 8)
        $display("FAIL: DDR3 select opened at %08x with the address changing in the same cycle (was %08x)",
                 {6'd0, tg68_ddraddr, 1'b0}, {6'd0, ddraddr_d, 1'b0});
      port_setup_errs = port_setup_errs + 1;
    end
  end
  ramaddr_d <= tg68_cad[25:1];
  ramcsn_d  <= tg68_cpustate[2];
  ddraddr_d <= tg68_ddraddr;
  ddrcsn_d  <= tg68_ddrcs;
end

`ifdef CPU_AP040
//-----------------------------------------------------------------
// The invariant that lets clkena carry two terms instead of six.
//
// TG68K.vhd's clkena used to OR in wk_ack, wk_berr, fl_ack and fl_err as
// deadlock guards: the core consumes those acknowledges under its own ce, and
// ce IS clkena, so an acknowledge raised while clkena happens to be stopped
// would hang the machine silently.  They were removed because they are
// redundant AND because they are expensive -- clkena is the clock enable of
// 7,391 kernel flops, and the ship build of the fill router had seven new
// failing clk_114 endpoints running from fl_active_reg into kernel CE pins.
//
// What replaces them is an invariant of the two bus routers:
//
//   whenever the walker or the line fill holds its acknowledge or its bus
//   error, it has already released the bus and the core's own bus side is
//   idle -- so bstate is "01", and clkena's first term enables the core
//   anyway.
//
// bstate is cpustate[1:0] here, and clkena is cpustate[5] (TG68K.vhd builds
// cpustate as longword_pair & clkena & slower(1:0) & ramcs & bstate).  Two
// checks, because the invariant has two halves:
//
//   ack_idle_errs   an acknowledge held in a cycle where bstate is not "01".
//                   This is the property that makes the removal safe.
//   ack_dry_errs    an acknowledge that dropped without the CPU having been
//                   enabled once while it was up.  A hang would already trip
//                   the stall watchdog; this names the cause instead of
//                   leaving a timeout to be diagnosed.
//
// Both hold on the OLD code too -- they are properties of the routers, which
// this change did not touch -- so a run of the old wrapper passes them.  That
// is the point: it is what makes the four removed terms redundant rather than
// load-bearing.  Measured, not argued: see the fix-round-2 section of
// .superpowers/sdd/plan-v2-with-ddr3/task-3-report.md.
//-----------------------------------------------------------------
integer ack_idle_errs = 0;
integer ack_dry_errs  = 0;

wire wk_ack_w  = ddr3_cpu_tb.tg68k.wk_ack;
wire wk_berr_w = ddr3_cpu_tb.tg68k.wk_berr;
wire fl_ack_w  = ddr3_cpu_tb.tg68k.fl_ack;
wire fl_err_w  = ddr3_cpu_tb.tg68k.fl_err;

wire any_ack   = wk_ack_w | wk_berr_w | fl_ack_w | fl_err_w;
reg  any_ack_d = 1'b0;
reg  ack_ena   = 1'b0;          // clkena seen while this acknowledge was up

always @(posedge clk) begin
  if (tg68_rst) begin
    if (any_ack && tg68_cpustate[1:0] !== 2'b01) begin
      if (ack_idle_errs < 8)
        $display("FAIL: acknowledge held with the bus NOT idle (wk_ack=%b wk_berr=%b fl_ack=%b fl_err=%b, bstate=%b) at %t",
                 wk_ack_w, wk_berr_w, fl_ack_w, fl_err_w, tg68_cpustate[1:0], $time);
      ack_idle_errs = ack_idle_errs + 1;
    end
    if (any_ack && tg68_cpustate[5]) ack_ena <= 1'b1;
    if (!any_ack &&  any_ack_d) begin
      if (!ack_ena) begin
        if (ack_dry_errs < 8)
          $display("FAIL: an acknowledge dropped without the CPU ever being enabled while it was up (t = %t)",
                   $time);
        ack_dry_errs = ack_dry_errs + 1;
      end
      ack_ena <= 1'b0;
    end
  end
  any_ack_d <= any_ack;
end

//-----------------------------------------------------------------
// Stage D: the line-fill channel.
//
// Two counters and one assertion, all from inside the DUT because the channel
// is invisible at the wrapper's ports: a channel fill and eight ordinary word
// reads look the same from outside, which is the point of it.
//
//   fill_ch  lines the wrapper served over the channel (fl_busy rising)
//   fill_ad  lines the cache pulled down the bus16 adapter instead, i.e.
//            C_FILL entries (ap040_cache.v:233).  With fill_ena_zorro = 1 and
//            fill_ena_chip = 0 these are the chip/kick/slow lines and the
//            cache-inhibited ones; a Zorro-window miss must never be one.
//   fill_err lines answered with a bus error (fl_err) -- expected zero, and a
//            FAIL if it is not: the SoC never raises a bus error, it
//            auto-completes an undecoded address with $FFFF.
//   fill_und channel fills whose address decoded to NOTHING and were therefore
//            served as a line of all ones.  The 68k program takes exactly one,
//            reading UNDECODED = $42000000 -- inside the core's cacheable
//            cache_z3_base1 window ($4xxxxxxx) but outside every board in this
//            bench.  Before the auto-complete arm existed that read raised
//            fl_err, the cache took C_FERR and the program died in its access
//            fault handler with status 99.
//
// The assertion is the ordering rule: the walker router and the fill router
// drive the same muxed bus signals, so they must never own them at once.
//-----------------------------------------------------------------
localparam [3:0] CST_FILL  = 4'd4;    // C_FILL,  ap040_cache.v:233
localparam [3:0] CST_FILLC = 4'd8;    // C_FILLC, ap040_cache.v:235

integer fill_ch    = 0;
integer fill_ad    = 0;
integer fill_be    = 0;
integer fill_und   = 0;
integer fill_excl  = 0;

wire       fl_ok_w     = ddr3_cpu_tb.tg68k.fl_ok;
wire       fl_busy_w   = ddr3_cpu_tb.tg68k.fl_busy;
wire       fl_active_w = ddr3_cpu_tb.tg68k.fl_active;
wire       wk_active_w = ddr3_cpu_tb.tg68k.wk_active;
// fl_err_w is declared with the acknowledge-invariant checks above.
wire [3:0] cst_w       = ddr3_cpu_tb.tg68k.g_ap040.ap040.g_cache.cache.cst;

reg       fl_busy_d = 1'b0;
reg       fl_err_d  = 1'b0;
reg [3:0] cst_d     = 4'd0;

always @(posedge clk) begin
  if (tg68_rst) begin
    // fl_busy rises at the edge into FL_DEC, so the cycle sampled here is
    // FL_DEC itself -- the one where the router reads fl_ok and decides
    // between a memory transfer and the auto-complete.
    if ( fl_busy_w && !fl_busy_d) begin
      fill_ch = fill_ch + 1;
      if (!fl_ok_w) fill_und = fill_und + 1;
    end
    if ( fl_err_w  && !fl_err_d )              fill_be = fill_be + 1;
    if ((cst_w === CST_FILL) && (cst_d !== CST_FILL)) fill_ad = fill_ad + 1;
    if (wk_active_w && fl_active_w) begin
      if (fill_excl < 8)
        $display("FAIL: the walker and the line fill own the bus at the same time (t = %t)", $time);
      fill_excl = fill_excl + 1;
    end
  end
  fl_busy_d <= fl_busy_w;
  fl_err_d  <= fl_err_w;
  cst_d     <= cst_w;
end
`endif

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
integer    stall_cnt   = 0;
reg        stalled     = 1'b0;

// The stall watchdog.  A walk that never acknowledges, or a clkena that stops
// while the walker owns the bus, does not crash and does not fault: the
// machine simply stops, and without this it reports as a bare timeout at the
// end of a 2.5 ms simulation with nothing to say about where.  STALL is
// generous -- phase 1 of the pattern program legitimately takes ~560 us -- so
// this fires on a stop, not on slow progress.
// 8815 ps a cycle.  The threshold has to be per program, because the two have
// very different phase lengths, and one that fits the pattern program is
// useless for catching a wedged walk:
//
//   pattern program  phases 2 -> 3 is the longest legitimate gap, 1.18 ms
//                    (134k cycles), so anything tighter is a false failure --
//                    and one was: 120k cycles failed a healthy run at phase 2
//   MMU program      the table build is 733 us (83k cycles); everything after
//                    it is 5-20 us, so 1.06 ms is generous and still catches a
//                    wedged walk well inside the 2.5 ms TIMEOUT -- that pair of
//                    numbers is measured, from the passing run and from
//                    --mmumutant, which fired at 1.87 ms
//
// The pattern program's own 2.5 ms TIMEOUT is the backstop for it; the tight
// threshold goes where it is wanted, on the walker.
localparam integer STALL_PAT = 300_000;
localparam integer STALL_MMU = 120_000;
wire [31:0] stall_limit = mmutest ? STALL_MMU : STALL_PAT;

always @(posedge clk) begin
  if (mbox_l(16) !== phase_seen) begin
    phase_seen = mbox_l(16);
    stall_cnt  = 0;
    $display("INFO: program phase %0d at %t", phase_seen, $time);
  end else if (!stalled && mbox_l(0) === 32'd0) begin
    stall_cnt = stall_cnt + 1;
    if (stall_cnt > stall_limit) begin
      stalled = 1'b1;
      $display("");
      $display("FAIL: no progress for %0d cycles at phase %0d (t = %t).  A walk",
               stall_limit, phase_seen, $time);
      $display("      that never acknowledges, or a clkena stopped while the");
      $display("      walker owns the bus, looks exactly like this.");
    end
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
  while (status === 32'd0 && !timed_out && !stalled) begin
    @(posedge clk);
    status = mbox_l(0);
  end

  if (stalled) begin
    final_report(0, "the program stopped making progress (stall watchdog)");
  end else if (timed_out) begin
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
      32'd14 : final_report(14, "cacheable read of an undecoded hole in the Zorro III window");
      // stage B, the MMU walker program
      32'd20 : final_report(20, "translated read of a warm page");
      32'd21 : final_report(21, "translated write/read-back of a warm page");
      32'd22 : final_report(22, "cold page (U/M clear): data wrong after the write-backs");
      32'd23 : final_report(23, "the page descriptor did not come back with U and M set");
      32'd24 : final_report(24, "an invalid page descriptor did not fault");
      32'd25 : final_report(25, "a table branch into undecoded space did not fault (walker_berr)");
      32'd26 : final_report(26, "data wrong after translation was turned off again");
      32'd99 : final_report(99, "unexpected 68k exception (bus/address error, privilege violation, ...)");
      default: final_report(status, "unknown failure code");
    endcase
  end

  //---------------------------------------------------------------
  // Independent DRAM check.  Runs whatever the program said, so a FAIL run
  // still reports what did and did not reach the DRAM.
  //---------------------------------------------------------------
  if (mmutest) begin
    $display("");
    $display("INFO: MMU walker program -- no pattern in the DDR3 to check");
  end else begin
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
  end

  if (lw_errs != 0) begin
    $display("");
    $display("DDR3 CPU TB: FAIL  %0d 32-bit-write protocol violations on the RAM port",
             lw_errs);
    nfail = nfail + 1;
  end

  if (port_setup_errs != 0) begin
    $display("");
    $display("DDR3 CPU TB: FAIL  %0d chip selects opened without a settled address",
             port_setup_errs);
    nfail = nfail + 1;
  end

`ifdef CPU_AP040
  $display("");
  $display("INFO: cache line fills -- %0d over the channel (%0d of them undecoded, auto-completed), %0d down the adapter, %0d bus errors",
           fill_ch, fill_und, fill_ad, fill_be);
  if (fill_be != 0) begin
    $display("DDR3 CPU TB: FAIL  %0d line fills answered with a bus error; this SoC auto-completes",
             fill_be);
    $display("       an address that decodes to nothing with $FFFF and never raises one");
    nfail = nfail + 1;
  end
  // The pattern program reads UNDECODED once, after phase 8.  With the channel
  // in use that read MUST be a channel fill taking the auto-complete arm; with
  // the channel off (--nofill, fill_ch = 0) it is eight adapter reads instead
  // and there is nothing here to check.  The MMU program does not read it.
  if (!mmutest && fill_ch != 0 && fill_und == 0) begin
    $display("DDR3 CPU TB: FAIL  the cacheable read of the undecoded Zorro III hole did not");
    $display("       take a line fill over the channel");
    nfail = nfail + 1;
  end
  if (fill_excl != 0) begin
    $display("DDR3 CPU TB: FAIL  %0d cycles with the walker and the line fill both on the bus",
             fill_excl);
    nfail = nfail + 1;
  end
  if (ack_idle_errs != 0) begin
    $display("DDR3 CPU TB: FAIL  %0d cycles with a router acknowledge held while the bus was NOT idle;",
             ack_idle_errs);
    $display("       clkena's bstate term does not cover those, so the removed ack terms were needed");
    nfail = nfail + 1;
  end
  if (ack_dry_errs != 0) begin
    $display("DDR3 CPU TB: FAIL  %0d router acknowledges dropped without the CPU being enabled while up",
             ack_dry_errs);
    nfail = nfail + 1;
  end
`endif

  $display("");
  if (nfail == 0) $display("DDR3 CPU TB: 2 passed, 0 failed");
  else            $display("DDR3 CPU TB: %0d checks failed", nfail);
  $display("");
  $finish;
end

endmodule
