// Registered-I/O OOC wrapper for Hazard3 (cpu_1port, AHB5-Lite), optional DM + pin JTAG-DTM.
`default_nettype none
module h3sys #(parameter C = 1, parameter DBG = 0, parameter RB = 0, parameter FBC = 1) (
  input wire clk, input wire rst_n, input wire tck, input wire tms, input wire tdi, output wire tdo,
  output wire [31:0] haddr, output wire hwrite, output wire [1:0] htrans, output wire [2:0] hsize,
  input wire hready, input wire hresp, output wire [31:0] hwdata, input wire [31:0] hrdata,
  input wire irq, input wire timer_irq);
  wire hr, hh, hres, hrr; wire [31:0] d0r, d0w, ida; wire d0wen, idv, idr, ice, icb;
  wire sys_rr; wire [0:0] hart_rr, hreq_halt, hreq_hor, hreq_res, h_halted, h_running;
  wire rst_n_cpu;
  generate if (DBG) begin : g_dbg
    wire psel, pen, pwr, prdy, perr; wire [8:0] paddr; wire [31:0] pwd, prd; wire hrq;
    hazard3_jtag_dtm #(.IDCODE(32'hdeadbeef)) dtm (.tck(tck), .trst_n(rst_n), .tms(tms), .tdi(tdi), .tdo(tdo),
      .dmihardreset_req(hrq), .clk_dmi(clk), .rst_n_dmi(rst_n), .dmi_psel(psel), .dmi_penable(pen), .dmi_pwrite(pwr),
      .dmi_paddr(paddr), .dmi_pwdata(pwd), .dmi_prdata(prd), .dmi_pready(prdy), .dmi_pslverr(perr));
    hazard3_dm #(.N_HARTS(1), .HAVE_SBA(0), .NEXT_DM_ADDR(0)) dm (.clk(clk), .rst_n(rst_n),
      .dmi_psel(psel), .dmi_penable(pen), .dmi_pwrite(pwr), .dmi_paddr(paddr), .dmi_pwdata(pwd), .dmi_prdata(prd),
      .dmi_pready(prdy), .dmi_pslverr(perr), .sys_reset_req(sys_rr), .sys_reset_done(rst_n_cpu),
      .hart_reset_req(hart_rr), .hart_reset_done(rst_n_cpu), .hart_req_halt(hreq_halt), .hart_req_halt_on_reset(hreq_hor),
      .hart_req_resume(hreq_res), .hart_halted(h_halted), .hart_running(h_running), .hart_data0_rdata(d0r),
      .hart_data0_wdata(d0w), .hart_data0_wen(d0wen), .hart_instr_data(ida), .hart_instr_data_vld(idv),
      .hart_instr_data_rdy(idr), .hart_instr_caught_exception(ice), .hart_instr_caught_ebreak(icb),
      .sbus_addr(), .sbus_write(), .sbus_size(), .sbus_vld(), .sbus_rdy(1'b0), .sbus_err(1'b0), .sbus_wdata(), .sbus_rdata(32'b0));
    hazard3_reset_sync rs (.clk(clk), .rst_n_in(rst_n && !sys_rr && !hart_rr[0]), .rst_n_out(rst_n_cpu));
  end else begin : g_nodbg
    assign tdo = 1'b0; assign rst_n_cpu = rst_n; assign hreq_halt = 1'b0; assign hreq_hor = 1'b0; assign hreq_res = 1'b0;
    assign d0r = 32'b0; assign ida = 32'b0; assign idv = 1'b0;
  end endgenerate
  hazard3_cpu_1port #(
    .RESET_VECTOR(32'h0), .MTVEC_INIT(32'h0), .EXTENSION_A(0), .EXTENSION_C(C), .EXTENSION_E(0), .EXTENSION_M(1),
    .CSR_M_MANDATORY(1), .CSR_M_TRAP(1), .CSR_COUNTER(0), .U_MODE(0), .PMP_REGIONS(0),
    .DEBUG_SUPPORT(DBG), .BREAKPOINT_TRIGGERS(0), .NUM_IRQS(1), .IRQ_PRIORITY_BITS(0),
    .MULDIV_UNROLL(1), .MUL_FAST(1), .MUL_FASTER(0), .MULH_FAST(0), .FAST_BRANCHCMP(FBC), .REDUCED_BYPASS(RB), .BRANCH_PREDICTOR(0)
  ) cpu (.clk(clk), .clk_always_on(clk), .rst_n(rst_n_cpu), .pwrup_req(), .pwrup_ack(1'b1), .clk_en(), .unblock_out(),
    .unblock_in(1'b0), .haddr(haddr), .hwrite(hwrite), .htrans(htrans), .hsize(hsize), .hburst(), .hprot(), .hmastlock(),
    .hmaster(), .hexcl(), .hready(hready), .hresp(hresp), .hexokay(1'b1), .hwdata(hwdata), .hrdata(hrdata),
    .fence_i_vld(), .fence_d_vld(), .fence_rdy(1'b1),
    .dbg_req_halt(hreq_halt[0]), .dbg_req_halt_on_reset(hreq_hor[0]), .dbg_req_resume(hreq_res[0]), .dbg_halted(h_halted[0]),
    .dbg_running(h_running[0]), .dbg_data0_rdata(d0r), .dbg_data0_wdata(d0w), .dbg_data0_wen(d0wen),
    .dbg_instr_data(ida), .dbg_instr_data_vld(idv), .dbg_instr_data_rdy(idr), .dbg_instr_caught_exception(ice),
    .dbg_instr_caught_ebreak(icb), .dbg_sbus_addr(32'b0), .dbg_sbus_write(1'b0), .dbg_sbus_size(2'b0), .dbg_sbus_vld(1'b0),
    .dbg_sbus_rdy(), .dbg_sbus_err(), .dbg_sbus_wdata(32'b0), .dbg_sbus_rdata(), .mhartid_val(32'b0), .eco_version(4'b0),
    .irq(irq), .soft_irq(1'b0), .timer_irq(timer_irq));
endmodule

module wtop #(parameter C = 1, parameter DBG = 0, parameter RB = 0, parameter FBC = 1) (
  input wire clk, input wire rst_n_i, input wire tck, input wire tms, input wire tdi, output wire tdo,
  input wire irq_i, input wire tirq_i, input wire hready_i, input wire hresp_i, input wire [31:0] hrdata_i,
  output reg [31:0] haddr, output reg hwrite, output reg [1:0] htrans, output reg [2:0] hsize, output reg [31:0] hwdata);
  reg rn, irq, tirq, hrdy, hresp; reg [31:0] hrd;
  wire [31:0] a, wd; wire w; wire [1:0] t; wire [2:0] s;
  always @(posedge clk) begin rn <= rst_n_i; irq <= irq_i; tirq <= tirq_i; hrdy <= hready_i; hresp <= hresp_i; hrd <= hrdata_i;
    haddr <= a; hwrite <= w; htrans <= t; hsize <= s; hwdata <= wd; end
  h3sys #(.C(C), .DBG(DBG), .RB(RB), .FBC(FBC)) u_core (.clk(clk), .rst_n(rn), .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo),
    .haddr(a), .hwrite(w), .htrans(t), .hsize(s), .hready(hrdy), .hresp(hresp), .hwdata(wd), .hrdata(hrd),
    .irq(irq), .timer_irq(tirq));
endmodule
