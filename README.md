# COODA CPU

32-bit von Neumann system for the Sipeed Tang Primer 20K. CPU instruction and data requests share one bus. Initialized BSRAM provides the boot region, the dock's DDR3 is additional system memory, a hardware loader fills that memory from a microSD card at boot, and an HDMI viewer shows MNIST images read out of that memory on a 720p screen.

Technical detail and measured performance: [doc/TECHNICAL_SPECS.md](doc/TECHNICAL_SPECS.md). Naming rules for new code: [doc/NAMING_CONVENTIONS.md](doc/NAMING_CONVENTIONS.md).

## Architecture

- `cpu.sv` wires the instruction unit, decoder, execution core, register file, and ALU together.
- `bus_arbiter.sv` is a reusable four-client round-robin arbiter for one target. It holds a grant through target stalls. The current system connects CPU instruction fetch and data access; two inactive slots reserve GPU and TPU clients for later integration. Instantiate another arbiter for each future shared target.
- `memory.sv` routes the low BSRAM and DDR3 windows, checks unmapped/misaligned accesses, and wraps the single-port, byte-write-enabled `memory_bsram`.
- `memory_ddr3.sv` adapts the system bus to the DDR3 controller, including clock-domain crossing, refresh, and calibration gating.
- `memory_sd.sv` wraps the microSD path (`sd_spi_master.sv`, `sd_controller.sv`, `sd_loader.sv` under `memory/sd/`) and is what `system.sv` instantiates when `SD_ENABLE` is set. It loads a card image into DDR3 at boot with no CPU program involved.
- `system.sv` maps BSRAM at `0x0000_0000..0x0000_7fff` and 128 MiB DDR3 at `0x0800_0000..0x0fff_ffff`. The BSRAM region remains the reset/boot region.
- `fpga_top.sv` is the board wrapper: it exposes the Tang Primer 20K dock pins - DDR3, microSD, the two onboard buttons, two header-pin rate buttons, the TMDS pairs, and the status LEDs - and wires them to `mnist_view_top`, which instantiates `system` (with `VIEW_ENABLE` set) plus the display path in `video/mnist/` and `video/hdmi/`.

The bus is 32-bit, byte-addressed, and word-aligned. A request completes when `valid && ready`; clients hold requests stable until completion. The DDR3 window is little-endian and requires full-word write strobes. A DDR3 access issued before the PHY has finished initialization and calibration is held until the PHY is ready, and fails with an error only if calibration never completes or the address, alignment, or write strobes violate the contract. The controller uses Gowin-specific DDR primitives and is intended for the Tang Primer 20K dock.

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
tests (`src/sim/testbench/memory/ddr3/`), and the memory subsystem map
test (`src/sim/testbench/memory/memory_map_tb.sv`). The DDR3 target test
uses a behavioral controller model; it does not model the Gowin PHY pins or
prove electrical timing on hardware.

The regression also drives the real controller against Micron's DDR3 model
on the DRAM pins (`src/sim/testbench/memory/ddr3/ddr3_controller_tb.sv`), which
exercises power-up initialization, ZQ calibration, write leveling, read
calibration, write/read-back, and refresh. That test needs Gowin's
`prim_sim.v` and Micron's model, which are third-party files and are not
included here; `src/sim/vendor/README.md` says where to put them, and the
regression prints a skip message when they are absent. It is by far the
slowest test in the regression.

The microSD path is covered by four tests under
`src/sim/testbench/memory/sd/`: `sd_spi_master_tb.sv` (the byte engine, bit
order, and both card speeds), `sd_controller_tb.sv` (the wake-up sequence
command by command, SDHC and SDSC addressing, and every error path),
`sd_loader_tb.sv` (the loader against a bus target that stalls and checks
the bus contract), and `sd_image_tb.sv`, which reads a card image produced
by `tools/mnist_pack.py` and checks that every byte of it lands in the
target. The last one is skipped when the MNIST IDX files are not present.

## microSD card

