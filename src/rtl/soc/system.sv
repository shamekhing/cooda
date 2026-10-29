// ============================================================
// system  CPU + reusable multi-master bus arbitration + BSRAM
// ============================================================
module system #(
    parameter INIT_FILE = "src/programs/boot_program.hex"
) (
    input  logic clk,
    input  logic rst,
    input  logic run,
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

    assign gpu_req = '0;
    assign tpu_req = '0;

    cpu u_cpu (
        .clk(clk), .rst(rst), .run(run),
        .instr_req(instr_req), .instr_rsp(instr_rsp),
        .data_req(data_req), .data_rsp(data_rsp),
        .retire_valid(retire_valid),
        .illegal_instr(illegal_instr), .fault(cpu_fault)
    );

    // One arbiter per future shared target. Today the only target is
    // BSRAM; slots 2 and 3 reserve future GPU and TPU master traffic.
    bus_arbiter u_memory_arbiter (
        .clk(clk), .rst(rst),
        .req0(instr_req), .rsp0(instr_rsp),
        .req1(data_req), .rsp1(data_rsp),
        .req2(gpu_req), .rsp2(gpu_rsp),
        .req3(tpu_req), .rsp3(tpu_rsp),
        .target_req(target_req), .target_rsp(target_rsp)
    );

    memory #(.INIT_FILE(INIT_FILE)) u_memory (
        .clk(clk), .rst(rst), .req(target_req), .rsp(target_rsp)
    );
endmodule
