`timescale 1ns/1ps
// Hand model of the Xilinx 7-series JTAG TAP (XC7A100T) and its BSCANE2 /
// BUFG primitives, for the Verilator debug bench (tb_rv_dbg.v, DEBUG = 1).
//
// Why a hand model: Verilator 5.020 cannot build Vivado's own TAP model
// $XILINX_VIVADO/data/verilog/src/unisims/JTAG_SIME2.v ("Unsupported
// tristate construct" on its procedural "TDO_latch <= 1'bz"), so this file
// reproduces what JTAG_SIME2 + BSCANE2 do, and sim/rv_dbg/xcheck (xsim,
// run.sh xcheck) compares the two on the same pseudo-random TMS/TDI stream
// at every TCK edge.  Behaviour copied from JTAG_SIME2 (PART_NAME "7A100T"),
// including its quirks:
//   * IEEE 1149.1 state machine on the rising TCK edge; IR 6 bits, captured
//     as 6'b010001 (0x11: "01" in the two LSBs, the upper bits as
//     JTAG_SIME2's IR_CAPTURE_VAL), shifted LSB first.
//   * Instructions: IDCODE 0x09 (IDCODE 0x03631093), BYPASS 0x3F,
//     USER1..4 0x02, 0x03, 0x22, 0x23 (decoded in that order: BYPASS, IDCODE,
//     USER1, USER2, USER3, USER4; parameter USER4 overrides the USER4 code,
//     the bench's teeth); anything else selects nothing (TDO high-Z in
//     Shift-DR).  The IR is updated on the falling edge in Update-IR and set
//     to IDCODE on every falling edge in Test-Logic-Reset.
//   * IDCODE: on every rising edge while IR = IDCODE the register shifts (if
//     the state was Shift-DR) or reloads the IDCODE (any other state).
//   * BYPASS: the bit takes TDI on rising edges in Shift-DR only; there is
//     no capture of 0 in Capture-DR (JTAG_SIME2 has none either).
//   * TDO: launched on the falling TCK edge: in Shift-IR IR[0], in Shift-DR
//     the selected register's bit (IDCODE[0], the bypass bit or the USERn
//     TDO of the BSCANE2 with JTAG_CHAIN = n), else high-Z (tdo_oe = 0).
//   * Global BSCANE2 outputs CAPTURE, SHIFT, UPDATE, RESET (= Test-Logic-
//     Reset), RUNTEST: the state decode, registered on the falling TCK edge.
//     TDI and TCK are the pins.  The global SELn is 1 while the IR holds
//     USERn and the state is not Test-Logic-Reset; BSCANE2 SEL follows a
//     rising SELn at once and a falling one on the next falling TCK edge.
//
// Structure (as glbl.v in the unisims, the TAP and the BSCANE2 instances
// meet through hierarchical names): the TAP instance must be called
// xc7_jtag and sit above (or beside) the BSCANE2 instances; each BSCANE2
// stand-in reads xc7_jtag.<signal> and drives xc7_jtag.user_tdo<n> (n =
// its JTAG_CHAIN).
//
// Modules: xc7_tap (the TAP), xc7_bscane2 (the BSCANE2 logic), and unless
// XC7_TAP_NO_PRIMS is defined (the xcheck bench, which compiles the real
// unisims beside this file) BSCANE2 and BUFG with the unisim port lists.
// DRCK is modelled without the unisim's 5 ps delay and is not cross-checked.
module xc7_tap #(
  parameter [5:0]  USER4  = 6'h23,          // the teeth change it to 6'h22
  parameter [31:0] IDCODE = 32'h03631093    // XC7A100T
) (
  input  wire tck,
  input  wire tms,
  input  wire tdi,
  output reg  tdo,            // valid while tdo_oe = 1
  output reg  tdo_oe          // 0 = high-Z (outside Shift-IR / Shift-DR)
);
  localparam [5:0] I_BYPASS = 6'h3F, I_IDCODE = 6'h09,
                   I_USER1 = 6'h02, I_USER2 = 6'h03, I_USER3 = 6'h22;
  localparam [5:0] IR_CAPTURE = 6'b010001;

  localparam [3:0] TLR = 4'h0, RTI = 4'h1, SELDR = 4'h2, CAPDR = 4'h3,
                   SHDR = 4'h4, EX1DR = 4'h5, PSDR = 4'h6, EX2DR = 4'h7,
                   UPDR = 4'h8, SELIR = 4'h9, CAPIR = 4'ha, SHIR = 4'hb,
                   EX1IR = 4'hc, PSIR = 4'hd, EX2IR = 4'he, UPIR = 4'hf;

  // USERn TDO, driven by the BSCANE2 stand-ins (hierarchical assign); an
  // undriven one is high-Z (JTAG_SIME2: glbl.JTAG_USER_TDOn_GLBL = 1'bz)
  wire user_tdo1, user_tdo2, user_tdo3, user_tdo4;

  reg [3:0]  state = TLR;
  reg [5:0]  ir_sh = IR_CAPTURE;   // IR shift register
  reg [5:0]  ir    = I_IDCODE;     // IR (instruction in force)
  reg [31:0] idreg = IDCODE;
  reg        bypass = 1'b0;

  // globals, registered on the falling edge (glbl.JTAG_*_GLBL)
  reg capture = 1'b0, reset = 1'b1, runtest = 1'b0, shift = 1'b0, update = 1'b0;

  initial begin tdo = 1'b0; tdo_oe = 1'b0; end

  // instruction decode, JTAG_SIME2's priority order
  wire [2:0] sel_n = (ir == I_BYPASS) ? 3'd6 :
                     (ir == I_IDCODE) ? 3'd5 :
                     (ir == I_USER1)  ? 3'd1 :
                     (ir == I_USER2)  ? 3'd2 :
                     (ir == I_USER3)  ? 3'd3 :
                     (ir == USER4)    ? 3'd4 : 3'd0;

  // global SELn (glbl.JTAG_SELn_GLBL)
  wire sel1 = (state != TLR) && (sel_n == 3'd1);
  wire sel2 = (state != TLR) && (sel_n == 3'd2);
  wire sel3 = (state != TLR) && (sel_n == 3'd3);
  wire sel4 = (state != TLR) && (sel_n == 3'd4);

  // pins straight through (glbl.JTAG_TCK_GLBL / JTAG_TDI_GLBL)
  wire tck_g = tck;
  wire tdi_g = tdi;

  always @(posedge tck) begin
    // registers clocked by the state before this edge
    if (state == CAPIR)     ir_sh <= IR_CAPTURE;
    else if (state == SHIR) ir_sh <= {tdi, ir_sh[5:1]};
    if (sel_n == 3'd5) idreg <= (state == SHDR) ? {tdi, idreg[31:1]} : IDCODE;
    if (state == SHDR && sel_n == 3'd6) bypass <= tdi;

    case (state)
      TLR:   state <= tms ? TLR   : RTI;
      RTI:   state <= tms ? SELDR : RTI;
      SELDR: state <= tms ? SELIR : CAPDR;
      CAPDR: state <= tms ? EX1DR : SHDR;
      SHDR:  state <= tms ? EX1DR : SHDR;
      EX1DR: state <= tms ? UPDR  : PSDR;
      PSDR:  state <= tms ? EX2DR : PSDR;
      EX2DR: state <= tms ? UPDR  : SHDR;
      UPDR:  state <= tms ? SELDR : RTI;
      SELIR: state <= tms ? TLR   : CAPIR;
      CAPIR: state <= tms ? EX1IR : SHIR;
      SHIR:  state <= tms ? EX1IR : SHIR;
      EX1IR: state <= tms ? UPIR  : PSIR;
      PSIR:  state <= tms ? EX2IR : PSIR;
      EX2IR: state <= tms ? UPIR  : SHIR;
      UPIR:  state <= tms ? SELDR : RTI;
      default: state <= TLR;
    endcase
  end

  always @(negedge tck) begin
    capture <= (state == CAPDR);
    reset   <= (state == TLR);
    runtest <= (state == RTI);
    shift   <= (state == SHDR);
    update  <= (state == UPDR);

    if (state == TLR)       ir <= I_IDCODE;
    else if (state == UPIR) ir <= ir_sh;

    tdo_oe <= (state == SHIR) || (state == SHDR && sel_n != 3'd0);
    if (state == SHIR) tdo <= ir_sh[0];
    else case (sel_n)
      3'd5:    tdo <= idreg[0];
      3'd6:    tdo <= bypass;
      3'd1:    tdo <= user_tdo1;
      3'd2:    tdo <= user_tdo2;
      3'd3:    tdo <= user_tdo3;
      3'd4:    tdo <= user_tdo4;
      default: tdo <= 1'b0;
    endcase
  end
endmodule

// BSCANE2 logic: reads the TAP instance xc7_jtag.
module xc7_bscane2 #(
  parameter integer JTAG_CHAIN = 1
) (
  output wire CAPTURE,
  output wire DRCK,
  output wire RESET,
  output wire RUNTEST,
  output reg  SEL,
  output wire SHIFT,
  output wire TCK,
  output wire TDI,
  output wire TMS,
  output wire UPDATE,
  input  wire TDO
);
  wire sel_g = (JTAG_CHAIN == 1) ? xc7_jtag.sel1 :
               (JTAG_CHAIN == 2) ? xc7_jtag.sel2 :
               (JTAG_CHAIN == 3) ? xc7_jtag.sel3 : xc7_jtag.sel4;

  initial begin
    SEL = 1'b0;
    if (JTAG_CHAIN < 1 || JTAG_CHAIN > 4) begin
      $display("=== FAIL xc7_bscane2 %m: JTAG_CHAIN %0d (legal 1..4)", JTAG_CHAIN);
      $finish;
    end
  end

  // a rising SELn at once, a falling one on the next falling TCK edge
  always @(negedge xc7_jtag.tck_g or posedge sel_g) SEL <= sel_g;

  assign CAPTURE = xc7_jtag.capture;
  assign RESET   = xc7_jtag.reset;
  assign RUNTEST = xc7_jtag.runtest;
  assign SHIFT   = xc7_jtag.shift;
  assign UPDATE  = xc7_jtag.update;
  assign TDI     = xc7_jtag.tdi_g;
  assign TCK     = xc7_jtag.tck_g;
  assign TMS     = xc7_jtag.tms;
  assign DRCK    = (sel_g & ~xc7_jtag.shift & ~xc7_jtag.capture) |
                   (sel_g &  xc7_jtag.shift   & xc7_jtag.tck_g) |
                   (sel_g &  xc7_jtag.capture & xc7_jtag.tck_g);

  generate
    if (JTAG_CHAIN == 1)      begin : g_tdo assign xc7_jtag.user_tdo1 = TDO; end
    else if (JTAG_CHAIN == 2) begin : g_tdo assign xc7_jtag.user_tdo2 = TDO; end
    else if (JTAG_CHAIN == 3) begin : g_tdo assign xc7_jtag.user_tdo3 = TDO; end
    else                      begin : g_tdo assign xc7_jtag.user_tdo4 = TDO; end
  endgenerate
endmodule

`ifndef XC7_TAP_NO_PRIMS
// Stand-ins for the unisim primitives rv_bscane2.v instantiates (same
// module names, parameters and ports as $XILINX_VIVADO/.../unisims/
// BSCANE2.v and BUFG.v).
module BSCANE2 #(
  parameter DISABLE_JTAG = "FALSE",
  parameter integer JTAG_CHAIN = 1
) (
  output wire CAPTURE,
  output wire DRCK,
  output wire RESET,
  output wire RUNTEST,
  output wire SEL,
  output wire SHIFT,
  output wire TCK,
  output wire TDI,
  output wire TMS,
  output wire UPDATE,
  input  wire TDO
);
  xc7_bscane2 #(.JTAG_CHAIN(JTAG_CHAIN)) u (
    .CAPTURE(CAPTURE), .DRCK(DRCK), .RESET(RESET), .RUNTEST(RUNTEST),
    .SEL(SEL), .SHIFT(SHIFT), .TCK(TCK), .TDI(TDI), .TMS(TMS),
    .UPDATE(UPDATE), .TDO(TDO));
endmodule

module BUFG (
  output wire O,
  input  wire I
);
  assign O = I;
endmodule
`endif
