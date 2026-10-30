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
    localparam string       IMAGE_FILE = "data/mnist/sd_image.img";

    // ---------------- clock / reset ----------------
    logic clk = 1'b0;
    always #18.518 clk = ~clk;              // 27 MHz

    logic rst = 1'b1;

    // ---------------- card side ----------------
    logic        cs_n, sck, mosi, miso;
    logic        block_req;
    logic [31:0] block_addr;
    logic        block_busy, block_done, block_valid;
    logic [31:0] block_data;
    logic        sd_ready, sd_error;
    logic [3:0]  sd_err_code;
    logic [1:0]  card_type;
    logic [4:0]  ctrl_state;

    sd_controller #(
        .DIVIDER_INIT      (16'd4),
        .DIVIDER_DATA      (16'd1),
        .POWERUP_BYTES (10),
        .R1_POLL_BYTES      (6),
        .ACMD41_MAX_RETRIES     (4),
        .TOKEN_TIMEOUT_BYTES     (8)
    ) u_ctrl (
        .clk       (clk),
        .rst       (rst),
        .cs_n      (cs_n),
        .sck       (sck),
        .mosi      (mosi),
        .miso      (miso),
        .block_req   (block_req),
        .block_addr  (block_addr),
        .block_busy  (block_busy),
        .block_done  (block_done),
        .block_data  (block_data),
        .block_valid (block_valid),
        .ready     (sd_ready),
        .error     (sd_error),
        .err_code  (sd_err_code),
        .card_type (card_type),
        .state_dbg (ctrl_state)
    );

    logic [7:0]  r1_idle_bytes      = 8'd3;
    logic [7:0]  token_idle_bytes = 8'd5;
    logic [15:0] ready_after_tries = 16'd1;
    logic [15:0] card_cmd_count;
    logic [5:0]  card_last_op;

    sd_model #(.BLOCKS(MAX_BLOCKS)) u_card (
        .rst               (rst),
        .cs_n              (cs_n),
        .sck               (sck),
        .mosi              (mosi),
        .miso              (miso),
        .r1_idle_bytes            (r1_idle_bytes),
        .token_idle_bytes       (token_idle_bytes),
        .ready_after_tries       (ready_after_tries),
        .fault_silent      (1'b0),
        .fault_bad_echo    (1'b0),
        .fault_never_ready (1'b0),
        .fault_no_token    (1'b0),
        .fault_bad_cmd17   (1'b0),
        .fault_sdsc        (1'b0),
        .fault_v1          (1'b0),
        .cmd_count         (card_cmd_count),
        .last_opcode           (card_last_op)
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
        .block_req       (block_req),
        .block_addr      (block_addr),
        .block_done      (block_done),
        .block_data      (block_data),
        .block_valid     (block_valid),
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
    logic [31:0] target_memory [0:16383];
    logic [31:0] target_writes = 32'd0;
    logic        accept;

    assign accept = loader_req.valid && !loader_rsp.ready;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            loader_rsp <= '0;
        end else begin
            loader_rsp.ready <= accept;
            if (accept && loader_req.op == soc_pkg::BusWrite) begin
                target_memory[(loader_req.addr - DDR3_BASE) >> 2] <= loader_req.wdata;
                target_writes <= target_writes + 32'd1;
            end
        end
    end

    // ========================================================
    // THE IMAGE
    // ========================================================

    logic [7:0]  image_data [0:MAX_BLOCKS*512-1];
    int          image_blocks;
    logic [31:0] image_magic, image_dest, image_payload_bytes;
    int          image_fd, bytes_read;

    int errors = 0;
    int checks = 0;

    // ========================================================
    // SEQUENCE
    // ========================================================

    initial begin
        rst = 1'b1;

        // Read the image the host packer wrote. Without it there is
        // nothing to test, and that is a skip rather than a failure.
        image_fd = $fopen(IMAGE_FILE, "rb");
        if (image_fd == 0) begin
            $display("SKIP: sd_image (%s not found; run tools/mnist_pack.py)", IMAGE_FILE);
            $finish;
        end

        bytes_read = $fread(image_data, image_fd);
        $fclose(image_fd);

        if (bytes_read < 512) begin
            $fatal(1, "FAIL: sd_image %s is only %0d bytes", IMAGE_FILE, bytes_read);
        end

        // Header words are little endian: first byte is the low byte.
        image_magic = {image_data[3],  image_data[2],  image_data[1],  image_data[0]};
        image_blocks = {image_data[7],  image_data[6],  image_data[5],  image_data[4]};
        image_dest   = {image_data[11], image_data[10], image_data[9],  image_data[8]};
        image_payload_bytes  = {image_data[15], image_data[14], image_data[13], image_data[12]};

        $display("image: %s, %0d bytes read, magic %08h, %0d payload blocks, %0d bytes, dest %08h",
                 IMAGE_FILE, bytes_read, image_magic, image_blocks, image_payload_bytes, image_dest);

        checks++;
        if (image_magic !== 32'h434F_4F44) begin
            errors++;
            $display("FAIL: image magic is %08h, expected_byte 434f4f44", image_magic);
        end
        checks++;
        if (image_blocks < 1 || image_blocks >= MAX_BLOCKS) begin
            errors++;
            $display("FAIL: image claims %0d payload blocks, model holds %0d",
                     image_blocks, MAX_BLOCKS);
        end
        checks++;
        if (bytes_read != 512 * (1 + image_blocks)) begin
            errors++;
            $display("FAIL: file is %0d bytes, header says %0d",
                     bytes_read, 512 * (1 + image_blocks));
        end

        // Hand the whole image to the card, header block included.
        for (int i = 0; i < 512 * (1 + image_blocks); i++)
            u_card.block_store[i] = image_data[i];

        repeat (5) @(negedge clk);
        rst = 1'b1;
        repeat (5) @(negedge clk);
        rst = 1'b0;

        for (int i = 0; i < 16384; i++)
            target_memory[i] = 32'hDEAD_BEEF;
        target_writes = 32'd0;

        // Wait for the load.
        bytes_read = 0;
        while (!load_done && !load_error && bytes_read < 8_000_000) begin
            @(negedge clk);
            bytes_read++;
        end

        checks++;
        if (!load_done) begin
            errors++;
            $display("FAIL: the load did not finish (error=%0b code=%0d after %0d cycles)",
                     load_error, load_err_code, bytes_read);
        end

        checks++;
        if (blocks_loaded !== image_blocks) begin
            errors++;
            $display("FAIL: %0d blocks loaded, the image has %0d",
                     blocks_loaded, image_blocks);
        end

        checks++;
        if (bytes_loaded !== (image_blocks * 512)) begin
            errors++;
            $display("FAIL: %0d bytes loaded, expected_byte %0d",
                     bytes_loaded, image_blocks * 512);
        end

        checks++;
        if (target_writes !== (image_blocks * 128)) begin
            errors++;
            $display("FAIL: %0d bus writes, expected_byte %0d",
                     target_writes, image_blocks * 128);
        end

        // Every payload byte of the file, at the destination the file
        // asked for. This is the whole point of the test: the bytes are
        // compared against the file, not against a second formula. The
        // loader moves whole blocks, so the block padding in the file is
        // compared too.
        checks++;
        for (int j = 0; j < image_blocks * 512; j++) begin
            int          addr_byte;
            int          word_index;
            logic [31:0] byte_lane;
            logic [7:0]  expected_byte;

            addr_byte = image_dest + j;
            word_index  = addr_byte >> 2;
            byte_lane      = addr_byte & 3;
            expected_byte  = image_data[512 + j];

            if (target_memory[word_index][8*byte_lane +: 8] !== expected_byte) begin
                errors++;
                if (errors < 8)
                    $display("FAIL: byte %0d of the payload: memory has %02h, image has %02h",
                             j, target_memory[word_index][8*byte_lane +: 8], expected_byte);
            end
        end

        // Nothing past the blocks the header asked for may be written.
        checks++;
        for (int i = (image_dest >> 2) + image_blocks * 128;
             i < (image_dest >> 2) + image_blocks * 128 + 4; i++) begin
            if (target_memory[i] !== 32'hDEAD_BEEF) begin
                errors++;
                $display("FAIL: word %0d past the payload was written", i);
            end
        end

        if (errors == 0)
            $display("PASS: sd_image %0d checks, %0d payload bytes verified",
                     checks, image_blocks * 512);
        else
            $fatal(1, "FAIL: sd_image %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #80_000_000;
        $fatal(1, "sd_image_tb timeout");
    end

endmodule

