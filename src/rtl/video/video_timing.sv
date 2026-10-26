// ============================================================
// video_timing  raster timing generator
// ============================================================
//
// Standard active / front-porch / sync / back-porch raster, driven by
// the pixel clock. Defaults are 720p60 (CEA-861):
//
//   H: 1280 active + 110 front + 40 sync + 220 back = 1650
//   V:  720 active +   5 front +  5 sync +  20 back =  750
//
// Other panels just override the parameters (the RGB LCD backend runs
// the same module at 800x480).
//
// OUTPUTS
//   de          high for exactly H_RES pixels on each of V_RES lines
//   hs          high for H_SYNC pixels on every line
//   vs          high for V_SYNC lines
//   x, y        pixel coordinates, valid while de is high
//   frame_start one-cycle pulse at the start of the active area of the
//               first line, i.e. once per frame
//
// Counters are free-running; frame_start is the (0,0) corner, so it is
// a single pulse by construction.
// ============================================================

module video_timing #(
    parameter int H_RES  = 1280,
    parameter int H_FP   = 110,
    parameter int H_SYNC = 40,
    parameter int H_BP   = 220,

    parameter int V_RES  = 720,
    parameter int V_FP   = 5,
    parameter int V_SYNC = 5,
    parameter int V_BP   = 20
) (
    input  logic        pix_clk,
    input  logic        rst,

    output logic        de,
    output logic        hs,
    output logic        vs,
    output logic [11:0] x,
    output logic [11:0] y,
    output logic        frame_start
);

    localparam int H_TOTAL = H_RES + H_FP + H_SYNC + H_BP;
    localparam int V_TOTAL = V_RES + V_FP + V_SYNC + V_BP;

    // Active / front porch / sync / back porch, in counter units.
    localparam int H_ACT_END  = H_RES;
    localparam int H_SYNC_END = H_RES + H_FP + H_SYNC;
    localparam int V_ACT_END  = V_RES;
    localparam int V_SYNC_END = V_RES + V_FP + V_SYNC;

    logic [11:0] h_cnt_q, h_cnt_d;
    logic [11:0] v_cnt_q, v_cnt_d;

    // ========================================================
    // NEXT-STATE VALUES
    // ========================================================

    always_comb begin
        h_cnt_d = h_cnt_q + 12'd1;
        v_cnt_d = v_cnt_q;

        if (h_cnt_q == 12'(H_TOTAL - 1)) begin
            h_cnt_d = 12'd0;

            if (v_cnt_q == 12'(V_TOTAL - 1)) v_cnt_d = 12'd0;
            else                             v_cnt_d = v_cnt_q + 12'd1;
        end
    end

    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) begin
            h_cnt_q <= 12'd0;
            v_cnt_q <= 12'd0;
        end else begin
            h_cnt_q <= h_cnt_d;
            v_cnt_q <= v_cnt_d;
        end
    end

    // ========================================================
    // DECODE
    // ========================================================
    // hs is the sync window on every line (it therefore spans the
    // active part of the vertical blanking lines too, which is what a
    // monitor expects).
    // --------------------------------------------------------

    assign de = (h_cnt_q < 12'(H_ACT_END)) && (v_cnt_q < 12'(V_ACT_END));

    assign hs = (h_cnt_q >= 12'(H_ACT_END + H_FP)) &&
                (h_cnt_q <  12'(H_SYNC_END));

    assign vs = (v_cnt_q >= 12'(V_ACT_END + V_FP)) &&
                (v_cnt_q <  12'(V_SYNC_END));

    assign x = h_cnt_q;
    assign y = v_cnt_q;

    assign frame_start = (h_cnt_q == 12'd0) && (v_cnt_q == 12'd0);

endmodule
