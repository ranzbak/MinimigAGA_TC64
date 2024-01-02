/********************************************/
/* toccata_fifo.v                           */
/* Toccata sound playback                   */
/*                                          */
/* 2022-2023, ranzbak@gmail.com             */
/********************************************/

module toccata_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int FIFO_DEPTH = 1024
) (
    input logic clk,
    input logic rst,
    input logic wr_en,
    input logic rd_en,
    input logic [DATA_WIDTH-1:0] data_in,
    output logic full,
    output logic empty,
    output logic half_full,
    output logic [DATA_WIDTH-1:0] data_out
);

// Internal variables
logic [DATA_WIDTH-1:0] fifo_array [FIFO_DEPTH-1:0];
// int read_ptr = 0, write_ptr = 0;
int count; // To handle full and empty states
logic [$clog2(FIFO_DEPTH)-1: 0] write_ptr = 0;
logic [$clog2(FIFO_DEPTH)-1: 0] write_ptr_next = 0;
logic [$clog2(FIFO_DEPTH)-1: 0] read_ptr = 0;
logic [$clog2(FIFO_DEPTH)-1: 0] read_ptr_next = 0;

always_comb begin
    // flags
    full = (count == FIFO_DEPTH);
    empty = (count == 0);
    half_full = (count >= FIFO_DEPTH/2);

    // Data out
    data_out = fifo_array[read_ptr];

    // Next pointer state
    write_ptr_next = write_ptr + 1;
    read_ptr_next = read_ptr + 1;
end

// Sequential logic for read and write operations
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        read_ptr <= 0;
        write_ptr <= 0;
        count <= 0;
        for (int i = 0; i < FIFO_DEPTH; i++ ) begin
            fifo_array[i] <= 0;
        end
    end else begin
        // Write to the FIFO
        if (wr_en && !full) begin
            fifo_array[write_ptr] <= data_in;
            write_ptr <= write_ptr_next;
            count <= count + 1;
        end
        // READ from the FIFO
        if (rd_en && !empty) begin
            read_ptr <= read_ptr_next;
            count <= count - 1;
        end

        // If read and write are both active, count doesn't change: 1 in, 1 out.
        if (rd_en && !empty && wr_en && !full) begin
            count <= count;
        end
    end
end

endmodule
