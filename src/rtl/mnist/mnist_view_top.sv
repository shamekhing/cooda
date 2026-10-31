// ============================================================
// mnist_view_top  display test: microSD -> DDR3 -> BSRAM -> HDMI
// ============================================================
//
// A board wrapper for the display test. It is fpga_top's DDR3 and
// microSD wiring with the video path added, and it exists so the test
// does not have to change fpga_top:
//
//   1. system (with DDR3_ENABLE, loader selection, and VIEW_ENABLE)
//      loads the packed image into DDR3 from UART or microSD;
//   2. mnist_fetch moves one MNIST record per tick - DDR3 into BSRAM,
//      BSRAM back out and into the async fifo;
//   3. mnist_frame_source, in the pixel clock's domain, pulls that
//      image out of the fifo during blanking and scans it out
//      upscaled, centred, grey;
//   4. the vendored HDMI example's PLL, clock divider and DVI
//      transmitter serialise it onto the dock's HDMI connector.
//
// The pixel clock is 74.25 MHz and the TMDS serial clock five times
// that, both from the example's PLL, so the pixel side is its own
// clock domain and the async fifo is the only crossing into it.
//
// Display rate: mnist_rate divides the refresh rate, and two dock
// buttons double and halve it. The bound is the screen's, since no
// setting can show an image faster than a frame.
//
// The DVI transmitter and the video PLL are Gowin's, from
// examples/HDMI. They are referenced from there and are not committed;
// add the two files to the Gowin project to build this top.
// ============================================================

