// ============================================================
// hdmi_rpll  pixel and serial clocks for the TMDS backend
// ============================================================
//
// Readable wrappers around two Gowin hard primitives (rPLL and
// CLKDIV), configured exactly as the Sipeed HDMI example for this
// board configures them. Hard macros, not IDE-generated IP.
//
//   rPLL   : 27 MHz x 55/4 = 371.25 MHz   (VCO = 371.25 x 2 = 742.5)
//   CLKDIV : /5 -> 74.25 MHz pixel clock
//
// The serial clock runs the 10:1 serializers; the pixel clock runs the
// raster, the encoders and the GPU renderer.
// ============================================================

module hdmi_rpll (
    input  logic clkin,
    input  logic resetn,        // active low, from the PLL lock

    output logic serial_clk,    // 371.25 MHz
    output logic pix_clk,       // 74.25 MHz
    output logic lock
);

    wire gw_gnd = 1'b0;

    wire clkoutp_o;
    wire clkoutd_o;
    wire clkoutd3_o;

    rPLL rpll_inst (
        .CLKOUT  (serial_clk),
        .LOCK    (lock),
        .CLKOUTP (clkoutp_o),
        .CLKOUTD (clkoutd_o),
        .CLKOUTD3(clkoutd3_o),
        .RESET   (gw_gnd),
        .RESET_P (gw_gnd),
        .CLKIN   (clkin),
        .CLKFB   (gw_gnd),
        .FBDSEL  ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .IDSEL   ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .ODSEL   ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .PSDA    ({gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .DUTYDA  ({gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .FDLY    ({gw_gnd, gw_gnd, gw_gnd, gw_gnd})
    );

    defparam rpll_inst.FCLKIN = "27";
    defparam rpll_inst.DYN_IDIV_SEL = "false";
    defparam rpll_inst.IDIV_SEL = 3;
    defparam rpll_inst.DYN_FBDIV_SEL = "false";
    defparam rpll_inst.FBDIV_SEL = 54;
    defparam rpll_inst.DYN_ODIV_SEL = "false";
    defparam rpll_inst.ODIV_SEL = 2;
    defparam rpll_inst.PSDA_SEL = "0000";
    defparam rpll_inst.DYN_DA_EN = "true";
    defparam rpll_inst.DUTYDA_SEL = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
    defparam rpll_inst.CLKFB_SEL = "internal";
    defparam rpll_inst.CLKOUT_BYPASS = "false";
    defparam rpll_inst.CLKOUTP_BYPASS = "false";
    defparam rpll_inst.CLKOUTD_BYPASS = "false";
    defparam rpll_inst.DYN_SDIV_SEL = 2;
    defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
    defparam rpll_inst.DEVICE = "GW2A-18C";

    CLKDIV u_clkdiv (
        .RESETN (resetn),
        .HCLKIN (serial_clk),
        .CLKOUT (pix_clk),
        .CALIB  (1'b1)
    );

    defparam u_clkdiv.DIV_MODE = "5";
    defparam u_clkdiv.GSREN = "false";

endmodule
