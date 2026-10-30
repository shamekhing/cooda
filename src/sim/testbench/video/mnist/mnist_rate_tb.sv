`timescale 1ns/1ps
// ============================================================
// rate_control_tb  the bounded display rate
// ============================================================
//
// The display rate is MAX_RATE >> rate_step, so the buttons move one
// step at a time and the ends hold:
//
//   1. reset starts at the slowest rate
//   2. halving at the bottom and doubling at the top hold
//   3. doubling halves the tick period, measured against the clock
//   4. the reported rate matches the step
//
// Periods are measured for the fast rates only: at one image per
// second a measurement costs a second of simulated time.
// ============================================================

module mnist_rate_tb;

    localparam int CLK_HZ   = 27_000_000;
    localparam int MAX_RATE = 32;
    localparam int MIN_RATE = 1;

    logic clk = 1'b0;
    always #18.518 clk = ~clk;

    logic       rst = 1'b1;
    logic       btn_double, btn_half;
    logic       fetch_tick;
    logic [2:0] rate_step;
    logic [5:0] rate_hz;

    mnist_rate #(
        .CLK_HZ(CLK_HZ), .MAX_RATE(MAX_RATE), .MIN_RATE(MIN_RATE)
    ) dut (
        .clk(clk), .rst(rst),
        .btn_double(btn_double), .btn_half(btn_half),
        .fetch_tick(fetch_tick), .rate_step(rate_step), .rate_hz(rate_hz)
    );

    int errors = 0;
    int checks = 0;

    // One button press: the debouncer is upstream, so this is the
    // one-cycle pulse it would emit.
    task automatic press(input logic which);
        @(negedge clk);
        if (which) btn_double = 1'b1; else btn_half = 1'b1;
        @(negedge clk);
        btn_double = 1'b0;
        btn_half   = 1'b0;
    endtask

    // Check the tick period against the rate the module reports: the
    // number of clock edges between two ticks.
    int clk_edges = 0;
    always @(posedge clk) clk_edges++;

    task automatic check_period(input int expect_cycles, input string name);
        int first_edge;
        int ticks;
        int measured;
        ticks = 0;
        while (ticks < 2) begin
            @(negedge clk);
            if (fetch_tick) begin
                ticks++;
                if (ticks == 1) first_edge = clk_edges;
                else measured = clk_edges - first_edge;
            end
        end
        checks++;
        if (measured != expect_cycles) begin
            errors++;
            $display("FAIL %s: %0d cycles between ticks, expected %0d (rate %0d/s)",
                     name, measured, expect_cycles, rate_hz);
        end
        checks++;
        if (rate_hz !== (MAX_RATE >> rate_step)) begin
            errors++;
            $display("FAIL %s: rate_hz %0d does not match step %0d",
                     name, rate_hz, rate_step);
        end
    endtask

    int step_expect;
    // ========================================================
    // SEQUENCE
    // ========================================================

    initial begin
        btn_double = 1'b0;
        btn_half = 1'b0;

        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);

        // 1. after reset: the slowest rate.
        checks++;
        if (rate_step !== 3'd5 || rate_hz !== MIN_RATE[5:0]) begin
            errors++;
            $display("FAIL after reset: step %0d rate %0d, expected 5/%0d",
                     rate_step, rate_hz, MIN_RATE);
        end

        // 2. halving at the bottom holds.
        press(0);
        checks++;
        if (rate_step !== 3'd5 || rate_hz !== MIN_RATE[5:0]) begin
            errors++;
            $display("FAIL halve at bottom: step %0d rate %0d",
                     rate_step, rate_hz);
        end

        // 3. doubling: one step per press, and the period follows.
        press(1);
        checks++;
        if (rate_step !== 3'd4 || rate_hz !== (MAX_RATE >> 4)) begin
            errors++;
            $display("FAIL double: step %0d rate %0d, expected 4/%0d",
                     rate_step, rate_hz, MAX_RATE >> 4);
        end
        check_period(CLK_HZ / (MAX_RATE >> 4), "period at rate 2");

        press(1);
        check_period(CLK_HZ / (MAX_RATE >> 3), "period at rate 4");

        // 4. doubling to the top and past it: the rate holds.
        repeat (3) press(1);
        checks++;
        if (rate_hz !== MAX_RATE[5:0] || rate_step !== 3'd0) begin
            errors++;
            $display("FAIL double at top: step %0d rate %0d, expected 0/%0d",
                     rate_step, rate_hz, MAX_RATE);
        end
        press(1);
        checks++;
        if (rate_hz !== MAX_RATE[5:0] || rate_step !== 3'd0) begin
            errors++;
            $display("FAIL double past top: step %0d rate %0d",
                     rate_step, rate_hz);
        end
        check_period(CLK_HZ / MAX_RATE, "period at the top rate");

        // 5. halving back down steps one at a time.
        press(0);
        checks++;
        if (rate_hz !== (MAX_RATE >> 1)) begin
            errors++;
            $display("FAIL halve from top: rate %0d, expected %0d",
                     rate_hz, MAX_RATE >> 1);
        end

        if (errors == 0)
            $display("PASS: mnist_rate %0d checks", checks);
        else
            $fatal(1, "FAIL: mnist_rate %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #10_000_000_000;
        $fatal(1, "mnist_rate_tb timeout");
    end

endmodule

