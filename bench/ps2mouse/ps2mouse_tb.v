// ps2mouse_tb.v
// 2014, rok.krajnc@gmail.com


`default_nettype none
`timescale 1ns/1ps


module ps2mouse_tb();

reg CLK7=1;
reg CLK=1;
reg RST=1;
wire ps2mclk;
wire ps2mdat;

wire mclk;
wire mdat;


// testbench
initial begin
  #1;
  $display("BENCH : ps2mouse_tb BEGIN");

  repeat (200000) @ (posedge CLK7);

  $display("BENCH : ps2mouse_tb END");
  $finish();
end


// clocks & async reset
initial begin
  CLK7 = 1'b1;
  CLK  = 1'b1;
  #1;
  forever begin
   #35  CLK = ~CLK;
   #71  CLK = ~CLK;
   #108 CLK = ~CLK;
   #143 
        CLK = ~CLK;
        CLK7 = ~CLK7;
  end;
end

initial begin
  RST = 1'b1;
  #1;
  RST = 1'b0;
  repeat(10) @ (posedge CLK7);
end


// modules
ps2mouse_ctrl ps2mouse_ctrl (
  .clk    (CLK7),
  .reset  (RST),
  .mclk   (mclk),
  .mdat   (mdat)
);

userio_ps2mouse ps2mouse (
  .clk(CLK),
  .clk7_en(CLK7),
  .reset(RST),
  .ps2mclk_i(mclk),
  .ps2mdat_i(mdat),
  .ps2mclk_o(ps2mclk),
  .ps2mdat_o(ps2mdat),
  .mou_emu(0),
  .sof(0),
  .test_load(0),
  .test_data(0)
);


endmodule

