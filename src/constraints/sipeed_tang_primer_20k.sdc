create_clock -name clk27 -period 37.037 -waveform {0.000 18.518} [get_ports {clk27}]

# Name the PLL outputs explicitly so path exceptions can select them during
# SDC parsing, before Gowin assigns its automatic generated-clock names.
create_generated_clock -name ddr_fclk -source [get_ports {clk27}] -multiply_by 59 -divide_by 4 [get_pins {pll/rpll_inst/CLKOUT}]
create_generated_clock -name ddr_pclk -source [get_ports {clk27}] -multiply_by 59 -divide_by 16 [get_pins {pll/rpll_inst/CLKOUTD}]
create_generated_clock -name ddr_ck -source [get_ports {clk27}] -multiply_by 59 -divide_by 4 -phase 90 [get_pins {pll/rpll_inst/CLKOUTP}]

# DDR bus CDC uses a toggle handshake and holds each payload stable until
# acknowledgement. These protocol crossings are not single-cycle paths.
set_false_path -from [get_clocks {clk27}] -to [get_clocks {ddr_pclk}]
set_false_path -from [get_clocks {ddr_pclk}] -to [get_clocks {clk27}]

# PCLK and FCLK both terminate at the DDR hard PHY primitives, which perform
# their internal serialization, hold control, and reset handling. Gowin STA
# models some of those primitive arcs as fabric PCLK-to-FCLK paths, so exclude
# that interface direction while keeping FCLK-to-PCLK and all same-domain
# fabric paths timed.
set_false_path -from [get_clocks {ddr_pclk}] -to [get_clocks {ddr_fclk}]
