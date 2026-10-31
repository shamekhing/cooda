// ============================================================
// hdmi_tx  TMDS transmit chain with differential LVDS outputs
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
// Each serialized lane passes through a differential LVDS output buffer;
// the .cst places each positive output on its HDMI pair and Gowin places
// the negative output on the paired pin.
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

    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n
);

    logic [9:0] q_blue;
    logic [9:0] q_green;
    logic [9:0] q_red;
    logic       tmds_clk_serial;
    logic [2:0] tmds_data_serial;

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
        .tmds_out   (tmds_data_serial[0])
    );

    hdmi_tmds_serializer u_ser_green (
        .pix_clk    (pix_clk),
        .serial_clk (serial_clk),
        .rst        (rst),
        .q          (q_green),
        .tmds_out   (tmds_data_serial[1])
    );

    hdmi_tmds_serializer u_ser_red (
        .pix_clk    (pix_clk),
        .serial_clk (serial_clk),
        .rst        (rst),
        .q          (q_red),
        .tmds_out   (tmds_data_serial[2])
    );

    hdmi_tmds_serializer u_ser_clk (
        .pix_clk    (pix_clk),
        .serial_clk (serial_clk),
        .rst        (rst),
        .q          (q_clk),
        .tmds_out   (tmds_clk_serial)
    );

    TLVDS_OBUF u_tmds_clk_obuf (
        .I(tmds_clk_serial), .O(tmds_clk_p), .OB(tmds_clk_n)
    );

    generate
        for (genvar lane = 0; lane < 3; lane++) begin : gen_tmds_obuf
            TLVDS_OBUF u_tmds_data_obuf (
                .I(tmds_data_serial[lane]),
                .O(tmds_data_p[lane]),
                .OB(tmds_data_n[lane])
            );
        end
    endgenerate

endmodule
