module amiga_keyboard
(
  input        clk,               // clock
  input        clk7_en,
  input        clk7n_en,
  input        reset,             // reset
  output       kbdrst,            // keyboard reset out
  input        kbddat_i,          // ps2 keyboard data
  input        kbdclk_i,          // ps2 keyboard clock
  output       kbddat_o,          // ps2 keyboard data
  output       kbdclk_o,          // ps2 keyboard clock
  input        keyboard_disabled, // disable keystrokes
  input        kbd_mouse_strobe,
  input        kms_level,
  input  [1:0] kbd_mouse_type,
  input  [7:0] kbd_mouse_data,
  output [7:0] osd_ctrl,          // osd control
  output       _lmb,
  output       _rmb,
  output [5:0] _joy2,
  output       aflock,            // auto fire lock
  output       freeze,            // Action Replay freeze key
  input        _f_led,            // audio filter LED
  input        disk_led,          // floppy disk activity LED
  output [5:0] mou_emu,
  output [5:0] joy_emu,
  input        hrtmon_en,

  output reg   key_strobe,        // parallel data out
  output reg [7:0] key_data,
  input        keyack,

  output reg   kbclk,             // serial data out
  output reg   kbdata
);

wire        keystrobe;
wire  [7:0] keydat;
reg   [7:0] osd_ctrl_reg;
assign osd_ctrl = osd_ctrl_reg;

