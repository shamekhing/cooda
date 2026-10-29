
// ============================================================
// LACOODA cpu_program  instruction unit
// ============================================================
//
// Owns everything that turns the program counter into a decoded
// instruction:
//
//   cpu_fetch     cpu_pc, fetch state machine, read-only
//                 instruction bus master, instruction buffer,
//                 bus-error latch
//   cpu_decoder   decode of the buffered instruction
//   cpu_branch    control-flow resolution -> PC redirect
//
// The loop fetch -> decode -> branch -> pc is closed inside this
// module. The execution core only sees one decoded instruction
// (isa_pkg::program_ctrl_s) and reports completion with `retire`.
//
// cpu_branch operands arrive from cpu_datapath, so a taken branch is
// decided on the same operand values the ALU sees.
//
// fault is sticky: an instruction-bus error or an illegal
// instruction stops the unit until reset. valid is the single
// "this decoded instruction may execute" indication.
// ============================================================

module cpu_program (
    input  logic        clk,
    input  logic        rst,
    input  logic        run,

    input  logic            retire,
    input  arch_pkg::word_t operand_a,
    input  arch_pkg::word_t operand_b,

    input  soc_pkg::bus_rsp_s instr_rsp,
    output soc_pkg::bus_req_s instr_req,

    output isa_pkg::program_ctrl_s ctrl,
    output logic        valid,
    output logic        illegal_instr,
    output logic        fault
);

    // ========================================================
    // INTERNAL SIGNALS
    // ========================================================

    // Buffered instruction, from cpu_fetch to cpu_decoder.
    isa_pkg::instruction_t instruction;
    arch_pkg::word_t       immediate_word;
    logic                  instruction_available;
    logic                  fetch_fault;

    // cpu_decoder outputs. The branch controls stay inside the unit
    // (cpu_decoder -> cpu_branch); the rest is gathered into ctrl.
    arch_pkg::reg_addr_t rs1;
    arch_pkg::reg_addr_t rs2;
    arch_pkg::reg_addr_t rd;

    isa_pkg::opcode_t op;
    arch_pkg::word_t  imm_operand;
    logic             imm_sel;

    logic register_write_enable;
    logic flags_write_enable;

    logic memory_read_enable;
    logic memory_write_enable;

    logic decode_valid;
    logic decode_illegal;

    logic             branch_enable;
    isa_pkg::opcode_t branch_op;
    arch_pkg::word_t  branch_target;

    // cpu_branch -> cpu_pc.
    logic            redirect;
    arch_pkg::word_t redirect_target;

    // ========================================================
    // VALID / ILLEGAL / FAULT
    // ========================================================
    // valid means "an instruction is buffered, decodes and may
    // execute". An illegal encoding leaves decode_valid low, so it
    // is never valid, and the latch below stops the unit.
    // --------------------------------------------------------

    logic fault_q, fault_d;

    assign fault = fault_q;

    assign valid =
        instruction_available && decode_valid && !fault_q;

    // An instruction is buffered but its encoding is unusable.
    assign illegal_instr =
        instruction_available && decode_illegal;

    always_comb begin
        fault_d = fault_q;

        if (fetch_fault || (instruction_available && decode_illegal))
            fault_d = 1'b1;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) fault_q <= 1'b0;
        else     fault_q <= fault_d;
    end

    // ========================================================
    // INSTRUCTION FETCH (owns cpu_pc)
    // ========================================================
    // run is qualified here, so the core only has to ask for a
    // running instruction unit rather than re-derive the fault gate.
    // --------------------------------------------------------

    cpu_fetch u_cpu_fetch (

        .clk                   (clk),
        .rst                   (rst),
        .run                   (run && !fault_q),

        .retire                (retire),
        .redirect              (redirect),
        .redirect_target       (redirect_target),

        .instr_req             (instr_req),
        .instr_rsp             (instr_rsp),

        .instruction           (instruction),
        .immediate_word        (immediate_word),
        .instruction_available (instruction_available),
        .fault                 (fetch_fault)

    );

    // ========================================================
    // DECODE
    // ========================================================

    cpu_decoder u_cpu_decoder (

        .instruction           (instruction),
        .immediate_word        (immediate_word),

        .rs1                   (rs1),
        .rs2                   (rs2),
        .rd                    (rd),

        .op                    (op),
        .imm_operand           (imm_operand),
        .imm_sel               (imm_sel),

        .register_write_enable (register_write_enable),
        .flags_write_enable    (flags_write_enable),

        .branch_enable         (branch_enable),
        .branch_op             (branch_op),
        .branch_target         (branch_target),

        .memory_read_enable            (memory_read_enable),
        .memory_write_enable            (memory_write_enable),

        .decode_valid          (decode_valid),
        .illegal_instr         (decode_illegal)

    );

    // ========================================================
    // DECODED-INSTRUCTION BUNDLE
    // ========================================================

    assign ctrl.rs1                   = rs1;
    assign ctrl.rs2                   = rs2;
    assign ctrl.rd                    = rd;

    assign ctrl.op                    = op;
    assign ctrl.imm_operand           = imm_operand;
    assign ctrl.imm_sel               = imm_sel;

    assign ctrl.register_write_enable = register_write_enable;
    assign ctrl.flags_write_enable    = flags_write_enable;

    assign ctrl.memory_read_enable            = memory_read_enable;
    assign ctrl.memory_write_enable            = memory_write_enable;

    assign ctrl.decode_valid          = decode_valid;

    // ========================================================
    // BRANCH RESOLUTION -> PROGRAM COUNTER REDIRECT
    // ========================================================
    // Gated by valid, so an illegal instruction, a fetch fault or
    // an empty buffer can never steer cpu_pc.
    // --------------------------------------------------------

    cpu_branch u_cpu_branch (

        .enable          (valid && branch_enable && !rst),
        .opcode          (branch_op),
        .operand_a       (operand_a),
        .operand_b       (operand_b),
        .target          (branch_target),

        .redirect        (redirect),
        .redirect_target (redirect_target)

    );

endmodule
