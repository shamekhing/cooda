`timescale 1ns/1ps
// ============================================================
// video_scan_tb  what the viewer puts on screen, pixel by pixel
// ============================================================
//
// Drives mnist_frame_source the way mnist_view_top does - video_timing
// for the mode, an async_fifo for the crossing - and acts as the
// fetcher: one 28x28 image plus its label byte, pushed in clk27.
//
// A behavioural monitor samples the RGB stream and rebuilds the frame
// in an array, counting active pixels in raster order, so the check is
// on what a screen would show rather than on internal nodes:
//
//   1. every one of the 448x448 screen pixels the image covers shows
//      the image byte it should (nearest neighbour, centred)
//   2. sampled points outside the image are background
//   3. the frame holds exactly 1280x720 active pixels
//   4. the label byte survives the fifo
//
// The image is deliberately not uniform: byte i is (5i + 11) & 0xff, so
// a byte-order or addressing slip shows up as a wrong grey anywhere.
// ============================================================

module mnist_frame_source_tb;

    localparam int H_ACTIVE = 1280;
    localparam int V_ACTIVE = 720;
    localparam int SCALE    = 16;
    localparam int ROWS     = 28;
    localparam int COLS     = 28;
    localparam int IMAGE_W  = COLS * SCALE;
    localparam int IMAGE_H  = ROWS * SCALE;
    localparam int X0       = (H_ACTIVE - IMAGE_W) / 2;
    localparam int Y0       = (V_ACTIVE - IMAGE_H) / 2;
    localparam logic [7:0] BACKGROUND = 8'h20;

    // ---------------- clocks ----------------
    logic pix_clk = 1'b0;                   // 74.25 MHz
    logic clk27   = 1'b0;                   // 27 MHz
    always #6.734 pix_clk = ~pix_clk;
    always #18.518 clk27 = ~clk27;

    logic rst = 1'b1;

    // ---------------- DUT ----------------
    logic        video_de, video_hs, video_vs, vblank_start;
    logic [10:0] pixel_x, pixel_y;

    logic [7:0] fifo_wr_data;
    logic       fifo_wr, fifo_full, fifo_empty, fifo_rd;
    logic       frame_pushed, frame_taken;

    logic [7:0] rgb_r, rgb_g, rgb_b, rgb_de;

    hdmi_timing #(
        .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE)
    ) u_timing (
        .pix_clk(pix_clk), .rst(rst),
        .de(video_de), .hs(video_hs), .vs(video_vs),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .frame_start(), .vblank_start(vblank_start)
    );

    logic [7:0] fifo_rd_data;

    async_fifo #(.DEPTH(1024), .WIDTH(8)) u_fifo (
        .wr_clk(clk27), .wr_rst(rst),
        .wr_en(fifo_wr && !fifo_full), .wr_data(fifo_wr_data), .full(fifo_full),
        .rd_clk(pix_clk), .rd_rst(rst),
        .rd_en(fifo_rd && !fifo_empty), .rd_data(fifo_rd_data), .empty(fifo_empty)
    );

    mnist_frame_source #(
        .SCALE(SCALE), .ROWS(ROWS), .COLS(COLS),
        .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .BACKGROUND(BACKGROUND)
    ) u_source (
        .pix_clk(pix_clk), .rst(rst),
        .de(video_de), .pixel_x(pixel_x), .pixel_y(pixel_y),
        .vblank_start(vblank_start),
        .fifo_data(fifo_rd_data), .fifo_empty(fifo_empty),
        .frame_pushed(frame_pushed),
        .fifo_rd(fifo_rd), .frame_taken(frame_taken),
        .rgb_r(rgb_r), .rgb_g(rgb_g), .rgb_b(rgb_b), .rgb_de(rgb_de)
    );

    int errors = 0;
    int checks = 0;
    // ========================================================
    // MONITOR: rebuild the frame from the RGB stream
    // ========================================================
    // rgb_de is high for exactly the active pixels in raster order, so
    // counting de cycles gives the screen coordinate without touching
    // the DUT's internal counters.
    // --------------------------------------------------------

    logic [7:0] framebuffer [0:H_ACTIVE*V_ACTIVE-1];
    int         fb_index;
    int         frames_seen;
    int         prev_frame_pixels;

    always @(posedge pix_clk) begin
        if (vblank_start) begin
            frames_seen++;
            prev_frame_pixels <= fb_index;
            fb_index <= 0;
        end else if (rgb_de) begin
            framebuffer[fb_index] <= rgb_r;
            fb_index <= fb_index + 1;
        end
    end

    // ========================================================
    // FETCHER ROLE: push one image plus its label byte
    // ========================================================

    logic [7:0] image [0:ROWS*COLS-1];
    logic [7:0] label_byte = 8'h5A;

    function automatic logic [7:0] image_byte(input int i);
        image_byte = (5 * i + 11) & 8'hFF;
    endfunction

    task automatic push_image;
        int pushed;
        pushed = 0;
        for (int i = 0; i < ROWS * COLS; i++)
            image[i] = image_byte(i);

        while (pushed < ROWS * COLS + 1) begin
            @(negedge clk27);
            if (!fifo_full) begin
                fifo_wr_data <= (pushed < ROWS * COLS) ? image[pushed]
                                                       : label_byte;
                fifo_wr <= 1'b1;
                pushed++;
            end else begin
                fifo_wr <= 1'b0;
            end
        end
        @(negedge clk27);
        fifo_wr <= 1'b0;
        frame_pushed <= ~frame_pushed;
    endtask

    int x, y;
    int outside [0:7];

    // ========================================================
    // SEQUENCE
    // ========================================================

    initial begin
        fifo_wr_data = 8'h00;
        fifo_wr = 1'b0;
        frame_pushed = 1'b0;
        fb_index = 0;
        frames_seen = 0;

        repeat (5) @(negedge pix_clk);
        rst = 1'b0;

        push_image();

        // Three blankings: the first one drains the image, the second
        // bounds a complete frame that showed it.
        while (frames_seen < 3) @(negedge pix_clk);

        // 1. the frame is a whole 1280x720.
        checks++;
        if (prev_frame_pixels !== H_ACTIVE * V_ACTIVE) begin
            errors++;
            $display("FAIL: %0d active pixels in the frame, expected %0d",
                     prev_frame_pixels, H_ACTIVE * V_ACTIVE);
        end

        // 2. every pixel of the image area shows the right byte: the
        //    corners and centre of each scaled cell.
        checks++;
        for (int j = 0; j < ROWS; j++) begin
            for (int i = 0; i < COLS; i++) begin
                for (int e = 0; e < SCALE; e = e + SCALE - 1) begin
                    for (int d = 0; d < SCALE; d = d + SCALE - 1) begin
                        x = X0 + i * SCALE + d;
                        y = Y0 + j * SCALE + e;
                        if (framebuffer[y * H_ACTIVE + x] !==
                            image_byte(j * COLS + i)) begin
                            errors++;
                            if (errors < 8)
                                $display("FAIL: screen (%0d,%0d) = %02h, expected %02h (image %0d,%0d)",
                                         x, y, framebuffer[y * H_ACTIVE + x],
                                         image_byte(j * COLS + i), i, j);
                        end
                    end
                end
            end
        end

        // 3. points outside the image are background.
        checks++;
        outside[0] = 0 * H_ACTIVE + 0;
        outside[1] = 0 * H_ACTIVE + (H_ACTIVE - 1);
        outside[2] = (V_ACTIVE - 1) * H_ACTIVE + 0;
        outside[3] = (V_ACTIVE - 1) * H_ACTIVE + (H_ACTIVE - 1);
        outside[4] = Y0 * H_ACTIVE + (X0 + IMAGE_W + 10);
        outside[5] = (Y0 + IMAGE_H + 5) * H_ACTIVE + (X0 + 10);
        outside[6] = Y0 * H_ACTIVE + 5;
        outside[7] = (Y0 + IMAGE_H - 1) * H_ACTIVE + (X0 + IMAGE_W + 3);
        for (int p = 0; p < 8; p++) begin
            if (framebuffer[outside[p]] !== BACKGROUND) begin
                errors++;
                $display("FAIL: screen pixel %0d = %02h, expected background %02h",
                         outside[p], framebuffer[outside[p]], BACKGROUND);
            end
        end

        // 4. the label byte reached the source.
        checks++;
        if (u_source.label_q !== 8'h5A) begin
            errors++;
            $display("FAIL: label = %02h, expected 5a", u_source.label_q);
        end

        if (errors == 0)
            $display("PASS: mnist_frame_source %0d checks, image %0d x %0d at scale %0d",
                     checks, IMAGE_W, IMAGE_H, SCALE);
        else
            $fatal(1, "FAIL: mnist_frame_source %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $fatal(1, "mnist_frame_source_tb timeout");
    end

endmodule
