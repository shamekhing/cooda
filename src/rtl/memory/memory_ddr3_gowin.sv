module memory_ddr3_gowin #(
    parameter int CAL_WAIT_CYCLES = 270_000,
    parameter int APP_TIMEOUT_CYCLES = 8_192
) (
    input  logic clk,
    input  logic rst,
    input  logic ddr_fclk,
    input  logic ddr_pll_lock,
    input  logic ddr_rst,
    input  soc_pkg::bus_req_s target_req,
    output soc_pkg::bus_rsp_s target_rsp,
    output logic ready,
    output logic err_sticky,
    output logic [63:0] debug_status,
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0] DDR3_DQS,
    inout  wire [1:0] DDR3_DQS_N,
    output wire [13:0] DDR3_A,
    output wire [2:0] DDR3_BA,
    output wire DDR3_nRAS,
    output wire DDR3_nCAS,
    output wire DDR3_nWE,
    output wire DDR3_CK,
    output wire DDR3_CK_N,
    output wire DDR3_CKE,
    output wire DDR3_nRESET,
    output wire [1:0] DDR3_DM,
    output wire DDR3_ODT
);
    localparam logic [31:0] DDR3_BYTES = 32'h0800_0000;
    localparam logic [2:0] CMD_WRITE = 3'h0;
    localparam logic [2:0] CMD_READ = 3'h1;

    logic init_calib_complete;
    logic app_clk;
    logic ready_meta, ready_sync;
    logic [31:0] cal_wait_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ready_meta <= 1'b0;
            ready_sync <= 1'b0;
            cal_wait_q <= '0;
        end else begin
            ready_meta <= init_calib_complete;
            ready_sync <= ready_meta;

            if (!target_req.valid || ready_sync)
                cal_wait_q <= '0;
            else if (cal_wait_q < CAL_WAIT_CYCLES)
                cal_wait_q <= cal_wait_q + 1'b1;
        end
    end

    assign ready = ready_sync;

    logic [2:0] bus_state_q;
    localparam logic [2:0] BusIdle = 3'd0;
    localparam logic [2:0] BusActive = 3'd1;
    localparam logic [2:0] BusRespond = 3'd2;

    logic [26:0] cdc_addr;
    logic cdc_wr;
    logic [31:0] cdc_wdata, cdc_rdata;
    logic cdc_req, cdc_ack, cdc_err;
    logic cdc_cmd_req;
    logic [26:0] cdc_cmd_addr;
    logic cdc_cmd_wr;
    logic [31:0] cdc_cmd_wdata, cdc_cmd_rdata;
    logic cdc_cmd_done, cdc_cmd_err;
    logic local_error, calibration_timeout;

    assign calibration_timeout = !ready_sync &&
                                 (cal_wait_q >= CAL_WAIT_CYCLES);
    assign local_error =
        (target_req.addr >= DDR3_BYTES) ||
        !soc_pkg::bus_is_aligned(target_req.addr) ||
        ((target_req.op == soc_pkg::BusWrite) &&
         (target_req.wstrb != soc_pkg::BUS_STRB_ALL)) ||
        calibration_timeout;
    assign cdc_req = (bus_state_q == BusActive);

    ddr3_cdc #(.ADDR_W(27)) u_ddr3_cdc (
        .clk_s(clk), .rst_s(rst),
        .req(cdc_req), .addr(cdc_addr), .wr(cdc_wr), .wdata(cdc_wdata),
        .ack(cdc_ack), .rdata(cdc_rdata), .err(cdc_err),
        .clk_c(app_clk), .rst_c(ddr_rst),
        .cmd_req(cdc_cmd_req), .cmd_addr(cdc_cmd_addr),
        .cmd_wr(cdc_cmd_wr), .cmd_wdata(cdc_cmd_wdata),
        .cmd_done(cdc_cmd_done), .cmd_rdata(cdc_cmd_rdata),
        .cmd_err(cdc_cmd_err)
    );

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bus_state_q <= BusIdle;
            cdc_addr <= '0;
            cdc_wr <= 1'b0;
            cdc_wdata <= '0;
            target_rsp.ready <= 1'b0;
            target_rsp.rdata <= '0;
            target_rsp.error <= 1'b0;
            err_sticky <= 1'b0;
        end else begin
            target_rsp.ready <= 1'b0;

            case (bus_state_q)
                BusIdle: begin
                    if (target_req.valid) begin
                        if (local_error) begin
                            target_rsp.ready <= 1'b1;
                            target_rsp.rdata <= '0;
                            target_rsp.error <= 1'b1;
                            err_sticky <= 1'b1;
                            bus_state_q <= BusRespond;
                        end else if (ready_sync) begin
                            cdc_addr <= {1'b0, target_req.addr[26:1]};
                            cdc_wr <= target_req.op == soc_pkg::BusWrite;
                            cdc_wdata <= target_req.wdata;
                            bus_state_q <= BusActive;
                        end
                    end
                end

                BusActive: begin
                    if (cdc_ack) begin
                        target_rsp.ready <= 1'b1;
                        target_rsp.rdata <= cdc_rdata;
                        target_rsp.error <= cdc_err;
                        if (cdc_err) err_sticky <= 1'b1;
                        bus_state_q <= BusRespond;
                    end
                end

                BusRespond: bus_state_q <= BusIdle;
                default: bus_state_q <= BusIdle;
            endcase
        end
    end

    logic app_cmd_ready, app_wr_data_ready;
    logic app_rd_data_valid;
    logic [127:0] app_rd_data;
    logic [2:0] app_cmd;
    logic app_cmd_en, app_wr_data_en;
    logic [26:0] app_addr;
    logic [127:0] app_wr_data;
    logic [15:0] app_wr_data_mask;
    logic app_rd_data_end, app_sr_ack, app_ref_ack, app_ddr_rst;
    logic [13:0] ip_ddr_addr;
    logic [2:0] ip_ddr_ba;
    logic ip_ddr_cs_n, ip_ddr_ck_n;
    logic ip_ddr_ras_n, ip_ddr_cas_n, ip_ddr_we_n;
    logic ip_ddr_ck, ip_ddr_cke, ip_ddr_odt, ip_ddr_reset_n;
    logic [1:0] ip_ddr_dqm;

    logic [2:0] engine_state_q;
    localparam logic [2:0] EngIdle = 3'd0;
    localparam logic [2:0] EngIssue = 3'd1;
    localparam logic [2:0] EngRead = 3'd2;
    localparam logic [2:0] EngDone = 3'd3;
    logic [26:0] engine_addr_q;
    logic engine_wr_q, engine_error_q;
    logic [31:0] engine_wdata_q, engine_rdata_q;
    logic [31:0] engine_wait_q;

    // The app address counts halfwords; one 128-bit BL8 transfer spans 8.
    // Gowin's byte-mask bits are active high, so mask all but this bus word.
    always_comb begin
        app_wr_data = '0;
        app_wr_data_mask = 16'hffff;
        case (engine_addr_q[2:1])
            2'd0: begin
                app_wr_data[31:0] = engine_wdata_q;
                app_wr_data_mask[3:0] = 4'b0000;
            end
            2'd1: begin
                app_wr_data[63:32] = engine_wdata_q;
                app_wr_data_mask[7:4] = 4'b0000;
            end
            2'd2: begin
                app_wr_data[95:64] = engine_wdata_q;
                app_wr_data_mask[11:8] = 4'b0000;
            end
            default: begin
                app_wr_data[127:96] = engine_wdata_q;
                app_wr_data_mask[15:12] = 4'b0000;
            end
        endcase
    end

    assign app_addr = {engine_addr_q[26:3], 3'b000};
    assign app_cmd = engine_wr_q ? CMD_WRITE : CMD_READ;
    assign app_cmd_en = (engine_state_q == EngIssue) &&
                        init_calib_complete && app_cmd_ready &&
                        (!engine_wr_q || app_wr_data_ready);
    assign app_wr_data_en = app_cmd_en && engine_wr_q;
    assign cdc_cmd_done = (engine_state_q == EngDone);
    assign cdc_cmd_rdata = engine_rdata_q;
    assign cdc_cmd_err = engine_error_q;

    always_ff @(posedge app_clk or posedge ddr_rst) begin
        if (ddr_rst) begin
            engine_state_q <= EngIdle;
            engine_addr_q <= '0;
            engine_wr_q <= 1'b0;
            engine_wdata_q <= '0;
            engine_rdata_q <= '0;
            engine_error_q <= 1'b0;
            engine_wait_q <= '0;
        end else begin
            case (engine_state_q)
                EngIdle: begin
                    engine_wait_q <= '0;
                    if (cdc_cmd_req && init_calib_complete) begin
                        engine_addr_q <= cdc_cmd_addr;
                        engine_wr_q <= cdc_cmd_wr;
                        engine_wdata_q <= cdc_cmd_wdata;
                        engine_error_q <= 1'b0;
                        engine_state_q <= EngIssue;
                    end
                end

                EngIssue: begin
                    if (app_cmd_en) begin
                        engine_wait_q <= '0;
                        if (engine_wr_q) begin
                            engine_state_q <= EngDone;
                        end else if (app_rd_data_valid) begin
                            case (engine_addr_q[2:1])
                                2'd0: engine_rdata_q <= app_rd_data[31:0];
                                2'd1: engine_rdata_q <= app_rd_data[63:32];
                                2'd2: engine_rdata_q <= app_rd_data[95:64];
                                default: engine_rdata_q <= app_rd_data[127:96];
                            endcase
                            engine_state_q <= EngDone;
                        end else begin
                            engine_state_q <= EngRead;
                        end
                    end else if (engine_wait_q >= APP_TIMEOUT_CYCLES) begin
                        engine_error_q <= 1'b1;
                        engine_state_q <= EngDone;
                    end else begin
                        engine_wait_q <= engine_wait_q + 1'b1;
                    end
                end

                EngRead: begin
                    if (app_rd_data_valid) begin
                        case (engine_addr_q[2:1])
                            2'd0: engine_rdata_q <= app_rd_data[31:0];
                            2'd1: engine_rdata_q <= app_rd_data[63:32];
                            2'd2: engine_rdata_q <= app_rd_data[95:64];
                            default: engine_rdata_q <= app_rd_data[127:96];
                        endcase
                        engine_state_q <= EngDone;
                    end else if (engine_wait_q >= APP_TIMEOUT_CYCLES) begin
                        engine_error_q <= 1'b1;
                        engine_state_q <= EngDone;
                    end else begin
                        engine_wait_q <= engine_wait_q + 1'b1;
                    end
                end

                EngDone: engine_state_q <= EngIdle;
                default: engine_state_q <= EngIdle;
            endcase
        end
    end

    DDR3_Memory_Interface_Top u_ddr3 (
        .memory_clk(ddr_fclk),
        .clk(clk),
        .pll_lock(ddr_pll_lock),
        .rst_n(!ddr_rst),
        .app_burst_number(6'd0),
        .cmd(app_cmd),
        .cmd_en(app_cmd_en),
        .addr({1'b0, app_addr}),
        .wr_data(app_wr_data),
        .wr_data_en(app_wr_data_en),
        .wr_data_end(app_wr_data_en),
        .wr_data_mask(app_wr_data_mask),
        .sr_req(1'b0),
        .ref_req(1'b0),
        .burst(1'b1),
        .cmd_ready(app_cmd_ready),
        .wr_data_rdy(app_wr_data_ready),
        .rd_data(app_rd_data),
        .rd_data_valid(app_rd_data_valid),
        .rd_data_end(app_rd_data_end),
        .sr_ack(app_sr_ack),
        .ref_ack(app_ref_ack),
        .init_calib_complete(init_calib_complete),
        .clk_out(app_clk),
        .ddr_rst(app_ddr_rst),
        .O_ddr_addr(ip_ddr_addr),
        .O_ddr_ba(ip_ddr_ba),
        .O_ddr_cs_n(ip_ddr_cs_n),
        .O_ddr_ras_n(ip_ddr_ras_n),
        .O_ddr_cas_n(ip_ddr_cas_n),
        .O_ddr_we_n(ip_ddr_we_n),
        .O_ddr_clk(ip_ddr_ck),
        .O_ddr_clk_n(ip_ddr_ck_n),
        .O_ddr_cke(ip_ddr_cke),
        .O_ddr_odt(ip_ddr_odt),
        .O_ddr_reset_n(ip_ddr_reset_n),
        .O_ddr_dqm(ip_ddr_dqm),
        .IO_ddr_dq(DDR3_DQ),
        .IO_ddr_dqs(DDR3_DQS),
        .IO_ddr_dqs_n(DDR3_DQS_N)
    );

    assign DDR3_A = ip_ddr_addr;
    assign DDR3_BA = ip_ddr_ba;
    assign DDR3_nRAS = ip_ddr_ras_n;
    assign DDR3_nCAS = ip_ddr_cas_n;
    assign DDR3_nWE = ip_ddr_we_n;
    assign DDR3_CK = ip_ddr_ck;
    assign DDR3_CK_N = ip_ddr_ck_n;
    assign DDR3_CKE = ip_ddr_cke;
    assign DDR3_nRESET = ip_ddr_reset_n;
    assign DDR3_DM = ip_ddr_dqm;
    assign DDR3_ODT = ip_ddr_odt;

    logic [2:0] engine_state_meta, engine_state_sync;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            engine_state_meta <= EngIdle;
            engine_state_sync <= EngIdle;
        end else begin
            engine_state_meta <= engine_state_q;
            engine_state_sync <= engine_state_meta;
        end
    end

    always_comb begin
        debug_status = '0;
        debug_status[2:0] = engine_state_sync;
        debug_status[8] = ready_sync;
        debug_status[9] = err_sticky;
    end

endmodule
