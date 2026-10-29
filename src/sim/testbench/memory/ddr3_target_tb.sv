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
    soc_pkg::bus_req_s target_req;
    soc_pkg::bus_rsp_s target_rsp;

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

    // Short refresh period so the scheduler is exercised, and a short
    // calibration wait so its timeout path is reachable in simulation.
    localparam int REFRESH_CYCLES  = 64;
    localparam int CAL_WAIT_CYCLES = 300;

    memory_ddr3 #(
        .REFRESH_CYCLES (REFRESH_CYCLES),
        .CAL_WAIT_CYCLES(CAL_WAIT_CYCLES)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .target_req(target_req),
        .target_rsp(target_rsp),

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
    logic        hold_busy_en;          // busy while idle, no command taken
    int          n_rd, n_wr, n_ref;
    int          pclk_cycles;           // free-running pclk counter

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
            pclk_cycles   <= 0;
        end else begin
            ctl_data_ready <= 1'b0;
            pclk_cycles    <= pclk_cycles + 1;

            if (!ctl_busy) begin
                // Hold the controller busy without taking a command,
                // which is what the engine's step 0 must retry
                // through rather than advance past.
                if (hold_busy_en) begin
                    ctl_busy <= 1'b1;
                    busy_cnt <= 4'd15;
                end else if (ctl_rd || ctl_wr || ctl_refresh) begin
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
        target_req.valid = 1'b1;
        target_req.op    = wr_v ? soc_pkg::BusWrite : soc_pkg::BusRead;
        target_req.addr  = a;
        target_req.wdata = wd;
        target_req.wstrb = strb;

        while (!target_rsp.ready) @(negedge clk);
        rd_out  = target_rsp.rdata;
        err_out = target_rsp.error;

        @(negedge clk);
        target_req.valid = 1'b0;
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
            $display("  eng=%0d step=%0d half=%b to_cnt=%0d refpend=%b busy=%b",
                     dut.eng_q, dut.step_q, dut.half_q, dut.to_cnt_q,
                     dut.ref_pending_q, ctl_busy);
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

    // Change the master's payload after the target has accepted it.
    // The transaction must still use the fields captured at acceptance.
    task automatic write_then_change_payload(input logic [31:0] a,
                                              input logic [31:0] wd);
        @(negedge clk);
        target_req.valid = 1'b1;
        target_req.op    = soc_pkg::BusWrite;
        target_req.addr  = a;
        target_req.wdata = wd;
        target_req.wstrb = soc_pkg::BUS_STRB_ALL;

        // One bus edge accepts the request and latches its payload.
        @(negedge clk);
        target_req.addr  = a + 32'd4;
        target_req.wdata = ~wd;
        while (!target_rsp.ready) @(negedge clk);
        err_v = target_rsp.error;

        @(negedge clk);
        target_req.valid = 1'b0;
        checks++;
    endtask



    // ========================================================
    // SEQUENCE
    // ========================================================

    int cmds_before;
    int cal_waited;

    initial begin
        target_req = '0;
        stall = 1'b0;
        hold_busy_en = 1'b0;
        ctl_ready = 1'b0;
        n_rd = 0; n_wr = 0; n_ref = 0;
        for (int i = 0; i < 1024; i++) fake_mem[i] = 16'h0;

        repeat (5) @(negedge clk);
        rst = 1'b0;
        rst_ddr = 1'b0;
        repeat (5) @(negedge clk);

        // 1a. Not calibrated: the request is held (no ready, nothing
        //     reaches the controller) rather than failed, then
        //     completes normally once calibration finishes.
        cmds_before = n_rd + n_wr;
        @(negedge clk);
        target_req.valid = 1'b1;
        target_req.op    = soc_pkg::BusWrite;
        target_req.addr  = 32'h0000_0010;
        target_req.wdata = 32'hAABB_CCDD;
        target_req.wstrb = BUS_STRB_ALL;
        repeat (100) @(negedge clk);        // well inside CAL_WAIT_CYCLES
        checks++;
        if (target_rsp.ready !== 1'b0) begin
            errors++;
            $display("FAIL pre-calibration: responded before calibration");
        end
        if ((n_rd + n_wr) !== cmds_before) begin
            errors++;
            $display("FAIL pre-calibration: command reached the controller");
        end

        ctl_ready = 1'b1;                   // calibration completes
        while (!target_rsp.ready) @(negedge clk);
        checks++;
        if (target_rsp.error !== 1'b0) begin
            errors++;
            $display("FAIL pre-calibration: error after calibration");
        end
        @(negedge clk);
        target_req.valid = 1'b0;
        if (fake_mem[8] !== 16'hCCDD || fake_mem[9] !== 16'hAABB) begin
            errors++;
            $display("FAIL pre-calibration: mem[8]=%04h mem[9]=%04h",
                     fake_mem[8], fake_mem[9]);
        end

        // 1b. A controller that never calibrates must produce an
        //     error rather than holding the bus forever.
        ctl_ready = 1'b0;                   // DRAM never comes up
        repeat (5) @(negedge clk);          // let the 2-FF sync settle
        @(negedge clk);
        target_req.valid = 1'b1;
        target_req.op    = soc_pkg::BusRead;
        target_req.addr  = 32'h0000_0020;
        target_req.wstrb = BUS_STRB_NONE;
        cal_waited = 0;
        while (!target_rsp.ready && cal_waited < CAL_WAIT_CYCLES + 50) begin
            @(negedge clk);
            cal_waited++;
        end
        checks++;
        if (target_rsp.ready !== 1'b1 || target_rsp.error !== 1'b1) begin
            errors++;
            $display("FAIL calibration timeout: ready=%b error=%b",
                     target_rsp.ready, target_rsp.error);
        end
        // It must have stalled for about the full wait, not failed
        // immediately.
        if (cal_waited < CAL_WAIT_CYCLES - 2) begin
            errors++;
            $display("FAIL calibration timeout: failed after only %0d cycles",
                     cal_waited);
        end
        @(negedge clk);
        target_req.valid = 1'b0;
        ctl_ready = 1'b1;                   // back to a healthy controller
        repeat (5) @(negedge clk);

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

        // The bus payload is captured when accepted, even if the
        // requester changes it before the CDC completes.
        write_then_change_payload(32'h0000_0030, 32'h5566_7788);
        if (err_v !== 1'b0 || fake_mem[24] !== 16'h7788 ||
            fake_mem[25] !== 16'h5566 || fake_mem[26] !== 16'h0000 ||
            fake_mem[27] !== 16'h0000) begin
            errors++;
            $display("FAIL payload capture: err=%b mem[24:27]=%h %h %h %h",
                     err_v, fake_mem[24], fake_mem[25],
                     fake_mem[26], fake_mem[27]);
        end

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
        expect_error(32'h0800_0000, 1'b0, 32'h0, BUS_STRB_NONE,
                    "first address beyond DDR window");
        repeat (5) @(negedge clk);
        if ((n_rd + n_wr) !== cmds_before) begin
            errors++;
            $display("FAIL: refused access reached the controller");
        end

        // The last aligned word is wholly inside the 128 MiB window;
        // the next byte address is outside it.
        bus_access(32'h07FF_FFFC, 1'b1, 32'h89AB_CDEF,
                   BUS_STRB_ALL, rd_v, err_v);
        if (err_v !== 1'b0 || fake_mem[1022] !== 16'hCDEF ||
            fake_mem[1023] !== 16'h89AB) begin
            errors++;
            $display("FAIL last DDR word: err=%b low=%h high=%h",
                     err_v, fake_mem[1022], fake_mem[1023]);
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

        // 6. Recovery: once the controller is healthy again the target
        //    must work. A stuck controller that left a refresh pending
        //    used to keep refresh holding the bus path hostage.
        expect_read(32'h0000_0010, 32'h1000_0027, "recovered after watchdog");

        // 7. Command retry: hold the controller busy while it is idle,
        //    with no command taken. The engine's step 0 must wait for
        //    ctl_busy to fall and then issue, not advance past the
        //    command (which used to lose it and end in a watchdog
        //    error).
        hold_busy_en = 1'b1;
        @(negedge clk);
        target_req.valid = 1'b1;
        target_req.op    = soc_pkg::BusWrite;
        target_req.addr  = 32'h0000_0050;
        target_req.wdata = 32'hCAFE_F00D;
        target_req.wstrb = BUS_STRB_ALL;
        repeat (30) @(negedge clk);         // engine waits in step 0
        hold_busy_en = 1'b0;                // release the controller
        while (!target_rsp.ready) @(negedge clk);
        checks++;
        if (target_rsp.error !== 1'b0) begin
            errors++;
            $display("FAIL busy-retry: unexpected error");
        end
        @(negedge clk);
        target_req.valid = 1'b0;
        if (fake_mem[40] !== 16'hF00D || fake_mem[41] !== 16'hCAFE) begin
            errors++;
            $display("FAIL busy-retry: mem[40]=%04h mem[41]=%04h",
                     fake_mem[40], fake_mem[41]);
        end

        // 8. Refresh rate: while idle, refreshes must keep coming at
        //    the programmed period (REFRESH_CYCLES pclk cycles), not
        //    at whatever rate traffic happens to allow.
        repeat (20) @(negedge clk);
        n_ref = 0;
        repeat (1000) @(negedge clk_ddr);
        checks++;
        // 1000 / 64 = 15.6 expected.
        if (n_ref < 13 || n_ref > 18) begin
            errors++;
            $display("FAIL refresh rate: %0d refreshes in 1000 pclk cycles",
                     n_ref);
        end else begin
            $display("  refresh rate: %0d refreshes per 1000 pclk cycles", n_ref);
        end

        if (errors == 0)
            $display("PASS: ddr3_target %0d checks (%0d rd, %0d wr, %0d ref)",
                     checks, n_rd, n_wr, n_ref);
        else
            $fatal(1, "FAIL: ddr3_target %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "ddr3_target_tb timeout");
    end

endmodule
