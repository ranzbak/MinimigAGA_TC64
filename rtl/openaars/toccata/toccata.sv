/********************************************/
/* toccata.v                                */
/* Toccata sound main                       */
/*                                          */
/* 2022-2023, ranzbak@gmail.com             */
/********************************************/


module toccata #(
    parameter int CLK_FREQUENCY = 28_359_380
) (
    input wire clk,
    input wire rst,
    input wire hsync,
    // Zorro II interface
    input  wire [15:0] data_in,
    output reg  [15:0] data_out,
    input  wire [15:1] addr,
    input  wire rd,
    input  wire hwr,
    input  wire lwr,
    input  wire sel,
    output logic t_int_, // Toccata interrupt active low
    // Audio output
    output logic [15:0] out_left,
    output logic [15:0] out_right
);

// Reset values for ad1848 registers
logic [7:0] ad1848_reset_reg [] = '{
    8'h00, // 0 - interrupt control
    8'h00, // 1 - Right input
    8'h00, // 2 - Left input
    8'h80, // 3 - right aux input control
    8'h80, // 4 - left aux input control
    8'h80, // 5 - right aux 2 input control
    8'h80, // 6 - left DAC control (volume)
    8'h80, // 7 - right DAC control (volume)
    8'h00, // 8 - clock and data format register
    8'h10, // 9 - interface configuration register
    8'h00, // a - pin control register
    8'h00, // b - test and initialization register
    8'h0a, // c - misc control register
    8'h00, // d - mix control register
    8'h00, // e - upper dma count register
    8'h00  // f - lower dma count register
};
logic [7:0] ad1848_reset_status = 8'hcc;
localparam logic [7:0] ad1848_reset_index = 8'h40;
logic       ad1848_fifo_play_byteswap = 1'b0;
logic       ad1848_fifo_record_byteswap = 1'b0; // Not recording, but it's there

// AD1848 register index
logic [7:0] ad1848_index;          // AD1848 current index
logic [7:0]  ad1848_regs [0:15];    // AD1848 registers

// Signals decoded from the ad1848_regs
struct {
    logic        pen;
    logic        cen; // Not used
    logic [2:0]  freq_sel;
    logic        sm;
    logic        lc;
    logic        fmt;
    logic [5:0]  lda; // Left DAC output attenuation
    logic [5:0]  rda; // Right DAC output attenuation
    logic        css;
    logic        acal;
    logic        aci;
    logic        int_;
    logic        pul;
    logic        plr;
} ad;


// Address decoder masks
// data->codec_reg1_mask = 0x6801; // Register 0 - we only look at the high byte
// data->codec_reg1_addr = 0x6001;
// data->codec_reg2_mask = 0x6801; // Register 1
// data->codec_reg2_addr = 0x6801;
// data->codec_fifo_mask = 0x6800;
// data->codec_fifo_addr = 0x2000;
localparam CODEC_STATUS     = 8'h00; // Address 'h0000
localparam CODEC_STATUS_MASK= 8'h68;
localparam CODEC_REG_1      = 8'h60; // Address 'h6000-67ff
localparam CODEC_REG_1_MASK = 8'h68; //
localparam CODEC_REG_2      = 8'h68; // Address 'h6800-68ff
localparam CODEC_REG_2_MASK = 8'h68; //
localparam CODEC_FIFO       = 8'h20; // 'h2000 - 'h20ff
localparam CODEC_FIFO_MASK  = 8'h68; //
// TOCC_FIFO_STAT   0x1ffe

// Status register bits:
// Halt playback :
//      (disables interrupt, let buffer drain)
//      - 0x01, 0x04, 0x10 (0, 2, 4)
// Start playback :
//      (Start playback without interrupt)
//      - 0x01 (0)
//      - 0x01, 0x10 (0, 4)
//  - Fill buffer
//      (Enable codec and enable interrupt)
//      - 0x01, 0x04, 0x10, 0x80
localparam STATUS_ACTIVE = 0;
localparam STATUS_RESET = 1;
localparam STATUS_FIFO_CODEC = 2; // In NetBSD driver TOC_MAGIC
localparam STATUS_FIFO_RECORD = 3;
localparam STATUS_FIFO_PLAY = 4;
localparam STATUS_RECORD_INTENA = 6;
localparam STATUS_PLAY_INTENA = 7;
logic [7:0]  status;

// IRQ register bits (CODEC_STATUS) 16'h0000:
localparam IRQ_RECORD_HALF = 2;
localparam IRQ_PLAY_HALF   = 3;
localparam IRQ_INT_IRQ     = 7;
logic [7:0] irq_reg;

// Play status
logic       play;         // 1 when playing otherwise 0

