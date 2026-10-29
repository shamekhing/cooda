// ============================================================
// ddr3_controller_tb  the real controller against the Micron model
// ============================================================
//
// Drives the vendored ddr3_controller through its client interface
// with the Micron DDR3 Verilog model on the DRAM pins, so the whole
// command and PHY path is exercised: power-up init, ZQ calibration,
// write leveling, read calibration, then write/read-back and
// refresh.
//
// The clocks are generated here rather than by ddr3_pll: rPLL is a
// hard macro, and its configuration is fixed by ddr3_pll's
// parameters. The PHY primitives (DLL, OSER8, OSER8_MEM, IDES8_MEM,
// DQS, GSR) come from prim_sim.v.
//
// Both of those are third-party files that are not in the
// repository; see src/sim/vendor/README.md. run.sh skips this test
// when they are missing.
//
// Compile defines: -D SIM -D den1024Mb -D sg25 -D x16
//
// CAVEAT: under -D SIM the controller takes read data from DQ lane 4
// (`assign dout = dq_in[4]`) where hardware uses lane 0. This test
// therefore validates the command sequence, the calibration handshake
// and the client protocol, not the physical DQ lane mapping.
// ============================================================
`timescale 1ps/1ps

module ddr3_controller_tb;

    // The 1 Gb parameter file below evaluates a few parameters with
    // ceil() and max(), exactly as the model's own testbench does, so
    // both helpers have to be in scope before it is included.
    function automatic int ceil(input real number);
        ceil = (number > $rtoi(number)) ? $rtoi(number) + 1 : $rtoi(number);
    endfunction

    function automatic int max(input int a, input int b);
        max = (a > b) ? a : b;
    endfunction

    // 1 Gb organisation parameters, shared with the model so that the
    // port widths agree: x16 gives ADDR_BITS/ROW_BITS 13, COL_BITS 10,
    // BA_BITS 3, DQ_BITS 16, DM_BITS 2.
    `include "ddr3/1024Mb_ddr3_parameters.vh"

    // ========================================================
    // CLOCKS
    // ========================================================
    // DDR3-800: tCK = 2.5 ns. fclk is 4x pclk, and ck is a quarter
    // period behind fclk, as ddr3_pll produces on the board.
    //
    // This deliberately reproduces upstream's clock bring-up, down to
    // initialising `tck` with a non-blocking assignment: the first
    // #(tck/4) then evaluates to #0, so the clocks start at time 0
    // instead of a quarter period later. That matters. The Gowin
    // primitive models latch their internal serialiser phase against
    // the clocks at time 0, so starting them late rotates the DQS/DQ
    // phases: write leveling then converges to wstep=0x18 instead of
    // 0x1a, the DRAM reports ck=1 on its leveling feedback instead of
    // ck=0, and every write lands as X. Do not "tidy" this up.
    // --------------------------------------------------------

    real tck;

    logic pclk, fclk, ck;

    initial begin
        tck  <= 2500;
        fclk <= 1'b1;
        ck   <= 1'b1;
        pclk <= 1'b1;

        forever begin
            #(tck/4) ck   = ~ck;
            #(tck/4) fclk = ~fclk;
            #(tck/4) ck   = ~ck;
            #(tck/4) fclk = ~fclk;
            #(tck/4) ck   = ~ck;
            #(tck/4) fclk = ~fclk;
            #(tck/4) ck   = ~ck;
            #(tck/4) fclk = ~fclk;
            pclk = ~pclk;
        end
    end

    // ========================================================
    // DRAM PINS AND MODEL
    // ========================================================

    logic                    rst_n;
    logic                    ddr_nrst, ddr_ck;
    wire                     cke, cs_n, ras_n, cas_n, we_n, odt;
    wire [DM_BITS-1:0]       dm;
    wire [BA_BITS-1:0]       ba;
    wire [ADDR_BITS-1:0]     a;
    wire [DQ_BITS-1:0]       dq;
    wire [DQS_BITS-1:0]      dqs;
    wire [DQS_BITS-1:0]      dqs_n = ~dqs;
    wire [DQS_BITS-1:0]      tdqs_n;

    // prim_sim.v's models resolve the global reset through the
    // hierarchical name GSR.GSRO, so the top of the simulation needs an
    // instance literally named GSR: Icarus 12 refuses to elaborate
    // without it (Icarus 11 let the reference float). GSRO is active
    // low, so GSRI is tied high to hold reset inactive. The primitives
    // this design uses (OSER8, OSER8_MEM, IDES8_MEM, DQS) all take
    // GSREN="false" by default, so GSRO does not actually gate them.
    GSR GSR (.GSRI(1'b1));

    ddr3 sdram (
        .rst_n  (ddr_nrst),
        .ck     (ddr_ck),
        .ck_n   (~ddr_ck),
        .cke    (cke),
        .cs_n   (cs_n),
        .ras_n  (ras_n),
        .cas_n  (cas_n),
        .we_n   (we_n),
        .dm_tdqs(dm),
        .ba     (ba),
        .addr   (a),
        .dq     (dq),
        .dqs    (dqs),
        .dqs_n  (dqs_n),
        .tdqs_n (tdqs_n),
        .odt    (odt)
    );

    // ========================================================
    // CONTROLLER UNDER TEST
    // ========================================================

    logic        rd, wr, refresh;
    logic [25:0] addr;
    logic [15:0] din, dout;
    logic        data_ready, busy;
    logic        write_level_done, read_calib_done;
    logic [7:0]  wstep;
    logic [1:0]  rclkpos;
    logic [2:0]  rclksel;

    ddr3_controller #(.ROW_WIDTH(13), .COL_WIDTH(10)) dut (
        .DDR3_DQ(dq), .DDR3_DQS(dqs), .DDR3_A(a), .DDR3_BA(ba),
        .DDR3_nRAS(ras_n), .DDR3_nCAS(cas_n), .DDR3_nWE(we_n),
        .DDR3_nCS(cs_n), .DDR3_CK(ddr_ck), .DDR3_CKE(cke),
        .DDR3_nRESET(ddr_nrst), .DDR3_DM(dm), .DDR3_ODT(odt),

        .pclk(pclk), .fclk(fclk), .ck(ck), .resetn(rst_n),
        .rd(rd), .wr(wr), .refresh(refresh), .addr(addr),
        .din(din), .dout(dout), .dout128(), .data_ready(data_ready),
        .busy(busy),

        .write_level_done(write_level_done), .wstep(wstep),
        .read_calib_done(read_calib_done), .rclkpos(rclkpos),
        .rclksel(rclksel), .debug()
    );

    // ========================================================
    // CLIENT SIDE
    // ========================================================

    int errors = 0;
    int checks = 0;
    int dqs_edges = 0;

    // Count DQS activity on the DRAM pins: the model needs a latching
    // edge every write clock period, so a dead write strobe shows up
    // here as a low count.
    always @(dqs) dqs_edges++;

    // Match the controller's upstream client timing: wait until busy is
    // low, then assert the request after a rising edge so the DUT samples
    // it on the following rising edge.
    task automatic client_cmd(input logic rd_v, input logic wr_v,
                              input logic ref_v, input logic [25:0] a_v,
                              input logic [15:0] d_v);
        wait (busy == 1'b0);
        @(posedge pclk);
        rd      <= rd_v;
        wr      <= wr_v;
        refresh <= ref_v;
        addr    <= a_v;
        din     <= d_v;
        @(posedge pclk);
        rd      <= 1'b0;
        wr      <= 1'b0;
        refresh <= 1'b0;
        // Let the DUT's registered busy update settle before a caller
        // immediately starts waiting for the next command slot.
        @(posedge pclk);
    endtask

    // A read returns data_ready for one pclk cycle with dout valid.
    task automatic client_read(input logic [25:0] a_v,
                               output logic [15:0] d_out,
                               output logic        ok);
        client_cmd(1'b1, 1'b0, 1'b0, a_v, 16'h0);
        d_out = 16'h0;
        ok    = 1'b0;
        for (int i = 0; i < 200 && !ok; i++) begin
            @(negedge pclk);
            if (data_ready) begin
                d_out = dout;
                ok    = 1'b1;
            end
        end
    endtask

    task automatic client_write(input logic [25:0] a_v,
                                input logic [15:0] d_v);
        client_cmd(1'b0, 1'b1, 1'b0, a_v, d_v);
    endtask

    // Write, then read back, and check the value.
    task automatic write_read_check(input logic [25:0] a_v,
                                    input logic [15:0] d_v,
                                    input string       name);
        logic [15:0] got;
        logic        ok;
        client_write(a_v, d_v);
        client_read(a_v, got, ok);
        checks++;
        if (!ok) begin
            errors++;
            $display("FAIL %s: no read data for addr %07h", name, a_v);
        end else if (got !== d_v) begin
            errors++;
            $display("FAIL %s: addr %07h read %04h expected %04h",
                     name, a_v, got, d_v);
        end
    endtask

    // ========================================================
    // SEQUENCE
    // ========================================================

    int cal_wait;

    initial begin
        rd = 1'b0; wr = 1'b0; refresh = 1'b0;
        addr = 26'h0; din = 16'h0;
        rst_n = 1'b0;

        // Reset, then release on a ck edge like the board does.
        #(100_000);
        @(negedge ck);
        rst_n = 1'b1;

        // 1. Calibration: the controller holds busy high through
        //    power-up, ZQ calibration, write leveling and read
        //    calibration, so nothing may be issued before it is done.
        cal_wait = 0;
        while (!(write_level_done && read_calib_done) &&
               cal_wait < 2_000_000) begin
            @(negedge pclk);
            cal_wait++;
        end
        checks++;
        if (!(write_level_done && read_calib_done)) begin
            errors++;
            $display("FAIL calibration: wlevel=%b rcalib=%b after %0d cycles",
                     write_level_done, read_calib_done, cal_wait);
        end else begin
            $display("  calibrated after %0d pclk cycles (wstep=%02h rclkpos=%0d rclksel=%0d)",
                     cal_wait, wstep, rclkpos, rclksel);
        end

        // 2. Write/read-back across rows, banks and column limits, plus
        //    the ends of the 128 MiB window. Kept short: the Micron
        //    model and the Gowin primitive models make each access
        //    expensive in simulation time.
        write_read_check(26'h000_0000, 16'h0000, "lowest halfword");
        write_read_check(26'h000_0001, 16'hFFFF, "column 1");
        write_read_check(26'h000_2000, 16'h9ABC, "bank 1 row 0");
        write_read_check(26'h3FF_FFFF, 16'h5A5A, "highest halfword");

        // 3. Distinct values side by side, so an address decode error
        //    shows up as a data mismatch.
        write_read_check(26'h000_0010, 16'h1111, "neighbour low");
        write_read_check(26'h000_0011, 16'h2222, "neighbour high");

        // 4. Refresh must complete and leave the memory readable.
        client_cmd(1'b0, 1'b0, 1'b1, 26'h0, 16'h0);
        while (busy) @(negedge pclk);
        checks++;
        write_read_check(26'h000_0001, 16'hFFFF, "after refresh");

        if (errors == 0)
            $display("PASS: ddr3_controller %0d checks, wstep=%02h rclkpos=%0d rclksel=%0d, dqs_edges=%0d",
                     checks, wstep, rclkpos, rclksel, dqs_edges);
        else
            $display("FAIL: ddr3_controller %0d checks, %0d errors", checks, errors);
        $display("  diag: dqs_edges=%0d wstep=%02h rclkpos=%0d rclksel=%0d",
                 dqs_edges, wstep, rclkpos, rclksel);
        if (errors != 0)
            $fatal(1, "FAIL: ddr3_controller %0d checks, %0d errors",
                   checks, errors);

        $finish;
    end

    initial begin
        #(50_000_000);      // 50 us
        $fatal(1, "ddr3_controller_tb timeout");
    end

endmodule
