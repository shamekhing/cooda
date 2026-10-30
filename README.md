# COODA

A 32-bit von Neumann computer on the Sipeed Tang Primer 20K (Gowin
GW2A-LV18PG256C8/I7), built from scratch in SystemVerilog. It boots from
on-chip BSRAM, fills its 128 MiB DDR3 from a microSD card at
configuration time — no CPU program involved — and shows the dataset
it loaded on an HDMI monitor: one MNIST digit at a time, upscaled and
centred, at a rate you set with buttons.

Everything is RTL: a hand-rolled CPU, a round-robin bus, a DDR3
controller over the vendor PHY primitives, an SPI card reader, and a
TMDS display backend with no IDE-generated IP — the same HDL
synthesizes with Gowin and simulates with Icarus.

| | |
| --- | --- |
| CPU | 32-bit, von Neumann, byte-addressed bus |
| Boot memory | 32 KiB on-chip BSRAM, initialised from hex |
| Main memory | 128 MiB DDR3 at 0x0800_0000 (DDR3-800, 16-bit) |
| Dataset input | microSD, SPI mode, loaded at boot by hardware |
| Display | HDMI 720p60, TMDS, 448x448 MNIST patch, 1..60 images/s |
| Toolchain | Gowin EDA (synthesis + P&R), Icarus Verilog (simulation) |
| Board | Sipeed Tang Primer 20K dock |

Deeper detail and measured numbers: [doc/TECHNICAL_SPECS.md](doc/TECHNICAL_SPECS.md).
Rules for adding code: [doc/NAMING_CONVENTIONS.md](doc/NAMING_CONVENTIONS.md).

## Status

| Part | State |
| --- | --- |
| CPU, ALU, bus, BSRAM | working, simulation-verified (14,510 ALU checks) |
| DDR3 controller + PHY | synthesis and P&R close timing; verified against Micron's model in simulation |
| microSD loader | verified byte for byte against a real packer image in simulation |
| HDMI display path | verified end to end in simulation (pixel-exact); not yet shown on a physical monitor |
| Hardware bring-up | next step — the LEDs report how far each path got |

## Repository layout

```
cooda.gprj                            Gowin project (top: fpga_top)
filelist.f                            Icarus compile order, mirrors the gprj
run.sh                                the regression runner
doc/TECHNICAL_SPECS.md                the technical specification
doc/NAMING_CONVENTIONS.md             naming rules for new code
tools/mnist_pack.py                   packs MNIST IDX files into a card image
src/rtl/
  packages/                           arch_pkg, soc_pkg, alu_pkg, isa_pkg
  cpu/                                the CPU core and its parts
  bus/                                bus_arbiter
  memory/                             memory, memory_bsram, memory_ddr3, memory_sd
    ddr3/                             ddr3_pll, ddr3_controller, ddr3_cdc
    sd/                               sd_spi_master, sd_controller, sd_loader
  soc/                                system.sv, fpga_top.sv
  util/                               async_fifo, button_debounce
  video/
    mnist/                            mnist_view_top, mnist_fetch,
                                      mnist_frame_source, mnist_rate
    hdmi/                             hdmi_tx, hdmi_tmds_encoder,
                                      hdmi_tmds_serializer, hdmi_rpll,
                                      hdmi_timing
src/rtl/soc/fpga_top.sv               the board wrapper (the synthesis top)
src/programs/boot_program.hex         the boot image for the BSRAM
src/constraints/                      the dock's .cst pins and .sdc timing
src/sim/
  vendor/                             where the Gowin/Micron models go (not included)
  testbench/                          one folder per module, mirroring src/rtl
  pkg_checks.sv                       package invariant checks
src/programs/                         programs loaded into the BSRAM
examples/                             vendor board examples, reference only
data/mnist/                           MNIST IDX files (not included)
```

## How the machine works

### Architecture

- `cpu.sv` wires the instruction unit, decoder, execution core, register
  file, and ALU together. The ALU is differentially tested against a
  reference model.
