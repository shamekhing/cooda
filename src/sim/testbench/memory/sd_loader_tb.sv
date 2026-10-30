`timescale 1ns/1ps
// ============================================================
// sd_loader_tb  card image -> memory, end to end
// ============================================================
//
// sd_loader + sd_controller + the behavioural card, against a simple
// bus target that stands in for memory_ddr3. The DDR3 target itself
// is covered by ddr3_target_tb and memory_map_tb; what this test is
// about is the loader's side of the bus contract, so the target here
// is cheap enough to run thousands of transactions:
//
//   - it only answers while a request is held, and it checks that the
//     request really is held stable until it does
//   - it can be told to stall for a while, to prove the loader waits
//   - it records whether a write ever arrived before the warm-up read
//
// Checked:
//   1. a good image lands in the target, byte for byte, at the header's
//      destination offset, with every word little endian
//   2. the warm-up read happens before the first payload write
//   3. a slow bus changes nothing (the loader waits for it)
//   4. blocks_loaded, bytes_loaded and done match the header
//   5. the failures have codes: bad magic, a zero block count, a
//      destination outside the window, and a card that stops answering
// ============================================================

module sd_loader_tb;

    localparam logic [31:0] DDR3_BASE = 32'h0800_0000;
    localparam logic [31:0] MAGIC     = 32'h434F_4F44;   // "COOD"

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

    // ---------------- card ----------------
    logic [7:0]  r1_idle_bytes      = 8'd3;
    logic [7:0]  token_idle_bytes = 8'd5;
    logic [15:0] ready_after_tries = 16'd1;

    logic fault_silent      = 1'b0;
    logic fault_bad_echo    = 1'b0;
    logic fault_never_ready = 1'b0;
    logic fault_no_token    = 1'b0;
    logic fault_bad_cmd17   = 1'b0;
    logic fault_sdsc        = 1'b0;
    logic fault_v1          = 1'b0;

    logic [15:0] card_cmd_count;
    logic [5:0]  card_last_op;

    sd_model u_card (
        .rst               (rst),
        .cs_n              (cs_n),
        .sck               (sck),
        .mosi              (mosi),
        .miso              (miso),
        .r1_idle_bytes            (r1_idle_bytes),
        .token_idle_bytes       (token_idle_bytes),
        .ready_after_tries       (ready_after_tries),
        .fault_silent      (fault_silent),
        .fault_bad_echo    (fault_bad_echo),
        .fault_never_ready (fault_never_ready),
        .fault_no_token    (fault_no_token),
        .fault_bad_cmd17   (fault_bad_cmd17),
        .fault_sdsc        (fault_sdsc),
        .fault_v1          (fault_v1),
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
        .DDR3_SIZE (32'h0800_0000),
        .MAGIC     (MAGIC)
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

    // ========================================================
    // BUS TARGET (stands in for memory_ddr3)
    // ========================================================
    // 64 KiB of words, one transaction at a time. It answers only
    // while the request is held, so a master that drops valid too
    // early, or changes the payload mid-flight, is caught. slow makes
    // every answer take ten cycles instead of one.
    // --------------------------------------------------------

    logic [31:0] target_memory [0:16383];
    logic [31:0] target_writes = 32'd0;
    logic [31:0] target_reads  = 32'd0;
    logic        read_seen     = 1'b0;
    logic        write_before_read   = 1'b0;      // a write arrived too early
    logic        contract_bad  = 1'b0;      // strb/alignment/stability
    logic        slow_bus      = 1'b0;

    logic [31:0] held_addr, held_wdata;
    logic        held_valid;
    logic        just_ready;    // ignore valid for one cycle after ready

    typedef enum logic [1:0] {
        TargetIdle = 2'd0,   // a request is up
        TargetWait = 2'd1    // counting down to ready
    } target_state_e;
    target_state_e     target_state_q;
    logic [4:0]  wait_count;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            target_state_q       <= TargetIdle;
            wait_count       <= 5'd0;
            loader_rsp   <= '0;
            held_addr    <= 32'd0;
            held_wdata   <= 32'd0;
            held_valid   <= 1'b0;
            just_ready   <= 1'b0;
        end else begin
            loader_rsp.ready <= 1'b0;

            // While a request is being served it must not move.
            if (held_valid) begin
                if (!loader_req.valid) begin
                    contract_bad <= 1'b1;
                end else if (loader_req.addr !== held_addr ||
                             loader_req.wdata !== held_wdata) begin
                    contract_bad <= 1'b1;
                end
            end

            case (target_state_q)
                TargetIdle: begin
                    just_ready <= 1'b0;

                    // A master drops valid on the cycle after ready, so
                    // a request that is still up right now has already
                    // been served.
                    if (loader_req.valid && !just_ready) begin
                        held_addr  <= loader_req.addr;
                        held_wdata <= loader_req.wdata;
                        held_valid <= 1'b1;
                        wait_count     <= slow_bus ? 5'd9 : 5'd0;

                        // Every write must be a full, aligned word in
                        // the DDR3 window.
                        if (loader_req.wstrb !== soc_pkg::BUS_STRB_ALL ||
                            loader_req.addr[1:0] !== 2'b00 ||
                            loader_req.addr < DDR3_BASE)
                            contract_bad <= 1'b1;

                        if (loader_req.op == soc_pkg::BusWrite) begin
                            target_writes <= target_writes + 32'd1;
                            if (!read_seen)
                                write_before_read <= 1'b1;
                        end else begin
                            target_reads <= target_reads + 32'd1;
                            read_seen    <= 1'b1;
                        end

                        target_state_q <= TargetWait;
                    end
                end

                TargetWait: begin
                    if (wait_count == 5'd0) begin
                        loader_rsp.ready <= 1'b1;
                        held_valid       <= 1'b0;
                        just_ready       <= 1'b1;
                        if (loader_req.op == soc_pkg::BusWrite)
                            target_memory[(loader_req.addr - DDR3_BASE) >> 2]
                                <= loader_req.wdata;
                        target_state_q <= TargetIdle;
                    end else begin
                        wait_count <= wait_count - 5'd1;
                    end
                end

                default: target_state_q <= TargetIdle;
            endcase
        end
    end

    int errors = 0;
    int checks = 0;


    // ========================================================
    // HELPERS
    // ========================================================

    logic [31:0] hdr [0:3];
    logic [7:0]  byte_value;
    int          waited_cycles;
    logic [31:0] expected_word;
    int          expected_index;

    // Payload byte i of payload block p, and the bus word it becomes:
    // four bytes, the first one least significant.
    function automatic logic [7:0] payload_byte(input int p, input int i);
        payload_byte = (p*32 + i) & 8'hFF;
    endfunction

    function automatic logic [31:0] payload_word(input int p, input int k);
        logic [31:0] o;
        o = p*32 + 4*k;
        payload_word[7:0]   = o;
        payload_word[15:8]  = o + 1;
        payload_word[23:16] = o + 2;
        payload_word[31:24] = o + 3;
    endfunction

    // Header in block 0, payload in blocks 1..blocks, all stored the
    // way the card puts bytes on the wire: little endian per word.
    task automatic build_image(input int blocks, input logic [31:0] dest_off,
                               input logic [31:0] bytes);
        logic [31:0] w;

        hdr[0] = MAGIC;
        hdr[1] = blocks;
        hdr[2] = dest_off;
        hdr[3] = bytes;

        for (int k = 0; k < 128; k++) begin
            w = (k < 4) ? hdr[k] : 32'h0;
            u_card.block_store[0*512 + 4*k + 0] = w[7:0];
            u_card.block_store[0*512 + 4*k + 1] = w[15:8];
            u_card.block_store[0*512 + 4*k + 2] = w[23:16];
            u_card.block_store[0*512 + 4*k + 3] = w[31:24];
        end

        for (int p = 1; p <= blocks; p++) begin
            for (int i = 0; i < 512; i++) begin
                byte_value = payload_byte(p, i);
                u_card.block_store[p*512 + i] = byte_value;
            end
        end
    endtask

    task automatic reset_dut();
        rst = 1'b1;
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);

        target_writes = 32'd0;
        target_reads  = 32'd0;
        read_seen     = 1'b0;
        write_before_read   = 1'b0;
        contract_bad  = 1'b0;

        // Poison, so a word nobody wrote cannot be mistaken for data.
        for (int i = 0; i < 16384; i++)
            target_memory[i] = 32'hDEAD_BEEF;
    endtask

    task automatic wait_load(input int max_cycles, input string name);
        waited_cycles = 0;
        while (!load_done && !load_error && waited_cycles < max_cycles) begin
            @(negedge clk);
            waited_cycles++;
        end
        checks++;
        if (!load_done && !load_error) begin
            errors++;
            $display("FAIL %s: neither done nor error after %0d cycles",
                     name, max_cycles);
        end
    endtask

    task automatic check_load_error(input logic [3:0] code, input string name);
        checks++;
        if (!load_error) begin
            errors++;
            $display("FAIL %s: no error raised", name);
        end else if (load_err_code !== code) begin
            errors++;
            $display("FAIL %s: err_code %0d, expected %0d",
                     name, load_err_code, code);
        end
    endtask

    // Everything a good load has to get right.
    task automatic check_loaded_image(input int blocks, input logic [31:0] dest_off,
                               input string name);
        int words;
        words = blocks * 128;

        checks++;
        if (!load_done) begin
            errors++;
            $display("FAIL %s: the load did not finish (error=%0b code=%0d)",
                     name, load_error, load_err_code);
        end

        checks++;
        if (blocks_loaded !== blocks) begin
            errors++;
            $display("FAIL %s: %0d blocks loaded, expected %0d",
                     name, blocks_loaded, blocks);
        end

        checks++;
        if (bytes_loaded !== (blocks*512)) begin
            errors++;
            $display("FAIL %s: %0d bytes loaded, expected %0d",
                     name, bytes_loaded, blocks*512);
        end

        checks++;
        if (target_writes !== words) begin
            errors++;
            $display("FAIL %s: %0d bus writes, expected %0d",
                     name, target_writes, words);
        end

        checks++;
        if (write_before_read) begin
            errors++;
            $display("FAIL %s: a payload write arrived before the warm-up read",
                     name);
        end

        checks++;
        if (contract_bad) begin
            errors++;
            $display("FAIL %s: the bus contract was violated", name);
        end

        // Byte for byte, at the offset the header asked for.
        checks++;
        for (int p = 1; p <= blocks; p++) begin
            for (int k = 0; k < 128; k++) begin
                expected_word = payload_word(p, k);
                expected_index = (dest_off >> 2) + (p-1)*128 + k;
                if (target_memory[expected_index] !== expected_word) begin
                    errors++;
                    $display("FAIL %s: block %0d word %0d = %08h, expected %08h",
                             name, p, k, target_memory[expected_index], expected_word);
                end
            end
        end

        // And nothing past the payload was touched.
        checks++;
        for (int i = (dest_off >> 2) + words;
             i < (dest_off >> 2) + words + 4; i++) begin
            if (target_memory[i] !== 32'hDEAD_BEEF) begin
                errors++;
                $display("FAIL %s: word %0d past the payload was written",
                         name, i);
            end
        end
    endtask

    // ========================================================
    // SEQUENCE
    // ========================================================

    initial begin
        rst = 1'b1;

        // Let sd_model's initial block clear the store first: two
        // initial blocks at time zero run in no defined order.
        repeat (5) @(negedge clk);

        // ----------------------------------------------------
        // 1. a good image: three blocks at offset 0x100
        // ----------------------------------------------------
        build_image(3, 32'h100, 32'd1536 - 32'd13);
        reset_dut();
        wait_load(4_000_000, "good image");
        check_loaded_image(3, 32'h100, "good image");

        // ----------------------------------------------------
        // 2. the same thing over a bus that takes ten cycles per
        //    access instead of one: nothing may change
        // ----------------------------------------------------
        slow_bus = 1'b1;
        build_image(2, 32'h400, 32'd1024);
        reset_dut();
        wait_load(4_000_000, "slow bus");
        check_loaded_image(2, 32'h400, "slow bus");
        slow_bus = 1'b0;

        // ----------------------------------------------------
        // 3. a header with the wrong magic
        // ----------------------------------------------------
        build_image(1, 32'h0, 32'd512);
        u_card.block_store[0] = 8'h00;              // break the magic
        reset_dut();
        wait_load(4_000_000, "bad magic");
        check_load_error(4'd2, "bad magic");

        // ----------------------------------------------------
        // 4. a header that claims no payload
        // ----------------------------------------------------
        build_image(0, 32'h0, 32'd0);
        reset_dut();
        wait_load(4_000_000, "zero blocks");
        check_load_error(4'd3, "zero blocks");

        // ----------------------------------------------------
        // 5. a header whose payload runs off the end of the window
        // ----------------------------------------------------
        build_image(1, 32'h07FF_FFF0, 32'd512);
        reset_dut();
        wait_load(4_000_000, "out of range");
        check_load_error(4'd4, "out of range");

        // ----------------------------------------------------
        // 6. the card stops answering part way through
        // ----------------------------------------------------
        build_image(1, 32'h0, 32'd512);
        fault_no_token = 1'b1;
        reset_dut();
        wait_load(4_000_000, "card error");
        check_load_error(4'd1, "card error");
        fault_no_token = 1'b0;

        // ----------------------------------------------------
        // done
        // ----------------------------------------------------
        if (errors == 0)
            $display("PASS: sd_loader %0d checks", checks);
        else
            $fatal(1, "FAIL: sd_loader %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #60_000_000;
        $fatal(1, "sd_loader_tb timeout");
    end

endmodule

