// ============================================================
// rate_control  how often a new image is fetched and shown
// ============================================================
//
// The display rate is a divisor of the video refresh rate, kept as a
// power-of-two step index so the two buttons are exact:
//
//   images per second = MAX_RATE >> rate_step
//
// With a 60 Hz screen that is 60, 30, 15, 7, 3 or 1 image/s. The bound
// comes from the screen, not from this module: MAX_RATE is the refresh
// rate, so no setting can ask for an image faster than the display can
// show one, and the slowest setting is one image per second.
//
// The button inputs are already-debounced press pulses (one per press).
// Doubling at the top of the range and halving at the bottom hold
// still; they never wrap.
// ============================================================

module mnist_rate #(
    parameter int CLK_HZ   = 27_000_000,
    parameter int MAX_RATE = 60,     // the screen's refresh rate
    parameter int MIN_RATE = 1
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       btn_double,   // one-cycle press pulse
    input  logic       btn_half,
    output logic       fetch_tick,   // one cycle, MAX_RATE >> rate_step Hz
    output logic [2:0] rate_step,    // log2 of how many frames per image
    output logic [5:0] rate_hz       // MAX_RATE >> rate_step
);

    localparam int MIN_PERIOD = CLK_HZ / MAX_RATE;    // fastest allowed
    localparam int MAX_PERIOD = CLK_HZ / MIN_RATE;    // slowest allowed

    // Steps between the fastest and the slowest rate, rounded down so
    // the slowest setting never reports less than MIN_RATE.
    localparam int STEP_MAX = $clog2((MAX_RATE / MIN_RATE) + 1) - 1;

    logic [2:0]  rate_step_q;
    logic [25:0] period_count_q;

    // Widened to 32 bits: the shift result would otherwise truncate in
    // the eyes of the linter, even though the values always fit.
    wire [31:0] period = 32'(MIN_PERIOD) << rate_step_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rate_step_q     <= STEP_MAX[2:0];
            period_count_q  <= '0;
            fetch_tick      <= 1'b0;
        end else begin
            fetch_tick <= 1'b0;

            if (btn_double && rate_step_q > '0)
                rate_step_q <= rate_step_q - 3'd1;
            else if (btn_half && rate_step_q < STEP_MAX[2:0])
                rate_step_q <= rate_step_q + 3'd1;

            if (period_count_q + 1'b1 >= 26'(period)) begin
                period_count_q <= '0;
                fetch_tick     <= 1'b1;
            end else begin
                period_count_q <= period_count_q + 1'b1;
            end
        end
    end

    assign rate_hz   = MAX_RATE[5:0] >> rate_step_q;
    assign rate_step = rate_step_q;

endmodule
