// ============================================================
// mnist_uart_loader  PC UART image receiver and DDR3 bus master
// ============================================================
//
// Receives the COOD packed-image format used by tools/mnist/mnist_pack.py:
// a 512-byte little-endian header followed by the unpadded payload.
// The payload is checksummed while received, packed into little-endian
// 32-bit words, and written to the DDR3 window through the SoC bus.
// The final partial word is zero-padded. The loader does not release
// the host until DDR3 calibration has completed.
//
// UART protocol (8N1, LSB first):
//   FPGA -> host: 'R' ready, 'D' done, or 'E' followed by an error code
//   host -> FPGA: 512-byte header, then header word 3 payload bytes
//
// Error codes: 1 bad magic, 2 inconsistent payload length, 3 invalid
// destination, 4 checksum mismatch, 5 receive timeout, 6 DDR bus error.
// ============================================================
module mnist_uart_loader #(
    parameter int CLOCK_FREQUENCY_MHZ = 27,
    parameter int BAUD_RATE = 921600,
    parameter logic [31:0] DDR3_BASE = 32'h0800_0000,
    parameter logic [31:0] DDR3_SIZE = 32'h0800_0000,
    parameter int RX_TIMEOUT_CYCLES = 135_000_000 // 5 s at 27 MHz
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             ddr_ready,
    input  logic             uart_rx_pin,
    output logic             uart_tx_pin,
    output logic             host_ready,
    output logic             load_done,
    output logic             load_error,
    output logic [3:0]       error_code,
    output soc_pkg::bus_req_s bus_req,
    input  soc_pkg::bus_rsp_s bus_rsp
);
    localparam logic [31:0] IMAGE_MAGIC = 32'h434F_4F44;

    // The host may begin only after DDR3 is usable and the FPGA reports R.
    typedef enum logic [3:0] {
        UartWaitDdr,
        UartSendReady,
        UartWaitReadyTx,
        UartReceiveHeader,
        UartValidateHeader,
        UartReceivePayload,
        UartSendDone,
        UartWaitDoneTx,
        UartSendError,
        UartWaitErrorTx,
        UartSendErrorCode,
        UartWaitErrorCodeTx,
        UartFailed
    } uart_loader_state_e;

    uart_loader_state_e state_q;

    logic [7:0] rx_data;
    logic rx_data_valid, rx_data_ready;
    logic [7:0] tx_data_q;
    logic tx_data_valid_q, tx_data_ready;

    logic [8:0] header_byte_count_q;
    logic [31:0] header_words_q [0:3];
    logic [31:0] expected_checksum_q;

    logic [31:0] payload_remaining_q;
    logic [31:0] checksum_q;
    logic [1:0] payload_byte_index_q;
    logic [31:0] word_buffer_q;
    logic [31:0] assembled_word;

    logic [31:0] write_addr_q, bus_addr_q, write_data_q;
    logic write_pending_q;
    logic [31:0] inactivity_cycles_q;

    logic [32:0] payload_end;
    logic [32:0] padded_payload_end;
    logic [32:0] blocks_required;
    logic rx_accept;

    // The serial engines run on the SoC clock; rx_data_ready provides
    // backpressure while a received payload word is being committed.
    uart_rx #(
        .CLOCK_FREQUENCY_MHZ(CLOCK_FREQUENCY_MHZ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uart_rx (
        .clk(clk),
        .rst_n(!rst),
        .rx_pin(uart_rx_pin),
        .rx_data(rx_data),
        .rx_data_valid(rx_data_valid),
        .rx_data_ready(rx_data_ready)
    );

    uart_tx #(
        .CLOCK_FREQUENCY_MHZ(CLOCK_FREQUENCY_MHZ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uart_tx (
        .clk(clk),
        .rst_n(!rst),
        .tx_data(tx_data_q),
        .tx_data_valid(tx_data_valid_q),
        .tx_data_ready(tx_data_ready),
        .tx_pin(uart_tx_pin),
        .tx_busy()
    );

    assign host_ready = (state_q == UartReceiveHeader) ||
                        (state_q == UartReceivePayload);
    assign rx_data_ready = (state_q == UartReceiveHeader) ||
                           ((state_q == UartReceivePayload) && !write_pending_q);
    assign rx_accept = rx_data_valid && rx_data_ready;

    assign payload_end = {1'b0, header_words_q[2]} +
                         {1'b0, header_words_q[3]};
    assign padded_payload_end = (payload_end + 33'd3) & 33'h1_FFFF_FFFC;
    assign blocks_required =
        ({1'b0, header_words_q[3]} + 33'd511) >> 9;

    // A held bus request is stable until the target returns ready.
    always_comb begin
        assembled_word = word_buffer_q;
        assembled_word[8*payload_byte_index_q +: 8] = rx_data;

        bus_req = '0;
        bus_req.valid = write_pending_q;
        bus_req.op = soc_pkg::BusWrite;
        bus_req.addr = bus_addr_q;
        bus_req.wdata = write_data_q;
        bus_req.wstrb = soc_pkg::BUS_STRB_ALL;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q <= UartWaitDdr;
            header_byte_count_q <= '0;
            header_words_q[0] <= '0;
            header_words_q[1] <= '0;
            header_words_q[2] <= '0;
            header_words_q[3] <= '0;
            expected_checksum_q <= '0;
            payload_remaining_q <= '0;
            checksum_q <= '0;
            payload_byte_index_q <= '0;
            word_buffer_q <= '0;
            write_addr_q <= '0;
            bus_addr_q <= '0;
            write_data_q <= '0;
            write_pending_q <= 1'b0;
            inactivity_cycles_q <= '0;
            tx_data_q <= '0;
            tx_data_valid_q <= 1'b0;
            load_done <= 1'b0;
            load_error <= 1'b0;
            error_code <= '0;
        end else begin
            if (tx_data_valid_q && tx_data_ready)
                tx_data_valid_q <= 1'b0;

            // Finish a DDR write before accepting the next payload byte.
            if (write_pending_q && bus_rsp.ready) begin
                write_pending_q <= 1'b0;
                if (bus_rsp.error) begin
                    error_code <= 4'd6;
                    load_error <= 1'b1;
                    state_q <= UartSendError;
                end else if (payload_remaining_q == 0) begin
                    if (checksum_q == expected_checksum_q) begin
                        load_done <= 1'b1;
                        state_q <= UartSendDone;
                    end else begin
                        error_code <= 4'd4;
                        load_error <= 1'b1;
                        state_q <= UartSendError;
                    end
                end
            end

            // A silent host while waiting for a new header is recoverable:
            // resend R. A timeout after any partial transfer is an error.
            if ((state_q == UartReceiveHeader) ||
                (state_q == UartReceivePayload)) begin
                if (rx_accept) begin
                    inactivity_cycles_q <= '0;
                end else if (!write_pending_q) begin
                    if (inactivity_cycles_q == RX_TIMEOUT_CYCLES - 1) begin
                        inactivity_cycles_q <= '0;
                        if ((state_q == UartReceiveHeader) &&
                            (header_byte_count_q == 0)) begin
                            state_q <= UartSendReady;
                        end else begin
                            error_code <= 4'd5;
                            load_error <= 1'b1;
                            state_q <= UartSendError;
                        end
                    end else begin
                        inactivity_cycles_q <= inactivity_cycles_q + 1'b1;
                    end
                end
            end else begin
                inactivity_cycles_q <= '0;
            end

            case (state_q)
                UartWaitDdr: begin
                    if (ddr_ready)
                        state_q <= UartSendReady;
                end

                UartSendReady: begin
                    if (!tx_data_valid_q && tx_data_ready) begin
                        tx_data_q <= 8'h52;
                        tx_data_valid_q <= 1'b1;
                        state_q <= UartWaitReadyTx;
                    end
                end

                UartWaitReadyTx: begin
                    if (tx_data_valid_q && tx_data_ready) begin
                        header_byte_count_q <= '0;
                        header_words_q[0] <= '0;
                        header_words_q[1] <= '0;
                        header_words_q[2] <= '0;
                        header_words_q[3] <= '0;
                        expected_checksum_q <= '0;
                        state_q <= UartReceiveHeader;
                    end
                end

                // Header words 0..3 occupy bytes 0..15; checksum is word 8.
                // The rest of the fixed-size header is reserved.
                UartReceiveHeader: begin
                    if (rx_accept) begin
                        if (header_byte_count_q < 9'd16) begin
                            header_words_q[header_byte_count_q[4:2]]
                                [8*header_byte_count_q[1:0] +: 8] <= rx_data;
                        end else if ((header_byte_count_q >= 9'd32) &&
                                     (header_byte_count_q < 9'd36)) begin
                            expected_checksum_q
                                [8*header_byte_count_q[1:0] +: 8] <= rx_data;
                        end

                        if (header_byte_count_q == 9'd511) begin
                            state_q <= UartValidateHeader;
                        end else begin
                            header_byte_count_q <= header_byte_count_q + 1'b1;
                        end
                    end
                end

                // Validate the full unpadded payload against its block
                // declaration and the configured DDR3 window before writing.
                UartValidateHeader: begin
                    if (header_words_q[0] != IMAGE_MAGIC) begin
                        error_code <= 4'd1;
                        load_error <= 1'b1;
                        state_q <= UartSendError;
                    end else if ((header_words_q[1] == 0) ||
                                 (header_words_q[3] == 0) ||
                                 (blocks_required != {1'b0, header_words_q[1]}) ||
                                 ({1'b0, header_words_q[3]} >
                                  ({1'b0, header_words_q[1]} << 9))) begin
                        error_code <= 4'd2;
                        load_error <= 1'b1;
                        state_q <= UartSendError;
                    end else if ((header_words_q[2][1:0] != 0) ||
                                 (padded_payload_end > {1'b0, DDR3_SIZE})) begin
                        error_code <= 4'd3;
                        load_error <= 1'b1;
                        state_q <= UartSendError;
                    end else begin
                        payload_remaining_q <= header_words_q[3];
                        checksum_q <= '0;
                        payload_byte_index_q <= '0;
                        word_buffer_q <= '0;
                        write_addr_q <= DDR3_BASE + header_words_q[2];
                        state_q <= UartReceivePayload;
                    end
                end

                // Assemble bytes little-endian, committing each full word
                // and zero-padding only the final partial word.
                UartReceivePayload: begin
                    if (rx_accept) begin
                        checksum_q <= checksum_q + {24'd0, rx_data};
                        payload_remaining_q <= payload_remaining_q - 1'b1;

                        if ((payload_byte_index_q == 2'd3) ||
                            (payload_remaining_q == 1)) begin
                            write_pending_q <= 1'b1;
                            bus_addr_q <= write_addr_q;
                            write_data_q <= assembled_word;
                            write_addr_q <= write_addr_q + 32'd4;
                            word_buffer_q <= '0;
                            payload_byte_index_q <= '0;
                        end else begin
                            word_buffer_q <= assembled_word;
                            payload_byte_index_q <= payload_byte_index_q + 1'b1;
                        end
                    end
                end

                UartSendDone: begin
                    if (!tx_data_valid_q && tx_data_ready) begin
                        tx_data_q <= 8'h44;
                        tx_data_valid_q <= 1'b1;
                        state_q <= UartWaitDoneTx;
                    end
                end

                UartWaitDoneTx: begin
                    if (tx_data_valid_q && tx_data_ready)
                        state_q <= UartFailed;
                end

                UartSendError: begin
                    if (!tx_data_valid_q && tx_data_ready) begin
                        tx_data_q <= 8'h45;
                        tx_data_valid_q <= 1'b1;
                        state_q <= UartWaitErrorTx;
                    end
                end

                UartWaitErrorTx: begin
                    if (tx_data_valid_q && tx_data_ready)
                        state_q <= UartSendErrorCode;
                end

                UartSendErrorCode: begin
                    if (!tx_data_valid_q && tx_data_ready) begin
                        tx_data_q <= {4'd0, error_code};
                        tx_data_valid_q <= 1'b1;
                        state_q <= UartWaitErrorCodeTx;
                    end
                end

                UartWaitErrorCodeTx: begin
                    if (tx_data_valid_q && tx_data_ready)
                        state_q <= UartFailed;
                end

                UartFailed: begin
                    state_q <= UartFailed;
                end

                default: state_q <= UartWaitDdr;
            endcase
        end
    end

endmodule