module mnist_view_top #(
    parameter bit UART_ENABLE = 1'b1,
    parameter bit SD_ENABLE = 1'b0,
    parameter int UART_BAUD_RATE = 921600
) (
    input  logic clk27,
    input  logic btn_n0,
    input  logic btn_n1,
    input  logic btn_n2,
    input  logic btn_n3,
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS,
    output wire [12:0] DDR3_A,
    output wire [2:0]  DDR3_BA,
    output wire        DDR3_nRAS,
    output wire        DDR3_nCAS,
    output wire        DDR3_nWE,
    output wire        DDR3_nCS,
    output wire        DDR3_CK,
    output wire        DDR3_CKE,
    output wire        DDR3_nRESET,
    output wire [1:0]  DDR3_DM,
    output wire        DDR3_ODT,
    output wire        sd_cs_n,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,
    input  wire        uart_rx_pin,
    output wire        uart_tx_pin,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,
    output logic led0,
    output logic led1,
    output logic led2,
    output logic led3,
    output logic led4,
    output logic led5
);
    logic [1:0] rst_sync = 2'b11;
    logic [1:0] run_sync = 2'b00;
    logic [1:0] dbl_sync = 2'b11;
    logic [1:0] hlf_sync = 2'b11;
    logic rst, user_rst, run;
    logic retire_valid, illegal_instr, cpu_fault;
    logic ddr_write_level_done, ddr_read_calib_done, ddr_err;
    logic [63:0] ddr_debug_status;
    logic sd_ready, sd_error, load_done, load_error;
    logic uart_ready, uart_load_done, uart_load_error, ddr_ready;
    logic dataset_loaded;
    logic [1:0] sd_card_type;
    logic [3:0] sd_err_code, load_err_code;
    logic [19:0] activity_count;
    logic [23:0] led_probe_count = 24'd0;
    logic led_probe_phase = 1'b0;
    logic ddr_pclk, ddr_fclk, ddr_ck, ddr_pll_lock;
    logic ddr_reset_async;
    logic ddr_rst;
    logic [1:0] ddr_rst_sync = 2'b11;

    logic btn_double, btn_half;
    logic fetch_tick, fetch_busy;
    logic frame_pushed, frame_taken;
    logic video_rst;

    logic pix_clk, serial_clk, video_pll_lock;
    logic video_de, video_hs, video_vs;
    logic [10:0] pixel_x, pixel_y;
    logic vblank_start;
    logic [7:0] fifo_wr_data, fifo_rd_data;
    logic fifo_wr, fifo_full, fifo_empty, fifo_rd;
    logic [7:0] rgb_r, rgb_g, rgb_b;
    logic       rgb_de;
    soc_pkg::bus_req_s view_req;
    soc_pkg::bus_rsp_s view_rsp;

    // ---------------- DDR3 clocks, as fpga_top brings them up --------
    ddr3_pll pll (
        .clkin(clk27), .pclk(ddr_pclk), .fclk(ddr_fclk),
        .ck(ddr_ck), .lock(ddr_pll_lock)
    );

    assign ddr_reset_async = rst;

    always_ff @(posedge ddr_pclk or posedge ddr_reset_async) begin
        if (ddr_reset_async) ddr_rst_sync <= 2'b11;
        else ddr_rst_sync <= {ddr_rst_sync[0], 1'b0};
    end
    assign ddr_rst = ddr_rst_sync[1] | !ddr_pll_lock;

    always_ff @(posedge clk27) begin
        rst_sync <= {rst_sync[0], ~btn_n0};
        run_sync <= {run_sync[0],  btn_n1};
        dbl_sync <= {dbl_sync[0], ~btn_n2};
        hlf_sync <= {hlf_sync[0], ~btn_n3};
    end

    // The video PLL has to be up as well: a display with no pixel clock
    // shows nothing, so the reset waits for both PLLs.
    assign user_rst = rst_sync[1];
    assign rst = user_rst || !ddr_pll_lock || !video_pll_lock;
    assign run = run_sync[1];
    // The video domain resets with the system and with its own PLL.
    assign video_rst = rst;

    // ---------------- rate and fetch ----------------------------------
    button_debounce u_rate_double (
        .clk(clk27), .rst(rst), .btn_n(btn_n2),
        .pressed(btn_double), .level()
    );

    button_debounce u_rate_half (
        .clk(clk27), .rst(rst), .btn_n(btn_n3),
        .pressed(btn_half), .level()
    );

    mnist_rate u_rate (
        .clk(clk27), .rst(rst),
        .btn_double(btn_double), .btn_half(btn_half),
        .fetch_tick(fetch_tick), .rate_step(), .rate_hz()
    );

    mnist_fetch u_fetch (
        .clk(clk27), .rst(rst),
        .fetch_tick(fetch_tick && dataset_loaded), .fetch_busy(fetch_busy),
        .frame_pushed(frame_pushed), .frame_taken(frame_taken),
        .bus_req(view_req), .bus_rsp(view_rsp),
        .fifo_full(fifo_full), .fifo_wr(fifo_wr), .fifo_data(fifo_wr_data)
    );

    async_fifo u_image_fifo (
        .wr_clk(clk27), .wr_rst(rst),
        .wr_en(fifo_wr && !fifo_full), .wr_data(fifo_wr_data),
        .full(fifo_full),
        .rd_clk(pix_clk), .rd_rst(video_rst),
        .rd_en(fifo_rd && !fifo_empty), .rd_data(fifo_rd_data),
        .empty(fifo_empty)
    );

    // ---------------- pixel clock and video ---------------------------
    // One PLL: 27 MHz x 55/4 = 371.25 MHz for the TMDS serializers,
    // divided by five to 74.25 MHz for the pixel path.
    hdmi_rpll u_hdmi_rpll (
        .clkin(clk27), .resetn(!video_rst),
        .serial_clk(serial_clk), .pix_clk(pix_clk), .lock(video_pll_lock)
    );

    hdmi_timing u_timing (
        .pix_clk(pix_clk), .rst(video_rst),
        .de(video_de), .hs(video_hs), .vs(video_vs),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .frame_start(), .vblank_start(vblank_start)
    );

    mnist_frame_source u_source (
        .pix_clk(pix_clk), .rst(video_rst),
        .de(video_de), .pixel_x(pixel_x), .pixel_y(pixel_y),
        .vblank_start(vblank_start),
        .fifo_data(fifo_rd_data), .fifo_empty(fifo_empty),
        .fifo_rd(fifo_rd), .frame_pushed(frame_pushed),
        .frame_taken(frame_taken),
        .rgb_r(rgb_r), .rgb_g(rgb_g), .rgb_b(rgb_b), .rgb_de(rgb_de)
    );

    // The serializer lanes are converted to true LVDS pairs for HDMI.
    hdmi_tx u_hdmi_tx (
        .pix_clk(pix_clk), .serial_clk(serial_clk), .rst(video_rst),
        .de(rgb_de), .hs(video_hs), .vs(video_vs),
        .r(rgb_r), .g(rgb_g), .b(rgb_b),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_data_p(tmds_data_p), .tmds_data_n(tmds_data_n)
    );

    // ---------------- the SoC -----------------------------------------
    system #(
        .DDR3_ENABLE(1'b1), .SD_ENABLE(SD_ENABLE), .VIEW_ENABLE(1'b1),
        .UART_ENABLE(UART_ENABLE), .UART_BAUD_RATE(UART_BAUD_RATE)
    ) u_system (
        .clk(clk27), .rst(rst), .run(run),
        .ddr_pclk(ddr_pclk), .ddr_fclk(ddr_fclk), .ddr_ck(ddr_ck),
        .ddr_rst(ddr_rst),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS),
        .DDR3_A(DDR3_A), .DDR3_BA(DDR3_BA),
        .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS),
        .DDR3_nWE(DDR3_nWE), .DDR3_nCS(DDR3_nCS), .DDR3_CK(DDR3_CK),
        .DDR3_CKE(DDR3_CKE), .DDR3_nRESET(DDR3_nRESET),
        .DDR3_DM(DDR3_DM), .DDR3_ODT(DDR3_ODT),
        .retire_valid(retire_valid),
        .illegal_instr(illegal_instr), .cpu_fault(cpu_fault),
        .ddr_write_level_done(ddr_write_level_done),
        .ddr_read_calib_done(ddr_read_calib_done),
        .ddr_err(ddr_err),
        .ddr_debug_status(ddr_debug_status),
        .sd_cs_n(sd_cs_n), .sd_sck(sd_sck),
        .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .uart_rx_pin(uart_rx_pin), .uart_tx_pin(uart_tx_pin),
        .uart_ready(uart_ready), .uart_load_done(uart_load_done),
        .uart_load_error(uart_load_error), .ddr_ready(ddr_ready),
        .sd_ready(sd_ready), .sd_card_type(sd_card_type),
        .sd_error(sd_error), .sd_err_code(sd_err_code),
        .load_done(load_done), .load_error(load_error),
        .load_err_code(load_err_code),
        .view_req(view_req), .view_rsp(view_rsp)
    );

    // ---------------- LEDs --------------------------------------------
    always_ff @(posedge clk27) begin
        if (rst) activity_count <= '0;
        else if (retire_valid) activity_count <= '1;
        else if (activity_count != '0) activity_count <= activity_count - 1'b1;
    end

    // Free-running half-second LED phase, independent of SoC reset.
    always_ff @(posedge clk27) begin
        if (led_probe_count == 24'd13_499_999) begin
            led_probe_count <= 24'd0;
            led_probe_phase <= ~led_probe_phase;
        end else begin
            led_probe_count <= led_probe_count + 1'b1;
        end
    end

    // LED0/1 remain the polarity check. Hold S2 (btn_n1 low) to test
    // LEDs 2-5: alternating pairs switch every half second. Released,
    // all four are forced off. LED outputs are active-low.
    assign led0 = 1'b1;
    assign led1 = 1'b0;
    assign dataset_loaded = UART_ENABLE ? uart_load_done : load_done;
    assign led2 = btn_n1 |  led_probe_phase;
    assign led3 = btn_n1 | ~led_probe_phase;
    assign led4 = btn_n1 |  led_probe_phase;
    assign led5 = btn_n1 | ~led_probe_phase;

endmodule
