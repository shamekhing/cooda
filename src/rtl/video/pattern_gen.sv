// ============================================================
// pattern_gen  test pattern generator (purely combinational)
// ============================================================
//
// Bring-up pattern for the display backend, used before the GPU
// visualiser is enabled.
//
//   mode 0  eight 160 pixel colour bars
//   mode 1  32 pixel grid
//   mode 2  grey ramp, tracking x
//   mode 3  flat colour selected by `colour`
//
// invert XORs the result with white. de low forces black in every
// mode, inverted or not.
//
// The module name is fixed by pattern_gen_tb.sv, which is the only
// reason it is not video_pattern_gen.
// ============================================================

module pattern_gen #(
    parameter int H_RES = 1280
) (
    input  logic        de,
    input  logic [11:0] x,
    input  logic [11:0] y,
    input  logic [1:0]  mode,
    input  logic [1:0]  colour,
    input  logic        invert,

    output logic [7:0]  r,
    output logic [7:0]  g,
    output logic [7:0]  b
);

    localparam logic [23:0] WHITE   = 24'hFFFFFF;
    localparam logic [23:0] YELLOW  = 24'hFFFF00;
    localparam logic [23:0] CYAN    = 24'h00FFFF;
    localparam logic [23:0] GREEN   = 24'h00FF00;
    localparam logic [23:0] MAGENTA = 24'hFF00FF;
    localparam logic [23:0] RED     = 24'hFF0000;
    localparam logic [23:0] BLUE    = 24'h0000FF;
    localparam logic [23:0] BLACK   = 24'h000000;

    localparam int BAR_W = H_RES / 8;

    logic [2:0]  bar;
    logic [23:0] pixel;
    logic [23:0] bars;
    logic [23:0] grid;
    logic [23:0] ramp;
    logic [23:0] flat;

    // Bar index: 8 bars of 160 pixels. A comparison chain rather than a
    // divider, so nothing but comparators lands in the netlist.
    always_comb begin
        if      (x >= 12'(BAR_W * 7)) bar = 3'd7;
        else if (x >= 12'(BAR_W * 6)) bar = 3'd6;
        else if (x >= 12'(BAR_W * 5)) bar = 3'd5;
        else if (x >= 12'(BAR_W * 4)) bar = 3'd4;
        else if (x >= 12'(BAR_W * 3)) bar = 3'd3;
        else if (x >= 12'(BAR_W * 2)) bar = 3'd2;
        else if (x >= 12'(BAR_W))     bar = 3'd1;
        else                    bar = 3'd0;
    end

    always_comb begin
        case (bar)
            3'd0: bars = WHITE;
            3'd1: bars = YELLOW;
            3'd2: bars = CYAN;
            3'd3: bars = GREEN;
            3'd4: bars = MAGENTA;
            3'd5: bars = RED;
            3'd6: bars = BLUE;
            default: bars = BLACK;
        endcase
    end

    // Grid: a line every 32 pixels in x and in y.
    assign grid = ((x[4:0] == 5'd0) || (y[4:0] == 5'd0)) ? RED : BLACK;

    assign ramp = {x[7:0], x[7:0], x[7:0]};

    always_comb begin
        case (colour)
            2'd0: flat = RED;
            2'd1: flat = GREEN;
            2'd2: flat = BLUE;
            default: flat = WHITE;
        endcase
    end

    always_comb begin
        case (mode)
            2'd0: pixel = bars;
            2'd1: pixel = grid;
            2'd2: pixel = ramp;
            default: pixel = flat;
        endcase
    end

    logic [23:0] rgb;

    assign rgb = invert ? ~pixel : pixel;

    assign {r, g, b} = de ? rgb : BLACK;

endmodule
