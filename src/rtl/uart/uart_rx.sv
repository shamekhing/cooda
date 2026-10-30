// ============================================================
// uart_rx  8N1 UART receive with a ready/valid handshake
// ============================================================
//
// Ported from the vendor UART example (examples/UART), which is proven
// on this board's BL616 USB serial. Two-flop sync on the pin, the
// start bit confirmed at its centre (a shorter glitch is dropped), the
// eight data bits sampled LSB first at their centres, and the stop bit
// required high - a framing error drops the byte.
//
// The byte is held until the caller takes it: rx_data_valid stays high
// until rx_data_ready.
// ============================================================

module uart_rx #(
    parameter int CLOCK_FREQUENCY_MHZ = 27,
    parameter int BAUD_RATE = 115200
) (
    input  logic       clk,
    input  logic       rst_n,               // active low

    input  logic       rx_pin,
    output logic [7:0] rx_data,
    output logic       rx_data_valid,
    input  logic       rx_data_ready
);
    localparam int BIT_PERIOD_CYCLES =
        CLOCK_FREQUENCY_MHZ * 1_000_000 / BAUD_RATE;
    localparam int CYCLE_COUNT_WIDTH =
        (BIT_PERIOD_CYCLES <= 1) ? 1 : $clog2(BIT_PERIOD_CYCLES + 1);
    localparam logic [CYCLE_COUNT_WIDTH-1:0] BIT_PERIOD_LAST =
        BIT_PERIOD_CYCLES - 1;
    localparam logic [CYCLE_COUNT_WIDTH-1:0] START_MIDPOINT =
        BIT_PERIOD_CYCLES / 2 - 1;

    typedef enum logic [2:0] {
        UartRxIdle = 3'd1,
        UartRxStart = 3'd2,
        UartRxByte = 3'd3,
        UartRxStop = 3'd4,
        UartRxHold = 3'd5
    } uart_rx_state_e;

    uart_rx_state_e state_q, state_d;

    logic rx_sync1_q, rx_sync2_q;
    logic rx_falling_edge;

    logic [7:0] rx_shift_q;
    logic [CYCLE_COUNT_WIDTH-1:0] cycle_count_q;
    logic [2:0] bit_index_q;

    assign rx_falling_edge = rx_sync2_q & ~rx_sync1_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1_q <= 1'b1;
            rx_sync2_q <= 1'b1;
        end else begin
            rx_sync1_q <= rx_pin;
            rx_sync2_q <= rx_sync1_q;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= UartRxIdle;
        else        state_q <= state_d;
    end

    always_comb begin
        case (state_q)
            UartRxIdle: begin
                if (rx_falling_edge) state_d = UartRxStart;
                else                 state_d = UartRxIdle;
            end

            // The start bit: confirm at half-bit, else it was a glitch.
            UartRxStart: begin
                if (cycle_count_q == START_MIDPOINT) begin
                    if (rx_sync1_q) state_d = UartRxIdle;
                    else            state_d = UartRxByte;
                end else begin
                    state_d = UartRxStart;
                end
            end

            UartRxByte: begin
                if (cycle_count_q == BIT_PERIOD_LAST && bit_index_q == 7)
                    state_d = UartRxStop;
                else
                    state_d = UartRxByte;
            end

            // The last data bit was sampled at its centre, so wait one
            // full bit period to sample the stop bit at its centre.
            UartRxStop: begin
                if (cycle_count_q == BIT_PERIOD_LAST) begin
                    if (rx_sync1_q) state_d = UartRxHold;
                    else            state_d = UartRxIdle;
                end else begin
                    state_d = UartRxStop;
                end
            end

            UartRxHold: begin
                if (rx_data_ready) state_d = UartRxIdle;
                else               state_d = UartRxHold;
            end

            default: state_d = UartRxIdle;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycle_count_q <= '0;
        else if (state_d != state_q) cycle_count_q <= '0;
        else if (state_q == UartRxStart) begin
            // Confirm the start bit at its midpoint.
            if (cycle_count_q == START_MIDPOINT) cycle_count_q <= '0;
            else                                  cycle_count_q <= cycle_count_q + 1'b1;
        end else begin
            if (cycle_count_q == BIT_PERIOD_LAST) cycle_count_q <= '0;
            else                                  cycle_count_q <= cycle_count_q + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) bit_index_q <= '0;
        else if (state_q == UartRxByte) begin
            if (cycle_count_q == BIT_PERIOD_LAST)
                bit_index_q <= bit_index_q + 3'd1;
        end else begin
            bit_index_q <= '0;
        end
    end

    // The data bits, LSB first, sampled at their centres.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_shift_q <= '0;
        else if (state_q == UartRxByte && cycle_count_q == BIT_PERIOD_LAST)
            rx_shift_q[bit_index_q] <= rx_sync1_q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_data <= '0;
        else if (state_q == UartRxStop && state_d == UartRxHold)
            rx_data <= rx_shift_q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_data_valid <= 1'b0;
        else if (state_q == UartRxStop && state_d == UartRxHold)
            rx_data_valid <= 1'b1;
        else if (state_q == UartRxHold && rx_data_ready)
            rx_data_valid <= 1'b0;
    end

endmodule
