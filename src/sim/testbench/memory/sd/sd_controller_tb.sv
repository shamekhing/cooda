`timescale 1ns/1ps
// ============================================================
// sd_controller_tb  microSD protocol test
// ============================================================
//
// sd_controller against the behavioural card in sd_model.
//
// Checked:
//   1. the wake-up sequence, command for command: CMD0, CMD8,
//      CMD55+ACMD41 (repeated until the card is ready), CMD58,
//      CMD16, and then ready
//   2. an SDHC card is recognised (sector addressing)
//   3. an SDSC card is recognised and addressed in bytes
//   4. an old (v1) card that rejects CMD8 is recognised, and CMD58
//      is skipped for it
//   5. block reads: 128 words per block, in order, assembled little
//      endian, with block_busy and block_done behaving
//   6. the card's Ncr bytes and token delay are waited out rather
//      than assumed away
//   7. every failure has a code: a deaf card (CMD0), a bad CMD8
//      echo, a card that never comes ready, a rejected CMD17, and a
//      missing data token
//
// The divider and the bounds are shortened from the hardware values
// so the simulation stays short; the protocol is identical.
// ============================================================

module sd_controller_tb;

    // ---------------- clock / reset ----------------
    logic clk = 1'b0;
    always #18.518 clk = ~clk;              // 27 MHz

    logic rst = 1'b1;

    // ---------------- DUT ----------------
    logic        cs_n, sck, mosi, miso;
    logic        block_req;
    logic [31:0] block_addr;
    logic        block_busy, block_done, block_valid;
    logic [31:0] block_data;
    logic        ready, error;
    logic [3:0]  err_code;
    logic [1:0]  card_type;
    logic [4:0]  state_dbg;

    sd_controller #(
        .DIVIDER_INIT      (16'd4),
        .DIVIDER_DATA      (16'd1),
        .POWERUP_BYTES (10),
        .R1_POLL_BYTES      (6),
        .ACMD41_MAX_RETRIES     (4),
        .TOKEN_TIMEOUT_BYTES     (8)
    ) dut (
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
        .ready     (ready),
        .error     (error),
        .err_code  (err_code),
        .card_type (card_type),
        .state_dbg (state_dbg)
    );

    // ---------------- card ----------------
    logic [7:0]  r1_idle_bytes      = 8'd3;        // 0xFF bytes before an R1
    logic [7:0]  token_idle_bytes = 8'd5;        // 0xFF bytes before 0xFE
    logic [15:0] ready_after_tries = 16'd2;       // ACMD41 attempts before ready

    logic fault_silent      = 1'b0;
    logic fault_bad_echo    = 1'b0;
    logic fault_never_ready = 1'b0;
    logic fault_no_token    = 1'b0;
    logic fault_bad_cmd17   = 1'b0;
    logic fault_sdsc        = 1'b0;
    logic fault_v1          = 1'b0;

    logic [15:0] cmd_count;
    logic [5:0]  last_opcode;

    sd_model u_card (
        .rst             (rst),
        .cs_n            (cs_n),
        .sck             (sck),
        .mosi            (mosi),
        .miso            (miso),
        .r1_idle_bytes          (r1_idle_bytes),
        .token_idle_bytes     (token_idle_bytes),
        .ready_after_tries     (ready_after_tries),
        .fault_silent    (fault_silent),
        .fault_bad_echo  (fault_bad_echo),
        .fault_never_ready (fault_never_ready),
        .fault_no_token  (fault_no_token),
        .fault_bad_cmd17 (fault_bad_cmd17),
        .fault_sdsc      (fault_sdsc),
        .fault_v1        (fault_v1),
        .cmd_count       (cmd_count),
        .last_opcode         (last_opcode)
    );

    int errors = 0;
    int checks = 0;


    // ========================================================
    // COMMAND LOG
    // ========================================================
    // Driven by the card's own count of commands received, so the
    // log is what actually reached the wire, not what the DUT
    // intended to send.
    // --------------------------------------------------------

    int          command_log [0:31];
    int          logged_commands = 0;
    logic [15:0] card_cmd_count_seen = 16'd0;

    always @(posedge clk) begin
        if (cmd_count != card_cmd_count_seen) begin
            card_cmd_count_seen <= cmd_count;
            if (logged_commands < 32) begin
                command_log[logged_commands] = last_opcode;
                logged_commands++;
            end
        end
    end

    // ========================================================
    // HELPERS
    // ========================================================

    int          expected_ops [0:15];
    logic [7:0]  byte_value;
    int          waited_cycles;

    // The pattern the testbench loads into the card: byte i of block
    // b is (b*64 + i) truncated to 8 bits. A bus word is four of
    // those bytes, little endian (the first byte of the block is the
    // least significant byte of the word), which is the contract
    // between the card, the controller and the SoC bus.
    function automatic logic [31:0] exp_word(input int b, input int k);
        logic [31:0] o;
        o = b*64 + 4*k;
        exp_word[7:0]   = o;
        exp_word[15:8]  = o + 1;
        exp_word[23:16] = o + 2;
        exp_word[31:24] = o + 3;
    endfunction

    task automatic reset_dut();
        rst = 1'b1;
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);
        logged_commands        = 0;
        card_cmd_count_seen = 16'd0;
        block_req     = 1'b0;
    endtask

    // Wait for the wake-up sequence to finish one way or the other.
    task automatic wait_init(input int max_cycles, input string name);
        waited_cycles = 0;
        while (!ready && !error && waited_cycles < max_cycles) begin
            @(negedge clk);
            waited_cycles++;
        end
        checks++;
        if (!ready && !error) begin
            errors++;
            $display("FAIL %s: neither ready nor error after %0d cycles",
                     name, max_cycles);
        end
    endtask

    task automatic wait_err(input int max_cycles, input string name);
        waited_cycles = 0;
        while (!error && waited_cycles < max_cycles) begin
            @(negedge clk);
            waited_cycles++;
        end
        checks++;
        if (!error) begin
            errors++;
            $display("FAIL %s: no error after %0d cycles", name, max_cycles);
        end
    endtask

    task automatic check_error(input logic [3:0] code, input string name);
        checks++;
        if (!error) begin
            errors++;
            $display("FAIL %s: no error raised", name);
        end else if (err_code !== code) begin
            errors++;
            $display("FAIL %s: err_code %0d, expected %0d", name, err_code, code);
        end
    endtask

    // The exact sequence of commands the card saw.
    task automatic check_command_log(input int len, input string name);
        checks++;
        if (logged_commands != len) begin
            errors++;
            $display("FAIL %s: %0d commands reached the card, expected %0d",
                     name, logged_commands, len);
        end else begin
            for (int i = 0; i < len; i++) begin
                if (command_log[i] != expected_ops[i]) begin
                    errors++;
                    $display("FAIL %s: command %0d was %0d, expected %0d",
                             name, i, command_log[i], expected_ops[i]);
                end
            end
        end
    endtask


    // Request one block and check the 128 words against the pattern
    // the testbench loaded into the card.
    task automatic read_block(input int b, input string name);
        int n;
        n = 0;

        @(negedge clk);
        block_addr = b;
        block_req  = 1'b1;
        @(negedge clk);
        block_req  = 1'b0;

        checks++;
        if (!block_busy) begin
            errors++;
            $display("FAIL %s: block_busy is low after the request", name);
        end

        // Collect the 128 words. block_done comes several byte times
        // after the last word, so checking it first cannot lose one.
        while (!block_done && !error) begin
            @(negedge clk);
            if (block_valid) begin
                if (n < 128 && block_data !== exp_word(b, n)) begin
                    errors++;
                    $display("FAIL %s: word %0d = %08h, expected %08h",
                             name, n, block_data, exp_word(b, n));
                end
                n++;
            end
        end

        checks++;
        if (n != 128) begin
            errors++;
            $display("FAIL %s: %0d words, expected 128", name, n);
        end
        checks++;
        if (!block_done) begin
            errors++;
            $display("FAIL %s: no block_done (error=%0b code=%0d)",
                     name, error, err_code);
        end

        @(negedge clk);
        checks++;
        if (block_busy) begin
            errors++;
            $display("FAIL %s: block_busy is still high after block_done", name);
        end
    endtask
    // ========================================================
    // SEQUENCE
    // ========================================================

    initial begin
        block_req  = 1'b0;
        block_addr = 32'd0;

        repeat (5) @(negedge clk);

        // Load the card's eight blocks with a recognisable pattern.
        // This happens after the first delay on purpose: sd_model's
        // own initial block clears the store, and two initial blocks
        // at time zero run in no defined order.
        for (int b = 0; b < 8; b++) begin
            for (int i = 0; i < 512; i++) begin
                byte_value = (b*64 + i) & 8'hFF;
                u_card.block_store[b*512 + i] = byte_value;
            end
        end

        // ----------------------------------------------------
        // 1. SDHC: the wake-up sequence, command for command
        // ----------------------------------------------------
        reset_dut();
        wait_init(400_000, "init sdhc");
        checks++;
        if (!ready) begin
            errors++;
            $display("FAIL init sdhc: error=%0b code=%0d", error, err_code);
        end else begin
            checks++;
            if (card_type !== 2'd3) begin
                errors++;
                $display("FAIL init sdhc: card_type=%0d, expected 3 (SDHC)",
                         card_type);
            end
        end

        expected_ops[0]=0;  expected_ops[1]=8;  expected_ops[2]=55; expected_ops[3]=41;
        expected_ops[4]=55; expected_ops[5]=41; expected_ops[6]=55; expected_ops[7]=41;
        expected_ops[8]=58; expected_ops[9]=16;
        check_command_log(10, "init sdhc");

        // ----------------------------------------------------
        // 2. block reads: 128 words each, in order, little endian
        // ----------------------------------------------------
        read_block(5, "read block 5");
        checks++;
        if (u_card.read_lba !== 32'd5) begin
            errors++;
            $display("FAIL read block 5: the card was asked for LBA %0d",
                     u_card.read_lba);
        end

        read_block(2, "read block 2");
        read_block(0, "read block 0");
        checks++;
        if (u_card.read_lba !== 32'd0) begin
            errors++;
            $display("FAIL read block 0: the card was asked for LBA %0d",
                     u_card.read_lba);
        end
        checks++;
        if (error) begin
            errors++;
            $display("FAIL block reads: error=%0d", err_code);
        end

        // ----------------------------------------------------
        // 3. SDSC: an older card is addressed in bytes
        // ----------------------------------------------------
        fault_sdsc = 1'b1;
        reset_dut();
        wait_init(400_000, "init sdsc");
        checks++;
        if (!ready) begin
            errors++;
            $display("FAIL init sdsc: error=%0b code=%0d", error, err_code);
        end else begin
            checks++;
            if (card_type !== 2'd2) begin
                errors++;
                $display("FAIL init sdsc: card_type=%0d, expected 2 (SDv2)",
                         card_type);
            end
        end

        read_block(3, "read block 3 (sdsc)");
        // The card turned the byte address back into an LBA, so this
        // proves the controller sent 3*512 rather than 3.
        checks++;
        if (u_card.read_lba !== 32'd3) begin
            errors++;
            $display("FAIL sdsc addressing: the card was asked for LBA %0d, expected 3",
                     u_card.read_lba);
        end
        fault_sdsc = 1'b0;

        // ----------------------------------------------------
        // 4. an old card that rejects CMD8: no OCR, so no CMD58
        // ----------------------------------------------------
        fault_v1 = 1'b1;
        reset_dut();
        wait_init(400_000, "init v1");
        checks++;
        if (!ready) begin
            errors++;
            $display("FAIL init v1: error=%0b code=%0d", error, err_code);
        end else begin
            checks++;
            if (card_type !== 2'd1) begin
                errors++;
                $display("FAIL init v1: card_type=%0d, expected 1 (SDv1)",
                         card_type);
            end
        end

        expected_ops[0]=0;  expected_ops[1]=8;  expected_ops[2]=55; expected_ops[3]=41;
        expected_ops[4]=55; expected_ops[5]=41; expected_ops[6]=55; expected_ops[7]=41;
        expected_ops[8]=16;
        check_command_log(9, "init v1");
        fault_v1 = 1'b0;

        // ----------------------------------------------------
        // 5. every failure has a code
        // ----------------------------------------------------

        // a deaf card: CMD0 is never answered
        fault_silent = 1'b1;
        reset_dut();
        wait_init(400_000, "deaf card");
        check_error(4'd1, "deaf card");
        fault_silent = 1'b0;

        // CMD8 answers, but not with the check pattern
        fault_bad_echo = 1'b1;
        reset_dut();
        wait_init(400_000, "bad cmd8 echo");
        check_error(4'd2, "bad cmd8 echo");
        fault_bad_echo = 1'b0;

        // ACMD41 never reports ready
        fault_never_ready = 1'b1;
        reset_dut();
        wait_init(400_000, "never ready");
        check_error(4'd3, "never ready");
        fault_never_ready = 1'b0;

        // CMD17 is rejected
        fault_bad_cmd17 = 1'b1;
        reset_dut();
        wait_init(400_000, "init for the cmd17 fault");
        checks++;
        if (!ready) begin
            errors++;
            $display("FAIL cmd17 fault: the card never initialised");
        end
        @(negedge clk);
        block_addr = 32'd1;
        block_req  = 1'b1;
        @(negedge clk);
        block_req  = 1'b0;
        wait_err(400_000, "cmd17 rejected");
        check_error(4'd6, "cmd17 rejected");
        fault_bad_cmd17 = 1'b0;

        // the card accepts the read but never sends the data token
        fault_no_token = 1'b1;
        reset_dut();
        wait_init(400_000, "init for the token fault");
        checks++;
        if (!ready) begin
            errors++;
            $display("FAIL token fault: the card never initialised");
        end
        @(negedge clk);
        block_addr = 32'd1;
        block_req  = 1'b1;
        @(negedge clk);
        block_req  = 1'b0;
        wait_err(400_000, "no data token");
        check_error(4'd7, "no data token");
        fault_no_token = 1'b0;

        // ----------------------------------------------------
        // done
        // ----------------------------------------------------
        if (errors == 0)
            $display("PASS: sd_controller %0d checks", checks);
        else
            $fatal(1, "FAIL: sd_controller %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $fatal(1, "sd_controller_tb timeout");
    end

endmodule

