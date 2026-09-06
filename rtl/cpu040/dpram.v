// Project-local replacement for lib/AP68040/rtl/primitives/dpram.v.
//
// The submodule's version writes both RAM ports in one always block.  Vivado
// refuses to map that to block RAM ("RAM has multiple writes via different
// ports in same process") and dissolves it into registers and muxes: the
// core's ctag_ram (128 x 94) and the MMU's atc_ram together become ~43k LUTs,
// which is why the core measured 70,832 LUTs as shipped and did not fit the
// xc7a100t.  With one process per port it infers block RAM and the full
// configuration -- MMU, FPU, caches -- places and routes at 28,694 LUTs and
// 10 BRAM tiles.  See findings/ap68040/compatibility.md.
//
// The AP68040 README invites this substitution ("replace it with a vendor
// macro if your flow needs one"), so the submodule is left untouched and this
// file is compiled in its place; tools/test_ap040.sh runs the core's own test
// suite against exactly this arrangement.
//
// ONE BEHAVIOURAL DIFFERENCE, deliberate and tested.  The original does both
// writes before both reads in a single process, so a read of a row another
// port writes in the same cycle returns the NEW data.  Two processes -- and
// any real RAMB primitive -- return the OLD data on such a collision.  The
// cache uses port B to invalidate while port A serves lookups, so a same-cycle
// collision on one row would see stale validity for a cycle.
// tb_ap040_cache_snoop.v is the test for that path and passes with this file.

module dpram #(parameter AW = 8, parameter DW = 8) (
	input clock,
	input [AW-1:0] address_a, input [DW-1:0] data_a, input wren_a, output reg [DW-1:0] q_a,
	input [AW-1:0] address_b, input [DW-1:0] data_b, input wren_b, output reg [DW-1:0] q_b
);
	(* ram_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];
	always @(posedge clock) begin
		if (wren_a) mem[address_a] <= data_a;
		q_a <= mem[address_a];
	end
	always @(posedge clock) begin
		if (wren_b) mem[address_b] <= data_b;
		q_b <= mem[address_b];
	end
endmodule
