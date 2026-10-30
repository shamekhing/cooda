// ============================================================
// system  CPU + shared bus arbitration + BSRAM and DDR3
// ============================================================
module system #(
    parameter INIT_FILE = "src/programs/boot_program.hex",
    parameter bit DDR3_ENABLE = 1'b0,
    parameter bit SD_ENABLE   = 1'b0
) (
    input  logic clk,
    input  logic rst,
    input  logic run,

    // DDR3 clocks/reset come from the board wrapper.
    input  logic ddr_pclk,
    input  logic ddr_fclk,
    input  logic ddr_ck,
    input  logic ddr_rst,
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS,
    output wire [12:0] DDR3_A,
    output wire [2:0]  DDR3_BA,
    output wire        DDR3_nRAS,
    output wire        DDR3_nCAS,
    output wire        DDR3_nWE,
    output wire        DDR3_CK,
    output wire        DDR3_CKE,
    output wire        DDR3_nRESET,
    output wire [1:0]  DDR3_DM,
    output wire        DDR3_ODT,

    output logic retire_valid,
    output logic illegal_instr,
    output logic cpu_fault,

    // DDR3 bring-up status for the board LEDs. All three are low when
    // DDR3_ENABLE is 0.
    output logic ddr_write_level_done,
    output logic ddr_read_calib_done,
    output logic ddr_err,

    // microSD card pins. Idle when SD_ENABLE is 0.
    output logic sd_cs_n,
    output logic sd_sck,
    output logic sd_mosi,
    input  logic sd_miso,

    // microSD bring-up status for the board LEDs. All low when
    // SD_ENABLE is 0.
    output logic        sd_ready,
    output logic [1:0]  sd_card_type,
    output logic        sd_error,
    output logic [3:0]  sd_err_code,
    output logic        load_done,
    output logic        load_error,
    output logic [3:0]  load_err_code
);
    soc_pkg::bus_req_s instr_req, data_req;
    soc_pkg::bus_rsp_s instr_rsp, data_rsp;
    soc_pkg::bus_req_s gpu_req, tpu_req;
    soc_pkg::bus_rsp_s gpu_rsp, tpu_rsp;
    soc_pkg::bus_req_s target_req;
    soc_pkg::bus_rsp_s target_rsp;
    soc_pkg::bus_req_s ddr_req;
    wire soc_pkg::bus_rsp_s ddr_rsp;
    soc_pkg::bus_rsp_s ddr_target_rsp;

    logic ctl_rd, ctl_wr, ctl_refresh;
    logic [25:0] ctl_addr;
    logic [15:0] ctl_din, ctl_dout;
    logic ctl_busy, ctl_data_ready;
    logic write_level_done, read_calib_done;
    logic [7:0] wstep;
    logic [1:0] rclkpos;
    logic [2:0] rclksel;
    logic [63:0] ddr_debug;

    // The microSD loader is a boot-time bus master. It takes arbiter
    // slot 2 (the GPU slot, still unused) and leaves slot 3 free for
    // the TPU. It runs once after reset and then holds its request
    // low, so a later GPU block can share the slot with a valid gate.
    generate
        if (SD_ENABLE) begin : gen_sd
            soc_pkg::bus_req_s sd_req;
            logic [4:0] sd_ctrl_state;
            logic [31:0] sd_blocks_loaded, sd_bytes_loaded;

            memory_sd u_memory_sd (
                .clk(clk), .rst(rst),
                .sd_cs_n(sd_cs_n), .sd_sck(sd_sck),
                .sd_mosi(sd_mosi), .sd_miso(sd_miso),
                .bus_req(sd_req), .bus_rsp(gpu_rsp),
                .sd_ready(sd_ready), .card_type(sd_card_type),
                .sd_error(sd_error), .sd_err_code(sd_err_code),
                .ctrl_state(sd_ctrl_state),
                .load_done(load_done), .load_error(load_error),
                .load_err_code(load_err_code),
                .blocks_loaded(sd_blocks_loaded),
                .bytes_loaded(sd_bytes_loaded)
            );

            assign gpu_req = sd_req;
        end else begin : gen_no_sd
            assign gpu_req = '0;
            assign sd_cs_n    = 1'b1;
            assign sd_sck     = 1'b0;
            assign sd_mosi    = 1'b1;
            assign sd_ready   = 1'b0;
            assign sd_card_type = 2'd0;
            assign sd_error   = 1'b0;
            assign sd_err_code = 4'd0;
            assign load_done  = 1'b0;
            assign load_error = 1'b0;
            assign load_err_code = 4'd0;
        end
    endgenerate
    assign tpu_req = '0;

    cpu u_cpu (
        .clk(clk), .rst(rst), .run(run),
        .instr_req(instr_req), .instr_rsp(instr_rsp),
        .data_req(data_req), .data_rsp(data_rsp),
        .retire_valid(retire_valid),
        .illegal_instr(illegal_instr), .fault(cpu_fault)
    );

    // BSRAM remains the initialized, low-latency boot memory. The
    // DDR3 window is decoded above it at 0x0800_0000..0x0fff_ffff.
    // Both targets share the CPU bus grant, so only one target sees a
    // request at a time.
    bus_arbiter u_memory_arbiter (
        .clk(clk), .rst(rst),
        .req0(instr_req), .rsp0(instr_rsp),
        .req1(data_req), .rsp1(data_rsp),
        .req2(gpu_req), .rsp2(gpu_rsp),
        .req3(tpu_req), .rsp3(tpu_rsp),
        .target_req(target_req), .target_rsp(target_rsp)
    );

    memory #(.INIT_FILE(INIT_FILE)) u_memory (
        .clk(clk), .rst(rst), .target_req(target_req),
        .target_rsp(target_rsp),
        .ddr_req(ddr_req), .ddr_rsp(ddr_rsp)
    );

    generate
        if (DDR3_ENABLE) begin : gen_ddr3
            memory_ddr3 u_ddr3_memory (
                .clk(clk), .rst(rst), .target_req(ddr_req),
                .target_rsp(ddr_target_rsp),
                .clk_ddr(ddr_pclk), .rst_ddr(ddr_rst),
                .ctl_rd(ctl_rd), .ctl_wr(ctl_wr), .ctl_refresh(ctl_refresh),
                .ctl_addr(ctl_addr), .ctl_din(ctl_din), .ctl_dout(ctl_dout),
                .ctl_busy(ctl_busy), .ctl_data_ready(ctl_data_ready),
                .ctl_ready(write_level_done && read_calib_done),
                .err_sticky(ddr_err)
            );

            ddr3_controller u_ddr3_controller (
                .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS),
                .DDR3_A(DDR3_A), .DDR3_BA(DDR3_BA),
                .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS),
                .DDR3_nWE(DDR3_nWE), .DDR3_nCS(), .DDR3_CK(DDR3_CK),
                .DDR3_CKE(DDR3_CKE), .DDR3_nRESET(DDR3_nRESET),
                .DDR3_DM(DDR3_DM), .DDR3_ODT(DDR3_ODT),
                .pclk(ddr_pclk), .fclk(ddr_fclk), .ck(ddr_ck),
                .resetn(!ddr_rst), .rd(ctl_rd), .wr(ctl_wr),
                .refresh(ctl_refresh), .addr(ctl_addr), .din(ctl_din),
                .dout(ctl_dout), .dout128(), .data_ready(ctl_data_ready),
                .busy(ctl_busy), .write_level_done(write_level_done),
                .wstep(wstep), .read_calib_done(read_calib_done),
                .rclkpos(rclkpos), .rclksel(rclksel), .debug(ddr_debug)
            );
        end else begin : gen_no_ddr3
            assign ddr_rsp = {ddr_req.valid, arch_pkg::word_t'(0), ddr_req.valid};
            assign {DDR3_A, DDR3_BA, DDR3_nRAS, DDR3_nCAS, DDR3_nWE,
                    DDR3_CK, DDR3_CKE, DDR3_nRESET, DDR3_DM, DDR3_ODT} = '0;
            assign DDR3_DQ  = 'z;
            assign DDR3_DQS = 'z;
            assign write_level_done = 1'b0;
            assign read_calib_done  = 1'b0;
            assign ddr_err          = 1'b0;
        end
        if (DDR3_ENABLE) begin : gen_ddr3_response
            assign ddr_rsp = ddr_target_rsp;
        end
    endgenerate

    assign ddr_write_level_done = write_level_done;
    assign ddr_read_calib_done  = read_calib_done;
endmodule
