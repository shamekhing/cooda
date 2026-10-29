// ============================================================
// system  CPU + shared bus arbitration + BSRAM and DDR3
// ============================================================
module system #(
    parameter INIT_FILE = "src/programs/boot_program.hex",
    parameter bit DDR3_ENABLE = 1'b0
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
    output logic cpu_fault
);
    soc_pkg::bus_req_s instr_req, data_req;
    soc_pkg::bus_rsp_s instr_rsp, data_rsp;
    soc_pkg::bus_req_s gpu_req, tpu_req;
    soc_pkg::bus_rsp_s gpu_rsp, tpu_rsp;
    soc_pkg::bus_req_s target_req;
    soc_pkg::bus_rsp_s target_rsp;
    soc_pkg::bus_req_s ddr_req;
    soc_pkg::bus_rsp_s ddr_rsp;

    logic ctl_rd, ctl_wr, ctl_refresh;
    logic [25:0] ctl_addr;
    logic [15:0] ctl_din, ctl_dout;
    logic ctl_busy, ctl_data_ready;
    logic write_level_done, read_calib_done;
    logic [7:0] wstep;
    logic [1:0] rclkpos;
    logic [2:0] rclksel;
    logic [63:0] ddr_debug;

    assign gpu_req = '0;
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
                .target_rsp(ddr_rsp),
                .clk_ddr(ddr_pclk), .rst_ddr(ddr_rst),
                .ctl_rd(ctl_rd), .ctl_wr(ctl_wr), .ctl_refresh(ctl_refresh),
                .ctl_addr(ctl_addr), .ctl_din(ctl_din), .ctl_dout(ctl_dout),
                .ctl_busy(ctl_busy), .ctl_data_ready(ctl_data_ready),
                .ctl_ready(write_level_done && read_calib_done)
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
            always_comb begin
                ddr_rsp = '0;
                ddr_rsp.ready = ddr_req.valid;
                ddr_rsp.error = ddr_req.valid;
            end
            assign {DDR3_A, DDR3_BA, DDR3_nRAS, DDR3_nCAS, DDR3_nWE,
                    DDR3_CK, DDR3_CKE, DDR3_nRESET, DDR3_DM, DDR3_ODT} = '0;
            assign DDR3_DQ  = 'z;
            assign DDR3_DQS = 'z;
        end
    endgenerate
endmodule
