//-----------------------------------------------------------------
//              Lightweight DDR3 Memory Controller
//                            V0.5
//                     Ultra-Embedded.com
//                     Copyright 2020-21
//
//                   admin@ultra-embedded.com
//
//                     License: Apache 2.0
//-----------------------------------------------------------------
// Copyright 2020-21 Ultra-Embedded.com
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//-----------------------------------------------------------------

module ddr3_core
//-----------------------------------------------------------------
// Params
//-----------------------------------------------------------------
#(
      parameter DDR_MHZ           = 25
    , parameter DDR_WRITE_LATENCY = 6
    , parameter DDR_READ_LATENCY  = 5
    , parameter DDR_COL_W         = 10
    , parameter DDR_BANK_W        = 3
    , parameter DDR_ROW_W         = 15
    , parameter DDR_BRC_MODE      = 0
)
//-----------------------------------------------------------------
// Ports
//-----------------------------------------------------------------
(
    // Control Signals
    // Inputs
    input         clk_i,                // Clock input
    input         rst_i,                // Reset input
    input         cfg_enable_i,         // Configuration enable signal
    input         cfg_stb_i,            // Configuration strobe/input valid signal
    input [ 31:0] cfg_data_i,           // Configuration data input
    input [ 15:0] inport_wr_i,          // Write enable signal for the input port
    input         inport_rd_i,          // Read enable signal for the input port
    input [ 31:0] inport_addr_i,        // Address for the input port
    input [127:0] inport_write_data_i,  // Write data for the input port
    input [ 15:0] inport_req_id_i,      // Request ID for the input port

    // Outputs
    output         init_done_o,        // LOCAL ADDITION (not upstream): high once the
                                       // power-up / mode-register init sequence has finished
                                       // (state_q != STATE_INIT). See README.md.
    output         cfg_stall_o,        // Configuration stall/output not ready signal
    output         inport_accept_o,    // Input port accept signal
    output         inport_ack_o,       // Input port acknowledge signal
    output         inport_error_o,     // Input port error signal
    output [ 15:0] inport_resp_id_o,   // Response ID for the input port
    output [127:0] inport_read_data_o, // Read data for the input port

    // DDR3 IO Signals
    // Inputs
    input [31:0] dfi_rddata_i,        // Data read from DDR3
    input        dfi_rddata_valid_i,  // Indicates if the read data is valid
    input [ 1:0] dfi_rddata_dnv_i,    // Indicates if the read data is not valid due to an error

    // Outputs
    output [14:0] dfi_address_o,      // Address to DDR3
    output [ 2:0] dfi_bank_o,         // Bank address to DDR3
    output        dfi_cas_n_o,        // CAS (Column Address Strobe) signal to DDR3
    output        dfi_cke_o,          // Clock enable signal to DDR3
    output        dfi_cs_n_o,         // Chip select signal to DDR3
    output        dfi_odt_o,          // On-die termination control signal to DDR3
    output        dfi_ras_n_o,        // RAS (Row Address Strobe) signal to DDR3
    output        dfi_reset_n_o,      // Reset signal to DDR3
    output        dfi_we_n_o,         // WE (Write Enable) signal to DDR3
    output [31:0] dfi_wrdata_o,       // Write data to DDR3
    output        dfi_wrdata_en_o,    // Write data enable signal to DDR3
    output [ 3:0] dfi_wrdata_mask_o,  // Write data mask to DDR3
    output        dfi_rddata_en_o     // Read data enable signal from DDR3
);


  //-----------------------------------------------------------------
  // Defines / Local params
  //-----------------------------------------------------------------
  localparam DDR_BANKS = 2 ** DDR_BANK_W;
`ifdef XILINX_SIMULATOR
  localparam DDR_START_DELAY = 60000 / (1000 / DDR_MHZ);  // 60uS
`else
  localparam DDR_START_DELAY = 600000 / (1000 / DDR_MHZ);  // 600uS
