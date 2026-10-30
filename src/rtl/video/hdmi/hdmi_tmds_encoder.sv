// ============================================================
// hdmi_tmds_encoder  8b/10b TMDS encoder (one channel)
// ============================================================
//
// DVI 1.0 / HDMI TMDS encoding with a pipeline between transition
// minimisation and DC balancing, plus the running disparity:
//
//   de high : transition-minimised 8b -> 9b, then DC balanced to 10b
//             using the running disparity
//   de low  : one of four fixed control words, disparity reset
//
// Control inputs by channel (per the HDMI wiring):
//   blue  : c = {vs, hs}
//   green : c = 2'b00
//   red   : c = 2'b00
//
// q[0] is the first bit to transmit, which is why the serializer maps
// q[0] to its D0 input.
// ============================================================

module hdmi_tmds_encoder (
    input  logic       pix_clk,
    input  logic       rst,

    input  logic       de,
    input  logic [7:0] d,
    input  logic [1:0] c,

    output logic [9:0] q
);

    logic [3:0] n1d;
    logic [3:0] n1q_d, n0q_d;
    logic [3:0] n1q_q, n0q_q;
    logic [8:0] q_m_d, q_m_q;
    logic       de_q;
    logic [1:0] c_q;
    logic signed [4:0] cnt_q, cnt_d;
    logic       qm8_invert;

    // ========================================================
    // STAGE 1  transition minimised 9-bit word
    // ========================================================

    always_comb begin
        n1d = 4'(d[0]) + 4'(d[1]) + 4'(d[2]) + 4'(d[3]) +
              4'(d[4]) + 4'(d[5]) + 4'(d[6]) + 4'(d[7]);

        // More 1s than 0s, or exactly balanced with d[0] low: XNOR chain.
        qm8_invert = (n1d > 4) || ((n1d == 4) && (d[0] == 1'b0));

        q_m_d[0] = d[0];

        if (qm8_invert) begin
            q_m_d[1] = ~(q_m_d[0] ^ d[1]);
            q_m_d[2] = ~(q_m_d[1] ^ d[2]);
            q_m_d[3] = ~(q_m_d[2] ^ d[3]);
            q_m_d[4] = ~(q_m_d[3] ^ d[4]);
            q_m_d[5] = ~(q_m_d[4] ^ d[5]);
            q_m_d[6] = ~(q_m_d[5] ^ d[6]);
            q_m_d[7] = ~(q_m_d[6] ^ d[7]);
            q_m_d[8] = 1'b0;
        end else begin
            q_m_d[1] = q_m_d[0] ^ d[1];
            q_m_d[2] = q_m_d[1] ^ d[2];
            q_m_d[3] = q_m_d[2] ^ d[3];
            q_m_d[4] = q_m_d[3] ^ d[4];
            q_m_d[5] = q_m_d[4] ^ d[5];
            q_m_d[6] = q_m_d[5] ^ d[6];
            q_m_d[7] = q_m_d[6] ^ d[7];
            q_m_d[8] = 1'b1;
        end

        n1q_d = 4'(q_m_d[0]) + 4'(q_m_d[1]) + 4'(q_m_d[2]) + 4'(q_m_d[3]) +
                4'(q_m_d[4]) + 4'(q_m_d[5]) + 4'(q_m_d[6]) + 4'(q_m_d[7]);
        n0q_d = 4'd8 - n1q_d;
    end

    // Pipeline the transition-minimised word and its bit count. This
    // separates the XOR/count stage from disparity selection and lets
    // the 74.25 MHz pixel clock meet timing.
    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) begin
            q_m_q  <= '0;
            n1q_q  <= '0;
            n0q_q  <= 4'd8;
            de_q   <= 1'b0;
            c_q    <= 2'b00;
            cnt_q  <= '0;
        end else begin
            q_m_q  <= q_m_d;
            n1q_q  <= n1q_d;
            n0q_q  <= n0q_d;
            de_q   <= de;
            c_q    <= c;
            cnt_q  <= cnt_d;
        end
    end

    // ========================================================
    // STAGE 2  DC balance and control words
    // ========================================================
    // The disparity each candidate 10-bit word adds, derived from the
    // bit counts:
    //   balanced form : depends on q_m[8], byte is inverted when low
    //   inverted form : 2*q_m[8] + n0q - n1q
    //   non-inverted  : 2*q_m[8] + n1q - n0q - 2
    // --------------------------------------------------------

    always_comb begin
        q   = 10'b0;
        cnt_d = cnt_q;

        if (de_q) begin

            if ((cnt_q == 5'sd0) || (n1q_q == n0q_q)) begin
                // Select the byte polarity from q_m[8]. When it is low,
                // invert the transition-minimised byte to balance the
                // two prefix bits and update disparity consistently.
                q = {~q_m_q[8], q_m_q[8], (q_m_q[8] ? q_m_q[7:0] : ~q_m_q[7:0])};
                if (q_m_q[8]) cnt_d = cnt_q + ({1'b0, n1q_q} - {1'b0, n0q_q});
                else           cnt_d = cnt_q + ({1'b0, n0q_q} - {1'b0, n1q_q});

            end else if ((!cnt_q[4] && (n1q_q > n0q_q)) ||
                         ( cnt_q[4] && (n0q_q > n1q_q))) begin
                // Invert when word disparity has the same sign as the
                // current running disparity (including negative/0-heavy).
                q     = {1'b1, q_m_q[8], ~q_m_q[7:0]};
                cnt_d = cnt_q + {3'b000, q_m_q[8], 1'b0} +
                        {1'b0, n0q_q} - {1'b0, n1q_q};

            end else begin
                // Otherwise send the word as it is.
                q     = {1'b0, q_m_q[8], q_m_q[7:0]};
                cnt_d = cnt_q + {3'b000, q_m_q[8], 1'b0} +
                        {1'b0, n1q_q} - {1'b0, n0q_q} - 5'd2;
            end

        end else begin
            // Control period: disparity is reset.
            cnt_d = 5'd0;

            case (c_q)
                2'b00:   q = 10'b1101010100;
                2'b01:   q = 10'b0010101011;
                2'b10:   q = 10'b0101010100;
                default: q = 10'b1010101011;
            endcase
        end
    end

endmodule
