/********************************************/
/* rtc_spi_clock.v                          */
/* OpenAARS Board Top File                  */
/*                                          */
/* Max speed SPI bus pcf2123 6.25MBits/s    */
/* Bridge OKI M6242B -> SPI -> PCF2123      */
/*                                          */
/* 2023, paul(at)printf.nl                  */
/********************************************/

`timescale 1ns / 10ps

///////////////////////////////////////////////////////////////////////////////
//              CLKS_PER_HALF_BIT - Sets frequency of o_SPI_Clk.  o_SPI_Clk is
//              derived from i_Clk.  Set to integer number of clocks for each
//              half-bit of SPI data.  E.g. 100 MHz i_Clk, CLKS_PER_HALF_BIT = 2
//              would create o_SPI_CLK of 25 MHz.  Must be >= 2
///////////////////////////////////////////////////////////////////////////////
module rtc_spi_clock #(
  parameter CLKS_PER_HALF_BIT = 6
) (
  input wire         clk,
  input wire         reset,

  // RTC hardware interface
  // (* keep = "true" *)
  input  wire        cs_n,
  input  wire        cpu_rd_n,     // read when low
  input  wire        cpu_wr_n,     // write when low
  input  wire [3:0]  cpu_address,
  input  wire [3:0]  rtc_data_in,
  output wire [3:0]  rtc_data_out,

  // PCF2123 RTC interface
  input   wire       rtc_clkout, // 32.768 kHz clock pulse
  input   wire       rtc_int_n,
  output  logic      rtc_spi_ce,
  output  logic      rtc_spi_clk,
  output  wire       rtc_spi_cmd,  // MOSI
  input   wire       rtc_spi_data0 // MISO
);

// Synchronization registers
// wire [63:0] rtc_q_w;
// reg  [63:0] rtc_q_reg;
// (* ASYNC_REG = "true" *)reg  [ 1:0] miso_s;
wire         rtc_spi_clk_w;

// OKI write state signals
(* MARK_DEBUG = "true" *)
wire         oki_write_dirty;
(* MARK_DEBUG = "true" *)
logic        oki_clear_dirty;
// wire        oki_hold;
(* MARK_DEBUG = "true" *)
logic [3:0]  pcf_addr;
(* MARK_DEBUG = "true" *)
logic [7:0]  pcf_rx_data;
(* MARK_DEBUG = "true" *)
wire  [7:0]  pcf_tx_data;
(* MARK_DEBUG = "true" *)
logic        pcf_dv;
(* MARK_DEBUG = "true" *)
logic        pcf_wr_n;
(* MARK_DEBUG = "true" *)
logic        pcf_latch;

// SPI control registers
logic [3:0]  rx_pos;
wire  [3:0]  rx_pos_next;
logic [3:0]  tx_pos;
wire  [3:0]  tx_pos_next;

// SPI master interface
logic [ 7:0] tx_byte;
logic        tx_dv;
wire         TX_Ready;
wire         rx_dv;
wire  [ 7:0] rx_byte;

// Generate 1/16 of a second pulse
// This to not continuously read / write to the SPI master, halting the counters
// (* ASYNC_REG = "true" *)

(* ASYNC_REG = "true" *)
logic [2:0] clk_out_cc;
logic [2:0] clk_out_cc_next;
(* ASYNC_REG = "true" *)
logic [11:0] clk_out_dev;
logic [11:0] clk_out_dev_next;
logic        clk_out_tr;
logic        clk_out_dev_tr;
logic [13:0] cnt_read_pcf;
logic [14:0] cnt_read_pcf_next;
logic        tr_read_pcf;


`ifdef COCOTB_SIM
localparam DELAY_CNT = 40;
`else
// parameter DELAY_CNT = 12'hFFF;
localparam DELAY_CNT = 10;
`endif

