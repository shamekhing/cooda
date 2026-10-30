`timescale 1ns/1ps
// ============================================================
// uart_tb  transmit into receive, several bytes and patterns
// ============================================================
module uart_tb;

    localparam int BIT_PERIOD_CYCLES = 27 * 1_000_000 / 115200;

    logic clk = 1'b0;
    always #18.5 clk = ~clk;

    logic rst_n = 1'b0;
    logic serial_tx_pin, serial_rx_pin;
    logic rx_override_enable, rx_override_value;
    logic [7:0] tx_data;
    logic tx_data_valid = 1'b0, tx_data_ready, tx_busy;
    logic [7:0] rx_data;
    logic rx_data_valid, rx_data_ready = 1'b1;

    uart_tx #(.CLOCK_FREQUENCY_MHZ(27), .BAUD_RATE(115200)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .tx_data(tx_data), .tx_data_valid(tx_data_valid),
        .tx_data_ready(tx_data_ready),
        .tx_pin(serial_tx_pin),
        .tx_busy(tx_busy)
    );

    uart_rx #(.CLOCK_FREQUENCY_MHZ(27), .BAUD_RATE(115200)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .rx_pin(serial_rx_pin), .rx_data(rx_data),
        .rx_data_valid(rx_data_valid), .rx_data_ready(rx_data_ready)
    );

    assign serial_rx_pin = rx_override_enable ?
                           rx_override_value : serial_tx_pin;

    int errors = 0;
    int checks = 0;
    int rx_count = 0;
    int rx_before;
    logic [7:0] rx_last;

    always @(posedge clk) begin
        if (rx_data_valid) begin
            rx_last <= rx_data;
            rx_count <= rx_count + 1;
        end
    end

    logic [7:0] test_bytes [0:5];

    task automatic transmit_byte(input logic [7:0] tx_byte);
        // Wait until the TX is idle and able to accept a new byte, then
        // hold valid through the idle-to-start transition so
        // the latch is never missed.
        wait (tx_data_ready);
        @(posedge clk);
        tx_data  <= tx_byte;
        tx_data_valid <= 1'b1;
        @(posedge clk);
        tx_data_valid <= 1'b0;
        // TX latches tx_data on the edge above; now wait it to shift out.
        wait (!tx_busy);
        @(posedge clk);
    endtask

    task automatic transmit_raw_frame(
        input logic [7:0] tx_byte,
        input logic stop_bit_level
    );
        rx_override_enable = 1'b1;
        rx_override_value = 1'b1;
        repeat (3) @(negedge clk);

        rx_override_value = 1'b0;
        repeat (BIT_PERIOD_CYCLES) @(negedge clk);
        for (int bit_index = 0; bit_index < 8; bit_index++) begin
            rx_override_value = tx_byte[bit_index];
            repeat (BIT_PERIOD_CYCLES) @(negedge clk);
        end

        rx_override_value = stop_bit_level;
        repeat (BIT_PERIOD_CYCLES) @(negedge clk);
        rx_override_value = 1'b1;
        repeat (3 * BIT_PERIOD_CYCLES) @(negedge clk);
        rx_override_enable = 1'b0;
        repeat (4) @(negedge clk);
    endtask

    initial begin
        test_bytes[0] = 8'h55;
        test_bytes[1] = 8'h00;
        test_bytes[2] = 8'hFF;
        test_bytes[3] = 8'hA3;
        test_bytes[4] = 8'hC0;
        test_bytes[5] = 8'h01;
    end

    initial begin
        rst_n = 1'b0;
        rx_override_enable = 1'b0;
        rx_override_value = 1'b1;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        for (int i = 0; i < 6; i++) begin
            rx_before = rx_count;
            transmit_byte(test_bytes[i]);
            wait (rx_count == rx_before + 1);   // RX has sampled the byte
            checks++;
            if (rx_last !== test_bytes[i]) begin
                errors++;
                $display("FAIL: rx %02h, expected %02h",
                         rx_last, test_bytes[i]);
            end
        end

        rx_before = rx_count;
        transmit_raw_frame(8'h96, 1'b1);
        checks++;
        if (rx_count != rx_before + 1 || rx_last !== 8'h96) begin
            errors++;
            $display("FAIL: valid stop-bit frame was not received");
        end

        rx_before = rx_count;
        transmit_raw_frame(8'h3C, 1'b0);
        checks++;
        if (rx_count != rx_before) begin
            errors++;
            $display("FAIL: framing-error frame was delivered");
        end

        if (errors == 0)
            $display("PASS: uart %0d checks", checks);
        else
            $display("FAIL: uart %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #10_000_000;
        $display("FAIL: uart timed out");
        $finish;
    end

endmodule
