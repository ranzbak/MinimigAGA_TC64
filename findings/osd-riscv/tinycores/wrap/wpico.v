// Registered-I/O OOC wrapper for picorv32 (native bus incl. look-ahead outputs)
module wtop #(parameter COMPRESSED_ISA = 1, parameter SMALL = 0) (
  input clk, input resetn, input [31:0] irq_i, input mem_ready, input [31:0] mem_rdata,
  output reg mem_valid, output reg mem_instr, output reg [31:0] mem_addr, output reg [31:0] mem_wdata,
  output reg [3:0] mem_wstrb, output reg la_read, output reg la_write, output reg [31:0] la_addr, output reg trap);
  reg rn, rdy; reg [31:0] rd, irq;
  wire v, ins, lr, lw, tr; wire [31:0] a, wd, laa; wire [3:0] ws;
  always @(posedge clk) begin rn <= resetn; rdy <= mem_ready; rd <= mem_rdata; irq <= irq_i;
    mem_valid <= v; mem_instr <= ins; mem_addr <= a; mem_wdata <= wd; mem_wstrb <= ws;
    la_read <= lr; la_write <= lw; la_addr <= laa; trap <= tr; end
  picorv32 #(
    .ENABLE_COUNTERS(!SMALL), .ENABLE_COUNTERS64(!SMALL), .ENABLE_REGS_16_31(1), .ENABLE_REGS_DUALPORT(!SMALL),
    .LATCHED_MEM_RDATA(0), .TWO_STAGE_SHIFT(0), .BARREL_SHIFTER(!SMALL), .TWO_CYCLE_COMPARE(0), .TWO_CYCLE_ALU(0),
    .COMPRESSED_ISA(COMPRESSED_ISA), .CATCH_MISALIGN(!SMALL), .CATCH_ILLINSN(!SMALL), .ENABLE_PCPI(0),
    .ENABLE_MUL(0), .ENABLE_FAST_MUL(1), .ENABLE_DIV(1), .ENABLE_IRQ(1), .ENABLE_IRQ_QREGS(1), .ENABLE_IRQ_TIMER(1),
    .PROGADDR_RESET(0), .PROGADDR_IRQ(32'h10), .STACKADDR(32'h2000)
  ) u_core (.clk(clk), .resetn(rn), .trap(tr), .mem_valid(v), .mem_instr(ins), .mem_ready(rdy), .mem_addr(a),
    .mem_wdata(wd), .mem_wstrb(ws), .mem_rdata(rd), .mem_la_read(lr), .mem_la_write(lw), .mem_la_addr(laa),
    .mem_la_wdata(), .mem_la_wstrb(), .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(), .pcpi_wr(1'b0),
    .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0), .irq(irq), .eoi());
endmodule
