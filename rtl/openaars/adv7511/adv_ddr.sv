// adv_ddr: the ADV7511's 12-bit DDR video bus (Paul Honig 2020; SystemVerilog 2026-10-27).
// A 24-bit pixel leaves as two halves on clk_148 posedges: {g[3:0], b} while the pixel clock
// is high, then {r, g[7:4]} (input register 0x16 = 0, ADV7511 Hardware User's Guide p. 35).
// DE is regenerated from hsync/vsync and switches on the clk_148 negedge, half a period
// after the posedge pins.  Pins: one pad register per pin (pad_clk, pad_de, pad_hsync,
// pad_vsync, pad_data; IOB + DONT_TOUCH) that drives the pin and nothing else, so it sits in
// the pin's OLOGIC with the same clock-to-pin delay in every build; adv7511_video.xdc names
// them (pad_*_reg) in its forwarded clock and output delays.  Each loads its internal twin's
// next state (*_n), never its own Q: a register that holds through its own feedback LUT is
// kept out of the OLOGIC (stage_padA 2026-10-10: bus hold -2.4 ns).  DONT_TOUCH stops the
// twins being merged.  Internal logic never reads a pad (2026-09-25: the pin hsync was
// also the 60 Hz upsampler's, so pin timing changed the picture).
module adv_ddr #(
  // X axis
  parameter PX_TO_DE = 100,
  parameter PX_ACT_DE = 1280,
  parameter PX_TOTAL = 1980,
  // Y axis
  parameter PY_TO_DE = 5,
  parameter ACT_720P = 720,
  parameter V_LINES_TOTAL = 806
)(
  input  logic        clk_out,  // clk_148, two bus words per pixel
  input  logic        clk_in,   // pixel clock (signal_generator, clk_148-synchronous)
  input  logic        reset,
  input  logic        vsync, hsync,
  input  logic [23:0] data,     // pixel {r, g, b}

  // Internal twins (the 60 Hz upsampler reads hsync_out; data_out is the bus word)
  (* DONT_TOUCH = "TRUE" *) output logic clk_pixel_out,
  (* DONT_TOUCH = "TRUE" *) output logic de_out = 1'b0,
  (* DONT_TOUCH = "TRUE" *) output logic vsync_out,
  (* DONT_TOUCH = "TRUE" *) output logic hsync_out,
  output logic [11:0] data_out,

  // The pins: pad registers (see the header)
  (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) output logic pad_clk = 1'b0,
  (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) output logic pad_de = 1'b0,
  (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) output logic pad_vsync = 1'b0,
  (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) output logic pad_hsync = 1'b0,
  (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) output logic [11:0] pad_data = 12'd0
);

// Delay lines, not synchronisers: clk_in, hsync, vsync and data all come from clk_148
// registers (signal_generator, the upsamplers; the muxes in front only switch on
// quasi-static selects).  Their depths set the pins' latency, so they stay as they are.
logic [1:0]  clk_pixel_s;
logic [2:0]  vsync_s;
logic [2:0]  hsync_s;
logic [23:0] data_d1, data_d2;

always_ff @(posedge clk_out) begin
  clk_pixel_s <= {clk_pixel_s[0], clk_in};
  vsync_s     <= {vsync_s[1:0], vsync};
  hsync_s     <= {hsync_s[1:0], hsync};
  data_d1     <= data;
  data_d2     <= data_d1;
end

// Line counter: DE only in the 720 active lines
localparam int VW = $clog2(V_LINES_TOTAL) + 1;
localparam logic [VW-1:0] V_DE_FIRST = VW'(PY_TO_DE);             // DE from the line after this
localparam logic [VW-1:0] V_DE_LAST  = VW'(PY_TO_DE + ACT_720P);  // to this one
logic [VW-1:0] v_counter = '0;
logic          v_active = 1'b0;

always_ff @(posedge clk_out) begin
  if (reset) begin
    v_counter <= '0;
    v_active  <= 1'b0;
  end else begin
    if (vsync_s[2:1] == 2'b10)
      v_counter <= '0;
    else if (hsync_s[2:1] == 2'b01)
      v_counter <= v_counter + 1;
    v_active <= (v_counter > V_DE_FIRST) && (v_counter <= V_DE_LAST);
  end
end

// Pixel counter and the DE set/clear events (toggles, taken over on the negedge)
localparam int PXW = $clog2(PX_TOTAL) + 1;
localparam logic [PXW-1:0] PX_DE_SET = PXW'(PX_TO_DE);
localparam logic [PXW-1:0] PX_DE_CLR = PXW'(PX_ACT_DE + PX_TO_DE);
logic [PXW-1:0] px_count = '0;
logic set_de = 1'b0;
logic reset_de = 1'b0;
logic [11:0] pad_data_n;

always_ff @(posedge clk_out) begin
  reset_de <= 1'b0;
  data_out <= pad_data_n;
  if (reset) begin
    px_count <= '0;
  end else begin
    if (clk_pixel_s[1]) begin
      // first half: syncs follow, DE events
      vsync_out <= vsync_s[1];
      hsync_out <= hsync_s[1];
      if ((px_count == PX_DE_SET) && v_active)
        set_de <= ~set_de;
      if (px_count == PX_DE_CLR)
        reset_de <= ~reset_de;
    end else begin
      // second half: count pixels from hsync
      px_count <= hsync_s[1] ? '0 : px_count + 1;
    end
    clk_pixel_out <= clk_pixel_s[1];
  end
end

// DE half a clk_148 period later, on the negedge
logic [1:0] r_neg_set_de = '0;
logic [1:0] r_neg_reset_de = '0;

always_ff @(negedge clk_out) begin
  if (clk_pixel_out) begin
    r_neg_set_de   <= {r_neg_set_de[0], set_de};
    r_neg_reset_de <= {r_neg_reset_de[0], reset_de};
    if (r_neg_reset_de[0] != r_neg_reset_de[1])
      de_out <= 1'b0;
    else if (r_neg_set_de[0] != r_neg_set_de[1])
      de_out <= 1'b1;
  end
end

// Pad registers: the twins' next states, written out without feedback from the pads
wire clk_pixel_n = reset ? clk_pixel_out : clk_pixel_s[1];
wire hsync_n     = (!reset && clk_pixel_s[1]) ? hsync_s[1] : hsync_out;
wire vsync_n     = (!reset && clk_pixel_s[1]) ? vsync_s[1] : vsync_out;
wire de_set_ev   = clk_pixel_out && (r_neg_set_de[0] != r_neg_set_de[1]);
wire de_rst_ev   = clk_pixel_out && (r_neg_reset_de[0] != r_neg_reset_de[1]);
wire de_n        = de_rst_ev ? 1'b0 : de_set_ev ? 1'b1 : de_out;
assign pad_data_n = (reset || !de_out) ? 12'd0
                  : clk_pixel_s[1]     ? data_d2[11:0]
                  :                      data_d2[23:12];

always_ff @(posedge clk_out) begin
  pad_clk   <= clk_pixel_n;
  pad_hsync <= hsync_n;
  pad_vsync <= vsync_n;
  pad_data  <= pad_data_n;
end

always_ff @(negedge clk_out)
  pad_de <= de_n;

endmodule
