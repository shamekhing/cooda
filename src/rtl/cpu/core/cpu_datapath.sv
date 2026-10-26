// ============================================================
// cpu_datapath  execution datapath
//
// Wires cpu_register_file, the operand-B multiplexer, cpu_alu, the
// LOAD writeback multiplexer and cpu_status_register together. Every
// word is the global word (arch_pkg::WORD_WIDTH).
//
// Normal ALU instruction:
//   register(s) -> cpu_alu -> register writeback
//
// LOAD:
//   RS1 + imm_operand word   -> effective address
//   dmem_rdata       -> RD writeback
//
// STORE:
//   RS1 + imm_operand word   -> effective address
//   raw RS2 value          -> store_data
//
// The raw second register-file output is kept separate from operand_b
// because STORE needs RS2 as write data while the ALU simultaneously
// needs the imm_operand as operand B.
// ============================================================

module cpu_datapath (
    input logic clk,
    input logic rst,

    // Register addresses
    input arch_pkg::reg_addr_t rs1,
    input arch_pkg::reg_addr_t rs2,
    input arch_pkg::reg_addr_t rd,

    // ALU control
    input isa_pkg::opcode_t op,
    input logic carry_in,
    input logic alu_start,
    input logic capture_operands,
    input logic use_captured_operands,

    // Immediate operand (the word that followed the instruction)
    input arch_pkg::word_t imm_operand,
    input logic imm_sel,

    // Write controls
    input logic register_write_enable,
    input logic flags_write_enable,

    // LOAD writeback input/control
    input arch_pkg::word_t dmem_rdata,
    input logic writeback_from_mem,

    // cpu_datapath outputs
    output arch_pkg::word_t operand_a,
    output arch_pkg::word_t operand_b,
    output arch_pkg::word_t store_data,
    output arch_pkg::word_t alu_result,
    output logic alu_done,
    output logic carry_flag
);
    arch_pkg::word_t rs2_data;
    arch_pkg::word_t rs1_data;
    arch_pkg::word_t operand_a_q,  operand_a_d;
    arch_pkg::word_t operand_b_q,  operand_b_d;
    arch_pkg::word_t store_data_q, store_data_d;
    arch_pkg::word_t writeback_data;

    logic register_wen;
    logic flags_wen;
    logic alu_valid;
    logic alu_busy;
    arch_pkg::flags_s alu_flags;
    arch_pkg::flags_s flags_q;
    assign carry_flag = flags_q.C;

    // =========================================================
    // WRITE ENABLE CONTROL
    // =========================================================
    // The core asserts these for exactly the cycle on which an
    // instruction completes, so the multi-cycle ALU cannot disturb
    // the register file until its result is final. An unrecognised
    // encoding (alu_valid low) can never write.
    assign register_wen =
        register_write_enable && alu_valid && !rst;

    assign flags_wen =
        flags_write_enable && alu_valid && !rst;

    // =========================================================
    // REGISTER FILE
    // =========================================================

    cpu_register_file u_cpu_register_file (
        .clk(clk),
        .rst(rst),

        .rs1_addr(rs1),
        .rs1_data(rs1_data),

        .rs2_addr(rs2),
        .rs2_data(rs2_data),

        .write_enable(register_wen),
        .write_addr(rd),
        .write_data(writeback_data)
    );

    // =========================================================
    // OPERAND MULTIPLEXERS
    // =========================================================
    // STORE always needs the unmodified value read from RS2.
    assign store_data = use_captured_operands ? store_data_q : rs2_data;

    assign operand_a = use_captured_operands ? operand_a_q : rs1_data;

    assign operand_b = use_captured_operands ? operand_b_q :
        (imm_sel ? imm_operand : rs2_data);

    // =========================================================
    // CAPTURED OPERANDS
    // =========================================================

    always_comb begin
        operand_a_d  = operand_a_q;
        operand_b_d  = operand_b_q;
        store_data_d = store_data_q;

        if (capture_operands) begin
            operand_a_d  = rs1_data;
            operand_b_d  = imm_sel ? imm_operand : rs2_data;
            store_data_d = rs2_data;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            operand_a_q  <= '0;
            operand_b_q  <= '0;
            store_data_q <= '0;
        end else begin
            operand_a_q  <= operand_a_d;
            operand_b_q  <= operand_b_d;
            store_data_q <= store_data_d;
        end
    end

    // =========================================================
    // ALU
    // =========================================================

    cpu_alu u_cpu_alu (
        .clk(clk),
        .rst(rst),

        .start(alu_start),

        .operand_a(operand_a),
        .operand_b(operand_b),

        .op(op),
        .carry_in(carry_in),

        .result(alu_result),
        .flags(alu_flags),
        .valid(alu_valid),
        .busy(alu_busy),
        .done(alu_done)
    );

    // =========================================================
    // WRITEBACK MULTIPLEXER
    // =========================================================
    // Normal ALU instructions write the ALU alu_result. LOAD writes the
    // combinational data-memory read value instead. The effective
    // address remains visible on alu_result for LOAD/STORE.
    assign writeback_data =
        writeback_from_mem ? dmem_rdata : alu_result;

    // =========================================================
    // STATUS REGISTER
    // =========================================================

    cpu_status_register u_cpu_status_register (
        .clk(clk),
        .rst(rst),

        .flags_write_enable(flags_wen),
        .flags_in(alu_flags),
        .flags(flags_q)
    );

endmodule
