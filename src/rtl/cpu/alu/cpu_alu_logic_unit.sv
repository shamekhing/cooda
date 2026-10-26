// ============================================================
// cpu_alu_logic_unit  bitwise-logic sub-unit (bit-serial, multi-cycle)
//
// One bit is processed per clock, LSB-first, so the unit is just two
// shift registers, a result register and a 1-bit logic function.
// Operations: OpAnd/OpOr/OpXor/OpNot/OpNand/OpNor/OpXnor plus the
// OpPassA/OpPassB paths used to implement MOV (OpPassA) and MOVI
// (OpPassB).
// ============================================================

module cpu_alu_logic_unit (
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

    logic [arch_pkg::WORD_WIDTH-1:0] a_sr_q, b_sr_q, r_sr_q;
    logic [arch_pkg::WORD_WIDTH-1:0] a_sr_d, b_sr_d, r_sr_d;
    logic [SERIAL_WIDTH-1:0]         cnt_q, cnt_d;

    logic a_bit, b_bit, out_bit;

    assign a_bit = a_sr_q[0];
    assign b_bit = b_sr_q[0];

    assign result = r_sr_q;
    assign busy   = (state_q != StIdle);
    assign done   = (state_q == StDone);

    // The 1-bit logic function for this cycle.
    always_comb begin
        case (op)
            OpNot:   out_bit = ~a_bit;
            OpAnd:   out_bit = a_bit & b_bit;
            OpOr:    out_bit = a_bit | b_bit;
            OpXor:   out_bit = a_bit ^ b_bit;
            OpNand:  out_bit = ~(a_bit & b_bit);
            OpNor:   out_bit = ~(a_bit | b_bit);
            OpXnor:  out_bit = ~(a_bit ^ b_bit);
            OpPassA: out_bit = a_bit;
            OpPassB: out_bit = b_bit;
            default: out_bit = 1'b0;
        endcase
    end

    // ------------------------------------------------------------
    // Next-state values
    // ------------------------------------------------------------
    always_comb begin
        // Hold by default; each state overrides what it changes.
        state_d = state_q;
        a_sr_d  = a_sr_q;
        b_sr_d  = b_sr_q;
        r_sr_d  = r_sr_q;
        cnt_d   = cnt_q;

        case (state_q)

            StIdle: begin
                if (start) begin
                    a_sr_d  = operand_a;
                    b_sr_d  = operand_b;
                    r_sr_d  = '0;
                    cnt_d   = '0;
                    state_d = StRun;
                end
            end

            StRun: begin
                a_sr_d = {1'b0, a_sr_q[arch_pkg::WORD_WIDTH-1:1]};
                b_sr_d = {1'b0, b_sr_q[arch_pkg::WORD_WIDTH-1:1]};
                r_sr_d = {out_bit, r_sr_q[arch_pkg::WORD_WIDTH-1:1]};

                if (cnt_q == arch_pkg::WORD_WIDTH - 1)
                    state_d = StDone;
                else
                    cnt_d = cnt_q + 1'b1;
            end

            StDone: state_d = StIdle;

            default: state_d = StIdle;

        endcase
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q <= StIdle;
            cnt_q   <= '0;
            a_sr_q  <= '0;
            b_sr_q  <= '0;
            r_sr_q  <= '0;
        end else begin
            state_q <= state_d;
            cnt_q   <= cnt_d;
            a_sr_q  <= a_sr_d;
            b_sr_q  <= b_sr_d;
            r_sr_q  <= r_sr_d;
        end
    end

endmodule
