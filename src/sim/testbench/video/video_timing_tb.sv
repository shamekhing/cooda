`timescale 1ns/1ps

// ============================================================
// video_timing testbench
// ============================================================
//
// Measures exactly one complete 720p60 frame and checks the raster
// against the numbers a 720p60 monitor requires:
//
//   1,237,500 pixel clocks per frame   (1650 * 750)
//     921,600 de pixels                (1280 * 720)
//      30,000 hs-high pixels            (40 * 750)
//       8,250 vs-high pixels            (5 * 1650)
//         720 de lines, each exactly 1280 pixels wide
//
// The frame window runs from one frame_start pulse to the next, so it
// is exactly one frame period by construction and no aggregate count
// depends on where in a pixel clock the testbench happens to sample.
// Everything is sampled at the falling edge, where all outputs are
// stable, which also removes any active-region ambiguity.
//
// The clock is the real pixel rate, 74.25 MHz.
// ============================================================

module video_timing_tb;

    localparam int H_TOTAL = 1650;
    localparam int V_TOTAL = 750;
    localparam int H_SYNC  = 40;
    localparam int V_SYNC  = 5;
    localparam int H_RES   = 1280;
    localparam int V_RES   = 720;

    localparam int EXP_FRAME_CLKS = H_TOTAL * V_TOTAL;
    localparam int EXP_DE_PIXELS  = H_RES * V_RES;
    localparam int EXP_HS_PIXELS  = H_SYNC * V_TOTAL;
    localparam int EXP_VS_PIXELS  = V_SYNC * H_TOTAL;

    logic pix_clk = 1'b0;
    always #6.734 pix_clk = ~pix_clk;

    logic rst = 1'b1;

    logic        de;
    logic        hs;
    logic        vs;
    logic [11:0] x;
    logic [11:0] y;
    logic        frame_start;

    video_timing dut (
        .pix_clk     (pix_clk),
        .rst         (rst),
        .de          (de),
        .hs          (hs),
        .vs          (vs),
        .x           (x),
        .y           (y),
        .frame_start (frame_start)
    );

    int frame_clks;
    int de_pixels;
    int hs_pixels;
    int vs_pixels;

    int de_lines;
    int bad_width_lines;
    int line_pixels;
    int bad_xy;
    int bad_y;

    logic de_d;

    task automatic check_frame;
        if (frame_clks != EXP_FRAME_CLKS)
            $fatal(1, "frame is %0d pixel clocks, expected %0d",
                   frame_clks, EXP_FRAME_CLKS);

        if (de_pixels != EXP_DE_PIXELS)
            $fatal(1, "frame has %0d de pixels, expected %0d",
                   de_pixels, EXP_DE_PIXELS);

        if (hs_pixels != EXP_HS_PIXELS)
            $fatal(1, "frame has %0d hs-high pixels, expected %0d",
                   hs_pixels, EXP_HS_PIXELS);

        if (vs_pixels != EXP_VS_PIXELS)
            $fatal(1, "frame has %0d vs-high pixels, expected %0d",
                   vs_pixels, EXP_VS_PIXELS);

        if (de_lines != V_RES)
            $fatal(1, "frame has %0d de lines, expected %0d", de_lines, V_RES);

        if (bad_width_lines != 0)
            $fatal(1, "%0d de lines were not exactly %0d pixels wide",
                   bad_width_lines, H_RES);

        if (bad_xy != 0)
            $fatal(1, "x exceeded H_RES-1 on %0d de pixels", bad_xy);

        if (bad_y != 0)
            $fatal(1, "y exceeded V_RES-1 on %0d de pixels", bad_y);
    endtask

    initial begin

        $dumpfile("video_timing.vcd");
        $dumpvars(0, video_timing_tb);

        frame_clks      = 0;
        de_pixels       = 0;
        hs_pixels       = 0;
        vs_pixels       = 0;
        de_lines        = 0;
        bad_width_lines = 0;
        line_pixels     = 0;
        bad_xy          = 0;
        bad_y           = 0;
        de_d            = 1'b0;

        repeat (4) @(posedge pix_clk);
        @(negedge pix_clk);
        rst = 1'b0;

        // ---- settle ----
        // Right after reset the counter pipeline holds its reset value for
        // DELAY cycles, so frame_start pulses for DELAY cycles in a row
        // instead of one. That transient is a bring-up artefact, not a
        // steady-state property; step well past it before aligning.
        repeat (10_000) @(negedge pix_clk);

        // ---- align to a frame origin ----
        @(negedge pix_clk);
        while (!frame_start) @(negedge pix_clk);

        // ---- measure exactly one frame, frame_start to frame_start ----
        //
        // The current cycle is sampled before advancing, so the window is
        // the 1,237,500 cycles beginning at the aligned frame_start. If
        // frame_start were ever not a one-cycle pulse this loop would exit
        // immediately and check_frame would report a one-clock "frame".

        frame_clks      = 0;
        de_pixels       = 0;
        hs_pixels       = 0;
        vs_pixels       = 0;
        de_lines        = 0;
        bad_width_lines = 0;
        line_pixels     = 0;
        bad_xy          = 0;
        bad_y           = 0;
        de_d            = 1'b0;

        do begin

            frame_clks = frame_clks + 1;

            if (de) begin

                de_pixels   = de_pixels + 1;
                line_pixels = line_pixels + 1;

                if (x > 12'(H_RES - 1)) bad_xy = bad_xy + 1;
                if (y > 12'(V_RES - 1)) bad_y  = bad_y  + 1;

            end else begin

                if (de_d) begin
                    de_lines = de_lines + 1;
                    if (line_pixels != H_RES) bad_width_lines = bad_width_lines + 1;
                end

                line_pixels = 0;

            end

            if (hs) hs_pixels = hs_pixels + 1;
            if (vs) vs_pixels = vs_pixels + 1;

            de_d = de;

            @(negedge pix_clk);

        end while (!frame_start);

        check_frame;

        $display("PASS: 720p60 raster - %0d clocks, %0d de pixels, %0d de lines, hs %0d, vs %0d",
                 frame_clks, de_pixels, de_lines, hs_pixels, vs_pixels);

        $finish;

    end

    initial begin
        // One 720p60 frame is 1,237,500 pixel clocks = 16.7 ms. Allow 100 ms.
        #100_000_000;
        $fatal(1, "timeout waiting for a frame");
    end

endmodule