always_ff @(posedge clk) begin
  clk_out_tr <= 1'b0;
  clk_out_dev_tr <= 1'b0;
  if (reset == 1'b1) begin
    clk_out_cc <= 3'b000;
    clk_out_dev <= 12'h000;
  end else begin
    // Synchronize the rtc_clk_out clock signal
    clk_out_cc <= clk_out_cc_next;
    // Trigger on positive edgo of the rtc_clk_out clock
    if (clk_out_cc[2:1] == 2'b01) begin
      clk_out_dev <= clk_out_dev_next;
      clk_out_tr <= 1'b1;

      if (clk_out_dev == DELAY_CNT) begin
        clk_out_dev_tr <= 1'b1;
        clk_out_dev <= 0;
      end
    end
  end
end

assign clk_out_cc_next = {clk_out_cc[1:0], rtc_clkout};
assign clk_out_dev_next = (clk_out_dev + 1);

always_ff @(posedge clk) begin
  tr_read_pcf <= 1'b0;
  if (reset == 1'b1) begin
    cnt_read_pcf <= 14'h000;
  end else if (clk_out_tr == 1'b1) begin
    {tr_read_pcf, cnt_read_pcf} <= cnt_read_pcf_next;
  end
end

assign cnt_read_pcf_next = (cnt_read_pcf + 1);

// Synchronize the interrupt input
  (* ASYNC_REG = "true" *)
logic [1:0] rtc_int_n_sync;
wire [1:0] rtc_int_n_sync_next;
always_ff @(posedge clk) begin
  if (reset == 1'b1) begin
    rtc_int_n_sync <= 2'b00;
  end else begin
    rtc_int_n_sync <= rtc_int_n_sync_next;
  end
end

assign rtc_int_n_sync_next = { rtc_int_n_sync[0], rtc_int_n};



// The PCF - OKI translation module
oki_pcf_buffer my_oki_buffer (
  .clk  (clk),
  .rst_n(~reset),

  // OKI interface
  .oki_addr       (cpu_address),
  .oki_rx_data    (rtc_data_in),
  .oki_tx_data    (rtc_data_out),
  .oki_rd_n       (cpu_rd_n),
  .oki_rw_n       (cpu_wr_n),
  .oki_cs_n       (cs_n),
  .oki_write_dirty(oki_write_dirty),  // High when write was done
  .oki_clear_dirty(oki_clear_dirty),  // Resets oki_write_dirty when high
  .oki_hold       (),         // 1 When the Hold bit is set

  // PCF interface for refreshing PCF data from SPI
  // Does not become readable until pcf_latch is pulsed
  // Interface is write only, value is written on dv=1'b1
  .pcf_addr       (pcf_addr),
  .pcf_rx_data    (pcf_rx_data),
  .pcf_tx_data    (pcf_tx_data),
  .pcf_dv         (pcf_dv),
  .pcf_wr_n         (pcf_wr_n),
  .pcf_latch      (pcf_latch)         // Latch written data to active buffer
);



// PCF2123 SPI INTERFACE
// When a read / write action are started, all registers are latched.
// 0 : Command - { r/w (0 for write), 1'b0, 4'bxxxx - addr}
// 1 - x : For every extra byte the address will auto increment.
//

// Triggers
logic [2:0] tx_ready;
wire [2:0] tx_ready_next;
logic tx_ready_t ; // Trigger when tx is ready
logic [2:0] rx_ready;
wire [2:0] rx_ready_next;
logic rx_ready_t ; // Trigger when rx is ready

always_ff @(posedge clk) begin
  // reset logic
  if (reset == 1'b1) begin
    rx_ready <= 0;
    rx_ready_t <= 1'b0;
    tx_ready <= 0;
    tx_ready_t <= 1'b0;
  end else begin

    // rx_ready pos edge trigger
    rx_ready_t <= 1'b0;
    if(rx_ready[2:1] == 2'b01) begin
      rx_ready_t <= 1'b1;
    end

    // tx_ready_ pos edge trigger
    tx_ready_t <= 1'b0;
    if (tx_ready[2:1] == 2'b01) begin
      tx_ready_t <= 1'b1;
    end

    // Next state
    rx_ready <= rx_ready_next;
    tx_ready <= tx_ready_next;
  end
end

// Next state for rx and tx trigger next state logic
assign rx_ready_next = {rx_ready[1], rx_ready[0], rx_dv}; // Becomes 1 when Read is complete
assign tx_ready_next = {tx_ready[1], tx_ready[0], TX_Ready}; // Becomes 1 when Write is complete
assign rtc_spi_clk = rtc_spi_clk_w;

// SPI Interface interfacing with the PCF2123
SPI_Master #(
  .SPI_MODE(0),
  .CLKS_PER_HALF_BIT(CLKS_PER_HALF_BIT)
) rtc_spi_master (
  .i_Clk  (clk),  // FPGA Clock
  .i_Rst_L(~reset),  // FPGA Reset (al)
  // TX (MOSI) Signals
  .i_TX_Byte (tx_byte),  // Byte to transmit on MOSI
  .i_TX_DV   (tx_dv),    // Data Valid Pulse with i_TX_Byte
  .o_TX_Ready(TX_Ready), // Transmit Ready for next byte
  // RX (MISO) Signals
  .o_RX_DV  (rx_dv),   // Data Valid pulse (1 clock cycle)
  .o_RX_Byte(rx_byte), // Byte received on MISO
  // SPI Interface
  .o_SPI_Clk (rtc_spi_clk_w),
  .i_SPI_MISO(rtc_spi_data0),
  .o_SPI_MOSI(rtc_spi_cmd)
);

// State machine to read and write to the PCF2123
// Reset the PCF2123
typedef enum {
  // Reset the PCF2123
  STATE_RST_1,
  STATE_RST_2,
  STATE_RST_3,
  // Setup Interrupt
  STATE_INIT_1,
  STATE_INIT_2,
  STATE_INIT_3,
  // Wait
  STATE_IDLE,
  // Read
  STATE_READ_0,
  STATE_READ_1,
  STATE_READ_2,
  STATE_READ_3,
  STATE_READ_4,
  // Write
  STATE_WRITE_0,
  STATE_WRITE_1,
  STATE_WRITE_2,
  STATE_WRITE_3,
  STATE_WRITE_4,
  STATE_WRITE_5
} pcf_fsm_state_t;

(* fsm_encoding = "one_hot", MARK_DEBUG = "true" *) // Set FSM state encoding
pcf_fsm_state_t pcf_fsm_state;

// PCF2123 CONTROL COMMANDS

// Reset sequence
localparam RESET_SEQ_1 = 8'h10;
localparam RESET_SEQ_2 = 8'h58;

// Read or write
localparam PCF_READ_CMD  = 8'b1001_0000;
localparam PCF_WRITE_CMD = 8'b0001_0000;

// Setup seconds interrupt
logic [7:0]   rtc_msg_init [0:4];
logic [1:0]   rtc_msg_cnt;

initial begin
  // rtc_msg_cnt = 0;

  // Initialization sequence that enables the 1 second interrupt
  rtc_msg_init[0] = PCF_WRITE_CMD;
  rtc_msg_init[1] = 8'h00; // Start writing at address 0x0
  rtc_msg_init[2] = 8'h00; // Config register A
  rtc_msg_init[3] = 8'h40; // Config register B : Enable second interrupt
end

// PCF SPI FSM
assign tx_pos_next = tx_pos + 1;
assign rx_pos_next = rx_pos + 1;

logic [1:0] pause_delay_count = 2'b00;
task static delay_to_next_state(
    pcf_fsm_state_t pause_next_state, // Desired next state
    input logic clk_tr                // delay clock trigger
  );
  // Wait 2 detay ticks
  if (clk_tr == 1'b1) begin
    if (pause_delay_count == 2'b01) begin
      pcf_fsm_state <= pause_next_state;
      pause_delay_count <= 2'b00;
    end else begin
      pause_delay_count <= pause_delay_count + 1;
    end
  end
endtask

logic state_next;

always_ff @(posedge clk) begin
  if (reset == 1'b1) begin
    tx_byte <= 8'h00;
    tx_dv <= 1'b0;
    oki_clear_dirty <= 1'b0;
    pcf_addr <= 4'h0;
    pcf_dv <= 1'b0;
    pcf_wr_n <= 1'b1; // Read by default
    pcf_fsm_state <= STATE_RST_1;
    pcf_latch <= 1'b0;
    pcf_rx_data <= 8'h00;
    rtc_spi_ce <= 1'b0; // No select
    rx_pos <= 4'h0;
    tx_pos <= 4'h0;
    state_next <= 1'b0;
    rtc_msg_cnt <= 0;
    pause_delay_count <= 2'b00;
  end else begin
    unique case (pcf_fsm_state)
      // Reset
      STATE_RST_1: begin
        tx_dv <= 1'b0;
        rtc_spi_ce <= 1'b1; // assert select

        if (rtc_spi_ce == 1'b1) begin
          // Send the command byte of the reset sequence
          tx_byte <= RESET_SEQ_1;
          tx_dv <= 1'b1;
        end

        if (tx_ready_t) begin
          pcf_fsm_state <= STATE_RST_2;
        end
      end

      STATE_RST_2: begin
        // Send the data byte of the reset sequence
        tx_dv <= 1'b0;
        if (rx_ready_t == 1'b1) begin
          state_next <= 1'b1;
        end

        if (state_next & rtc_spi_clk_w == 1'b0) begin
          state_next <= 1'b0;
          tx_byte <= RESET_SEQ_2;
          tx_dv <= 1'b1;
          pcf_fsm_state <= STATE_RST_3;
        end
      end

      STATE_RST_3: begin
        // Close the transmission
        tx_dv <= 1'b0;

        if (rx_ready_t == 1'b1) begin
          state_next <= 1'b1;
        end

        if (state_next == 1'b1) begin
          // cs_to_start_pause(STATE_INIT_1, clk_out_tr);
          delay_to_next_state(STATE_IDLE, clk_out_dev_tr);
        end
      end

      // Setup the 1 second interrupt
      STATE_INIT_1: begin
        rtc_spi_ce <= 1'b0;
        state_next <= 1'b0;
        delay_to_next_state(STATE_INIT_2, clk_out_dev_tr);
      end

      STATE_INIT_2: begin
        rtc_spi_ce <= 1'b1;
        rtc_msg_cnt <= 2'h0;
        delay_to_next_state(STATE_INIT_3, clk_out_dev_tr);
      end

      STATE_INIT_3: begin
        tx_dv <= 1'b0;
        // Send first byte
        if (rtc_msg_cnt == 2'h0 && ~state_next) begin
          tx_dv <= 1'b1;
          tx_byte <= rtc_msg_init[rtc_msg_cnt];
          rtc_msg_cnt <= rtc_msg_cnt + 1;
        end
        // Send sequential bytes
        if (rx_ready_t && ~state_next) begin
          tx_dv <= 1'b1;
          tx_byte <= rtc_msg_init[rtc_msg_cnt];

          if (rtc_msg_cnt == 2'b11) begin
            state_next <= 1'b1;
          end
          rtc_msg_cnt <= rtc_msg_cnt + 1;

          if (rtc_msg_cnt == 2'b11) begin
            state_next <= 1'b1;
          end

        end

        if (state_next) begin
          // cs_to_start_pause(STATE_IDLE);
          pcf_fsm_state <= STATE_IDLE;
        end
      end

      STATE_IDLE: begin
        // Set registers
        state_next <= 1'b0;
        oki_clear_dirty <= 1'b0;
        rtc_spi_ce <= 1'b0;
        pcf_dv <= 1'b0;
        pcf_latch <= 1'b0;

        // Make sure there is a little delay before starting the next transaction
//          if (clk_out_tr == 1'b1) begin
        if (oki_write_dirty == 1'b1) begin
          // When data is touched write it back
          pcf_fsm_state <= STATE_WRITE_0;
        // end else if (rtc_int_n_sync[1] == 1'b0) begin
        end else if (tr_read_pcf == 1'b1) begin
          // When data is not touched just load updates from the chip
          rx_pos <= 4'h0;
          pcf_fsm_state <= STATE_READ_0;
        end
//          end
      end

      // Refresh registers from the PCF2123
      // AKA read from the PCF2123
      STATE_READ_0: begin
        rtc_spi_ce <= 1'b1; // Start the SPI transaction
        delay_to_next_state(STATE_READ_1, clk_out_dev_tr);
      end
      STATE_READ_1: begin
        rx_pos <= 4'h0; // Reset the read counter
        // Send the command to start reading at address 0x0
        // if (rtc_spi_clk_w == 1'b0) begin
        tx_dv <= 1'b1;
        tx_byte <= PCF_READ_CMD;
        // end
        if (tx_dv == 1'b1) begin
          tx_dv <= 1'b0; //
          state_next <= 1'b0;
          pcf_fsm_state <= STATE_READ_2;
          tx_byte <= 8'h00; // Send 0 to start at address 0x0
        end
      end
      // Not used for now, because we need the first byte
      // TODO: Remove if not needed at all
      STATE_READ_2: begin
        if (tx_ready_t == 1'b1) begin
          // Skip the address byte in the buffer
          tx_byte <= 8'h00;
          tx_dv <= 1'b1;
          state_next <= 1'b1;
        end

        if (state_next == 1'b1) begin
          tx_dv <= 1'b0;
          state_next <= 1'b0;
          pcf_fsm_state <= STATE_READ_3;
        end

      end
      STATE_READ_3: begin
        tx_dv <= 1'b0;
        pcf_dv <= 1'b0;

        // When the read is ready store value
        if (rx_ready_t == 1'b1) begin
          state_next <= 1'b0;
          pcf_addr <= rx_pos;
          pcf_rx_data <= rx_byte;
          pcf_wr_n <= 1'b0;
          pcf_dv <= 1'b1;
          // Setup for next value
          rx_pos <= rx_pos_next;
        end

        if (tx_ready_t) begin
          // Start the next transaction unless the more tha 0x08 bytas have been transferred
          // Read register 0x00 - 0x08, ignore the rest
          if (rx_pos < 4'h09) begin
            // Send next 0x00 byte to enable receiving of data
            tx_dv <= 1'b1; //
            tx_byte <= 8'h00;
          end else begin
            // Latch the received data to the active buffer
            pcf_latch <= 1'b1;

            pcf_fsm_state <= STATE_READ_4;
          end
        end
      end
      STATE_READ_4: begin
        rx_pos <= 4'h0;
        pcf_dv <= 1'b0;
        pcf_latch <= 1'b0;
        delay_to_next_state(STATE_IDLE, clk_out_dev_tr);
      end
      // End of read


      // Write modified registers to the PCF IC
      STATE_WRITE_0: begin
        rtc_spi_ce <= 1'b1; // Start the SPI transaction
        delay_to_next_state(STATE_WRITE_1, clk_out_dev_tr);
      end

      STATE_WRITE_1: begin
        // Clear the write flag
        oki_clear_dirty <= 1'b1;
        tx_pos <= 4'h0; // Clear the TX counter
        rtc_spi_ce <= 1'b1; // Start the transaction
        // Send the write command to the PCF2123
        tx_byte <= PCF_WRITE_CMD;
        tx_dv <= 1'b1;

        if (tx_dv == 1'b1) begin
          tx_dv <= 1'b0; // End data valid pulse
          tx_byte <= 8'h00;
          pcf_fsm_state <= STATE_WRITE_2;
        end
      end

      // Send the Address to start writing to the PCF2123
      STATE_WRITE_2: begin

        if (rx_ready_t == 1'b1) begin
          state_next <= 1'b1;
        end

        // Wait for the command by to be transmitted to the PCF2123
        if (state_next & rtc_spi_clk_w == 1'b0) begin
          state_next <= 1'b0;
          tx_dv <= 1'b1; // Send the address
          tx_byte <= 8'h00; // Start the transfer at address 0x00

          pcf_fsm_state <= STATE_WRITE_3;
        end
      end

      // Send the data bytes one by one to the PCF2123
      STATE_WRITE_3: begin
        tx_dv <= 1'b0;
        tx_byte <= 8'h00;

        // Prepare to read the next value from the PCF2123
        pcf_wr_n <= 1'b1; // Write
        pcf_addr <= tx_pos;
        // Send the register values to the PCF2123
        if (rx_ready_t == 1'b1) begin
          state_next <= 1'b1;
        end

        if (state_next & rtc_spi_clk_w == 1'b0) begin
          state_next <= 1'b0;
          tx_dv <= 1'b1; // Send the data
          tx_byte <= pcf_tx_data;

          pcf_fsm_state <= STATE_WRITE_4;
        end
      end

      // End byte queue
      STATE_WRITE_4: begin
        tx_dv <= 1'b0;
        tx_byte <= 8'h00;
        tx_pos <= tx_pos_next;

        if (tx_pos < 4'h9) begin
          pcf_fsm_state <= STATE_WRITE_3;
        end else begin
          pcf_fsm_state <= STATE_WRITE_5;

        end
      end

      // Some time for the CS to drop after the last byte
      STATE_WRITE_5: begin
        delay_to_next_state(STATE_IDLE, clk_out_dev_tr);
      end

      default: begin
        pcf_fsm_state <= STATE_RST_1;
      end
    endcase
  end
end

// Dump waves only when simulating
`ifdef COCOTB_SIM
initial begin
  $dumpfile("dump.vcd");
  $dumpvars(1, rtc_spi_clock);
end
`endif

endmodule


