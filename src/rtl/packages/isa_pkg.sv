`ifndef ISA_PKG_SV
`define ISA_PKG_SV

// ============================================================
// isa_pkg  instruction set: opcodes + instruction format
//
// Depends on: arch_pkg
//
// Opcode map:
//   Arithmetic, logical, movement, shifts, comparisons: 0x00..0x27
//   Control flow:                                      0x28..0x2E
//   Memory:                                            0x2F..0x30
//
// Instruction format (struct below is the single source of
// truth; MSB first):
//
//     [26]     update_status
//     [25]     immediate_mode
//     [24:19]  opcode
//     [18:13]  rd
//     [12:7]   rs1
//     [6:1]    rs2
//
// Note: The instruction struct is 26 bits wide. When cast to
// a wider word_t, it is zero-extended.
//
// Immediates are OpNot packed. An instruction that needs one is
// followed by one complete word holding it (see isa_has_imm).
// ============================================================

package isa_pkg;

    import arch_pkg::word_t;
    import arch_pkg::reg_addr_t;
    import arch_pkg::ZERO_REG;

    // ---------------- Opcodes ----------------

    localparam int OPCODE_WIDTH = 6;

    typedef enum logic [OPCODE_WIDTH-1:0] {

        // ----------------------------------------------------
        // Arithmetic
        // ----------------------------------------------------

        OpAdd             = 'h00,
        OpAdc             = 'h01,
        OpSub             = 'h02,
        OpSbc             = 'h03,
        OpMul             = 'h04,
        OpMulh            = 'h05,
        OpDivu            = 'h06,
        OpModu            = 'h07,
        OpDivs            = 'h08,
        OpMods            = 'h09,
        OpMinu            = 'h0A,
        OpMaxu            = 'h0B,
        OpMins            = 'h0C,
        OpMaxs            = 'h0D,
        OpAbs             = 'h0E,
        OpNeg             = 'h0F,

        // ----------------------------------------------------
        // Logical operations
        // ----------------------------------------------------

        OpNot             = 'h10,
        OpAnd             = 'h11,
        OpOr              = 'h12,
        OpXor             = 'h13,
        OpNand            = 'h14,
        OpNor             = 'h15,
        OpXnor            = 'h16,

        // ----------------------------------------------------
        // Data movement
        // ----------------------------------------------------

        OpPassA          = 'h17,
        OpPassB          = 'h18,

        // ----------------------------------------------------
        // Shifts and rotates
        // ----------------------------------------------------

        OpShl             = 'h19,
        OpShr             = 'h1A,
        OpSar             = 'h1B,
        OpRol             = 'h1C,
        OpRor             = 'h1D,

        // ----------------------------------------------------
        // Comparisons
        // ----------------------------------------------------

        OpEq              = 'h1E,
        OpNe              = 'h1F,
        OpLtu             = 'h20,
        OpLeu             = 'h21,
        OpGtu             = 'h22,
        OpGeu             = 'h23,
        OpLts             = 'h24,
        OpLes             = 'h25,
        OpGts             = 'h26,
        OpGes             = 'h27,

        // ----------------------------------------------------
        // Control flow
        // ----------------------------------------------------

        OpJmp             = 'h28,
        OpBeq             = 'h29,
        OpBne             = 'h2A,
        OpBlt             = 'h2B,
        OpBge             = 'h2C,
        OpBltu            = 'h2D,
        OpBgeu            = 'h2E,

        // ----------------------------------------------------
        // Memory
        // ----------------------------------------------------

        OpLoad            = 'h2F,
        OpStore           = 'h30

    } opcode_e;

    typedef logic [OPCODE_WIDTH-1:0] opcode_t;

    localparam int OPCODE_MAX       = int'(OpStore);
    localparam int ALU_OPCODE_COUNT = int'(OpGes) + 1;

    // ---------------- Classification ----------------
    // Take raw opcode bits so call sites stay cast-free.

    function automatic logic isa_is_valid(input opcode_t op);
        return (op <= OpStore);
    endfunction

    function automatic logic isa_is_alu(input opcode_t op);
        return (op <= OpGes);
    endfunction

    function automatic logic isa_is_unary(input opcode_t op);
        return (op == OpNeg || op == OpAbs || op == OpNot);
    endfunction

    function automatic logic isa_is_mov(input opcode_t op);
        return (op == OpPassA);
    endfunction

    function automatic logic isa_is_movi(input opcode_t op);
        return (op == OpPassB);
    endfunction

    function automatic logic isa_is_program_branch(input opcode_t op);
        return (op >= OpJmp && op <= OpBgeu);
    endfunction

    function automatic logic isa_is_memory(input opcode_t op);
        return (op >= OpLoad && op <= OpStore);
    endfunction

    // ---------------- Instruction ----------------

    typedef word_t instruction_t;

    typedef struct packed {
        logic      update_status;
        logic      immediate_mode;
        opcode_t   opcode;
        reg_addr_t rd;
        reg_addr_t rs1;
        reg_addr_t rs2;
    } instruction_s;

    // Low bits that carry meaning; the rest must be zero.
    localparam int INSTRUCTION_BITS = $bits(instruction_s);

    // An immediate word follows program_branches/jumps, OpLoad/OpStore and
    // any instruction in immediate mode.
    function automatic logic isa_has_imm(
        input opcode_t opcode,
        input logic    immediate_mode
    );
        return isa_is_program_branch(opcode) || isa_is_memory(opcode) || immediate_mode;
    endfunction

    function automatic logic isa_has_imm_word(input instruction_t instruction);
        instruction_s f;
        f = instruction_s'(instruction);
        return isa_has_imm(f.opcode, f.immediate_mode);
    endfunction

    // ---------------- Encoders ----------------

    function automatic instruction_t isa_encode(
        input opcode_t   opcode,
        input reg_addr_t rd,
        input reg_addr_t rs1,
        input reg_addr_t rs2,
        input logic      immediate_mode,
        input logic      update_status
    );
        instruction_s f;
        f                = '0;
        f.opcode         = opcode;
        f.rd             = rd;
        f.rs1            = rs1;
        f.rs2            = rs2;
        f.immediate_mode = immediate_mode;
        f.update_status  = update_status;
        return instruction_t'(f);
    endfunction

    function automatic instruction_t isa_encode_program_branch(
        input opcode_t   opcode,
        input reg_addr_t rs1,
        input reg_addr_t rs2
    );
        return isa_encode(opcode, ZERO_REG, rs1, rs2, 1'b0, 1'b0);
    endfunction

    function automatic instruction_t isa_encode_jump();
        return isa_encode_program_branch(OpJmp, ZERO_REG, ZERO_REG);
    endfunction

    // OpLoad rd, [base + imm]
    function automatic instruction_t isa_encode_load(
        input reg_addr_t rd,
        input reg_addr_t base
    );
        return isa_encode(OpLoad, rd, base, ZERO_REG, 1'b0, 1'b0);
    endfunction

    // OpStore source, [base + imm]
    function automatic instruction_t isa_encode_store(
        input reg_addr_t source,
        input reg_addr_t base
    );
        return isa_encode(OpStore, ZERO_REG, base, source, 1'b0, 1'b0);
    endfunction

    // ---------------- Decoded instruction ----------------
    //
    // The complete set of cpu_decoder outputs, packed so the
    // instruction unit hands the execution core one bundle instead
    // of a dozen scalar ports. Same pattern as soc_pkg's
    // bus_req_s / bus_rsp_s.
    //
    // The field order is a grouping, not an architectural layout:
    // nothing outside this struct depends on the bit positions.
    //
    // decode_valid low means the encoding is unusable, and every
    // other field then holds its safe default: no register write,
    // no flag write, no branch, no memory access.
    // ----------------------------------------------------

    typedef struct packed {
        reg_addr_t rs1;
        reg_addr_t rs2;
        reg_addr_t rd;

        opcode_t   op;
        word_t     imm_operand;
        logic      imm_sel;

        logic      register_write_enable;
        logic      flags_write_enable;

        logic      memory_read_enable;
        logic      memory_write_enable;

        logic      decode_valid;
    } program_ctrl_s;

endpackage

`endif