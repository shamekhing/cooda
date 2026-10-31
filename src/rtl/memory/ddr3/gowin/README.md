# Gowin DDR3 core

`ddr3_memory_interface.ipc` uses the DDR3 configuration from the Tang
Primer 20K DDR-test example: GW2A-18C, x16 DDR3, 400 MHz memory clock,
and a 1:4 controller ratio.

Generate `ddr3_memory_interface.v` with Gowin's DDR3 IP generator from
this `.ipc` file and place the protected generated output beside it.
That output is ignored by Git because it is Gowin-generated IP; it is
required by `cooda.gprj` to build the FPGA image. Do not copy the example's
generated protected source into the repository.

The adapter drives one 128-bit app transfer per aligned burst. It maps
each 32-bit SoC word into the corresponding app-data lane and masks the
other twelve bytes. The IP owns initialization and refresh; the adapter
does not issue user refresh requests.
