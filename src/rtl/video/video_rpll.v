// ============================================================
// video_rpll  pixel clock for the display backend
// ============================================================
//
// Readable wrapper around the Gowin rPLL hard primitive (rPLL is a
// hard macro in the fabric, like BSRAM or CLKDIV - not IDE-generated
// IP). Configuration copied from the Sipeed RGB LCD example for this
// board:
//
//   27 MHz in, IDIV 1, FBDIV 2, ODIV 16  ->  40.5 MHz out
//   VCO = 40.5 * 16 = 648 MHz, inside the GW2A range
//
// 40.5 MHz with 1066 x 520 totals gives about 73.1 frames/s. Change
// IDIV/FBDIV/ODIV here for another panel; the
// HDMI backend needs 74.25 MHz.
//
// lock is exposed so the pixel-domain reset can be held until the PLL
// has settled.
// ============================================================

module video_rpll (
    input  logic clkin,
    output logic clkout,
    output logic lock
);

    wire gw_gnd = 1'b0;

    wire clkoutp_o;
    wire clkoutd_o;
    wire clkoutd3_o;

    rPLL rpll_inst (
        .CLKOUT  (clkout),
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
    defparam rpll_inst.IDIV_SEL = 1;
    defparam rpll_inst.DYN_FBDIV_SEL = "false";
    defparam rpll_inst.FBDIV_SEL = 2;
    defparam rpll_inst.DYN_ODIV_SEL = "false";
    defparam rpll_inst.ODIV_SEL = 16;
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

endmodule
