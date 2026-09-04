//-----------------------------------------------------------------
// ddr3_pll - clock generation for the DDR3 island
//
// Derived from lib/core_ddr3_controller/examples/arty_a7/artix7_pll.v
// (ultra-embedded, Apache-2.0), with three deliberate changes:
//   * the reference is the board's 50 MHz oscillator, not 100 MHz, so
//     CLKFBOUT_MULT is 24 instead of 12 (VCO stays at 1200 MHz);
//   * every output gets a BUFG (upstream drives raw PLL outputs);
//   * RST and LOCKED are brought out so the island can hold its logic in
//     reset until the PLL has locked.
//
// VCO = 50 MHz * 24 / 1 = 1200 MHz (within the -1/-2 Artix-7 800..1600 MHz range)
//   CLKOUT0 /12 = 100 MHz   clk100      controller + PHY fabric clock
//   CLKOUT1 /3  = 400 MHz   clk400      PHY OSERDES/ISERDES 4x bit clock
//   CLKOUT2 /6  = 200 MHz   clk200      IDELAYCTRL reference (REFCLK_FREQUENCY 200)
//   CLKOUT3 /3  = 400 MHz   clk400_90   as CLKOUT1 but 90 deg, DQS strobe
//
// The Minimig MMCM (rtl/clock/amiga_clk_xilinx.v) is NOT touched: it cannot
// produce this set of ratios and it is deliberately left alone (design.md D3).
//-----------------------------------------------------------------
`timescale 1ns / 1ps

module ddr3_pll
(
     input       clkref_i      // 50 MHz board oscillator (already on a global buffer)
    ,input       rst_i         // active high, asynchronous

    ,output      clk100_o      // 100 MHz
    ,output      clk400_o      // 400 MHz
    ,output      clk200_o      // 200 MHz
    ,output      clk400_90_o   // 400 MHz, 90 degrees
    ,output      locked_o
);

wire clkfbout_w;
wire clkfbout_buffered_w;
wire pll_clkout0_w;
wire pll_clkout1_w;
wire pll_clkout2_w;
wire pll_clkout3_w;

PLLE2_BASE
#(
     .BANDWIDTH("OPTIMIZED")
    ,.CLKFBOUT_PHASE(0.0)
    ,.CLKIN1_PERIOD(20.0)          // 50 MHz reference
    ,.CLKFBOUT_MULT(24)            // VCO = 1200 MHz
    ,.DIVCLK_DIVIDE(1)

    ,.CLKOUT0_DIVIDE(12)           // 100 MHz
    ,.CLKOUT1_DIVIDE(3)            // 400 MHz
    ,.CLKOUT2_DIVIDE(6)            // 200 MHz
    ,.CLKOUT3_DIVIDE(3)            // 400 MHz

    ,.CLKOUT0_DUTY_CYCLE(0.5)
    ,.CLKOUT1_DUTY_CYCLE(0.5)
    ,.CLKOUT2_DUTY_CYCLE(0.5)
    ,.CLKOUT3_DUTY_CYCLE(0.5)
    ,.CLKOUT4_DUTY_CYCLE(0.5)

    ,.CLKOUT0_PHASE(0.0)
    ,.CLKOUT1_PHASE(0.0)
    ,.CLKOUT2_PHASE(0.0)
    ,.CLKOUT3_PHASE(90.0)
    ,.CLKOUT4_PHASE(0.0)

    ,.REF_JITTER1(0.0)
    ,.STARTUP_WAIT("FALSE")        // configuration DONE must not wait on this PLL:
                                   // the rest of the design has to come up even if the
                                   // DDR3 island never locks.
)
u_plle2
(
     .CLKFBOUT(clkfbout_w)
    ,.CLKOUT0(pll_clkout0_w)
    ,.CLKOUT1(pll_clkout1_w)
    ,.CLKOUT2(pll_clkout2_w)
    ,.CLKOUT3(pll_clkout3_w)
    ,.CLKOUT4()
    ,.CLKOUT5()
    ,.LOCKED(locked_o)
    ,.PWRDWN(1'b0)
    ,.RST(rst_i)
    ,.CLKIN1(clkref_i)
    ,.CLKFBIN(clkfbout_buffered_w)
);

BUFG u_clkfb_buf   (.I(clkfbout_w),    .O(clkfbout_buffered_w));
BUFG u_clk100_buf  (.I(pll_clkout0_w), .O(clk100_o));
BUFG u_clk400_buf  (.I(pll_clkout1_w), .O(clk400_o));
BUFG u_clk200_buf  (.I(pll_clkout2_w), .O(clk200_o));
BUFG u_clk400d_buf (.I(pll_clkout3_w), .O(clk400_90_o));

endmodule