`endif
  localparam DDR_REFRESH_CYCLES = (64000 * DDR_MHZ) / 8192;
  localparam DDR_BURST_LEN = 8;

  localparam CMD_W = 4;  // Command byte width
  typedef enum logic [3:0] {
    CMD_LOAD_MODE = 4'b0000,
    CMD_REFRESH   = 4'b0001,
    CMD_PRECHARGE = 4'b0010,
    CMD_ACTIVE    = 4'b0011,
    CMD_WRITE     = 4'b0100,
    CMD_READ      = 4'b0101,
    CMD_ZQCL      = 4'b0110,
    CMD_NOP       = 4'b0111
  } cmd_t;

  // Mode Configuration
  // - DLL disabled (low speed only)
  // - CL=6
  // - AL=0
  // - CWL=6
  localparam MR0_REG = 15'h0120;
  localparam MR1_REG = 15'h0001;
  localparam MR2_REG = 15'h0008;
  localparam MR3_REG = 15'h0000;

  // SM states
  typedef enum {
    STATE_INIT,
    STATE_DELAY,
    STATE_IDLE,
    STATE_ACTIVATE,
    STATE_READ,
    STATE_WRITE,
    STATE_PRECHARGE,
    STATE_REFRESH
  } state_t;

  localparam AUTO_PRECHARGE = 10;
  localparam ALL_BANKS = 10;

  //-----------------------------------------------------------------
  // External Interface
  //-----------------------------------------------------------------
  wire [31:0] ram_addr_w = inport_addr_i;
  wire [15:0] ram_wr_w = inport_wr_i;
  wire ram_rd_w = inport_rd_i;
  wire ram_accept_w;
  wire [127:0] ram_write_data_w = inport_write_data_i;
  wire [127:0] ram_read_data_w;
  wire ram_ack_w;

  wire id_fifo_space_w;
  wire ram_req_w = ((ram_wr_w != 16'b0) | ram_rd_w) && id_fifo_space_w;

  assign inport_ack_o       = ram_ack_w;
  assign inport_read_data_o = ram_read_data_w;
  assign inport_error_o     = 1'b0;
  assign inport_accept_o    = ram_accept_w;

  //-----------------------------------------------------------------
  // Registers / Wires
  //-----------------------------------------------------------------
  wire cmd_accept_w;

  wire sdram_rd_valid_w;
  wire [127:0] sdram_data_in_w;

  reg refresh_q;

  reg [DDR_BANKS-1:0] row_open_q;
  reg [DDR_ROW_W-1:0] active_row_q[0:DDR_BANKS-1];

  state_t state_q;
  state_t next_state_r;
  state_t target_state_r;
  state_t target_state_q;

  // Address bits (RBC mode)
  wire [DDR_ROW_W-1:0] addr_col_w = {
    {(DDR_ROW_W - DDR_COL_W) {1'b0}}, ram_addr_w[DDR_COL_W:2], 1'b0
  };
  wire [DDR_ROW_W-1:0]  addr_row_w  = DDR_BRC_MODE ? ram_addr_w[DDR_ROW_W+DDR_COL_W:DDR_COL_W+1] :            // BRC
  ram_addr_w[DDR_ROW_W+DDR_COL_W+3:DDR_COL_W+3+1];  // RBC
  wire [DDR_BANK_W-1:0] addr_bank_w = DDR_BRC_MODE ? ram_addr_w[DDR_ROW_W+DDR_COL_W+3:DDR_ROW_W+DDR_COL_W+1]: // BRC
  ram_addr_w[DDR_COL_W+1+3-1:DDR_COL_W+1];  // RBC

  //-----------------------------------------------------------------
  // SDRAM State Machine
  //-----------------------------------------------------------------
  always_comb begin
    next_state_r   = state_q;
    target_state_r = target_state_q;

    case (state_q)
      //-----------------------------------------
      // STATE_INIT
      //-----------------------------------------
      STATE_INIT: begin
        if (refresh_q) next_state_r = STATE_IDLE;
      end
      //-----------------------------------------
      // STATE_IDLE
      //-----------------------------------------
      STATE_IDLE: begin
        // Disabled
        if (!cfg_enable_i) next_state_r = STATE_IDLE;
        // Pending refresh
        // Note: tRAS (open row time) cannot be exceeded due to periodic
        //        auto refreshes.
        else if (refresh_q) begin
          // Close open rows, then refresh
          if (|row_open_q) next_state_r = STATE_PRECHARGE;
          else next_state_r = STATE_REFRESH;

          target_state_r = STATE_REFRESH;
        end  // Access request
        else if (ram_req_w) begin
          // Open row hit
          if (row_open_q[addr_bank_w] && addr_row_w == active_row_q[addr_bank_w]) begin
            if (!ram_rd_w) next_state_r = STATE_WRITE;
            else next_state_r = STATE_READ;
          end  // Row miss, close row, open new row
          else if (row_open_q[addr_bank_w]) begin
            next_state_r = STATE_PRECHARGE;

            if (!ram_rd_w) target_state_r = STATE_WRITE;
            else target_state_r = STATE_READ;
          end  // No open row, open row
          else begin
            next_state_r = STATE_ACTIVATE;

            if (!ram_rd_w) target_state_r = STATE_WRITE;
            else target_state_r = STATE_READ;
          end
        end
      end
      //-----------------------------------------
      // STATE_ACTIVATE
      //-----------------------------------------
      STATE_ACTIVATE: begin
        // Proceed to read or write state
        next_state_r = target_state_q;
      end
      //-----------------------------------------
      // STATE_READ
      //-----------------------------------------
      STATE_READ: begin
        next_state_r = STATE_IDLE;
      end
      //-----------------------------------------
      // STATE_WRITE
      //-----------------------------------------
      STATE_WRITE: begin
        next_state_r = STATE_IDLE;
      end
      //-----------------------------------------
      // STATE_PRECHARGE
      //-----------------------------------------
      STATE_PRECHARGE: begin
        // Closing row to perform refresh
        if (target_state_q == STATE_REFRESH) next_state_r = STATE_REFRESH;
        // Must be closing row to open another
        else
          next_state_r = STATE_ACTIVATE;
      end
      //-----------------------------------------
      // STATE_REFRESH
      //-----------------------------------------
      STATE_REFRESH: begin
        next_state_r = STATE_IDLE;
      end
      default: ;
    endcase
  end

  // Record target state
  always_ff @(posedge clk_i)
    if (rst_i) target_state_q <= STATE_IDLE;
    else if (cmd_accept_w) target_state_q <= target_state_r;

  // Update state
  always_ff @(posedge clk_i)
    if (rst_i) state_q <= STATE_INIT;
    else if (cmd_accept_w) state_q <= next_state_r;

  //-----------------------------------------------------------------
  // Refresh counter
  //-----------------------------------------------------------------
  localparam REFRESH_CNT_W = 20;

  reg [REFRESH_CNT_W-1:0] refresh_timer_q;
  always_ff @(posedge clk_i)
    if (rst_i) refresh_timer_q <= DDR_START_DELAY;
    else if (refresh_timer_q == {REFRESH_CNT_W{1'b0}}) refresh_timer_q <= DDR_REFRESH_CYCLES;
    else refresh_timer_q <= refresh_timer_q - 1;

  always_ff @(posedge clk_i)
    if (rst_i) refresh_q <= 1'b0;
    else if (refresh_timer_q == {REFRESH_CNT_W{1'b0}}) refresh_q <= 1'b1;
    else if (state_q == STATE_REFRESH) refresh_q <= 1'b0;

  //-----------------------------------------------------------------
  // Bank Logic
  //-----------------------------------------------------------------
  integer idx;

  always_ff @(posedge clk_i)
    if (rst_i) begin
      for (idx = 0; idx < DDR_BANKS; idx = idx + 1) active_row_q[idx] <= {DDR_ROW_W{1'b0}};

      row_open_q <= {DDR_BANKS{1'b0}};
    end else begin
      case (state_q)
        //-----------------------------------------
        // STATE_IDLE / Default (delays)
        //-----------------------------------------
        default: begin
          if (!cfg_enable_i) row_open_q <= {DDR_BANKS{1'b0}};
        end
        //-----------------------------------------
        // STATE_ACTIVATE
        //-----------------------------------------
        STATE_ACTIVATE: begin
          active_row_q[addr_bank_w] <= addr_row_w;
          row_open_q[addr_bank_w]   <= 1'b1;
        end
        //-----------------------------------------
        // STATE_PRECHARGE
        //-----------------------------------------
        STATE_PRECHARGE: begin
          // Precharge due to refresh, close all banks
          if (target_state_q == STATE_REFRESH) begin
            // Precharge all banks
            row_open_q <= {DDR_BANKS{1'b0}};
          end else begin
            // Precharge specific banks
            row_open_q[addr_bank_w] <= 1'b0;
          end
        end
      endcase
    end

  //-----------------------------------------------------------------
  // Command
  //-----------------------------------------------------------------
  cmd_t                  command_r;
  reg   [ DDR_ROW_W-1:0] addr_r;
  reg                    cke_r;
  reg   [DDR_BANK_W-1:0] bank_r;

  always_comb begin
    command_r = CMD_NOP;
    addr_r    = {DDR_ROW_W{1'b0}};
    bank_r    = {DDR_BANK_W{1'b0}};
    cke_r     = 1'b1;

    case (state_q)
      //-----------------------------------------
      // STATE_INIT
      //-----------------------------------------
      STATE_INIT: begin
        // Assert CKE after 500uS
        if (refresh_timer_q > 2500) cke_r = 1'b0;

        if (refresh_timer_q == 2400) begin
          command_r = CMD_LOAD_MODE;
          bank_r    = 3'd2;
          addr_r    = MR2_REG;
        end

        if (refresh_timer_q == 2300) begin
          command_r = CMD_LOAD_MODE;
          bank_r    = 3'd3;
          addr_r    = MR3_REG;
        end

        if (refresh_timer_q == 2200) begin
          command_r = CMD_LOAD_MODE;
          bank_r    = 3'd1;
          addr_r    = MR1_REG;
        end

        if (refresh_timer_q == 2100) begin
          command_r = CMD_LOAD_MODE;
          bank_r    = 3'd0;
          addr_r    = MR0_REG;
        end

        // Long ZQ calibration
        if (refresh_timer_q == 2000) begin
          command_r  = CMD_ZQCL;
          addr_r[10] = 1;
        end

        // ---

        // PRECHARGE
        if (refresh_timer_q == 10) begin
          // Precharge all banks
          command_r         = CMD_PRECHARGE;
          addr_r[ALL_BANKS] = 1'b1;
        end
      end
      //-----------------------------------------
      // STATE_IDLE
      //-----------------------------------------
      STATE_IDLE: begin
        if (!cfg_enable_i && cfg_stb_i)
          {cke_r, addr_r, bank_r, command_r} = cfg_data_i[CMD_W+DDR_ROW_W+DDR_BANK_W:0];
      end
      //-----------------------------------------
      // STATE_ACTIVATE
      //-----------------------------------------
      STATE_ACTIVATE: begin
        // Select a row and activate it
        command_r = CMD_ACTIVE;
        addr_r    = addr_row_w;
        bank_r    = addr_bank_w;
      end
      //-----------------------------------------
      // STATE_PRECHARGE
      //-----------------------------------------
      STATE_PRECHARGE: begin
        // Precharge due to refresh, close all banks
        if (target_state_r == STATE_REFRESH) begin
          // Precharge all banks
          command_r         = CMD_PRECHARGE;
          addr_r[ALL_BANKS] = 1'b1;
        end else begin
          // Precharge specific banks
          command_r         = CMD_PRECHARGE;
          addr_r[ALL_BANKS] = 1'b0;
          bank_r            = addr_bank_w;
        end
      end
      //-----------------------------------------
      // STATE_REFRESH
      //-----------------------------------------
      STATE_REFRESH: begin
        // Auto refresh
        command_r = CMD_REFRESH;
        addr_r    = {DDR_ROW_W{1'b0}};
        bank_r    = {DDR_BANK_W{1'b0}};
      end
      //-----------------------------------------
      // STATE_READ
      //-----------------------------------------
      STATE_READ: begin
        command_r              = CMD_READ;
        addr_r                 = {addr_col_w[DDR_ROW_W-1:3], 3'b0};
        bank_r                 = addr_bank_w;

        // Disable auto precharge (auto close of row)
        addr_r[AUTO_PRECHARGE] = 1'b0;
      end
      //-----------------------------------------
      // STATE_WRITE
      //-----------------------------------------
      STATE_WRITE: begin
        command_r              = CMD_WRITE;
        addr_r                 = {addr_col_w[DDR_ROW_W-1:3], 3'b0};
        bank_r                 = addr_bank_w;

        // Disable auto precharge (auto close of row)
        addr_r[AUTO_PRECHARGE] = 1'b0;
      end
      default: ;
    endcase
  end

  //-----------------------------------------------------------------
  // ACK
  //-----------------------------------------------------------------
  reg write_ack_q;

  always_ff @(posedge clk_i)
    if (rst_i) write_ack_q <= 1'b0;
    else write_ack_q <= (state_q == STATE_WRITE) && cmd_accept_w;

  ddr3_fifo #(
        .WIDTH (16)
      , .DEPTH (8)
      , .ADDR_W(3)
  ) u_id_fifo (
        .clk_i(clk_i)
      , .rst_i(rst_i)

      , .push_i(ram_req_w & ram_accept_w)
      , .data_in_i(inport_req_id_i)
      , .accept_o(id_fifo_space_w)

      , .valid_o()
      , .data_out_o(inport_resp_id_o)
      , .pop_i(ram_ack_w)
  );

  assign ram_ack_w = sdram_rd_valid_w || write_ack_q;

  // Accept command in READ or WRITE0 states
  assign ram_accept_w = (state_q == STATE_READ || state_q == STATE_WRITE) && cmd_accept_w;

  // Config stall
  assign cfg_stall_o = ~(state_q == STATE_IDLE && cmd_accept_w);

  // LOCAL ADDITION (not upstream): initialisation complete.
  // STATE_INIT is entered on reset and left exactly once, when the power-up delay,
  // ZQCL and the four mode-register writes have all been issued.
  assign init_done_o = (state_q != STATE_INIT);

  //-----------------------------------------------------------------
  // DDR3 DFI Interface
  //-----------------------------------------------------------------
  ddr3_dfi_seq #(
      .DDR_MHZ(DDR_MHZ)
      , .DDR_WRITE_LATENCY(DDR_WRITE_LATENCY)
      , .DDR_READ_LATENCY(DDR_READ_LATENCY)
  ) u_seq (
        .clk_i(clk_i)
      , .rst_i(rst_i)

      , .address_i(addr_r)
      , .bank_i(bank_r)
      , .command_i(command_r)
      , .cke_i(cke_r)
      , .accept_o(cmd_accept_w)

      , .wrdata_i(ram_write_data_w)
      , .wrdata_mask_i(~ram_wr_w)

      , .rddata_valid_o(sdram_rd_valid_w)
      , .rddata_o(sdram_data_in_w)

      , .dfi_address_o(dfi_address_o)
      , .dfi_bank_o(dfi_bank_o)
      , .dfi_cas_n_o(dfi_cas_n_o)
      , .dfi_cke_o(dfi_cke_o)
      , .dfi_cs_n_o(dfi_cs_n_o)
      , .dfi_odt_o(dfi_odt_o)
      , .dfi_ras_n_o(dfi_ras_n_o)
      , .dfi_reset_n_o(dfi_reset_n_o)
      , .dfi_we_n_o(dfi_we_n_o)
      , .dfi_wrdata_o(dfi_wrdata_o)
      , .dfi_wrdata_en_o(dfi_wrdata_en_o)
      , .dfi_wrdata_mask_o(dfi_wrdata_mask_o)
      , .dfi_rddata_en_o(dfi_rddata_en_o)
      , .dfi_rddata_i(dfi_rddata_i)
      , .dfi_rddata_valid_i(dfi_rddata_valid_i)
      , .dfi_rddata_dnv_i(dfi_rddata_dnv_i)
  );

  // Read data output
  assign ram_read_data_w = sdram_data_in_w;

  //-----------------------------------------------------------------
  // Simulation only
  //-----------------------------------------------------------------
`ifdef verilator
  reg [79:0] dbg_state;

  always_comb begin
    case (state_q)
      STATE_INIT:      dbg_state = "INIT";
      STATE_DELAY:     dbg_state = "DELAY";
      STATE_IDLE:      dbg_state = "IDLE";
      STATE_ACTIVATE:  dbg_state = "ACTIVATE";
      STATE_READ:      dbg_state = "READ";
      STATE_WRITE:     dbg_state = "WRITE";
      STATE_PRECHARGE: dbg_state = "PRECHARGE";
      STATE_REFRESH:   dbg_state = "REFRESH";
      default:         dbg_state = "UNKNOWN";
    endcase
  end
