`timescale 1ns/1ps
// ============================================================
// button_debounce_tb  a raw, bouncing button into one clean pulse
// ============================================================
//
// Drives the raw active-low pin with bounce and checks:
//   1. a bounce shorter than STABLE_CYCLES never produces a press
//   2. a hold longer than STABLE_CYCLES produces exactly one press
//     pulse, on the cycle the level settles
//   3. release produces no press (only a level change)
//
// STABLE_CYCLES is scaled down so the test simulates fast.
// ============================================================

module button_debounce_tb;

    localparam int STABLE = 100;
    localparam int CLK_NS = 37;             // 27 MHz

    logic clk = 1'b0;
    always #(CLK_NS / 2) clk = ~clk;

    logic rst = 1'b1;
    logic btn_n = 1'b1;
    logic pressed, level;

    button_debounce #(.STABLE_CYCLES(STABLE)) u_dut (
        .clk(clk), .rst(rst), .btn_n(btn_n),
        .pressed(pressed), .level(level)
    );

    int errors = 0;
    int checks = 0;

    task automatic expect_press(input logic want);
        checks++;
        if (pressed !== want) begin
            errors++;
            $display("FAIL: pressed=%b at %0t, expected %b", pressed, $time, want);
        end
    endtask

    task automatic step(input int cycles);
        repeat (cycles) @(posedge clk);
        #1;
    endtask

    initial begin
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        step(10);

        // 1. A short bounce: five partial dips, each far shorter than
        //    the stability window. No press may come out.
        repeat (5) begin
            btn_n = 1'b0; step(10);
            btn_n = 1'b1; step(10);
        end
        expect_press(1'b0);
        if (level !== 1'b0) begin
            errors++;
            checks++;
            $display("FAIL: level rose on bounce at %0t", $time);
        end else checks++;
        step(STABLE + 20);                  // let the bounce settle out
        expect_press(1'b0);

        // 2. A real press: held past the window. Exactly one press
        //    pulse, near the settle cycle.
        btn_n = 1'b0;
        step(STABLE - 2);
        expect_press(1'b0);                 // not yet
        step(4);
        expect_press(1'b1);                 // settled: one pulse
        step(2);
        expect_press(1'b0);                 // and only one
        checks++;
        if (level !== 1'b1) begin
            errors++;
            $display("FAIL: level did not rise on a real press at %0t", $time);
        end

        // 3. Hold, then release. Release is not a press.
        step(200);
        expect_press(1'b0);
        btn_n = 1'b1;
        step(STABLE + 20);
        expect_press(1'b0);
        checks++;
        if (level !== 1'b0) begin
            errors++;
            $display("FAIL: level did not fall on release at %0t", $time);
        end

        if (errors == 0)
            $display("PASS: button_debounce %0d checks", checks);
        else
            $display("FAIL: button_debounce %0d checks, %0d errors", checks, errors);
        $finish;
    end

    // Watchdog.
    initial begin
        #100_000;
        $display("FAIL: button_debounce timed out");
        $finish;
    end

endmodule
