module spi_slave (
    input wire clk,        // System clock
    input wire rst,      // Active low reset
    input wire cs,       // Chip Select, active low
    input wire sclk,       // SPI Clock
    input wire mosi,       // Master Out, Slave In
    output logic miso        // Master In, Slave Out
);

logic [7:0] shift_reg = 8'b0;
logic [3:0] bit_counter = 0;
logic [7:0] response_array [10]; // 10-byte array with response
logic [7:0] received_array [10]; // 10-byte array with received
logic [3:0] byte_counter = 0;

// Initialize the response array
initial begin
    response_array[0] = 8'haa;
    response_array[1] = 8'h01;
    response_array[2] = 8'h02;
    response_array[3] = 8'h03;
    response_array[4] = 8'h04;
    response_array[5] = 8'h05;
    response_array[6] = 8'h06;
    response_array[7] = 8'h07;
    response_array[8] = 8'h08;
    response_array[9] = 8'hFF;
end

logic       sclk_tr;
logic [1:0] sclk_buf;
logic [1:0] sclk_buf_next;

logic       cs_end_tr;
logic [1:0] cs_buf;
logic [1:0] cs_buf_next;


always_ff @(posedge clk) begin
    sclk_tr <= 1'b0;
    cs_end_tr <= 1'b0;

    if (rst) begin
        sclk_buf <= 2'b00;
        cs_buf <= 2'b00;
    end else begin
        sclk_buf <= sclk_buf_next;
        cs_buf <= cs_buf_next;

        // Trigger on rising edge
        if (sclk_buf_next == 2'b01) begin
            sclk_tr <= 1'b1;
        end

        if (cs_buf == 2'b10) begin
            cs_end_tr <= 1'b1;
        end
    end

end

assign sclk_buf_next = {sclk_buf[0], sclk};
assign cs_buf_next = {cs_buf[0], cs};




// SPI Slave Logic for simultaneous send and receive
always_ff @(posedge clk) begin
    if (rst) begin
        bit_counter <= 0;
        byte_counter <= 0;
        miso <= 1'b0;
        shift_reg <= 0;

        for (int i = 0; i < 10; i++) begin
            received_array[i] <= 8'b0;
        end
    end else if (cs) begin
        if (bit_counter == 0) begin
            // Load the next byte to be sent
            shift_reg <= response_array[byte_counter];
        end

        // Send and receive on SPI clock edge
        if (sclk_tr) begin
            // Shift out the MSB, shift in from MOSI
            miso <= shift_reg[7];
            shift_reg <= {shift_reg[6:0], mosi};

            // Increment bit counter
            bit_counter <= bit_counter + 1;

            // Reset bit counter and move to next byte after 8 bits
            if (bit_counter == 4'h7) begin
                received_array[byte_counter] <= shift_reg;
                bit_counter <= 0;
                byte_counter <= byte_counter + 1;
                if (byte_counter == 9) begin
                    byte_counter <= 0; // Reset to first byte after 10 bytes
                end
            end
        end

        // Print the received array to the screen
        if (cs_end_tr) begin
            for (int i = 0; i < 10; i++) begin
                $display("Received: %d - %h", i, received_array[i]);
            end
            bit_counter <= 0;
            byte_counter <= 0;
        end
    end else begin
        // Reset counters when CS is not active
        bit_counter <= 0;
        byte_counter <= 0;
    end
end

endmodule