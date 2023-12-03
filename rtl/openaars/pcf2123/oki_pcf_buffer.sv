/********************************************/
/* oki_pcf_buffer.v                         */
/* MiST Board Top File                      */
/*                                          */
/* 2012-2015, rok.krajnc@gmail.com          */
/********************************************/

`timescale 1ns / 10ps

module oki_pcf_buffer (
  input  wire       clk,
  input  wire       rst_n,
  // OKI interface
  input  wire [3:0] oki_addr,
  input  wire [3:0] oki_rx_data,
  output wire [3:0] oki_tx_data,
  input  wire       oki_rd_n,
  input  wire       oki_rw_n,
  input  wire       oki_cs_n,
  output logic      oki_write_dirty,
  output wire       oki_write_valid,   // 1 if valid otherwise 0
  input  wire       oki_clear_dirty,
  output wire       oki_hold,         // 1 When the Hold bit is set
  // PCF interface for refreshing PCF data
  // Does not become readable until pcf_latch is pulsed
  input  wire [3:0] pcf_addr,
  input  wire [7:0] pcf_rx_data,
  output logic [7:0] pcf_tx_data,
  input  wire       pcf_wr_n,            // low is write
  input  wire       pcf_dv,            // active high
  input  wire       pcf_latch          // Latch written data to active buffer
);

// Data registers
logic  [7:0] pcf_read_reg    [0:15];
logic  [7:0] pcf_write_reg   [0:15];
logic  [7:0] pcf_tx_reg      [0:15];
logic  [7:0] pcf_refresh_reg [0:15];

// Mapped registers to output in OKI format
wire   [3:0] oki_read_wire   [0:15];

// status registers
logic        oki_status_busy;
logic        oki_status_hold;
logic  [1:0] oki_status_t;

assign oki_hold = oki_status_hold;

// Map pcf_read_reg to oki_read_wire
assign oki_read_wire[4'h0] = pcf_read_reg[2][3:0];  // Seconds 1
assign oki_read_wire[4'h1] = {1'b0, pcf_read_reg[2][6:4]};  // Secends 10
assign oki_read_wire[4'h2] = pcf_read_reg[3][3:0];  // Minutes 1
assign oki_read_wire[4'h3] = {1'b0, pcf_read_reg[3][6:4]};  // Minutes 10
assign oki_read_wire[4'h4] = pcf_read_reg[4][3:0];  // Hours 1
assign oki_read_wire[4'h5] = pcf_read_reg[0][2] ?  // pcf : 0 - 24 hour mode is selected
  {1'b0, pcf_read_reg[4][5], 1'b0, pcf_read_reg[4][4]} :  // Hours 10 + PM/AM (duplicated bit 5)
  {2'b00, pcf_read_reg[4][5:4]};  // 24 hour mode 0-2
assign oki_read_wire[4'h6] = pcf_read_reg[5][3:0];  // Days 1 (Of the month)
assign oki_read_wire[4'h7] = {2'b00, pcf_read_reg[5][5:4]};  // Days 10 (Of the month)
assign oki_read_wire[4'h8] = pcf_read_reg[7][3:0];  // Months 1
assign oki_read_wire[4'h9] = {3'b000, pcf_read_reg[7][4]};  // Months 10
assign oki_read_wire[4'hA] = pcf_read_reg[8][3:0];  // Years 1
assign oki_read_wire[4'hB] = pcf_read_reg[8][7:4];  // Years 10
assign oki_read_wire[4'hC] = {1'b0, pcf_read_reg[6][2:0]};  // Weekdays 1
assign oki_read_wire[4'hD] = {2'b0, oki_status_busy, oki_status_hold};  // Config register D
assign oki_read_wire[4'hE] = {oki_status_t, 2'b0};  // Config register E
assign oki_read_wire[4'hF] = {
    pcf_read_reg[0][7],  // Ext Test
    !pcf_read_reg[0][2],  // 12_24 ( Inverted between chips)
    pcf_read_reg[0][5],  // STOP
    1'b0
  };

// output OKI data
assign oki_tx_data = (oki_rd_n == 1'b0 && oki_rw_n == 1'b1 && oki_cs_n == 1'b0) ? oki_read_wire[oki_addr] : 4'h0;

// Read OKI register
always_ff @(posedge clk) begin

  if (rst_n == 1'b0) begin
    oki_write_dirty <= 1'b0;
    oki_status_busy <= 1'b0;
    oki_status_hold <= 1'b0;

    oki_status_t <= 2'b00;

    pcf_tx_data <= 8'h00;

    for (int loop = 0; loop < 16; loop++) begin
      pcf_read_reg[loop] <= 8'h00;
      pcf_write_reg[loop]   <= 8'h00;
      pcf_refresh_reg[loop] <= 8'h00;
      pcf_tx_reg[loop] <= 8'h00;
    end
  end else begin

    // On the latch copy to the PCF read register
    if (pcf_latch == 1'b1 && oki_write_dirty == 1'b0) begin
      for (int loop = 0; loop < 16; loop++) begin
        pcf_read_reg[loop] <= pcf_refresh_reg[loop];
      end
    end

    // When hold reg is high show the written status directly
    if (oki_status_hold == 1'b1) begin
      for (int loop = 0; loop < 16; loop++) begin
        pcf_read_reg[loop] <= pcf_write_reg[loop];
      end
    end

    if (oki_rd_n == 1'b1 && oki_rw_n == 1'b0 && oki_cs_n == 1'b0) begin
      // Handle a write action to the OKI RTC
      oki_status_busy <= 1'b1;
      case (oki_addr)
        4'h0: pcf_write_reg[2][3:0] <= oki_rx_data;  // Seconds 1
        4'h1: pcf_write_reg[2][7:4] <= {1'b0, oki_rx_data[2:0]};  // Seconds 10
        4'h2: pcf_write_reg[3][3:0] <= oki_rx_data;  // Minutes 1
        4'h3: pcf_write_reg[3][7:4] <= {1'b0, oki_rx_data[2:0]};  // Minutes 10
        4'h4: pcf_write_reg[4][3:0] <= oki_rx_data;  // Hours 1
        4'h5:
          pcf_write_reg[4][7:4] <= pcf_write_reg[0][2] ?        // Hours 10 (2412 = 1 = 12 hour format)
          {2'b00, oki_rx_data[2], oki_rx_data[0]} : { 2'b00, oki_rx_data[1:0]};
        4'h6: pcf_write_reg[5][3:0] <= oki_rx_data;  // Days 1 (Of the month)
        4'h7: pcf_write_reg[5][7:4] <= {2'b0, oki_rx_data[1:0]};  // Days 10 (Of the month)
        4'h8: pcf_write_reg[7][3:0] <= oki_rx_data;  // months 1
        4'h9: pcf_write_reg[7][7:4] <= {3'b000, oki_rx_data[0]};  // Months 10
        4'hA: pcf_write_reg[8][3:0] <= oki_rx_data;  // years 1
        4'hB: begin
          pcf_write_reg[8][7:4] <= oki_rx_data;  // years 10
          // Only when complete configuration is written, write out.
          oki_write_dirty <= 1'b1;
        end
        4'hC: pcf_write_reg[6][3:0] <= {1'h0, oki_rx_data[2:0]};  // weekday (0 - 6)
        4'hD: oki_status_hold <= oki_rx_data[0];  // Config register D
        4'hE: oki_status_t <= oki_rx_data[1:0];  // Config register E
        4'hF: begin
          pcf_write_reg[0][5] <= oki_rx_data[1];  // STOP
          pcf_write_reg[0][2] <= !oki_rx_data[2];  // 12_24 (Enverted between chips)
        end
      endcase
    end else if (pcf_latch == 1'b1 && oki_write_dirty == 1'b0 && oki_status_hold == 1'b0) begin
      // When latch is pulsed,
      for (int loop = 0; loop < 15; loop++) begin
        pcf_write_reg[loop] <= pcf_refresh_reg[loop];
      end
    end else if (oki_clear_dirty == 1'b1) begin
      // Clear the dirty flag and make altered data available for reading
      oki_write_dirty <= 1'b0;  // Clear flag
      for (int loop = 0; loop < 16; loop++) begin
        pcf_tx_reg[loop] <= pcf_write_reg[loop];
      end
    end

    // Write to the PCF registers
    if (pcf_dv == 1'b1 && pcf_wr_n == 1'b0) begin
      pcf_refresh_reg[pcf_addr] <= pcf_rx_data;
    end

    // Read from the PCF registers
    // Latched when the oki_clear_dirty strobe is given
    if (pcf_wr_n == 1'b1) begin
      pcf_tx_data <= pcf_tx_reg[pcf_addr];
    end
  end
end

// BCD encoded day of the month and month of the year cannot be be 0x00
assign oki_write_valid = pcf_write_reg[7] != 8'h00 && pcf_write_reg[5] != 8'h00;

// CocoTB test block
`ifdef COCOTB_SIM
// Put pcf_write_reg array values in separate buses to aide debugging
wire [7:0] pcf_read_reg_0,
pcf_read_reg_1,
pcf_read_reg_2,
pcf_read_reg_3,
pcf_read_reg_4,
pcf_read_reg_5;

assign pcf_read_reg_0 = pcf_read_reg[0];
assign pcf_read_reg_1 = pcf_read_reg[1];
assign pcf_read_reg_2 = pcf_read_reg[2];
assign pcf_read_reg_3 = pcf_read_reg[3];
assign pcf_read_reg_4 = pcf_read_reg[4];
assign pcf_read_reg_5 = pcf_read_reg[5];

// Create GTKWave dump file
initial begin
  $dumpfile("dump.vcd");
  $dumpvars(1, oki_pcf_buffer);
end
`endif

endmodule
