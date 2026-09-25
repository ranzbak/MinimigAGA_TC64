`timescale 1ps/1ps
// MCP23S17 behavioural model + the board's mcp23s17_input: are joya/joyb right?
module tb_mcp;
parameter integer TV_PS    = 60000;   // SO valid after SCK falls (datasheet max 90 ns)
parameter integer DOUT_PS  = 7000;    // FPGA clock -> SCK/MOSI/CS pin
parameter integer DIN_PS   = 2000;    // MISO pin -> first sync FF
parameter FLOAT = 1'b1;               // SO when not driven (no pull on js_miso)
reg clk = 0; always #17621 clk = ~clk;   // 28.375 MHz
reg rst = 1;
wire mosi_f, cs_f, sck_f; wire miso_pin;
wire mosi, cs, sck;
assign #(DOUT_PS) mosi = mosi_f;
assign #(DOUT_PS) cs = cs_f;
assign #(DOUT_PS) sck = sck_f;
wire miso_f; assign #(DIN_PS) miso_f = miso_pin;
wire [5:0] joya, joyb;
mcp23s17_input dut(.clk(clk), .rst(rst), .inta(1'b1), .mosi(mosi_f), .miso(miso_f), .cs(cs_f), .sck(sck_f), .ready(), .joya(joya), .joyb(joyb));

// ---- the MCP23S17 ----
reg [7:0] gpa = 8'hFF, gpb = 8'hFF;      // pin levels (pull-ups, nothing pressed)
reg [7:0] regs [0:31];
integer bitn; reg [7:0] sh; reg [7:0] opc, adr; reg rd; reg so_en; reg so_val;
reg [7:0] outb;
assign miso_pin = so_en ? so_val : FLOAT;
integer k; initial begin for (k=0;k<32;k=k+1) regs[k]=0; so_en=0; so_val=0; end
function [7:0] rdreg; input [7:0] a; begin
  if (a == 8'h12) rdreg = gpa; else if (a == 8'h13) rdreg = gpb; else rdreg = regs[a[4:0]]; end endfunction
always @(negedge cs) begin bitn = 0; sh = 0; so_en = 0; end
always @(posedge cs) begin so_en = 0; end
integer nbytes = 0;
always @(posedge sck) if (!cs) begin
  sh = {sh[6:0], mosi}; bitn = bitn + 1;
  if (bitn % 8 == 0) begin
    if (bitn == 8) begin opc = sh; rd = sh[0]; end
    else if (bitn == 16) begin adr = sh; end
    else begin if (!rd) regs[adr[4:0]] = sh; adr = adr + 1; end
    if (rd && bitn >= 16) begin outb = rdreg(adr); if (bitn > 16) begin end end
  end
end
// output on the falling edge: after the 16th rising edge the first data bit
reg [7:0] ob; integer obit;
always @(negedge sck) if (!cs && rd && bitn >= 16) begin
  if (bitn % 8 == 0) begin
    // new byte: during a read the pointer advanced at the byte boundary
    if (bitn > 16) ; // adr already incremented for writes only; reads:
    ob = rdreg(adr + (bitn-16)/8); obit = 7;
  end
  so_en <= #(TV_PS) 1'b1;
  so_val <= #(TV_PS) ob[obit];
  obit = obit - 1;
end

// ---- checks ----
integer good = 0, bad = 0; reg [5:0] ja_q, jb_q;
wire [5:0] exp_a = { gpa[6], gpa[2], gpa[1], gpa[3], gpa[4], gpa[5] };
wire [5:0] exp_b = { gpb[2], gpb[6], gpb[7], gpb[5], gpb[4], gpb[3] };
integer nch = 0;
always @(posedge clk) if (!rst) begin
  if (joya !== ja_q || joyb !== jb_q) begin
    nch = nch + 1;
    if (nch < 40) $display("%0t joya=%b (exp %b) joyb=%b (exp %b)", $time, joya, exp_a, joyb, exp_b);
  end
  ja_q <= joya; jb_q <= joyb;
end
initial begin
  #(200000); rst = 0;
  #(2000000000);   // 2 ms idle
  $display("IDLE END joya=%b exp %b joyb=%b exp %b", joya, exp_a, joyb, exp_b);
  gpa = 8'hFB; // fire on port A pressed (bit 2)
  #(1000000000);
  $display("FIREA   joya=%b exp %b joyb=%b exp %b", joya, exp_a, joyb, exp_b);
  gpa = 8'hFF; gpb = 8'h7F;
  #(1000000000);
  $display("B7      joya=%b exp %b joyb=%b exp %b", joya, exp_a, joyb, exp_b);
  $display("IOCON=%02x IODIRA=%02x GPPUA=%02x GPPUB=%02x changes=%0d", regs[10], regs[0], regs[12], regs[13], nch);
  $finish;
end
endmodule
