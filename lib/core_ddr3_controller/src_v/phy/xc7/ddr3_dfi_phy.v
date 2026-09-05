//-----------------------------------------------------------------
//              Lightweight DDR3 Memory Controller
//                            V0.5
//                     Ultra-Embedded.com
//                     Copyright 2020-21
//
//                   admin@ultra-embedded.com
//
//                     License: Apache 2.0
//-----------------------------------------------------------------
// Copyright 2020-21 Ultra-Embedded.com
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//-----------------------------------------------------------------
module ddr3_dfi_phy
//-----------------------------------------------------------------
// Params
//-----------------------------------------------------------------
#(
     parameter REFCLK_FREQUENCY = 200
    // DQS_TAP_DELAY_INIT is DEAD since the read path stopped capturing with the
    // DQS strobe (see "Read Data Strobe (DQS) - input side unused" below).  It
    // is kept so that instantiations do not have to change.
    ,parameter DQS_TAP_DELAY_INIT = 15
    ,parameter DQ_TAP_DELAY_INIT = 1
    // TPHY_RDLAT: clk_i cycles from dfi_rddata_en_i to dfi_rddata_valid_o.
    // Overridable at runtime by cfg_i[10:8].  5 is the value MEASURED on the
    // QMTECH XC7A100T board with this oversampled read capture; see
    // findings/ddr3/bringup.md, "Read-path rework".
    ,parameter TPHY_RDLAT       = 5
    ,parameter TPHY_WRLAT       = 3
    ,parameter TPHY_WRDATA      = 0
    // RDSEL_INIT: reset value of the read-sample select, cfg_i[3:0].  11 (sample
    // phase 3, half-cycle offset set) is the centre of the window measured on
    // the board.  Simulation against the Micron model prefers one beat earlier;
    // the board wins.
    ,parameter RDSEL_INIT       = 4'hB
)
//-----------------------------------------------------------------
// Ports
//-----------------------------------------------------------------
(
    // Inputs
     input           clk_i
    ,input           clk_ddr_i
    ,input           clk_ddr90_i
    ,input           clk_ref_i
    ,input           rst_i
    ,input           cfg_valid_i
    ,input  [ 31:0]  cfg_i
    ,input  [ 14:0]  dfi_address_i
    ,input  [  2:0]  dfi_bank_i
    ,input           dfi_cas_n_i
    ,input           dfi_cke_i
    ,input           dfi_cs_n_i
    ,input           dfi_odt_i
    ,input           dfi_ras_n_i
    ,input           dfi_reset_n_i
    ,input           dfi_we_n_i
    ,input  [ 31:0]  dfi_wrdata_i
    ,input           dfi_wrdata_en_i
    ,input  [  3:0]  dfi_wrdata_mask_i
    ,input           dfi_rddata_en_i

    // Outputs
    ,output [ 31:0]  dfi_rddata_o
    ,output          dfi_rddata_valid_o
    ,output [  1:0]  dfi_rddata_dnv_o
    ,output          ddr3_ck_p_o
    ,output          ddr3_ck_n_o
    ,output          ddr3_cke_o
    ,output          ddr3_reset_n_o
    ,output          ddr3_ras_n_o
    ,output          ddr3_cas_n_o
    ,output          ddr3_we_n_o
    ,output          ddr3_cs_n_o
    ,output [  2:0]  ddr3_ba_o
    ,output [ 13:0]  ddr3_addr_o
    ,output          ddr3_odt_o
    ,output [  1:0]  ddr3_dm_o
    ,inout [  1:0]  ddr3_dqs_p_io
    ,inout [  1:0]  ddr3_dqs_n_io
    ,inout [ 15:0]  ddr3_dq_io
);



//-----------------------------------------------------------------
// Configuration
//-----------------------------------------------------------------
`define DDR_PHY_CFG_RDSEL_R         3:0
`define DDR_PHY_CFG_RDLAT_R         10:8
`define DDR_PHY_CFG_DLY_DQS_RST_R   17:16
`define DDR_PHY_CFG_DLY_DQS_INC_R   19:18
`define DDR_PHY_CFG_DLY_DQ_RST_R    21:20
`define DDR_PHY_CFG_DLY_DQ_INC_R    23:22

reg cfg_valid_q;

always @ (posedge clk_i )
if (rst_i)
    cfg_valid_q <= 1'b0;
else
    cfg_valid_q <= cfg_valid_i;

wire cfg_valid_pulse_w = cfg_valid_i & ~cfg_valid_q;

reg [2:0] rd_lat_q;

always @ (posedge clk_i )
if (rst_i)
    rd_lat_q <= TPHY_RDLAT;
else if (cfg_valid_i)
    rd_lat_q <= cfg_i[`DDR_PHY_CFG_RDLAT_R];

reg [3:0] rd_sel_q;

always @ (posedge clk_i )
if (rst_i)
    rd_sel_q <= RDSEL_INIT;
else if (cfg_valid_i)
    rd_sel_q <= cfg_i[`DDR_PHY_CFG_RDSEL_R];

reg [1:0] dqs_delay_rst_q;
reg [1:0] dqs_delay_inc_q;
reg [1:0] dq_delay_rst_q;
reg [1:0] dq_delay_inc_q;

always @ (posedge clk_i )
if (rst_i)
    dqs_delay_rst_q <= 2'b0;
else if (cfg_valid_pulse_w)
    dqs_delay_rst_q <= cfg_i[`DDR_PHY_CFG_DLY_DQS_RST_R];
else
    dqs_delay_rst_q <= 2'b0;

always @ (posedge clk_i )
if (rst_i)
    dqs_delay_inc_q <= 2'b0;
else if (cfg_valid_pulse_w)
    dqs_delay_inc_q <= cfg_i[`DDR_PHY_CFG_DLY_DQS_INC_R];
else
    dqs_delay_inc_q <= 2'b0;

always @ (posedge clk_i )
if (rst_i)
    dq_delay_rst_q <= 2'b0;
