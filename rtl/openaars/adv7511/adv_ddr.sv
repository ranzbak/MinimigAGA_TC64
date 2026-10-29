// adv_ddr: the ADV7511's 12-bit DDR video bus (Paul Honig 2020; SystemVerilog 2026-10-27).
// A 24-bit pixel leaves as two halves on clk_148 posedges: {r, g[7:4]} while the pixel clock
// is low, then {g[3:0], b} while it is high (DE covers whole pixels in that order; input
// register 0x16 = 0, ADV7511 Hardware User's Guide p. 35).
// DE is the signal generator's active window (de_in), delayed with the data, and switches
// on the clk_148 negedge, half a period after the posedge pins.  Pins: one pad register per
// pin (pad_clk, pad_de, pad_hsync, pad_vsync, pad_data; IOB + DONT_TOUCH) that drives the
// pin and nothing else, so it sits in the pin's OLOGIC with the same clock-to-pin delay in
// every build; adv7511_video.xdc names them (pad_*_reg) in its forwarded clock and output
// delays.  Each loads its internal twin's next state (*_n), never its own Q: a register that
// holds through its own feedback LUT is kept out of the OLOGIC (stage_padA 2026-10-10: bus
// hold -2.4 ns).  DONT_TOUCH stops the twins being merged.  Internal logic never reads a pad
// (2026-09-25: the pin hsync was also the 60 Hz upsampler's, so pin timing changed the
// picture).
module adv_ddr (
  input  logic        clk_out,  // clk_148, two bus words per pixel
  input  logic        clk_in,   // pixel clock (signal_generator, clk_148-synchronous)
  input  logic        reset,
  input  logic        vsync, hsync,
  input  logic        de_in,    // signal_generator's o_adv_de: its active window
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

// Delay lines, not synchronisers: clk_in, hsync, vsync, de_in and data all come from
// clk_148 registers (signal_generator, the upsamplers; the muxes in front only switch on
// quasi-static selects).  Their depths set the pins' latency, so they stay as they are;
// DE goes through the data's two stages, so the pin DE is the generator's window.
logic [1:0]  clk_pixel_s;
logic [1:0]  vsync_s;
logic [1:0]  hsync_s;
logic        de_d1 = 1'b0, de_d2 = 1'b0;
logic [23:0] data_d1, data_d2;

always_ff @(posedge clk_out) begin
  clk_pixel_s <= {clk_pixel_s[0], clk_in};
  vsync_s     <= {vsync_s[0], vsync};
  hsync_s     <= {hsync_s[0], hsync};
  de_d1       <= de_in;
  de_d2       <= de_d1;
  data_d1     <= data;
  data_d2     <= data_d1;
end

logic [11:0] pad_data_n;

always_ff @(posedge clk_out) begin
  data_out <= pad_data_n;
  if (!reset) begin
    if (clk_pixel_s[1]) begin
      // first half: syncs follow
      vsync_out <= vsync_s[1];
      hsync_out <= hsync_s[1];
    end
    clk_pixel_out <= clk_pixel_s[1];
  end
end

// DE half a clk_148 period later, on the negedge, taken in the pixel clock's high half
always_ff @(negedge clk_out)
  if (clk_pixel_out)
    de_out <= de_d2;

// Pad registers: the twins' next states, written out without feedback from the pads
wire clk_pixel_n = reset ? clk_pixel_out : clk_pixel_s[1];
wire hsync_n     = (!reset && clk_pixel_s[1]) ? hsync_s[1] : hsync_out;
wire vsync_n     = (!reset && clk_pixel_s[1]) ? vsync_s[1] : vsync_out;
wire de_n        = clk_pixel_out ? de_d2 : de_out;
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
