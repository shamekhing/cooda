// ============================================================
// memory_ddr3  bus target backed by the DDR3 controller
// ============================================================
//
// Presents the main-memory contract the SoC already uses, on top
// of ddr3_controller (pclk domain) and ddr3_cdc:
//
//   - 32-bit, byte-addressed, word-aligned bus
//   - target_rsp.ready is a one-cycle pulse, so the master must drop
//     target_req.valid once it completes
//   - one outstanding transaction, no pipelining
//   - while the controller has not calibrated yet the request is
//     held (stalled), not failed: the DRAM is simply not available
//     yet. If calibration never completes within CAL_WAIT_CYCLES
//     the request is failed, so a dead DRAM faults visibly instead
//     of hanging the SoC.
//   - an error instead of a hang when the address is outside the
//     DDR3 window, misaligned, or a write strobe is partial
//
// ADDRESSING
//   The controller works in 16-bit halfword addresses and writes
//   only the addressed halfword (it masks the rest of the burst
//   with DM), so one 32-bit bus word becomes two commands:
//
//     write: halfword 2i then 2i+1, low half first (little endian)
//     read : halfword 2i then 2i+1, assembled {high, low}
//
//   Byte address A maps to halfword A[26:1], so the window is
//   2^27 bytes = 128 MiB, the whole fitted DRAM.
//
// REFRESH
//   The controller leaves refresh scheduling to its client. A 1 Gb
//   DDR3 part needs 8192 auto-refreshes per 64 ms, i.e. tREFI =
//   7.8 us, so a pclk counter raises ref_pending every
//   REFRESH_CYCLES (7.5 us at 99.56 MHz, a little inside tREFI) and
//   the engine issues it as soon as the current command finishes.
//   Refresh has priority in EngIdle, so bus traffic cannot starve
//   it; a refresh that fails leaves the timer to retry rather than
//   blocking the bus path (see the watchdog below).
//
// TWO CLOCK DOMAINS
//   clk / rst        : 27 MHz SoC side, the bus contract
//   clk_ddr / rst_ddr: pclk side, the command engine
//   Only ddr3_cdc and the ctl_ready synchroniser cross between
//   them.
// ============================================================