`endif


endmodule

//-----------------------------------------------------------------
// FIFO
//-----------------------------------------------------------------
module ddr3_fifo

//-----------------------------------------------------------------
// Params
//-----------------------------------------------------------------
#(
    parameter WIDTH  = 8,
    parameter DEPTH  = 4,
    parameter ADDR_W = 2
)
//-----------------------------------------------------------------
// Ports
//-----------------------------------------------------------------
(
    // Inputs
      input             clk_i
    , input             rst_i
    , input [WIDTH-1:0] data_in_i
    , input             push_i
    , input             pop_i

    // Outputs
    , output [WIDTH-1:0] data_out_o
    , output             accept_o
    , output             valid_o
);

  //-----------------------------------------------------------------
  // Local Params
  //-----------------------------------------------------------------
  localparam COUNT_W = ADDR_W + 1;

  //-----------------------------------------------------------------
  // Registers
  //-----------------------------------------------------------------
  reg [  WIDTH-1:0] ram    [DEPTH-1:0];
  reg [ ADDR_W-1:0] rd_ptr;
  reg [ ADDR_W-1:0] wr_ptr;
  reg [COUNT_W-1:0] count;

  //-----------------------------------------------------------------
  // Sequential
  //-----------------------------------------------------------------
  always_ff @(posedge clk_i)
    if (rst_i) begin
      count  <= {(COUNT_W) {1'b0}};
      rd_ptr <= {(ADDR_W) {1'b0}};
      wr_ptr <= {(ADDR_W) {1'b0}};
    end else begin
      // Push
      if (push_i & accept_o) begin
        ram[wr_ptr] <= data_in_i;
        wr_ptr      <= wr_ptr + 1;
      end

      // Pop
      if (pop_i & valid_o) rd_ptr <= rd_ptr + 1;

      // Count up
      if ((push_i & accept_o) & ~(pop_i & valid_o)) count <= count + 1;
      // Count down
      else if (~(push_i & accept_o) & (pop_i & valid_o)) count <= count - 1;
    end

  //-------------------------------------------------------------------
  // Combinatorial
  //-------------------------------------------------------------------
  /* verilator lint_off WIDTH */
  assign accept_o   = (count != DEPTH);
  assign valid_o    = (count != 0);
  /* verilator lint_on WIDTH */

  assign data_out_o = ram[rd_ptr];



endmodule
