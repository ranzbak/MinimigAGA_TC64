//-----------------------------------------------------------------
// ddr3_top - the DDR3 "island"
//
// Self-contained 256 MB DDR3 subsystem: its own PLL, its own reset, the
// vendored ultra-embedded DLL-off controller and its Xilinx 7-series DFI PHY,
// and a bring-up BIST.  Everything inside runs on clk100; the only signals
// that leave the island are the native 128-bit request port (also clk100),
// the status/control bundle for a VIO, and the 47 DDR3 board pins.
//
// See findings/ddr3/design.md and lib/core_ddr3_controller/README.md.
// The parameter values below are the ones proven by the vendored testbench on
// this exact core/PHY pair; do not change them without re-running that bench.
//
// Request port contract (clk100 domain), matching rtl/ddr3/ddr3_cdc.v:
//   * req_valid is HELD until req_accept (valid/ready), it is not a pulse;
//     req_wr / req_addr / req_wdata must be stable for that whole time.
//   * req_wr == 0 with req_valid is a read; req_wr != 0 is a write with
//     those 16 active-high byte enables.  Never both.
//   * resp_valid pulses exactly once per accepted request, for writes as
//     well as reads.  For a read, resp_rdata is valid in that cycle only.
//     For a write it only means the command was issued to the DRAM.
//   * resp_valid can never be asserted in the same cycle as req_accept.
//   * req_addr is a byte address and must be 16-byte aligned; bits [3:0] are
//     ignored by the controller.
//
// While the BIST is running (bist_busy) the external port is held off
// (req_accept low) and the BIST owns the controller.  The external requester
// is expected to be idle during bring-up.
//
// rst100 is asserted whenever the board reset is asserted or the island PLL
// is unlocked, and is released synchronously to clk100 four cycles later.
// It is deliberately NOT a runtime-controllable reset: the cache backend ties
// its CDC destination reset to 0, so resetting the island mid-request would
// let a stale response through.  Power-on only.
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module ddr3_top
(
    // Clock / reset
     input           clk_50          // 50 MHz board oscillator
    ,input           reset_n         // asynchronous, active low, board reset chain

    // Island clock and reset, for the user of the request port
    ,output          clk100
    ,output          rst100
    ,output          init_done       // controller has finished its init sequence
    ,output          pll_locked

    // Native 128-bit request port (clk100 domain)
    ,input           req_valid
    ,input  [ 15:0]  req_wr
    ,input  [ 31:0]  req_addr
    ,input  [127:0]  req_wdata
    ,output          req_accept
    ,output          resp_valid
    ,output [127:0]  resp_rdata

    // BIST / PHY control bundle (clk100 domain; plain registers for a VIO)
    ,input           bist_start
    ,input  [  2:0]  bist_pattern
    ,input  [  4:0]  bist_range_log2
    ,input           bist_mode
    ,output          bist_busy
    ,output          bist_done
    ,output [ 31:0]  bist_err_count
    ,output [ 31:0]  bist_first_err_addr
    ,output [ 31:0]  bist_first_err_xor
    ,output [ 31:0]  bist_lines_done
    ,input           phy_cfg_valid
    ,input  [  1:0]  phy_dqs_inc
    ,input  [  1:0]  phy_dqs_rst
    ,input  [  1:0]  phy_dq_inc
    ,input  [  1:0]  phy_dq_rst
    ,input  [  2:0]  phy_rdlat
    ,input  [  3:0]  phy_rdsel

    // DDR3 pins (names as in the QMTECH XC7A100T core board DDR3.ucf)
    ,output [ 13:0]  ddr3_addr
    ,output [  2:0]  ddr3_ba
    ,output          ddr3_ras_n
    ,output          ddr3_cas_n
    ,output          ddr3_we_n
    ,output          ddr3_cs_n      // no board pin on the QMTECH module (CS# is
                                    // strapped low); brought out for simulation
                                    // and for boards that do route it.
    ,output          ddr3_cke
    ,output          ddr3_odt
    ,output          ddr3_reset_n
    ,output          ddr3_ck_p
    ,output          ddr3_ck_n
    ,output [  1:0]  ddr3_dm
    ,inout  [ 15:0]  ddr3_dq
    ,inout  [  1:0]  ddr3_dqs_p
    ,inout  [  1:0]  ddr3_dqs_n
);

