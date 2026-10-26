// ============================================================
// gpu_pixel_engine  bus activity visualiser (purely combinational)
// ============================================================
//
// Draws the SoC's bus fabric straight from x/y, no framebuffer:
//
//   header    clear_color (RegClearColor), a divider line under it
//   left      4 master tiles: cpu_i, cpu_d, gpu, tpu
//   middle    a 4 x 4 matrix; cell (master, slave) fills with the
//             slave's level, in the slave's colour, and lights its
//             border while that pair is being served
//   right     4 slave tiles: rom, ram, gpu_mmio, ddr3
//
// Each tile is filled bottom-up by its 8-bit activity level, so a tile
// visibly loses or gains pixel area as the program moves data. The
// geometry scales from H_RES/V_RES, so the same renderer serves the
// 800x480 LCD and the 1280x720 HDMI raster.
// ============================================================

module gpu_pixel_engine #(
    parameter int H_RES = 1280,
    parameter int V_RES = 720
) (
    input  logic        de,
    input  logic [11:0] x,
    input  logic [11:0] y,

    // 8 x 8-bit activity levels: 0..3 masters, 4..7 slaves.
    input  logic [63:0] level,

    // One-cycle grants from the RPU taps, synchronised.
    input  logic [3:0]  act_m,
    input  logic [3:0]  act_s,

    input  logic [23:0] clear_color,

    output logic [7:0]  r,
    output logic [7:0]  g,
    output logic [7:0]  b
);

    // ========================================================
    // GEOMETRY
    // ========================================================

    localparam int MARGIN   = H_RES / 32;
    localparam int TILE_W   = H_RES / 6;
    localparam int TILE_H   = V_RES / 12;
    localparam int TILE_GAP = V_RES / 32;
    localparam int PITCH    = TILE_H + TILE_GAP;
    localparam int BAND_Y   = V_RES / 8;
    localparam int BAND_H   = 4 * PITCH - TILE_GAP;
    localparam int HEADER_H = V_RES / 10;

    localparam int LEFT_X  = MARGIN;
    localparam int RIGHT_X = H_RES - MARGIN - TILE_W;
    localparam int MAT_X0  = LEFT_X + TILE_W + MARGIN;
    localparam int MAT_X1  = RIGHT_X - MARGIN;
    localparam int CELL_W  = (MAT_X1 - MAT_X0) / 4;

    // ========================================================
    // COLOURS
    // ========================================================

    localparam logic [23:0] BLACK   = 24'h000000;
    localparam logic [23:0] DARK    = 24'h0C0C0C;
    localparam logic [23:0] GREY    = 24'h606060;

    localparam logic [23:0] C_CPU_I = 24'hFFFFFF;   // master 0
    localparam logic [23:0] C_CPU_D = 24'hFFFF00;   // master 1
    localparam logic [23:0] C_GPU   = 24'h00FFFF;   // master 2
    localparam logic [23:0] C_TPU   = 24'h00FF00;   // master 3
    localparam logic [23:0] C_ROM   = 24'hFF00FF;   // slave 0
    localparam logic [23:0] C_RAM   = 24'hFF0000;   // slave 1
    localparam logic [23:0] C_GMEM  = 24'h0040FF;   // slave 2
    localparam logic [23:0] C_DDR3  = 24'hFF8000;   // slave 3

    function automatic logic [23:0] level_color(input logic [2:0] idx);
        case (idx)
            3'd0:    level_color = C_CPU_I;
            3'd1:    level_color = C_CPU_D;
            3'd2:    level_color = C_GPU;
            3'd3:    level_color = C_TPU;
            3'd4:    level_color = C_ROM;
            3'd5:    level_color = C_RAM;
            3'd6:    level_color = C_GMEM;
            default: level_color = C_DDR3;
        endcase
    endfunction

    // ========================================================
    // REGION DECODE
    // ========================================================

    logic [2:0]  row;
    logic [11:0] row_y;
    logic        in_band;

    logic [1:0]  col;
    logic [11:0] col_x;

    logic sel_left, sel_right, sel_matrix;
    logic [2:0]  lvl_idx;
    logic        active_pair;

    always_comb begin
        in_band = (y >= 12'(BAND_Y)) && (y < 12'(BAND_Y + BAND_H));

        if      (y >= 12'(BAND_Y + 3*PITCH)) row = 3'd3;
        else if (y >= 12'(BAND_Y + 2*PITCH)) row = 3'd2;
        else if (y >= 12'(BAND_Y + 1*PITCH)) row = 3'd1;
        else                                 row = 3'd0;

        case (row)
            3'd0:    row_y = y - 12'(BAND_Y);
            3'd1:    row_y = y - 12'(BAND_Y + PITCH);
            3'd2:    row_y = y - 12'(BAND_Y + 2*PITCH);
            default: row_y = y - 12'(BAND_Y + 3*PITCH);
        endcase
    end

    always_comb begin
        if      (x >= 12'(MAT_X0 + 3*CELL_W)) col = 2'd3;
        else if (x >= 12'(MAT_X0 + 2*CELL_W)) col = 2'd2;
        else if (x >= 12'(MAT_X0 + 1*CELL_W)) col = 2'd1;
        else                                  col = 2'd0;

        col_x = x - 12'(MAT_X0 + col*CELL_W);
    end

    always_comb begin
        sel_left   = in_band && (row_y < 12'(TILE_H)) &&
                     (x >= 12'(LEFT_X)) && (x < 12'(LEFT_X + TILE_W));

        sel_right  = in_band && (row_y < 12'(TILE_H)) &&
                     (x >= 12'(RIGHT_X)) && (x < 12'(RIGHT_X + TILE_W));

        sel_matrix = in_band && (row_y < 12'(TILE_H)) &&
                     (x >= 12'(MAT_X0)) && (x < 12'(MAT_X0 + 4*CELL_W));

        // Which level drives this pixel.
        lvl_idx = 3'd0;
        if (sel_left)   lvl_idx = {1'b0, row[1:0]};   // masters 0..3
        if (sel_right)  lvl_idx = {1'b1, row[1:0]};   // slaves  4..7
        if (sel_matrix) lvl_idx = {1'b1, col};        // slave of the column

        active_pair = sel_matrix && act_m[row[1:0]] && act_s[col];
    end

    // ========================================================
    // LEVEL SELECT AND FILL
    // ========================================================

    logic [7:0]  lvl;
    logic [11:0] fill_h;
    logic        filled;

    always_comb begin
        case (lvl_idx)
            3'd0:    lvl = level[7:0];
            3'd1:    lvl = level[15:8];
            3'd2:    lvl = level[23:16];
            3'd3:    lvl = level[31:24];
            3'd4:    lvl = level[39:32];
            3'd5:    lvl = level[47:40];
            3'd6:    lvl = level[55:48];
            default: lvl = level[63:56];
        endcase
    end

    always_comb begin
        fill_h = 12'((lvl * TILE_H) >> 8);
        filled = (row_y >= (12'(TILE_H) - fill_h));
    end

    // ========================================================
    // RENDER
    // ========================================================

    logic [23:0] rgb;

    always_comb begin
        rgb = DARK;

        if (y < 12'(HEADER_H)) begin

            // ---- header ----
            rgb = clear_color;
            if (y == 12'(HEADER_H - 1)) rgb = GREY;

        end else if (sel_left || sel_right) begin

            // ---- block tiles: the filled area grows and shrinks ----
            rgb = filled ? level_color(lvl_idx) : (level_color(lvl_idx) >> 2);

            if (row_y == 12'd0) rgb = GREY;

        end else if (sel_matrix) begin

            // ---- traffic matrix cell ----
            rgb = filled ? level_color(lvl_idx) : (level_color(lvl_idx) >> 3);

            // Border lights while this master/slave pair is served.
            if (active_pair)
                rgb = ((col_x < 12'd2) ||
                       (col_x >= 12'(CELL_W - 2)) ||
                       (row_y  < 12'd2) ||
                       (row_y  >= 12'(TILE_H - 2)))
                      ? level_color(lvl_idx)
                      : rgb;

        end
    end

    assign {r, g, b} = de ? rgb : BLACK;

endmodule