- `bus_arbiter.sv` is a reusable four-client round-robin arbiter for one
  target. It holds a grant through target stalls. The current system
  connects CPU instruction fetch, CPU data access, the microSD loader,
  and the display fetcher; the GPU and TPU are reserved for later
  integration. Instantiate another arbiter for each future shared target.
- `memory.sv` routes the low BSRAM and DDR3 windows, checks
  unmapped/misaligned accesses, and wraps the single-port,
  byte-write-enabled `memory_bsram`.
- `memory_ddr3.sv` adapts the system bus to the DDR3 controller,
  including clock-domain crossing, refresh, and calibration gating.
- `memory_sd.sv` wraps the microSD path (`sd_spi_master.sv`,
  `sd_controller.sv`, `sd_loader.sv` under `memory/sd/`) and is what
  `system.sv` instantiates when `SD_ENABLE` is set. It loads a card
  image into DDR3 at boot with no CPU program involved.
- `system.sv` maps BSRAM at `0x0000_0000..0x0000_7fff` and 128 MiB DDR3
  at `0x0800_0000..0x0fff_ffff`. The BSRAM region remains the reset/boot
  region.
- `mnist_view_top.sv` is `system` plus the display half: the video PLL,
  the raster, the frame source, and the display fetcher. It is what the
  board actually instantiates.
- `fpga_top.sv` is the board wrapper: it exposes the Tang Primer 20K
  dock pins — DDR3, microSD, the two onboard buttons, two header-pin
  rate buttons, the TMDS pairs, and the status LEDs — and wires them to
  `mnist_view_top`.

### Bus contract

The bus is 32-bit, byte-addressed, and word-aligned. A request completes
when `valid && ready`; clients hold requests stable until completion.
The DDR3 window is little-endian and requires full-word write strobes. A
DDR3 access issued before the PHY has finished initialization and
calibration is held until the PHY is ready, and fails with an error only
if calibration never completes or the address, alignment, or write
strobes violate the contract. The controller uses Gowin-specific DDR
primitives and is intended for the Tang Primer 20K dock.

### Memory map

| Region | Address range | Size | Notes |
| --- | --- | --- | --- |
| BSRAM | `0x0000_0000..0x0000_7FFF` | 32 KiB | boot region, initialised from `boot_program.hex` |
| DDR3 | `0x0800_0000..0x0FFF_FFFF` | 128 MiB | the card image lands here at boot |

### Clock domains

| Clock | Frequency | Used by |
| --- | --- | --- |
| `clk27` | 27.000 MHz | CPU, bus, arbiter, BSRAM, microSD, image fetch |
| `pclk` | 99.563 MHz | DDR3 controller command/data path |
| `ck` / `fclk` | 398.25 MHz | DDR3 DRAM interface and serialiser (DDR3-800) |
| `serial_clk` | 371.25 MHz | HDMI TMDS serialiser |
| `pix_clk` | 74.25 MHz | raster, TMDS encoders, frame source |

Crossings: bus-to-DDR3 through `ddr3_cdc` (a two-toggle handshake,
payload latched before the toggle moves); image data `clk27`-to-`pix_clk`
through `async_fifo` (grey-coded pointers, combinational read data).
Both are excluded from timing analysis as protocol CDCs.

## Getting data in: the microSD path

The dock's microSD slot is wired to the FPGA in SPI mode, and the card
is how data reaches DDR3: there is no assembler yet, so there is no
software that could copy a dataset, and the loader is hardware instead.

- `sd_spi_master.sv` clocks bytes on the four card pins (SPI mode 0),
  full duplex, with a divider the protocol layer rewrites between phases.
- `sd_controller.sv` speaks the card's protocol: the wake-up sequence
  (CMD0, CMD8, CMD55+ACMD41 until the card is ready, CMD58, CMD16) and
  then CMD17 block reads with the 0xFE data token. Every wait is bounded
  and every failure has a code.
- `sd_loader.sv` is the boot-time bus master. It warms the DDR3 window
  up with one read first, so a PHY that is still calibrating cannot
  swallow payload, then reads the header and streams the payload in.
