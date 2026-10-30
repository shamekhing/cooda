`timescale 1ns/1ps

// Exercise the UART image protocol, DDR3 writes, checksum validation,
// status responses, and timeout handling with a small bus target.
module mnist_uart_loader_tb;
    localparam int CLOCK_FREQUENCY_MHZ = 27;
    localparam int BAUD_RATE = 921600;
    localparam int BIT_PERIOD_CYCLES =
        CLOCK_FREQUENCY_MHZ * 1_000_000 / BAUD_RATE;
    localparam logic [31:0] DDR3_BASE = 32'h0800_0000;

    logic clk = 1'b0;
    always #18.5 clk = ~clk;

    logic rst = 1'b1;
    logic ddr_ready = 1'b0;
    logic host_uart_tx = 1'b1;
    logic device_uart_tx;
    logic host_ready, load_done, load_error;
    logic [3:0] error_code;
    logic [7:0] host_status_data;
    logic host_status_valid;
    soc_pkg::bus_req_s bus_req;
    soc_pkg::bus_rsp_s bus_rsp;

    mnist_uart_loader #(
        .BAUD_RATE(BAUD_RATE),
        .RX_TIMEOUT_CYCLES(20_000)
    ) u_uart_loader (
        .clk(clk),
        .rst(rst),
        .ddr_ready(ddr_ready),
        .uart_rx_pin(host_uart_tx),
        .uart_tx_pin(device_uart_tx),
        .host_ready(host_ready),
        .load_done(load_done),
        .load_error(load_error),
        .error_code(error_code),
        .bus_req(bus_req),
        .bus_rsp(bus_rsp)
    );

    uart_rx #(
        .CLOCK_FREQUENCY_MHZ(CLOCK_FREQUENCY_MHZ),
        .BAUD_RATE(BAUD_RATE)
    ) u_status_rx (
        .clk(clk),
        .rst_n(!rst),
        .rx_pin(device_uart_tx),
        .rx_data(host_status_data),
        .rx_data_valid(host_status_valid),
        .rx_data_ready(1'b1)
    );

    logic [31:0] target_memory [0:127];
    logic [31:0] target_write_count = 0;
    logic target_accept;
    int checks = 0;
    int errors = 0;

    assign target_accept = bus_req.valid && !bus_rsp.ready;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bus_rsp <= '0;
            target_write_count <= '0;
        end else begin
            bus_rsp.ready <= target_accept;
            bus_rsp.error <= 1'b0;
            if (target_accept) begin
                if (bus_req.op != soc_pkg::BusWrite ||
                    bus_req.wstrb != soc_pkg::BUS_STRB_ALL) begin
                    bus_rsp.error <= 1'b1;
                end else begin
                    target_memory[(bus_req.addr - DDR3_BASE) >> 2] <= bus_req.wdata;
                    target_write_count <= target_write_count + 1'b1;
                end
            end
        end
    end

    task automatic send_uart_byte(input logic [7:0] data);
        begin
            host_uart_tx = 1'b0;
            repeat (BIT_PERIOD_CYCLES) @(negedge clk);
            for (int bit_index = 0; bit_index < 8; bit_index++) begin
                host_uart_tx = data[bit_index];
                repeat (BIT_PERIOD_CYCLES) @(negedge clk);
            end
            host_uart_tx = 1'b1;
            repeat (BIT_PERIOD_CYCLES) @(negedge clk);
        end
    endtask

    task automatic set_header_word(input int index, input logic [31:0] value);
        for (int lane = 0; lane < 4; lane++)
            header[index * 4 + lane] = value[8 * lane +: 8];
    endtask

    logic [7:0] header [0:511];
    logic [7:0] payload [0:6];

    task automatic send_image(input logic bad_magic, input logic bad_checksum);
        begin
            for (int i = 0; i < 512; i++)
                header[i] = 8'd0;
            set_header_word(0, bad_magic ? 32'hBAD0_0000 : 32'h434F_4F44);
            set_header_word(1, 32'd1);
            set_header_word(2, 32'h0000_0100);
            set_header_word(3, 32'd7);
            set_header_word(4, 32'd1);
            set_header_word(5, 32'd2);
            set_header_word(6, 32'd3);
            set_header_word(7, 32'd1);
            set_header_word(8, bad_checksum ? 32'd477 : 32'd476);
            for (int i = 0; i < 512; i++)
                send_uart_byte(header[i]);
            payload[0] = 8'h11;
            payload[1] = 8'h22;
            payload[2] = 8'h33;
            payload[3] = 8'h44;
            payload[4] = 8'h55;
            payload[5] = 8'h66;
            payload[6] = 8'h77;
            if (!bad_magic) begin
                for (int i = 0; i < 7; i++)
                    send_uart_byte(payload[i]);
            end
        end
    endtask

    task automatic expect_status(input logic [7:0] expected);
        begin
            while (!host_status_valid)
                @(negedge clk);
            checks++;
            if (host_status_data !== expected) begin
                errors++;
                $display("FAIL: status %02h, expected %02h",
                         host_status_data, expected);
            end
            @(negedge clk);
        end
    endtask

    initial begin
        for (int i = 0; i < 128; i++)
            target_memory[i] = '0;

        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);
        checks++;
        if (host_ready) begin
            errors++;
            $display("FAIL: loader reported ready before DDR3 calibration");
        end

        ddr_ready = 1'b1;
        expect_status(8'h52);
        send_image(1'b0, 1'b0);
        expect_status(8'h44);

        checks++;
        if (!load_done || load_error || host_ready) begin
            errors++;
            $display("FAIL: successful image did not complete cleanly");
        end
        checks++;
        if (target_write_count != 2 ||
            target_memory[64] != 32'h4433_2211 ||
            target_memory[65] != 32'h0077_6655) begin
            errors++;
            $display("FAIL: payload DDR words/count are incorrect");
        end

        rst = 1'b1;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);
        expect_status(8'h52);
        send_image(1'b1, 1'b0);
        expect_status(8'h45);
        expect_status(8'h01);

        checks++;
        if (!load_error || error_code != 1 || load_done) begin
            errors++;
            $display("FAIL: invalid image magic was not rejected");
        end

        rst = 1'b1;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);
        expect_status(8'h52);
        send_image(1'b0, 1'b1);
        expect_status(8'h45);
        expect_status(8'h04);

        checks++;
        if (!load_error || error_code != 4 || load_done) begin
            errors++;
            $display("FAIL: invalid payload checksum was not rejected");
        end

        rst = 1'b1;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);
        expect_status(8'h52);
        send_uart_byte(8'h44);
        wait (load_error);
        expect_status(8'h45);
        expect_status(8'h05);

        checks++;
        if (!load_error || error_code != 5 || load_done) begin
            errors++;
            $display("FAIL: partial-header timeout was not reported");
        end

        if (errors == 0)
            $display("PASS: mnist_uart_loader %0d checks", checks);
        else
            $fatal(1, "FAIL: mnist_uart_loader %0d checks, %0d errors",
                   checks, errors);
        $finish;
    end

    initial begin
        #30_000_000;
        $fatal(1, "mnist_uart_loader_tb timeout");
    end
endmodule