// FIFO status
logic       fifo_half;    //

// Status registers
logic [5:0] left_volume;  // 0 - 0dB dempening, max = -95.4 dB
logic       left_mute;    // 1 mutes channel
logic [5:0] right_volume; // 0 - 0dB dempersing, max = -95.4 dB
logic       right_mute;   // 1 mutes channel

// FIFO change registers
logic [1:0] fifo_half_;   // Delta FIFO half
logic [1:0] fifo_half_next; // Delta FIFO half next state
logic [1:0] acal_;          // ACAL state
logic [1:0] acal_next;      // ACAL next state
logic [1:0] hsync_;         // HSYNC state
logic [1:0] hsync_next;     // HSYNC next state
logic       write_second_byte; // write second byte to FIFO
logic [7:0] second_byte;    // second byte value

logic [5:0] auto_callibration; // auto callibration counter
logic prl_next = !status[2];
logic pul_next = !status[3];

// interrupt change registers
struct {
    logic rst;
    logic wr_en;
    logic rd_en;
    logic [7:0] data_in;
    logic full;
    logic empty;
    logic half_full;
    logic half_empty;
    logic [7:0] data_out;
    logic endata;
} fifo;

/*
 * The Toccata board consists of: GALs for ZBus AutoConfig(tm) glue, GALs
 * that interface the FIFO chips and the audio codec chip to the ZBus,
 * an AD1848 (or AD1845), and 2 Integrated Device Technology 7202LA
 * (1024x9bit FIFO) chips.
 */

// Address decoder

// Sample playback
logic [15:0]  playback_left;
logic [15:0]  playback_right;

// Contains written byte through hwr or lwr
logic [7:0] din_byte;

// Toccata FIFO to 2-complement 16-bit audio output
toccata_playback #(
    .CLK_FREQUENCY(CLK_FREQUENCY)
) my_playback (
    .clk(clk),
    .rst(rst),
    .pen(ad.pen),
    .freq_sel(ad.freq_sel),
    .sm(ad.sm),
    .lc(ad.lc),
    .fmt(ad.fmt),
    .css(ad.css),

    .rst_fifo(fifo.rst),
    .rd_en(fifo.rd_en),
    .data_in(fifo.data_out),
    .empty(fifo.empty),

    .ldata(playback_left),
    .rdata(playback_right),
    .endata(fifo.endata)
);

// Dummy Toccata audio capture module
struct {
    logic rd;
    logic empty;
    logic half_full;
    logic full;
    logic endata;
} cap;
toccata_capture #(
    .CLK_FREQUENCY(CLK_FREQUENCY)
) my_capture (
    .clk(clk),
    .rst(rst),

    .cen(ad.cen),
    .freq_sel(ad.freq_sel),
    .sm(ad.sm),
    .fmt(ad.fmt),
    .css(ad.css),

    .data_out(),
    .rd(cap.rd),
    .empty(cap.empty),
    .half_full(cap.half_full),
    .full(cap.full),

    .endata(cap.endata)
);


// Volume playback
toccata_volume my_toccata_volume (
    .clk(clk),
    .rst(rst),
    .audio_in_left(playback_left),
    .audio_in_right(playback_right),
    .attenuation_left(ad.lda),
    .attenuation_right(ad.rda),
    .audio_out_left(out_left),
    .audio_out_right(out_right)
);


// Sound FIFO, used to hold the ad1848 sound data
toccata_fifo #(
    .DATA_WIDTH(8),
    .FIFO_DEPTH(1024)
) myfifo (
    .clk(clk),
    .rst(fifo.rst),
    .wr_en(fifo.wr_en),
    .rd_en(fifo.rd_en),
    .data_in(fifo.data_in),
    .full(fifo.full),
    .empty(fifo.empty),
    .half_full(fifo.half_full),
    .half_empty(fifo.half_empty),
    .data_out(fifo.data_out)
);

always_comb begin
    // Set interrupt pin
    t_int_ = irq_reg[IRQ_INT_IRQ];

    // AD1848 status register
    ad.plr = status[2];
    ad.pul = status[3];

    // Decode AD1848 audio registers
    ad.int_ = ad1848_regs[2][0];
    ad.lda = ad1848_regs[6][5:0];
    ad.rda = ad1848_regs[7][5:0];
    ad.css = ad1848_regs[8][0];         // Crystal select
    ad.freq_sel = ad1848_regs[8][3:1];
    ad.sm = ad1848_regs[8][4];
    ad.lc = ad1848_regs[8][5];
    ad.fmt = ad1848_regs[8][6];
    ad.pen = ad1848_regs[9][0];
    ad.cen = ad1848_regs[9][1];
    ad.acal = ad1848_regs[9][3];
    ad.aci = ad1848_regs[11][5];

    // Detect changes in the signals that generate interrupts
    fifo_half_next = {fifo_half_[0], fifo.half_empty};
    acal_next = {acal_[0], ad.acal};
    hsync_next = {hsync_[0], hsync};

    // Get the byte written from the high or low byte
    // High byte write has priority
    din_byte = hwr ? data_in[15:8] : lwr ? data_in[7:0] : 0;

    // prl and pul signal generation
    prl_next = !status[2];
    pul_next =!status[3];
