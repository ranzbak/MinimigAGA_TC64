// Registered-I/O OOC wrapper for rtl/openaars/adv7511/osd_text.v, with the
// 720p generator in front of it as pal_to_ddr.sv will wire them (Phase 2):
// osd_text's video, syncs, frame pulse and pixel enable (~o_adv_clk) are
// the generator's outputs.  Every top port is registered
// (the video side on clk, the write side on wclk), so all of osd_text's
// paths are register to register.  u_osd is the layer, u_gen the generator.
module wosd #(parameter LAT = 3) (
  input clk, input reset_i, input hz60_i, input fend_i,
  input [7:0] r_i, input [7:0] g_i, input [7:0] b_i,
  output reg [7:0] r_o, output reg [7:0] g_o, output reg [7:0] b_o,
  output reg hs_o, output reg vs_o, output reg de_o,
  input wclk,
  input txt_we_i, input [1:0] txt_lane_i, input [10:0] txt_adr_i, input [15:0] txt_dat_i,
  input font_we_i, input [11:0] font_adr_i, input [7:0] font_dat_i,
  input pal_we_i, input [5:0] pal_adr_i, input [7:0] pal_dat_i,
  input [39:0] txt_cfg_i, input txt_commit_i);

  reg rst, hz60, fend; reg [7:0] ri, gi, bi;
  always @(posedge clk) begin rst <= reset_i; hz60 <= hz60_i; fend <= fend_i; ri <= r_i; gi <= g_i; bi <= b_i; end
  reg txt_we, font_we, pal_we, txt_commit; reg [1:0] txt_lane; reg [10:0] txt_adr; reg [15:0] txt_dat;
  reg [11:0] font_adr; reg [7:0] font_dat, pal_dat; reg [5:0] pal_adr; reg [39:0] txt_cfg;
  always @(posedge wclk) begin txt_we <= txt_we_i; txt_lane <= txt_lane_i; txt_adr <= txt_adr_i; txt_dat <= txt_dat_i;
    font_we <= font_we_i; font_adr <= font_adr_i; font_dat <= font_dat_i;
    pal_we <= pal_we_i; pal_adr <= pal_adr_i; pal_dat <= pal_dat_i; txt_cfg <= txt_cfg_i; txt_commit <= txt_commit_i; end

  wire [7:0] gr, gg, gb, or_w, og_w, ob_w; wire ghs, gvs, gde, gfr, gck, ohs, ovs, ode;
  signal_generator #(
    .PAL_HZ_ACT_PIX(1280), .PAL_HZ_FRONT_PORCH(440), .PAL_HZ_FRONT_PORCH60(110),
    .PAL_HZ_SYNC_WIDTH(40), .PAL_HZ_BACK_PORCH(220),
    .PAL_VT_ACT_LN(720), .PAL_VT_FRONT_PORCH(5), .PAL_VT_SYNC_WIDTH(5), .PAL_VT_BACK_PORCH(20)
  ) u_gen (
    .clk(clk), .reset(rst), .i_hz60(hz60), .i_frame_end(fend), .i_r(ri), .i_g(gi), .i_b(bi),
    .o_hsync(ghs), .o_vsync(gvs), .o_x(), .o_y(),
    .o_frame(gfr), .o_r(gr), .o_g(gg), .o_b(gb), .o_adv_clk(gck), .o_adv_de(gde));

  osd_text #(.LAT(LAT)) u_osd (
    .clk(clk), .i_pe(~gck), .i_frame(gfr), .i_r(gr), .i_g(gg), .i_b(gb),
    .i_hs(ghs), .i_vs(gvs), .i_de(gde),
    .o_r(or_w), .o_g(og_w), .o_b(ob_w), .o_hs(ohs), .o_vs(ovs), .o_de(ode),
    .wclk(wclk), .txt_we(txt_we), .txt_lane(txt_lane), .txt_adr(txt_adr), .txt_dat(txt_dat),
    .font_we(font_we), .font_adr(font_adr), .font_dat(font_dat),
    .pal_we(pal_we), .pal_adr(pal_adr), .pal_dat(pal_dat), .txt_cfg(txt_cfg), .txt_commit(txt_commit));

  always @(posedge clk) begin r_o <= or_w; g_o <= og_w; b_o <= ob_w; hs_o <= ohs; vs_o <= ovs; de_o <= ode; end
endmodule