module memory_ddr3 #(
    // pclk cycles between refreshes. 99.56 MHz / 750 = 7.53 us, just
    // inside the 7.8 us tREFI a 1 Gb DDR3 part requires (8192
    // refreshes per 64 ms). At 750 the DRAM sees ~8500 refreshes per
    // 64 ms, so there is margin for the issue latency too.
    parameter int REFRESH_CYCLES = 750,

    // clk cycles to wait for the controller to finish calibration
    // before failing the request. Power-up timers, ZQ calibration,
    // write leveling and read calibration take about 1-1.5 ms, so
    // 10 ms at 27 MHz only expires when the DRAM really is not
    // coming up.
    parameter int CAL_WAIT_CYCLES = 270_000
) (
    // ---------------- SoC domain ----------------
    input  logic        clk,
    input  logic        rst,
    input  soc_pkg::bus_req_s target_req,
    output soc_pkg::bus_rsp_s target_rsp,

    // ---------------- DDR3 controller domain ----------------
    input  logic        clk_ddr,
    input  logic        rst_ddr,

    // ddr3_controller client interface
    output logic        ctl_rd,
    output logic        ctl_wr,
    output logic        ctl_refresh,
    output logic [25:0] ctl_addr,       // halfword address
    output logic [15:0] ctl_din,
    input  logic [15:0] ctl_dout,
    input  logic        ctl_busy,
    input  logic        ctl_data_ready,
    input  logic        ctl_ready       // write_level_done & read_calib_done
);

    localparam logic [31:0] DDR3_BYTES = 32'h0800_0000;   // 128 MiB

    // ========================================================
    // STATUS CROSSING (pclk -> clk)
    // ========================================================
    // ctl_ready is quasi-static (it only ever rises), so a plain
    // two-flop synchroniser is enough.
    // --------------------------------------------------------

    logic ctl_ready_s1, ctl_ready_s2;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ctl_ready_s1 <= 1'b0;
            ctl_ready_s2 <= 1'b0;
        end else begin
            ctl_ready_s1 <= ctl_ready;
            ctl_ready_s2 <= ctl_ready_s1;
        end
    end



    // ========================================================
    // BUS CONTRACT (clk domain)
    // ========================================================

    typedef enum logic [1:0] {
        StIdle,
        StBusy,
        StDone
    } bus_state_e;

    bus_state_e bus_q, bus_d;

    logic addr_ok, align_ok, strobe_ok, local_err;
    logic ctl_wait, cal_timeout;
    logic [19:0] cal_wait_q, cal_wait_d;

    assign addr_ok   = (target_req.addr < DDR3_BYTES);
    assign align_ok  = soc_pkg::bus_is_aligned(target_req.addr);
    assign strobe_ok = (target_req.op == soc_pkg::BusRead) ||
                       (target_req.wstrb == soc_pkg::BUS_STRB_ALL);

    // Not calibrated yet: hold the request rather than failing it.
    assign ctl_wait = !ctl_ready_s2;

    // ...but do not hold forever. A DRAM that never calibrates must
    // produce an error, so the SoC faults instead of hanging.
    assign cal_timeout = (cal_wait_q == CAL_WAIT_CYCLES[19:0]);

    assign local_err = !addr_ok || !align_ok || !strobe_ok || cal_timeout;

    // Count how long a request has been held waiting for calibration.
    always_comb begin
        cal_wait_d = cal_wait_q;
        if (!ctl_wait) begin
            cal_wait_d = 20'd0;
        end else if (bus_q == StIdle && target_req.valid && !cal_timeout) begin
            cal_wait_d = cal_wait_q + 20'd1;
        end
    end

    // CDC request: held up for the whole transaction.
    logic        cdc_req;
    logic [25:0] cdc_addr;
    logic        cdc_wr;
    logic [31:0] cdc_wdata;
    logic [31:0] cdc_rdata;
    logic        cdc_ack, cdc_err;

    // The upstream master may withdraw or change its request as soon
    // as this target accepts it. Hold the accepted payload until done.
    logic [25:0] req_addr_q;
    logic        req_wr_q;
    logic [31:0] req_wdata_q;

    assign cdc_req  = (bus_q == StBusy);
    assign cdc_addr = req_addr_q;
    assign cdc_wr   = req_wr_q;
    assign cdc_wdata= req_wdata_q;

    always_comb begin
        bus_d = bus_q;

        case (bus_q)
            // Refuse a contract violation, wait for calibration, or
            // start the transaction.
            StIdle: begin
                if (target_req.valid) begin
                    if (local_err)     bus_d = StDone;   // refuse
                    else if (ctl_wait) bus_d = StIdle;   // hold
                    else               bus_d = StBusy;
                end
            end

            // Wait for the DDR3 side to finish.
            StBusy: begin
                if (cdc_ack) bus_d = StDone;
            end

            // One cycle with target_rsp.ready high.
            StDone: bus_d = StIdle;

            default: bus_d = StIdle;
        endcase
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bus_q     <= StIdle;
            req_addr_q <= '0;
            req_wr_q   <= 1'b0;
            req_wdata_q<= '0;
            cal_wait_q <= 20'd0;
            target_rsp.ready <= 1'b0;
            target_rsp.rdata <= '0;
            target_rsp.error <= 1'b0;
        end else begin
            bus_q     <= bus_d;
            cal_wait_q<= cal_wait_d;
            target_rsp.ready <= 1'b0;

            if (bus_q == StIdle && target_req.valid && !local_err) begin
                req_addr_q  <= target_req.addr[26:1];
                req_wr_q    <= (target_req.op == soc_pkg::BusWrite);
                req_wdata_q <= target_req.wdata;
            end

            if (bus_q == StIdle && target_req.valid && local_err) begin
                target_rsp.ready <= 1'b1;
                target_rsp.rdata <= '0;
                target_rsp.error <= 1'b1;
            end

            if (bus_q == StBusy && cdc_ack) begin
                target_rsp.ready <= 1'b1;
                target_rsp.rdata <= cdc_rdata;
                target_rsp.error <= cdc_err;
            end
        end
    end



    // ========================================================
    // CROSSING
    // ========================================================

    logic        eng_req, eng_wr, eng_done, eng_err;
    logic [25:0] eng_addr;
    logic [31:0] eng_wdata, eng_rdata;

    ddr3_cdc #(
        .ADDR_W (26)
    ) u_cdc (
        .clk_s     (clk),
        .rst_s     (rst),
        .req       (cdc_req),
        .addr      (cdc_addr),
        .wr        (cdc_wr),
        .wdata     (cdc_wdata),
        .ack       (cdc_ack),
        .rdata     (cdc_rdata),
        .err       (cdc_err),

        .clk_c     (clk_ddr),
        .rst_c     (rst_ddr),
        .cmd_req   (eng_req),
        .cmd_addr  (eng_addr),
        .cmd_wr    (eng_wr),
        .cmd_wdata (eng_wdata),
        .cmd_done  (eng_done),
        .cmd_rdata (eng_rdata),
        .cmd_err   (eng_err)
    );

    // ========================================================
    // COMMAND ENGINE (clk_ddr domain)
    // ========================================================
    // One command at a time, always in the same shape:
    //
    //   step 0 : wait !busy, assert the command strobe
    //   step 1 : wait busy          (the controller took it)
    //   step 2 : wait data_ready    (reads only: latch ctl_dout)
    //   step 3 : wait !busy         (command finished)
    //
    // then either repeat for the second halfword or report done.
    // A watchdog turns a command that never finishes into a bus
    // error instead of a hung SoC.
    // --------------------------------------------------------

    localparam int TIMEOUT = 1024;      // pclk cycles, ~10 us

    typedef enum logic [2:0] {
        EngIdle,
        EngRefresh,
        EngRd,
        EngWr,
        EngDone
    } eng_state_e;

    eng_state_e  eng_q,      eng_d;
    logic [1:0]  step_q,     step_d;
    logic        half_q,     half_d;
    logic [25:0] base_q,     base_d;
    logic [31:0] rdata_q,    rdata_d;
    logic        ref_pending_q, ref_pending_d;
    logic [10:0] ref_cnt_q,  ref_cnt_d;
    logic [10:0] to_cnt_q,   to_cnt_d;
    logic        err_q,      err_d;

    // Command strobes. A step only advances once the controller has
    // actually taken the command (ctl_busy high), so a strobe that
    // was gated off by ctl_busy is retried instead of being lost.
    assign ctl_rd      = (eng_q == EngRd)      && (step_q == 2'd0) && !ctl_busy;
    assign ctl_wr      = (eng_q == EngWr)      && (step_q == 2'd0) && !ctl_busy;
    assign ctl_refresh = (eng_q == EngRefresh) && (step_q == 2'd0) && !ctl_busy;

    // Halfword address and write data follow half_q, so the second
    // half of a bus word is one increment away.
    assign ctl_addr = base_q + {25'b0, half_q};
    assign ctl_din  = half_q ? eng_wdata[31:16] : eng_wdata[15:0];

    assign eng_rdata = rdata_q;
    assign eng_err   = err_q;
    assign eng_done  = (eng_q == EngDone);

    always_comb begin
        // Hold by default.
        eng_d         = eng_q;
        step_d        = step_q;
        half_d        = half_q;
        base_d        = base_q;
        rdata_d       = rdata_q;
        ref_pending_d = ref_pending_q;
        ref_cnt_d     = ref_cnt_q + 11'd1;
        to_cnt_d      = (eng_q == EngIdle) ? 11'd0 : to_cnt_q + 11'd1;
        err_d         = (eng_q == EngIdle) ? 1'b0 : err_q;

        // Refresh timer: one tick every REFRESH_CYCLES (7.5 us at
        // 99.56 MHz, inside the 7.8 us tREFI of a 1 Gb DDR3 part).
        if (ref_cnt_q >= REFRESH_CYCLES[10:0]) begin
            ref_cnt_d     = 11'd0;
            ref_pending_d = 1'b1;
        end

        // Watchdog: a command that never completes. Report the error
        // and drop any pending refresh, so a controller that is stuck
        // cannot leave refresh holding the bus path hostage; the
        // refresh timer will raise it again.
        //
        // EngDone is excluded: it is the one-cycle error-report state,
        // and letting the watchdog pre-empt its exit would trap the
        // engine there until to_cnt wrapped, answering every later
        // access with a stale error.
        if (to_cnt_q >= TIMEOUT[10:0] && eng_q != EngDone) begin
            eng_d         = EngDone;
            step_d        = 2'd0;
            half_d        = 1'b0;
            ref_pending_d = 1'b0;
            err_d         = 1'b1;
        end else begin

            case (eng_q)

                // Refresh has priority: it must not be starved by
                // bus traffic, and it is cheap (about 5 pclk cycles).
                EngIdle: begin
                    if (ref_pending_q) begin
                        eng_d  = EngRefresh;
                        step_d = 2'd0;
                    end else if (eng_req) begin
                        base_d = eng_addr;
                        half_d = 1'b0;
                        step_d = 2'd0;
                        if (eng_wr) eng_d = EngWr;
                        else        eng_d = EngRd;
                    end
                end

                EngRefresh: begin
                    case (step_q)
                        2'd0: if (!ctl_busy) step_d = 2'd1;
                        2'd1: if (ctl_busy) step_d = 2'd3;
                        2'd3: if (!ctl_busy) begin
                                  ref_pending_d = 1'b0;
                                  ref_cnt_d     = 11'd0;
                                  eng_d         = EngIdle;
                              end
                        default: step_d = 2'd0;
                    endcase
                end

                EngRd: begin
                    case (step_q)
                        // Issue the read for this halfword; retry if
                        // the controller was still busy.
                        2'd0: if (!ctl_busy) step_d = 2'd1;
                        2'd1: if (ctl_busy) step_d = 2'd2;
                        // Read data is valid on the data_ready cycle.
                        2'd2: if (ctl_data_ready) begin
                                  if (half_q) rdata_d[31:16] = ctl_dout;
                                  else        rdata_d[15:0]  = ctl_dout;
                                  step_d = 2'd3;
                              end
                        // Finished: second halfword, or done.
                        // ctl_addr is base_q + half_q, so only the
                        // half index changes here.
                        2'd3: if (!ctl_busy) begin
                                  if (!half_q) begin
                                      half_d = 1'b1;
                                      step_d = 2'd0;
                                  end else begin
                                      half_d = 1'b0;
                                      eng_d  = EngDone;
                                  end
                              end
                        default: step_d = 2'd0;
                    endcase
                end

                EngWr: begin
                    case (step_q)
                        // Issue the write for this halfword; retry if
                        // the controller was still busy. The
                        // controller masks the rest of the burst.
                        2'd0: if (!ctl_busy) step_d = 2'd1;
                        2'd1: if (ctl_busy) step_d = 2'd3;
                        2'd3: if (!ctl_busy) begin
                                  if (!half_q) begin
                                      half_d = 1'b1;
                                      step_d = 2'd0;
                                  end else begin
                                      half_d = 1'b0;
                                      eng_d  = EngDone;
                                  end
                              end
                        default: step_d = 2'd0;
                    endcase
                end

                // cmd_done pulses for exactly this one cycle.
                EngDone: eng_d = EngIdle;

                default: eng_d = EngIdle;

            endcase
        end
    end

    always_ff @(posedge clk_ddr or posedge rst_ddr) begin
        if (rst_ddr) begin
            eng_q         <= EngIdle;
            step_q        <= 2'd0;
            half_q        <= 1'b0;
            base_q        <= '0;
            rdata_q       <= '0;
            ref_pending_q <= 1'b0;
            ref_cnt_q     <= '0;
            to_cnt_q      <= '0;
            err_q         <= 1'b0;
        end else begin
            eng_q         <= eng_d;
            step_q        <= step_d;
            half_q        <= half_d;
            base_q        <= base_d;
            rdata_q       <= rdata_d;
            ref_pending_q <= ref_pending_d;
            ref_cnt_q     <= ref_cnt_d;
            to_cnt_q      <= to_cnt_d;
            err_q         <= err_d;
        end
    end

endmodule