The dock's microSD slot is wired to the FPGA in SPI mode, and the card is how data reaches DDR3: there is no assembler yet, so there is no software that could copy a dataset, and the loader is hardware instead.

- `src/rtl/memory/sd/sd_spi_master.sv` clocks bytes on the four card pins (SPI mode 0), full duplex, with a divider the protocol layer rewrites between phases.
- `src/rtl/memory/sd/sd_controller.sv` speaks the card's protocol: the wake-up sequence (CMD0, CMD8, CMD55+ACMD41 until the card is ready, CMD58, CMD16) and then CMD17 block reads with the 0xFE data token. Every wait is bounded and every failure has a code.
- `src/rtl/memory/sd/sd_loader.sv` is the boot-time bus master. It warms the DDR3 window up with one read first, so a PHY that is still calibrating cannot swallow payload, then reads the header and streams the payload in.
- `memory_sd.sv` wraps those three; `system.sv` instantiates it when `SD_ENABLE` is set, on arbiter slot 2. The loader is idle once a load finishes, so a later compute block can share that slot behind a valid gate.

### Card image

`tools/mnist_pack.py` turns MNIST IDX files into the raw image the loader expects. Block 0 is a header of little-endian 32-bit words:

| word | meaning |
| --- | --- |
| 0 | magic `COOD` (`0x434F_4F44`) |
| 1 | payload blocks (512 bytes each) |
| 2 | destination byte offset in the DDR3 window |
| 3 | payload bytes (true length) |
| 4 | records |
| 5, 6 | image rows, columns |
| 7 | label bytes per record |
| 8 | payload checksum |

The payload is the images (one byte per pixel) followed by the labels, padded to a block boundary. The loader checks words 0..3 and refuses anything that does not fit the window; the rest is for whatever reads the data out of DDR3 later.

```sh
python3 tools/mnist_pack.py \
    --images data/mnist/train-images.idx3-ubyte \
    --labels data/mnist/train-labels.idx1-ubyte \
    --out mnist.img
sudo dd if=mnist.img of=/dev/sdX bs=512 conv=fsync   # a dedicated card
```

For a card that has to keep its filesystem, build the image with `--dest-offset`, write it with `dd ... seek=<LBA>`, and set `HDR_LBA` in `fpga_top.sv`'s `memory_sd` instantiation to the same LBA.

### Speed

The card runs at 397 kHz during initialization and 13.5 MHz during data transfer. SPI carries one bit per clock, so 13.5 MHz gives a raw ceiling of 1.69 MB/s (about 1.6 MiB/s); a 25 MHz SPI clock would raise that only to 3.125 MB/s raw. `sd_controller` issues one CMD17 per 512-byte block, adding command, response, token, CRC, tail, and byte-engine handshake overhead, so the payload rate lands a little under that ceiling: the 60,000-image training set is 47 MB, which loads in about 30 seconds.

The DDR3 write path is not what limits a load. A benchmark in `ddr3_target_tb.sv` measures sequential writes through the adapter and its clock crossing at 7.19 MiB/s (about 7.5 MB/s) - roughly five times the card path - and it measures RTL transaction overhead only: it runs against a behavioral controller and says nothing about PHY or DRAM timing.

The dock routes all four SD data pins (DAT0..DAT3), but this RTL uses them as SPI MISO, MOSI, CS, and clock. A native four-bit bus at 50 MHz would have a raw bus ceiling of 25 MB/s; 50 MB/s requires a 100 MHz four-bit mode (SDR50) and 1.8 V signaling. SDR104 reaches 104 MB/s at 208 MHz, also at 1.8 V. The Tang Primer 20K bank voltage defaults to 3.3 V, so the dock's actual SD voltage-switching path and FPGA bank configuration must be verified before enabling UHS-I modes. A four-bit card would also need the DDR3 write path widened first: it moves one 32-bit word as two serial 16-bit commands, one transaction at a time, so a card faster than the measured 7.5 MB/s would trip the loader's overrun trap instead of loading.

### Failures

Every wait in the path is bounded, so a missing card, a card that never answers, or an image that does not fit fails instead of hanging. The controller reports `sd_err_code`:

| code | meaning |
| --- | --- |
| 1 | CMD0 was not answered, or did not answer 0x01 |
| 2 | CMD8 did not echo the check pattern |
| 3 | ACMD41 was not answered, or the card never came ready |
| 4 | CMD58 was not answered, or did not answer 0x00 |
| 5 | CMD16 was not answered, or did not answer 0x00 |
| 6 | CMD17 was not answered, or did not answer 0x00 |
| 7 | no 0xFE data token arrived |

and the loader reports `load_err_code`:

| code | meaning |
| --- | --- |
| 1 | the card failed, or a read stopped part way |
| 2 | the header magic is wrong |
| 3 | the block count is zero, too large, or inconsistent with the byte count |
| 4 | the destination does not fit in the DDR3 window |
| 5 | a payload word arrived while the bus was still busy |

The whole path is verified in simulation, including a real image from `tools/mnist_pack.py` byte for byte, and the display test (`mnist_view_tb`) shows those bytes landing pixel-perfect on the modelled screen. Neither path has been brought up on hardware yet: card and monitor bring-up are the next steps, which is why the LEDs show how far a load got.

## Board controls

- S1 (`btn_n0`) resets the CPU, the microSD path and the video path.
- S2 (`btn_n1`) pauses execution while held.
- The two rate buttons for the MNIST viewer sit on header pins T12 (`btn_n2`, show images faster) and T11 (`btn_n3`, show images slower) - jumper each to ground for a press; the dock only carries the two tactile buttons.
- The HDMI connector carries a 720p60 TMDS stream showing the MNIST records the card image holds, one image at a time (448x448, centred), starting at 1 image/s; the rate buttons double or halve it, bounded at 60 and 1. The backend is pure RTL plus Gowin hard macros (rPLL, CLKDIV, OSER10) - no IDE-generated IP, so it simulates under Icarus and commits. See `doc/TECHNICAL_SPECS.md`, section 8.
- LED0 indicates recent instruction retirement.
- LED1 indicates DDR3 write leveling done; LED2 indicates DDR3 read calibration done.
- LED3 indicates the card answered the wake-up sequence; LED4 indicates the card image is in DDR3; LED5 indicates nothing failed (DDR3, the card, or the image).

The LEDs are active-low, so a lit LED means the condition is false. LED1 and LED2 lit together means DDR3 calibration never finished; LED3 lit means the card never initialised; LED4 lit after LED3 has gone out means the load did not finish; LED5 lit means something failed.

Six LEDs cannot show everything, so the four-bit error codes (`sd_err_code` and `load_err_code` on `system.sv`, and the FSM state on `sd_controller`'s `state_dbg`) stay in simulation. A board that fails to load shows which stage it reached; a waveform or an added pin shows why.

The microSD slot is wired in SPI mode on `sd_cs_n` (N11), `sd_sck` (N10), `sd_mosi` (R14), and `sd_miso` (M8), which is the mapping LiteX-Boards uses for this dock. The slot also has DAT1 (M7), DAT2 (M10), and card detect (D15) wired; SPI mode uses none of them.

The physical pin assignments, including DDR3 and microSD, are in `src/constraints/sipeed_tang_primer_20k.cst`; the 27 MHz clock constraint is in the matching `.sdc` file. The DDR3 pin map and PHY follow the [upstream Tang Primer 20K implementation](https://github.com/nand2mario/ddr3-tang-primer-20k).

## Timing constraints

The SDC names the PLL outputs explicitly: DDR serializer `fclk` at 398.25 MHz, controller `pclk` at 99.563 MHz, phase-shifted DDR `ck` at 398.25 MHz, TMDS serializer clock at 371.25 MHz, and pixel clock at 74.25 MHz. It excludes the bus CDC paths (`clk27`/`pclk` and `clk27`/pixel) and the hard-PHY/OSER10 clock-to-clock interface paths; same-clock fabric paths remain timed. Timing closure status is per the latest Gowin run - the video path grew the design, so check the latest report.