- `memory_sd.sv` wraps those three; `system.sv` instantiates it when
  `SD_ENABLE` is set, on arbiter slot 2. The loader is idle once a load
  finishes, so a later compute block can share that slot behind a valid
  gate.

### Card image

`tools/mnist_pack.py` turns MNIST IDX files into the raw image the
loader expects. Block 0 is a header of little-endian 32-bit words:

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

The payload is the images (one byte per pixel, record after record)
followed by the labels (one per record), padded to a block boundary.
The loader checks words 0..3 and refuses anything that does not fit the
window; the rest is for whatever reads the data out of DDR3 later.

```sh
python3 tools/mnist_pack.py \
    --images data/mnist/train-images.idx3-ubyte \
    --labels data/mnist/train-labels.idx1-ubyte \
    --out mnist.img
sudo dd if=mnist.img of=/dev/sdX bs=512 conv=fsync   # a dedicated card
```

The FPGA only ever *reads* the card: data gets onto it from a PC with
`dd`, written to the raw device with no filesystem. Anything already on
the card is overwritten from block 0. For a card that has to keep its
filesystem, build the image with `--dest-offset`, write it with
`dd ... seek=<LBA>`, and set `HDR_LBA` in `fpga_top`'s `memory_sd`
instantiation to the same LBA.

### Card speed

The card runs at 397 kHz during initialization and 13.5 MHz during data
transfer. SPI carries one bit per clock, so 13.5 MHz gives a raw ceiling
of 1.69 MB/s; one CMD17 per 512-byte block plus command, response,
token, CRC, tail, and byte-engine handshake overhead lands the payload
rate a little under that. The 60,000-image training set (47 MB) loads in
about 30 seconds.

The DDR3 write path is not what limits a load: a benchmark in
`ddr3_target_tb.sv` measures sequential writes through the adapter and
its clock crossing at 7.19 MiB/s — roughly five times the card path.

The dock routes all four SD data pins, but this RTL uses them as SPI
MISO, MOSI, CS, and clock. A native four-bit bus at 50 MHz would have a
raw ceiling of 25 MB/s; 50 MB/s needs SDR50 at 1.8 V signaling, which
the board's 3.3 V banks do not provide — and a four-bit card would need
the DDR3 write path widened first (it moves one 32-bit word as two
serial 16-bit commands, one transaction at a time).

### Card failures

Every wait in the path is bounded, so a missing card, a card that never
answers, or an image that does not fit fails instead of hanging. The
controller reports `sd_err_code`:

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

## Getting data out: the HDMI display path

The viewer shows one MNIST record at a time, upscaled and centred on a
720p screen. Everything runs in `mnist_view_top`, which wraps the SoC
and adds the video half:

1. `mnist_fetch` is a bus master on the arbiter's spare slot. One
   `fetch_tick` copies one record — 28x28 image bytes plus its label —
   from DDR3 into BSRAM, then reads it back and pushes it byte by byte
   into `async_fifo`. A record is only fetched once the pixel side has
   taken the previous one, so the fifo never holds more than one image.
   Record order wraps at the count in the card header, so the display
   runs forever.
2. `mnist_frame_source` runs in the pixel domain. During vertical
   blanking it drains the fifo into an image store, latching the
   record's label byte last; during the active area it scans the store
   out at 16x16 nearest-neighbour upsampling — 448x448 screen pixels,
   centred — with the background filling the rest.
3. `hdmi_timing` generates the 720p60 raster (CEA-861) and a one-cycle
   `vblank_start` pulse marking the drain window.
