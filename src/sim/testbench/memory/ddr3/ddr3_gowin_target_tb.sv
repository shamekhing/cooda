module ddr3_gowin_target_tb;
    logic clk = 1'b0;
    logic app_clk = 1'b0;
    logic rst = 1'b1;
    logic ddr_rst = 1'b1;
    logic ddr_pll_lock = 1'b1;

    always #18.518 clk = ~clk;
    always #5 app_clk = ~app_clk;

    soc_pkg::bus_req_s target_req;
    soc_pkg::bus_rsp_s target_rsp;
    logic ready, err_sticky;
    logic [63:0] debug_status;
    wire [15:0] ddr_dq;
    wire [1:0] ddr_dqs;
    wire [1:0] ddr_dqs_n;
    wire [13:0] ddr_addr;
    wire [2:0] ddr_ba;
    wire ddr_ras_n, ddr_cas_n, ddr_we_n, ddr_ck, ddr_ck_n;
    wire ddr_cke, ddr_reset_n;
    wire [1:0] ddr_dm;
    wire ddr_odt;

    memory_ddr3_gowin #(
        .CAL_WAIT_CYCLES(60),
        .APP_TIMEOUT_CYCLES(32)
    ) dut (
        .clk(clk), .rst(rst),
        .ddr_fclk(app_clk), .ddr_pll_lock(ddr_pll_lock),
        .ddr_rst(ddr_rst),
        .target_req(target_req), .target_rsp(target_rsp),
        .ready(ready), .err_sticky(err_sticky),
        .debug_status(debug_status),
        .DDR3_DQ(ddr_dq), .DDR3_DQS(ddr_dqs), .DDR3_DQS_N(ddr_dqs_n),
        .DDR3_A(ddr_addr), .DDR3_BA(ddr_ba),
        .DDR3_nRAS(ddr_ras_n), .DDR3_nCAS(ddr_cas_n),
        .DDR3_nWE(ddr_we_n), .DDR3_CK(ddr_ck), .DDR3_CK_N(ddr_ck_n),
        .DDR3_CKE(ddr_cke), .DDR3_nRESET(ddr_reset_n),
        .DDR3_DM(ddr_dm), .DDR3_ODT(ddr_odt)
    );

    int checks = 0;
    int errors = 0;
    int writes_before_errors;
    int reads_before_errors;

    task automatic start_access(
        input logic [31:0] addr,
        input logic write,
        input logic [31:0] wdata,
        input logic [3:0] wstrb
    );
        @(negedge clk);
        target_req.valid = 1'b1;
        target_req.op = write ? soc_pkg::BusWrite : soc_pkg::BusRead;
        target_req.addr = addr;
        target_req.wdata = wdata;
        target_req.wstrb = wstrb;
    endtask

    task automatic finish_access(
        output logic [31:0] rdata,
        output logic error
    );
        while (target_rsp.ready !== 1'b1) @(negedge clk);
        rdata = target_rsp.rdata;
        error = target_rsp.error;
        @(negedge clk);
        target_req.valid = 1'b0;
        checks++;
    endtask

    task automatic access(
        input logic [31:0] addr,
        input logic write,
        input logic [31:0] wdata,
        input logic [3:0] wstrb,
        output logic [31:0] rdata,
        output logic error
    );
        start_access(addr, write, wdata, wstrb);
        finish_access(rdata, error);
    endtask

    task automatic expect_read(input logic [31:0] addr,
                               input logic [31:0] expected);
        logic [31:0] rdata;
        logic error;
        access(addr, 1'b0, '0, soc_pkg::BUS_STRB_NONE, rdata, error);
        if (error || rdata !== expected) begin
            errors++;
            $display("FAIL read %08h: got %08h error=%b expected %08h",
                     addr, rdata, error, expected);
        end
    endtask

    task automatic expect_error(input logic [31:0] addr,
                                input logic write,
                                input logic [31:0] wdata,
                                input logic [3:0] wstrb);
        logic [31:0] rdata;
        logic error;
        access(addr, write, wdata, wstrb, rdata, error);
        if (!error) begin
            errors++;
            $display("FAIL expected bus error at %08h", addr);
        end
    endtask

    logic [31:0] read_value;
    logic read_error;
    logic [31:0] lane_data [0:3];
    logic [15:0] expected_masks [0:3];
    int i;

    initial begin
        target_req = '0;
        lane_data[0] = 32'h1122_3344;
        lane_data[1] = 32'h5566_7788;
        lane_data[2] = 32'h99aa_bbcc;
        lane_data[3] = 32'hddee_ff00;
        expected_masks[0] = 16'hfff0;
        expected_masks[1] = 16'hff0f;
        expected_masks[2] = 16'hf0ff;
        expected_masks[3] = 16'h0fff;

        #100;
        rst = 1'b0;
        ddr_rst = 1'b0;

        start_access(32'h0, 1'b1, lane_data[0], soc_pkg::BUS_STRB_ALL);
        repeat (4) @(negedge clk);
        if (target_rsp.ready) begin
            errors++;
            $display("FAIL target responded before IP calibration");
        end
        finish_access(read_value, read_error);
        if (read_error) begin
            errors++;
            $display("FAIL first write errored while calibration completed");
        end
        if (dut.u_ddr3.fake_last_mask !== expected_masks[0] ||
            dut.u_ddr3.fake_last_addr !== 28'd0) begin
            errors++;
            $display("FAIL write lane 0 mask=%04h addr=%07h",
                     dut.u_ddr3.fake_last_mask,
                     dut.u_ddr3.fake_last_addr);
        end
        if (!ready) begin
            errors++;
            $display("FAIL calibration status did not cross to the SoC clock");
        end

        for (i = 1; i < 4; i++) begin
            access(i * 4, 1'b1, lane_data[i], soc_pkg::BUS_STRB_ALL,
                   read_value, read_error);
            if (read_error ||
                dut.u_ddr3.fake_last_mask !== expected_masks[i] ||
                dut.u_ddr3.fake_last_addr !== 28'd0) begin
                errors++;
                $display("FAIL write lane %0d mask=%04h addr=%07h",
                         i, dut.u_ddr3.fake_last_mask,
                         dut.u_ddr3.fake_last_addr);
            end
        end
        if (dut.u_ddr3.fake_last_mask !== expected_masks[3] ||
            dut.u_ddr3.fake_write_count != 4) begin
            errors++;
            $display("FAIL write lane mapping or burst count");
        end

        for (i = 0; i < 4; i++)
            expect_read(i * 4, lane_data[i]);

        access(32'h10, 1'b1, 32'hcafe_beef, soc_pkg::BUS_STRB_ALL,
               read_value, read_error);
        if (read_error || dut.u_ddr3.fake_last_addr !== 28'd8 ||
            dut.u_ddr3.fake_last_mask !== expected_masks[0]) begin
            errors++;
            $display("FAIL next-burst address/mask: addr=%07h mask=%04h",
                     dut.u_ddr3.fake_last_addr,
                     dut.u_ddr3.fake_last_mask);
        end
        expect_read(32'h10, 32'hcafe_beef);

        writes_before_errors = dut.u_ddr3.fake_write_count;
        reads_before_errors = dut.u_ddr3.fake_read_count;
        expect_error(32'h2, 1'b0, '0, soc_pkg::BUS_STRB_NONE);
        expect_error(32'h0800_0000, 1'b0, '0, soc_pkg::BUS_STRB_NONE);
        expect_error(32'h20, 1'b1, 32'h1234_5678, 4'h1);
        if (dut.u_ddr3.fake_write_count != writes_before_errors ||
            dut.u_ddr3.fake_read_count != reads_before_errors) begin
            errors++;
            $display("FAIL invalid bus accesses reached the app interface");
        end

        force dut.app_cmd_ready = 1'b0;
        expect_error(32'h0, 1'b0, '0, soc_pkg::BUS_STRB_NONE);
        release dut.app_cmd_ready;
        if (!err_sticky) begin
            errors++;
            $display("FAIL app-interface timeout was not made sticky");
        end

        ddr_pll_lock = 1'b0;
        repeat (5) @(negedge clk);
        reads_before_errors = dut.u_ddr3.fake_read_count;
        expect_error(32'h0, 1'b0, '0, soc_pkg::BUS_STRB_NONE);
        if (dut.u_ddr3.fake_read_count != reads_before_errors) begin
            errors++;
            $display("FAIL access reached the app interface before calibration");
        end

        if (errors == 0) begin
            $display("PASS ddr3_gowin_target_tb: %0d checks", checks);
            $finish;
        end else begin
            $fatal(1, "ddr3_gowin_target_tb: %0d/%0d checks failed",
                   errors, checks);
        end
    end
endmodule

module DDR3_Memory_Interface_Top (
    input wire memory_clk,
    input wire clk,
    input wire pll_lock,
    input wire rst_n,
    input wire [5:0] app_burst_number,
    input wire [2:0] cmd,
    input wire cmd_en,
    input wire [27:0] addr,
    input wire [127:0] wr_data,
    input wire wr_data_en,
    input wire wr_data_end,
    input wire [15:0] wr_data_mask,
    input wire sr_req,
    input wire ref_req,
    input wire burst,
    output wire cmd_ready,
    output wire wr_data_rdy,
    output logic [127:0] rd_data,
    output logic rd_data_valid,
    output wire rd_data_end,
    output wire sr_ack,
    output wire ref_ack,
    output logic init_calib_complete,
    output wire clk_out,
    output wire ddr_rst,
    output wire [13:0] O_ddr_addr,
    output wire [2:0] O_ddr_ba,
    output wire O_ddr_cs_n,
    output wire O_ddr_ras_n,
    output wire O_ddr_cas_n,
    output wire O_ddr_we_n,
    output wire O_ddr_clk,
    output wire O_ddr_clk_n,
    output wire O_ddr_cke,
    output wire O_ddr_odt,
    output wire O_ddr_reset_n,
    output wire [1:0] O_ddr_dqm,
    inout wire [15:0] IO_ddr_dq,
    inout wire [1:0] IO_ddr_dqs,
    inout wire [1:0] IO_ddr_dqs_n
);
    logic [7:0] calibration_count;
    logic read_pending;
    logic [5:0] read_index;
    logic [127:0] fake_mem [0:63];
    integer fake_write_count = 0;
    integer fake_read_count = 0;
    logic [15:0] fake_last_mask;
    logic [27:0] fake_last_addr;
    integer byte_lane;
    integer init_index;

    assign clk_out = memory_clk;
    assign cmd_ready = init_calib_complete;
    assign wr_data_rdy = cmd_ready;
    assign rd_data_end = rd_data_valid;
    assign sr_ack = 1'b0;
    assign ref_ack = 1'b0;
    assign ddr_rst = 1'b0;
    assign O_ddr_addr = '0;
    assign O_ddr_ba = '0;
    assign O_ddr_cs_n = 1'b0;
    assign O_ddr_ras_n = 1'b1;
    assign O_ddr_cas_n = 1'b1;
    assign O_ddr_we_n = 1'b1;
    assign O_ddr_clk = memory_clk;
    assign O_ddr_clk_n = ~memory_clk;
    assign O_ddr_cke = 1'b1;
    assign O_ddr_odt = 1'b0;
    assign O_ddr_reset_n = rst_n;
    assign O_ddr_dqm = '0;
    assign IO_ddr_dq = 'z;
    assign IO_ddr_dqs = 'z;
    assign IO_ddr_dqs_n = 'z;

    initial begin
        for (init_index = 0; init_index < 64; init_index++)
            fake_mem[init_index] = '0;
    end

    always_ff @(posedge memory_clk or negedge rst_n) begin
        if (!rst_n) begin
            calibration_count <= '0;
            init_calib_complete <= 1'b0;
            read_pending <= 1'b0;
            read_index <= '0;
            rd_data <= '0;
            rd_data_valid <= 1'b0;
            fake_write_count <= 0;
            fake_read_count <= 0;
            fake_last_mask <= '0;
            fake_last_addr <= '0;
        end else if (!pll_lock) begin
            calibration_count <= '0;
            init_calib_complete <= 1'b0;
        end else begin
            if (!init_calib_complete) begin
                if (calibration_count == 8'd99)
                    init_calib_complete <= 1'b1;
                else
                    calibration_count <= calibration_count + 1'b1;
            end

            rd_data_valid <= 1'b0;
            if (read_pending) begin
                rd_data <= fake_mem[read_index];
                rd_data_valid <= 1'b1;
                read_pending <= 1'b0;
            end

            if (cmd_en && cmd_ready) begin
                fake_last_addr <= addr;
                if (cmd == 3'h0 && wr_data_en && wr_data_rdy) begin
                    fake_last_mask <= wr_data_mask;
                    fake_write_count <= fake_write_count + 1;
                    for (byte_lane = 0; byte_lane < 16; byte_lane++) begin
                        if (!wr_data_mask[byte_lane])
                            fake_mem[addr[8:3]][byte_lane*8 +: 8] <=
                                wr_data[byte_lane*8 +: 8];
                    end
                end else if (cmd == 3'h1) begin
                    read_index <= addr[8:3];
                    read_pending <= 1'b1;
                    fake_read_count <= fake_read_count + 1;
                end
            end
        end
    end
endmodule