end



always_ff @(posedge clk) begin
    fifo.wr_en <= 1'b0;
    fifo.rst <= 1'b0;
    write_second_byte <= 1'b0;

    if (rst == 1) begin
        // Reset the ad1848 registers
        for(int i = 0; i < 16; i++) begin
            ad1848_regs[i] <= ad1848_reset_reg[i];
        end
        // Reset the FIFO
        fifo.rst <= 1'b1;
        ad1848_index <= ad1848_reset_index;
        data_out <= 16'h0000;
        irq_reg <= 8'h80;
        auto_callibration <= 0;
        status <= 0; // Intitial status set
    end else begin
        // Update int trigger records
        fifo_half_ <= fifo_half_next;
        acal_ <= acal_next;
        hsync_ <= hsync_next;

        // Trigger interrupt if the FIFO state changes
        if (fifo_half_next == 2'b01 && status[STATUS_PLAY_INTENA] == 1'b1) begin
            irq_reg[IRQ_INT_IRQ] <= 1'b0; // Active low
        end

        // Trigger on acal bit change
        if (acal_next == 2'b01) begin
            auto_callibration <= 50;
        end

        // Set Playback Underrun bit when FIFO is empty
        ad1848_regs[11][6] <= fifo.empty;

        // Simulate auto callibration cycle
        if (hsync_next == 2'b01 && auto_callibration > 0) begin
            auto_callibration <= auto_callibration - 1;
        end
        if (auto_callibration > 10 && auto_callibration < 30) begin
            // Auto callibration in progress
            ad1848_regs[11][5] <= 1'b1; // Set ACAL bit to indicate callbiration in progress
        end else begin
            // Auto callibration done
            ad1848_regs[11][5] <= 1'b0; // Reset ACAL bit
            ad1848_regs[9][3] <= 1'b0;  // Reset ACI bit
        end

        // Trigger interrupt if the FIFO state changes

        // populate interrupt record
        // We don't do recording, so we only trigger the playback interrupt
        irq_reg[IRQ_PLAY_HALF] <= fifo.half_empty;

        // When the ACAL bit is set, run a fake auto calibration
        // This is needed to keep the drivers happy


        // Handle second byte to FIFO first
        // This is to handle 16-bit writes
        if (write_second_byte == 1'b1) begin
            // Write second byte to the FIFO
            fifo.wr_en <= 1'b1;
            fifo.data_in <= second_byte;
        end else if (sel == 1'b1) begin
            // When selected start answering

            // Put data into the registers
            if (lwr || hwr) begin // Might need to trigger on both
                // Decode codec reg 1
                if ((addr[15:8] & CODEC_REG_1_MASK) == CODEC_REG_1 && hwr) begin
                    ad1848_index <= data_in[15:8]; // TODO: correct???
                end

                // Decode codec reg 2
                if ((addr[15:8] & CODEC_REG_2_MASK) == CODEC_REG_2 && hwr) begin
                    `ifdef DEBUG
                    $display("write - index: %1h data: %2h", ad1848_index, data_in[15:8]);
                    `endif
                    case (ad1848_index)
                        8'h02: begin
                            // Interrupt register, clear interrupt
                            ad1848_regs[2][0] <= 1'b0;
                        end
                        8'h03: begin
                            // PIO register
                            fifo.wr_en <= 1'b1;
                            fifo.data_in <= data_in[15:8];
                        end
                        8'h0c: begin
                        // Ignore
                        end
                        default: begin
                            // Only write to the first 16 register, there is no more
                            if (ad1848_index[7:4] == 4'h0) begin
                                // Store the values in the registers
                                ad1848_regs[ad1848_index] <= data_in[15:8];
                            end
                        end
                    endcase
                end

                // Decode irq reg
                if ((addr[15:8] & CODEC_STATUS_MASK) == CODEC_STATUS) begin

                    // If the reset bit is set, stop codec, reset fifo
                    if (din_byte[STATUS_RESET] == 1'b1) begin
                        // Reset the card, and stop playback
                        fifo.rst <= 1'b1;
                        irq_reg <= 8'h80; // Clear all interrupts
                        status <= 8'h00; // Inactivate card

                        // Reset registers
                        ad1848_regs[9][0] <= 1'b0;
                        ad1848_regs[9][1] <= 1'b0;
                        ad1848_regs[9][6] <= 1'b0;
                        ad1848_regs[9][7] <= 1'b0;
                        ad1848_regs[10][1] <= 1'b0;
                    end else begin
                        // When not resetting, store the status
                        status <= din_byte;

                        // When only Status active is set and nothing else,
                        // Reset the buffer
                        if (din_byte == 8'h01) begin // STATUS_ACTIVE
                            // Activate card
                            fifo.rst <= 1'b1; // Start with a clean FIFO
                            irq_reg <= 8'h80; // Clear all interrupts
                        end

                        // Store bytes in the AD1848 registers
                        ad1848_regs[9][0] <= din_byte[STATUS_FIFO_CODEC] ? din_byte[STATUS_FIFO_PLAY] : 1'b0;
                        ad1848_regs[9][1] <= din_byte[STATUS_FIFO_CODEC] ? din_byte[STATUS_FIFO_RECORD] : 1'b0;
                        ad1848_regs[9][6] <= din_byte[STATUS_PLAY_INTENA];
                        ad1848_regs[9][7] <= din_byte[STATUS_RECORD_INTENA];
                        ad1848_regs[10][1] <= din_byte[STATUS_PLAY_INTENA] | din_byte[STATUS_RECORD_INTENA];
                    end
                end

                // Decode codec FIFO (DMA)
                if ((addr[15:8] & CODEC_FIFO_MASK) == CODEC_FIFO) begin
                    if (status[STATUS_FIFO_PLAY] == 1'b1 && fifo.full == 1'b0) begin
                        if (lwr == 1'b1) begin
                            // Write byte to the FIFO
                            fifo.wr_en <= 1'b1;
                            fifo.data_in <= data_in[7:0];
                        end
                        if (hwr == 1'b1) begin
                            // Setup second byte write
                            write_second_byte <= 1'b1;
                            second_byte <= data_in[15:8];
                        end
                    end
                end
            end

            // Get data from the registers
            else if (rd == 1'b1) begin
                // Decode codec reg 1
                if((addr[15:8] & CODEC_REG_1_MASK) == CODEC_REG_1) begin
                    // Return the current index address
                    data_out[15:8] <= ad1848_index;
                end

                // Decode codec reg 2
                if((addr[15:8] & CODEC_REG_2_MASK) == CODEC_REG_2) begin
                    case (ad1848_index)
                        8'h03: begin
                            // PIO register, because we don't do input 'h80 always
                            data_out <= 16'h8000;
                        end
                        default: begin
                            if (ad1848_index[7:4] == 4'h0) begin
                                // Return the current value
                                data_out[15:8] <= ad1848_regs[ad1848_index];
                            end else begin
                                // We only have 16 registers, ignore all else
                                data_out <= 16'h0000;
                            end
                        end
                    endcase
                end

                // Decode irq register
                if(addr[15:8] == CODEC_STATUS ) begin
                    // Return the current interrupt status register
                    data_out <= {irq_reg, irq_reg};
                end

                // Decode codec fifo
                if (addr[15:8] == 8'h20) begin
                    // Return dummy value of 'h0000 because we don't record sound
                    // Might need to be 'h8000 in the future (2 complement)
                    data_out <= 16'h0000;
                end
            end else begin
                // When not selected, stay off the bus
                data_out <= 16'h0000;
            end
        end

        // Generate plr and pul registers

        // prl = status[2]
        // pul = status[3]
        // Mono prl = 1
        // 8-bit pul = 1
        // MONO 16-bit stereo pul alternates
        // Stereo 16-bit stereo pul alternates, prl alternates at 1 -> 0

        // Lower / higher byte
        if (ad.fmt == 1'b0) begin // 8-bit
            status[3] <= 1'b1;
        end else begin // 16-bit
            // Update on write to FIFO
            if (fifo.wr_en == 1'b1) begin
                // Flip left / right channel every other write
                status[3] <= pul_next;
            end
        end

        // Right lef channel bits in status generation
        if (ad.sm == 1'b0) begin // Mono
            status[2] <= 1'b1;
        end else begin // Stereo
            // Update on write to FIFO
            if (fifo.wr_en == 1'b1) begin
                // 8-bit Stereo flip every byte
                // 16-bit Stereo flip every second byte
                if ((pul_next == 1'b0 && ad.fmt == 1'b1) || ad.fmt == 1'b0) begin
                    // Flip upper and lower en overy write
                    status[2] <= prl_next;
                end
            end
        end

// Paula sound forward
// register 4 for left channel value
// register 5 for right channel value

    end
end

endmodule