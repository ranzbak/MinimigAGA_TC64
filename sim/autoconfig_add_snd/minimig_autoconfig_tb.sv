`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 12/17/2023 09:45:28 PM
// Design Name:
// Module Name: minimig_autoconfig_tb
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module minimig_autoconfig_tb;

// Declarations
logic clk, clk7_en, reset, lwr, hwr, sel;
logic[15:0] data_in;
logic[8:1] address;
wire [15:0] data_out;
logic[15:0] cycle_count;
wire autoconfig_done;

int lookup[] = '{'h0, 'h2, 'h4, 'h6, 'h8, 'ha, 'h10, 'h12, 'h14, 'h16, 'h26};


// Instance of DUT
minimig_autoconfig dut(
    .clk(clk),
    .clk7_en(clk7_en),
    .reset(reset),
    .lwr(lwr),
    .hwr(hwr),
    .sel(sel),
    .rd(1'b0), // Not used
    .address_in(address),
    .data_in(data_in),
    .data_out(data_out),
    .autoconfig_done(autoconfig_done),
    .slowram_config(2'b00),
    .fastram_config(2'b11),
    .m68020(1'b1),
    .ram_64meg(1'b0)
);

// FSM states
enum {RESET, READ, READ1, WRITE, WRITE_WAIT, CHECK_DONE, FINISH} state;

// Clock generation
always #5 clk = !clk;

always @(posedge clk) begin
    clk7_en <= ~clk7_en;
end

// Initial setup
initial begin
    clk = 0;
    clk7_en = 0;
    reset = 1;
    lwr = 0;
    hwr = 0;
    sel = 0;
    address = 0;
    data_in = 0;
    cycle_count = 0;
    state = RESET;
end

// Main FSM
int pos = 0;
always @(posedge clk) begin
    cycle_count <= cycle_count + 1;

    // Timeout check
    if (cycle_count >= 10000) begin
        $display("Test failed: Timeout");
        $finish;
    end

    case (state)
        RESET: begin
            // Hold reset for 2 cycles
            if (cycle_count >= 2) begin
                reset <= 0;
            end
            // Wait for a few cycles after reseting
            if (cycle_count >= 10) begin
                sel <= 1'b1;
                state <= READ;
            end
        end
        READ: begin
            sel <= 1'b1;
            // Read operation
            if (pos < lookup.size()) begin
                address <= lookup[pos] >> 1;
            end else begin
                state <= WRITE;
            end
            if (clk7_en) begin
                state <= READ1;
            end
        end
        READ1: begin
            if (clk7_en) begin
                if (address == lookup[pos] >> 1 ) begin
                    $display("0x%h - b%b", {address, 1'b0}, data_out[15:12]);
                    pos <= pos + 1;
                    sel <= 1'b0;
                    state <= READ;
                end
            end
        end
        WRITE: begin
            // Write operation
            address <= 'h44 >> 1;
            data_in <= 16'b0101;
            hwr <= 1;
            if (clk7_en && hwr <= 1 && {address, 1'b0} == 'h44) begin
                $display("%h - write - %b", {address, 1'b0}, data_out[15:12]);
                state <= WRITE_WAIT;
            end
        end
        WRITE_WAIT: begin
            // Wait one cycle after write
            address <= 'h48 >> 1;
            // state <= WRITE;
            if (address == 'h48 >> 1 && clk7_en) begin
                hwr <= 0;
                $display("%h - write - %b", {address, 1'b0}, data_out[15:12]);
                $display("Next cycle");
                state <= CHECK_DONE;
            end
        end
        CHECK_DONE: begin
            sel <= 1'b0;
            hwr <= 1'b0;
            address <= 0;
            pos <= 0;
            // Check if autoconfig is done
            if (autoconfig_done) state <= FINISH;
            else state <= READ;
        end
        FINISH: begin
            // Finish test
            $display("Test completed");
            $finish;
        end
    endcase
end

endmodule





