// ============================================================
// button_debounce  a dock button into one clean press pulse
// ============================================================
//
// Buttons on the dock are active low and bounce for milliseconds.
// This synchronises the raw pin, waits for it to hold one level for
// STABLE_CYCLES, and then reports the press as a single-cycle pulse
// and as a level, so a caller can choose.
//
// stable_q holds the debounced RAW pin level, so it resets to the
// released state and a press is a falling edge of it - the press
// pulse fires when the button goes down, not when it comes up, and
// power-up does not look like a press.
// ============================================================

module button_debounce #(
    parameter int STABLE_CYCLES = 540_000    // 20 ms at 27 MHz
) (
    input  logic clk,
    input  logic rst,
    input  logic btn_n,                      // raw pin, active low
    output logic pressed,                    // one cycle per press
    output logic level                       // 1 = held down
);

    logic btn_sync1, btn_sync2;
    logic stable_q;
    logic level_prev_q;
    // Wide enough to count to STABLE_CYCLES: at 540_000 a 19-bit
    // counter would wrap before ever matching, and the press would
    // never register (synthesis sweeps the whole button path away).
    logic [$clog2(STABLE_CYCLES)-1:0] count_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            btn_sync1 <= 1'b1;
            btn_sync2 <= 1'b1;
            stable_q  <= 1'b1;               // the released level
            count_q   <= '0;
        end else begin
            btn_sync1 <= btn_n;
            btn_sync2 <= btn_sync1;

            if (btn_sync2 == stable_q) begin
                count_q <= '0;
            end else begin
                count_q <= count_q + 1'b1;
                if (count_q == STABLE_CYCLES - 1) begin
                    stable_q <= btn_sync2;
                    count_q  <= '0;
                end
            end
        end
    end

    assign level   = ~stable_q;              // 1 = held down
    // A press is the debounced level's falling edge, one cycle wide.
    assign pressed = level & ~level_prev_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) level_prev_q <= 1'b0;
        else level_prev_q <= level;
    end

endmodule
