// ============================================================
// cpu_pc  program counter
//
// Byte-addressed, synchronous, active-high reset. Priority at each
// rising edge: reset, enabled redirect, enabled increment. When
// enable is low the PC holds its value even if redirect is asserted.
// The increment skips the immediate word when the retiring
// instruction was followed by one.
// ============================================================

module cpu_pc (
    input  logic            clk,
    input  logic            rst,
    input  logic            enable,

    input  logic            redirect,
    input  arch_pkg::word_t redirect_target,
    input  logic            has_imm,

    output arch_pkg::word_t pc
);

    arch_pkg::word_t pc_q;

    assign pc = pc_q;

    always_ff @(posedge clk) begin
        if (rst) pc_q <= '0;
        else if (enable) begin
            pc_q <= redirect
                    ? redirect_target
                    : pc_q + arch_pkg::word_t'(
                          (has_imm ? 2 : 1) * arch_pkg::WORD_BYTES);
        end
    end

endmodule
