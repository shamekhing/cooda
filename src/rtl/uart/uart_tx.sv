// ============================================================
// uart_tx  8N1 UART transmit with a ready/valid handshake
// ============================================================
//
// Ported from the vendor UART example (examples/UART), proven on this
// board's BL616 USB serial. Latch tx_data while idle when
// tx_data_valid, shift out the start bit, eight data bits (LSB first),
// and the stop bit. Each serial bit lasts BIT_PERIOD_CYCLES clock cycles.
// ============================================================

module uart_tx #(
    parameter int CLOCK_FREQUENCY_MHZ = 27,
    parameter int BAUD_RATE = 115200
) (
    input  logic       clk,
    input  logic       rst_n,               // active low

    input  logic [7:0] tx_data,
    input  logic       tx_data_valid,
    output logic       tx_data_ready,
    output logic       tx_pin,
    output logic       tx_busy
);
    localparam int BIT_PERIOD_CYCLES =
        CLOCK_FREQUENCY_MHZ * 1_000_000 / BAUD_RATE;
    localparam int CYCLE_COUNT_WIDTH =
        (BIT_PERIOD_CYCLES <= 1) ? 1 : $clog2(BIT_PERIOD_CYCLES + 1);
    localparam logic [CYCLE_COUNT_WIDTH-1:0] BIT_PERIOD_LAST =
        BIT_PERIOD_CYCLES - 1;

    typedef enum logic [2:0] {
        UartTxIdle  = 3'd1,
        UartTxStart = 3'd2,
        UartTxData  = 3'd3,
        UartTxStop  = 3'd4
    } uart_tx_state_e;

    uart_tx_state_e state_q, state_d;
    logic [CYCLE_COUNT_WIDTH-1:0] cycle_count_q;
    logic [2:0] bit_index_q;
    logic [7:0] tx_data_q;
    logic tx_pin_q;

    wire bit_tick = (cycle_count_q == BIT_PERIOD_LAST);
    wire accept_data = (state_q == UartTxIdle) && tx_data_valid;

    assign tx_data_ready = (state_q == UartTxIdle);
    assign tx_busy = (state_q != UartTxIdle);
    assign tx_pin = tx_pin_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= UartTxIdle;
        else        state_q <= state_d;
    end

    always_comb begin
        case (state_q)
            UartTxIdle: begin
                if (tx_data_valid) state_d = UartTxStart;
                else               state_d = UartTxIdle;
            end

            UartTxStart: begin
                if (bit_tick) state_d = UartTxData;
                else          state_d = UartTxStart;
            end

            UartTxData: begin
                if (bit_tick && bit_index_q == 7) state_d = UartTxStop;
                else                              state_d = UartTxData;
            end

            UartTxStop: begin
                if (bit_tick) state_d = UartTxIdle;
                else          state_d = UartTxStop;
            end

            default: state_d = UartTxIdle;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycle_count_q <= '0;
        else if (state_d != state_q) cycle_count_q <= '0;
        else begin
            if (bit_tick) cycle_count_q <= '0;
            else          cycle_count_q <= cycle_count_q + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) bit_index_q <= '0;
        else if (state_q == UartTxData) begin
            if (bit_tick) bit_index_q <= bit_index_q + 3'd1;
        end else begin
            bit_index_q <= '0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) tx_data_q <= '0;
        else if (accept_data) tx_data_q <= tx_data;
    end

    // The serial line: low for the start bit, the data bits LSB first,
    // high for the stop bit.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) tx_pin_q <= 1'b1;
        else begin
            case (state_q)
                UartTxIdle:  tx_pin_q <= 1'b1;
                UartTxStart: tx_pin_q <= 1'b0;
                UartTxData:  tx_pin_q <= tx_data_q[bit_index_q];
                UartTxStop:  tx_pin_q <= 1'b1;
                default:     tx_pin_q <= 1'b1;
            endcase
        end
    end

endmodule
