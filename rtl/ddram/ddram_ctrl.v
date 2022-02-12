`timescale 1ns/100ps

//////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////
//                                                                          //
// Copyright (c) 2009/2011 Tobias Gubener                                   //
// Subdesign fAMpIGA by TobiFlex                                            //
//                                                                          //
// This source file is free software: you can redistribute it and/or modify //
// it under the terms of the GNU General Public License as published        //
// by the Free Software Foundation, either version 3 of the License, or     //
// (at your option) any later version.                                      //
//                                                                          //
// This source file is distributed in the hope that it will be useful,      //
// but WITHOUT ANY WARRANTY; without even the implied warranty of           //
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            //
// GNU General Public License for more details.                             //
//                                                                          //
// You should have received a copy of the GNU General Public License        //
// along with this program.  If not, see <http://www.gnu.org/licenses/>.    //
//                                                                          //
//////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////


module ddram_ctrl(
    // system
    input  wire           sysclk,
    input  wire           reset_in,
    input  wire           cache_rst,
    input  wire           cache_inhibit,
    input  wire           cacheline_clr,
    input  wire [  4-1:0] cpu_cache_ctrl,
    output wire           reset_out,

    // DDR3 
    output wire          DDR3_CK_P_O,
    output wire          DDR3_CK_N_O,
    output wire          DDR3_CKE_O,
    output wire          DDR3_RESET_N_O,
    output wire          DDR3_RAS_N_O,
    output wire          DDR3_CAS_N_O,
    output wire          DDR3_WE_N_O,
    output wire          DDR3_CS_N_O,
    output wire [  2:0]  DDR3_BA_O,
    output wire [ 13:0]  DDR3_ADDR_O,
    output wire          DDR3_ODT_O,
    output wire [  1:0]  DDR3_DM_O,
    inout wire  [  1:0]  DDR3_DQS_P_IO,
    inout wire  [  1:0]  DDR3_DQS_N_IO,
    inout wire  [ 15:0]  DDR3_DQ_IO,

    // DDR3 Core interface
    // input wire             ram_accept,
    // input wire             ram_ack,
    // input wire             ram_error,
    // input wire  [   15:0]  ram_resp_id,
    // input wire  [  127:0]  ram_read_data,
    // output wire [   15:0]  ram_wr,
    // output wire            ram_rd,
    // output wire [   31:0]  ram_addr,
    // output wire [  127:0]  ram_write_data,
    // output wire [   15:0]  ram_req_id,

    // cpu
    input  wire    [25:1] cpuAddr,
    input  wire [  7-1:0] cpustate,
    input  wire           cpuL,
    input  wire           cpuU,
    input  wire [ 16-1:0] cpuWR,
    output wire [ 16-1:0] cpuRD,
    output wire           cpuena
);

    // From TG68K.vhd line 301

    // Second block of ZIII RAM - 32 meg from 0x42000000 - 0x43ffffff

    //  On 64-meg platforms we need an extra 32 meg merged into the memory map.
    //  If we configure that range second, it should end up in 42000000 - 43ffffff
    //  so the extra 2 or 4 meg will end up at either 41000000 or 4400000, depending
    //  on whether the extra 32 meg is configured.

    // CPU state register
    // cpustate <= longword&clkena&slower(1 downto 0)&ramcs&state(1 downto 0);
    //
    // cpu bus time sharing based on cpustate
    // cpustate <= longword&clkena&slower(1 downto 0)&ramcs&state(1 downto 0)
    // cpu_we       : 7'bxxxxx11;
    // cpu_ir       : 7'bxxxxx00;
    // cpu_dr       : 7'bxxxxx10;
    // cpuLongword  : 7'b1xxxxxx;
    // cpuCSn       : 7'bxxxx0xx;
    // cpuLongword = cpustate[6];
    // cpuCSn      = cpustate[2];

    //// parameters ////

    //// local signals ////
    reg  [16-1:0] sdr_dat_r;
    (* IOB="FORCE" *)
    reg  [16-1:0] sdata_out;
    reg           sdata_oe;
    wire          cpu_ack;
    wire          cpuCSn;
    //reg  [ 8-1:0] hostslot_cnt;
    reg  [ 8-1:0] reset_cnt;
    reg           reset;
    // writebuffer
    wire          sdr_read_req;
    reg           sdr_read_ack;
    wire          sdr_write_req;
    wire [26-1:1] sdr_adr;
    wire [32-1:0] sdr_dat_w;
    wire [ 4-1:0] sdr_dqm_w;
    reg           sdr_write_ack;

    reg  [26-1:1] cpuAddr_r; // registered CPU address - cpuAddr must be stable one cycle before cpuCSn

    wire          cpuLongword;

    ////////////////////////////////////////
    // misc signals
    ////////////////////////////////////////

    // Latch the Address
    always @(posedge sysclk) cpuAddr_r <= cpuAddr;

    // Chip select, active low
    assign cpuCSn      = cpustate[2];

    ////////////////////////////////////////
    // reset
    ////////////////////////////////////////

    always @(posedge sysclk) begin
        if(!reset_in) begin
            reset_cnt       <= #1 8'b00000000;
            reset           <= #1 1'b0;
        end
        else begin
            if(reset_cnt == 8'b10101010) begin
                reset       <= #1 1'b1;
            end
            else begin
                reset_cnt     <= #1 reset_cnt + 8'd1;
                reset         <= #1 1'b0;
            end
        end
    end

    assign reset_out = reset;


    ////////////////////////////////////////
    // cpu cache
    ////////////////////////////////////////

    // cpu interface
    // Read cycle
    // • S0: Address bus is in high impedance state, R/W is set to 1 (read operation).
    // • S1: Valid address appears on address bus.
    // • S2: AS goes low (valid address), LDS and UDS are set to the desired state.
    // • S3,S4: Minimum time given to memory to signal with DTACK=0.
    // • S5: µP looks for DTACK=0.
    //   – if DTACK=1, insert two wait states then test DTACK again.
    //   – if DTACK=0, continue with S6 and S7.
    // • S6: Nothing new happens.
    // • S7: Latch data into µP, set AS, UDS, and LDS to 1. Memory releases DTACK
    //
    // Write cycle
    // • S0: Address bus is in high impedance state.
    // • S1: Valid address appears on address bus.
    // • S2: AS goes low (valid address), R/W is set to 0 (write operation). (LDS and UDS are delayed to allow the bus transceivers to switch direction, and to allow the memory time to prepare.)
    // • S3: Valid data is placed on the bus by the µP.
    // • S4: LDS and UDS are set to the desired state.
    // • S5: µP looks for DTACK=0.
    //   – if DTACK=1, insert two wait states then test DTACK again.
    //   – if DTACK=0, continue with S6 and S7.
    // • S6: Nothing new happens.
    // • S7: Set AS, UDS, and LDS to 1. Memory releases DTACK

    //// cpu cache ////
    cpu_cache_new cpu_cache (
        .clk              (sysclk), // clock
        .rst              (!reset || !cache_rst), // cache reset
        .cache_en         (1'b1), // cache enable
        // CPU interface
        .cpu_cache_ctrl   (cpu_cache_ctrl), // CPU cache control (IN)
        .cache_inhibit    (1'b0), // cache inhibit (IN)
        .cacheline_clr    (1'b0), // cacheline clear (IN)
        .cpu_cs           (!cpuCSn), // cpu chip select, active high (IN)
        .cpu_adr          ({cpuAddr, 1'b0}), // cpu address bus (IN)
        .cpu_bs           ({!cpuU, !cpuL}), // cpu byte selects (IN)
        .cpu_32bit        (longword_en), // cpu 32 bit write active high (IN)
        .cpu_we           (&cpustate[1:0]), // cpu write (IN)
        .cpu_ir           (!(|cpustate[1:0])), // cpu instruction read (IN)
        .cpu_dr           (cpustate[1] && !cpustate[0]), // cpu data read (IN)
        .cpu_dat_w        (cpuWR), // cpu write data (IN)
        .cpu_dat_r        (cpuRD), // cpu rea1d data (OUT)
        .cpu_ack          (cpu_ack), // cpu acknowledge, low when busy, 1 when done (OUT)
        // Interface to SDRAM phy
        .sdr_dat_r        (sdr_dat_r), // sdram read data (IN)
        .sdr_read_req     (sdr_read_req), // sdram read request from cache (OUT)
        .sdr_read_ack     (sdr_read_ack), // sdram read acknowledge to cache (IN)
        .sdr_adr          (sdr_adr), // sdram address (OUT)
        .sdr_dat_w        (sdr_dat_w), // sdram write data (OUT)
        .sdr_dqm_w        (sdr_dqm_w), // sdram write byte selects (OUT)
        .sdr_write_req    (sdr_write_req), // write buffer request (OUT)
        .sdr_write_ack    (sdr_write_ack), // Write ack (IN)
        // Snoop on chipram bus, to update values in cache
        .snoop_act        (1'b0), // snoop act, active high (write only - just update existing data in cache) (IN)
        .snoop_adr        ('b0), // snoop address (IN)
        .snoop_dat_w      (32'h0), // snoop write data (IN)
        .snoop_bs         ('b0) // Snoop byte select, active low (IN)
    );

    // Tell the cpu to continue after data fetch from memory
    assign longword_en = cpuLongword && cpuAddr_r[3:1]!=3'b111 && cpustate[1:0]==2'b11;
    assign cpuena = cpu_ack;

    //// ddr3 core interface ////

    // Read cycleo
    //
    // ram_addr        __<00000010                   \       ><            >
    // ram_req_id      __<0004                       /       ><0005        >
    // ram_rd          __/¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯\____ \ _____________________
    // ram_accept      ______________________/¯\____ / _____________________
    // ram_ack         _____________________________ \ ____/¯\______________
    // ram_read_data   _____________________________ /     ><'128-bit value'>

    // Write cycle
    //
    // ram_addr        __<00000010                   \       ><            >
    // ram_req_id      __<0004                       /       ><0005        >
    // ram_wr          __<FFFF                 >_____\ _____________________
    // ram_accept      ______________________/¯\____ / _____________________
    // ram_ack         _____________________________ \ ____/¯\______________
    // ram_write_data  __<'128-bit value'                    >______________

    //// ddr3 core interface registers ////
    reg  [ 15:0] ram_cur_id_q = 16'h0; // Current request ID
    reg  [ 15:0] ram_req_id_out_q = 16'h0; // request id core commands
    reg  [ 31:0] ram_addr_q = 32'b0; // core address bus
    reg  [ 31:0] ram_addr_out_q = 32'b0; // core address bus
    reg          ram_rd_q = 1'b0; // read core command
    reg  [ 15:0] ram_wr_q = 16'b0; // write mask / core command ah
    reg  [ 15:0] ram_wr_out_q = 16'b0; // write mask / core command ah
    wire [ 127:0] ram_write_data; // core data bus
    reg  [ 8-1:0] ram_write_data_l_q [0:8]; // core data bus
    reg  [ 8-1:0] ram_write_data_h_q [0:8]; // core data bus
    reg           ram_write_data_dirty = 1'b0; // Data waiting in buffer to be written
    reg  [ 127:0] ram_write_data_out_q = 128'b0; // core data bus

    // 128 bit read cache to make reads more efficient
    // This is because the cache only supports 16-bit

    // Concatenates the cache registers
    assign ram_wire_data = {
    ram_write_data_h_q[7],
    ram_write_data_l_q[7],
    ram_write_data_h_q[6],
    ram_write_data_l_q[6],
    ram_write_data_h_q[5],
    ram_write_data_l_q[5],
    ram_write_data_h_q[4],
    ram_write_data_l_q[4],
    ram_write_data_h_q[3],
    ram_write_data_l_q[3],
    ram_write_data_h_q[2],
    ram_write_data_l_q[2],
    ram_write_data_h_q[1],
    ram_write_data_l_q[1],
    ram_write_data_h_q[0],
    ram_write_data_l_q[0]
    };

    // ddr3_core interface
    wire            ram_accept;
    wire            ram_ack;
    wire            ram_error;
    wire [   15:0]  ram_resp_id;
    wire [  127:0]  ram_read_data;
    wire [   15:0]  ram_wr;
    wire            ram_rd;
    wire [   31:0]  ram_addr;
    wire [  127:0]  ram_write_data;
    wire [   15:0]  ram_req_id;

    // Controller FSM
    parameter DDR3_FSM_INIT    = 0; // Entry state
    parameter DDR3_FSM_IDLE    = 1; // Idle state
    parameter DDR3_FSM_READ    = 3; // Read state
    parameter DDR3_FSM_READ_1  = 4; // Read state 1
    parameter DDR3_FSM_READ_2  = 5; // Read state 2
    parameter DDR3_FSM_WRITE   = 6; // Write state
    parameter DDR3_FSM_WRITE_1 = 7; // Write state 1
    parameter DDR3_FSM_WRITE_2 = 8; // Write state 2
    reg [3:0] controller_state_q = 0;
    reg [3:0] dat_offset_q = 0;
    reg       inhibit_sdr_ack_q = 1'b0;
    integer   i, j;

    always @(posedge sysclk) begin
        if (!reset) begin
            // Reset the command lines
            ram_rd_q <= 1'b0;
            ram_wr_q <= 16'b0;
            ram_wr_out_q <= 16'b0;
            // Back to Init
            controller_state_q <= DDR3_FSM_INIT;
        end

        else begin
            case (controller_state_q)
                DDR3_FSM_INIT: begin
                    controller_state_q <= DDR3_FSM_IDLE;
                end
                ////////////////////////////////
                // Idle state, wait for request
                ////////////////////////////////
                DDR3_FSM_IDLE: begin
                    // Reset readcache flag
                    sdr_write_ack <= 1'b0;
                    sdr_read_ack <= 1'b0;

                    // Burst cache read 
                    ram_req_id_out_q <= ram_cur_id_q; // Set the ID

                    // On read request to DDR3
                    if (sdr_read_req == 1'b1) begin
                        // If the write cache is dirty, clean that first
                        if(ram_write_data_dirty == 1'b1) begin
                            // Save to out registers
                            ram_addr_out_q <= ram_addr_q; // Write out current data
                            ram_wr_out_q <= ram_wr_q;
                            ram_write_data_out_q <= ram_write_data;

                            inhibit_sdr_ack_q <= 1'b1; // Inihibit write ack, we don't want to confuse the cache  
                            controller_state_q <= DDR3_FSM_WRITE; // Write out dirty cache
                        end else begin
                            // I the cache is clean start the read
                            ram_addr_out_q <= {cpuAddr[26-1:1], 1'b0}; // Set the address per 16 bytes for burst cache
                            $display("Read cache address: %h", ram_addr_out_q);
                            ram_rd_q <= 1'b1;
                            // Start read sequence
                            controller_state_q <= DDR3_FSM_READ;
                        end
                    end
                    // On Write request to DDR3
                    if (sdr_write_req == 1'b1) begin
                        // Start write sequence
                        if (ram_addr_q[26-1:4] == sdr_adr[26-1:4]) begin
                            // Supports 16-bit writes only
                            ram_wr_q <= ({14'h0, ~sdr_dqm_w[1:0]} << {sdr_adr[4-1:1], 1'b0}) | ram_wr_q; // Byte write mask
                            // ram_write_data_q[sdr_adr[4-1:1]*16 +: 16] <= sdr_dat_w[16-1:0]; // Write data to cache
                            if (sdr_dqm_w[0] == 1'b0) begin
                                ram_write_data_l_q[sdr_adr[4-1:1]] <= sdr_dat_w[0 +: 8]; // Write data to cache
                            end
                            if (sdr_dqm_w[1] == 1'b0) begin
                                ram_write_data_h_q[sdr_adr[4-1:1]] <= sdr_dat_w[8 +: 8]; // Write data to cache
                            end
                            ram_write_data_dirty <= 1'b1; // mark cache dirty
                            sdr_write_ack <= 1'b1;
                            controller_state_q <= DDR3_FSM_WRITE_2;
                        end else begin
                            // Save to out registers
                            ram_addr_out_q <= ram_addr_q; // Write out current data
                            ram_wr_out_q <= ram_wr_q;
                            ram_write_data_out_q <= ram_write_data;
                            // Create new write cache
                            ram_wr_q <= {14'h0, ~sdr_dqm_w[1:0]} << {sdr_adr[4-1:1], 1'b0}; // new Byte write mask 
                            // ram_write_data_q <= {112'h0, sdr_dat_w[16-1:0]} << (sdr_adr[4-1:1] * 16); // Data to be written padded to 128 bits
                            for (i = 0; i < 8; i=i+1) begin
                                ram_write_data_l_q[i] <= 8'h0;
                                ram_write_data_h_q[i] <= 8'h0;
                            end
                            // Load new value in write cache
                            ram_write_data_l_q[sdr_adr[4-1:1]] <= sdr_dat_w[0 +: 8]; // Write data to cache
                            ram_write_data_h_q[sdr_adr[4-1:1]] <= sdr_dat_w[8 +: 8]; // Write data to cache

                            controller_state_q <= DDR3_FSM_WRITE;
                        end
                        // Store previous address
                        ram_addr_q <= {sdr_adr[26-1:4], 4'b0000}; // Set Address on bus to write to
                    end

                end


                ////////////////////////////////////////////////////////////////
                // Read states
                ////////////////////////////////////////////////////////////////
                DDR3_FSM_READ: begin
                    // When the command is accepted drop the rd signal
                    if (ram_accept == 1'b1) begin
                        controller_state_q <= DDR3_FSM_READ_1;
                        ram_rd_q <= 1'b0;
                    end
                end
                DDR3_FSM_READ_1: begin
                    // When the Read has completed
                    if (ram_ack == 1'b1 || sdr_read_ack == 1'b1) begin
                        // Indicate to the cache data is ready
                        sdr_read_ack <= 1'b1;

                        // Store new data and address in cache, reset dirty flag
                        dat_offset_q <= dat_offset_q + 1;
                        sdr_dat_r <= ram_read_data[dat_offset_q*16 +: 16];

                        // When we went through all burst values return to idle
                        if (dat_offset_q == 7) begin
                            sdr_read_ack <= 1'b0;
                            dat_offset_q <= 0;
                            ram_cur_id_q <= ram_cur_id_q + 1;
                            controller_state_q <= DDR3_FSM_IDLE;
                        end
                    end
                    // if (cpuCSn == 1'b1) begin
                    //     controller_state_q <= DDR3_FSM_READ_2;
                    //     // Increment the request ID
                    // end
                end
                DDR3_FSM_READ_2: begin
                    if (cpuCSn == 1'b0) begin
                        sdr_read_ack <= 1'b0;
                    end
                    if (sdr_read_req == 1'b0) begin
                        controller_state_q <= DDR3_FSM_IDLE;
                    end
                end

                ////////////////////////////////////////////////////////////////
                // Write States
                ////////////////////////////////////////////////////////////////
                DDR3_FSM_WRITE: begin
                    // When the command is accepted drop the wr signal
                    if (ram_accept == 1'b1) begin
                        controller_state_q <= DDR3_FSM_WRITE_1;
                        // Set byte mask so only the correct bytes are written
                        ram_wr_out_q <= 16'h0000;
                    end
                    // Set dirty flag if we are writing to the current location of the burst cache
                end
                DDR3_FSM_WRITE_1: begin
                    // When the command is accepted drop the wr signal
                    //if (ram_accept == 1'b0) begin
                    //end
                    if (ram_ack == 1'b1) begin
                        // Indicate the write is done
                        if ( !inhibit_sdr_ack_q) begin
                            sdr_write_ack <= 1'b1;
                        end
                        // Clear durty flag as we are writing the data 
                        ram_write_data_dirty <= 1'b0; // Clear dirty flag

                        // Increment the request ID
                        ram_cur_id_q <= ram_cur_id_q + 1;

                        // Back to idle
                        controller_state_q <= DDR3_FSM_WRITE_2;
                    end
                end
                DDR3_FSM_WRITE_2: begin
                    sdr_write_ack <= 1'b0;
                    inhibit_sdr_ack_q <= 1'b0; // Clear write ack inhibit
                    // reset the write register
                    for (j = 0; j < 8; j = j + 1) begin
                        ram_write_data_l_q[i] <= 8'b0;
                        ram_write_data_h_q[i] <= 8'b0;
                    end
                    if (sdr_write_req == 1'b0) begin
                        controller_state_q <= DDR3_FSM_IDLE;
                    end
                end
                default: begin
                    controller_state_q <= DDR3_FSM_IDLE;
                end
            endcase
        end
    end

    ////////////////////////////////////////////////////////////////
    // Ultra embedded memory controller
    ////////////////////////////////////////////////////////////////

    ddr3_core
    //-----------------------------------------------------------------
    // Params
    //-----------------------------------------------------------------
    #(
    .DDR_MHZ(100),
    .DDR_WRITE_LATENCY(4),
    .DDR_READ_LATENCY(4)
    ) ddr3_core
    //-----------------------------------------------------------------
    // Ports
    //-----------------------------------------------------------------
    (
        // Inputs
        .clk_i(sysclk),
        .rst_i(!reset_in),
        .cfg_enable_i(1'b1),
        .cfg_stb_i(1'b0),
        .cfg_data_i(32'b0),

        .inport_wr_i(ram_wr), // Byte mask active high?
        .inport_rd_i(ram_rd), // read bit
        .inport_addr_i({ram_addr, 1'b0}), // ram address
        .inport_write_data_i(ram_write_data), // Data to write
        .inport_req_id_i(ram_req_id), // id of the request by default +1 until overflow
        .dfi_rddata_i(dfi_rddata),
        .dfi_rddata_valid_i(dfi_rddata_valid),
        .dfi_rddata_dnv_i(dfi_rddata_dnv),

        // Outputs
        .cfg_stall_o(),
        .inport_accept_o(ram_accept), // Goes high when request is accepted
        .inport_ack_o(ram_ack), // Goes high when request is done
        .inport_error_o(ram_error), // Ignored it seems in the example code
        .inport_resp_id_o(ram_resp_id), // Request id, entered with inport_req_id_i, for out of order requests
        .inport_read_data_o(ram_read_data), // Data read
        .dfi_address_o(dfi_address),
        .dfi_bank_o(dfi_bank),
        .dfi_cas_n_o(dfi_cas_n),
        .dfi_cke_o(dfi_cke),
        .dfi_cs_n_o(dfi_cs_n),
        .dfi_odt_o(dfi_odt),
        .dfi_ras_n_o(dfi_ras_n),
        .dfi_reset_n_o(dfi_reset_n),
        .dfi_we_n_o(dfi_we_n),
        .dfi_wrdata_o(dfi_wrdata),
        .dfi_wrdata_en_o(dfi_wrdata_en),
        .dfi_wrdata_mask_o(dfi_wrdata_mask),
        .dfi_rddata_en_o(dfi_rddata_en)
    );

    ddr3_dfi_phy
    //-----------------------------------------------------------------
    // Params
    //-----------------------------------------------------------------
    #(
    .DQS_TAP_DELAY_INIT(27),
    .DQ_TAP_DELAY_INIT(0),
    .TPHY_RDLAT(5)
    ) ddr3_dfi_phy
    //-----------------------------------------------------------------
    // Ports
    //-----------------------------------------------------------------
    (
        // Inputs
        .clk_i(sysclk), // Main clock
        .rst_i(!reset_in), // Active high
        .clk_ddr_i(sysclk_ddr), // DDR logic clock
        .clk_ddr90_i(sysclk_ddr_90), // DDR logic clock 90 degree phase behind clk_ddr_i
        .clk_ref_i(sysclk_ref), // Idle clock 1/2 of clk_ddr_i
        //.cfg_valid_i(1'b0),            // active when asserted
        //.cfg_i(32'b0),                  // DFI Configuration (DDR_PHY_CFG)
        // Control intreface to DFI
        .dfi_address_i(dfi_address), // pN
        .dfi_bank_i(dfi_bank), // pN
        .dfi_cas_n_i(dfi_cas_n), // pN
        .dfi_cke_i(dfi_cke), // pN
        .dfi_cs_n_i(dfi_cs_n), // pN
        .dfi_odt_i(dfi_odt), // pN
        .dfi_ras_n_i(dfi_ras_n), // pN
        .dfi_reset_n_i(dfi_reset_n), // pN
        .dfi_we_n_i(dfi_we_n), // pN

        // Write data interface
        .dfi_wrdata_i(dfi_wrdata), // pN write data from the MC to thePHY
        .dfi_wrdata_en_i(dfi_wrdata_en), // pN This signal indicates to the PHY that valid dfi_wrdata will be transmitted
        .dfi_wrdata_mask_i(dfi_wrdata_mask), // pN Write data byte mask

        // Read data interface
        .dfi_rddata_en_i(dfi_rddata_en), // pN This signal indicates to the PHY that a read operation to memory is underway

        // Outputs
        // Read data interface
        .dfi_rddata_o(dfi_rddata), // pN Read data from the PHY to the MC
        .dfi_rddata_valid_o(dfi_rddata_valid), // wN Read data valid indicator, active high, every cycle a byte
        .dfi_rddata_dnv_o(dfi_rddata_dnv), // wN Used with LPDDR2 DRAM only, unused here
        // DDR3 interface
        .ddr3_ck_p_o(DDR3_CK_P_O),
        .ddr3_ck_n_o(DDR3_CK_N_O),
        .ddr3_cke_o(DDR3_CKE_O),
        .ddr3_reset_n_o(DDR3_RESET_N_O),
        .ddr3_ras_n_o(DDR3_RAS_N_O),
        .ddr3_cas_n_o(DDR3_CAS_N_O),
        .ddr3_we_n_o(DDR3_WE_N_O),
        .ddr3_cs_n_o(DDR3_CS_N_O),
        .ddr3_ba_o(DDR3_BA_O),
        .ddr3_addr_o(DDR3_ADDR_O),
        .ddr3_odt_o(DDR3_ODT_O),
        .ddr3_dm_o(DDR3_DM_O),
        .ddr3_dqs_p_io(DDR3_DQS_P_IO),
        .ddr3_dqs_n_io(DDR3_DQS_N_IO),
        .ddr3_dq_io(DDR3_DQ_IO),

        // Open
        .cfg_valid_i(),
        .cfg_i()
    );

    // assign outputs
    assign ram_rd = ram_rd_q;
    assign ram_wr = ram_wr_out_q;
    assign ram_req_id = ram_req_id_out_q;
    assign ram_addr = ram_addr_out_q;
    assign ram_write_data = ram_write_data_out_q;


endmodule

