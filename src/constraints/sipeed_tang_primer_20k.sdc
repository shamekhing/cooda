create_clock -name clk27 -period 37.037 -waveform {0.000 18.518} [get_ports {clk27}]

# Name the PLL outputs explicitly so path exceptions can select them during
# SDC parsing, before Gowin assigns its automatic generated-clock names.
# fpga_top wraps the SoC, so both PLLs sit one hierarchy level down.
create_generated_clock -name ddr_fclk -source [get_ports {clk27}] -multiply_by 59 -divide_by 4 [get_pins {u_soc/pll/rpll_inst/CLKOUT}]
create_generated_clock -name ddr_pclk -source [get_ports {clk27}] -multiply_by 59 -divide_by 16 [get_pins {u_soc/pll/rpll_inst/CLKOUTD}]
create_generated_clock -name ddr_ck -source [get_ports {clk27}] -multiply_by 59 -divide_by 4 -phase 90 [get_pins {u_soc/pll/rpll_inst/CLKOUTP}]

# The video pair: hdmi_rpll makes 371.25 MHz (27 x 55/4) for the TMDS
# serialisers, and its CLKDIV makes 74.25 MHz (÷5) for the pixel path.
create_generated_clock -name video_fclk -source [get_ports {clk27}] -multiply_by 55 -divide_by 4 [get_pins {u_soc/u_hdmi_rpll/rpll_inst/CLKOUT}]
create_generated_clock -name video_pclk -source [get_pins {u_soc/u_hdmi_rpll/rpll_inst/CLKOUT}] -divide_by 5 [get_pins {u_soc/u_hdmi_rpll/u_clkdiv/CLKOUT}]

# DDR bus CDC uses a toggle handshake and holds each payload stable until
# acknowledgement. These protocol crossings are not single-cycle paths.
set_false_path -from [get_clocks {clk27}] -to [get_clocks {ddr_pclk}]
set_false_path -from [get_clocks {ddr_pclk}] -to [get_clocks {clk27}]

# The image crosses clk27 to the pixel domain through async_fifo, whose
# grey-coded pointers each sit behind their own two-flop synchroniser.
set_false_path -from [get_clocks {clk27}] -to [get_clocks {video_pclk}]
set_false_path -from [get_clocks {video_pclk}] -to [get_clocks {clk27}]

# PCLK and FCLK both terminate at hard primitives that perform their
# internal serialisation and control (the DDR hard PHY, the TMDS
# serialisers' OSER10). Gowin STA models some of those primitive arcs as
# fabric clock-to-clock paths, so exclude that interface direction while
# keeping the return direction and all same-domain fabric paths timed.
set_false_path -from [get_clocks {ddr_pclk}] -to [get_clocks {ddr_fclk}]
set_false_path -from [get_clocks {video_pclk}] -to [get_clocks {video_fclk}]
