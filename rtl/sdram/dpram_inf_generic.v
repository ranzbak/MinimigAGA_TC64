// dpram_inf_256x32.v
// 2015, rok.krajnc@gmail.com
// 2021, paul@etv.cx made it more friendly towards Vivado
// inferrable dual-port memory

module dpram_inf_generic #(
  parameter depth = 8, 
  parameter width = 32
) (
  input  wire               clock,
  input  wire               wren_a,
  input  wire [  depth-1:0] address_a,
  input  wire [  width-1:0] data_a,
  output reg  [  width-1:0] q_a,
  input  wire               wren_b,
  input  wire [  depth-1:0] address_b,
  input  wire [  width-1:0] data_b,
  output reg  [  width-1:0] q_b
);

// memory
//(* ram_style = "block" *)
reg [width-1:0] mem [0:(2**depth)-1];

// Port A
always @(posedge clock) begin
    q_a      <= mem[address_a];
    if(wren_a) begin
        //q_a      <= data_a;
        mem[address_a] <= data_a;
    end
end

// Port B
always @(posedge clock) begin
    q_b      <= mem[address_b];
    if(wren_b) begin
        //q_b      <= data_b;
        mem[address_b] <= data_b;
    end
end

endmodule

