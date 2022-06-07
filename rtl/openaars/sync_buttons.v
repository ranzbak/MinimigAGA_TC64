// sync_buttons.v
// 2021, paul@printf.nl

`default_nettype none
`timescale 1ns/10ps

module sync_buttons (
    input wire clk,
    input wire sys_reset_n_in,
    input wire button_user_in,
    input wire button_osd_in,
    output wire user_button,
    output wire osd_button,
    output wire reset_button_n
);
    (* ASYNC_REG = "true" *) reg [1:0] sys_reset_s;
    (* ASYNC_REG = "true" *) reg [1:0] button_user_s;
    (* ASYNC_REG = "true" *) reg [1:0] button_osd_s;

    // Setup next step
    wire [1:0] sys_reset_next = {sys_reset_s[0], sys_reset_n_in};
    wire [1:0] button_user_next = {button_user_s[0], button_user_in};
    wire [1:0] button_osd_next = {button_osd_s[0], button_osd_in};

    // Apply next sync step
    always @(posedge clk) begin
        sys_reset_s <= sys_reset_next;
        button_user_s <= button_user_next;
        button_osd_s <= button_osd_next;
    end

    // assign output signals
    assign user_button = button_user_s[1];
    assign osd_button = button_osd_s[1];
    assign reset_button_n = sys_reset_s[1];
endmodule