else if (cfg_valid_pulse_w)
    dq_delay_rst_q <= cfg_i[`DDR_PHY_CFG_DLY_DQ_RST_R];
else
    dq_delay_rst_q <= 2'b0;

always @ (posedge clk_i )
if (rst_i)
    dq_delay_inc_q <= 2'b0;
else if (cfg_valid_pulse_w)
    dq_delay_inc_q <= cfg_i[`DDR_PHY_CFG_DLY_DQ_INC_R];
else
    dq_delay_inc_q <= 2'b0;

//-----------------------------------------------------------------
// DDR Clock
//-----------------------------------------------------------------
// Differential clock output
OBUFDS
#(
    .IOSTANDARD("DIFF_SSTL135")
)
u_pad_ck
(
     .I(~clk_i)
    ,.O(ddr3_ck_p_o)
    ,.OB(ddr3_ck_n_o)
);

//-----------------------------------------------------------------
// Command
//-----------------------------------------------------------------
// Xilinx placement pragmas:
//synthesis attribute IOB of cke_q is "TRUE"
//synthesis attribute IOB of reset_n_q is "TRUE"
//synthesis attribute IOB of ras_n_q is "TRUE"
//synthesis attribute IOB of cas_n_q is "TRUE"
//synthesis attribute IOB of we_n_q is "TRUE"
//synthesis attribute IOB of cs_n_q is "TRUE"
//synthesis attribute IOB of ba_q is "TRUE"
//synthesis attribute IOB of addr_q is "TRUE"
//synthesis attribute IOB of odt_q is "TRUE"

reg        cke_q;
always @ (posedge clk_i )
if (rst_i)
    cke_q <= 1'b0;
else
    cke_q <= dfi_cke_i;
assign ddr3_cke_o       = cke_q;

reg        reset_n_q;
always @ (posedge clk_i )
if (rst_i)
    reset_n_q <= 1'b0;
else
    reset_n_q <= dfi_reset_n_i;
assign ddr3_reset_n_o   = reset_n_q;

reg        ras_n_q;
always @ (posedge clk_i )
if (rst_i)
    ras_n_q <= 1'b0;
else
    ras_n_q <= dfi_ras_n_i;
assign ddr3_ras_n_o     = ras_n_q;

reg        cas_n_q;
always @ (posedge clk_i )
if (rst_i)
    cas_n_q <= 1'b0;
else
    cas_n_q <= dfi_cas_n_i;
assign ddr3_cas_n_o     = cas_n_q;

reg        we_n_q;
always @ (posedge clk_i )
if (rst_i)
    we_n_q <= 1'b0;
else
    we_n_q <= dfi_we_n_i;
assign ddr3_we_n_o      = we_n_q;

reg        cs_n_q;
always @ (posedge clk_i )
if (rst_i)
    cs_n_q <= 1'b0;
else
    cs_n_q <= dfi_cs_n_i;
assign ddr3_cs_n_o      = cs_n_q;

reg [2:0]  ba_q;
always @ (posedge clk_i )
if (rst_i)
    ba_q <= 3'b0;
else
    ba_q <= dfi_bank_i;
assign ddr3_ba_o        = ba_q;

reg [13:0] addr_q;
always @ (posedge clk_i )
if (rst_i)
    addr_q <= 14'b0;
else
    addr_q <= dfi_address_i[13:0]; // TODO: Address bit...
assign ddr3_addr_o      = addr_q;

reg        odt_q;
always @ (posedge clk_i )
if (rst_i)
    odt_q <= 1'b0;
else
    odt_q <= dfi_odt_i;
assign ddr3_odt_o       = odt_q;

//-----------------------------------------------------------------
// Write Output Enable
//-----------------------------------------------------------------
reg wr_valid_q0;
always @ (posedge clk_i )
if (rst_i)
    wr_valid_q0 <= 1'b0;
else
    wr_valid_q0 <= dfi_wrdata_en_i;

reg wr_valid_q1;
always @ (posedge clk_i )
if (rst_i)
    wr_valid_q1 <= 1'b0;
else
    wr_valid_q1 <= wr_valid_q0;

reg dqs_out_en_n_q;
always @ (posedge clk_i )
if (rst_i)
    dqs_out_en_n_q <= 1'b0;
else
    dqs_out_en_n_q <= ~wr_valid_q1;    

//-----------------------------------------------------------------
// DQS I/O Buffers
//-----------------------------------------------------------------
wire [1:0] dqs_out_en_n_w;
wire [1:0] dqs_out_w;
wire [1:0] dqs_in_w;

IOBUFDS
#(
    .IOSTANDARD("DIFF_SSTL135")
)
u_pad_dqs0
(
     .I(dqs_out_w[0])
    ,.O(dqs_in_w[0])
    ,.T(dqs_out_en_n_w[0])
    ,.IO(ddr3_dqs_p_io[0])
    ,.IOB(ddr3_dqs_n_io[0])
);

IOBUFDS
#(
    .IOSTANDARD("DIFF_SSTL135")
)
u_pad_dqs1
(
     .I(dqs_out_w[1])
    ,.O(dqs_in_w[1])
    ,.T(dqs_out_en_n_w[1])
    ,.IO(ddr3_dqs_p_io[1])
    ,.IOB(ddr3_dqs_n_io[1])
);

//-----------------------------------------------------------------
// Write Data (DQ)
//-----------------------------------------------------------------
reg [31:0] dfi_wrdata_q;

always @ (posedge clk_i )
if (rst_i)
    dfi_wrdata_q <= 32'b0;
else
    dfi_wrdata_q <= dfi_wrdata_i;

wire [15:0] dq_in_w;
wire [15:0] dq_out_w;
wire [15:0] dq_out_en_n_w;

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq0
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[0+0])
  ,.D2(dfi_wrdata_q[0+0])
  ,.D3(dfi_wrdata_q[0+0])
  ,.D4(dfi_wrdata_q[0+0])
  ,.D5(dfi_wrdata_q[0+16])
  ,.D6(dfi_wrdata_q[0+16])
  ,.D7(dfi_wrdata_q[0+16])
  ,.D8(dfi_wrdata_q[0+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[0])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[0])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq0
