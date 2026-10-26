// ============================================================
// gpu  GPU_MMIO slave + bus activity visualiser
// ============================================================
//
// Two clock domains:
//
//   clk     : the SoC domain. The GPU_MMIO register file and the bus
//             monitor live here.
//   pix_clk : the video domain. The renderer and the test pattern
//             live here.
//
// Crossing (all into the pixel domain, all short):
//   - activity levels, Gray coded by gpu_bus_mon, two flops + decode
//   - the RPU grants, as live indicators
//   - the configuration registers, which are quasi-static: a write can
//     glitch one frame, which is acceptable for a display
//
// RegControl selects the source: vis_enable = 1 shows the visualiser,
// otherwise pattern_gen mode [2:1] is shown, so the board boots into
// the colour bars before a program touches the MMIO.
// ============================================================

module gpu #(
    parameter int H_RES = 1280,
    parameter int V_RES = 720
) (
    input  logic clk,
    input  logic rst,

    input  logic pix_clk,
    input  logic pix_rst,

    // GPU_MMIO slave (RPU slave port gpu_mmio)
    input  soc_pkg::bus_req_s req,
    output soc_pkg::bus_rsp_s rsp,

    // Passive RPU monitor taps
    input  logic [3:0] mon_m,
    input  logic [3:0] mon_s,

    // Video side (pix_clk domain)
    input  logic        de,
    input  logic [11:0] x,
    input  logic [11:0] y,

    output logic [7:0]  r,
    output logic [7:0]  g,
    output logic [7:0]  b
);

    // ========================================================
    // SOC DOMAIN
    // ========================================================

    logic        vis_enable;
    logic [1:0]  mode;
    logic        pattern_invert;
    logic [1:0]  pattern_colour;
    logic [23:0] clear_color;
    logic [31:0] level_master;

    logic [63:0] level_gray;

    gpu_registers u_gpu_registers (
        .clk (clk),
        .rst (rst),

        .req (req),
        .rsp (rsp),

        .vis_enable     (vis_enable),
        .mode           (mode),
        .pattern_invert (pattern_invert),
        .pattern_colour (pattern_colour),
        .clear_color    (clear_color),

        .status (level_master)
    );

    gpu_bus_mon u_gpu_bus_mon (
        .clk (clk),
        .rst (rst),

        .mon_m (mon_m),
        .mon_s (mon_s),

        .level_gray   (level_gray),
        .level_master (level_master)
    );

    // ========================================================
    // CROSSING INTO THE PIXEL DOMAIN
    // ========================================================
    // Synchroniser chains are written in place: a shift chain is not
    // state (same rule as memory_ddr3's reset chain). The levels arrive
    // Gray coded, so each level changes at most one bit per update.
    // --------------------------------------------------------

    logic [63:0] lvl_sync_q0,  lvl_sync_q1;
    logic [3:0]  actm_sync_q0, actm_sync_q1;
    logic [3:0]  acts_sync_q0, acts_sync_q1;

    logic        vis_sync_q0, vis_sync_q1;
    logic [1:0]  mode_sync_q0, mode_sync_q1;
    logic        inv_sync_q0, inv_sync_q1;
    logic [1:0]  col_sync_q0, col_sync_q1;
    logic [23:0] clr_sync_q0, clr_sync_q1;

    always_ff @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) begin
            lvl_sync_q0  <= '0;
            lvl_sync_q1  <= '0;
            actm_sync_q0 <= '0;
            actm_sync_q1 <= '0;
            acts_sync_q0 <= '0;
            acts_sync_q1 <= '0;
            vis_sync_q0  <= 1'b0;
            vis_sync_q1  <= 1'b0;
            mode_sync_q0 <= 2'b00;
            mode_sync_q1 <= 2'b00;
            inv_sync_q0  <= 1'b0;
            inv_sync_q1  <= 1'b0;
            col_sync_q0  <= 2'b00;
            col_sync_q1  <= 2'b00;
            clr_sync_q0  <= '0;
            clr_sync_q1  <= '0;
        end else begin
            lvl_sync_q0  <= level_gray;
            lvl_sync_q1  <= lvl_sync_q0;

            actm_sync_q0 <= mon_m;
            actm_sync_q1 <= actm_sync_q0;

            acts_sync_q0 <= mon_s;
            acts_sync_q1 <= acts_sync_q0;

            vis_sync_q0  <= vis_enable;
            vis_sync_q1  <= vis_sync_q0;

            mode_sync_q0 <= mode;
            mode_sync_q1 <= mode_sync_q0;

            inv_sync_q0  <= pattern_invert;
            inv_sync_q1  <= inv_sync_q0;

            col_sync_q0  <= pattern_colour;
            col_sync_q1  <= col_sync_q0;

            clr_sync_q0  <= clear_color;
            clr_sync_q1  <= clr_sync_q0;
        end
    end

    // ========================================================
    // GRAY DECODE
    // ========================================================

    function automatic logic [7:0] gray_to_bin(input logic [7:0] g);
        logic [7:0] b;
        b[7] = g[7];
        b[6] = b[7] ^ g[6];
        b[5] = b[6] ^ g[5];
        b[4] = b[5] ^ g[4];
        b[3] = b[4] ^ g[3];
        b[2] = b[3] ^ g[2];
        b[1] = b[2] ^ g[1];
        b[0] = b[1] ^ g[0];
        return b;
    endfunction

    logic [63:0] level_bin;

    always_comb begin
        for (int i = 0; i < 8; i++)
            level_bin[8*i +: 8] = gray_to_bin(lvl_sync_q1[8*i +: 8]);
    end

    // ========================================================
    // PIXEL SOURCES
    // ========================================================

    logic [7:0] pat_r, pat_g, pat_b;
    logic [7:0] eng_r, eng_g, eng_b;

    pattern_gen #(.H_RES(H_RES)) u_pattern_gen (
        .de     (de),
        .x      (x),
        .y      (y),
        .mode   (mode_sync_q1),
        .colour (col_sync_q1),
        .invert (inv_sync_q1),

        .r      (pat_r),
        .g      (pat_g),
        .b      (pat_b)
    );

    gpu_pixel_engine #(.H_RES(H_RES), .V_RES(V_RES)) u_gpu_pixel_engine (
        .de          (de),
        .x           (x),
        .y           (y),

        .level       (level_bin),
        .act_m       (actm_sync_q1),
        .act_s       (acts_sync_q1),

        .clear_color (clr_sync_q1),

        .r           (eng_r),
        .g           (eng_g),
        .b           (eng_b)
    );

    assign r = vis_sync_q1 ? eng_r : pat_r;
    assign g = vis_sync_q1 ? eng_g : pat_g;
    assign b = vis_sync_q1 ? eng_b : pat_b;

endmodule
