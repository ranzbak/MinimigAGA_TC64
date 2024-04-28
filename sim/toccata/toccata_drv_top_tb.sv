
`timescale 1ns / 1ps

module toccata_drv_top_tb;

localparam real PI = 3.141592654;

// count clock cycles
int clk_cycles = 0;

// Test bench signals
logic clk, rst;
logic hsync;
logic [15:0] data_in, data_out;
logic [15:0] addr;
logic rd, hwr, lwr, sel;
logic toc_int;
logic [15:0] out_left, out_right;

// Instantiate the Unit Under Test (UUT)
toccata uut (
    .clk(clk),
    .rst(rst),
    .hsync(hsync),
    .data_in(data_in),
    .data_out(data_out),
    .addr(addr[15:1]),
    .rd(rd),
    .hwr(hwr),
    .lwr(lwr),
    .sel(sel),
    .toc_int(toc_int),
    .out_left(out_left),
    .out_right(out_right)
);

// Clock generation
initial begin
    clk = 0;
    forever #5 clk = ~clk; // Define clock period
end

// Back stop to stop simulation in case of hanging process
initial begin
    #2000000 $fatal(1, "Simulation took too long, failing");
end

// State and step variables
typedef enum int {
    START,
    // Init sequence
    RESET,
    ACTIVATE,
    // Test buffer(s?)
    READ_3000_1,
    WRITE_3000_80,
    WRITE_3000_48,
    WRITE_3400_06,
    READ_3000_2,
    WRITE_3000_49,
    READ_3000_3,
    WRITE_3400_08,
    WRITE_3000_0b,
    READ_3400_1,
    READ_UNTIL_EMPTY,
    // Done
    FINISH
} state_t;
state_t state;
int step;

// Reset pulse
initial begin
    rst = 1;
    // ... Initialize other signals
    #20 rst = 0;
end

// task for writing
task write_toc(
        input [15:0] wr_addr,
        input [15:0] wr_data,
        input        wr_lwr,
        input        wr_hwr,
        input state_t wr_next_state
    );

    begin
        addr <= wr_addr;
        data_in <= wr_data;
        lwr <= wr_lwr;
        hwr <= wr_hwr;
        if (lwr == wr_lwr && hwr == wr_hwr) begin
            state <= wr_next_state;
        end
    end
endtask

// Read value and go to next state
task read_toc(
        input [15:0] rd_addr,
        input state_t rd_next_state
    );

    begin
        addr <= rd_addr;
        rd <= 1'b1;
        if (rd == 1'b1) begin
            $display("%d - Read value: %h", clk_cycles, data_out );
            state <= rd_next_state;
        end
    end
endtask

// Sequential test sequence
int read_times = 10;

always_ff @(posedge clk) begin
    rd <= 1'b0;
    hwr <= 1'b0;
    lwr <= 1'b0;


    // Measure time in clock cycles
    clk_cycles = clk_cycles + 1;

    // Main test body
    if (rst) begin
        state <= START;
        step <= 0;
        addr <= 16'h0000;
        sel <= 1'b0;
        data_in <= 16'h0000;
        hsync <= 1'b0;
    end else begin
        case(state)

            START: begin
                sel <= 1'b1;
                state <= state.next();
            end
            // Init sequence
            RESET: begin
                write_toc(16'h0000, 16'h0202, 0, 1, state.next());
            end
            ACTIVATE: begin
                write_toc(16'h0000, 16'h0101, 0, 1, state.next());
            end
            // Test buffer(s?)
            READ_3000_1: begin
                read_toc(16'h3000, state.next());
            end
            WRITE_3000_80: begin
                write_toc(16'h3000, 16'h8080, 1, 0, state.next());
            end
            WRITE_3000_48: begin
                write_toc(16'h3000, 16'h4848, 1, 0, state.next());
            end
            WRITE_3400_06: begin
                write_toc(16'h3400, 16'h0606, 1, 0, state.next());
            end
            READ_3000_2: begin
                read_toc(16'h3000, state.next());
            end
            WRITE_3000_49: begin
                write_toc(16'h3000, 16'h4949, 1, 0, state.next());
            end
            READ_3000_3: begin
                read_toc(16'h3000, state.next());
            end
            WRITE_3400_08: begin
                write_toc(16'h3400, 16'h0808, 1, 0, state.next());
            end
            WRITE_3000_0b: begin
                write_toc(16'h3000, 16'h0b0b, 1, 0, state.next());
            end
            READ_3400_1: begin
                read_toc(16'h3400, state.next());
            end
            READ_UNTIL_EMPTY : begin
                if (read_times == 0) begin
                    state <= FINISH;
                end else begin
                    read_times <= read_times - 1;
                    state <= READ_3400_1;
                end
            end

            // Done
            FINISH: begin
                $display("simulation complete");
                $finish(200);
            end
        endcase
    end
end

endmodule