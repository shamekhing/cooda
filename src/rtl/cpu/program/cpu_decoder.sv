
// ============================================================
// cpu_decoder  instruction decode
//
// Decodes the existing ALU/control-flow instructions plus Stage-7
// OpLoad/OpStore without changing the instruction layout.
//
// Stage-7 memory formats:
//   OpLoad  rd, [rs1 + imm] : RD=destination, RS1=base, RS2=0,
//                            I=0, S=0, IMM=signed byte offset
//   OpStore rs2,[rs1 + imm] : RD=0, RS1=base, RS2=source,
//                            I=0, S=0, IMM=signed byte offset
//
// OpLoad/OpStore use OpAdd internally to calculate the effective byte
// address. OpStore still reads RS2 through the register file's second
// read port; cpu_datapath exposes that raw value separately as store_data.
// ============================================================

module cpu_decoder (
    input  isa_pkg::instruction_t instruction,
    input  arch_pkg::word_t immediate_word,

    output arch_pkg::reg_addr_t rs1,
    output arch_pkg::reg_addr_t rs2,
    output arch_pkg::reg_addr_t rd,

    output isa_pkg::opcode_t op,
    output arch_pkg::word_t imm_operand,
    output logic imm_sel,

    output logic register_write_enable,
    output logic flags_write_enable,

    // Stage 6 control-flow outputs.
    output logic branch_enable,
    output isa_pkg::opcode_t branch_op,
    output arch_pkg::word_t branch_target,

    // Stage 7 memory controls.
    output logic memory_read_enable,
    output logic memory_write_enable,

    output logic decode_valid,
    output logic illegal_instr
);

    import arch_pkg::*;
    import isa_pkg::*;

    instruction_s instr_fields;

    logic opcode_valid;
    logic format_valid;
    logic unary_qual;
    logic mov_qual;
    logic movi_qual;
    logic branch_qual;
    logic memory_qual;
    logic load_qual;
    logic store_qual;

    // ------------------------------------------------------------
    // Packed struct overlay: no hardcoded instruction bit slicing here.
    // Opcode classification is provided by the isa_pkg helpers.
    // ------------------------------------------------------------
    // The packed decode view excludes the six reserved high bits; those are
    // checked separately below before the instruction is accepted.
    assign instr_fields = instruction_s'(instruction);

    // ------------------------------------------------------------
    // Validate opcode and operand format.
    // ------------------------------------------------------------
    always_comb begin
        branch_qual       = isa_pkg::isa_is_program_branch(instr_fields.opcode);
        memory_qual       = isa_pkg::isa_is_memory(instr_fields.opcode);
        opcode_valid      = isa_pkg::isa_is_valid(instr_fields.opcode);
        unary_qual        = isa_pkg::isa_is_unary(instr_fields.opcode);
        mov_qual          = isa_pkg::isa_is_mov(instr_fields.opcode);
        movi_qual         = isa_pkg::isa_is_movi(instr_fields.opcode);

        load_qual         = (instr_fields.opcode == OpLoad);
        store_qual        = (instr_fields.opcode == OpStore);
        format_valid      = opcode_valid;

        // Every currently defined instruction requires reserved bits 0.
        if (instruction[31:INSTRUCTION_BITS] != '0)
            format_valid = 1'b0;

        // Non-power-of-two register counts leave unused address encodings.
        if (instr_fields.rd >= REG_FILE_COUNT || instr_fields.rs1 >= REG_FILE_COUNT || instr_fields.rs2 >= REG_FILE_COUNT)
            format_valid = 1'b0;

        if (branch_qual) begin
            // Branches/jumps never write a destination register and do not
            // use the normal ALU imm_operand/status mode bits.
            if (instr_fields.rd != ZERO_REG)
                format_valid = 1'b0;
            if (instr_fields.immediate_mode)
                format_valid = 1'b0;
            if (instr_fields.update_status)
                format_valid = 1'b0;

            // OpJmp consumes no register operands. Conditional branches do.
            if (instr_fields.opcode == OpJmp) begin
                if (instr_fields.rs1 != ZERO_REG)
                    format_valid = 1'b0;
                if (instr_fields.rs2 != ZERO_REG)
                    format_valid = 1'b0;
            end

        end else if (memory_qual) begin
            // OpLoad/OpStore always use their encoded IMM32 as a signed byte
            // offset, so the normal ALU imm_operand/status bits stay zero.
            if (instr_fields.immediate_mode)
                format_valid = 1'b0;
            if (instr_fields.update_status)
                format_valid = 1'b0;

            if (load_qual) begin
                // OpLoad uses RD as destination and RS1 as base. RS2 is unused.
                if (instr_fields.rs2 != ZERO_REG)
                    format_valid = 1'b0;
            end else if (store_qual) begin
                // OpStore uses RS1 as base and RS2 as source. RD is unused.
                if (instr_fields.rd != ZERO_REG)
                    format_valid = 1'b0;
            end

        end else begin
            // MOV and MOVI preserve status.
            if ((mov_qual || movi_qual) && instr_fields.update_status)
                format_valid = 1'b0;

            if (mov_qual || unary_qual) begin
                // Operand A = RS1. Operand B and the imm_operand are unused.
                if (instr_fields.immediate_mode)
                    format_valid = 1'b0;
                if (instr_fields.rs2 != ZERO_REG)
                    format_valid = 1'b0;

            end else if (movi_qual) begin
                // Operand B = the imm_operand word that followed. Sources are unused.
                if (!instr_fields.immediate_mode)
                    format_valid = 1'b0;
                if (instr_fields.rs1 != ZERO_REG)
                    format_valid = 1'b0;
                if (instr_fields.rs2 != ZERO_REG)
                    format_valid = 1'b0;

            end else begin
                // Binary ALU op.
                if (instr_fields.immediate_mode) begin
                    // Immediate word replaces RS2.
                    if (instr_fields.rs2 != ZERO_REG)
                        format_valid = 1'b0;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // Generate cpu_datapath/control-flow/memory controls.
    // ------------------------------------------------------------
    always_comb begin
        // Safe defaults used for every illegal instruction.
        rs1 = ZERO_REG;
        rs2 = ZERO_REG;
        rd  = ZERO_REG;

        op        = OpAdd;
        imm_operand     = '0;
        imm_sel = 1'b0;

        register_write_enable = 1'b0;
        flags_write_enable    = 1'b0;

        branch_enable    = 1'b0;
        branch_op    = OpJmp;
        branch_target    = '0;

        memory_read_enable = 1'b0;
        memory_write_enable= 1'b0;

        decode_valid   = 1'b0;
        illegal_instr = 1'b1;

        if (format_valid) begin
            if (branch_qual) begin
                // Source addresses feed the existing register file, so the
                // cpu_branch receives the actual register values through
                // cpu_datapath operand_a/operand_b.
                rs1 = instr_fields.rs1;
                rs2 = instr_fields.rs2;

                branch_enable = 1'b1;
                branch_target = immediate_word;

                branch_op = instr_fields.opcode;

            end else if (memory_qual) begin
                // The existing ALU calculates base + signed byte offset.
                rs1 = instr_fields.rs1;
                rs2 = instr_fields.rs2;
                rd  = instr_fields.rd;

                op        = OpAdd;
                imm_operand     = immediate_word;
                imm_sel = 1'b1;

                if (load_qual) begin
                    memory_read_enable   = 1'b1;
                    register_write_enable = 1'b1;
                end else begin
                    memory_write_enable= 1'b1;
                end

                // Memory instructions do not update status flags.
                flags_write_enable = 1'b0;

            end else begin
                // Original ALU path is unchanged.
                rs1 = instr_fields.rs1;
                rs2 = instr_fields.rs2;
                rd  = instr_fields.rd;

                op = opcode_t'(instr_fields.opcode);
                imm_operand = immediate_word;
                imm_sel = instr_fields.immediate_mode;

                register_write_enable = 1'b1;
                flags_write_enable = instr_fields.update_status;
            end

            decode_valid   = 1'b1;
            illegal_instr = 1'b0;
        end
    end

endmodule
