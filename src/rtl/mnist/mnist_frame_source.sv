// ============================================================
// mnist_frame_source  the image on screen, upscaled and centred
// ============================================================
//
// The pixel-clock side of the viewer. It owns the image that is on
// screen:
//
//   - once per frame, during vertical blanking, it pulls the next
//     image out of the async fifo and stores it - 28x28 bytes plus the
//     label - which finishes long before the active area begins;
//   - during the active area it reads that image back and upscales it
//     by SCALE with nearest-neighbour sampling: one image byte becomes
//     SCALE x SCALE screen pixels of the same grey, centred on a dark
//     background.
//
// The store is read synchronously, so the RGB output is one pixel
// clock behind the incoming coordinates; de is delayed by the same
// cycle to stay with its data, and hs/vs pass through undelayed, since
// sync edges do not need to sit on a pixel.
//
// A new image is only taken when the fetcher has marked one present,
// and the fetcher is told when it has been taken. If the rate
// controller asks for more images than the screen has frames per
// second, the extra images are simply never fetched.
// ============================================================

module mnist_frame_source #(
    parameter int         SCALE      = 16,
    parameter int         ROWS       = 28,
    parameter int         COLS       = 28,
    parameter int         H_ACTIVE   = 1280,
    parameter int         V_ACTIVE   = 720,
    parameter logic [7:0] BACKGROUND = 8'h20
) (
    input  logic        pix_clk,
    input  logic        rst,

    // timing
    input  logic        de,
    input  logic [10:0] pixel_x,
    input  logic [10:0] pixel_y,
    input  logic        vblank_start,

    // image stream from the fetcher
    input  logic [7:0]  fifo_data,
    input  logic        fifo_empty,
    input  logic        frame_pushed,   // toggle: the fetcher has an image
    output logic        fifo_rd,
    output logic        frame_taken,    // toggle: the image was taken

    // video out
    output logic [7:0]  rgb_r,
    output logic [7:0]  rgb_g,
    output logic [7:0]  rgb_b,
    output logic        rgb_de
);

    localparam int BYTES_PER_RECORD = ROWS * COLS + 1;
    localparam int SCALE_SHIFT = $clog2(SCALE);
    localparam int IMAGE_W = COLS << SCALE_SHIFT;
    localparam int IMAGE_H = ROWS << SCALE_SHIFT;
    localparam int X0 = (H_ACTIVE - IMAGE_W) / 2;
    localparam int Y0 = (V_ACTIVE - IMAGE_H) / 2;

    typedef enum logic {
        PixScan  = 1'd0,     // showing the image
        PixDrain = 1'd1      // pulling an image out of the fifo
    } frame_state_e;

    frame_state_e state_q;

    // The image on screen, and the label that came with it.
    logic [7:0] image_store [0:ROWS*COLS-1];
    logic [7:0] label_q;

    // Handoff toggles with the fetcher, which runs in clk27.
    logic        frame_taken_q;
    logic        frame_pushed_sync1, frame_pushed_sync2;

    // Pulling an image out of the fifo during blanking.
    logic [10:0] drain_index_q;

    // Scan-out pipeline.
    logic [10:0] row_base_q;
    logic [10:0] x_q, y_q;
    logic        de_q;
    logic        inside_q;
    logic [7:0]  pixel_q;

    // The geometry arrives as int parameters; narrowing once keeps the
    // per-pixel math at the counters' width.
    wire [10:0] x0_w     = X0;
    wire [10:0] y0_w     = Y0;
    wire [10:0] image_w  = IMAGE_W;
    wire [10:0] image_h  = IMAGE_H;
    wire [10:0] h_last_active = H_ACTIVE - 1;

    wire inside_x = (pixel_x >= x0_w) && (pixel_x < x0_w + image_w);
    wire inside_y = (pixel_y >= y0_w) && (pixel_y < y0_w + image_h);

    wire [10:0] img_x = (pixel_x - x0_w) >> SCALE_SHIFT;
    wire [10:0] img_y = (pixel_y - y0_w) >> SCALE_SHIFT;
    wire [10:0] next_img_y = (pixel_y + 1'b1 - y0_w) >> SCALE_SHIFT;

    // The store index of the image row being shown on this display
    // line, updated once per line rather than once per pixel.
    wire [10:0] read_addr = row_base_q + img_x;

    // The fifo's read data is combinational from its read pointer, so
    // the read enable has to be too: asserting it in the same cycle as
    // the store write is what keeps one fifo byte per image byte.
    always_comb begin
        fifo_rd     = (state_q == PixDrain) && !fifo_empty;
        frame_taken = frame_taken_q;
    end

    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) begin
            state_q            <= PixScan;
            drain_index_q      <= '0;
            frame_taken_q      <= 1'b0;
            frame_pushed_sync1 <= 1'b0;
            frame_pushed_sync2 <= 1'b0;
            row_base_q         <= '0;
            x_q                <= '0;
            y_q                <= '0;
            de_q               <= 1'b0;
            inside_q           <= 1'b0;
            pixel_q            <= 8'h00;
            label_q            <= 8'h00;
            rgb_r              <= 8'h00;
            rgb_g              <= 8'h00;
            rgb_b              <= 8'h00;
            rgb_de             <= 1'b0;
        end else begin
            frame_pushed_sync1 <= frame_pushed;
            frame_pushed_sync2 <= frame_pushed_sync1;

            case (state_q)
                // --------------------------------------------
                // Showing the image. Vertical blanking is the window
                // in which a new image can be pulled out of the fifo.
                // --------------------------------------------
                PixScan: begin
                    if (vblank_start && !fifo_empty &&
                        (frame_pushed_sync2 != frame_taken_q)) begin
                        drain_index_q <= '0;
                        state_q       <= PixDrain;
                    end
                end

                // --------------------------------------------
                // Pulling the image, one byte per fifo cycle. The
                // store is written in image order, so the scan-out
                // reads it back in the same order.
                // --------------------------------------------
                PixDrain: begin
                    if (!fifo_empty) begin
                        if (drain_index_q < BYTES_PER_RECORD - 1) begin
                            image_store[drain_index_q] <= fifo_data;
                            drain_index_q <= drain_index_q + 1'b1;
                        end else begin
                            label_q       <= fifo_data;
                            frame_taken_q <= ~frame_taken_q;
                            state_q       <= PixScan;
                        end
                    end
                end

                default: state_q <= PixScan;
            endcase

            // --------------------------------------------
            // Scan-out, with the store read one cycle ahead of the
            // pixel it belongs to.
            // --------------------------------------------
            pixel_q  <= image_store[read_addr];
            inside_q <= de && inside_x && inside_y;

            x_q   <= pixel_x;
            y_q   <= pixel_y;
            de_q  <= de;

            rgb_r  <= inside_q ? pixel_q : BACKGROUND;
            rgb_g  <= inside_q ? pixel_q : BACKGROUND;
            rgb_b  <= inside_q ? pixel_q : BACKGROUND;
            rgb_de <= de_q;

            // The row base for the next display line, decided at the
            // end of this one; blanking resets it to the image top.
            if (pixel_x == h_last_active)
                row_base_q <= (next_img_y < ROWS) ? 11'(next_img_y * COLS) : '0;
            else if (vblank_start)
                row_base_q <= '0;
        end
    end

endmodule
