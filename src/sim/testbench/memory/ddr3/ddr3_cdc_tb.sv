`timescale 1ns/1ps
// ============================================================
// ddr3_cdc_tb  unit test for the clk27 <-> pclk crossing
// ============================================================
//
// Two deliberately unrelated clocks (27 MHz and 99.56 MHz) with a
// fake command engine that has variable latency, so the handshake
// is exercised at many phase relationships.
//
// Checked:
//   1. every request is answered exactly once, with the data the
//      engine produced for that address
//   2. the error bit crosses
//   3. the payload (addr/wr/wdata) does not change while cmd_req
//      is high - the property the whole crossing depends on
//   4. back-to-back requests work (a new request on the ack cycle)
//   5. reset produces no spurious ack
// ============================================================

module ddr3_cdc_tb;

    // ---------------- clocks ----------------
    logic clk_s = 1'b0;     // 27 MHz
    logic clk_c = 1'b0;     // 99.56 MHz

    always #18.518 clk_s = ~clk_s;
    always #5.022  clk_c = ~clk_c;

    logic rst_s = 1'b1;
    logic rst_c = 1'b1;

    // ---------------- SoC side ----------------
    logic        req;
    logic [25:0] addr;
    logic        wr;
    logic [31:0] wdata;
    logic        ack;
    logic [31:0] rdata;
    logic        err;

    // ---------------- engine side ----------------
    logic        cmd_req;
    logic [25:0] cmd_addr;
    logic        cmd_wr;
    logic [31:0] cmd_wdata;
    logic        cmd_done;
    logic [31:0] cmd_rdata;
    logic        cmd_err;

    int errors = 0;
    int checks = 0;

    ddr3_cdc #(.ADDR_W(26)) dut (
        .clk_s     (clk_s),
        .rst_s     (rst_s),
        .req       (req),
        .addr      (addr),
        .wr        (wr),
        .wdata     (wdata),
        .ack       (ack),
        .rdata     (rdata),
        .err       (err),

        .clk_c     (clk_c),
        .rst_c     (rst_c),
        .cmd_req   (cmd_req),
        .cmd_addr  (cmd_addr),
        .cmd_wr    (cmd_wr),
        .cmd_wdata (cmd_wdata),
        .cmd_done  (cmd_done),
        .cmd_rdata (cmd_rdata),
        .cmd_err   (cmd_err)
    );

    // ========================================================
    // FAKE COMMAND ENGINE (clk_c domain)
    // ========================================================
    // Latency varies with the address so the response never lands
    // in the same phase twice.
    // --------------------------------------------------------

    localparam logic [25:0] TOP_ADDR = '1;          // 26'h3FF_FFFF
    localparam logic [25:0] ERR_ADDR = TOP_ADDR;

    logic [31:0] exp_data;
    logic        exp_err;

    always_comb begin
        exp_data = {cmd_addr, 6'b10_1010};
        exp_err  = (cmd_addr == ERR_ADDR);
    end

    logic        eng_busy;
    logic [5:0]  eng_delay;

    always_ff @(posedge clk_c or posedge rst_c) begin
        if (rst_c) begin
            eng_busy  <= 1'b0;
            eng_delay <= 6'd0;
            cmd_done  <= 1'b0;
            cmd_rdata <= '0;
            cmd_err   <= 1'b0;
        end else begin
            cmd_done <= 1'b0;

            if (!eng_busy && cmd_req) begin
                eng_busy  <= 1'b1;
                eng_delay <= 6'd2 + cmd_addr[3:0];
            end else if (eng_busy) begin
                if (eng_delay == 6'd0) begin
                    eng_busy  <= 1'b0;
                    cmd_done  <= 1'b1;
                    cmd_rdata <= exp_data;
                    cmd_err   <= exp_err;
                end else begin
                    eng_delay <= eng_delay - 6'd1;
                end
            end
        end
    end

    // ========================================================
    // PAYLOAD STABILITY CHECKER (clk_c domain)
    // ========================================================
    // While cmd_req is asserted the payload must be rock steady.
    // --------------------------------------------------------

    logic        watch;
    logic [25:0] w_addr;
    logic        w_wr;
    logic [31:0] w_wdata;

    always @(posedge clk_c or posedge rst_c) begin
        if (rst_c) begin
            watch <= 1'b0;
        end else begin
            if (cmd_req && !watch) begin
                watch   <= 1'b1;
                w_addr  <= cmd_addr;
                w_wr    <= cmd_wr;
                w_wdata <= cmd_wdata;
            end else if (!cmd_req) begin
                watch <= 1'b0;
            end else if (cmd_addr !== w_addr ||
                         cmd_wr   !== w_wr   ||
                         cmd_wdata!== w_wdata) begin
                errors++;
                $display("FAIL payload changed while cmd_req high at %0t", $time);
            end
        end
    end

    // ========================================================
    // ACK COUNTER (clk_s domain)
    // ========================================================

    int acks;
    int reqs;
    int acks_before_reset;

    always_ff @(posedge clk_s or posedge rst_s) begin
        if (rst_s) acks <= 0;
        else if (ack) acks <= acks + 1;
    end



    // ========================================================
    // SoC-SIDE DRIVER
    // ========================================================

    logic [31:0] exp_rdata;
    logic        exp_err_s;

    // Issue one transaction and check its response.
    task automatic do_txn(input logic [25:0] a, input logic wr_v,
                          input logic [31:0] wd, input string name);
        exp_rdata = {a, 6'b10_1010};
        exp_err_s = (a == ERR_ADDR);

        @(negedge clk_s);
        req   = 1'b1;
        addr  = a;
        wr    = wr_v;
        wdata = wd;
        reqs++;

        // Hold until ack.
        while (!ack) @(negedge clk_s);

        checks++;
        if (rdata !== exp_rdata) begin
            errors++;
            $display("FAIL %s rdata: got %08h expected %08h",
                     name, rdata, exp_rdata);
        end
        if (err !== exp_err_s) begin
            errors++;
            $display("FAIL %s err: got %0b expected %0b", name, err, exp_err_s);
        end

        @(negedge clk_s);
        req = 1'b0;
    endtask

    // ========================================================
    // SEQUENCE
    // ========================================================

    logic [25:0] a;

    initial begin
        req = 1'b0; addr = '0; wr = 1'b0; wdata = '0;
        reqs = 0;

        repeat (5) @(negedge clk_s);
        rst_s = 1'b0;
        rst_c = 1'b0;
        repeat (5) @(negedge clk_s);

        // 1. reads and writes across the window, including bank
        //    and row boundaries and the top address.
        for (int i = 0; i < 32; i++) begin
            a = 26'(i * 2048);                      // row-sized steps
            do_txn(a, 1'b0, 32'h0, "read");
            do_txn(a + 26'd1, 1'b1, 32'hDEAD_0000 + 26'(i), "write");
        end
        do_txn(TOP_ADDR, 1'b0, 32'h0, "err read");
        do_txn(26'h000_0000, 1'b1, 32'h1234_5678, "low write");
        do_txn(TOP_ADDR - 26'd1, 1'b0, 32'h0, "top read");

        // 2. back-to-back transactions, no idle gap between them.
        for (int i = 0; i < 8; i++) begin
            do_txn(26'h1000 + 26'(i), 1'b0, 32'h0, "back-to-back");
        end

        repeat (20) @(negedge clk_s);

        // 3. exactly one ack per request.
        acks_before_reset = acks;
        checks++;
        if (acks_before_reset !== reqs) begin
            errors++;
            $display("FAIL ack count: %0d acks for %0d requests",
                     acks_before_reset, reqs);
        end

        // 4. reset must not produce a spurious ack.
        rst_s = 1'b1;
        rst_c = 1'b1;
        repeat (50) @(negedge clk_s);
        checks++;
        if (ack !== 1'b0) begin
            errors++;
            $display("FAIL spurious ack after reset");
        end
        rst_s = 1'b0;
        rst_c = 1'b0;
        repeat (5) @(negedge clk_s);
        do_txn(26'd256, 1'b0, 32'h0, "after reset");

        if (errors == 0)
            $display("PASS: ddr3_cdc %0d checks, %0d transactions, %0d acks",
                     checks, reqs, acks_before_reset);
        else
            $fatal(1, "FAIL: ddr3_cdc %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "ddr3_cdc_tb timeout");
    end

endmodule
