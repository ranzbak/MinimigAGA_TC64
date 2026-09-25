module init0;
// Vivado powers every register without an initialiser up at 0: do the same
initial begin
  tb_mcp.dut.cs = 0; tb_mcp.dut.tx_pos = 0; tb_mcp.dut.rx_pos = 0; tb_mcp.dut.tx_start = 0; tb_mcp.dut.rx_start = 0;
  tb_mcp.dut.st_wait = 0; tb_mcp.dut.st_wait_cnt = 0; tb_mcp.dut.TX_DV = 0; tb_mcp.dut.TX_Byte = 0;
  tb_mcp.dut.st_dv = 0; tb_mcp.dut.st_seq = 0; tb_mcp.dut.st_data = 0; tb_mcp.dut.rx_ready_p = 0;
  tb_mcp.dut.tx_ready_ = 0; tb_mcp.dut.tx_ready_t = 0; tb_mcp.dut.rx_ready_ = 0; tb_mcp.dut.rx_ready_t = 0;
  tb_mcp.dut.joya = 0; tb_mcp.dut.joyb = 0; tb_mcp.dut.inta_s = 0; tb_mcp.dut.miso_s = 0;
end
endmodule
