// Registered-I/O OOC wrapper for Ibex (ibex_top, RV32IMC, FPGA regfile, no I$, no PMP, no DM)
module wtop #(parameter int MSEL = 2, parameter bit E = 1'b0) (
  input logic clk, input logic rst_ni_i, input logic irq_ext_i, input logic irq_tmr_i,
  input logic igt_i, input logic irv_i, input logic [31:0] ird_i, input logic dgt_i, input logic drv_i, input logic [31:0] drd_i,
  output logic ireq, output logic [31:0] iaddr, output logic dreq, output logic dwe, output logic [3:0] dbe,
  output logic [31:0] daddr, output logic [31:0] dwdata);
  logic rn, iext, itmr, igt, irv, dgt, drv; logic [31:0] ird, drd;
  logic ireq_w, dreq_w, dwe_w; logic [31:0] ia_w, da_w, dw_w; logic [3:0] dbe_w;
  always_ff @(posedge clk) begin rn <= rst_ni_i; iext <= irq_ext_i; itmr <= irq_tmr_i; igt <= igt_i; irv <= irv_i; ird <= ird_i;
    dgt <= dgt_i; drv <= drv_i; drd <= drd_i; ireq <= ireq_w; iaddr <= ia_w; dreq <= dreq_w; dwe <= dwe_w; dbe <= dbe_w;
    daddr <= da_w; dwdata <= dw_w; end
  localparam ibex_pkg::rv32m_e M = (MSEL == 0) ? ibex_pkg::RV32MNone : (MSEL == 1) ? ibex_pkg::RV32MSlow :
                                   (MSEL == 2) ? ibex_pkg::RV32MFast : ibex_pkg::RV32MSingleCycle;
  ibex_top #(.RV32E(E), .RV32M(M), .RV32B(ibex_pkg::RV32BNone), .RV32ZC(ibex_pkg::RV32Zca),
    .RegFile(ibex_pkg::RegFileFPGA), .BranchTargetALU(1'b0), .WritebackStage(1'b0), .ICache(1'b0), .BranchPredictor(1'b0),
    .DbgTriggerEn(1'b0), .SecureIbex(1'b0), .PMPEnable(1'b0), .MHPMCounterNum(0)
  ) u_core (.clk_i(clk), .rst_ni(rn), .test_en_i(1'b0), .ram_cfg_icache_tag_i('0), .ram_cfg_icache_tag_o(),
    .ram_cfg_icache_data_i('0), .ram_cfg_icache_data_o(), .cheriot_enable_i(ibex_pkg::IbexMuBiOff),
    .hart_id_i(32'b0), .boot_addr_i(32'h0), .trvk_heap_base_addr_i(32'b0),
    .instr_req_o(ireq_w), .instr_gnt_i(igt), .instr_rvalid_i(irv), .instr_addr_o(ia_w), .instr_rdata_i(ird),
    .instr_rdata_intg_i(7'b0), .instr_err_i(1'b0),
    .data_req_o(dreq_w), .data_gnt_i(dgt), .data_rvalid_i(drv), .data_we_o(dwe_w), .data_be_o(dbe_w), .data_addr_o(da_w),
    .data_wdata_o(dw_w), .data_wdata_intg_o(), .data_tag_o(), .data_rdata_i(drd), .data_rdata_intg_i(7'b0), .data_tag_i(1'b0),
    .data_err_i(1'b0),
    .trvk_revbm_req_o(), .trvk_revbm_gnt_i(1'b0), .trvk_revbm_rvalid_i(1'b0), .trvk_revbm_addr_o(), .trvk_revbm_rdata_i(32'b0),
    .trvk_revbm_rdata_intg_i(7'b0), .trvk_revbm_err_i(1'b0),
    .irq_software_i(1'b0), .irq_timer_i(itmr), .irq_external_i(iext), .irq_fast_i(15'b0), .irq_nm_i(1'b0),
    .scramble_key_valid_i(1'b0), .scramble_key_i('0), .scramble_nonce_i('0), .scramble_req_o(),
    .debug_req_i(1'b0), .crash_dump_o(), .double_fault_seen_o(),
    .fetch_enable_i(ibex_pkg::IbexMuBiOn), .mcounteren_writable_i(ibex_pkg::IbexMuBiOff), .alert_minor_o(), .alert_major_internal_o(),
    .alert_major_bus_o(), .core_sleep_o(), .scan_rst_ni(1'b1), .lockstep_cmp_en_o(),
    .data_req_shadow_o(), .data_we_shadow_o(), .data_be_shadow_o(), .data_addr_shadow_o(), .data_wdata_shadow_o(),
    .data_wdata_intg_shadow_o(), .instr_req_shadow_o(), .instr_addr_shadow_o());
endmodule
