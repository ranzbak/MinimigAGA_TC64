// real_sdram.vh -- the REAL rtl/sdram/sdram_ctrl.v, the vendor SDRAM part, and
// a chipset DMA master, in place of this bench's behavioural memory model.
//
// WHY.  Every hardware control points at one configuration and no bench runs
// it.  ddr3_cpu has the real TG68K wrapper and the real AP68040 but MODELS the
// SDRAM side (a chipmem array, a line-buffer model, and its own enable
// generation).  sim/sdram_coherency has the real sdram_ctrl and a real chipset
// master but a hand-written CPU agent.  The corruption needs REAL CPU + REAL
// WRAPPER + REAL sdram_ctrl + CHIPSET DMA together, with Turbo chip RAM on.
// That combination has never been simulated anywhere.
//
// Included only under `REALSDRAM, so every existing leg stays bit-for-bit as
// it was.
//
// A second thing this fixes by construction: the bench generates enaWRreg /
// ena7RDreg / ena7WRreg itself from rtl/sdram/cpu_enable_cadence.v.  On
// hardware those are sdram_ctrl's OUTPUTS, and the corruption is known to
// depend on the CPU's phase relationship to the sixteen-phase SDRAM round --
// so a bench that invents its own enables is wrong on exactly the axis under
// investigation.  Here they come from the controller itself.

// ---------------------------------------------------------------- SDRAM pins
wire [12:0] sd_addr;
wire [ 3:0] sd_cs;
wire [ 1:0] sd_ba;
wire        sd_we, sd_ras, sd_cas;
wire [ 1:0] sd_dqm;
wire [15:0] sdata_fpga;
wire        sdram_reset_out;

// Board and IOB delays, FAST corner.  The coherency work uses the fast corner
// because at the slow corner the read path is one word late by itself
// (findings/constraints/sdram-sim-results.md) and every read would fail for a
// reason that is not coherency.
localparam integer DLY_CLK_PIN = 6999;
localparam integer T_CO        = 200;
localparam integer T_IN        = 493;

reg pin_clk = 1'b0;
always @(clk) pin_clk <= #DLY_CLK_PIN clk;

wire [12:0] pin_addr;  assign #T_CO pin_addr = sd_addr;
wire [ 1:0] pin_ba;    assign #T_CO pin_ba   = sd_ba;
wire        pin_cs;    assign #T_CO pin_cs   = sd_cs[0];
wire        pin_ras;   assign #T_CO pin_ras  = sd_ras;
wire        pin_cas;   assign #T_CO pin_cas  = sd_cas;
wire        pin_we;    assign #T_CO pin_we   = sd_we;
wire [ 1:0] pin_dqm;   assign #T_CO pin_dqm  = sd_dqm;

wire        sd_oe = u_sdram.sdata_oe;
reg         sd_oe_d = 1'b0;
always @(sd_oe) sd_oe_d <= #T_CO sd_oe;
reg  [15:0] sd_out_d;
always @(u_sdram.sdata_out) sd_out_d <= #T_CO u_sdram.sdata_out;
wire [15:0] dq_pin = sd_oe_d ? sd_out_d : 16'bz;
reg  [15:0] dq_in_d = 16'bz;
always @(dq_pin) dq_in_d <= #T_IN dq_pin;
assign sdata_fpga = sd_oe ? 16'bz : dq_in_d;

// ---------------------------------------------------------------- chipset DMA master
// Duty-cycled, not back to back.  Chip RAM is bank 0, a CPU access there can
// only use slot 1 (cpu_slot2ok requires a non-zero bank), and slot 1 goes to
// the chipset first -- so an agent that never pauses starves the CPU port
// completely and the run livelocks.  Real DMA has gaps.
reg  [23:1] chipAddr = 23'd0;
reg         chipL  = 1'b1, chipU  = 1'b1;
reg         chipL2 = 1'b1, chipU2 = 1'b1;
reg         chipRW = 1'b1, chip_dma = 1'b1;
reg  [15:0] chipWR = 16'd0, chipWR2 = 16'd0;
wire [15:0] chipRD;
wire [47:0] chip48;

// ---------------------------------------------------------------- the controller
sdram_ctrl u_sdram (
    .sysclk         (clk              ),
    .clk7_en        (clk7_en_real     ),
    .reset_in       (sdram_reset_in   ),
    .cache_rst      (sdram_reset_in   ),
    .cache_inhibit  (cache_inhibit    ),
    .cacheline_clr  (cacheline_clr    ),
    .cpu_cache_ctrl (tg68_CACR_out    ),
`ifdef WRSYNC
    // Unposted CPU writes.  Every CPU write reaching sdram_ctrl in this bench is
    // chip RAM (fast RAM goes to ddr3_fastram), so tying it high is exactly what
    // the wrapper's sel_chipram would drive.
    .cpu_wr_sync    (1'b1             ),
`else
    .cpu_wr_sync    (1'b0             ),
`endif
    .reset_out      (sdram_reset_out  ),

    .sdaddr         (sd_addr          ),
    .sd_cs          (sd_cs            ),
    .ba             (sd_ba            ),
    .sd_we          (sd_we            ),
    .sd_ras         (sd_ras           ),
    .sd_cas         (sd_cas           ),
    .dqm            (sd_dqm           ),
    .sdata          (sdata_fpga       ),

    .hostWR         (32'd0            ),
    .hostAddr       (22'd0            ),
    .hostce         (1'b0             ),
    .hostwe         (1'b0             ),
    .hostbytesel    (4'b0000          ),
    .hostRD         (                 ),
    .hostena        (                 ),

    .chipAddr       (chipAddr         ),
    .chipL          (chipL            ),
    .chipU          (chipU            ),
    .chipL2         (chipL2           ),
    .chipU2         (chipU2           ),
    .chipRW         (chipRW           ),
    .chip_dma       (chip_dma         ),
    .chipWR         (chipWR           ),
    .chipWR2        (chipWR2          ),
    .chipRD         (chipRD           ),
    .chip48         (chip48           ),

    .rtgAddr        (26'd0            ),
    .rtgce          (1'b0             ),
    .rtgfill        (                 ),
    .rtgRd          (                 ),
    .audAddr        (23'd0            ),
    .audce          (1'b0             ),
    .audfill        (                 ),
    .audRd          (                 ),

    // The CPU side, straight off the wrapper -- no model in between.
    .cpuAddr        (tg68_cad[25:1]   ),
    .cpustate       (tg68_cpustate    ),
    .cpuL           (tg68_clds        ),
    .cpuU           (tg68_cuds        ),
    .cpuWR          (tg68_cin         ),
    .cpuRD          (fromram_real     ),

    // The enables the bench used to invent for itself.
    .enaWRreg       (enaWR_real       ),
    .ena7RDreg      (ena7RD_real      ),
    .ena7WRreg      (ena7WR_real      ),
    .cpuena         (ramready_real    )
);

sdr16mx16 u_sdram_chip (
    .Dq(dq_pin), .Addr(pin_addr), .Ba(pin_ba), .Clk(pin_clk), .Cke(1'b1),
    .Cs_n(pin_cs), .Ras_n(pin_ras), .Cas_n(pin_cas), .We_n(pin_we),
    .LDQM(pin_dqm[0]), .UDQM(pin_dqm[1])
);
