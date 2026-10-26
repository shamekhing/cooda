// ============================================================
// hdmi_tx  TMDS transmit chain (pure RTL, no vendor IP)
// ============================================================
//
// Three encoders and four serializers: one pair per colour channel and
// one for the clock channel.
//
// Channel order follows the DVI/HDMI spec:
//   data[0] = blue  (carries HSYNC/VSYNC during blanking)
//   data[1] = green
//   data[2] = red
// If a monitor shows swapped colours, that mapping is the thing to
// change.
//
// The clock channel sends a fixed 1111100000 pattern, i.e. a square
// wave at one tenth of the serial rate, which is the pixel clock the
// sink expects.
//
// Each pair is driven as ONE logical output; the .cst maps it onto the
// two pins of the board's differential pair, which is how the Sipeed
// HDMI example constrains the same connector.
// ============================================================

module hdmi_tx (
    input  logic       pix_clk,
    input  logic       serial_clk,
    input  logic       rst,

    input  logic       de,
    input  logic       hs,
    input  logic       vs,
    input  logic [7:0] r,
    input  logic [7:0] g,
    input  logic [7:0] b,

    output logic       tmds_clk,
    output logic [2:0] tmds_data
);

    logic [9:0] q_blue;
    logic [9:0] q_green;
    logic [9:0] q_red;

    // Clock channel: 5 high, 5 low, every pixel.
    logic [9:0] q_clk;
    assign q_clk = 10'b1111100000;

    // The bus visualiser contains a multiply and several levels of
    // region/color selection. Register its stream before TMDS encoding so
    // rendering and encoding occupy separate pixel-clock paths.
    logic       de_q;
    logic       hs_q, vs_q;
    logic [7:0] r_q, g_q, b_q;

    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) begin
            de_q <= 1'b0;
            hs_q <= 1'b0;
            vs_q <= 1'b0;
            r_q  <= '0;
            g_q  <= '0;
            b_q  <= '0;
        end else begin
            de_q <= de;
            hs_q <= hs;
            vs_q <= vs;
            r_q  <= r;
            g_q  <= g;
            b_q  <= b;
        end
    end

    hdmi_tmds_encoder u_enc_blue (
        .pix_clk (pix_clk),
        .rst     (rst),
        .de      (de_q),
        .d       (b_q),
        .c       ({vs_q, hs_q}),
        .q       (q_blue)
    );

    hdmi_tmds_encoder u_enc_green (
        .pix_clk (pix_clk),
        .rst     (rst),
        .de      (de_q),
        .d       (g_q),
        .c       (2'b00),
        .q       (q_green)
    );

    hdmi_tmds_encoder u_enc_red (
        .pix_clk (pix_clk),
        .rst     (rst),
        .de      (de_q),
        .d       (r_q),
        .c       (2'b00),
        .q       (q_red)
    );

    hdmi_tmds_serializer u_ser_blue (
        .pix_clk    (pix_clk),
        .serial_clk (serial_clk),
        .rst        (rst),
        .q          (q_blue),
        .tmds_out   (tmds_data[0])
    );

    hdmi_tmds_serializer u_ser_green (
        .pix_clk    (pix_clk),
        .serial_clk (serial_clk),
        .rst        (rst),
        .q          (q_green),
        .tmds_out   (tmds_data[1])
    );

    hdmi_tmds_serializer u_ser_red (
        .pix_clk    (pix_clk),
        .serial_clk (serial_clk),
        .rst        (rst),
        .q          (q_red),
        .tmds_out   (tmds_data[2])
    );

    hdmi_tmds_serializer u_ser_clk (
        .pix_clk    (pix_clk),
        .serial_clk (serial_clk),
        .rst        (rst),
        .q          (q_clk),
        .tmds_out   (tmds_clk)
    );

endmodule
