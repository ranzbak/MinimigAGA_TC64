/*

 Copyright (c) 2021 Paul Honig

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.

 */

// Language: Verilog 2001

`timescale 1ns / 10ps

/*
 * I2C master
 */
module i2c_master_mmio (
    input  wire          clk,
    input  wire          rst,

    input        [15:0]  d,
    output logic [15:0]  q,

    output wire          interrupt,

    /*
     * MMIO interface
     */
    input  logic [31:2]  addr,
    input  logic         i2c_select,
    input  logic         interrupt_select,
    input  logic         req,
    input  logic         wr,

    /*
     * I2C interface
     */
    input  logic         scl_i,
    output logic         scl_o,
    output logic         scl_t,
    input  logic         sda_i,
    output logic         sda_o,
    output logic         sda_t
);
//////////////////////////////////////////////////////////////////////
//
// Read
// ----
//
// Addr | Function
// ===============================================
// 0000 | Last read byte
// 0100 | Status register
// 1000 | I2C divider
// 1100 | read device ID
//
// Write
// -----
// Addr, 0000 - 1100 all connect to the same functionality
//
// bit  | function
// ===============================================
// 7:0  | Payload data
// 11:8 | command
// 12   | data_in_last (use with CMD_WRITE_MULTI)
//
// 0xNum |  command
// ===============================================
// 4'h0  |  CMD_NOP          | No operation
// 4'h1  |  CMD_READ         | Read a byte
// 4'h2  |  CMD_WRITE        | write one byte
// 4'h3  |  CMD_WRITE_MULTI  | Write multiple bytes
// 4'h4  |  CMD_START        | Send start command
// 4'h5  |  CMD_STOP         | Send stop command
// 4'hb  |  CMD_SET_ADDR     | Set the slave address
// 4'hc  |  CMD_SET_SCL_L    | Set lower byte of I2C clock devider
// 4'hd  |  CMD_SET_SCL_H    | Set high byte of I2C clock devider
// 4'he  |  CMD_STOP_ON_IDLE | Send automatic stop on bus error
// 4'hf  |  CMD_RESET        | Reset state machine
//
//////////////////////////////////////////////////////////////////////


logic [6:0]  cmd_address;
logic        cmd_start_r = 1'b0;
logic        cmd_read_r = 1'b0;
logic        cmd_write_r = 1'b0;
logic        cmd_write_multiple_r = 0;
logic        cmd_stop_r = 0;
logic        cmd_valid_r = 0;
logic        cmd_ready_r;

//(* MARK_DEBUG="true", KEEP="true" *)
logic  [7:0]data_in;
//(* MARK_DEBUG="true", KEEP="true" *)
logic        data_in_valid;
logic        data_in_ready;
logic        data_in_last;

logic [7:0]data_out;
// logic       data_out_valid;
logic        data_out_ready;
// logic       data_out_last;

//(* MARK_DEBUG="true", KEEP="true" *)
logic [15:0] i2c_prescale = 0;
logic        stop_on_idle = 0;

logic        r_interrupt = 0;
//reg [15:0] r_q = 0;

// data buffers
logic [15:0] buf_write [0:7];
logic [2:0]  prod_write = 0;
logic [2:0]  prod_write_next;
logic [2:0]  con_write = 0;
logic [2:0]  con_write_next;
logic        buf_write_empty = 0;
// reg        buf_write_empty_ = 0;
logic        buf_write_full = 0;
logic [15:0] buf_read [0:7];
logic [2:0]  prod_read = 0;
logic [2:0]  prod_read_next;
logic [2:0]  con_read = 0;
logic [2:0]  con_read_next;
logic        buf_read_empty = 0;
logic        buf_read_empty_ = 0;
logic        buf_read_full = 0;


// Enumerations
typedef logic [3:0] i2c_enum_t;
typedef enum {
    STATE_IDLE,
    STATE_READ,
    STATE_WRITE,
    STATE_WRITE_MULTI,
    STATE_START,
    STATE_STOP,
    STATE_SET_ADDRESS,
    STATE_SET_SOI,
    STATE_SET_SCL_L,
    STATE_SET_SCL_H,
    STATE_RESET
} state_t;
state_t state_reg = STATE_IDLE;

// This enum needs to be defined, because the commands need to be predictable
typedef enum i2c_enum_t {
    CMD_NOP           = 4'h0,
    CMD_READ          = 4'h1,
    CMD_WRITE         = 4'h2,
    CMD_WRITE_MULTI   = 4'h3,
    CMD_START         = 4'h4,
    CMD_STOP          = 4'h5,
// READ VALUE
    CMD_READ_NEXT     = 4'ha,
// config
    CMD_SET_ADDR      = 4'hb,
    CMD_SET_SCL_L     = 4'hc,
    CMD_SET_SCL_H     = 4'hd,
    CMD_STOP_ON_IDLE  = 4'he,
    CMD_RESET         = 4'hf
} cmd_t;
cmd_t cmd_flag;

logic busy;
// logic bus_control;
logic bus_active;
logic missed_ack;

// Command state machine
logic [15:0] cmd_in = 0;
logic [15:0] cmd_result_r = 0;
logic [15:0] status_reg = 0;

// Flag registers
// reg flag_write_ready = 1'b0;
// reg flag_read_ready = 1'b0;
logic r_write_ready = 1'b0;
logic r_read_ready = 1'b0;
logic r_cmd_done = 1'b0;

// busy registers
logic busy_ = 0;
logic busy_strobe = 0;

// Register to output wire
assign interrupt = r_interrupt;
//assign q = q;

initial begin
    $monitor("r_cmd_done=%d\n",r_cmd_done);
end

logic req_;
logic req_strobe;

// Handle buffer flags
always_ff @(posedge clk) begin
    // buffer assignments
    buf_write_empty <= 0;
    // buf_write_empty_ <= buf_write_empty;
    buf_write_full <= 0;
    buf_read_empty <= 0;
    buf_read_empty_ <= buf_read_empty;

    // Buffer empty
    if (con_write == prod_write)
        buf_write_empty <= 1;
    if (con_read == prod_read)
        buf_read_empty <= 1;

    // Buffer full?
    if ((prod_write_next) == con_write)
        buf_write_full <= 1;
    if ((prod_read_next) == prod_read)
        buf_read_full <= 1;
end

logic _r_cmd_done;
logic _r_read_ready;
logic _r_write_ready;
logic _i2c_select;
logic _interrupt_select;
logic _req;
logic _wr;
logic _busy;

always_comb begin
    // The status registere as shown on the mmio
    status_reg = {
        6'b0,
        missed_ack,
        stop_on_idle,
        {1{1'b0}},
        bus_active,         // 0x40
        missed_ack,         // 0x20
        busy,               // 0x10
        buf_read_full,      // 0x08
        buf_read_empty,     // 0x04
        buf_write_full,     // 0x02
        buf_write_empty     // 0x01
    };
end

// handle reads combinational
// TODO: Results in combinational logic without a clock
// always @(r_cmd_done, r_read_ready, r_write_ready, i2c_select, interrupt_select, req, wr, busy) begin
always_ff @(posedge clk) begin
    // Save state for next cycle, so we can detect changes
    _r_cmd_done <= r_cmd_done;
    _r_read_ready <= r_read_ready;
    _r_write_ready <= r_write_ready;
    _i2c_select <= i2c_select;
    _interrupt_select <= interrupt_select;
    _req <= req;
    _wr <= wr;
    _busy <= busy;

    if (rst) begin
        q <= 16'h0000;
        r_interrupt <= 1'b0;
        // flag_read_ready <= 1'b0;
        // flag_write_ready <= 1'b0;
    end else begin

        if (
                _r_cmd_done != r_cmd_done
                || _r_read_ready != r_read_ready
                || _r_write_ready != r_write_ready
                || _i2c_select != i2c_select
                || _interrupt_select != interrupt_select
                || _req != req
                || _wr != wr
                || _busy != busy
            ) begin


            /* Handle interrupt flag
             * Go high when :
             * read buffer has content (byte received)
             */
            if (buf_read_empty_ == 1'b1 & buf_read_empty == 1'b0) begin
                r_interrupt <= 1'b1;
            end
            if (buf_write_empty == 1'b1 & busy_strobe == 1'b1) begin
                r_interrupt <= 1'b1;
            end

            // Latch status flags
            // if (r_read_ready == 1'b1) begin
            //     flag_read_ready <= 1'b1;
            // end

            // if (r_write_ready == 1'b1) begin
            //     flag_write_ready <= 1'b1;
            // end

            // Clear interrupt when the interrupt register is read
            if (interrupt_select == 1'b1 & wr == 1'b0) begin
                r_interrupt <= 1'b0;
                // flag_read_ready <= 1'b0;
                // flag_write_ready <= 1'b0;
            end

            // Handle data out asynchronous
            if(i2c_select == 1'b1 & req == 1'b1 & wr == 1'b0 ) begin
                case (addr[3:2])
                    2'b00: begin
                        // Read answer from a read action
                        q <= cmd_result_r;
                    end
                    2'b01: begin
                        // Return status register
                        q <= status_reg;
                    end
                    2'b10: begin
                        // Return IO prescale value
                        q <= i2c_prescale;
                    end
                    2'b11: begin
                        // do nothing
                        q <= 16'h1337;
                    end
                endcase
            end
        end
    end
end

// Generate bus free pulse
always_ff @(posedge clk) begin
    busy_ <= busy;
    busy_strobe <= 1'b0;

    if (busy_ == 1'b1 && busy == 1'b0) begin
        busy_strobe <= 1'b1;
    end
end

// Handle write synchronous
always_comb begin
    req_strobe = (req_ == 1'b0 & req == 1'b1);
    cmd_flag = cmd_t'(buf_write[con_write][11:8]);

    // Buffer consumer and producer next state
    con_read_next = con_read+1;
    con_write_next = con_write+1;
    prod_read_next = prod_read+1;
    prod_write_next = prod_write+1;
end

always_ff @(posedge clk) begin
    r_cmd_done <= 1'b0;
    req_ <= req;

    if (rst) begin
        cmd_valid_r <= 0;
        data_in_valid <= 0;
        data_out_ready <= 0;
        cmd_read_r <= 0;
        cmd_write_r <= 0;
        cmd_write_multiple_r <= 0;
        cmd_stop_r <= 0;
        cmd_start_r <= 0;
        con_read <= 0;
        prod_read <= 0;
        cmd_result_r <= 0;
        data_in_last <= 0;
        cmd_address <= 0;
        stop_on_idle <= 0;
        data_in <= 8'h00;
        i2c_prescale <= 16'h0000;
        state_reg <= STATE_IDLE;
    end else begin

        // Write to the buffer
        if(i2c_select == 1'b1 & req_strobe == 1'b1 & wr == 1'b1) begin
            buf_write[prod_write] <= d;
            prod_write <= prod_write_next;
        end

        // Read from the buffer
        if(i2c_select == 1'b1 & req_strobe == 1'b1 & wr == 1'b0) begin
            con_read <= con_read_next;
        end

        // handle writes
        unique case(state_reg)
            // Idle wait for a command to come in
            STATE_IDLE: begin
                cmd_valid_r <= 0;
                data_in_valid <= 0;
                data_out_ready <= 0;
                cmd_read_r <= 0;
                cmd_write_r <= 0;
                cmd_write_multiple_r <= 0;
                cmd_stop_r <= 0;
                cmd_start_r <= 0;

                // On reset, reset
                if(rst) begin
                    state_reg <= STATE_IDLE;
                    prod_write <= 0;
                    con_write <= 0;

                    r_write_ready <= 0;
                    r_read_ready <= 0;
                    cmd_in <= 0;
                end
                // When unsent data is present
                if(prod_write != con_write) begin
                    // Fetch data
                    cmd_in <= buf_write[con_write];
                    con_write <= con_write_next;
                    // decode
                    // case(buf_write[con_write][11:8])
                    unique case(cmd_flag)
                        CMD_NOP: begin
                            state_reg <= STATE_IDLE;
                        end
                        CMD_READ: begin
                            r_read_ready <= 1'b0;
                            state_reg <= STATE_READ;
                        end
                        CMD_WRITE: begin
                            r_write_ready <= 1'b0;
                            state_reg <= STATE_WRITE;
                        end
                        CMD_WRITE_MULTI: begin
                            r_write_ready <= 1'b0;
                            state_reg <= STATE_WRITE_MULTI;
                        end
                        CMD_START: begin
                            state_reg <= STATE_START;
                        end
                        CMD_STOP: begin
                            state_reg <= STATE_STOP;
                        end
                        // read pointer
                        CMD_READ_NEXT: begin
                            con_read <= con_read_next;
                        end
                        // config
                        CMD_SET_ADDR: begin
                            state_reg <= STATE_SET_ADDRESS;
                        end
                        CMD_SET_SCL_L: begin
                            state_reg <= STATE_SET_SCL_L;
                        end
                        CMD_SET_SCL_H: begin
                            state_reg <= STATE_SET_SCL_H;
                        end
                        CMD_STOP_ON_IDLE: begin
                            state_reg <= STATE_SET_SOI;
                        end
                        CMD_RESET: begin
                            state_reg <= STATE_RESET;
                        end
                    endcase
                end
            end

            // Read a byte
            STATE_READ: begin
                cmd_valid_r <= 1;
                cmd_read_r <= 1;
                data_out_ready <= 1;

                if (data_out_ready == 1) begin
                    r_cmd_done <= 1'b1;

                    cmd_valid_r <= 0;
                    data_out_ready <= 0;
                    r_read_ready <= 1'b1;

                    // Write result to buffer read buffer
                    buf_read [prod_read] <= {8'h00, data_out};
                    prod_read <= prod_read_next;

                    state_reg <= STATE_IDLE;
                end
            end
            // Write a byte
            // Start is implicit when bus is Idle
            STATE_WRITE: begin
                cmd_valid_r <= 1;
                cmd_write_r <= 1;
                data_in_valid <= 1;
                data_in <= cmd_in[7:0];

                if (data_in_ready == 1) begin
                    r_cmd_done <= 1'b1;
                    cmd_valid_r <= 0;
                    cmd_result_r <= 0;
                    r_write_ready <= 1'b1;

                    state_reg <= STATE_IDLE;
                end
            end
            // Write mutiple bytes
            // When writing last byte set data_in_last(byte 12) high to end
            // transmission
            STATE_WRITE_MULTI: begin
                cmd_valid_r <= 1;
                cmd_write_multiple_r <= 1;
                data_in_valid <= 1;
                data_in <= cmd_in[7:0];
                data_in_last <= cmd_in[12];

                if (data_in_ready == 1) begin
                    r_cmd_done <= 1'b1;
                    cmd_valid_r <= 0;
                    cmd_result_r <= 0;
                    r_write_ready <= 1'b1;

                    state_reg <= STATE_IDLE;
                end
            end
            // Trigger start
            STATE_START: begin
                cmd_valid_r <= 1;
                cmd_start_r <= 1;
                if(cmd_ready_r == 1) begin
                    // r_cmd_done <= 1'b1;
                    cmd_valid_r <= 0;
                    state_reg <= STATE_IDLE;
                end
            end
            // Trigger stop
            STATE_STOP: begin
                cmd_valid_r <= 1;
                cmd_stop_r <= 1;
                if (cmd_ready_r == 1) begin
                    r_cmd_done <= 1'b1;
                    cmd_valid_r <= 0;
                    state_reg <= STATE_IDLE;
                end
            end
            // Set the address of the slave device
            STATE_SET_ADDRESS: begin
                cmd_address <= cmd_in[7:1];
                state_reg <= STATE_IDLE;
            end
            // Set low byte of the devider
            STATE_SET_SCL_L: begin
                i2c_prescale[7:0] <= cmd_in[7:0];
                state_reg <= STATE_IDLE;
            end
            // Set the high byte of the devider
            STATE_SET_SCL_H: begin
                i2c_prescale[15:8] <= cmd_in[7:0];
                state_reg <= STATE_IDLE;
            end
            // Set the stop on idle bit, when set the transmission
            // ends on detection of a bus error.
            STATE_SET_SOI: begin
                stop_on_idle <= d[0];
                state_reg <= STATE_IDLE;
            end
            // Reset, what else to say
            default: begin
                // reset registes to I2C master
                cmd_address <= 0;
                cmd_start_r <= 0;
                cmd_read_r <= 0;
                cmd_write_r <= 0;
                cmd_write_multiple_r <= 0;
                cmd_stop_r <= 0;
                cmd_valid_r <= 0;
                // And return
                state_reg <= STATE_IDLE;
            end
        endcase
    end
end

// I2C Master
i2c_master my_i2c_master(
    .clk(clk),
    .rst(rst),

    // Host interface
    .cmd_address        ( cmd_address),
    .cmd_start          ( cmd_start_r),
    .cmd_read           ( cmd_read_r),
    .cmd_write          ( cmd_write_r),
    .cmd_write_multiple ( cmd_write_multiple_r),
    .cmd_stop           ( cmd_stop_r),
    .cmd_valid          ( cmd_valid_r),
    .cmd_ready          ( cmd_ready_r),

    .data_in            ( data_in),
    .data_in_valid      ( data_in_valid),
    .data_in_ready      ( data_in_ready),
    .data_in_last       ( data_in_last),

    .data_out           ( data_out),
    // .data_out_valid     ( data_out_valid),
    .data_out_valid     ( ),
    .data_out_ready     ( data_out_ready),
    // .data_out_last      ( data_out_last),
    .data_out_last      ( ),

    // I2C interface
    .scl_i (scl_i),
    .scl_o (scl_o),
    .scl_t (scl_t),
    .sda_i (sda_i),
    .sda_o (sda_o),
    .sda_t (sda_t),

    // Status
    .busy (busy),
    // .bus_control (bus_control),
    .bus_control ( ),
    .bus_active (bus_active),
    .missed_ack (missed_ack),

    // Configuration
    .prescale (i2c_prescale),
    .stop_on_idle (stop_on_idle)
);

endmodule
