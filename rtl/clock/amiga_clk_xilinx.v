/* amiga_clk_xilinx.v */
/* 2012, rok.krajnc@gmail.com */


module amiga_clk_xilinx #(
    // The AP68040 island clock, CLKOUT3.  VCO is 1134.375 MHz, so
    //   30 -> 37.81250 MHz, clk_114 / 3   (stage D3, the shipping value)
    //   40 -> 28.35938 MHz, clk_114 / 4   (the pre-D3 CPU RATE, with the D3
    //        architecture otherwise untouched -- the single-variable bisect
    //        for "is this a rate-dependent window or a structural fault",
    //        findings/ap68040/sdd-d3/d3-snoop-coherency.md)
    // Everything downstream is ratio-agnostic: the phase marker derives
    // cpu_ph from a toggle, so it produces a one-in-N pulse for any N.
    parameter CPU_CLK_DIVIDE = 30
) (
    input  wire areset,
    input  wire inclk0,
    output wire c0,
    output wire c1,
    output wire c2,
    output wire c3,
    output wire locked
);


// internal wires
wire pll_114;
wire dll_114;
wire dll_28;
wire dll_38;
wire clk_fb_main;
wire locked_async;
// Synchonize the PLL locked signal to the dll_114 clock
(* ASYNC_REG = "TRUE" *) reg [1:0] locked_sync_reg;
// reg [1:0] clk_7;

initial begin
    locked_sync_reg = 2'b11;
// clk_7 = 2'b0;
end

MMCME2_ADV #(
    .CLKIN1_PERIOD(20.0), // 50        MHz (20 ns)
    .CLKFBOUT_MULT_F(45.375), // 50 MHz  * <this value> = common multiply
    .DIVCLK_DIVIDE(2), // <common multiply>  MHz / <this value> =  common divided frequency
    .BANDWIDTH("OPTIMIZED"),
    .CLKOUT0_DIVIDE_F(10.000), // 113.4375 MHz /10 divide
    .CLKOUT1_DIVIDE(10), // 113.4375 MHz /10 divide
    .CLKOUT1_PHASE(-121.5), // -144.00' phase shift
    .CLKOUT2_DIVIDE(40), // 28.35938  MHz /40 divide
    // The CPU island's own clock.  1134.375 / 30 = 37.8125 MHz EXACTLY, i.e.
    // clk_114 / 3 off the same VCO with no phase shift, so every clk_38 rising
    // edge coincides with a clk_114 one.  That makes the CPU island a
    // SYNCHRONOUS 1:3 sibling of the system clock, not an asynchronous domain:
    // static timing analyses the real edges and no synchroniser belongs on the
    // crossing (findings/ap68040/plan-v2-with-ddr3.md, stage D3).
    .CLKOUT3_DIVIDE(CPU_CLK_DIVIDE), // the AP68040 island; see the parameter
    .REF_JITTER1(0.010),
    .STARTUP_WAIT("TRUE")
// .REF_JITTER2(0.010),
// .COMPENSATION("ZHOLD")
) clk_main (
    .PWRDWN(1'b0),
    .RST(1'b0),
    .CLKIN1(inclk0),
    .CLKFBIN(clk_fb_main),
    .CLKFBOUT(clk_fb_main),
    .CLKOUT0(dll_114), //  114 MHz SDRAM clock
    .CLKOUT1(pll_114),
    .CLKOUT2(dll_28),
    .CLKOUT3(dll_38),
    .LOCKED(locked_async)
);


always @(posedge dll_114) begin
    locked_sync_reg <= {locked_sync_reg[0], locked_async};
end
assign locked = locked_sync_reg[1];

// always @ (posedge c1) begin
//     clk_7 <= #1 clk_7 + 2'd1;
// end

// global clock buffers
BUFG  BUFG_114 (.I(dll_114),  .O(c0));
BUFG  BUFG_28  (.I(dll_28),   .O(c1));
BUFG  BUFG_SDR (.I(pll_114),  .O(c2));
BUFG  BUFG_38  (.I(dll_38),   .O(c3));
//BUFG  BUFG_7   (.I(clk_7[1]), .O(c3));


endmodule
