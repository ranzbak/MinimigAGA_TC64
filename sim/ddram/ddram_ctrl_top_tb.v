`timescale 1ns/1ps

//`define SOC_SIM


`include "ddram_ctrl_defs.vh"


module ddram_ctrl_top_tb;

    // registers
    wire           sysclk;
    wire           sysclk_ref;
    wire           sysclk_ddr;
    wire           sysclk_ddr_90;
    reg            reset_in = 1'b0;
    reg            cache_rst = 1'b0;
    reg            cache_inhibit = 1'b0;
    reg            cacheline_clr = 1'b0;
    reg  [  4-1:0] cpu_cache_ctrl = 4'b0000;
    wire           reset_out;

    // DDR3 Core interface
    wire             ram_accept;
    wire             ram_ack;
    reg              ram_error;
    reg   [   15:0]  ram_resp_id;
    reg   [  127:0]  ram_read_data;
    wire  [   15:0]  ram_wr;
    wire             ram_rd;
    wire  [   31:0]  ram_addr;
    wire  [  127:0]  ram_write_data;
    wire  [   15:0]  ram_req_id;

    // cpu
    reg       [25:1] cpuAddr;
    reg    [  7-1:0] cpustate;
    reg              cpuL = 1'b0;
    reg              cpuU = 1'b0;
    reg    [ 16-1:0] cpuWR;
    wire   [ 16-1:0] cpuRD;
    wire             cpuena;

    reg              enable = 1'b0;

    // DDR3 Ram dimensions
    parameter DM_BITS =  2;
    parameter BA_BITS =  3;
    parameter ADDR_BITS = 14;
    parameter DQ_BITS = 16;
    parameter DQS_BITS = 2;

    initial begin
        // Release reset
        #50000 reset_in <= 1'b1;
        // Enable Cache
        // Disabled to see when the init_done switches
        #60000 cache_rst <= 1'b1;
        cache_inhibit <= 1'b0;
    end

    // Sane defaults
    initial begin

        #10 enable = 1'b1;
        // reset_in = 1'b0;
        // cache_rst = 1'b0;
        // cache_inhibit = 1'b0;
        // cacheline_clr = 1'b0;
        // cpu_cache_ctrl = 4'b0000;

        // // Ram inputs
        // ram_error = 1'b0;
        // ram_resp_id = 16'b0000;
        // ram_read_data = 128'b0;
    end

    // Generate clock signals
    clock_gen #(
                  .FREQ(100000),
                  .PHASE(0),
                  .DUTY(50)
              )
              u1(
                  .enable(enable),
                  .clk(sysclk)
              );
    clock_gen #(
                  .FREQ(200000)
              )
              u2(
                  .enable(enable),
                  .clk(sysclk_ref)
              );
    clock_gen #(
                  .FREQ(400000)
              )
              u3(
                  .enable(enable),
                  .clk(sysclk_ddr)
              );
    clock_gen #(
                  .FREQ(400000),
                  .PHASE(90)
              )
              u4(
                  .enable(enable),
                  .clk(sysclk_ddr_90)
              );

    // Generate test signals
    test_read_write mytest (
                        .sysclk(sysclk),
                        .reset(!reset_in),
                        .cpuAddr(cpuAddr),
                        .cpustate(cpustate),
                        .cpuL(cpuL),
                        .cpuU(cpuU),
                        .cpuWR(cpuWR),
                        .cpuRD(cpuRD),
                        .cpuena(cpuena)
                    );

    // cache
    ddram_ctrl ddram_test(
                   // system
                   .sysclk(sysclk),
                   .reset_in(reset_in),
                   .cache_rst(cache_rst),
                   .cache_inhibit(cache_inhibit),
                   .cacheline_clr(cacheline_clr),
                   .cpu_cache_ctrl(cpu_cache_ctrl),
                   .reset_out(reset_out),

                   // DDR3 Core interface
                   .ram_accept(ram_accept),
                   .ram_ack(ram_ack),
                   .ram_error(ram_error),
                   .ram_resp_id(ram_resp_id),
                   .ram_read_data(ram_read_data),
                   .ram_wr(ram_wr),
                   .ram_rd(ram_rd),
                   .ram_addr(ram_addr),
                   .ram_write_data(ram_write_data),
                   .ram_req_id(ram_req_id),

                   // cpu
                   .cpuAddr(cpuAddr),
                   .cpustate(cpustate),
                   .cpuL(cpuL),
                   .cpuU(cpuU),
                   .cpuWR(cpuWR),
                   .cpuRD(cpuRD),
                   .cpuena(cpuena)
               );

    // Control intreface to DFI
    wire  [ 14:0]  dfi_address;          // pN
    wire  [  2:0]  dfi_bank;             // pN
    wire           dfi_cas_n;            // pN
    wire           dfi_cke;              // pN
    wire           dfi_cs_n;             // pN
    wire           dfi_odt;              // pN
    wire           dfi_ras_n;            // pN
    wire           dfi_reset_n;          // pN
    wire           dfi_we_n;             // pN

    // Write data interface
    wire  [31:0]  dfi_wrdata;           // pN write data from the MC to thePHY
    wire          dfi_wrdata_en;        // pN This signal indicates to the PHY that valid dfi_wrdata will be transmitted
    wire  [3:0]   dfi_wrdata_mask;      // pN Write data byte mask

    // Read data interface
    wire           dfi_rddata_en;        // pN This signal indicates to the PHY that a read operation to memory is underway

    // Outputs
    // Read data interface
    wire [31:0]  dfi_rddata;            // pN Read data from the PHY to the MC
    wire         dfi_rddata_valid;      // wN Read data valid indicator, active high, every cycle a byte
    wire [1:0]   dfi_rddata_dnv;        // wN Used with LPDDR2 DRAM only, unused here



    // Ultraembedded DDR3 controle core
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

            .inport_wr_i(ram_wr),            // Byte mask active high?
            .inport_rd_i(ram_rd),            // read bit
            .inport_addr_i({ram_addr, 1'b0}),          // ram address
            .inport_write_data_i(ram_write_data),    // Data to write
            .inport_req_id_i(ram_req_id),        // id of the request by default +1 until overflow
            .dfi_rddata_i(dfi_rddata),
            .dfi_rddata_valid_i(dfi_rddata_valid),
            .dfi_rddata_dnv_i(dfi_rddata_dnv),

            // Outputs
            .cfg_stall_o(),
            .inport_accept_o(ram_accept),           // Goes high when request is accepted
            .inport_ack_o(ram_ack),                 // Goes high when request is done
            .inport_error_o(ram_error),             // Ignored it seems in the example code
            .inport_resp_id_o(ram_resp_id),         // Request id, entered with inport_req_id_i, for out of order requests
            .inport_read_data_o(ram_read_data),     // Data read
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


    // DDR
    // Declare Ports

    wire                    rst_n;
    wire                    ck_p;
    wire                    ck_n;
    wire                    cke;
    wire                    cs_n;
    wire                    ras_n;
    wire                    cas_n;
    wire                    we_n;
    wire  [DM_BITS-1: 0]    dm_tdqs;
    wire  [BA_BITS-1: 0]    ba;
    wire  [ADDR_BITS-1: 0]  addr;
    wire  [DQ_BITS-1: 0]    dq;
    wire  [DQS_BITS-1: 0]   dqs_p;
    wire  [DQS_BITS-1: 0]   dqs_n;
    wire  [DQS_BITS-1: 0]   tdqs_n;
    wire                    odt;

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
            .clk_i(sysclk),            // Main clock
            .rst_i(!reset_in),         // Active high
            .clk_ddr_i(sysclk_ddr),        // DDR logic clock
            .clk_ddr90_i(sysclk_ddr_90),    // DDR logic clock 90 degree phase behind clk_ddr_i
            .clk_ref_i(sysclk_ref),    // Idle clock 1/2 of clk_ddr_i
            //.cfg_valid_i(1'b0),            // active when asserted
            //.cfg_i(32'b0),                  // DFI Configuration (DDR_PHY_CFG)
            // Control intreface to DFI
            .dfi_address_i(dfi_address),        // pN
            .dfi_bank_i(dfi_bank),              // pN
            .dfi_cas_n_i(dfi_cas_n),            // pN
            .dfi_cke_i(dfi_cke),                // pN
            .dfi_cs_n_i(dfi_cs_n),              // pN
            .dfi_odt_i(dfi_odt),                // pN
            .dfi_ras_n_i(dfi_ras_n),            // pN
            .dfi_reset_n_i(dfi_reset_n),        // pN
            .dfi_we_n_i(dfi_we_n),              // pN

            // Write data interface
            .dfi_wrdata_i(dfi_wrdata),           // pN write data from the MC to thePHY
            .dfi_wrdata_en_i(dfi_wrdata_en),        // pN This signal indicates to the PHY that valid dfi_wrdata will be transmitted
            .dfi_wrdata_mask_i(dfi_wrdata_mask),      // pN Write data byte mask

            // Read data interface
            .dfi_rddata_en_i(dfi_rddata_en),        // pN This signal indicates to the PHY that a read operation to memory is underway

            // Outputs
            // Read data interface
            .dfi_rddata_o(dfi_rddata),           // pN Read data from the PHY to the MC
            .dfi_rddata_valid_o(dfi_rddata_valid),     // wN Read data valid indicator, active high, every cycle a byte
            .dfi_rddata_dnv_o(dfi_rddata_dnv),       // wN Used with LPDDR2 DRAM only, unused here
            // DDR3 interface
            .ddr3_ck_p_o(ck_p),
            .ddr3_ck_n_o(ck_n),
            .ddr3_cke_o(cke),
            .ddr3_reset_n_o(rst_n),
            .ddr3_ras_n_o(ras_n),
            .ddr3_cas_n_o(cas_n),
            .ddr3_we_n_o(we_n),
            .ddr3_cs_n_o(cs_n),
            .ddr3_ba_o(ba),
            .ddr3_addr_o(addr),
            .ddr3_odt_o(odt),
            .ddr3_dm_o(dm_tdqs),
            .ddr3_dqs_p_io(dqs_p),
            .ddr3_dqs_n_io(dqs_n),
            .ddr3_dq_io(dq)
        );

    //-----------------------------------------------------------------
    // DDR3 simulation
    //-----------------------------------------------------------------
    ddr3 ddr3_sim (
             .rst_n(rst_n),
             .ck(ck_p),
             .ck_n(ck_n),
             .cke(cke),
             .cs_n(cs_n),
             .ras_n(ras_n),
             .cas_n(cas_n),
             .we_n(we_n),
             .dm_tdqs(dm_tdqs),
             .ba(ba),
             .addr(addr),
             .dq(dq),
             .dqs(dqs_p),
             .dqs_n(dqs_n),
             .tdqs_n(),
             .odt(odt)
         );

endmodule
