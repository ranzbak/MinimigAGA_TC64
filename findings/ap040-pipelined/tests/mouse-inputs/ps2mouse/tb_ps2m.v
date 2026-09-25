`timescale 1ns/1ps
// userio_ps2mouse against a behavioural PS/2 wheel mouse.
//   BAT_US   : how long the mouse's self-test takes after a 0xFF reset
//   BATRTS   : 1 = a host request-to-send during the self-test is served
//              only after it (the device does not clock while busy) and the
//              pending AA 00 are then SENT after the reply; 0 = AA 00 dropped
// Checks: the core's intellimouse flag matches the mouse's mode, and a
// button held for 200 ms reads as held (sampled every 20 ms, like VBlank).
module tb_ps2m;
parameter integer BAT_US = 400000;
parameter integer BATRTS = 1;
reg clk = 0; always #17.621 clk = ~clk;      // 28.375 MHz
reg [1:0] div = 0; always @(posedge clk) div <= div + 1;
wire clk7_en = (div == 2'd3);
reg reset = 1;
wire mclk_o, mdat_o;
reg  dev_clk = 1, dev_dat = 1;
wire mclk = mclk_o & dev_clk;
wire mdat = mdat_o & dev_dat;
wire [7:0] xc, yc, zc; wire ml, mm, mr;
userio_ps2mouse dut(.clk(clk), .clk7_en(clk7_en), .reset(reset),
	.ps2mdat_i(mdat), .ps2mclk_i(mclk), .ps2mdat_o(mdat_o), .ps2mclk_o(mclk_o),
	.mou_emu(6'b0), .sof(1'b0), .zcount(zc), .ycount(yc), .xcount(xc),
	._mleft(ml), ._mthird(mm), ._mright(mr), .test_load(1'b0), .test_data(16'd0));

// ------------------------------------------------------------ the mouse
reg        wheel = 0;       // intellimouse mode reached
reg        report = 0;      // data reporting enabled
reg  [7:0] rates [0:2];
reg        busy_bat = 0;
reg  [7:0] txq [0:31]; integer txh = 0, txt = 0;
integer    ncmd = 0;
task qbyte; input [7:0] b; begin txq[txt % 32] = b; txt = txt + 1; end endtask

// host -> device: RTS is data low with clock released after an inhibit
task recv_cmd; output [7:0] b; integer i; reg p; begin
	// device clocks 11 times; data sampled while clock high
	for (i = 0; i < 10; i = i + 1) begin
		#15000; dev_clk = 0; #40000; dev_clk = 1; #5000;
		if (i <= 7) b[i] = mdat;
		if (i == 8) p = mdat;
		#20000;
	end
	// ack: data low for the 11th clock
	#15000; dev_dat = 0; dev_clk = 0; #40000; dev_clk = 1; #5000; dev_dat = 1; #20000;
end endtask

task send_byte; input [7:0] b; integer i; reg [10:0] fr; begin
	fr = {1'b1, ~^b, b, 1'b0};
	for (i = 0; i < 11; i = i + 1) begin
		dev_dat = fr[i]; #20000; dev_clk = 0; #40000; dev_clk = 1; #20000;
	end
	dev_dat = 1;
end endtask

reg [7:0] cmd; reg want_arg; reg [7:0] last;
integer rate_i = 0;
always begin : device
	#1000;
	if (mclk === 1'b0) begin
		// host inhibit / RTS in progress: wait for clock release
		wait (mclk === 1'b1);
		#1000;
		if (mdat === 1'b0) begin
			if (busy_bat) wait (!busy_bat);
			if (!BATRTS) begin txh = txt; end   // the BAT reply is dropped
			recv_cmd(cmd); ncmd = ncmd + 1; $display("%0t us: mouse got %02x (core state %0d cnt %0d)", $time/1000, cmd, dut.mstate, dut.mcmd_cnt);
			if (want_arg) begin
				want_arg = 0; qbyte(8'hFA);
				rates[0] = rates[1]; rates[1] = rates[2]; rates[2] = cmd;
				if (rates[0] == 200 && rates[1] == 100 && rates[2] == 80) wheel = 1;
			end
			else case (cmd)
				8'hFF: begin qbyte(8'hFA); report = 0; wheel = 0; busy_bat = 1;
				             fork begin #(BAT_US*1000); busy_bat = 0; qbyte(8'hAA); qbyte(8'h00); end join_none end
				8'hF3: begin qbyte(8'hFA); want_arg = 1; end
				8'hF2: begin qbyte(8'hFA); qbyte(wheel ? 8'h03 : 8'h00); end
				8'hF4: begin qbyte(8'hFA); report = 1; end
				default: qbyte(8'hFA);
			endcase
		end
	end
	else if (txh != txt && !busy_bat_tx_block) begin
		$display("%0t us: mouse sends %02x (core state %0d)", $time/1000, txq[txh % 32], dut.mstate); send_byte(txq[txh % 32]); txh = txh + 1; #200000;
	end
end
wire busy_bat_tx_block = 1'b0;

// a report: buttons + movement, 3 or 4 bytes
task packet; input [2:0] btn; input [7:0] dx; input [7:0] dy; begin
	if (report) begin
		qbyte({1'b0, 1'b0, dy[7], dx[7], 1'b1, btn[2], btn[1], btn[0]});
		qbyte(dx); qbyte(dy);
		if (wheel) qbyte(8'h00);
	end
end endtask

// ------------------------------------------------------------ the test
integer held = 0, notheld = 0, s;
initial begin
	rates[0] = 0; rates[1] = 0; rates[2] = 0; want_arg = 0;
	#2000; reset = 1; #10000; reset = 0;
	#((BAT_US + 700000) * 1000);             // init + self-test + margin
	$display("after init: mouse wheel=%0d report=%0d  core intellimouse=%0d mcmd_cnt=%0d mstate=%0d cmds=%0d",
	         wheel, report, dut.intellimouse, dut.mcmd_cnt, dut.mstate, ncmd);
	// some movement first, then a 200 ms click with movement during it
	repeat (5) begin packet(3'b000, 8'd3, 8'd2); #10000000; end
	#50000000;
	packet(3'b001, 8'd0, 8'd0);             // press, no movement
	for (s = 0; s < 10; s = s + 1) begin
		#20000000; if (ml == 1'b0) held = held + 1; else notheld = notheld + 1;
	end
	packet(3'b000, 8'd0, 8'd0); #20000000;
	$display("press 200 ms still: held %0d/10 samples", held);
	held = 0; notheld = 0;
	packet(3'b001, 8'd0, 8'd0);
	for (s = 0; s < 10; s = s + 1) begin
		packet(3'b001, 8'd2, 8'd1);           // dragging
		#20000000; if (ml == 1'b0) held = held + 1; else notheld = notheld + 1;
	end
	packet(3'b000, 8'd0, 8'd0); #20000000;
	$display("press 200 ms dragging: held %0d/10 samples", held);
	$display("left now %b (1 = released)", ml);
	$finish;
end
endmodule