//-----------------------------------------------------------------
// Clocking
//-----------------------------------------------------------------
wire clk100_w;
wire clk400_w;
wire clk200_w;
wire clk400_90_w;
wire pll_locked_w;

ddr3_pll u_pll
(
     .clkref_i(clk_50)
    ,.rst_i(1'b0)                  // the PLL free-runs; the fabric is held in
                                   // reset by rst100_w until LOCKED is high.
    ,.clk100_o(clk100_w)
    ,.clk400_o(clk400_w)
    ,.clk200_o(clk200_w)
    ,.clk400_90_o(clk400_90_w)
    ,.locked_o(pll_locked_w)
);

assign clk100     = clk100_w;
assign pll_locked = pll_locked_w;

//-----------------------------------------------------------------
// Reset synchroniser
//
// Asynchronous assert (board reset low, or PLL unlocked), synchronous release
// four clk100 cycles after both conditions clear.
//-----------------------------------------------------------------
wire arst_w = (~reset_n) | (~pll_locked_w);

(* ASYNC_REG = "TRUE" *) reg [3:0] rst_sync_q;

always @(posedge clk100_w or posedge arst_w)
if (arst_w)
    rst_sync_q <= 4'hF;
else
    rst_sync_q <= {rst_sync_q[2:0], 1'b0};

wire rst100_w = rst_sync_q[3];
assign rst100 = rst100_w;

//-----------------------------------------------------------------
// BIST
//-----------------------------------------------------------------
wire [ 15:0] bist_wr_w;
wire         bist_rd_w;
wire [ 31:0] bist_addr_w;
wire [127:0] bist_wdata_w;
wire         bist_busy_w;
wire         phy_cfg_valid_w;
wire [ 31:0] phy_cfg_w;

wire         mem_accept_w;
wire         mem_ack_w;
wire [127:0] mem_read_data_w;

//-----------------------------------------------------------------
// init_done, registered before it leaves the island
//
// ddr3_core drives init_done_o combinationally from its state register.  Its
// only consumer is the two-flop synchroniser in rtl/ddr3/ddr3_fastram.v
// (init_sync), and combinational logic immediately in front of a synchroniser
// is a real hazard -- a decode glitch can be captured as a spurious "ready" --
// as well as a Critical report_cdc finding (CDC-10, "combinational logic
// detected before a synchronizer").  One clk100 flop here fixes both.  The
// signal goes high once, after calibration, and never changes again, so the
// extra cycle of latency is free.
//-----------------------------------------------------------------
wire         init_done_w;
reg          init_done_q;

always @(posedge clk100_w)
if (rst100_w)
    init_done_q <= 1'b0;
else
    init_done_q <= init_done_w;

assign init_done = init_done_q;

ddr3_bist u_bist
(
     .clk_i(clk100_w)
    ,.rst_i(rst100_w)

    ,.start_i(bist_start)
    ,.pattern_i(bist_pattern)
    ,.range_log2_i(bist_range_log2)
    ,.mode_i(bist_mode)

    ,.busy_o(bist_busy_w)
    ,.done_o(bist_done)
    ,.err_count_o(bist_err_count)
    ,.first_err_addr_o(bist_first_err_addr)
    ,.first_err_xor_o(bist_first_err_xor)
    ,.lines_done_o(bist_lines_done)

    ,.phy_cfg_valid_i(phy_cfg_valid)
    ,.phy_dqs_inc_i(phy_dqs_inc)
    ,.phy_dqs_rst_i(phy_dqs_rst)
    ,.phy_dq_inc_i(phy_dq_inc)
    ,.phy_dq_rst_i(phy_dq_rst)
    ,.phy_rdlat_i(phy_rdlat)
    ,.phy_rdsel_i(phy_rdsel)
    ,.phy_cfg_valid_o(phy_cfg_valid_w)
    ,.phy_cfg_o(phy_cfg_w)

    ,.mem_wr_o(bist_wr_w)
    ,.mem_rd_o(bist_rd_w)
    ,.mem_addr_o(bist_addr_w)
    ,.mem_write_data_o(bist_wdata_w)
    ,.mem_accept_i(mem_accept_w)
    ,.mem_ack_i(mem_ack_w)
    ,.mem_read_data_i(mem_read_data_w)
);

assign bist_busy = bist_busy_w;

//-----------------------------------------------------------------
// Native port arbiter
//
// A plain mux: the BIST owns the port while it is busy, the external port owns
// it otherwise.  The external requester is idle during BIST (bring-up only),
// and bist_busy_w only changes while both sides are idle, so no transaction
// can be cut in half.
//-----------------------------------------------------------------
wire [ 15:0] core_wr_w    = bist_busy_w ? bist_wr_w    : (req_valid ? req_wr : 16'b0);
wire         core_rd_w    = bist_busy_w ? bist_rd_w    : (req_valid && (req_wr == 16'b0));
wire [ 31:0] core_addr_w  = bist_busy_w ? bist_addr_w  : req_addr;
wire [127:0] core_wdata_w = bist_busy_w ? bist_wdata_w : req_wdata;

assign req_accept = mem_accept_w & ~bist_busy_w;
assign resp_valid = mem_ack_w    & ~bist_busy_w;
assign resp_rdata = mem_read_data_w;

//-----------------------------------------------------------------
// DFI between core and PHY
//-----------------------------------------------------------------
wire [ 14:0] dfi_address_w;
wire [  2:0] dfi_bank_w;
wire         dfi_cas_n_w;
wire         dfi_cke_w;
wire         dfi_cs_n_w;
wire         dfi_odt_w;
wire         dfi_ras_n_w;
wire         dfi_reset_n_w;
wire         dfi_we_n_w;
wire [ 31:0] dfi_wrdata_w;
wire         dfi_wrdata_en_w;
wire [  3:0] dfi_wrdata_mask_w;
wire         dfi_rddata_en_w;
wire [ 31:0] dfi_rddata_w;
wire         dfi_rddata_valid_w;
wire [  1:0] dfi_rddata_dnv_w;

//-----------------------------------------------------------------
// Controller
//
// cfg_enable_i must be tied high: with it low the core parks in STATE_IDLE.
// cfg_stb_i / cfg_data_i are a raw-command injection port that is only sampled
// while cfg_enable_i is low; the mode registers for DLL-off operation are
// hard-coded inside the core and issued by STATE_INIT.  (README.md, "cfg_* on
// the core is NOT the PHY delay control".)
//-----------------------------------------------------------------
ddr3_core
#(
     .DDR_WRITE_LATENCY(4)          // CWL 6 -> tPHY_WRLAT 3 inside ddr3_dfi_seq
    ,.DDR_READ_LATENCY(4)           // CL  6 -> tPHY_RDLAT 3 inside ddr3_dfi_seq
    ,.DDR_MHZ(100)
)
u_core
(
     .clk_i(clk100_w)
    ,.rst_i(rst100_w)

    ,.cfg_enable_i(1'b1)
    ,.cfg_stb_i(1'b0)
    ,.cfg_data_i(32'b0)
    ,.cfg_stall_o()

    ,.init_done_o(init_done_w)

    ,.inport_wr_i(core_wr_w)
    ,.inport_rd_i(core_rd_w)
    ,.inport_addr_i(core_addr_w)
    ,.inport_write_data_i(core_wdata_w)
    ,.inport_req_id_i(16'b0)
    ,.inport_accept_o(mem_accept_w)
    ,.inport_ack_o(mem_ack_w)
    ,.inport_error_o()
    ,.inport_resp_id_o()
    ,.inport_read_data_o(mem_read_data_w)

    ,.dfi_address_o(dfi_address_w)
    ,.dfi_bank_o(dfi_bank_w)
    ,.dfi_cas_n_o(dfi_cas_n_w)
    ,.dfi_cke_o(dfi_cke_w)
    ,.dfi_cs_n_o(dfi_cs_n_w)
    ,.dfi_odt_o(dfi_odt_w)
    ,.dfi_ras_n_o(dfi_ras_n_w)
    ,.dfi_reset_n_o(dfi_reset_n_w)
    ,.dfi_we_n_o(dfi_we_n_w)
    ,.dfi_wrdata_o(dfi_wrdata_w)
    ,.dfi_wrdata_en_o(dfi_wrdata_en_w)
    ,.dfi_wrdata_mask_o(dfi_wrdata_mask_w)
    ,.dfi_rddata_en_o(dfi_rddata_en_w)
    ,.dfi_rddata_i(dfi_rddata_w)
    ,.dfi_rddata_valid_i(dfi_rddata_valid_w)
    ,.dfi_rddata_dnv_i(dfi_rddata_dnv_w)
);

//-----------------------------------------------------------------
// PHY
//
// The PHY instantiates its own IDELAYCTRL on clk_ref_i, so the island only has
// to supply the 200 MHz reference.  Do not add a second one.
// cfg_valid_i / cfg_i are the DQ tap, read-latency and read-sample controls;
// the vendored testbench leaves them floating, we drive them from the BIST's
// register block so the bring-up sweep can use a VIO.  The DQS tap fields
// (cfg_i[19:16]) are now no-ops - the read path is oversampled off clk400 and
// clk100, not strobed by DQS (findings/ddr3/bringup.md, "Read-path rework").
// TPHY_RDLAT(5) / RDSEL_INIT(4'd11) are MEASURED ON THE BOARD (stage-A2 JTAG
// BIST): the whole passing window there is rdlat 5 with rdsel 6,7,10,11,12,13
// (plus its alias rdlat 6, rdsel 0,1), and rdsel 11 is its centre.
// sim/ddr3_island finds the same window shape one beat (4 oversamples, 5 ns)
// earlier, because the Micron model's DLL-off strobe timing is not
// representative - hardware is the source of truth for these two numbers.
// See findings/ddr3/bringup.md, "Read-path rework".
//-----------------------------------------------------------------
ddr3_dfi_phy
#(
     .REFCLK_FREQUENCY(200)
    ,.DQ_TAP_DELAY_INIT(0)          // per-lane DQ IDELAYE2 start tap (78 ps each);
                                    // the board is clean from tap 0 to 22
    ,.TPHY_RDLAT(5)                 // clk100 cycles, dfi_rddata_en -> rddata_valid
    ,.RDSEL_INIT(4'd11)             // oversample select, see the PHY header
)                                   // DQS_TAP_DELAY_INIT is dead: the read path
                                    // no longer captures with the DQS strobe.
u_phy
(
     .clk_i(clk100_w)
    ,.clk_ddr_i(clk400_w)
    ,.clk_ddr90_i(clk400_90_w)
    ,.clk_ref_i(clk200_w)
    ,.rst_i(rst100_w)

    ,.cfg_valid_i(phy_cfg_valid_w)
    ,.cfg_i(phy_cfg_w)

    ,.dfi_address_i(dfi_address_w)
    ,.dfi_bank_i(dfi_bank_w)
    ,.dfi_cas_n_i(dfi_cas_n_w)
    ,.dfi_cke_i(dfi_cke_w)
    ,.dfi_cs_n_i(dfi_cs_n_w)
    ,.dfi_odt_i(dfi_odt_w)
    ,.dfi_ras_n_i(dfi_ras_n_w)
    ,.dfi_reset_n_i(dfi_reset_n_w)
    ,.dfi_we_n_i(dfi_we_n_w)

    ,.dfi_wrdata_i(dfi_wrdata_w)
    ,.dfi_wrdata_en_i(dfi_wrdata_en_w)
    ,.dfi_wrdata_mask_i(dfi_wrdata_mask_w)
    ,.dfi_rddata_en_i(dfi_rddata_en_w)

    ,.dfi_rddata_o(dfi_rddata_w)
    ,.dfi_rddata_valid_o(dfi_rddata_valid_w)
    ,.dfi_rddata_dnv_o(dfi_rddata_dnv_w)

    ,.ddr3_ck_p_o(ddr3_ck_p)
    ,.ddr3_ck_n_o(ddr3_ck_n)
    ,.ddr3_cke_o(ddr3_cke)
    ,.ddr3_reset_n_o(ddr3_reset_n)
    ,.ddr3_ras_n_o(ddr3_ras_n)
    ,.ddr3_cas_n_o(ddr3_cas_n)
    ,.ddr3_we_n_o(ddr3_we_n)
    ,.ddr3_cs_n_o(ddr3_cs_n)
    ,.ddr3_ba_o(ddr3_ba)
    ,.ddr3_addr_o(ddr3_addr)
    ,.ddr3_odt_o(ddr3_odt)
    ,.ddr3_dm_o(ddr3_dm)
    ,.ddr3_dqs_p_io(ddr3_dqs_p)
    ,.ddr3_dqs_n_io(ddr3_dqs_n)
    ,.ddr3_dq_io(ddr3_dq)
);

endmodule
