// ============================================================
// COODA timing constraints - Sipeed Tang Primer 20K
//
// TARGET
//
//   clk27 is the onboard 27 MHz oscillator (H11): 37.037 ns period,
//   50 % duty, matching the Gowin process configuration.
//
//   clk27 is the SoC clock. The LCD rPLL and DDR3 DQS capture logic
//   create additional clock domains that require explicit timing review.
//
//   Without the create_clock below the analyzer only sees an inferred
//   clock and falls back to the synthesis global frequency.
// ============================================================

create_clock -name clk27 -period 37.037 -waveform {0.000 18.518} [get_ports {clk27}]

// HDMI build only (VIDEO_HDMI=1): create the 74.25 MHz pixel clock at
// the CLKDIV output. Gowin does not propagate this divider clock through
// the hierarchy automatically and reports TA1132 otherwise. The LCD
// build uses video_rpll instead; use its separate clock constraint when
// building that backend.
create_generated_clock -name hdmi_pix_clk -source [get_ports {clk27}] -master_clock clk27 -divide_by 4 -multiply_by 11 [get_pins {g_hdmi_clk.u_hdmi_rpll/u_clkdiv/CLKOUT}]

// ---------------------------------------------------------------------------
// RGB LCD
//
// The panel clock (video_rpll: 27 MHz -> 40.5 MHz) is produced by the
// rPLL hard primitive. Confirm the PnR tool propagates this PLL clock
// and add panel-specific output delays from the panel timing sheet.
//
// The LCD interface is a plain synchronous output group: video_lcd
// launches data on pix_clk and drives lcd_dclk inverted, so the panel
// samples half a pixel period later. If the analyzer reports the
// lcd_* outputs against an inferred clock, constrain them explicitly:
//
//   create_clock -name lcd_dclk -period 24.691 [get_ports {lcd_dclk}]
//
// Do not create a second clock on lcd_dclk if the PLL clock is already
// propagated; that would mask the actual source relationship.
// ---------------------------------------------------------------------------

// memory_ddr3_phy contains DQS-derived capture clocks. Gowin reports
// these as clocks that were not created and routes them on generic
// resources. This is a real DDR timing risk: the current controller
// does not use dedicated DQS clocking resources in this implementation.
//
// The following constraints are intentionally not added blindly. A
// correct DDR interface constraint set requires the exact DRAM speed
// grade, board trace delays, and tool-supported DQS/IDDR primitives.
//
//   1. Declare the DDR clock as a generated clock on the pin's net so
//      the output timing of the SSTL15 group is reported against it:
//
//        create_generated_clock -name ddr3_ck -source [get_ports {clk27}] \
//            -divide_by 2 [get_ports {ddr3_ck_p}]
//
//   2. Cut the DQ/DQS capture paths, which the controller closes by
//      construction (DQS-strobed capture with a half-cycle window at
//      13.5 MHz):
//
//        set_false_path -from [get_ports {ddr3_dq[*]}] -to [get_ports {ddr3_dq[*]}]
//        set_false_path -from [get_ports {ddr3_dqs_*[*]}]
//
// False-pathing these paths would hide the warning without fixing
// capture timing. Rework the PHY/IO implementation before claiming
// reliable DDR operation on hardware.
// ---------------------------------------------------------------------------

