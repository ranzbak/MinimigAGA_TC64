// kbd_release_gate (rtl/minimig/amiga_keyboard.v): with the OSD open a key the
// Amiga saw go down must still get its release; presses, and releases of keys
// pressed only for the OSD, stay blocked.  `define GATE_MUTANT puts back the
// old rule (OSD open blocks everything), which this bench must reject.
`timescale 1ns/1ps
module kbd_gate_tb;
  reg clk = 0, clk7_en = 1, reset = 1, dis = 0;
  reg sa = 0, sb = 0; reg [7:0] ca = 0, cb = 0;
  wire pa, pb;
  kbd_release_gate dut(.clk(clk), .clk7_en(clk7_en), .reset(reset), .disabled(dis),
                       .strobe_a(sa), .code_a(ca), .strobe_b(sb), .code_b(cb),
                       .pass_a(pa), .pass_b(pb));
  always #5 clk = ~clk;
  integer errs = 0;
  // one event on source a; check whether it passed
  task ev_a(input [7:0] code, input want, input [8*40:1] what);
    begin
      @(negedge clk); ca = code; sa = 1;
      #1 if (pa !== want) begin errs = errs + 1; $display("FAIL a %0s: code %h pass=%b want %b", what, code, pa, want); end
      @(negedge clk); sa = 0;
    end
  endtask
  task ev_b(input [7:0] code, input want, input [8*40:1] what);
    begin
      @(negedge clk); cb = code; sb = 1;
      #1 if (pb !== want) begin errs = errs + 1; $display("FAIL b %0s: code %h pass=%b want %b", what, code, pb, want); end
      @(negedge clk); sb = 0;
    end
  endtask
  localparam LAMIGA = 8'h66, LALT = 8'h64, KEY_A = 8'h20, CURSOR_UP = 8'h4c, RETURN = 8'h44;
  initial begin
    repeat (3) @(negedge clk); reset = 0;
    // OSD closed: everything passes
    ev_a(KEY_A, 1, "closed press");
    ev_a(KEY_A | 8'h80, 1, "closed release");
    // held qualifiers, then the OSD opens
    ev_a(LAMIGA, 1, "LAmiga down before OSD");
    ev_a(LALT,   1, "LAlt down before OSD");
    @(negedge clk); dis = 1;
    ev_a(CURSOR_UP, 0, "OSD press blocked");
    ev_a(CURSOR_UP | 8'h80, 0, "OSD-only release blocked");
    ev_a(RETURN, 0, "OSD Enter press blocked");
    ev_a(LAMIGA | 8'h80, 1, "LAmiga release while OSD open");
    ev_b(LALT | 8'h80, 1, "LAlt release (source b) while OSD open");
    ev_a(LAMIGA | 8'h80, 0, "second LAmiga release blocked");
    @(negedge clk); dis = 0;
    // after the OSD: the Amiga has nothing held; a stray RETURN release passes as before
    ev_a(RETURN | 8'h80, 1, "closed release passes");
    ev_b(KEY_A, 1, "source b press closed");
    @(negedge clk); dis = 1;
    ev_b(KEY_A | 8'h80, 1, "source b release while open");
    // reset clears the table
    ev_a(LAMIGA, 0, "press while open");
    @(negedge clk); dis = 0; ev_a(LAMIGA, 1, "press closed");
    @(negedge clk); reset = 1; @(negedge clk); reset = 0; dis = 1;
    ev_a(LAMIGA | 8'h80, 0, "release after reset blocked");
    if (errs == 0) $display("KBD_GATE PASS"); else $display("KBD_GATE FAIL (%0d)", errs);
    $finish;
  end
endmodule
