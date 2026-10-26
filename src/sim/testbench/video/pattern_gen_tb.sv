`timescale 1ns/1ps

// ============================================================
// pattern_gen testbench
// ============================================================
//
// pattern_gen is purely combinational, so this testbench drives
// de/x/y/mode/colour/invert directly and checks the pixel that comes
// back. Nothing here needs a clock.
//
// Checks:
//   mode 0  colour bars, all eight, at their true x boundaries
//   mode 1  grid, on and off the 32 pixel lines
//   mode 2  grey ramp tracks x
//   mode 3  flat colour, all four selections
//   invert  XORs with white
//   de low  forces black in every mode
// ============================================================

module pattern_gen_tb;

    localparam int BAR_W = 1280 / 8;   // 160

    localparam logic [23:0] WHITE   = 24'hFFFFFF;
    localparam logic [23:0] YELLOW  = 24'hFFFF00;
    localparam logic [23:0] CYAN    = 24'h00FFFF;
    localparam logic [23:0] GREEN   = 24'h00FF00;
    localparam logic [23:0] MAGENTA = 24'hFF00FF;
    localparam logic [23:0] RED     = 24'hFF0000;
    localparam logic [23:0] BLUE    = 24'h0000FF;
    localparam logic [23:0] BLACK   = 24'h000000;

    logic        de;
    logic [11:0] x;
    logic [11:0] y;
    logic [1:0]  mode;
    logic [1:0]  colour;
    logic        invert;
    logic [7:0]  r;
    logic [7:0]  g;
    logic [7:0]  b;

    pattern_gen dut (
        .de     (de),
        .x      (x),
        .y      (y),
        .mode   (mode),
        .colour (colour),
        .invert (invert),
        .r      (r),
        .g      (g),
        .b      (b)
    );

    task automatic check_pixel(
        input logic [1:0]  t_mode,
        input logic [1:0]  t_colour,
        input logic        t_invert,
        input logic        t_de,
        input logic [11:0] t_x,
        input logic [11:0] t_y,
        input logic [23:0] expected,
        input string       label
    );
        mode   = t_mode;
        colour = t_colour;
        invert = t_invert;
        de     = t_de;
        x      = t_x;
        y      = t_y;
        #1;

        if ({r, g, b} !== expected)
            $fatal(1, "%s: mode=%0d colour=%0d invert=%0b de=%0b x=%0d y=%0d gave %06h, expected %06h",
                   label, t_mode, t_colour, t_invert, t_de, t_x, t_y, {r, g, b}, expected);
    endtask

    initial begin

        $dumpfile("pattern_gen.vcd");
        $dumpvars(0, pattern_gen_tb);

        // ---- mode 0: colour bars, checked at each true boundary ----
        check_pixel(2'd0, 2'd0, 1'b0, 1'b1, 12'd0,           12'd0, WHITE,   "bar 0");
        check_pixel(2'd0, 2'd0, 1'b0, 1'b1, 12'(BAR_W-1),    12'd0, WHITE,   "bar 0 last");
        check_pixel(2'd0, 2'd0, 1'b0, 1'b1, 12'(BAR_W),      12'd0, YELLOW,  "bar 1 first");
        check_pixel(2'd0, 2'd0, 1'b0, 1'b1, 12'(2*BAR_W),    12'd0, CYAN,    "bar 2");
        check_pixel(2'd0, 2'd0, 1'b0, 1'b1, 12'(3*BAR_W),    12'd0, GREEN,   "bar 3");
        check_pixel(2'd0, 2'd0, 1'b0, 1'b1, 12'(4*BAR_W),    12'd0, MAGENTA, "bar 4");
        check_pixel(2'd0, 2'd0, 1'b0, 1'b1, 12'(5*BAR_W),    12'd0, RED,     "bar 5");
        check_pixel(2'd0, 2'd0, 1'b0, 1'b1, 12'(6*BAR_W),    12'd0, BLUE,    "bar 6");
        check_pixel(2'd0, 2'd0, 1'b0, 1'b1, 12'(7*BAR_W),    12'd0, BLACK,   "bar 7");
        check_pixel(2'd0, 2'd0, 1'b0, 1'b1, 12'd1279,        12'd0, BLACK,   "bar 7 last");

        // ---- mode 1: grid ----
        check_pixel(2'd1, 2'd0, 1'b0, 1'b1, 12'd0,   12'd0,  RED,   "grid origin");
        check_pixel(2'd1, 2'd0, 1'b0, 1'b1, 12'd1,   12'd1,  BLACK, "grid interior");
        check_pixel(2'd1, 2'd0, 1'b0, 1'b1, 12'd32,  12'd5,  RED,   "grid h line");
        check_pixel(2'd1, 2'd0, 1'b0, 1'b1, 12'd5,   12'd64, RED,   "grid v line");

        // ---- mode 2: grey ramp ----
        check_pixel(2'd2, 2'd0, 1'b0, 1'b1, 12'd100, 12'd7,  24'h646464, "grey 100");
        check_pixel(2'd2, 2'd0, 1'b0, 1'b1, 12'd255, 12'd7,  24'hFFFFFF, "grey 255");

        // ---- mode 3: flat colour ----
        check_pixel(2'd3, 2'd0, 1'b0, 1'b1, 12'd10, 12'd10, RED,   "solid 0");
        check_pixel(2'd3, 2'd1, 1'b0, 1'b1, 12'd10, 12'd10, GREEN, "solid 1");
        check_pixel(2'd3, 2'd2, 1'b0, 1'b1, 12'd10, 12'd10, BLUE,  "solid 2");
        check_pixel(2'd3, 2'd3, 1'b0, 1'b1, 12'd10, 12'd10, WHITE, "solid 3");

        // ---- invert ----
        check_pixel(2'd0, 2'd0, 1'b1, 1'b1, 12'd0,  12'd0, BLACK, "invert white");
        check_pixel(2'd3, 2'd0, 1'b1, 1'b1, 12'd0,  12'd0, CYAN,  "invert red");
        check_pixel(2'd2, 2'd0, 1'b1, 1'b1, 12'd0,  12'd0, WHITE, "invert grey 0");

        // ---- de low forces black in every mode ----
        check_pixel(2'd0, 2'd0, 1'b0, 1'b0, 12'd0,   12'd0, BLACK, "blank bars");
        check_pixel(2'd1, 2'd0, 1'b0, 1'b0, 12'd0,   12'd0, BLACK, "blank grid");
        check_pixel(2'd2, 2'd0, 1'b0, 1'b0, 12'd200, 12'd0, BLACK, "blank grey");
        check_pixel(2'd3, 2'd3, 1'b0, 1'b0, 12'd0,   12'd0, BLACK, "blank solid");

        $display("PASS: pattern_gen - 8 bars, grid, grey ramp, 4 flat colours, invert, blanking");

        $finish;

    end

endmodule
