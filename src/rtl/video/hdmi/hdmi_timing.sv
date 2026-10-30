// ============================================================
// video_timing  720p-style horizontal and vertical counters
// ============================================================
//
// Generates the sync, blanking and active-area timing for a
// progressive video mode, plus the active-area coordinate the image
// source needs. The defaults are 1280x720 at 60 Hz on a 74.25 MHz
// pixel clock, the mode the vendored HDMI example drives.
//
// frame_start is a single-cycle pulse when the active area begins,
// which is where the image source swaps in a new image.
// ============================================================

module hdmi_timing #(
    parameter int H_TOTAL  = 1650,
    parameter int H_SYNC   = 40,
    parameter int H_BACK   = 220,
    parameter int H_ACTIVE = 1280,
    parameter int V_TOTAL  = 750,
    parameter int V_SYNC   = 5,
    parameter int V_BACK   = 20,
    parameter int V_ACTIVE = 720
) (
    input  logic        pix_clk,
    input  logic        rst,
    output logic        de,
    output logic        hs,
    output logic        vs,
    output logic [10:0] pixel_x,      // 0..H_ACTIVE-1 in the active area
    output logic [10:0] pixel_y,      // 0..V_ACTIVE-1 in the active area
    output logic        frame_start,
    output logic        vblank_start  // one cycle, first line of blanking
);

    logic [10:0] h_count_q;
    logic [10:0] v_count_q;

    // The geometry arrives as int parameters; narrowing it once keeps
    // every comparison at the counters' width.
    wire [10:0] h_sync_w  = H_SYNC;
    wire [10:0] v_sync_w  = V_SYNC;
    wire [10:0] h_back_w  = H_SYNC + H_BACK;
    wire [10:0] v_back_w  = V_SYNC + V_BACK;
    wire [10:0] h_total_w = H_TOTAL - 1;
    wire [10:0] v_total_w = V_TOTAL - 1;
    wire [10:0] h_act_w   = H_ACTIVE;
    wire [10:0] v_act_w   = V_ACTIVE;

    wire h_last  = (h_count_q == h_total_w);
    wire v_last  = (v_count_q == v_total_w);
    wire h_sync_on  = (h_count_q < h_sync_w);
    wire v_sync_on  = (v_count_q < v_sync_w);
    wire h_active   = (h_count_q >= h_back_w) &&
                      (h_count_q < h_back_w + h_act_w);
    wire v_active   = (v_count_q >= v_back_w) &&
                      (v_count_q < v_back_w + v_act_w);

    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) begin
            h_count_q <= '0;
            v_count_q <= '0;
        end else begin
            if (h_last) begin
                h_count_q <= '0;
                v_count_q <= v_last ? '0 : v_count_q + 1'b1;
            end else begin
                h_count_q <= h_count_q + 1'b1;
            end
        end
    end

    assign de          = h_active && v_active;
    assign hs          = h_sync_on;
    assign vs          = v_sync_on;
    assign pixel_x     = h_count_q - h_back_w;
    assign pixel_y     = v_count_q - v_back_w;
    assign frame_start = de && (pixel_x == '0) && (pixel_y == '0);

    // Blanking begins on the first line after the last active line, and
    // that is when the image source may pull a new frame in. One cycle
    // only: the first pixel of that first blanking line.
    assign vblank_start = !v_active && (v_count_q == v_back_w + v_act_w)
                          && (h_count_q == '0);

endmodule
