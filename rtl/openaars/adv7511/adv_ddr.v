// ADV video out DDR
// Paul Honig 2020
//

// When register 0x16 = 0 first byte in middle of positive
// https://www.analog.com/media/en/technical-documentation/user-guides/ADV7511_Hardware_Users_Guide.pdf
// Page 35
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
  // INPUT
  input clk_out, // DDR clock at 4xpixel clock
  input clk_in, // Pixel clock
  input reset,

  // input de_in,                        // Used to generate DE
  input vsync, hsync, //
  input [23:0 ] data, // Pixel data in 24-bpp

  // OUTPUT (internal: the 60 Hz upsampler reads hsync_out, this module de_out
  // and clk_pixel_out)
  output reg clk_pixel_out, // Output pixel clock after synchronization to clk_out
  output reg de_out, // Data enable signal
  output reg vsync_out, hsync_out,
  output reg [11:0] data_out, // DDR data stream out

  // PADS (2026-10-10): one register per ADV7511 pin, a copy of the internal
  // register above with the same D and the same clock edge, that drives the
  // pin and nothing else -- so it sits in the pin's OLOGIC (IOB) and its
  // clock-to-pin delay is the same in every build.  Until now Vivado made
  // these copies itself (*_reg_rep) to honour IOB=TRUE on registers that also
  // feed internal logic; the pins' timing is unchanged (measured on
  // stage_combo5_x0: dv_clk and dv_d within 0.04 ns at the pins).
  // DONT_TOUCH keeps them from being merged back into the internal ones.
  // Internal logic never reads them: on 2026-09-25 the pin hsync was also
  // the 60 Hz upsampler's hsync, so changing pin timing changed the picture.
  (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) output reg pad_clk = 1'b0,
  (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) output reg pad_de = 1'b0,
  (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) output reg pad_vsync = 1'b0,
  (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) output reg pad_hsync = 1'b0,
  (* IOB = "TRUE", DONT_TOUCH = "TRUE" *) output reg [11:0] pad_data = 12'd0
);

// The amount of pixels before the Data enabled is triggered
//
//    { XVIDC_VM_1280x720_50_P, "1280x720@50Hz", XVIDC_FR_50HZ,
//        {1280, 440, 40, 220, 1980, 1,
//        720, 5, 5, 20, 750, 0, 0, 0, 0, 1} },

// reg clk_pixel_, clk_pixel__;
(* ASYNC_REG = "TRUE" *) reg [1:0] clk_pixel_s;
(* ASYNC_REG = "TRUE" *) reg [2:0] vsync_s;
(* ASYNC_REG = "TRUE" *) reg [2:0] hsync_s;
(* ASYNC_REG = "TRUE" *) reg [23:0] data_s [1:0];

// Set and reset Data enable
reg set_de = 1'b0;
reg reset_de = 1'b0;


// Synchronize signal to clk_out
wire [2:0] vsync_s_next = {vsync_s[1], vsync_s[0], vsync};
wire [2:0] hsync_s_next = {hsync_s[1], hsync_s[0], hsync};
wire [1:0] clk_pixel_s_next = {clk_pixel_s[0], clk_in};
wire [23:0] data_s_next [1:0];

initial begin
  de_out <= 1'b0;
end

always @(posedge clk_out)
begin
  clk_pixel_s <= clk_pixel_s_next;
  // de_in_s <= {de_in_s[0], de_in};
  vsync_s <= vsync_s_next;
  hsync_s <= hsync_s_next;
  // Sync 2d array
  data_s[0] <= data;
  data_s[1] <= data_s[0];
end

// line counter
reg [$clog2(V_LINES_TOTAL):0] v_counter = 0;
reg                           v_active = 1'b0; // Active reagion 720p

// Make sure the DE lines are only active when data is displayed
always @(posedge clk_out)
begin
  v_active <= 1'b0;

  if (hsync_s[2:1] == 2'b01)
  begin
    v_counter <= v_counter + 1;
  end

  // On vsync reset line counter
  if (vsync_s[2:1] == 2'b10)
  begin
    v_counter <= 0;
  end

  // Only have the video DE active in the active reagon
  if ((v_counter > PY_TO_DE) && (v_counter <= (PY_TO_DE + ACT_720P)))
  begin
    v_active <= 1'b1;
  end

  if (reset)
  begin
    v_counter <= 0;
    v_active <= 0;
  end
end


// Generate DDR signals
// reg phase_count = 0;
reg [$clog2(PX_TOTAL):0] px_count = 0;
always @(posedge clk_out)
begin
  reset_de <= 1'b0;
  data_out <= 0;
  pad_data <= 0;
  if (reset)
  begin
    // phase_count <= 0;
    px_count <= 0;
  end
  else
  begin
    // Next phase
    // phase_count <= ~phase_count;

    // Handle positive pixel clock edge
    // if (!clk_pixel_s[2] && clk_pixel_s[1]) begin
    //    phase_count <= 1'b0;
    // end

    // Do actions according to phases
    if (clk_pixel_s[1] == 1'b1)
    begin // Phase 0
      // Output the lower (1st) part
      if (de_out) begin
        data_out <= data_s[1][11:0];
        pad_data <= data_s[1][11:0];
      end
      // Output vsync and hsync as well
      vsync_out <= vsync_s[1];
      hsync_out <= hsync_s[1];
      pad_vsync <= vsync_s[1];
      pad_hsync <= hsync_s[1];
      // Generate data enable
      if ((px_count == PX_TO_DE) && v_active)
        set_de <= ~set_de;
      if (px_count == (PX_ACT_DE + PX_TO_DE))
        reset_de <= ~reset_de;
    end
    else
    begin
      // Output the high (2nd) part
      if (de_out)
      begin
        data_out <= data_s[1][23:12];
        pad_data <= data_s[1][23:12];
      end
      // Handle pixel counter to Data enable
      px_count <= px_count + 1;
      // Reset horizontal counter
      if (hsync_s[1])
        px_count <= 0;
    end

    // Output synchronized pixel clock
    clk_pixel_out <= clk_pixel_s[1];
    pad_clk       <= clk_pixel_s[1];
  end
end


// 180 degrees later switch the data enable
reg [1:0] r_neg_set_de = 0;
reg [1:0] r_neg_reset_de = 0;
always @(negedge clk_out)
begin

  if (clk_pixel_out == 1'b1)
  begin
    r_neg_set_de <= {r_neg_set_de[0], set_de};
    r_neg_reset_de <= {r_neg_reset_de[0], reset_de};

    if (r_neg_set_de[0] != r_neg_set_de[1])
    begin
      de_out <= 1'b1;
      pad_de <= 1'b1;
    end

    if (r_neg_reset_de[0] != r_neg_reset_de[1])
    begin
      de_out <= 1'b0;
      pad_de <= 1'b0;
    end
  end
end

endmodule
