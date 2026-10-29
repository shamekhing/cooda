// ============================================================
// ddr3_pll  DDR3 clock generation (rPLL wrapper)
// ============================================================
//
// One rPLL hard macro (a fabric macro like BSRAM or CLKDIV, not
// IDE-generated IP) makes all three DDR3 clocks from clk27:
//
//   fclk = clk27 x (58+1)/(3+1) = 398.25 MHz   4 x pclk, the
//                                              DDR serializer clock
//   pclk = fclk / 4             =  99.56 MHz   command/response
//                                              clock (see
//                                              ddr3_controller.sv)
//   ck   = phase-shifted fclk                  driven out as
//                                              DDR3_CK
//
// VCO = fclk x ODIV_SEL = 796.5 MHz, inside the GW2A range.
//
// The divider set is the one upstream validated on this board
// (nand2mario/ddr3-tang-primer-20k, Apache-2.0, see
// ddr3_controller.sv in this directory). CLKOUTD_SRC="CLKOUT"
// with DYN_SDIV_SEL=4 is what makes pclk exactly fclk/4;
// PSDA_SEL selects the ck phase.
//
// lock is exposed so the DDR3 domain reset can be held until the
// PLL settles; the controller additionally needs its own DLL
// lock, which it takes internally.
// ============================================================

module ddr3_pll (
    input  logic clkin,     // 27 MHz board clock
    output logic pclk,      //  99.56 MHz
    output logic fclk,      // 398.25 MHz
    output logic ck,        // 398.25 MHz, phase-shifted
    output logic lock
);

    wire gw_gnd = 1'b0;
    wire clkoutd3_o;

    rPLL rpll_inst (
        .CLKOUT  (fclk),
        .LOCK    (lock),
        .CLKOUTP (ck),
        .CLKOUTD (pclk),
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

    defparam rpll_inst.FBDIV_SEL = 58;
    defparam rpll_inst.IDIV_SEL  = 3;
    defparam rpll_inst.ODIV_SEL  = 2;

    // pclk = fclk / 4.
    defparam rpll_inst.DYN_SDIV_SEL = 4;

    defparam rpll_inst.FCLKIN          = "27";
    defparam rpll_inst.DYN_IDIV_SEL    = "false";
    defparam rpll_inst.DYN_FBDIV_SEL   = "false";
    defparam rpll_inst.DYN_ODIV_SEL    = "false";
    defparam rpll_inst.PSDA_SEL        = "0100";
    defparam rpll_inst.DYN_DA_EN       = "false";
    defparam rpll_inst.DUTYDA_SEL      = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR   = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR  = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP= 0;
    defparam rpll_inst.CLKFB_SEL       = "internal";
    defparam rpll_inst.CLKOUT_BYPASS   = "false";
    defparam rpll_inst.CLKOUTP_BYPASS  = "false";
    defparam rpll_inst.CLKOUTD_BYPASS  = "false";
    defparam rpll_inst.CLKOUTD_SRC     = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC    = "CLKOUT";
    defparam rpll_inst.DEVICE          = "GW2A-18C";

endmodule
