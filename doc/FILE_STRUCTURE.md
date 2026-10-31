# COODA file and folder structure

This document describes where project-owned source, tests, tools, and
documentation belong. Keep implementation files out of `examples/`, which
contains board/vendor reference material.

## Repository root

```text
cooda.gprj                 Gowin project and synthesis source list
filelist.f                 Icarus source order for project-owned RTL
run.sh                     simulation regression runner
README.md                  project overview, use, and bring-up notes
doc/                       maintained project documentation
src/                       RTL, simulation, constraints, and boot programs
tools/                     host-side utilities
  mnist/                   MNIST image packer, UART sender, and host tests
data/mnist/                local MNIST IDX files and generated test images
examples/                  vendor/board references, not project RTL
impl/                      Gowin synthesis and place-and-route outputs
```

Generated files such as simulation binaries and waveforms belong under
`src/sim/build/` and `src/sim/waveforms/`. Keep downloaded device models in
`src/sim/vendor/`; do not commit generated dataset files or build outputs.

## RTL

```text
src/rtl/
  packages/                 shared architecture, ISA, ALU, and SoC types
  bus/                      bus arbitration and bus-level components
  cpu/
    alu/                    CPU arithmetic, logic, compare, and shift units
    core/                   register file, datapath, status, and execution
    program/                fetch, decode, branch, PC, and program logic
  memory/
    ddr3/                   DDR3 PLL, controller, and clock-domain crossing
    sd/                     SPI byte engine, card protocol, and SD loader
    memory.sv               memory map and BSRAM target
    memory_bsram.sv         on-chip boot memory
    memory_ddr3.sv          DDR3 bus target and calibration interface
    memory_sd.sv            microSD path wrapper
  mnist/                    MNIST-specific loader, fetch, rate, and display logic
    mnist_uart_loader.sv     MNIST UART image-to-DDR3 loader
    mnist_fetch.sv           moves MNIST records through DDR3/BSRAM
    mnist_frame_source.sv    MNIST pixels and labels for display
    mnist_rate.sv            MNIST image display-rate controls
    mnist_view_top.sv        MNIST SoC/video integration top
  soc/                      system integration and FPGA board top
  uart/                     reusable UART byte engines (RX/TX)
  util/
    async_fifo.sv           dual-clock FIFO utility
    button_debounce.sv      debounced button interface
  video/
    hdmi/                   raster, TMDS encoding, serialization, and PLL
```

`src/rtl/uart/` contains only reusable serial transport logic. All
MNIST-specific functions—including the UART image protocol/DDR3 loader and
the video fetch/display pipeline—belong in `src/rtl/mnist/`, not in a
generic UART, memory, or video subsystem. MNIST host tools live in
`tools/mnist/`; their files, simulation tests, and local input data are
likewise grouped by MNIST. UART and SD are alternative transports for
loading the same MNIST image.

## Simulation

```text
src/sim/
  pkg_checks.sv              package invariants
  build/                     compiled simulation executables
  waveforms/                 generated VCD files
  vendor/                    optional Gowin/Micron behavioral models
  testbench/
    cpu/                     CPU and ALU tests
    memory/
      ddr3/                  DDR3 adapter/controller tests
      sd/                    SD protocol, loader, and image tests
    mnist/                   MNIST loader, fetch, display, and rate tests
    soc/                     SoC and package tests
    uart/                    reusable UART byte-engine loopback test
    video/
                             reserved for video tests not specific to MNIST
```

Place UART transport tests in `src/sim/testbench/uart/`. Place all
MNIST-specific tests, including the UART image-loader test, in
`src/sim/testbench/mnist/`. For example,
`src/rtl/mnist/mnist_uart_loader.sv` pairs with
`src/sim/testbench/mnist/mnist_uart_loader_tb.sv`. The testbench top
should be named after the tested unit with a `_tb` suffix.

## Board files, tools, and documentation

```text
src/constraints/              board pin map (.cst) and timing constraints (.sdc)
src/programs/                  BSRAM boot program and program checks
tools/mnist/mnist_pack.py      packs MNIST IDX data into the COOD image format
tools/mnist/mnist_uart_send.py sends a packed image from a PC over UART
tools/sd_flash.py              SD-card image helper
doc/TECHNICAL_SPECS.md         architecture, clocks, throughput, and limits
doc/NAMING_CONVENTIONS.md      naming rules for RTL, tests, and scripts
doc/FILE_STRUCTURE.md          this source-placement guide
doc/MNIST_QUICK_START.md       PC-to-FPGA MNIST upload and bring-up guide
```

Use lowercase `snake_case` for new directories and source filenames. Name a
SystemVerilog file after its primary module. Keep testbenches under
`src/sim/testbench/` using the RTL directory hierarchy. Update both
`filelist.f` and `cooda.gprj` whenever a synthesizable source file is added
or moved; update `run.sh` when a regression test is added or moved.
