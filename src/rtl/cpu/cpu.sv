// ============================================================
// cpu  instruction unit + execution core with internal fetch/data ports
//
//   instr_* : instruction fetch request
//   data_*  : data / MMIO request
//
// cpu_program owns the program counter, the fetch state machine, the
// decoder and branch resolution. It hands the execution core one
// decoded instruction (isa_pkg::program_ctrl_s) and the core reports
// completion back with `retire`.
//
// A bus error on either bus, or an illegal instruction, latches
// `fault` and halts execution until reset. This is a stop
// indication, not a vectored exception. cpu_program latches its own
// fetch/illegal fault; a failed data transaction is latched here.
//
// A buffered instruction may finish even if run falls, so an
// active data request is never abandoned before its response.
// ============================================================

module cpu (
    input  logic clk,
    input  logic rst,
    input  logic run,

    input  soc_pkg::bus_rsp_s instr_rsp,
    output soc_pkg::bus_req_s instr_req,

    input  soc_pkg::bus_rsp_s data_rsp,
    output soc_pkg::bus_req_s data_req,

    output logic retire_valid,
    output logic illegal_instr,
    output logic fault
);

    // ========================================================
    // SIGNALS
    // ========================================================

    isa_pkg::program_ctrl_s ctrl;
    logic                   program_valid;
    logic                   program_fault;

    arch_pkg::word_t operand_a;
    arch_pkg::word_t operand_b;

    logic            carry_flag;
    logic            core_enable;
    logic            retire;
    logic            data_fault_q, data_fault_d;

    // ========================================================
    // DATA-BUS FAULT LATCH
    // ========================================================

    assign fault = program_fault | data_fault_q;

    always_comb begin
        data_fault_d = data_fault_q;

        if (data_req.valid && data_rsp.ready && data_rsp.error)
            data_fault_d = 1'b1;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) data_fault_q <= 1'b0;
        else     data_fault_q <= data_fault_d;
    end

    // ========================================================
    // EXECUTION CONTROL
    // ========================================================

    assign core_enable = program_valid && !rst && !fault;
    assign retire      = core_enable && retire_valid;

    // ========================================================
    // INSTRUCTION UNIT (pc + fetch + decode + branch)
    // ========================================================
    // run is qualified with the whole-CPU fault, so a data-bus fault
    // also stops the instruction unit.
    // --------------------------------------------------------

    cpu_program u_cpu_program (
        .clk           (clk),
        .rst           (rst),
        .run           (run && !fault),

        .instr_req     (instr_req),
        .instr_rsp     (instr_rsp),

        .retire        (retire),
        .operand_a     (operand_a),
        .operand_b     (operand_b),

        .ctrl          (ctrl),
        .valid         (program_valid),
        .illegal_instr (illegal_instr),
        .fault         (program_fault)
    );

    // ========================================================
    // EXECUTION CORE
    // ========================================================
    //
    // A failed data transaction completes the bus handshake but
    // cannot retire or write back; the latch above stops the CPU.
    // ========================================================

    cpu_core u_cpu_core (
        .clk          (clk),
        .rst          (rst),

        .core_enable  (core_enable),
        .ctrl         (ctrl),

        .carry_in     (carry_flag),
        .carry_flag   (carry_flag),

        .cpu_req      (data_req),
        .cpu_rsp      (data_rsp),

        .operand_a    (operand_a),
        .operand_b    (operand_b),

        .retire_valid (retire_valid)
    );

endmodule
