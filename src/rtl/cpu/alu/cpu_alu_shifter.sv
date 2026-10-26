// ============================================================
// cpu_alu_shifter  shift / rotate sub-unit (bit-serial, multi-cycle)
//
// A single serial shifter covers OpShl, OpShr, arithmetic right shift
// and the OpRol/OpRor rotations. OpShl/OpShr/OpSar hold the serialiser
// for the first (shift amount) cycles while emitting the fill bit,
// then stream the operand. Rotations pre-rotate a circular register
// into position before emitting, so they take
// arch_pkg::WORD_WIDTH + offset cycles.
// ============================================================

module cpu_alu_shifter (
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

    // Counter wide enough for rotate offsets (WORD_WIDTH + offset).
    localparam int COUNTER_WIDTH = SERIAL_WIDTH + 1;

    typedef enum logic [1:0] {
        StIdle,
        StRun,
        StDone
    } state_e;

    state_e state_q, state_d;

    logic is_shl, is_shr, is_sar, is_rol, is_rotate, is_shift;

    always_comb begin
        is_shl    = (op == OpShl);
        is_shr    = (op == OpShr);
        is_sar    = (op == OpSar);
        is_rol    = (op == OpRol);
        is_rotate = is_rol || (op == OpRor);
        is_shift  = is_shl || is_shr || is_sar;
    end

    logic [arch_pkg::WORD_WIDTH-1:0] a_q,    a_d;
    logic [arch_pkg::WORD_WIDTH-1:0] a_sr_q, a_sr_d;
    logic [arch_pkg::WORD_WIDTH-1:0] r_sr_q, r_sr_d;

    logic [COUNTER_WIDTH-1:0] cnt_q,     cnt_d;
    logic [COUNTER_WIDTH-1:0] limit_q,   limit_d;
    logic [COUNTER_WIDTH-1:0] rot_pre_q, rot_pre_d;
    logic [COUNTER_WIDTH-1:0] sh_amt_q,  sh_amt_d;

    // ------------------------------------------------------------
    // Per-cycle serial datapath
    // ------------------------------------------------------------
    logic [SERIAL_WIDTH-1:0]  rot_k;
    logic [COUNTER_WIDTH-1:0] sh_amt;
    logic                     shift_hold, shift_fill, emitting, r_msb_first;
    logic                     a_bit, out_bit;

    assign rot_k = operand_b[SERIAL_WIDTH-1:0];

    // Shift amount capped at a full-width shift.
    assign sh_amt = (operand_b >= arch_pkg::WORD_WIDTH)
                    ? arch_pkg::WORD_WIDTH
                    : {1'b0, rot_k};

    assign a_bit       = a_sr_q[0];
    assign r_msb_first = is_shr || is_sar;

    assign shift_hold = is_shift && (cnt_q < sh_amt_q);
    assign shift_fill = is_sar ? a_q[arch_pkg::WORD_WIDTH-1] : 1'b0;
    assign emitting   = is_rotate ? (cnt_q >= rot_pre_q) : 1'b1;

    always_comb begin
        if (is_shift)        out_bit = shift_hold ? shift_fill : a_bit;
        else if (is_rotate)  out_bit = a_bit;
        else                 out_bit = 1'b0;
    end

    assign result = r_sr_q;
    assign busy   = (state_q != StIdle);
    assign done   = (state_q == StDone);

    // ------------------------------------------------------------
    // Next-state values
    // ------------------------------------------------------------
    always_comb begin
        // Hold by default; each state overrides what it changes.
        state_d   = state_q;
        cnt_d     = cnt_q;
        limit_d   = limit_q;
        rot_pre_d = rot_pre_q;
        sh_amt_d  = sh_amt_q;
        a_d       = a_q;
        a_sr_d    = a_sr_q;
        r_sr_d    = r_sr_q;

        case (state_q)

            StIdle: begin
                if (start) begin
                    a_d       = operand_a;
                    a_sr_d    = (is_shr || is_sar) ? alu_reverse(operand_a)
                                                   : operand_a;
                    r_sr_d    = '0;
                    rot_pre_d = is_rol
                                ? ((arch_pkg::WORD_WIDTH - rot_k) &
                                   (arch_pkg::WORD_WIDTH - 1))
                                : rot_k;
                    sh_amt_d  = sh_amt;
                    limit_d   = is_rotate
                                ? (arch_pkg::WORD_WIDTH + rot_pre_d - 1)
                                : (arch_pkg::WORD_WIDTH - 1);
                    cnt_d     = '0;
                    state_d   = StRun;
                end
            end

            StRun: begin
                // Circular for rotate offsets, held during a shift fill.
                a_sr_d = is_rotate
                         ? {a_sr_q[0], a_sr_q[arch_pkg::WORD_WIDTH-1:1]}
                         : (shift_hold
                            ? a_sr_q
                            : {1'b0, a_sr_q[arch_pkg::WORD_WIDTH-1:1]});

                // LSB-first streams the fill from the top, MSB-first
                // from the bottom.
                if (is_rotate)
                    r_sr_d = emitting
                             ? {out_bit, r_sr_q[arch_pkg::WORD_WIDTH-1:1]}
                             : r_sr_q;
                else if (r_msb_first)
                    r_sr_d = {r_sr_q[arch_pkg::WORD_WIDTH-2:0], out_bit};
                else
                    r_sr_d = {out_bit, r_sr_q[arch_pkg::WORD_WIDTH-1:1]};

                if (cnt_q == limit_q)
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
            state_q   <= StIdle;
            cnt_q     <= '0;
            limit_q   <= '0;
            rot_pre_q <= '0;
            sh_amt_q  <= '0;
            a_q       <= '0;
            a_sr_q    <= '0;
            r_sr_q    <= '0;
        end else begin
            state_q   <= state_d;
            cnt_q     <= cnt_d;
            limit_q   <= limit_d;
            rot_pre_q <= rot_pre_d;
            sh_amt_q  <= sh_amt_d;
            a_q       <= a_d;
            a_sr_q    <= a_sr_d;
            r_sr_q    <= r_sr_d;
        end
    end

endmodule
