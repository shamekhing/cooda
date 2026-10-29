# COODA CPU

CPU-only 32-bit von Neumann system for the Sipeed Tang Primer 20K. CPU instruction and data requests share one bus. Initialized BSRAM provides the boot region, and the dock's DDR3 is available as additional system memory.

## Architecture

- `cpu.sv` wires the instruction unit, decoder, execution core, register file, and ALU together.
- `bus_arbiter.sv` is a reusable four-client round-robin arbiter for one target. It holds a grant through target stalls. The current system connects CPU instruction fetch and data access; two inactive slots reserve GPU and TPU clients for later integration. Instantiate another arbiter for each future shared target.
- `memory.sv` routes the low BSRAM and DDR3 windows, checks unmapped/misaligned accesses, and wraps the single-port, byte-write-enabled `memory_bsram`.
- `memory_ddr3.sv` adapts the system bus to the DDR3 controller, including clock-domain crossing, refresh, and calibration gating.
- `system.sv` maps BSRAM at `0x0000_0000..0x0000_7fff` and 128 MiB DDR3 at `0x0800_0000..0x0fff_ffff`. The BSRAM region remains the reset/boot region.
- `fpga_top.sv` instantiates the DDR3 PLL and controller and exposes the Tang Primer 20K dock pins, plus the reset/run buttons and CPU status LEDs. GPU, video, and RPU logic are not active.

The bus is 32-bit, byte-addressed, and word-aligned. A request completes when `valid && ready`; clients hold requests stable until completion. The DDR3 window is little-endian and requires full-word write strobes. DDR3 accesses return an error until the PHY finishes initialization and calibration. The controller uses Gowin-specific DDR primitives and is intended for the Tang Primer 20K dock.

## Build and simulation

The Gowin project is `cooda.gprj`, with top module `fpga_top`. `filelist.f` gives the RTL compile order. The board build uses Gowin's `rPLL`, `DLL`, `DQS`, `OSER8`, `OSER8_MEM`, and `IDES8_MEM` primitives. The physical top therefore requires Gowin's primitive library for Icarus elaboration; the RTL-only system test below does not instantiate the PHY.

Run the CPU/BSRAM smoke test:

```sh
iverilog -g2012 -s system_tb -f filelist.f src/sim/testbench/soc/system_tb.sv -o /tmp/system_tb.out
vvp /tmp/system_tb.out
```

The test program writes `0x12345678` to BSRAM address `0x100`, reads it back, and loops. DDR3 is connected to the CPU bus for software accesses in its mapped window; the current boot image does not exercise DDR3.

The full regression is `./run.sh --no-gui`. It runs package invariants, the
ALU differential test, CPU and system boot tests, the DDR3 CDC and target
tests (`src/sim/testbench/memory/ddr3_*_tb.sv`), and the memory subsystem map
test (`src/sim/testbench/memory/memory_map_tb.sv`). The DDR3 target test
uses a behavioral controller model; it does not model the Gowin PHY pins or
prove electrical timing on hardware. Pin-level PHY simulation follows the
[upstream setup](https://github.com/nand2mario/ddr3-tang-primer-20k/tree/main/simulation)
and requires Gowin's `prim_sim.v` plus Micron's DDR3 model; those external
models are not included here.

## Board controls

- S1 (`btn_n0`) resets the CPU.
- S2 (`btn_n1`) pauses execution while held.
- LED0 indicates recent instruction retirement; LED1 indicates no CPU fault; LED2 indicates no illegal instruction.
- LED3 indicates DDR3 write leveling done; LED4 indicates DDR3 read calibration done; LED5 indicates no latched DDR3 access error.

The LEDs are active-low, so a lit LED means the condition is false. LED3 and LED4 lit together means DDR3 calibration never finished, and LED5 lit after a DDR3 access means that access failed.

The physical pin assignments, including DDR3, are in `src/constraints/sipeed_tang_primer_20k.cst`; the 27 MHz clock constraint is in the matching `.sdc` file. The DDR3 pin map and PHY follow the [upstream Tang Primer 20K implementation](https://github.com/nand2mario/ddr3-tang-primer-20k).

## Timing constraints

The SDC names the rPLL outputs explicitly: DDR serializer `fclk` at 398.25 MHz, controller `pclk` at 99.563 MHz, and phase-shifted DDR `ck` at 398.25 MHz. It excludes the `clk27`/`pclk` bus CDC paths and the `pclk`-to-`fclk` hard-PHY interface paths; same-clock fabric paths remain timed. A Gowin synthesis and place-and-route run completed with zero setup or hold violations. The reported worst setup slack was +1.891 ns and worst hold slack was +0.334 ns.