(
     .I(dq_out_w[0])
    ,.O(dq_in_w[0])
    ,.T(dq_out_en_n_w[0])
    ,.IO(ddr3_dq_io[0])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq1
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[1+0])
  ,.D2(dfi_wrdata_q[1+0])
  ,.D3(dfi_wrdata_q[1+0])
  ,.D4(dfi_wrdata_q[1+0])
  ,.D5(dfi_wrdata_q[1+16])
  ,.D6(dfi_wrdata_q[1+16])
  ,.D7(dfi_wrdata_q[1+16])
  ,.D8(dfi_wrdata_q[1+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[1])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[1])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq1
(
     .I(dq_out_w[1])
    ,.O(dq_in_w[1])
    ,.T(dq_out_en_n_w[1])
    ,.IO(ddr3_dq_io[1])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq2
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[2+0])
  ,.D2(dfi_wrdata_q[2+0])
  ,.D3(dfi_wrdata_q[2+0])
  ,.D4(dfi_wrdata_q[2+0])
  ,.D5(dfi_wrdata_q[2+16])
  ,.D6(dfi_wrdata_q[2+16])
  ,.D7(dfi_wrdata_q[2+16])
  ,.D8(dfi_wrdata_q[2+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[2])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[2])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq2
(
     .I(dq_out_w[2])
    ,.O(dq_in_w[2])
    ,.T(dq_out_en_n_w[2])
    ,.IO(ddr3_dq_io[2])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq3
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[3+0])
  ,.D2(dfi_wrdata_q[3+0])
  ,.D3(dfi_wrdata_q[3+0])
  ,.D4(dfi_wrdata_q[3+0])
  ,.D5(dfi_wrdata_q[3+16])
  ,.D6(dfi_wrdata_q[3+16])
  ,.D7(dfi_wrdata_q[3+16])
  ,.D8(dfi_wrdata_q[3+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[3])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[3])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq3
(
     .I(dq_out_w[3])
    ,.O(dq_in_w[3])
    ,.T(dq_out_en_n_w[3])
    ,.IO(ddr3_dq_io[3])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq4
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[4+0])
  ,.D2(dfi_wrdata_q[4+0])
  ,.D3(dfi_wrdata_q[4+0])
  ,.D4(dfi_wrdata_q[4+0])
  ,.D5(dfi_wrdata_q[4+16])
  ,.D6(dfi_wrdata_q[4+16])
  ,.D7(dfi_wrdata_q[4+16])
  ,.D8(dfi_wrdata_q[4+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[4])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[4])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq4
(
     .I(dq_out_w[4])
    ,.O(dq_in_w[4])
    ,.T(dq_out_en_n_w[4])
    ,.IO(ddr3_dq_io[4])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq5
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[5+0])
  ,.D2(dfi_wrdata_q[5+0])
  ,.D3(dfi_wrdata_q[5+0])
  ,.D4(dfi_wrdata_q[5+0])
  ,.D5(dfi_wrdata_q[5+16])
  ,.D6(dfi_wrdata_q[5+16])
  ,.D7(dfi_wrdata_q[5+16])
  ,.D8(dfi_wrdata_q[5+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[5])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[5])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq5
(
     .I(dq_out_w[5])
    ,.O(dq_in_w[5])
    ,.T(dq_out_en_n_w[5])
    ,.IO(ddr3_dq_io[5])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq6
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[6+0])
  ,.D2(dfi_wrdata_q[6+0])
  ,.D3(dfi_wrdata_q[6+0])
  ,.D4(dfi_wrdata_q[6+0])
  ,.D5(dfi_wrdata_q[6+16])
  ,.D6(dfi_wrdata_q[6+16])
  ,.D7(dfi_wrdata_q[6+16])
  ,.D8(dfi_wrdata_q[6+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[6])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[6])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq6
(
     .I(dq_out_w[6])
    ,.O(dq_in_w[6])
    ,.T(dq_out_en_n_w[6])
    ,.IO(ddr3_dq_io[6])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq7
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[7+0])
  ,.D2(dfi_wrdata_q[7+0])
  ,.D3(dfi_wrdata_q[7+0])
  ,.D4(dfi_wrdata_q[7+0])
  ,.D5(dfi_wrdata_q[7+16])
  ,.D6(dfi_wrdata_q[7+16])
  ,.D7(dfi_wrdata_q[7+16])
  ,.D8(dfi_wrdata_q[7+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[7])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[7])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq7
(
     .I(dq_out_w[7])
    ,.O(dq_in_w[7])
    ,.T(dq_out_en_n_w[7])
    ,.IO(ddr3_dq_io[7])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq8
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[8+0])
  ,.D2(dfi_wrdata_q[8+0])
  ,.D3(dfi_wrdata_q[8+0])
  ,.D4(dfi_wrdata_q[8+0])
  ,.D5(dfi_wrdata_q[8+16])
  ,.D6(dfi_wrdata_q[8+16])
  ,.D7(dfi_wrdata_q[8+16])
  ,.D8(dfi_wrdata_q[8+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[8])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[8])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq8
(
     .I(dq_out_w[8])
    ,.O(dq_in_w[8])
    ,.T(dq_out_en_n_w[8])
    ,.IO(ddr3_dq_io[8])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq9
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[9+0])
  ,.D2(dfi_wrdata_q[9+0])
  ,.D3(dfi_wrdata_q[9+0])
  ,.D4(dfi_wrdata_q[9+0])
  ,.D5(dfi_wrdata_q[9+16])
  ,.D6(dfi_wrdata_q[9+16])
  ,.D7(dfi_wrdata_q[9+16])
  ,.D8(dfi_wrdata_q[9+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[9])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[9])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq9
(
     .I(dq_out_w[9])
    ,.O(dq_in_w[9])
    ,.T(dq_out_en_n_w[9])
    ,.IO(ddr3_dq_io[9])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq10
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[10+0])
  ,.D2(dfi_wrdata_q[10+0])
  ,.D3(dfi_wrdata_q[10+0])
  ,.D4(dfi_wrdata_q[10+0])
  ,.D5(dfi_wrdata_q[10+16])
  ,.D6(dfi_wrdata_q[10+16])
  ,.D7(dfi_wrdata_q[10+16])
  ,.D8(dfi_wrdata_q[10+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[10])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[10])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq10
