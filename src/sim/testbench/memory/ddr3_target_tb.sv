`timescale 1ns/1ps
// ============================================================
// ddr3_target_tb  unit test for memory_ddr3 (bus target + engine)
// ============================================================
//
// Uses a behavioural stand-in for ddr3_controller in the pclk
// domain: same busy/data_ready handshake, a 16-bit memory array,
// and a `stall` input for the watchdog test. That lets the whole
// target be tested - contract, two-halfword sequencing, refresh
// scheduling, watchdog - without Gowin's primitives or a DRAM
// model.
//
// Checked:
//   1. every access errors while the controller is not calibrated,
//      and no command reaches the controller
//   2. write then read-back of a 32-bit word, with the low
//      halfword at the lower address
//   3. misaligned, out-of-range and partial-strobe accesses error
//      without issuing a command
//   4. the refresh scheduler issues refreshes under bus load and
//      does not disturb traffic
//   5. a controller that never finishes produces an error, not a
//      hung bus (watchdog)
// ============================================================

module ddr3_target_tb;

    import soc_pkg::*;

    // ---------------- clocks ----------------
    logic clk = 1'b0;       // 27 MHz
    logic clk_ddr = 1'b0;   // 99.56 MHz

    always #18.518 clk = ~clk;
    always #5.022  clk_ddr = ~clk_ddr;

    logic rst = 1'b1;
    logic rst_ddr = 1'b1;

    // ---------------- bus ----------------
    soc_pkg::bus_req_s req;
    soc_pkg::bus_rsp_s rsp;

    // ---------------- controller side ----------------
    logic        ctl_rd, ctl_wr, ctl_refresh;
    logic [25:0] ctl_addr;
    logic [15:0] ctl_din;
    logic [15:0] ctl_dout;
    logic        ctl_busy;
    logic        ctl_data_ready;
    logic        ctl_ready;

    int errors = 0;
    int checks = 0;

    // Short refresh period so the scheduler is exercised.
    localparam int REFRESH_CYCLES = 64;

    memory_ddr3 #(
        .REFRESH_CYCLES (REFRESH_CYCLES)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .req       (req),
        .rsp       (rsp),

        .clk_ddr   (clk_ddr),
        .rst_ddr   (rst_ddr),

        .ctl_rd        (ctl_rd),
        .ctl_wr        (ctl_wr),
        .ctl_refresh   (ctl_refresh),
        .ctl_addr      (ctl_addr),
        .ctl_din       (ctl_din),
        .ctl_dout      (ctl_dout),
        .ctl_busy      (ctl_busy),
        .ctl_data_ready(ctl_data_ready),
        .ctl_ready     (ctl_ready)
    );

    // ========================================================
    // FAKE CONTROLLER (clk_ddr domain)
    // ========================================================
    // Mirrors the real handshake: busy rises the cycle after a
    // command is accepted, data_ready pulses one cycle before busy
    // falls, reads return the addressed halfword.
    // --------------------------------------------------------

    logic [15:0] fake_mem [0:1023];     // small window is enough
    logic [15:0] rd_data;
    logic [3:0]  busy_cnt;
    logic        rd_active;             // a read is in flight
    logic        stall;
    int          n_rd, n_wr, n_ref;

    always_comb begin
        ctl_dout = rd_data;
    end

    always_ff @(posedge clk_ddr or posedge rst_ddr) begin
        if (rst_ddr) begin
            ctl_busy      <= 1'b0;
            ctl_data_ready<= 1'b0;
            busy_cnt      <= 4'd0;
            rd_active     <= 1'b0;
            rd_data       <= 16'h0;
        end else begin
            ctl_data_ready <= 1'b0;

            if (!ctl_busy) begin
                if (ctl_rd || ctl_wr || ctl_refresh) begin
                    ctl_busy <= 1'b1;
                    busy_cnt <= ctl_refresh ? 4'd4 : 4'd9;
                    if (ctl_rd) begin
                        rd_data   <= fake_mem[ctl_addr[9:0]];
                        rd_active <= 1'b1;
                        n_rd      <= n_rd + 1;
                    end
                    if (ctl_wr) begin
                        fake_mem[ctl_addr[9:0]] <= ctl_din;
                        n_wr    <= n_wr + 1;
                    end
                    if (ctl_refresh) n_ref <= n_ref + 1;
                end
            end else if (stall) begin
                busy_cnt <= 4'd15;              // never finishes
            end else if (busy_cnt == 4'd0) begin
                ctl_busy  <= 1'b0;
                rd_active <= 1'b0;
            end else begin
                busy_cnt <= busy_cnt - 4'd1;
                // data_ready one cycle before busy falls, like the
                // real controller. Driven from the latched
                // rd_active, not from the transient rd strobe.
                if (rd_active && busy_cnt == 4'd1) ctl_data_ready <= 1'b1;
            end
        end
    end



    // ========================================================
    // BUS DRIVER (clk domain)
    // ========================================================

    // One access: drive the bus, wait for the response, return it.
    task automatic bus_access(input logic [31:0] a, input logic wr_v,
                              input logic [31:0] wd, input logic [3:0] strb,
                              output logic [31:0] rd_out,
                              output logic        err_out);
        @(negedge clk);
        req.valid = 1'b1;
        req.op    = wr_v ? soc_pkg::BusWrite : soc_pkg::BusRead;
        req.addr  = a;
        req.wdata = wd;
        req.wstrb = strb;

        while (!rsp.ready) @(negedge clk);
        rd_out  = rsp.rdata;
        err_out = rsp.error;

        @(negedge clk);
        req.valid = 1'b0;
        checks++;
    endtask

    logic [31:0] rd_v;
    logic        err_v;

    task automatic expect_read(input logic [31:0] a, input logic [31:0] exp,
                               input string name);
        bus_access(a, 1'b0, 32'h0, soc_pkg::BUS_STRB_NONE, rd_v, err_v);
        if (err_v !== 1'b0) begin
            errors++;
            $display("FAIL %s: unexpected error on read", name);
        end else if (rd_v !== exp) begin
            errors++;
            $display("FAIL %s: got %08h expected %08h", name, rd_v, exp);
        end
    endtask

    task automatic expect_error(input logic [31:0] a, input logic wr_v,
                                input logic [31:0] wd, input logic [3:0] strb,
                                input string name);
        bus_access(a, wr_v, wd, strb, rd_v, err_v);
        if (err_v !== 1'b1) begin
            errors++;
            $display("FAIL %s: expected an error, got none", name);
        end
    endtask



    // ========================================================
    // SEQUENCE
    // ========================================================

    int cmds_before;

    initial begin
        req = '0;
        stall = 1'b0;
        ctl_ready = 1'b0;
        n_rd = 0; n_wr = 0; n_ref = 0;
        for (int i = 0; i < 1024; i++) fake_mem[i] = 16'h0;

        repeat (5) @(negedge clk);
        rst = 1'b0;
        rst_ddr = 1'b0;
        repeat (5) @(negedge clk);

        // 1. Not calibrated: everything errors and nothing reaches
        //    the controller. (Refreshes are expected and counted
        //    separately.)
        cmds_before = n_rd + n_wr;
        expect_error(32'h0000_0000, 1'b0, 32'h0, BUS_STRB_NONE, "not-ready read");
        expect_error(32'h0000_0004, 1'b1, 32'h1234_5678, BUS_STRB_ALL, "not-ready write");
        repeat (5) @(negedge clk);
        if ((n_rd + n_wr) !== cmds_before) begin
            errors++;
            $display("FAIL: command issued while not calibrated");
        end

        // 2. Calibrated: write, read back, and check the halfword
        //    order in the DRAM.
        ctl_ready = 1'b1;
        repeat (5) @(negedge clk);

        bus_access(32'h0000_0010, 1'b1, 32'hAABB_CCDD, BUS_STRB_ALL, rd_v, err_v);
        if (err_v !== 1'b0) begin
            errors++;
            $display("FAIL write: unexpected error");
        end
        if (fake_mem[8] !== 16'hCCDD || fake_mem[9] !== 16'hAABB) begin
            errors++;
            $display("FAIL halfword order: mem[8]=%04h mem[9]=%04h",
                     fake_mem[8], fake_mem[9]);
        end
        expect_read(32'h0000_0010, 32'hAABB_CCDD, "read back");

        // A second word, to be sure addressing advances.
        bus_access(32'h0000_0020, 1'b1, 32'h1122_3344, BUS_STRB_ALL, rd_v, err_v);
        expect_read(32'h0000_0020, 32'h1122_3344, "read back 2");
        expect_read(32'h0000_0010, 32'hAABB_CCDD, "read back 1 again");

        // 3. Refused accesses: misaligned, out of range, partial
        //    strobe. None may reach the controller.
        cmds_before = n_rd + n_wr;
        expect_error(32'h0000_0002, 1'b0, 32'h0, BUS_STRB_NONE, "misaligned read");
        expect_error(32'h0800_0000, 1'b0, 32'h0, BUS_STRB_NONE, "out-of-range read");
        expect_error(32'hFFFF_FFFC, 1'b1, 32'h1, BUS_STRB_ALL, "way out of range");
        expect_error(32'h0000_0040, 1'b1, 32'h1, 4'b0001, "partial strobe");
        repeat (5) @(negedge clk);
        if ((n_rd + n_wr) !== cmds_before) begin
            errors++;
            $display("FAIL: refused access reached the controller");
        end

        // 4. Refresh: with a 64-cycle period, a burst of accesses
        //    must see refreshes and still return correct data.
        n_ref = 0;
        for (int i = 0; i < 40; i++) begin
            bus_access(32'h0000_0010, 1'b1, 32'h1000_0000 + 32'(i),
                       BUS_STRB_ALL, rd_v, err_v);
        end
        expect_read(32'h0000_0010, 32'h1000_0027, "after refresh burst");
        checks++;
        if (n_ref == 0) begin
            errors++;
            $display("FAIL: no refresh issued during the burst");
        end else begin
            $display("  refresh: %0d refreshes during 40 accesses", n_ref);
        end

        // 5. Watchdog: a controller that never finishes must turn
        //    into an error instead of a hang.
        stall = 1'b1;
        bus_access(32'h0000_0080, 1'b0, 32'h0, BUS_STRB_NONE, rd_v, err_v);
        checks++;
        if (err_v !== 1'b1) begin
            errors++;
            $display("FAIL watchdog: expected an error, got none");
        end
        stall = 1'b0;
        repeat (200) @(negedge clk);

        if (errors == 0)
            $display("PASS: ddr3_target %0d checks (%0d rd, %0d wr, %0d ref)",
                     checks, n_rd, n_wr, n_ref);
        else
            $display("FAIL: ddr3_target %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "ddr3_target_tb timeout");
    end

endmodule