4. `hdmi_tx` serialises TMDS: three `hdmi_tmds_encoder`s (DVI 8b/10b
   encoding with running disparity) and four `hdmi_tmds_serializer`s
   (Gowin's OSER10 hard macro, 10:1), plus the clock channel's fixed
   1111100000 pattern. Each pair leaves the chip as one net that the
   `.cst` maps onto the two pins of the board's differential pair.

The backend is pure RTL plus Gowin hard macros (rPLL, CLKDIV, OSER10 —
the same primitives the DDR3 PHY uses). No IDE-generated IP is
involved, so the same files synthesize and simulate.

### Display rate

The rate is `MAX_RATE >> rate_step` — a divisor of the refresh rate, so
no setting can outrun the screen. Reset lands on the slowest step, so
bring-up never races the display:

| `rate_step` | 0 | 1 | 2 | 3 | 4 | 5 |
| --- | --- | --- | --- | --- | --- | --- |
| images per second | 60 | 30 | 15 | 7 | 3 | 1 |

`btn_n2` (double) and `btn_n3` (half) step either way and hold at the
ends, never wrapping.

## Build, simulate, flash

### Prerequisites

- Gowin EDA (V1.9.9 or later) for synthesis, place-and-route, and the
  bitstream; the device is GW2A-LV18PG256C8/I7.
- Icarus Verilog (12.x) for the regression.
- Python 3 for `tools/mnist_pack.py`.
- Optional, for the slowest test only: Gowin's `prim_sim.v` primitive
  models and Micron's DDR3 model — `src/sim/vendor/README.md` says where
  to put them. The regression skips that test when they are absent.

### Simulate

One test by hand:

```sh
iverilog -g2012 -s system_tb -f filelist.f \
    src/sim/testbench/soc/system_tb.sv -o /tmp/system_tb.out
vvp /tmp/system_tb.out
```

The whole regression:

```sh
./run.sh --no-gui
```

Sixteen tests, all green, in a couple of minutes (the DDR3 controller
test against Micron's model takes the bulk of that). Every test prints
`PASS:` or `FAIL:` with its check count; the runner moves the VCD
waveforms to `src/sim/waveforms/` unless `--no-gui`.

What the tests prove:

| Test | What it proves |
| --- | --- |
| `pkg_checks` | word geometry and opcode widths |
| `alu_tb` | the ALU against a reference model (14,510 checks) |
| `cpu_tb` | a program retires correctly |
| `system_tb` | bus arbitration, BSRAM store/load |
| `ddr3_cdc_tb` | the clock crossing under unrelated clocks |
| `ddr3_target_tb` | the adapter contract, and the write benchmark |
| `sd_spi_master_tb` | SPI byte engine, both card speeds |
| `sd_controller_tb` | the wake-up sequence and every error path |
| `sd_loader_tb` | the loader against a stalling bus |
| `sd_image_tb` | a real packer image lands byte for byte |
| `memory_map_tb` | decode of every window |
| `button_debounce_tb` | bounce rejection, one pulse per press, polarity |
| `mnist_rate_tb` | the rate ladder, both buttons, both ends |
| `mnist_frame_source_tb` | blanking drain, upscale, centre, background |
| `mnist_view_tb` | DDR3 to BSRAM to fifo to screen, byte for byte |
| `ddr3_controller_tb` | the real controller against Micron's model |

### Flash

Open `cooda.gprj` in Gowin EDA, run synthesis, place-and-route, and
program the device — or drive the flow from the command line. The
resulting bitstream is `impl/pnr/cooda.fs`. The SDC reports zero
violations on all five clock domains.

## The board: buttons, LEDs, pins

### Controls

- **S1** (`btn_n0`, pin T3) resets the CPU, the microSD path, and the
  video path.
- **S2** (`btn_n1`, pin T2) pauses the CPU while held — the display
  keeps running.
- **Rate buttons** sit on header pins **T12** (`btn_n2`, show images
  faster) and **T11** (`btn_n3`, show images slower): jumper each to
  ground for a press. The dock only carries the two tactile buttons, so
  the viewer's buttons live on headers.

### Status LEDs (active low: lit means the condition is false)

| LED | Lit means | Out means |
| --- | --- | --- |
| led0 | no recent CPU activity | instructions retired recently |
| led1 | DDR3 write levelling not done | write levelling done |
| led2 | DDR3 read calibration not done | read calibration done |
| led3 | the card never answered the wake-up | the card initialised |
| led4 | the card image is not (yet) in DDR3 | the image loaded |
| led5 | something failed | nothing failed |

Useful combinations: led1+led2 lit together means DDR3 calibration never
finished; led3 stuck lit means the card never initialised; led4 lit
after led3 went out means the load stopped part way. The four-bit error
codes (`sd_err_code`, `load_err_code`) and the controller's FSM state
stay in simulation — a waveform, or an added debug pin, says *why*.

### Pins

The microSD slot is wired in SPI mode on `sd_cs_n` (N11), `sd_sck` (N10),
`sd_mosi` (R14), and `sd_miso` (M8) — the mapping LiteX-Boards uses for
this dock. The slot also has DAT1 (M7), DAT2 (M10), and card detect
(D15) wired; SPI mode uses none of them. The HDMI connector carries the
four TMDS pairs: clock on G16/H15, data on H14/H16, J15/K16, K14/K15.
Three of the SD pins share bank 2 with the DDR3 and run at its 1.5 V
rail; `sd_miso` sits in a 3.3 V bank.

The physical assignments, including all of DDR3, are in
`src/constraints/sipeed_tang_primer_20k.cst`; the clock and generated
clock constraints are in the matching `.sdc`. The DDR3 pin map and PHY
follow the [upstream Tang Primer 20K implementation](https://github.com/nand2mario/ddr3-tang-primer-20k).

### Timing constraints

The SDC names the PLL outputs explicitly: DDR serializer `fclk` at
398.25 MHz, controller `pclk` at 99.563 MHz, phase-shifted DDR `ck` at
398.25 MHz, TMDS serializer clock at 371.25 MHz, and pixel clock at
74.25 MHz. It excludes the protocol CDC paths (`clk27`/`pclk` and
`clk27`/pixel) and the hard-macro clock-to-clock interfaces (the DDR PHY
and the OSER10 serialisers); same-clock fabric paths remain timed.

## First flash: what to expect

1. **led1/led2** go out first — DDR3 calibration finished and the reset
   released. If they stay lit, the DDR3 clock or PHY never came up.
2. **A monitor on the HDMI port shows a uniform grey screen** — the
   raster is running, no image fetched yet. This is the first unproven
   link on real hardware; a working grey screen means the PLL, the
   serialisers, and the pin mapping are all alive.
3. **led3 goes out** when the card answers; **led4** follows when the
   payload is in DDR3.
4. **A first MNIST digit appears about a second later** — 448x448,
   centred — and the display then advances one record per second.
5. **T12/T11 jumpered to ground** double and halve that rate.

If the screen stays grey with the load complete, the display fetch
chain is not running on hardware — check that `view_req` survived
synthesis connected (it was once reported unconnected, and a swept
button path is the tell-tale).

## Known limits

- The display path has not been shown on a real monitor yet; the HDMI
  backend is the part to watch at bring-up (the serialiser follows the
  vendor primitive guide, but the screen is the judge).
- The microSD path is one bit wide and clocked at 13.5 MHz, so no
  change to the divider can make it faster than about 3.1 MB/s. A 4-bit
  native mode is the next step; 50 MB/s specifically needs 1.8 V SDR50,
  which the board's 3.3 V banks do not provide.
- The DDR3 write path moves one 32-bit word as two 16-bit commands, one
  transaction at a time: 7.19 MiB/s measured.
- There is no assembler and no TPU yet.

## Conventions

- Folder names carry the module prefix: `video/hdmi/` holds `hdmi_*`,
  `memory/sd/` holds `sd_*`. Testbenches mirror the RTL tree under
  `src/sim/testbench/`. Details: [doc/NAMING_CONVENTIONS.md](doc/NAMING_CONVENTIONS.md).
- Every design unit carries a header comment saying what it is for;
  every clock crossing names its mechanism.
- `filelist.f` and `cooda.gprj` must stay in step — the same files, the
  same order.

## References

- [nand2mario/ddr3-tang-primer-20k](https://github.com/nand2mario/ddr3-tang-primer-20k) — the DDR3 PHY this project follows.
- Sipeed's board examples under `examples/` (HDMI, camera-to-HDMI) — the
  TMDS pin mapping and the rPLL/CLKDIV configurations match theirs.
- The [MNIST database](https://yann.lecun.com/exdb/mnist/) — the IDX
  files `tools/mnist_pack.py` consumes.