(
     .I(dq_out_w[10])
    ,.O(dq_in_w[10])
    ,.T(dq_out_en_n_w[10])
    ,.IO(ddr3_dq_io[10])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq11
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[11+0])
  ,.D2(dfi_wrdata_q[11+0])
  ,.D3(dfi_wrdata_q[11+0])
  ,.D4(dfi_wrdata_q[11+0])
  ,.D5(dfi_wrdata_q[11+16])
  ,.D6(dfi_wrdata_q[11+16])
  ,.D7(dfi_wrdata_q[11+16])
  ,.D8(dfi_wrdata_q[11+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[11])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[11])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq11
(
     .I(dq_out_w[11])
    ,.O(dq_in_w[11])
    ,.T(dq_out_en_n_w[11])
    ,.IO(ddr3_dq_io[11])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq12
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[12+0])
  ,.D2(dfi_wrdata_q[12+0])
  ,.D3(dfi_wrdata_q[12+0])
  ,.D4(dfi_wrdata_q[12+0])
  ,.D5(dfi_wrdata_q[12+16])
  ,.D6(dfi_wrdata_q[12+16])
  ,.D7(dfi_wrdata_q[12+16])
  ,.D8(dfi_wrdata_q[12+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[12])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[12])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq12
(
     .I(dq_out_w[12])
    ,.O(dq_in_w[12])
    ,.T(dq_out_en_n_w[12])
    ,.IO(ddr3_dq_io[12])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq13
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[13+0])
  ,.D2(dfi_wrdata_q[13+0])
  ,.D3(dfi_wrdata_q[13+0])
  ,.D4(dfi_wrdata_q[13+0])
  ,.D5(dfi_wrdata_q[13+16])
  ,.D6(dfi_wrdata_q[13+16])
  ,.D7(dfi_wrdata_q[13+16])
  ,.D8(dfi_wrdata_q[13+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[13])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[13])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq13
(
     .I(dq_out_w[13])
    ,.O(dq_in_w[13])
    ,.T(dq_out_en_n_w[13])
    ,.IO(ddr3_dq_io[13])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq14
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[14+0])
  ,.D2(dfi_wrdata_q[14+0])
  ,.D3(dfi_wrdata_q[14+0])
  ,.D4(dfi_wrdata_q[14+0])
  ,.D5(dfi_wrdata_q[14+16])
  ,.D6(dfi_wrdata_q[14+16])
  ,.D7(dfi_wrdata_q[14+16])
  ,.D8(dfi_wrdata_q[14+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[14])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[14])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq14
(
     .I(dq_out_w[14])
    ,.O(dq_in_w[14])
    ,.T(dq_out_en_n_w[14])
    ,.IO(ddr3_dq_io[14])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dq15
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wrdata_q[15+0])
  ,.D2(dfi_wrdata_q[15+0])
  ,.D3(dfi_wrdata_q[15+0])
  ,.D4(dfi_wrdata_q[15+0])
  ,.D5(dfi_wrdata_q[15+16])
  ,.D6(dfi_wrdata_q[15+16])
  ,.D7(dfi_wrdata_q[15+16])
  ,.D8(dfi_wrdata_q[15+16])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dq_out_w[15])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dq_out_en_n_w[15])
);

IOBUF
#(
     .IOSTANDARD("SSTL135")
    ,.SLEW("FAST")
)
u_pad_dq15
(
     .I(dq_out_w[15])
    ,.O(dq_in_w[15])
    ,.T(dq_out_en_n_w[15])
    ,.IO(ddr3_dq_io[15])
);


//-----------------------------------------------------------------
// Data Mask (DM)
//-----------------------------------------------------------------
wire [1:0] dm_out_w;
reg [3:0]  dfi_wr_mask_q;

always @ (posedge clk_i )
if (rst_i)
    dfi_wr_mask_q <= 4'b0;
else
    dfi_wr_mask_q <= dfi_wrdata_mask_i;

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dm0
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wr_mask_q[0])
  ,.D2(dfi_wr_mask_q[0])
  ,.D3(dfi_wr_mask_q[0])
  ,.D4(dfi_wr_mask_q[0])
  ,.D5(dfi_wr_mask_q[2])
  ,.D6(dfi_wr_mask_q[2])
  ,.D7(dfi_wr_mask_q[2])
  ,.D8(dfi_wr_mask_q[2])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(0)
  ,.T2(0)
  ,.T3(0)
  ,.T4(0)
  ,.TBYTEIN(0)
  ,.TCE(0)

  ,.OQ(dm_out_w[0])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ()
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dm1
(
   .CLK(clk_ddr_i)
  ,.CLKDIV(clk_i)
  ,.D1(dfi_wr_mask_q[1])
  ,.D2(dfi_wr_mask_q[1])
  ,.D3(dfi_wr_mask_q[1])
  ,.D4(dfi_wr_mask_q[1])
  ,.D5(dfi_wr_mask_q[3])
  ,.D6(dfi_wr_mask_q[3])
  ,.D7(dfi_wr_mask_q[3])
  ,.D8(dfi_wr_mask_q[3])
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(0)
  ,.T2(0)
  ,.T3(0)
  ,.T4(0)
  ,.TBYTEIN(0)
  ,.TCE(0)

  ,.OQ(dm_out_w[1])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ()
);

assign ddr3_dm_o   = dm_out_w;

//-----------------------------------------------------------------
// Write Data Strobe (DQS)
//-----------------------------------------------------------------
OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dqs0
(
   .CLK(clk_ddr90_i)
  ,.CLKDIV(clk_i)
  ,.D1(0)
  ,.D2(0)
  ,.D3(1)
  ,.D4(1)
  ,.D5(1)
  ,.D6(1)
  ,.D7(0)
  ,.D8(0)
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dqs_out_w[0])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dqs_out_en_n_w[0])
);

OSERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.DATA_WIDTH(8)
    ,.TRISTATE_WIDTH(1)
    ,.DATA_RATE_OQ("DDR")
    ,.DATA_RATE_TQ("BUF")
)
u_serdes_dqs1
(
   .CLK(clk_ddr90_i)
  ,.CLKDIV(clk_i)
  ,.D1(0)
  ,.D2(0)
  ,.D3(1)
  ,.D4(1)
  ,.D5(1)
  ,.D6(1)
  ,.D7(0)
  ,.D8(0)
  ,.OCE(1)
  ,.RST(rst_i)
  ,.SHIFTIN1(0)
  ,.SHIFTIN2(0)
  ,.T1(dqs_out_en_n_q)
  ,.T2(dqs_out_en_n_q)
  ,.T3(dqs_out_en_n_q)
  ,.T4(dqs_out_en_n_q)
  ,.TBYTEIN(0)
  ,.TCE(1)

  ,.OQ(dqs_out_w[1])
  ,.OFB()
  ,.SHIFTOUT1()
  ,.SHIFTOUT2()
  ,.TBYTEOUT()
  ,.TFB()
  ,.TQ(dqs_out_en_n_w[1])
);

//-----------------------------------------------------------------
// Read Data Strobe (DQS) - input side unused
//
// The DQS pads are still driven during writes (see the OSERDESE2 above and
// the IOBUFDS pair), but the READ path no longer captures with the strobe.
// On this board (QMTECH XC7A100T core module) the DQS pins B20/A20 and
// A23/A24 are byte-group strobe pins, not clock-capable pins: they cannot
// drive a BUFIO/BUFR, so a MEMORY-mode ISERDESE2 clocked by DQS mixes a
// strobe-region CLK with BUFG OCLK/CLKDIV.  That is DRC REQP-1580 and it is
// what broke beats 2..8 of every burst on hardware (findings/ddr3/bringup.md).
//
// The two input IDELAYE2 delay lines that used to sit here (u_dqs_delay0/1)
// have been REMOVED; the IOBUFDS `O` pins (dqs_in_w) are simply left
// unconnected.  cfg_i[19:16] (DLY_DQS_RST / DLY_DQS_INC) keep their bit
// positions in the register map but are now no-ops.
//-----------------------------------------------------------------

//-----------------------------------------------------------------
// Read capture
//-----------------------------------------------------------------
wire delay_rdy_w;

IDELAYCTRL 
#(.SIM_DEVICE ("7SERIES")) 
u_dly_ref
(
     .REFCLK(clk_ref_i)
    ,.RST(rst_i)
    ,.RDY(delay_rdy_w)
);


wire [15:0] dq_delayed_w;


IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay0
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[0])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[0])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[0])  // Delayed data
    ,.LD(dq_delay_rst_q[0])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq0_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in0
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[0])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq0_in_w[0])
    ,.Q2(rd_dq0_in_w[1])
    ,.Q3(rd_dq0_in_w[2])
    ,.Q4(rd_dq0_in_w[3])
    ,.Q5(rd_dq0_in_w[4])
    ,.Q6(rd_dq0_in_w[5])
    ,.Q7(rd_dq0_in_w[6])
    ,.Q8(rd_dq0_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay1
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[0])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[1])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[1])  // Delayed data
    ,.LD(dq_delay_rst_q[0])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq1_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in1
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[1])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq1_in_w[0])
    ,.Q2(rd_dq1_in_w[1])
    ,.Q3(rd_dq1_in_w[2])
    ,.Q4(rd_dq1_in_w[3])
    ,.Q5(rd_dq1_in_w[4])
    ,.Q6(rd_dq1_in_w[5])
    ,.Q7(rd_dq1_in_w[6])
    ,.Q8(rd_dq1_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay2
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[0])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[2])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[2])  // Delayed data
    ,.LD(dq_delay_rst_q[0])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq2_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in2
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[2])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq2_in_w[0])
    ,.Q2(rd_dq2_in_w[1])
    ,.Q3(rd_dq2_in_w[2])
    ,.Q4(rd_dq2_in_w[3])
    ,.Q5(rd_dq2_in_w[4])
    ,.Q6(rd_dq2_in_w[5])
    ,.Q7(rd_dq2_in_w[6])
    ,.Q8(rd_dq2_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay3
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[0])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[3])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[3])  // Delayed data
    ,.LD(dq_delay_rst_q[0])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq3_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in3
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[3])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq3_in_w[0])
    ,.Q2(rd_dq3_in_w[1])
    ,.Q3(rd_dq3_in_w[2])
    ,.Q4(rd_dq3_in_w[3])
    ,.Q5(rd_dq3_in_w[4])
    ,.Q6(rd_dq3_in_w[5])
    ,.Q7(rd_dq3_in_w[6])
    ,.Q8(rd_dq3_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay4
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[0])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[4])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[4])  // Delayed data
    ,.LD(dq_delay_rst_q[0])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq4_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in4
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[4])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq4_in_w[0])
    ,.Q2(rd_dq4_in_w[1])
    ,.Q3(rd_dq4_in_w[2])
    ,.Q4(rd_dq4_in_w[3])
    ,.Q5(rd_dq4_in_w[4])
    ,.Q6(rd_dq4_in_w[5])
    ,.Q7(rd_dq4_in_w[6])
    ,.Q8(rd_dq4_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay5
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[0])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[5])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[5])  // Delayed data
    ,.LD(dq_delay_rst_q[0])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq5_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in5
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[5])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq5_in_w[0])
    ,.Q2(rd_dq5_in_w[1])
    ,.Q3(rd_dq5_in_w[2])
    ,.Q4(rd_dq5_in_w[3])
    ,.Q5(rd_dq5_in_w[4])
    ,.Q6(rd_dq5_in_w[5])
    ,.Q7(rd_dq5_in_w[6])
    ,.Q8(rd_dq5_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay6
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[0])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[6])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[6])  // Delayed data
    ,.LD(dq_delay_rst_q[0])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq6_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in6
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[6])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq6_in_w[0])
    ,.Q2(rd_dq6_in_w[1])
    ,.Q3(rd_dq6_in_w[2])
    ,.Q4(rd_dq6_in_w[3])
    ,.Q5(rd_dq6_in_w[4])
    ,.Q6(rd_dq6_in_w[5])
    ,.Q7(rd_dq6_in_w[6])
    ,.Q8(rd_dq6_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay7
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[0])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[7])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[7])  // Delayed data
    ,.LD(dq_delay_rst_q[0])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq7_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in7
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[7])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq7_in_w[0])
    ,.Q2(rd_dq7_in_w[1])
    ,.Q3(rd_dq7_in_w[2])
    ,.Q4(rd_dq7_in_w[3])
    ,.Q5(rd_dq7_in_w[4])
    ,.Q6(rd_dq7_in_w[5])
    ,.Q7(rd_dq7_in_w[6])
    ,.Q8(rd_dq7_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay8
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[1])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[8])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[8])  // Delayed data
    ,.LD(dq_delay_rst_q[1])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq8_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in8
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[8])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq8_in_w[0])
    ,.Q2(rd_dq8_in_w[1])
    ,.Q3(rd_dq8_in_w[2])
    ,.Q4(rd_dq8_in_w[3])
    ,.Q5(rd_dq8_in_w[4])
    ,.Q6(rd_dq8_in_w[5])
    ,.Q7(rd_dq8_in_w[6])
    ,.Q8(rd_dq8_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay9
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[1])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[9])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[9])  // Delayed data
    ,.LD(dq_delay_rst_q[1])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq9_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in9
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[9])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq9_in_w[0])
    ,.Q2(rd_dq9_in_w[1])
    ,.Q3(rd_dq9_in_w[2])
    ,.Q4(rd_dq9_in_w[3])
    ,.Q5(rd_dq9_in_w[4])
    ,.Q6(rd_dq9_in_w[5])
    ,.Q7(rd_dq9_in_w[6])
    ,.Q8(rd_dq9_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay10
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[1])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[10])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[10])  // Delayed data
    ,.LD(dq_delay_rst_q[1])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq10_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in10
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[10])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq10_in_w[0])
    ,.Q2(rd_dq10_in_w[1])
    ,.Q3(rd_dq10_in_w[2])
    ,.Q4(rd_dq10_in_w[3])
    ,.Q5(rd_dq10_in_w[4])
    ,.Q6(rd_dq10_in_w[5])
    ,.Q7(rd_dq10_in_w[6])
    ,.Q8(rd_dq10_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay11
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[1])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[11])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[11])  // Delayed data
    ,.LD(dq_delay_rst_q[1])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq11_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in11
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[11])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq11_in_w[0])
    ,.Q2(rd_dq11_in_w[1])
    ,.Q3(rd_dq11_in_w[2])
    ,.Q4(rd_dq11_in_w[3])
    ,.Q5(rd_dq11_in_w[4])
    ,.Q6(rd_dq11_in_w[5])
    ,.Q7(rd_dq11_in_w[6])
    ,.Q8(rd_dq11_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay12
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[1])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[12])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[12])  // Delayed data
    ,.LD(dq_delay_rst_q[1])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq12_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in12
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[12])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq12_in_w[0])
    ,.Q2(rd_dq12_in_w[1])
    ,.Q3(rd_dq12_in_w[2])
    ,.Q4(rd_dq12_in_w[3])
    ,.Q5(rd_dq12_in_w[4])
    ,.Q6(rd_dq12_in_w[5])
    ,.Q7(rd_dq12_in_w[6])
    ,.Q8(rd_dq12_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay13
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[1])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[13])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[13])  // Delayed data
    ,.LD(dq_delay_rst_q[1])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq13_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in13
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[13])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq13_in_w[0])
    ,.Q2(rd_dq13_in_w[1])
    ,.Q3(rd_dq13_in_w[2])
    ,.Q4(rd_dq13_in_w[3])
    ,.Q5(rd_dq13_in_w[4])
    ,.Q6(rd_dq13_in_w[5])
    ,.Q7(rd_dq13_in_w[6])
    ,.Q8(rd_dq13_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay14
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[1])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[14])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[14])  // Delayed data
    ,.LD(dq_delay_rst_q[1])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq14_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in14
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[14])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq14_in_w[0])
    ,.Q2(rd_dq14_in_w[1])
    ,.Q3(rd_dq14_in_w[2])
    ,.Q4(rd_dq14_in_w[3])
    ,.Q5(rd_dq14_in_w[4])
    ,.Q6(rd_dq14_in_w[5])
    ,.Q7(rd_dq14_in_w[6])
    ,.Q8(rd_dq14_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

IDELAYE2 
#(
     .IDELAY_TYPE("VARIABLE")
    ,.DELAY_SRC("IDATAIN")
    ,.CINVCTRL_SEL("FALSE")
    ,.IDELAY_VALUE(DQ_TAP_DELAY_INIT)
    ,.HIGH_PERFORMANCE_MODE ("TRUE")
    ,.REFCLK_FREQUENCY(REFCLK_FREQUENCY)
    ,.PIPE_SEL("FALSE")
    ,.SIGNAL_PATTERN("DATA")
)
u_dq_delay15
(
     .C(clk_i)
    ,.REGRST(1'b0)
    ,.CE(dq_delay_inc_q[1])
    ,.INC(1'b1)                    // Increment/decrement number of tap delays.
    ,.DATAIN(1'b0)
    ,.IDATAIN(dq_in_w[15])       // Data input for IDELAY from the IBUF.
    ,.LDPIPEEN(1'b0)
    ,.CINVCTRL(1'b0)
    ,.DATAOUT(dq_delayed_w[15])  // Delayed data
    ,.LD(dq_delay_rst_q[1])   // Set the IDELAYE2 delay to IDELAY_VALUE
    ,.CNTVALUEIN(5'b0)
    ,.CNTVALUEOUT()
);

wire [7:0] rd_dq15_in_w;
ISERDESE2
#(
     .SERDES_MODE("MASTER")
    ,.INTERFACE_TYPE("NETWORKING")   // CK-clocked oversampling, no DQS strobe
    ,.DATA_WIDTH(8)
    ,.DATA_RATE("DDR")
    ,.NUM_CE(1)
    ,.IOBDELAY("IFD")                // capture the IDELAYE2 output (DDLY)
)
u_serdes_dq_in15
(
    // Sample clock: the 400 MHz BUFG, both edges -> 800 Msps
     .CLK(clk_ddr_i)
    ,.CLKB(~clk_ddr_i)

    // Fabric clock: the 100 MHz BUFG, 8 samples per cycle
    ,.CLKDIV(clk_i)
    ,.CLKDIVP(1'b0)

    // Unused in NETWORKING mode
    ,.OCLK(1'b0)
    ,.OCLKB(1'b0)

    ,.RST(rst_i)
    ,.BITSLIP(1'b0)
    ,.CE1(1'b1)
    ,.CE2(1'b0)

    ,.DDLY(dq_delayed_w[15])
    ,.D(1'b0)

    // Parallel output: Q8 is the OLDEST sample, Q1 the NEWEST.
    ,.Q1(rd_dq15_in_w[0])
    ,.Q2(rd_dq15_in_w[1])
    ,.Q3(rd_dq15_in_w[2])
    ,.Q4(rd_dq15_in_w[3])
    ,.Q5(rd_dq15_in_w[4])
    ,.Q6(rd_dq15_in_w[5])
    ,.Q7(rd_dq15_in_w[6])
    ,.Q8(rd_dq15_in_w[7])

    // Unused
    ,.O()
    ,.SHIFTOUT1()
    ,.SHIFTOUT2()
    ,.DYNCLKDIVSEL(1'b0)
    ,.DYNCLKSEL(1'b0)
    ,.OFB(1'b0)
    ,.SHIFTIN1(1'b0)
    ,.SHIFTIN2(1'b0)
);

//-----------------------------------------------------------------
// Read data assembly - oversampled, no DQS
//
// Each DQ lane is deserialised 8:1 by an ISERDESE2 in NETWORKING mode with
// CLK = clk_ddr_i (400 MHz, BUFG) sampling on both edges and CLKDIV = clk_i
// (100 MHz, BUFG).  That is 800 Msps = one sample every 1.25 ns, and eight
// samples per 100 MHz cycle.
//
// The DDR3 runs DLL-off at CK = 100 MHz, so one read beat is 5 ns wide:
// exactly FOUR oversamples per beat and TWO beats per clk_i cycle.
//
//                      one clk_i cycle = 10 ns = 8 oversamples
//                    |<--------------------------------------->|
//   clk_i         ___|~~~~~~~~~~~~~~~~~~~~|____________________|~~~~
//   DQ from DRAM  ...|<-- beat A -->|<-- beat B -->|<-- beat C -->|
//                    |    5 ns      |
//   sample index      0   1   2   3   4   5   6   7   0   1   2  ...
//                     ^-- 1.25 ns --^
//
// So samples 0..3 of a cycle sit inside one beat and samples 4..7 inside the
// next; whichever sample is nearest the centre of its beat is the one to keep.
//
// `rd_smp_w` holds the eight samples presented at THIS clk_i edge, index 0 =
// oldest, index 7 = newest (ISERDESE2 Q8 is the oldest bit, Q1 the newest).
// `rd_smp_q` is the same eight samples from the PREVIOUS cycle, so the pair
// forms a 16-sample sliding window per DQ bit:
//
//   rd_win_w index :  0  1  2  3  4  5  6  7 | 8  9 10 11 12 13 14 15
//                    <---- previous cycle --->|<---- this cycle ------>
//                    older  <--------- time --------->  newer
//
// The read-sample select cfg_i[3:0] (`RDSEL`, rd_sel_q) picks the pair:
//
//   sel  = rd_sel_q[2:0]  +  (rd_sel_q[3] ? 4 : 0)     -> 0 .. 11
//   beat0 = rd_win_w[sel]        (the EARLIER beat)
//   beat1 = rd_win_w[sel + 4]    (the LATER beat, one beat = 4 samples)
//
//   * rd_sel_q[2:0] walks the sample point across the eye in 1.25 ns steps.
//     0..3 stay inside one beat; 4..7 are the same four phases one beat (5 ns)
//     later, which is how the beat pairing (which physical beat becomes beat0)
//     is corrected.
//   * rd_sel_q[3] adds a further half cycle (4 samples = 5 ns), sliding the
//     beat pair across the previous/current window boundary, so that the whole
//     16-sample history is reachable.
//   * sel spans 0..11 so that sel+4 never leaves the 16-sample window; the
//     reachable range is 13.75 ns, more than one full clk_i cycle, and it
//     overlaps with the whole-cycle steps of RDLAT (cfg_i[10:8]).
//
// dfi_rddata_o keeps the original beat order: the EARLIER beat in [15:0] and
// the LATER beat in [31:16] (the old rd_sel_q==0 case was
// {rd_data1_w, rd_data0_w} with rd_data0_w = the first captured beat).
//
// RDLAT is unchanged in meaning: clk_i cycles from dfi_rddata_en_i to
// dfi_rddata_valid_o.  The pipeline depth from the ISERDES outputs to
// dfi_rddata_o is one register (rd_capture_q) exactly as before; rd_smp_q is
// a parallel history register, it does not add latency.
//-----------------------------------------------------------------

// rd_smp_w[k*16 + b] = sample k (0 = oldest) of DQ lane b, this cycle.
wire [127:0] rd_smp_w;

assign {rd_smp_w[  0+ 0], rd_smp_w[ 16+ 0], rd_smp_w[ 32+ 0], rd_smp_w[ 48+ 0],
        rd_smp_w[ 64+ 0], rd_smp_w[ 80+ 0], rd_smp_w[ 96+ 0], rd_smp_w[112+ 0]} = rd_dq0_in_w;
assign {rd_smp_w[  0+ 1], rd_smp_w[ 16+ 1], rd_smp_w[ 32+ 1], rd_smp_w[ 48+ 1],
        rd_smp_w[ 64+ 1], rd_smp_w[ 80+ 1], rd_smp_w[ 96+ 1], rd_smp_w[112+ 1]} = rd_dq1_in_w;
assign {rd_smp_w[  0+ 2], rd_smp_w[ 16+ 2], rd_smp_w[ 32+ 2], rd_smp_w[ 48+ 2],
        rd_smp_w[ 64+ 2], rd_smp_w[ 80+ 2], rd_smp_w[ 96+ 2], rd_smp_w[112+ 2]} = rd_dq2_in_w;
assign {rd_smp_w[  0+ 3], rd_smp_w[ 16+ 3], rd_smp_w[ 32+ 3], rd_smp_w[ 48+ 3],
        rd_smp_w[ 64+ 3], rd_smp_w[ 80+ 3], rd_smp_w[ 96+ 3], rd_smp_w[112+ 3]} = rd_dq3_in_w;
assign {rd_smp_w[  0+ 4], rd_smp_w[ 16+ 4], rd_smp_w[ 32+ 4], rd_smp_w[ 48+ 4],
        rd_smp_w[ 64+ 4], rd_smp_w[ 80+ 4], rd_smp_w[ 96+ 4], rd_smp_w[112+ 4]} = rd_dq4_in_w;
assign {rd_smp_w[  0+ 5], rd_smp_w[ 16+ 5], rd_smp_w[ 32+ 5], rd_smp_w[ 48+ 5],
        rd_smp_w[ 64+ 5], rd_smp_w[ 80+ 5], rd_smp_w[ 96+ 5], rd_smp_w[112+ 5]} = rd_dq5_in_w;
assign {rd_smp_w[  0+ 6], rd_smp_w[ 16+ 6], rd_smp_w[ 32+ 6], rd_smp_w[ 48+ 6],
        rd_smp_w[ 64+ 6], rd_smp_w[ 80+ 6], rd_smp_w[ 96+ 6], rd_smp_w[112+ 6]} = rd_dq6_in_w;
assign {rd_smp_w[  0+ 7], rd_smp_w[ 16+ 7], rd_smp_w[ 32+ 7], rd_smp_w[ 48+ 7],
        rd_smp_w[ 64+ 7], rd_smp_w[ 80+ 7], rd_smp_w[ 96+ 7], rd_smp_w[112+ 7]} = rd_dq7_in_w;
assign {rd_smp_w[  0+ 8], rd_smp_w[ 16+ 8], rd_smp_w[ 32+ 8], rd_smp_w[ 48+ 8],
        rd_smp_w[ 64+ 8], rd_smp_w[ 80+ 8], rd_smp_w[ 96+ 8], rd_smp_w[112+ 8]} = rd_dq8_in_w;
assign {rd_smp_w[  0+ 9], rd_smp_w[ 16+ 9], rd_smp_w[ 32+ 9], rd_smp_w[ 48+ 9],
        rd_smp_w[ 64+ 9], rd_smp_w[ 80+ 9], rd_smp_w[ 96+ 9], rd_smp_w[112+ 9]} = rd_dq9_in_w;
assign {rd_smp_w[  0+10], rd_smp_w[ 16+10], rd_smp_w[ 32+10], rd_smp_w[ 48+10],
        rd_smp_w[ 64+10], rd_smp_w[ 80+10], rd_smp_w[ 96+10], rd_smp_w[112+10]} = rd_dq10_in_w;
assign {rd_smp_w[  0+11], rd_smp_w[ 16+11], rd_smp_w[ 32+11], rd_smp_w[ 48+11],
        rd_smp_w[ 64+11], rd_smp_w[ 80+11], rd_smp_w[ 96+11], rd_smp_w[112+11]} = rd_dq11_in_w;
assign {rd_smp_w[  0+12], rd_smp_w[ 16+12], rd_smp_w[ 32+12], rd_smp_w[ 48+12],
        rd_smp_w[ 64+12], rd_smp_w[ 80+12], rd_smp_w[ 96+12], rd_smp_w[112+12]} = rd_dq12_in_w;
assign {rd_smp_w[  0+13], rd_smp_w[ 16+13], rd_smp_w[ 32+13], rd_smp_w[ 48+13],
        rd_smp_w[ 64+13], rd_smp_w[ 80+13], rd_smp_w[ 96+13], rd_smp_w[112+13]} = rd_dq13_in_w;
assign {rd_smp_w[  0+14], rd_smp_w[ 16+14], rd_smp_w[ 32+14], rd_smp_w[ 48+14],
        rd_smp_w[ 64+14], rd_smp_w[ 80+14], rd_smp_w[ 96+14], rd_smp_w[112+14]} = rd_dq14_in_w;
assign {rd_smp_w[  0+15], rd_smp_w[ 16+15], rd_smp_w[ 32+15], rd_smp_w[ 48+15],
        rd_smp_w[ 64+15], rd_smp_w[ 80+15], rd_smp_w[ 96+15], rd_smp_w[112+15]} = rd_dq15_in_w;

// Previous cycle's eight samples.
reg [127:0] rd_smp_q;

always @ (posedge clk_i )
if (rst_i)
    rd_smp_q <= 128'b0;
else
    rd_smp_q <= rd_smp_w;

// 16-sample sliding window, oldest at index 0.
wire [255:0] rd_win_w = {rd_smp_w, rd_smp_q};

wire [3:0] rd_sel_base_w = {1'b0, rd_sel_q[2:0]} + (rd_sel_q[3] ? 4'd4 : 4'd0);

wire [15:0] rd_beat0_w = rd_win_w[{rd_sel_base_w,            4'b0} +: 16];
wire [15:0] rd_beat1_w = rd_win_w[{rd_sel_base_w + 4'd4,     4'b0} +: 16];

reg [31:0] rd_capture_q;

always @ (posedge clk_i )
if (rst_i)
    rd_capture_q <= 32'b0;
else
    rd_capture_q <= {rd_beat1_w, rd_beat0_w};

assign dfi_rddata_o       = rd_capture_q;
assign dfi_rddata_dnv_o   = 2'b0;

//-----------------------------------------------------------------
// Read Valid
//-----------------------------------------------------------------
localparam RD_SHIFT_W = 8;
reg [RD_SHIFT_W-1:0] rd_en_q;
reg [RD_SHIFT_W-1:0] rd_en_r;

always @ *
begin
    rd_en_r = {1'b0, rd_en_q[RD_SHIFT_W-1:1]};
    rd_en_r[rd_lat_q] = dfi_rddata_en_i;
end

always @ (posedge clk_i )
if (rst_i)
    rd_en_q <= {(RD_SHIFT_W){1'b0}};
else
    rd_en_q <= rd_en_r;

assign dfi_rddata_valid_o = rd_en_q[0];


endmodule
