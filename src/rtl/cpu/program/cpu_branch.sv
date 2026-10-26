// ============================================================
// cpu_branch  control-flow resolution
// ============================================================
//
// Pure combinational. Compares the two source operands according to
// the condition cpu_decoder selected.
//
// If the condition is true and enable is asserted:
//      redirect = 1
//      redirect_target = target
//
// cpu_pc then loads redirect_target on the next rising clock edge.
// If redirect is 0, the counter advances by WORD_BYTES, or by two
// words when the retiring instruction had an immediate.
//
// The unit lives in the instruction unit rather than the execution
// core: its only output is the program-counter redirect. The operand
// values it compares are supplied by cpu_datapath, so the decision
// uses the same values the ALU sees.
//
// Signed and unsigned comparisons are intentionally separate.
// ============================================================

module cpu_branch (
    input  logic                enable,
    input  isa_pkg::opcode_t    opcode,
    input  arch_pkg::word_t     operand_a,
    input  arch_pkg::word_t     operand_b,
    input  arch_pkg::word_t     target,

    output logic                redirect,
    output arch_pkg::word_t     redirect_target
);

    import isa_pkg::*;

    always_comb begin
        // Safe defaults: no branch. The target is still forwarded so
        // it remains visible in simulation even when the branch is not
        // taken.
        redirect        = 1'b0;
        redirect_target = target;

        if (enable) begin
            case (opcode)
                OpJmp:   redirect = 1'b1;
                OpBeq:   redirect = (operand_a == operand_b);
                OpBne:   redirect = (operand_a != operand_b);
                OpBlt:   redirect = ($signed(operand_a) <  $signed(operand_b));
                OpBge:   redirect = ($signed(operand_a) >= $signed(operand_b));
                OpBltu:  redirect = (operand_a <  operand_b);
                OpBgeu:  redirect = (operand_a >= operand_b);
                default: redirect = 1'b0;
            endcase
        end
    end

endmodule
