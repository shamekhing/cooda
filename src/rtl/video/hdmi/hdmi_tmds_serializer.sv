// ============================================================
// hdmi_tmds_serializer  10:1 serializer for one TMDS pair
// ============================================================
//
// Uses the Gowin OSER10 hard primitive (a fabric macro, documented in
// the Gowin primitive guide, not IDE-generated IP): the 10-bit word is
// loaded on the pixel clock and shifted out at 10x on the serial
// clock, which is what a TMDS channel needs (74.25 MHz pixel clock,
// 742.5 Mbit/s per pair).
//
// q[0] is transmitted first, so it drives D0.
//
// The GW2A OSER10 primitive has GSREN and LSREN parameters. Its clock
// rates are established by PCLK/FCLK and the connected PLL, not by
// frequency parameters on this primitive.
// ============================================================

module hdmi_tmds_serializer (
    input  logic       pix_clk,
    input  logic       serial_clk,
    input  logic       rst,

    input  logic [9:0] q,

    output logic       tmds_out
);

    OSER10 u_oser10 (
        .Q     (tmds_out),

        .D0    (q[0]),
        .D1    (q[1]),
        .D2    (q[2]),
        .D3    (q[3]),
        .D4    (q[4]),
        .D5    (q[5]),
        .D6    (q[6]),
        .D7    (q[7]),
        .D8    (q[8]),
        .D9    (q[9]),

        .PCLK  (pix_clk),
        .FCLK  (serial_clk),
        .RESET (rst)
    );

    defparam u_oser10.GSREN = "false";
    defparam u_oser10.LSREN = "true";

endmodule
