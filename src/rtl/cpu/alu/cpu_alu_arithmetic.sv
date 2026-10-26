// ============================================================
// cpu_alu_arithmetic  arithmetic sub-unit (bit-serial, multi-cycle)
//
// OpAdd/OpAdc/OpSub/OpSbc/OpNeg/OpAbs are produced one bit per clock
// through a single 1-bit adder plus a carry flip-flop. OpMul/OpMulh use
// an iterative shift-add loop and OpDiv/OpMod a restoring loop, both
// built from narrow adders instead of parallel multipliers/dividers.
//
// Side-channel status:
//   carry    : unsigned carry out (OpAdd) / no borrow (OpSub)
//   overflow : signed overflow; set when the true result is not
//              representable in arch_pkg::WORD_WIDTH bits
//   div_zero : asserted whenever the divisor operand_b is zero
//
// The signed MIN/-1 division and modulo cases are special-cased to
// avoid the implementation-defined overflow of signed division.
// ============================================================

module cpu_alu_arithmetic (
    input  logic clk,
    input  logic rst,
    input  logic start,

    input  arch_pkg::word_t operand_a, operand_b,
    input  isa_pkg::opcode_t op,
    input  logic carry_in,

    output arch_pkg::word_t result,
    output logic carry,
    output logic overflow,
    output logic div_zero,
    output logic busy,
    output logic done
);

    import arch_pkg::*;
    import isa_pkg::*;
    import alu_pkg::*;

    // ------------------------------------------------------------
    // Operation classification
    // ------------------------------------------------------------
    logic is_addsub, is_adc, is_sbc, is_sub, is_neg, is_abs;
    logic is_mul, is_mulh, is_divop, is_div, is_signed_div;
    logic use_neg;

    always_comb begin
        is_addsub     = (op == OpAdd) || (op == OpAdc) ||
                        (op == OpSub) || (op == OpSbc);
        is_adc        = (op == OpAdc);
        is_sbc        = (op == OpSbc);
        is_sub        = (op == OpSub) || (op == OpSbc);
        is_neg        = (op == OpNeg);
        is_abs        = (op == OpAbs);
        is_mul        = (op == OpMul) || (op == OpMulh);
        is_mulh       = (op == OpMulh);
        is_divop      = (op >= OpDivu) && (op <= OpMods);
        is_div        = (op == OpDivu) || (op == OpDivs);
        is_signed_div = (op == OpDivs) || (op == OpMods);
    end

    // ------------------------------------------------------------
    // Engine state
    // ------------------------------------------------------------
    typedef enum logic [1:0] {
        StIdle,
        StRun,
        StDone
    } state_e;

    state_e state_q, state_d;

    logic [arch_pkg::WORD_WIDTH-1:0] a_q,     a_d;
    logic [arch_pkg::WORD_WIDTH-1:0] b_q,     b_d;
    logic [arch_pkg::WORD_WIDTH-1:0] a_sr_q,  a_sr_d;
    logic [arch_pkg::WORD_WIDTH-1:0] b_sr_q,  b_sr_d;
    logic [arch_pkg::WORD_WIDTH-1:0] r_sr_q,  r_sr_d;
    logic [SERIAL_WIDTH-1:0]         cnt_q,   cnt_d;
    logic                            carry_bit_q, carry_bit_d;

    logic [2*arch_pkg::WORD_WIDTH-1:0] macc_q,  macc_d;
    logic [2*arch_pkg::WORD_WIDTH-1:0] mcand_q, mcand_d;
    logic [arch_pkg::WORD_WIDTH:0]     drem_q,  drem_d;
    logic [arch_pkg::WORD_WIDTH-1:0]   dquo_q,  dquo_d;

    logic [arch_pkg::WORD_WIDTH-1:0] result_q, result_d;
    logic                            carry_q,    carry_d;
    logic                            overflow_q, overflow_d;
    logic                            div_zero_q, div_zero_d;

    assign result   = result_q;
    assign carry    = carry_q;
    assign overflow = overflow_q;
    assign div_zero = div_zero_q;
    assign busy     = (state_q != StIdle);
    assign done     = (state_q == StDone);

    // ------------------------------------------------------------
    // Per-cycle 1-bit datapath
    // ------------------------------------------------------------
    logic [arch_pkg::WORD_WIDTH-1:0] a_abs;
    logic a_bit, b_bit, x_bit, y_bit, sum_bit, cout_bit, add_out;

    assign a_abs = operand_a[arch_pkg::WORD_WIDTH-1]
                   ? alu_negate(operand_a) : operand_a;

    assign a_bit   = a_sr_q[0];
    assign b_bit   = b_sr_q[0];
    assign use_neg = is_neg || (is_abs && a_q[arch_pkg::WORD_WIDTH-1]);

    always_comb begin
        x_bit    = use_neg ? 1'b0 : a_bit;
        y_bit    = use_neg ? ~a_bit : (b_bit ^ is_sub);
        sum_bit  = x_bit ^ y_bit ^ carry_bit_q;
        cout_bit = (x_bit & y_bit) | (carry_bit_q & (x_bit ^ y_bit));
        add_out  = (is_abs && !a_q[arch_pkg::WORD_WIDTH-1]) ? a_bit : sum_bit;
    end

    // ------------------------------------------------------------
    // Multiply / divide helpers
    // ------------------------------------------------------------
    logic [arch_pkg::WORD_WIDTH:0] drem_shifted;
    logic [arch_pkg::WORD_WIDTH-1:0] div_b;
    logic                            div_ge;

    assign div_b        = is_signed_div
                          ? (b_q[arch_pkg::WORD_WIDTH-1] ? alu_negate(b_q) : b_q)
                          : b_q;
    assign drem_shifted = {drem_q[arch_pkg::WORD_WIDTH-1:0], a_bit};
    assign div_ge       = (drem_shifted >= {1'b0, div_b});

    // ------------------------------------------------------------
    // Next-state values
    // ------------------------------------------------------------
    always_comb begin
        // Hold by default; each state overrides what it changes.
        state_d     = state_q;
        a_d         = a_q;
        b_d         = b_q;
        a_sr_d      = a_sr_q;
        b_sr_d      = b_sr_q;
        r_sr_d      = r_sr_q;
        cnt_d       = cnt_q;
        carry_bit_d = carry_bit_q;
        macc_d      = macc_q;
        mcand_d     = mcand_q;
        drem_d      = drem_q;
        dquo_d      = dquo_q;
        result_d    = result_q;
        carry_d     = carry_q;
        overflow_d  = overflow_q;
        div_zero_d  = div_zero_q;

        case (state_q)

            StIdle: begin
                if (start) begin
                    a_d = operand_a;
                    b_d = operand_b;

                    // Restoring division consumes the dividend MSB-first.
                    a_sr_d = is_divop
                             ? alu_reverse(is_signed_div ? a_abs : operand_a)
                             : operand_a;
                    b_sr_d = operand_b;

                    // Initial carry: -x sets it, subtraction borrows, the
                    // carry-in variants take the flag, everything else 0.
                    carry_bit_d = is_neg ? 1'b1 :
                                  is_abs ? operand_a[arch_pkg::WORD_WIDTH-1] :
                                  is_sbc ? carry_in :
                                  is_sub ? 1'b1 :
                                  is_adc ? carry_in : 1'b0;

                    r_sr_d  = '0;
                    macc_d  = '0;
                    mcand_d = {{arch_pkg::WORD_WIDTH{1'b0}}, operand_a};
                    drem_d  = '0;
                    dquo_d  = '0;
                    cnt_d   = '0;
                    state_d = StRun;
                end
            end

            StRun: begin
                a_sr_d      = {1'b0, a_sr_q[arch_pkg::WORD_WIDTH-1:1]};
                b_sr_d      = {1'b0, b_sr_q[arch_pkg::WORD_WIDTH-1:1]};
                r_sr_d      = {add_out, r_sr_q[arch_pkg::WORD_WIDTH-1:1]};
                carry_bit_d = cout_bit;

                // Multiply (shift-add).
                macc_d  = b_bit ? (macc_q + mcand_q) : macc_q;
                mcand_d = mcand_q << 1;

                // Restoring divide.
                drem_d = div_ge ? (drem_shifted - {1'b0, div_b})
                                : drem_shifted;
                dquo_d = div_ge ? {dquo_q[arch_pkg::WORD_WIDTH-2:0], 1'b1}
                                : {dquo_q[arch_pkg::WORD_WIDTH-2:0], 1'b0};

                if (cnt_q == arch_pkg::WORD_WIDTH - 1) begin

                    // ------------------------------------------------
                    // Result finalisation
                    // ------------------------------------------------
                    if (is_mul) begin
                        result_d = is_mulh
                                   ? macc_d[2*arch_pkg::WORD_WIDTH-1:
                                            arch_pkg::WORD_WIDTH]
                                   : macc_d[arch_pkg::WORD_WIDTH-1:0];
                    end else if (is_divop) begin
                        if (b_q == '0)
                            result_d = '0;
                        else if (is_signed_div && (a_q == MSB_ONE) &&
                                 (b_q == ALL_ONES))
                            result_d = is_div ? MSB_ONE : '0;
                        else if (is_signed_div) begin
                            if (is_div)
                                result_d = (a_q[arch_pkg::WORD_WIDTH-1] ^
                                            b_q[arch_pkg::WORD_WIDTH-1])
                                           ? alu_negate(dquo_d) : dquo_d;
                            else
                                result_d = a_q[arch_pkg::WORD_WIDTH-1]
                                           ? alu_negate(
                                                 drem_d[arch_pkg::WORD_WIDTH-1:0])
                                           : drem_d[arch_pkg::WORD_WIDTH-1:0];
                        end else begin
                            result_d = is_div
                                       ? dquo_d
                                       : drem_d[arch_pkg::WORD_WIDTH-1:0];
                        end
                    end else begin
                        result_d = r_sr_d;
                    end

                    // ------------------------------------------------
                    // Status flags describe that result
                    // ------------------------------------------------
                    carry_d    = 1'b0;
                    overflow_d = 1'b0;
                    div_zero_d = 1'b0;

                    if (is_addsub) begin
                        carry_d = cout_bit;
                        if (is_sub)
                            overflow_d = (a_q[arch_pkg::WORD_WIDTH-1] ^
                                          b_q[arch_pkg::WORD_WIDTH-1]) &
                                         (a_q[arch_pkg::WORD_WIDTH-1] ^
                                          result_d[arch_pkg::WORD_WIDTH-1]);
                        else
                            overflow_d = ~(a_q[arch_pkg::WORD_WIDTH-1] ^
                                           b_q[arch_pkg::WORD_WIDTH-1]) &
                                         (a_q[arch_pkg::WORD_WIDTH-1] ^
                                          result_d[arch_pkg::WORD_WIDTH-1]);
                    end else if (is_neg) begin
                        carry_d    = (a_q == '0);
                        overflow_d = (a_q == MSB_ONE);
                    end else if (is_abs) begin
                        overflow_d = (a_q == MSB_ONE);
                    end else if (is_divop) begin
                        div_zero_d = (b_q == '0);
                        if (is_signed_div && (a_q == MSB_ONE) &&
                            (b_q == ALL_ONES))
                            overflow_d = is_div;
                    end

                    state_d = StDone;

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
            state_q     <= StIdle;
            a_q         <= '0;
            b_q         <= '0;
            a_sr_q      <= '0;
            b_sr_q      <= '0;
            r_sr_q      <= '0;
            cnt_q       <= '0;
            carry_bit_q <= 1'b0;
            macc_q      <= '0;
            mcand_q     <= '0;
            drem_q      <= '0;
            dquo_q      <= '0;
            result_q    <= '0;
            carry_q     <= 1'b0;
            overflow_q  <= 1'b0;
            div_zero_q  <= 1'b0;
        end else begin
            state_q     <= state_d;
            a_q         <= a_d;
            b_q         <= b_d;
            a_sr_q      <= a_sr_d;
            b_sr_q      <= b_sr_d;
            r_sr_q      <= r_sr_d;
            cnt_q       <= cnt_d;
            carry_bit_q <= carry_bit_d;
            macc_q      <= macc_d;
            mcand_q     <= mcand_d;
            drem_q      <= drem_d;
            dquo_q      <= dquo_d;
            result_q    <= result_d;
            carry_q     <= carry_d;
            overflow_q  <= overflow_d;
            div_zero_q  <= div_zero_d;
        end
    end

endmodule
