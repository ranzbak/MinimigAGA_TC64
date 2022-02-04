`timescale 1ns/100ps

module test_read_write (
    input  wire            sysclk,
    input  wire            reset,
    output reg      [25:1] cpuAddr = 0,
    output wire  [  7-1:0] cpustate,
    output reg             cpuL,
    output reg             cpuU,
    output reg   [ 16-1:0] cpuWR,
    input  wire  [ 16-1:0] cpuRD,
    input  wire            cpuena // low when busy, high when done
);

    // CPU State parameters
    reg [1:0] cState = 2'b00;
    reg       cpu_ncs = 1'b1;
    reg       cpuLongWord = 1'b0;


    // Test data
    parameter TEST_SEQ_LEN = 22;

    reg [25:1] addr [0:TEST_SEQ_LEN];
    reg [15:0] data [0:TEST_SEQ_LEN];
    reg [1:0]  byte_ena [0:TEST_SEQ_LEN];

    // Set values to read and write
    initial begin

        // Data                 // Address             // Byte enable
        data[0] <= 16'h1234;    addr[0] <= 26'h0;      byte_ena[0] <= 2'b11;
        data[1] <= 16'h5678;    addr[1] <= 26'h10;     byte_ena[1] <= 2'b11;
        data[2] <= 16'h9abc;    addr[2] <= 26'h20;     byte_ena[2] <= 2'b11;
        data[3] <= 16'hdef0;    addr[3] <= 26'h30;     byte_ena[3] <= 2'b11;
        data[4] <= 16'h1234;    addr[4] <= 26'h40;     byte_ena[4] <= 2'b11;
        data[5] <= 16'h5678;    addr[5] <= 26'h50;     byte_ena[5] <= 2'b11;
        data[6] <= 16'h89ab;    addr[6] <= 26'h60;     byte_ena[6] <= 2'b11;
        // data2                // Higher offset       // partial
        data[7] <= 16'h0000;    addr[7] <= 26'h100;    byte_ena[7]  <= 2'b11;
        data[8] <= 16'h0101;    addr[8] <= 26'h101;    byte_ena[8]  <= 2'b11;
        data[9] <= 16'h1010;    addr[9] <= 26'h102;    byte_ena[9]  <= 2'b11;
        data[10] <= 16'habab;   addr[10] <= 26'h103;   byte_ena[10] <= 2'b11;
        data[11] <= 16'hbaba;   addr[11] <= 26'h104;   byte_ena[11] <= 2'b11;
        data[12] <= 16'h8a8a;   addr[12] <= 26'h105;   byte_ena[12] <= 2'b11;
        data[13] <= 16'ha8a8;   addr[13] <= 26'h106;   byte_ena[13] <= 2'b11;
        data[14] <= 16'haa88;   addr[14] <= 26'h107;   byte_ena[14] <= 2'b11;
        // data3                // Random order        // partial high
        data[15] <= 16'hffff;   addr[15] <= 26'h200;   byte_ena[15] <= 2'b11;
        data[16] <= 16'heeee;   addr[16] <= 26'h201;   byte_ena[16] <= 2'b11;
        data[17] <= 16'hdddd;   addr[17] <= 26'h202;   byte_ena[17] <= 2'b11;
        data[18] <= 16'hcccc;   addr[18] <= 26'h203;   byte_ena[18] <= 2'b11;
        data[19] <= 16'hbbbb;   addr[19] <= 26'h204;   byte_ena[19] <= 2'b11;
        data[20] <= 16'haaaa;   addr[20] <= 26'h205;   byte_ena[20] <= 2'b11;
        data[21] <= 16'h9999;   addr[21] <= 26'h206;   byte_ena[21] <= 2'b11;
        data[22] <= 16'h8888;   addr[22] <= 26'h207;   byte_ena[22] <= 2'b11;


    end

    // FSM states
    parameter STATE_WRITE = 2'h0;
    parameter STATE_WAIT_BUSY = 2'h1;
    parameter STATE_READ = 2'h2;
    parameter STATE_WAIT_READ = 2'h3;

    reg [2:0] state = STATE_WRITE;
    reg [7:0] test_pos = 0; // position in test sequence

    // Use cpustate register to set read/write state
    // cpustate <= longword&clkena&slower(1 downto 0)&ramcs&state(1 downto 0);
    //
    // cpu bus time sharing based on cpustate
    // cpustate <= longword&clkena&slower(1 downto 0)&ramcs&state(1 downto 0)
    // idle         : 7'xxxxxx01;
    // cpu_we       : 7'bxxxxx11;
    // cpu_ir       : 7'bxxxxx00;
    // cpu_dr       : 7'bxxxxx10;
    // cpuLongword  : 7'b1xxxxxx;
    // cpuCSn       : 7'bxxxx0xx;
    // cpuLongword = cpustate[6];
    // cpuCSn      = cpustate[2];

    // CPU states
    parameter CPU_IR = 2'b00;
    parameter CPU_IDLE = 2'b01;
    parameter CPU_DR = 2'b10;
    parameter CPU_WE = 2'b11;


    // Handle posting write cycle
    always @(posedge sysclk) begin
        // When in reset, reset
        if (reset) begin
            state <= STATE_WRITE;
            test_pos <= 0;
            cpuLongWord <= 1'b0;
            cpu_ncs <= 1'b1;
            cState <= 2'b00;
        end
        // Simple write sequence
        else begin
            case (state)
                // TODO: Add clear from 0 to 1024 to init

                // Write test data
                STATE_WRITE: begin
                    // TODO: Enable cpuL and cpuU later
                    cpuL <= 1'b0;
                    cpuU <= 1'b0;
                    cpuAddr <= addr[test_pos][25:1];
                    cpuWR <= data[test_pos];
                    cState <= CPU_WE;
                    cpu_ncs <= 1'b0;
                    if (cpuena == 1'b1) begin
                        // both high and low bits
                        //cpuL <= byte_ena[test_pos][0];
                        //cpuU <= byte_ena[test_pos][1];
                        state = STATE_WAIT_BUSY;
                    end

                end
                STATE_WAIT_BUSY: begin
                    cpu_ncs <= 1'b1;
                    //cState <= CPU_IDLE;
                    // Wait for the CPU to go busy
                    if (cpuena == 1'b0) begin
                        state <= STATE_WRITE;
                        test_pos <= test_pos + 1;

                        $display("Write data: %h : %h", addr[test_pos], data[test_pos]);

                        if (test_pos == TEST_SEQ_LEN) begin
                            state <= STATE_READ;
                            test_pos <= 0;
                        end
                    end
                end

                // Read data back
                STATE_READ: begin
                    //cpuL <= 1'b0;
                    //cpuU <= 1'b0;
                    cpuAddr <= addr[test_pos][25:1];
                    cpu_ncs <= 1'b0;
                    cState <= CPU_DR;
                    // Wait for the CPU to go busy
                    if (cpuena == 1'b1) begin
                        //cpuL <= byte_ena[test_pos][0];
                        //cpuU <= byte_ena[test_pos][1];
                        state <= STATE_WAIT_READ;
                    end
                end
                STATE_WAIT_READ: begin
                    cpu_ncs <= 1'b1;
                    cState <= CPU_IDLE;
                    // Wait for the CPU to go busy
                    if (cpuena == 1'b0 ) begin

                        if (cpuRD !== data[test_pos]) begin
                            $display("Readback error: %h: %h : %h =/= %h", test_pos, cpuAddr, cpuRD, data[test_pos]);
                        end else begin
                            $display("Readback OK   : %h: %h : %h", test_pos, cpuAddr, cpuRD);
                        end


                        if (test_pos == TEST_SEQ_LEN) begin
                            $display("Test finish");
                            $finish();
                        end
                        test_pos <= test_pos + 1;
                        state <= STATE_READ;
                    end
                end
                default: begin
                    $display("Unknown state: %h", state);
                    state <= STATE_WRITE;
                end
            endcase
        end
    end

    // CPU interface state
    assign    cpustate = {cpuLongWord, 3'b000, cpu_ncs, cState[1:0]};

endmodule
