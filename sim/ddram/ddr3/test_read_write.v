`timescale 1ns/100ps

module test_read_write (
        input  wire            sysclk,
        input  wire            reset,
        output reg      [25:1] cpuAddr = 0,
        output reg   [  7-1:0] cpustate = 0,
        output reg             cpuL,
        output reg             cpuU,
        output reg   [ 16-1:0] cpuWR,
        input  wire  [ 16-1:0] cpuRD,
        input  wire            cpuena // low when busy, high when done
    );


    // Test data
    parameter TEST_SEQ_LEN = 6;

    reg [25:1] addr [0:TEST_SEQ_LEN];
    reg [15:0] data [0:TEST_SEQ_LEN];
    reg [1:0]  byte_ena [0:TEST_SEQ_LEN];

    // Set values to read and write
    initial begin
        // Address
        addr[0] <= 26'h0;
        addr[1] <= 26'h10;
        addr[2] <= 26'h20;
        addr[3] <= 26'h30;
        addr[4] <= 26'h40;
        addr[5] <= 26'h50;
        addr[6] <= 26'h60;
        // Higher offset
        addr[7] <= 26'h100;
        addr[8] <= 26'h101;
        addr[9] <= 26'h102;
        addr[10] <= 26'h103;
        addr[11] <= 26'h104;
        addr[12] <= 26'h105;
        addr[13] <= 26'h106;
        // Random order
        addr[14] <= 26'h206;
        addr[15] <= 26'h205;
        addr[16] <= 26'h204;
        addr[17] <= 26'h203;
        addr[18] <= 26'h202;
        addr[19] <= 26'h201;
        addr[20] <= 26'h200;

        // Data
        data[0] <= 16'h1234;
        data[1] <= 16'h5678;
        data[2] <= 16'h9abc;
        data[3] <= 16'hdef0;
        data[4] <= 16'h1234;
        data[5] <= 16'h5678;
        data[6] <= 16'h89ab;
        // data2
        data[7] <= 16'h0000;
        data[8] <= 16'h0101;
        data[9] <= 16'h1010;
        data[10] <= 16'habab;
        data[11] <= 16'hbaba;
        data[12] <= 16'h8a8a;
        data[13] <= 16'ha8a8;
        // data3
        data[14] <= 16'hffff;
        data[15] <= 16'heeee;
        data[16] <= 16'hdddd;
        data[17] <= 16'hcccc;
        data[18] <= 16'hbbbb;
        data[19] <= 16'haaaa;
        data[20] <= 16'h0000;

        // Byte enable
        byte_ena[0] <= 2'b11;
        byte_ena[1] <= 2'b11;
        byte_ena[2] <= 2'b11;
        byte_ena[3] <= 2'b11;
        byte_ena[4] <= 2'b11;
        byte_ena[5] <= 2'b11;
        byte_ena[6] <= 2'b11;
        // partial
        byte_ena[7] <= 2'b01;
        byte_ena[8] <= 2'b01;
        byte_ena[9] <= 2'b01;
        byte_ena[10] <= 2'b01;
        byte_ena[11] <= 2'b01;
        byte_ena[12] <= 2'b01;
        byte_ena[13] <= 2'b10;
        // partial high
        byte_ena[14] <= 2'b10;
        byte_ena[15] <= 2'b10;
        byte_ena[16] <= 2'b10;
        byte_ena[17] <= 2'b10;
        byte_ena[18] <= 2'b10;
        byte_ena[19] <= 2'b10;
        byte_ena[20] <= 2'b10;

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
    // cpu_we       : 7'bxxxxx11;
    // cpu_ir       : 7'bxxxxx00;
    // cpu_dr       : 7'bxxxxx10;
    // cpuLongword  : 7'b1xxxxxx;
    // cpuCSn       : 7'bxxxx0xx;
    // cpuLongword = cpustate[6];
    // cpuCSn      = cpustate[2];


    // Handle posting write cycle
    always @(posedge sysclk) begin
        // When in reset, reset
        if (reset) begin
            state <= STATE_WRITE;
            test_pos <= 0;
            cpustate <= 0;
        end
        // Simple write sequence
        else begin
            case (state)
                // Write test data
                STATE_WRITE: begin
                    // TODO: Enable cpuL and cpuU later
                    cpuL <= 1'b0;
                    cpuU <= 1'b0;
                    cpuAddr <= addr[test_pos];
                    cpuWR <= data[test_pos];
                    cpustate <= 7'b000011;
                    if (cpuena == 1'b1) begin
                        // both high and low bits
                        //cpuL <= byte_ena[test_pos][0];
                        //cpuU <= byte_ena[test_pos][1];
                        state = STATE_WAIT_BUSY;
                    end

                end
                STATE_WAIT_BUSY: begin
                    cpustate <= 7'b000100;
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
                    cpuAddr <= addr[test_pos];

                    cpustate <= 7'b000010;
                    // Wait for the CPU to go busy
                    if (cpuena == 1'b1) begin
                        //cpuL <= byte_ena[test_pos][0];
                        //cpuU <= byte_ena[test_pos][1];

                        state <= STATE_WAIT_READ;
                    end
                end
                STATE_WAIT_READ: begin
                    cpustate <= 7'b000110;
                    // Wait for the CPU to go busy
                    if (cpuena == 1'b0) begin
                        $display("Readback: %h: %h : %h", test_pos, cpuAddr, cpuRD);

                        if (cpuRD != data[test_pos]) begin
                            $display("Readback error: %h : %h =/= %h", cpuAddr, cpuRD, data[test_pos]);
                        end

                        if (test_pos == TEST_SEQ_LEN) begin
                            $display("Test passed");
                            $finish();
                        end
                        test_pos <= test_pos + 1;
                        state <= STATE_READ;
                    end
                end
            endcase
        end
    end

endmodule
