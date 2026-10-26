// ooc_sdcard_top -- out-of-context wrapper for the SD card engine's size and
// timing check (tools/vivado/ooc_sdcard/run.tcl; plan Task 8 step 5).
//
// What it holds, as in the real design:
//   - rtl/host/sdcard_spi.v on clk_g (clk_114), its register port driven the
//     way cfide drives it: the host bus (addr / d / req / wr) arrives in
//     clk_114 registers (host_bridge.vhd's), the window decode and the
//     first-cycle strobes are cfide.vhd's equations (ext_*), and reg_q goes
//     through a 2:1 read mux into a clk_114 register (host_bridge's cpu_d);
//   - rtl/minimig/sdcard_gayle.v (clk = clk_28 with clk7_en, clk_g) and
//     sdcard_gayle_mux, with the Gayle- and paula_floppy-side inputs from
//     clk_28 registers and the mux outputs into clk_28 registers (Gayle's).
// Every port of this wrapper goes to or from a register, so out of context
// every internal path is a timed register-to-register path.  The card pins
// are the sdcard_spi registers themselves (no IO buffers out of context; the
// io mode of run.tcl puts them on the real package pins), with the board's
// port names (sd_m_*, minimig_openaars_top.v) and instance names (sdc_spi,
// SDCGAYLE1) so that run.tcl reads sd_card.xdc's own lines for them.
// Not part of the design; never instantiated by a board top.
module ooc_sdcard_top (
    input  wire        clk_g,            // clk_114
    input  wire        clk,              // clk_28
    input  wire        reset_g,          // clk_114 reset (registered here)
    // host bus (clk_114)
    input  wire        bus_req, input wire bus_wr,
    input  wire        bus_a23,           // addr(23): the hardware window
    input  wire  [7:2] bus_a,             // addr(7 downto 2)
    input  wire [15:0] bus_d,
    output reg  [15:0] bus_q,
    output wire        irq,
    // card (minimig_openaars_top.v's names)
    output wire        sd_m_clk, output wire sd_m_d3, output wire sd_m_cmd,
    input  wire        sd_m_d0, input wire sd_m_cdet,
    output wire        sd_m_d1, output wire sd_m_d2,
    // Gayle side (clk_28)
    input  wire        g_reset,
    input  wire [15:0] hdd_data_in,
    input  wire        hdd_dat_req,
    input  wire  [1:0] hdd_fifo_reset,
    input  wire  [1:0] hdd_cmd_new,
    input  wire        pf_port, input wire pf_data_wr, input wire pf_data_rd,
    input  wire [15:0] pf_data_out,
    input  wire  [2:0] pf_addr,
    input  wire        hdd_regs_rd,
    output reg  [15:0] pf_data_in_q,
    output reg         hdd_port_q, output reg hdd_data_wr_q, output reg hdd_data_rd_q,
    output reg  [15:0] hdd_data_out_q,
    output reg   [2:0] hdd_addr_q
);

    // ------------------------------------------------------------ clk_114 side
    reg        rst_r;
    reg        req_r, wr_r, a23_r;
    reg  [7:2] a_r;
    reg [15:0] d_r;
    always @(posedge clk_g) begin
        rst_r <= reset_g;
        req_r <= bus_req; wr_r <= bus_wr; a23_r <= bus_a23; a_r <= bus_a; d_r <= bus_d;
    end

    // cfide.vhd: ext_select (windows 0-2), the first cycle of req, strobes
    reg        req_d;
    always @(posedge clk_g) req_d <= req_r;
    wire       ext_sel  = a23_r && a_r[7:6] == 2'b00 && a_r[5:4] != 2'b11;
    wire       ext_go   = ext_sel && req_r && !req_d;
    wire       ext_wstb = ext_go && wr_r;
    wire       ext_rstb = ext_go && !wr_r;
    wire [15:0] ext_q;

    wire        g_req, g_dir, g_port, g_ack, g_err, g_wvalid, g_wnext, g_rvalid;
    wire  [9:0] g_words;
    wire [15:0] g_wdata, g_rdata;

    sdcard_spi sdc_spi (
        .clk(clk_g), .reset(rst_r),
        .reg_wstb(ext_wstb), .reg_rstb(ext_rstb), .reg_addr(a_r[5:2]),
        .reg_d(d_r), .reg_q(ext_q),
        .irq(irq),
        .sd_sck(sd_m_clk), .sd_cs_n(sd_m_d3), .sd_mosi(sd_m_cmd), .sd_miso(sd_m_d0),
        .sd_cd_n(sd_m_cdet),
        .g_req(g_req), .g_dir(g_dir), .g_port(g_port), .g_words(g_words),
        .g_ack(g_ack), .g_err(g_err),
        .g_wdata(g_wdata), .g_wvalid(g_wvalid), .g_wnext(g_wnext),
        .g_rdata(g_rdata), .g_rvalid(g_rvalid)
    );

    assign sd_m_d1 = 1'b1;
    assign sd_m_d2 = 1'b1;

    // cfide's q mux (one other source stands for the rest), host_bridge's cpu_d
    always @(posedge clk_g) bus_q <= ext_sel ? ext_q : d_r;

    // ------------------------------------------------------------ clk_28 side
    reg  [1:0] div = 2'd0;
    reg        clk7_en = 1'b0;
    reg        g_reset_r;
    reg [15:0] din_r;
    reg        dreq_r, rrd_r;
    reg  [1:0] frs_r, cnew_r;
    reg        pf_port_r, pf_wr_r, pf_rd_r;
    reg [15:0] pf_out_r;
    reg  [2:0] pf_addr_r;
    always @(posedge clk) begin
        div <= div + 2'd1;
        clk7_en <= div == 2'd3;
        g_reset_r <= g_reset;
        din_r <= hdd_data_in; dreq_r <= hdd_dat_req; frs_r <= hdd_fifo_reset;
        cnew_r <= hdd_cmd_new; rrd_r <= hdd_regs_rd;
        pf_port_r <= pf_port; pf_wr_r <= pf_data_wr; pf_rd_r <= pf_data_rd;
        pf_out_r <= pf_data_out; pf_addr_r <= pf_addr;
    end

    wire        sg_active, sg_port, sg_data_wr, sg_data_rd;
    wire [15:0] sg_data_out, pf_data_in;
    wire  [1:0] sg_cmd_seen;
    wire        hdd_port, hdd_data_wr, hdd_data_rd;
    wire [15:0] hdd_data_out;
    wire  [2:0] hdd_addr;

    sdcard_gayle #(.CLK_RATIO(4)) SDCGAYLE1 (
        .clk(clk), .clk7_en(clk7_en), .reset(g_reset_r), .clk_g(clk_g),
        .g_req(g_req), .g_dir(g_dir), .g_port(g_port), .g_words(g_words),
        .g_ack(g_ack), .g_err(g_err),
        .g_wdata(g_wdata), .g_wvalid(g_wvalid), .g_wnext(g_wnext),
        .g_rdata(g_rdata), .g_rvalid(g_rvalid),
        .active(sg_active), .port(sg_port),
        .data_wr(sg_data_wr), .data_rd(sg_data_rd),
        .data_out(sg_data_out), .data_in(din_r),
        .dat_req(dreq_r), .fifo_reset_seen(frs_r), .cmd_new(cnew_r),
        .fw_port(pf_port_r), .fw_regs_rd(rrd_r), .cmd_seen(sg_cmd_seen)
    );

    sdcard_gayle_mux sdc_mux (
        .sg_active(sg_active), .sg_port(sg_port),
        .sg_data_wr(sg_data_wr), .sg_data_rd(sg_data_rd), .sg_data_out(sg_data_out),
        .sg_cmd_seen(sg_cmd_seen),
        .pf_port(pf_port_r), .pf_data_wr(pf_wr_r), .pf_data_rd(pf_rd_r),
        .pf_data_out(pf_out_r), .pf_addr(pf_addr_r),
        .pf_data_in(pf_data_in), .gy_data_in(din_r),
        .hdd_port(hdd_port), .hdd_data_wr(hdd_data_wr), .hdd_data_rd(hdd_data_rd),
        .hdd_data_out(hdd_data_out), .hdd_addr(hdd_addr)
    );

    always @(posedge clk) begin
        hdd_port_q <= hdd_port; hdd_data_wr_q <= hdd_data_wr; hdd_data_rd_q <= hdd_data_rd;
        hdd_data_out_q <= hdd_data_out; hdd_addr_q <= hdd_addr; pf_data_in_q <= pf_data_in;
    end

endmodule