// serial transmitter
always @(posedge clk) begin
    reg [10:0] txcnt;
    reg  [7:0] txsr;

    if (reset) begin
        kbclk <= 1;
        kbdata <= 1;
    end else if (clk7_en) begin
        // initialize the transmitter when key_strobe detected
        if (key_strobe) begin
            txcnt <= { 3'h7, 8'hff };
            txsr <= key_data;
        end

        // first put the data bit on kbdata
        if (txcnt[7:0] == 8'hff) begin
            kbdata <= txsr[7];
            txsr <= { txsr[6:0], 1'b0 };
        end
        // then a clock pulse follows
        if (txcnt[7:0] == 8'hc0) kbclk <= 0;
        if (txcnt[7:0] == 8'h40) kbclk <= 1;

        if (|txcnt) txcnt <= txcnt - 1'd1;
    end
end

`ifdef MINIMIG_PS2_KEYBOARD

wire freeze_out;
wire keystrobe_ps2;
wire [7:0] osd_ctrl_ps2;
wire osd_ctrl_strobe_ps2;

ciaa_ps2keyboard  kbd1
(
  .clk(clk),
  .clk7_en(clk7_en),
  .reset(reset),
  .ps2kdat_i(kbddat_i),
  .ps2kclk_i(kbdclk_i),
  .ps2kdat_o(kbddat_o),
  .ps2kclk_o(kbdclk_o),
  .leda(~_f_led),     // keyboard joystick LED - num lock
  .ledb(disk_led),    // disk activity LED - scroll lock
  .aflock(aflock),
  .kbdrst(kbdrst),
  .keydat(keydat[7:0]),
  .keystrobe(keystrobe_ps2),
  .keyack(keyack),
  .keyboard_disabled(keyboard_disabled),
  .osd_ctrl(osd_ctrl_ps2),
  .osd_strobe(osd_ctrl_strobe_ps2),
  ._lmb(),                  // keyboard mouse emulation removed (Paul,
  ._rmb(),                  // 2026-09-24): "not very useful, I have a mouse"
  ._joy2(_joy2),
  .freeze(freeze_out),
  .mou_emu(mou_emu),        // no longer used: userio ties it off
  .joy_emu(joy_emu)
);

assign _lmb = 1'b1;
assign _rmb = 1'b1;
assign freeze = hrtmon_en && freeze_out;

// Which key events reach the Amiga while the OSD has the keyboard: see
// kbd_release_gate below.  A key the Amiga saw go down always gets its
// release, so opening the OSD while a key is held cannot leave it stuck.
wire pass_ps2;
wire pass_kms;

kbd_release_gate gate_ps2
(
  .clk(clk), .clk7_en(clk7_en), .reset(reset),
  .disabled(keyboard_disabled),
  .strobe_a(keystrobe_ps2), .code_a(keydat),
  .strobe_b(kbd_mouse_strobe & ~keystrobe_ps2), .code_b(kbd_mouse_data),
  .pass_a(pass_ps2), .pass_b(pass_kms)
);

`ifdef MINIMIG_EXTRA_KEYBOARD

reg keystrobe_reg;
assign keystrobe = keystrobe_reg | keystrobe_ps2;

// !!! Amiga receives keycode ONE STEP ROTATED TO THE RIGHT AND INVERTED !!!
always @(posedge clk) begin

    if(osd_ctrl_strobe_ps2)
        osd_ctrl_reg<=osd_ctrl_ps2;
    else if (kbd_mouse_strobe)
        osd_ctrl_reg<=kbd_mouse_data;

    if (reset) begin
        key_data <= 8'h00;
        key_strobe <= 0;
    end else if (clk7_en) begin
        keystrobe_reg<=1'b0;
        if (pass_ps2) begin
            key_data <= ~{keydat[6:0],keydat[7]};
            key_strobe <= 1;
        end else if (pass_kms) begin
            keystrobe_reg<=1'b1;
            key_data <= ~{kbd_mouse_data[6:0],kbd_mouse_data[7]};
            key_strobe <= 1;
        end else begin
            key_strobe <= 0;
        end
    end
end

`else

assign keystrobe=keystrobe_ps2;

// sdr register
// !!! Amiga receives keycode ONE STEP ROTATED TO THE RIGHT AND INVERTED !!!
always @(posedge clk) begin
    osd_ctrl_reg<=osd_ctrl_ps2;
    if (reset) begin
        key_data <= 8'h00;
        key_strobe <= 0;
    end else if (clk7_en) begin
        if (pass_ps2) begin
            key_strobe <= 1;
            key_data <= ~{keydat[6:0],keydat[7]};
        end else begin
            key_strobe <= 0;
        end
    end
end
`endif
  
`else
//MiST kbd

assign kbdrst = 1'b0;
assign _lmb = 1'b1;
assign _rmb = 1'b1;
assign _joy2 = 6'b11_1111;
assign joy_emu = 6'b11_1111;
assign mou_emu = 6'b11_1111;
reg freeze_reg=0;
assign freeze = freeze_reg;
assign aflock = 1'b0;

reg keystrobe_reg;
assign keystrobe = keystrobe_reg && ((kbd_mouse_type == 2) || (kbd_mouse_type == 3));


reg kms_levelD;
always @(posedge clk) begin
    if (clk7n_en) begin
        keystrobe_reg <= 0;
        kms_levelD <= kms_level;
        if (kms_level ^ kms_levelD) keystrobe_reg <= 1;
    end
end

// !!! Amiga receives keycode ONE STEP ROTATED TO THE RIGHT AND INVERTED !!!
always @(posedge clk) begin
    if (reset) begin
        key_strobe <= 0;
        key_data <= 0;
        osd_ctrl_reg <= 0;
    end else if (clk7_en) begin
        key_strobe <= 0;
        if (keystrobe && (kbd_mouse_type == 2) && ~keyboard_disabled) begin
            key_strobe <= 1;
            key_data <= ~{kbd_mouse_data[6:0],kbd_mouse_data[7]};
            if (hrtmon_en && (kbd_mouse_data == 8'h5f))
                freeze_reg <= 1;
            else
                freeze_reg <= 0;
        end
        if(keystrobe && ((kbd_mouse_type == 2) || (kbd_mouse_type == 3)))
            osd_ctrl_reg <= kbd_mouse_data;
    end
end

`endif

endmodule


// Key events and the OSD (2026-09-24).  With the OSD open the Amiga must see
// no keystrokes -- but it must see the RELEASE of a key it already saw go
// down.  Blocking both directions (the old `strobe & ~keyboard_disabled`)
// lost the release of any key held when the OSD opened, so after closing it
// the Amiga kept that key pressed: a stuck qualifier (Amiga, Alt, Shift) made
// typing impossible, and Amiga+Alt is AmigaOS's keyboard mouse button, so it
// could also look like a held right mouse button.  (The PS/2 mouse buttons are
// levels, not events, and are not gated here.)
//
// `down` holds, per Amiga key code, whether the Amiga has seen that key go
// down and not yet come up.  Rules, per event (code bit 7 = release):
//   OSD closed: everything passes, and `down` follows.
//   OSD open:   a press is blocked; a release passes only if `down` says the
//               Amiga has the key down -- so releases of keys pressed only for
//               the OSD (arrows, Enter, Esc) stay blocked too.
// Two sources share one table (the PS/2 keyboard, and keys the firmware
// injects); the caller never presents both in the same clock.
module kbd_release_gate
(
  input        clk,
  input        clk7_en,
  input        reset,
  input        disabled,        // the OSD has the keyboard
  input        strobe_a,
  input  [7:0] code_a,          // Amiga key code, bit 7 = release
  input        strobe_b,
  input  [7:0] code_b,
  output       pass_a,
  output       pass_b
);

reg [127:0] down = 128'd0;

function allowed(input [7:0] code, input dis, input [127:0] dn);
  allowed = !dis || (code[7] && dn[code[6:0]]);
endfunction

assign pass_a = strobe_a && allowed(code_a, disabled, down);
assign pass_b = strobe_b && allowed(code_b, disabled, down);

always @(posedge clk) begin
  if (reset)
    down <= 128'd0;
  else if (clk7_en) begin
    if (pass_a)
      down[code_a[6:0]] <= !code_a[7];
    else if (pass_b)
      down[code_b[6:0]] <= !code_b[7];
  end
end

endmodule
