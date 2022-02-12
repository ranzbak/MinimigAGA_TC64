`timescale 1ns/10ps

module clock_gen (
    input      enable,
    output reg clk
);

    parameter FREQ = 100000; // in kHZ
    parameter PHASE = 0; // in degrees
    parameter DUTY = 50; // in percentage

    parameter real clk_pd  		= 1.0/(FREQ * 1e3) * 1e9; // convert to ns
    parameter real clk_on  		= DUTY/100.0 * clk_pd;
    parameter real clk_off 		= (100.0 - DUTY)/100.0 * clk_pd;
    parameter real quarter 		= clk_pd/4;
    parameter real start_dly     = quarter * PHASE/90;

    reg start_clk;

    initial begin
        $display("FREQ      = %0d kHz", FREQ);
        $display("PHASE     = %0d deg", PHASE);
        $display("DUTY      = %0d %%",  DUTY);

        $display("PERIOD    = %0.3f ns", clk_pd);
        $display("CLK_ON    = %0.3f ns", clk_on);
        $display("CLK_OFF   = %0.3f ns", clk_off);
        $display("QUARTER   = %0.3f ns", quarter);
        $display("START_DLY = %0.3f ns", start_dly);
    end

    // Initialize variables to zero
    initial begin
        clk <= 0;
        start_clk <= 0;
    end

    // When clock is enabled, delay driving the clock to one in order
    // to achieve the phase effect. start_dly is configured to the
    // correct delay for the configured phase. When enable is 0,
    // allow enough time to complete the current clock period
    always @ (posedge enable or negedge enable) begin
        if (enable) begin
            #(start_dly) start_clk = 1;
        end
        else begin
            #(start_dly) start_clk = 0;
        end
    end

    // Achieve duty cycle by a skewed clock on/off time and let this
    // run as long as the clocks are turned on.
    always @(posedge start_clk) begin
        if (start_clk) begin
            clk = 1;

            while (start_clk) begin
                #(clk_on)  clk = 0;
                #(clk_off) clk = 1;
            end

            clk = 0;
        end
    end
endmodule
