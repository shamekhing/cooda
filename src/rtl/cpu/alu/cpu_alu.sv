// ============================================================
// cpu_alu  ALU top level
//
// Decodes the opcode, launches exactly one of the four multi-cycle
// bit-serial sub-units (cpu_alu_arithmetic, cpu_alu_logic_unit,
// cpu_alu_shifter, cpu_alu_comparator) and selects its result.
// Status flags are derived centrally from the selected result plus
// the arithmetic sub-unit's carry/overflow/div-zero.
//
// Ports:
//   start : asserted for one cycle by the core to launch an op
//   busy  : high while the selected sub-unit is running
//   done  : one-cycle pulse when result/flags are valid
//   valid : op is a recognised ALU encoding (combinational)
//
// An unrecognised opcode completes immediately with result = 0 and
// flags = 0 so the enclosing core can consume it safely.
// ============================================================

module cpu_alu (
    input  logic clk,
    input  logic rst,

    input  logic start,

    input  arch_pkg::word_t operand_a, operand_b,
    input  isa_pkg::opcode_t op,
    input  logic carry_in,

    output arch_pkg::word_t result,
    output arch_pkg::flags_s flags,
    output logic valid,
    output logic busy,
    output logic done
);

    import arch_pkg::*;
    import isa_pkg::*;

    assign valid = (op <= OpGes);

    // ------------------------------------------------------------
    // Sub-unit selection
    // ------------------------------------------------------------
    logic sel_arith, sel_logic, sel_shift, sel_cmp;

    always_comb begin
        sel_arith = (op <= OpMods) || (op == OpAbs) || (op == OpNeg);
        sel_logic = (op >= OpNot) && (op <= OpPassB);
        sel_shift = (op >= OpShl) && (op <= OpRor);
        sel_cmp   = ((op >= OpEq) && (op <= OpGes)) ||
                    ((op >= OpMinu) && (op <= OpMaxs));
    end

    // Only the selected sub-unit is started.
    logic arith_start, logic_start, shift_start, cmp_start;

    assign arith_start = start && sel_arith;
    assign logic_start = start && sel_logic;
    assign shift_start = start && sel_shift;
    assign cmp_start   = start && sel_cmp;

    // ------------------------------------------------------------
    // Sub-units
    // ------------------------------------------------------------
    word_t arith_result, logic_result, shift_result, cmp_result;
    logic  arith_busy, logic_busy, shift_busy, cmp_busy;
    logic  arith_done, logic_done, shift_done, cmp_done;
    logic  arith_carry, arith_overflow, arith_div_zero;

    cpu_alu_arithmetic u_cpu_alu_arithmetic (
        .clk(clk),
        .rst(rst),
        .start(arith_start),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .op(op),
        .carry_in(carry_in),
        .result(arith_result),
        .carry(arith_carry),
        .overflow(arith_overflow),
        .div_zero(arith_div_zero),
        .busy(arith_busy),
        .done(arith_done)
    );

    cpu_alu_logic_unit u_cpu_alu_logic_unit (
        .clk(clk),
        .rst(rst),
        .start(logic_start),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .op(op),
        .result(logic_result),
        .busy(logic_busy),
        .done(logic_done)
    );

    cpu_alu_shifter u_cpu_alu_shifter (
        .clk(clk),
        .rst(rst),
        .start(shift_start),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .op(op),
        .result(shift_result),
        .busy(shift_busy),
        .done(shift_done)
    );

    cpu_alu_comparator u_cpu_alu_comparator (
        .clk(clk),
        .rst(rst),
        .start(cmp_start),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .op(op),
        .result(cmp_result),
        .busy(cmp_busy),
        .done(cmp_done)
    );

    // ------------------------------------------------------------
    // Result and handshake
    // ------------------------------------------------------------
    assign result = sel_arith ? arith_result :
                    sel_logic ? logic_result :
                    sel_shift ? shift_result :
                    sel_cmp   ? cmp_result   : '0;

    // An unrecognised opcode finishes in one cycle with a null result.
    logic invalid_done_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) invalid_done_q <= 1'b0;
        else     invalid_done_q <= start && !valid;
    end

    assign busy = arith_busy | logic_busy | shift_busy | cmp_busy;
    assign done = invalid_done_q | arith_done | logic_done |
                  shift_done | cmp_done;

    // ------------------------------------------------------------
    // Flags describe the selected result
    // ------------------------------------------------------------
    always_comb begin
        flags = '0;

        if (valid) begin
            flags.Z = (result == '0);
            flags.N = result[arch_pkg::WORD_WIDTH-1];

            if (sel_arith) begin
                flags.C  = arith_carry;
                flags.V  = arith_overflow;
                flags.DZ = arith_div_zero;
            end
        end
    end

endmodule
