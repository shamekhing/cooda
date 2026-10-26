// ============================================================
// fpga_top  Sipeed Tang Primer 20K
//
//   clk27  : 27 MHz system clock
//   btn_n0 : active-low reset
//   btn_n1 : active-low run
//   led0   : stretched CPU instruction retirement
//   led1   : sticky CPU fault (fetch, data bus, illegal instruction)
//   led2-5 : reserved
//
// DISPLAY: the GPU (bus activity visualiser) renders into an 800x480
// raster and the RGB LCD backend drives the Dock's parallel RGB565
// connector. No serializer and no vendor IP: video_rpll (a wrapper
// around the rPLL hard primitive) makes the 40.5 MHz pixel clock and
// the panel takes the data directly.
//
// DDR3: memory_ddr3_phy (the open-source slow DDR3 controller) drives
// the DDR3 pins directly, all in the clk27 domain. It generates its
// own DDR clock at clk27/2, so there is no second SoC clock domain and
// no vendor IP. Until the controller finishes initialisation every
// DDR3 access returns a bus error instead of hanging.
// ============================================================

module fpga_top #(
    // Display backend:
    //   0 = RGB LCD   (800x480, parallel RGB565, no serializer)
    //   1 = HDMI/TMDS (720p60, pure-RTL TMDS encoder + OSER10)
    parameter int VIDEO_HDMI = 1
) (
    input  logic clk27,

    input  logic btn_n0,
    input  logic btn_n1,

    output logic led0,
    output logic led1,
    output logic led2,
    output logic led3,
    output logic led4,
    output logic led5,

    // RGB LCD (RGB565 + sync + backlight), see the .cst
    output logic       lcd_dclk,
    output logic       lcd_de,
    output logic       lcd_hs,
    output logic       lcd_vs,
    output logic [4:0] lcd_r,
    output logic [5:0] lcd_g,
    output logic [4:0] lcd_b,
    output logic       lcd_bl,

    // HDMI TMDS differential pairs, see the .cst
    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_data_p,
    output logic [2:0] tmds_data_n,

    // DDR3 (SSTL15, see the .cst)
    output logic [13:0]  ddr3_addr,
    output logic [2:0]   ddr3_bank,
    output logic         ddr3_ras,
    output logic         ddr3_cas,
    output logic         ddr3_we,
    output logic         ddr3_ck_p,
    output logic         ddr3_ck_n,
    output logic         ddr3_cke,
    output logic         ddr3_odt,
    output logic         ddr3_rst_n,
    output logic         ddr3_cs,
    output logic [1:0]   ddr3_dm,
    inout  wire  [15:0]  ddr3_dq,
    inout  wire  [1:0]   ddr3_dqs_p,
    inout  wire  [1:0]   ddr3_dqs_n
);

    // ========================================================
    // BUTTONS: two-stage synchronizers, active-high internally
    // ========================================================

    logic [1:0] rst_sync = 2'b11;
    logic [1:0] run_sync = 2'b00;

    logic rst;
    logic run;

    always_ff @(posedge clk27) begin
        rst_sync <= {rst_sync[0], ~btn_n0};
        run_sync <= {run_sync[0],  btn_n1};
    end

    // rst  : S1 pressed (active low on the board)
    // run  : high unless S2 is held. The CPU runs by default, so the
    //        boot program starts as soon as the board is configured;
    //        holding S2 pauses it.
    assign rst = rst_sync[1];
    assign run = run_sync[1];

    // ========================================================
    // VIDEO CLOCKS AND RASTER
    // ========================================================

    localparam bit HDMI_BACKEND = (VIDEO_HDMI != 0);

    localparam int VIDEO_H_RES  = HDMI_BACKEND ? 1280 : 800;
    localparam int VIDEO_V_RES  = HDMI_BACKEND ? 720  : 480;

    // 1280x720@60: 1650 x 750 total, 74.25 MHz pixel clock.
    //  800x480@60: 1066 x 520 total, 40.5 MHz pixel clock.
    localparam int VIDEO_H_FP   = HDMI_BACKEND ? 110 : 210;
    localparam int VIDEO_H_SYNC = HDMI_BACKEND ? 40  : 10;
    localparam int VIDEO_H_BP   = HDMI_BACKEND ? 220 : 46;

    localparam int VIDEO_V_FP   = HDMI_BACKEND ? 5 : 13;
    localparam int VIDEO_V_SYNC = HDMI_BACKEND ? 5 : 4;
    localparam int VIDEO_V_BP   = HDMI_BACKEND ? 20 : 23;

    logic pix_clk;
    logic serial_clk;
    logic pll_lock;

    generate
        if (HDMI_BACKEND) begin : g_hdmi_clk

            // 371.25 MHz serial, /5 -> 74.25 MHz pixel.
            hdmi_rpll u_hdmi_rpll (
                .clkin      (clk27),
                .resetn     (~rst),
                .serial_clk (serial_clk),
                .pix_clk    (pix_clk),
                .lock       (pll_lock)
            );

        end else begin : g_lcd_clk

            // 40.5 MHz pixel clock, no serializer clock.
            video_rpll u_video_rpll (
                .clkin  (clk27),
                .clkout (pix_clk),
                .lock   (pll_lock)
            );

            assign serial_clk = 1'b0;

        end
    endgenerate

    // Pixel domain reset: held until the PLL has locked.
    logic pix_rst;
    assign pix_rst = rst | ~pll_lock;

    logic        pix_de;
    logic        pix_hs;
    logic        pix_vs;
    logic [11:0] pix_x;
    logic [11:0] pix_y;
    logic [7:0]  pix_r;
    logic [7:0]  pix_g;
    logic [7:0]  pix_b;

    video_timing #(
        .H_RES  (VIDEO_H_RES),
        .H_FP   (VIDEO_H_FP),
        .H_SYNC (VIDEO_H_SYNC),
        .H_BP   (VIDEO_H_BP),
        .V_RES  (VIDEO_V_RES),
        .V_FP   (VIDEO_V_FP),
        .V_SYNC (VIDEO_V_SYNC),
        .V_BP   (VIDEO_V_BP)
    ) u_video_timing (
        .pix_clk (pix_clk),
        .rst     (pix_rst),

        .de  (pix_de),
        .hs  (pix_hs),
        .vs  (pix_vs),
        .x   (pix_x),
        .y   (pix_y),

        .frame_start ()
    );

    // ========================================================
    // SYSTEM
    // ========================================================

    logic retire_valid;
    logic cpu_fault;

    system #(
        .H_RES  (VIDEO_H_RES),
        .V_RES  (VIDEO_V_RES)
    ) u_system (
        .clk           (clk27),
        .rst           (rst),
        .run           (run),

        .retire_valid  (retire_valid),
        .illegal_instr (),
        .cpu_fault     (cpu_fault),

        .pix_clk       (pix_clk),
        .pix_rst       (pix_rst),
        .pix_de        (pix_de),
        .pix_x         (pix_x),
        .pix_y         (pix_y),
        .pix_r         (pix_r),
        .pix_g         (pix_g),
        .pix_b         (pix_b),

        .ddr3_addr     (ddr3_addr),
        .ddr3_bank     (ddr3_bank),
        .ddr3_ras      (ddr3_ras),
        .ddr3_cas      (ddr3_cas),
        .ddr3_we       (ddr3_we),
        .ddr3_ck_p     (ddr3_ck_p),
        .ddr3_ck_n     (ddr3_ck_n),
        .ddr3_cke      (ddr3_cke),
        .ddr3_odt      (ddr3_odt),
        .ddr3_rst_n    (ddr3_rst_n),
        .ddr3_cs       (ddr3_cs),
        .ddr3_dm       (ddr3_dm),
        .ddr3_dq       (ddr3_dq),
        .ddr3_dqs_p    (ddr3_dqs_p),
        .ddr3_dqs_n    (ddr3_dqs_n)
    );

    // ========================================================
    // DISPLAY BACKEND
    // ========================================================

    generate
        if (HDMI_BACKEND) begin : g_hdmi_out

            logic       tmds_clk;
            logic [2:0] tmds_data;

            hdmi_tx u_hdmi_tx (
                .pix_clk    (pix_clk),
                .serial_clk (serial_clk),
                .rst        (pix_rst),

                .de (pix_de),
                .hs (pix_hs),
                .vs (pix_vs),
                .r  (pix_r),
                .g  (pix_g),
                .b  (pix_b),

                .tmds_clk  (tmds_clk),
                .tmds_data (tmds_data)
            );

            // TMDS must leave the FPGA as true differential pairs. The
            // single-ended LVCMOS outputs previously constrained here
            // did not provide a valid HDMI electrical interface.
            TLVDS_OBUF u_tmds_clk_obuf (
                .I  (tmds_clk),
                .O  (tmds_clk_p),
                .OB (tmds_clk_n)
            );

            for (genvar lane = 0; lane < 3; lane++) begin : g_tmds_obuf
                TLVDS_OBUF u_tmds_data_obuf (
                    .I  (tmds_data[lane]),
                    .O  (tmds_data_p[lane]),
                    .OB (tmds_data_n[lane])
                );
            end

            // RGB LCD pins idle in this build.
            assign lcd_dclk = 1'b0;
            assign lcd_de   = 1'b0;
            assign lcd_hs   = 1'b0;
            assign lcd_vs   = 1'b0;
            assign lcd_r    = 5'b00000;
            assign lcd_g    = 6'b000000;
            assign lcd_b    = 5'b00000;
            assign lcd_bl   = 1'b0;

        end else begin : g_lcd_out

            video_lcd u_video_lcd (
                .pix_clk (pix_clk),

                .de (pix_de),
                .hs (pix_hs),
                .vs (pix_vs),
                .r  (pix_r),
                .g  (pix_g),
                .b  (pix_b),

                .lcd_dclk (lcd_dclk),
                .lcd_de   (lcd_de),
                .lcd_hs   (lcd_hs),
                .lcd_vs   (lcd_vs),

                .lcd_r (lcd_r),
                .lcd_g (lcd_g),
                .lcd_b (lcd_b),

                .lcd_bl (lcd_bl)
            );

            // TMDS pins idle in this build.
            assign tmds_clk_p  = 1'b0;
            assign tmds_clk_n  = 1'b0;
            assign tmds_data_p = 3'b000;
            assign tmds_data_n = 3'b000;

        end
    endgenerate

    // ========================================================
    // STATUS LEDS
    // ========================================================

    logic [19:0] activity_count;

    always_ff @(posedge clk27) begin
        if (rst)                         activity_count <= '0;
        else if (retire_valid)           activity_count <= '1;
        else if (activity_count != '0)   activity_count <= activity_count - 1'b1;
    end

    // Dock LEDs are active-low: drive low only while asserting a status.
    assign led0 = (activity_count == '0);
    assign led1 = ~cpu_fault;
    assign led2 = 1'b1;
    assign led3 = 1'b1;
    assign led4 = 1'b1;
    assign led5 = 1'b1;

endmodule
