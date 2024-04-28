`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 02/27/2021 08:27:46 PM
// Design Name:
// Module Name: i2c_bridge_tb
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


module i2c_bridge_tb (

);
logic        clk_28;
logic        clk_114;
logic [31:0] count;
logic        reset_n;

logic [31:2] addr;

logic [15:0] d;
wire  [15:0] q;
logic [15:0] r_q;
logic        req;
logic        wr;
wire         ack;
wire         interrupt;

typedef enum {
    CMD_NOP          = 4'h0,
    CMD_READ         = 4'h1,
    CMD_WRITE        = 4'h2,
    CMD_WRITE_MULTI  = 4'h3,
    CMD_START        = 4'h4,
    CMD_STOP         = 4'h5,
// config
    CMD_SET_ADDR     = 4'hb,
    CMD_SET_SCL_L    = 4'hc,
    CMD_SET_SCL_H    = 4'hd,
    CMD_STOP_ON_IDLE = 4'he,
    CMD_RESET        = 4'hf
} cmd_enum_t;

typedef enum {
    STATE_IDLE       = 4'h0,
    STATE_ENABLE_INT = 4'h1,
    STATE_SET_PRH    = 4'h2,
    STATE_SET_PRL    = 4'h3,
    STATE_SET_ADDR   = 4'h4,
    STATE_WRITE_1    = 4'h5,
    STATE_WRITE_2    = 4'h6,
    STATE_WRITE_3    = 4'h7,
    STATE_WAIT       = 5'h8,
    STATE_FINISH     = 4'h9
} state_enum_t;
state_enum_t state_reg = STATE_IDLE;


// I2C loopback
wire       scl_o;
tri1       scl_t;
wire       sda_o;
tri1       sda_t;

wire [7:0] s_out;
wire       s_out_valid;
// Clock generation
initial begin
    clk_114 = 1'b0;
    clk_28  = 1'b0;
    count   = 0;
    reset_n = 1'b0;

    addr    = 0;
    d       = 0;
    req     = 1'b0;
    wr      = 1'b0;
end

// 114 MHz
always #4.464 clk_114 = ~clk_114;

// 28MHz
always @(posedge clk_114) begin
    clk_28 <= ~clk_28;
end

// read the q
always @(posedge clk_28) begin
    r_q <= q;
end

function [31:0] addr_to_out;
    // Because the nomal address is [31:0], but the bus is [31:2]
    input [31:0] addr;
    begin
        addr_to_out = (addr >> 2);
    end
endfunction

// Do write
always @(posedge clk_28) begin
    count <= count + 1;
    d <= 0;
    addr <= 0;
    wr <= 0;
    req <= 0;

    // release reset
    if (count == 5) reset_n <= 1'b1;

    // Start first write to I2C bridge
    // i2c_select <= '1' when addr(23)='1' and addr(7 downto 4)=X"6" else '0';
    case(state_reg)
        // Start
        STATE_IDLE: begin
            if (count == 'd6) state_reg <= STATE_ENABLE_INT;
        end
        STATE_ENABLE_INT: begin
            addr <= addr_to_out(32'h8000A0);
            wr <= 1'b1;
            req <= 1'b1;
            d <= {16'h0001}; // Enable interrupt
            if (count == 'd10) begin
                req <= 1'b0;
                state_reg <= STATE_SET_PRH;
            end
        end
        // Set I2C devider registers
        STATE_SET_PRH: begin
            addr <= addr_to_out(32'h800060);
            wr <= 1'b1;
            req <= 1'b1;
            d <= {4'h0, CMD_SET_SCL_H, 8'h00};
            if (count == 'd12) begin
                req <= 1'b0;
                state_reg <= STATE_SET_PRL;
            end
        end
        STATE_SET_PRL: begin
            addr <= addr_to_out(32'h800060);
            wr <= 1'b1;
            req <= 1'b1;
            d <= {4'h0, CMD_SET_SCL_L, 8'h11};
            if (count == 'd14) begin
                req <= 1'b0;
                state_reg <= STATE_SET_ADDR;
            end
        end
        // Set device address to communicate with
        STATE_SET_ADDR: begin
            addr <= addr_to_out(32'h800060);
            wr <= 1'b1;
            req <= 1'b1;
            d <= {4'h0, CMD_SET_ADDR, 8'h72};
            if (count == 'd18) begin
                req <= 1'b0;
                state_reg <= STATE_WRITE_1;
            end
        end
        // Write 3 byte message, observe interrupt
        STATE_WRITE_1: begin
            addr <= addr_to_out(32'h800060);
            wr <= 1'b1;
            req <= 1'b1;
            //d <= 16'h221e;
            d <= {4'h0, CMD_WRITE_MULTI, 8'h1e};
            if (req == 1'd1) begin
                req <= 1'b0;
                state_reg <= STATE_WRITE_2;
            end
        end
        STATE_WRITE_2: begin
            addr <= addr_to_out(32'h800060);
            wr <= 1'b1;
            req <= 1'b1;
            //d <= 16'h0211;
            d <= {4'h0, CMD_WRITE_MULTI, 8'hbb};
            if (req == 1'b1) begin
                req <= 1'b0;
                state_reg <= STATE_WRITE_3;
            end
        end
        STATE_WRITE_3: begin
            addr <= addr_to_out(32'h800060);
            wr <= 1'b1;
            req <= 1'b1;
            //d <= 16'h0211;
            d <= {4'h1, CMD_WRITE_MULTI, 8'h27}; // Set 4'h1 high, indicate last byte, controller adds stop
            if (req == 1'b1) begin
                req <= 1'b0;
                state_reg <= STATE_WAIT;
            end
        end
        STATE_WAIT: begin
            addr <= addr_to_out(32'h800064);
            wr <= 1'b0;
            req <= 1'b1;
            if (interrupt == 1'b1) begin
                state_reg <= STATE_FINISH;
            end
        end
        // Done, finish the test
        STATE_FINISH: begin
            addr <= addr_to_out(32'h8000A0); // Ack interrupt
            wr <= 1'b0;
            req <= 1'b1;
            if (q[2] == 1'b0) begin // Check if the bus is free
                if(s_out[7:0] != 8'h27) begin
                    $display("%t: state: %0h out: %0h  does not match d: %0h", $time, state_reg, s_out,  8'h27);
                end
                $finish;
            end else begin
                req <= 1'b1;
                state_reg <= STATE_WAIT;
            end
        end
        default: begin
            state_reg <= STATE_IDLE;
        end
    endcase

    // if (count == 'd4000) begin
    //  $finish;
    // end

end


// CFIDE test subject
cfide #(
    .spimux(1'b0),
    .havespirtc(1'b0),
    .havei2c(1'b1),
    .havevpos(1'b0)
)mycfide (

    .sysclk(clk_114), //    : in std_logic;
    .n_reset(reset_n), //   : in std_logic;

    .addr(addr), // : in std_logic_vector(31 downto 2);
    .d(d), //       : in std_logic_vector(15 downto 0);
    .q(q), //       : out std_logic_vector(15 downto 0);
    .req(req), //       : in std_logic;
    .wr(wr), //     : in std_logic;
    .ack(ack), //       : out std_logic;

    .sd_di(1'b1), //        : in std_logic;
    .sd_cs(), //    : out std_logic_vector(7 downto 0);
    .sd_clk(), //       : out std_logic;
    .sd_do(), //        : out std_logic;
    .sd_dimm(1'b1), //  : in std_logic;     --for sdcard
    .sd_ack(1'b1), //       : in std_logic; -- indicates that SPI signal has made it to the wire
    .debugTxD(), //TxD : out std_logic;
    .debugRxD(1'b1), //RxD : in std_logic;
    .menu_button(1'b1), //  : in std_logic:='1';
    .scandoubler(), //  : out std_logic;

    .audio_ena(), // : out std_logic;
    .audio_clear(), // : out std_logic;
    .audio_buf(), // : in std_logic;
    .audio_amiga(), // : in std_logic;

    .vbl_int(1'b0), //  : in std_logic;
    .interrupt(interrupt), //   : out std_logic;
    .c64_keys('hf), //  : in std_logic_vector(63 downto 0) :=X"FFFFFFFFFFFFFFFF";
    .amiga_key(), //    : out std_logic_vector(7 downto 0);
    .amiga_key_stb(), //    : out std_logic;

    .amiga_addr(8'h0), // : in std_logic_vector(7 downto 0);
    .amiga_d(16'h00), // : in std_logic_vector(15 downto 0);
    .amiga_q(), // : out std_logic_vector(15 downto 0);
    .amiga_req(1'b0), // : in std_logic;
    .amiga_wr(1'b0), // : in std_logic;
    .amiga_ack(), // : out std_logic;

    .rtc_q(), // : out std_logic_vector(63 downto 0);

    // I2C interface
    .scl_i(scl_t), // Loopback for test
    .scl_o(scl_o),
    .scl_t(scl_t),

    .sda_i(sda_t), // Loopback for test
    .sda_o(sda_o),
    .sda_t(),


    // 28Mhz signals
    .clk_28(clk_28), // : in std_logic;
    .tick_in(1'b0) // : in std_logic    -- 44.1KHz - makes it easy to keep timer in lockstep with audio.
);

assign sda_t = sda_o ? 1'bZ : 1'b0;

i2c_slave_tb my_i2c_slave(
    .out(s_out),
    .out_valid(s_out_valid),
    .sda(sda_t),
    .scl(scl_o)
);




endmodule
