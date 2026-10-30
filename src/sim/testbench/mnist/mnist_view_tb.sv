`timescale 1ns/1ps
// ============================================================
// mnist_view_tb  the display test case, end to end
// ============================================================
//
// The chain the board runs, with the DRAM PHY mocked and the TMDS
// serialiser left out (both are covered by the vendor primitives and
// the ddr3 tests):
//
//   a card image in the packer's format sits in a fake DDR3;
//   a rate tick starts mnist_fetch, which reads the record from the
//     fake DDR3, writes it into the real BSRAM through memory.sv's
//     decode, reads it back and pushes it byte by byte into the fifo;
//   mnist_frame_source drains the fifo in blanking and scans the
//     image out through hdmi_timing's raster;
//   a behavioural monitor rebuilds the frame and checks every pixel.
//
// Checked:
//   1. the record lands in BSRAM byte for byte at BSRAM_OFFSET
//   2. every image pixel on screen matches the record the source
//      drained (identified by the label byte it latched)
//   3. the background stays background outside the image
//   4. successive rate ticks advance the record, so the display moves
//      through the card image
//
// The video mode is shrunk (128x72 active) through hdmi_timing's
// parameters, not by touching the modules, so frames simulate fast.
// ============================================================

module mnist_view_tb;

    localparam logic [31:0] DDR3_BASE    = 32'h0800_0000;
    localparam int          RECORD_BYTES = 784;   // 28x28
    localparam int          RECORDS      = 6;
    localparam int          SCALE        = 2;
    localparam int          ROWS         = 28;
    localparam int          COLS         = 28;
    localparam int          H_ACTIVE     = 128;
    localparam int          V_ACTIVE     = 72;
    localparam int          IMAGE_W      = COLS * SCALE;
    localparam int          IMAGE_H      = ROWS * SCALE;
    localparam int          X0           = (H_ACTIVE - IMAGE_W) / 2;
    localparam int          Y0           = (V_ACTIVE - IMAGE_H) / 2;
    localparam logic [7:0]  BACKGROUND   = 8'h20;
    localparam int          BSRAM_BASE_WORD = 32'h400;  // BSRAM_OFFSET 0x1000 / 4

    // ---------------- clocks ----------------
    logic pix_clk = 1'b0;                   // 74.25 MHz
    logic clk27   = 1'b0;                   // 27 MHz
    always #6.734 pix_clk = ~pix_clk;
    always #18.518 clk27 = ~clk27;

    logic rst = 1'b1;

    // ---------------- the fake DDR3 ----------------
    // Reads only (the fetcher never writes DDR3): a byte array behind
    // the same one-cycle ready contract memory_ddr3 keeps.
    logic [7:0] ddr_store [0:65535];
    soc_pkg::bus_req_s  ddr_req;
    soc_pkg::bus_rsp_s  ddr_rsp;

    always_ff @(posedge clk27) begin
        ddr_rsp.ready <= ddr_req.valid;
        ddr_rsp.error <= 1'b0;
        if (ddr_req.valid && ddr_req.op == soc_pkg::BusRead)
            ddr_rsp.rdata <= {ddr_store[ddr_req.addr + 3],
                              ddr_store[ddr_req.addr + 2],
                              ddr_store[ddr_req.addr + 1],
                              ddr_store[ddr_req.addr + 0]};
    end

    // The card image as the loader leaves it: the payload copied to the
    // DDR3 window (the header stays on the card), N records then N
    // label bytes, per tools/mnist/mnist_pack.py.
    function automatic int record_base(input int r);
        record_base = r * RECORD_BYTES;
    endfunction

    function automatic int label_base;
        label_base = RECORDS * RECORD_BYTES;
    endfunction

    function automatic logic [7:0] image_byte(input int r, input int i);
        image_byte = (r * 32 + i * 3 + 5) & 8'hFF;
    endfunction

    function automatic logic [7:0] label_byte(input int r);
        label_byte = (r * 7 + 3) & 8'h07;
    endfunction

    // Which record carries a given label byte (unique for these six).
    function automatic int record_of_label(input logic [7:0] l);
        record_of_label = 0;
        for (int r = 0; r < RECORDS; r++)
            if (label_byte(r) == l) record_of_label = r;
    endfunction

    initial begin
        for (int i = 0; i < 65536; i++) ddr_store[i] = 8'h00;
        for (int r = 0; r < RECORDS; r++)
            for (int i = 0; i < RECORD_BYTES; i++)
                ddr_store[record_base(r) + i] = image_byte(r, i);
        for (int r = 0; r < RECORDS; r++)
            ddr_store[label_base() + r] = label_byte(r);
    end


    // ---------------- the display path ----------------
    // One fetch tick every TICK_CYCLES of clk27 - about one in every
    // few frames of the shrunk raster. The fetcher only starts a new
    // record once the pixel side has taken the previous one, so the
    // real pace is still set by the display.
    localparam int TICK_CYCLES = 24000;
    int         tick_count = 0;
    logic       fetch_tick = 1'b0;

    always @(posedge clk27) begin
        if (rst) begin
            tick_count <= 0;
            fetch_tick <= 1'b0;
        end else begin
            fetch_tick <= 1'b0;
            tick_count <= tick_count + 1;
            if (tick_count == TICK_CYCLES - 1) begin
                tick_count <= 0;
                fetch_tick <= 1'b1;
            end
        end
    end

    soc_pkg::bus_req_s  fetch_req;
    soc_pkg::bus_rsp_s  fetch_rsp;
    logic               fetch_busy;
    logic               frame_pushed, frame_taken;
    logic               fifo_wr, fifo_full, fifo_rd, fifo_empty;
    logic [7:0]         fifo_wr_data, fifo_rd_data;

    // The real decode and the real BSRAM; only the DRAM is fake.
    // memory.sv hands the controller DDR3 addresses rebased to zero,
    // which is what the fake indexes its array with.
    memory #(
        .INIT_FILE("src/programs/boot_program.hex"),
        .DDR3_BASE(DDR3_BASE)
    ) u_memory (
        .clk(clk27), .rst(rst),
        .target_req(fetch_req), .target_rsp(fetch_rsp),
        .ddr_req(ddr_req), .ddr_rsp(ddr_rsp)
    );

    mnist_fetch #(
        .DDR3_BASE(DDR3_BASE),
        .RECORD_BYTES(RECORD_BYTES),
        .RECORDS(RECORDS)
    ) u_fetch (
        .clk(clk27), .rst(rst),
        .fetch_tick(fetch_tick), .fetch_busy(fetch_busy),
        .frame_pushed(frame_pushed), .frame_taken(frame_taken),
        .bus_req(fetch_req), .bus_rsp(fetch_rsp),
        .fifo_full(fifo_full), .fifo_wr(fifo_wr), .fifo_data(fifo_wr_data)
    );

    async_fifo #(.DEPTH(1024), .WIDTH(8)) u_fifo (
        .wr_clk(clk27), .wr_rst(rst),
        .wr_en(fifo_wr && !fifo_full), .wr_data(fifo_wr_data), .full(fifo_full),
        .rd_clk(pix_clk), .rd_rst(rst),
        .rd_en(fifo_rd && !fifo_empty), .rd_data(fifo_rd_data), .empty(fifo_empty)
    );

    logic        video_de, video_hs, video_vs, vblank_start, frame_start;
    logic [10:0] pixel_x, pixel_y;
    logic [7:0]  rgb_r, rgb_g, rgb_b, rgb_de;

    hdmi_timing #(
        .H_TOTAL(H_ACTIVE + 32), .H_SYNC(8), .H_BACK(16), .H_ACTIVE(H_ACTIVE),
        .V_TOTAL(V_ACTIVE + 8),  .V_SYNC(2), .V_BACK(4),  .V_ACTIVE(V_ACTIVE)
    ) u_timing (
        .pix_clk(pix_clk), .rst(rst),
        .de(video_de), .hs(video_hs), .vs(video_vs),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .frame_start(frame_start), .vblank_start(vblank_start)
    );

    mnist_frame_source #(
        .SCALE(SCALE), .ROWS(ROWS), .COLS(COLS),
        .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .BACKGROUND(BACKGROUND)
    ) u_source (
        .pix_clk(pix_clk), .rst(rst),
        .de(video_de), .pixel_x(pixel_x), .pixel_y(pixel_y),
        .vblank_start(vblank_start),
        .fifo_data(fifo_rd_data), .fifo_empty(fifo_empty),
        .fifo_rd(fifo_rd),
        .frame_pushed(frame_pushed), .frame_taken(frame_taken),
        .rgb_r(rgb_r), .rgb_g(rgb_g), .rgb_b(rgb_b), .rgb_de(rgb_de)
    );


    // ---------------- the monitor ----------------
    // Rebuilds the frame from rgb_de cycles only, and at each blanking
    // checks the frame that just finished against the record the
    // source says it drained (its latched label byte).
    int         fb_index = 0;
    int         frames_seen = 0;
    logic [7:0] framebuffer [0:H_ACTIVE*V_ACTIVE-1];

    always @(posedge pix_clk) begin
        if (vblank_start) begin
            frames_seen++;
            fb_index <= 0;
        end else if (rgb_de) begin
            framebuffer[fb_index] <= rgb_r;
            fb_index <= fb_index + 1;
        end
    end

    int  errors = 0;
    int  checks = 0;
    int  frames_checked = 0;
    logic [7:0] last_checked_label = 8'hFF;
    int  distinct_labels = 0;

    // Check one finished frame against the record the source drained.
    task automatic check_frame(input logic [7:0] label_cur);
        int r, dx, dy, idx;
        logic [7:0] want;
    begin
        checks++;
        // The label the source last drained names the record on screen:
        // by the time a frame has been shown, its drain is long done.
        r = record_of_label(label_cur);
        if (label_cur != last_checked_label) begin
            distinct_labels++;
            last_checked_label = label_cur;
        end

        // Every image pixel.
        for (dy = 0; dy < IMAGE_H; dy++)
            for (dx = 0; dx < IMAGE_W; dx++) begin
                idx = (Y0 + dy) * H_ACTIVE + X0 + dx;
                want = image_byte(r, (dy / SCALE) * COLS + dx / SCALE);
                if (framebuffer[idx] !== want) begin
                    errors++;
                    if (errors < 8)
                        $display("FAIL: screen (%0d,%0d) = %02h, expected %02h (record %0d)",
                                 X0 + dx, Y0 + dy, framebuffer[idx], want, r);
                end
            end

        // Background outside the image.
        for (int by = 0; by < V_ACTIVE; by += 7)
            for (int bx = 0; bx < H_ACTIVE; bx += 5) begin
                idx = by * H_ACTIVE + bx;
                if (!(bx >= X0 && bx < X0 + IMAGE_W && by >= Y0 && by < Y0 + IMAGE_H)
                        && framebuffer[idx] !== BACKGROUND) begin
                    errors++;
                    if (errors < 8)
                        $display("FAIL: background (%0d,%0d) = %02h, expected %02h",
                                 bx, by, framebuffer[idx], BACKGROUND);
                end
            end
        frames_checked++;
    end
    endtask


    // BSRAM check: the record the fetcher just copied, byte for byte.
    // Each record goes to BSRAM_OFFSET + r*RECORD_BYTES, which wraps
    // through the 32 KiB array as a ring.
    task automatic check_bsram(input int r);
        logic [7:0] want, got;
        int base;
    begin
        base = (32'h1000 + r * RECORD_BYTES) >> 2;
        for (int i = 0; i < RECORD_BYTES; i++) begin
            want = image_byte(r, i);
            got = u_memory.u_bsram.mem_q[base + i / 4] >> (8 * (i % 4));
            if (got !== want) begin
                errors++;
                if (errors < 8)
                    $display("FAIL: bsram[%0d] = %02h, expected %02h (record %0d)",
                             i, got, want, r);
            end
        end
        checks++;
    end
    endtask

    // ---------------- the script ----------------
    int bsram_checked = 0;
    logic pushed_q = 1'b0;

    // The record the fetcher is copying: latched when its tick starts,
    // because record_index_q advances in the same cycle as the push.
    int exp_record = 0;
    int dbg_cycles = 0;

    always @(posedge clk27) begin
        if (rst) begin
            dbg_cycles <= 0;
        end else begin
            if (fetch_tick && !fetch_busy) exp_record <= u_fetch.record_index_q;
            if (fetch_tick) dbg_cycles <= 1;
            else if (dbg_cycles > 0 && dbg_cycles < 14) begin
                dbg_cycles <= dbg_cycles + 1;
                $display("bus cy%0d st=%0d widx=%0d req=%b op=%b addr=%h wdata=%h ready=%b",
                         dbg_cycles, u_fetch.state_q, u_fetch.word_index_q,
                         fetch_req.valid, fetch_req.op,
                         fetch_req.addr, fetch_req.wdata, fetch_rsp.ready);
            end
        end
    end

    always @(posedge clk27) begin
        if (!rst) begin
            if (frame_pushed && !pushed_q && bsram_checked < 2) begin
                $display("push: record_index=%0d label=%0d mem400=%h mem401=%h",
                         u_fetch.record_index_q, u_fetch.label_byte_q,
                         u_memory.u_bsram.mem_q[32'h400],
                         u_memory.u_bsram.mem_q[32'h401]);
                check_bsram(exp_record);
                bsram_checked++;
            end
            pushed_q <= frame_pushed;
        end
    end

    always @(posedge pix_clk) begin
        if (vblank_start && frames_seen < 14)
            $display("vbl #%0d empty=%b full=%b st=%0d psync=%b taken_q=%b wrp=%0d rdp=%0d fstate=%0d",
                     frames_seen, fifo_empty, fifo_full, u_source.state_q,
                     u_source.frame_pushed_sync2, u_source.frame_taken_q,
                     u_fifo.wr_ptr_q, u_fifo.rd_ptr_q, u_fetch.state_q);
        if (vblank_start && frames_seen >= 3 && frames_seen <= 80 &&
            u_source.frame_taken_q) begin
            check_frame(u_source.label_q);
            $display("checked frame %0d: label=%0d st=%0d img[0..5]=%h %h %h %h %h %h drain_idx=%0d",
                     frames_seen, u_source.label_q, u_source.state_q,
                     u_source.image_store[0], u_source.image_store[1],
                     u_source.image_store[2], u_source.image_store[3],
                     u_source.image_store[4], u_source.image_store[5],
                     u_source.drain_index_q);
        end
    end

    initial begin
        rst = 1'b1;
        repeat (8) @(posedge clk27);
        rst = 1'b0;
        // The fetcher needs several ticks to run through the records;
        // each one is limited by the display, one image per drain.
        wait (frames_seen >= 80);
        repeat (4) @(posedge pix_clk);

        checks++;
        if (frames_checked < 4) begin
            errors++;
            $display("FAIL: only %0d frames checked, expected at least 4", frames_checked);
        end
        if (distinct_labels < 3) begin
            errors++;
            $display("FAIL: only %0d distinct records shown, expected at least 3",
                     distinct_labels);
        end
        if (errors == 0)
            $display("PASS: mnist_view %0d checks, %0d frames, %0d records shown",
                     checks, frames_checked, distinct_labels);
        else
            $display("FAIL: mnist_view %0d checks, %0d errors", checks, errors);
        $finish;
    end

    // Watchdog: the run should finish well inside this budget.
    initial begin
        #40_000_000;
        $display("FAIL: mnist_view timed out after %0d frames", frames_seen);
        $finish;
    end

endmodule
