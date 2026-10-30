`timescale 1ns/1ps
// ============================================================
// sd_image_tb  a real card image, packed on the host, loaded by RTL
// ============================================================
//
// This is the test that closes the loop: tools/mnist_pack.py writes a
// card image, this testbench reads that exact file into the card
// model, and the RTL has to put every byte of the payload into the
// bus target at the offset the header asks for. Nothing about the
// header layout, the byte order, or the addressing is left to two
// separate implementations agreeing by hand.
//
// run.sh generates the image from the MNIST files in data/mnist when
// they are present; without them this test is skipped.
//
// Checked:
//   1. the magic, block count, byte count and destination in the file
//      are what the loader reports back
//   2. every payload byte arrives at DDR3_BASE + destination offset,
//      compared against the file itself, not against a formula
//   3. nothing outside the payload is touched
// ============================================================

module sd_image_tb;

    localparam logic [31:0] DDR3_BASE = 32'h0800_0000;
    localparam int          MAX_BLOCKS = 64;
    localparam string       IMG = "data/mnist/sd_image.img";

    // ---------------- clock / reset ----------------
    logic clk = 1'b0;
    always #18.518 clk = ~clk;              // 27 MHz

    logic rst = 1'b1;

    // ---------------- card side ----------------
    logic        cs_n, sck, mosi, miso;
    logic        blk_req;
    logic [31:0] blk_addr;
    logic        blk_busy, blk_done, blk_valid;
    logic [31:0] blk_data;
    logic        sd_ready, sd_error;
    logic [3:0]  sd_err_code;
    logic [1:0]  card_type;
    logic [4:0]  ctrl_state;

    sd_controller #(
        .DIV_INIT      (16'd4),
        .DIV_DATA      (16'd1),
        .POWERUP_BYTES (10),
        .POLL_MAX      (6),
        .RETRY_MAX     (4),
        .TOKEN_MAX     (8)
    ) u_ctrl (
        .clk       (clk),
        .rst       (rst),
        .cs_n      (cs_n),
        .sck       (sck),
        .mosi      (mosi),
        .miso      (miso),
        .blk_req   (blk_req),
        .blk_addr  (blk_addr),
        .blk_busy  (blk_busy),
        .blk_done  (blk_done),
        .blk_data  (blk_data),
        .blk_valid (blk_valid),
        .ready     (sd_ready),
        .error     (sd_error),
        .err_code  (sd_err_code),
        .card_type (card_type),
        .state_dbg (ctrl_state)
    );

    logic [7:0]  ncr_ff      = 8'd3;
    logic [7:0]  token_delay = 8'd5;
    logic [15:0] ready_after = 16'd1;
    logic [15:0] card_cmd_count;
    logic [5:0]  card_last_op;

    sd_model #(.BLOCKS(MAX_BLOCKS)) u_card (
        .rst               (rst),
        .cs_n              (cs_n),
        .sck               (sck),
        .mosi              (mosi),
        .miso              (miso),
        .ncr_ff            (ncr_ff),
        .token_delay       (token_delay),
        .ready_after       (ready_after),
        .fault_silent      (1'b0),
        .fault_bad_echo    (1'b0),
        .fault_never_ready (1'b0),
        .fault_no_token    (1'b0),
        .fault_bad_cmd17   (1'b0),
        .fault_sdsc        (1'b0),
        .fault_v1          (1'b0),
        .cmd_count         (card_cmd_count),
        .last_op           (card_last_op)
    );


    // ---------------- loader ----------------
    soc_pkg::bus_req_s loader_req;
    soc_pkg::bus_rsp_s loader_rsp;
    logic        load_done, load_error;
    logic [3:0]  load_err_code;
    logic [31:0] blocks_loaded, bytes_loaded;

    sd_loader #(
        .DDR3_BASE (DDR3_BASE),
        .DDR3_SIZE (32'h0800_0000)
    ) u_loader (
        .clk           (clk),
        .rst           (rst),
        .blk_req       (blk_req),
        .blk_addr      (blk_addr),
        .blk_done      (blk_done),
        .blk_data      (blk_data),
        .blk_valid     (blk_valid),
        .sd_ready      (sd_ready),
        .sd_error      (sd_error),
        .bus_req       (loader_req),
        .bus_rsp       (loader_rsp),
        .done          (load_done),
        .error         (load_error),
        .err_code      (load_err_code),
        .blocks_loaded (blocks_loaded),
        .bytes_loaded  (bytes_loaded),
        .state_dbg     ()
    );

    // ---------------- bus target ----------------
    // One transaction at a time, answered on the cycle after the
    // request. The bus contract itself is sd_loader_tb's job.
    logic [31:0] mem [0:16383];
    logic [31:0] target_writes = 32'd0;
    logic        accept;

    assign accept = loader_req.valid && !loader_rsp.ready;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            loader_rsp <= '0;
        end else begin
            loader_rsp.ready <= accept;
            if (accept && loader_req.op == soc_pkg::BusWrite) begin
                mem[(loader_req.addr - DDR3_BASE) >> 2] <= loader_req.wdata;
                target_writes <= target_writes + 32'd1;
            end
        end
    end

    // ========================================================
    // THE IMAGE
    // ========================================================

    logic [7:0]  img [0:MAX_BLOCKS*512-1];
    int          img_blocks;
    logic [31:0] img_magic, img_dest, img_bytes;
    int          fd, got;

    int errors = 0;
    int checks = 0;

    // ========================================================
    // SEQUENCE
    // ========================================================

    initial begin
        rst = 1'b1;

        // Read the image the host packer wrote. Without it there is
        // nothing to test, and that is a skip rather than a failure.
        fd = $fopen(IMG, "rb");
        if (fd == 0) begin
            $display("SKIP: sd_image (%s not found; run tools/mnist_pack.py)", IMG);
            $finish;
        end

        got = $fread(img, fd);
        $fclose(fd);

        if (got < 512) begin
            $fatal(1, "FAIL: sd_image %s is only %0d bytes", IMG, got);
        end

        // Header words are little endian: first byte is the low byte.
        img_magic = {img[3],  img[2],  img[1],  img[0]};
        img_blocks = {img[7],  img[6],  img[5],  img[4]};
        img_dest   = {img[11], img[10], img[9],  img[8]};
        img_bytes  = {img[15], img[14], img[13], img[12]};

        $display("image: %s, %0d bytes read, magic %08h, %0d payload blocks, %0d bytes, dest %08h",
                 IMG, got, img_magic, img_blocks, img_bytes, img_dest);

        checks++;
        if (img_magic !== 32'h434F_4F44) begin
            errors++;
            $display("FAIL: image magic is %08h, expected 434f4f44", img_magic);
        end
        checks++;
        if (img_blocks < 1 || img_blocks >= MAX_BLOCKS) begin
            errors++;
            $display("FAIL: image claims %0d payload blocks, model holds %0d",
                     img_blocks, MAX_BLOCKS);
        end
        checks++;
        if (got != 512 * (1 + img_blocks)) begin
            errors++;
            $display("FAIL: file is %0d bytes, header says %0d",
                     got, 512 * (1 + img_blocks));
        end

        // Hand the whole image to the card, header block included.
        for (int i = 0; i < 512 * (1 + img_blocks); i++)
            u_card.blk[i] = img[i];

        repeat (5) @(negedge clk);
        rst = 1'b1;
        repeat (5) @(negedge clk);
        rst = 1'b0;

        for (int i = 0; i < 16384; i++)
            mem[i] = 32'hDEAD_BEEF;
        target_writes = 32'd0;

        // Wait for the load.
        got = 0;
        while (!load_done && !load_error && got < 8_000_000) begin
            @(negedge clk);
            got++;
        end

        checks++;
        if (!load_done) begin
            errors++;
            $display("FAIL: the load did not finish (error=%0b code=%0d after %0d cycles)",
                     load_error, load_err_code, got);
        end

        checks++;
        if (blocks_loaded !== img_blocks) begin
            errors++;
            $display("FAIL: %0d blocks loaded, the image has %0d",
                     blocks_loaded, img_blocks);
        end

        checks++;
        if (bytes_loaded !== (img_blocks * 512)) begin
            errors++;
            $display("FAIL: %0d bytes loaded, expected %0d",
                     bytes_loaded, img_blocks * 512);
        end

        checks++;
        if (target_writes !== (img_blocks * 128)) begin
            errors++;
            $display("FAIL: %0d bus writes, expected %0d",
                     target_writes, img_blocks * 128);
        end

        // Every payload byte of the file, at the destination the file
        // asked for. This is the whole point of the test: the bytes are
        // compared against the file, not against a second formula. The
        // loader moves whole blocks, so the block padding in the file is
        // compared too.
        checks++;
        for (int j = 0; j < img_blocks * 512; j++) begin
            int          addr_byte;
            int          word_idx;
            logic [31:0] lane;
            logic [7:0]  expected;

            addr_byte = img_dest + j;
            word_idx  = addr_byte >> 2;
            lane      = addr_byte & 3;
            expected  = img[512 + j];

            if (mem[word_idx][8*lane +: 8] !== expected) begin
                errors++;
                if (errors < 8)
                    $display("FAIL: byte %0d of the payload: memory has %02h, image has %02h",
                             j, mem[word_idx][8*lane +: 8], expected);
            end
        end

        // Nothing past the blocks the header asked for may be written.
        checks++;
        for (int i = (img_dest >> 2) + img_blocks * 128;
             i < (img_dest >> 2) + img_blocks * 128 + 4; i++) begin
            if (mem[i] !== 32'hDEAD_BEEF) begin
                errors++;
                $display("FAIL: word %0d past the payload was written", i);
            end
        end

        if (errors == 0)
            $display("PASS: sd_image %0d checks, %0d payload bytes verified",
                     checks, img_blocks * 512);
        else
            $fatal(1, "FAIL: sd_image %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #80_000_000;
        $fatal(1, "sd_image_tb timeout");
    end

endmodule

