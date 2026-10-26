// ============================================================
// cpu_alu_comparator  comparison sub-unit (bit-serial, multi-cycle)
//
// Equality and ordered comparisons plus the MIN/MAX operations, all
// derived from a single MSB-first comparison: the first differing bit
// decides. Signed variants flip the sign bit and compare unsigned.
// The comparator outputs a 1-bit boolean (zero-extended to the word)
// for the comparisons and the selected operand for MIN/MAX, so no
// separate compare path is needed in the arithmetic unit.
// ============================================================

module cpu_alu_comparator (
    input  logic clk,
    input  logic rst,
    input  logic start,

    input  arch_pkg::word_t operand_a, operand_b,
    input  isa_pkg::opcode_t op,

    output arch_pkg::word_t result,
    output logic busy,
    output logic done
);

    import arch_pkg::*;
    import isa_pkg::*;
    import alu_pkg::*;

    typedef enum logic [1:0] {
        StIdle,
        StRun,
        StDone
    } state_e;

    state_e state_q, state_d;

    logic is_signed, is_minmax, is_min;

    always_comb begin
        is_minmax = (op >= OpMinu) && (op <= OpMaxs);
        is_signed = ((op >= OpLts) && (op <= OpGes)) ||
                    ((op >= OpMins) && (op <= OpMaxs));
        is_min    = (op == OpMinu) || (op == OpMins);
    end

    logic [arch_pkg::WORD_WIDTH-1:0] a_q,    a_d;
    logic [arch_pkg::WORD_WIDTH-1:0] b_q,    b_d;
    logic [arch_pkg::WORD_WIDTH-1:0] a_sr_q, a_sr_d;
    logic [arch_pkg::WORD_WIDTH-1:0] b_sr_q, b_sr_d;
    logic [SERIAL_WIDTH-1:0]         cnt_q,  cnt_d;

    logic cmp_eq_q, cmp_gt_q, cmp_lt_q;
    logic cmp_eq_d, cmp_gt_d, cmp_lt_d;

    logic [arch_pkg::WORD_WIDTH-1:0] result_q, result_d;

    // Preload: MSB-first, sign bit flipped for signed comparisons.
    logic [arch_pkg::WORD_WIDTH-1:0] cmp_a, cmp_b;
    assign cmp_a = is_signed ? (operand_a ^ MSB_ONE) : operand_a;
    assign cmp_b = is_signed ? (operand_b ^ MSB_ONE) : operand_b;

    // Per-cycle comparison state.
    logic a_bit, b_bit;

    assign a_bit = a_sr_q[0];
    assign b_bit = b_sr_q[0];

    // The first differing bit decides; once decided, it holds.
    always_comb begin
        cmp_eq_d = cmp_eq_q;
        cmp_gt_d = cmp_gt_q;
        cmp_lt_d = cmp_lt_q;

        // Each operation starts with an undecided comparison. Without
        // reinitializing these flags here, a later operation inherits the
        // previous comparison's first-differing-bit result.
        if ((state_q == StIdle) && start) begin
            cmp_eq_d = 1'b1;
            cmp_gt_d = 1'b0;
            cmp_lt_d = 1'b0;
        end else if (cmp_eq_q) begin
            if (a_bit & ~b_bit) begin
                cmp_gt_d = 1'b1;
                cmp_eq_d = 1'b0;
            end else if (~a_bit & b_bit) begin
                cmp_lt_d = 1'b1;
                cmp_eq_d = 1'b0;
            end
        end
    end

    // Comparison result for this cycle, before the final latch.
    logic [arch_pkg::WORD_WIDTH-1:0] cmp_result;

    always_comb begin
        if (is_minmax) begin
            if (is_min)
                cmp_result = cmp_lt_d ? a_q : b_q;
            else
                cmp_result = cmp_gt_d ? a_q : b_q;
        end else begin
            case (op)
                OpNe:         cmp_result = {{(arch_pkg::WORD_WIDTH-1){1'b0}}, ~cmp_eq_d};
                OpLtu, OpLts: cmp_result = {{(arch_pkg::WORD_WIDTH-1){1'b0}},  cmp_lt_d};
                OpLeu, OpLes: cmp_result = {{(arch_pkg::WORD_WIDTH-1){1'b0}},
                                            (cmp_lt_d | cmp_eq_d)};
                OpGtu, OpGts: cmp_result = {{(arch_pkg::WORD_WIDTH-1){1'b0}},  cmp_gt_d};
                OpGeu, OpGes: cmp_result = {{(arch_pkg::WORD_WIDTH-1){1'b0}},
                                            (cmp_gt_d | cmp_eq_d)};
                default:      cmp_result = {{(arch_pkg::WORD_WIDTH-1){1'b0}},  cmp_eq_d};
            endcase
        end
    end

    assign result = result_q;
    assign busy   = (state_q != StIdle);
    assign done   = (state_q == StDone);

    // ------------------------------------------------------------
    // Next-state values
    // ------------------------------------------------------------
    always_comb begin
        // Hold by default; each state overrides what it changes.
        state_d = state_q;
        cnt_d   = cnt_q;
        a_d     = a_q;
        b_d     = b_q;
        a_sr_d  = a_sr_q;
        b_sr_d  = b_sr_q;
        result_d = result_q;

        case (state_q)

            StIdle: begin
                if (start) begin
                    a_d      = operand_a;
                    b_d      = operand_b;
                    a_sr_d   = alu_reverse(cmp_a);
                    b_sr_d   = alu_reverse(cmp_b);
                    cnt_d    = '0;
                    state_d  = StRun;
                end
            end

            StRun: begin
                a_sr_d = {1'b0, a_sr_q[arch_pkg::WORD_WIDTH-1:1]};
                b_sr_d = {1'b0, b_sr_q[arch_pkg::WORD_WIDTH-1:1]};

                if (cnt_q == arch_pkg::WORD_WIDTH - 1) begin
                    result_d = cmp_result;
                    state_d  = StDone;
                end else begin
                    cnt_d = cnt_q + 1'b1;
                end
            end

            StDone: state_d = StIdle;

            default: state_d = StIdle;

        endcase
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q  <= StIdle;
            cnt_q    <= '0;
            a_q      <= '0;
            b_q      <= '0;
            a_sr_q   <= '0;
            b_sr_q   <= '0;
            cmp_eq_q <= 1'b1;
            cmp_gt_q <= 1'b0;
            cmp_lt_q <= 1'b0;
            result_q <= '0;
        end else begin
            state_q  <= state_d;
            cnt_q    <= cnt_d;
            a_q      <= a_d;
            b_q      <= b_d;
            a_sr_q   <= a_sr_d;
            b_sr_q   <= b_sr_d;
            cmp_eq_q <= cmp_eq_d;
            cmp_gt_q <= cmp_gt_d;
            cmp_lt_q <= cmp_lt_d;
            result_q <= result_d;
        end
    end

endmodule
