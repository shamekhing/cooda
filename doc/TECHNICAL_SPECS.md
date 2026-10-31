# COODA technical specification

Technical details and measured performance of the COODA SoC. Everything
here is read from the RTL,
the constraints, or a test in this repository; numbers that came from a
simulation are marked *measured*, numbers that come from a datasheet or
a configuration are marked *calculated*. Hardware bring-up of the
microSD and UART data paths have not happened yet, so no transfer number
here was measured on a board.

## 1. System overview

COODA is a 32-bit von Neumann SoC for the Sipeed Tang Primer 20K
(Gowin GW2A-LV18PG256C8/I7) with its dock. The CPU issues instruction
and data requests into one shared bus; a round-robin arbiter gives
clients access to one memory subsystem made of an initialised BSRAM
boot region and a 128 MiB DDR3 SDRAM. A hardware loader fills the DDR3
from a PC over UART by default or from a microSD card as an alternative,
so a dataset reaches memory without any CPU software.

Active in the board viewer: CPU, bus, BSRAM, DDR3 (PHY + controller +
adapter), selectable UART/microSD loader, and HDMI display path. The
board defaults to UART; SD is the alternative. GPU, RPU, and TPU are
not instantiated.

## 2. Clock domains

| Clock | Frequency | Used by |
| --- | --- | --- |
| `clk27` | 27.000 MHz | CPU, bus, arbiter, BSRAM, UART, microSD, image fetch |
| `pclk` | 99.563 MHz | DDR3 controller command/data path |
| `ck` / `fclk` | 398.25 MHz | DDR3 DRAM interface and serializer (800 MT/s DDR3) |
| `serial_clk` | 371.25 MHz | HDMI TMDS serialiser (5x the bit pairs) |
| `pix_clk` | 74.250 MHz | raster, TMDS encoders, frame source |

The DDR3 clocks come from `ddr3_pll` off the 27 MHz input. The bus and
the DDR3 controller are unrelated clocks, so every bus transaction
crosses `clk27` to `pclk` through `ddr3_cdc`, a two-toggle handshake
with payloads latched before the toggle moves. There is one outstanding
crossing at a time.

The UART and microSD paths have no separate clock domains. UART is
sampled and driven from `clk27` at 921600 baud by default; the SD card is
clocked from `clk27` through a divider (397 kHz during initialization,
13.5 MHz for data).

The video clocks come from `hdmi_rpll` off the same 27 MHz: 27 MHz x
55/4 = 371.25 MHz for the serialisers, divided by five to 74.25 MHz
for the pixel path. The image crosses from `clk27` to `pix_clk`
through `async_fifo`, a grey-code pointer pair with the read data
decoded combinationally, so the scan-out never stalls a clock domain.

## 3. Memory map

| Region | Range | Size | Notes |
| --- | --- | --- | --- |
| BSRAM | `0x0000_0000..0x0000_7FFF` | 32 KiB | boot region, initialised from `boot_program.hex` |
| DDR3 | `0x0800_0000..0x0FFF_FFFF` | 128 MiB | filled by the selected UART or microSD loader |

Anything else faults with `error` on the responding cycle.

## 4. Bus contract

32-bit, byte-addressed, word-aligned. A request completes when
`valid && ready`; the client holds `valid`, `addr`, `wdata` and `wstrb`
stable until then. One outstanding request per client, no pipelining.
The DDR3 window is little-endian and requires full-word write strobes.
Requests issued before the DDR3 PHY has calibrated are held, not
failed.

Clients: CPU instruction fetch (slot 0), CPU data (slot 1), the
selected UART/microSD loader (slot 2), and the display fetcher (slot 3).
The arbiter is round-robin and holds a grant through a target stall.

## 5. CPU

A single-issue 32-bit core with no pipeline: fetch, decode, execute
(register file to ALU to writeback) with a load writeback multiplexer.
It stalls on an unready bus, which is how it waits for DDR3.

- Register file: 64 x 32-bit, `r0` hardwired to zero.
- Instruction word: 26 bits packed in a 32-bit word -
  `[25] update_status`, `[24] immediate_mode`, `[23:18] opcode`,
  `[17:12] rd`, `[11:6] rs1`, `[5:0] rs2` - with the reserved bits
  checked: a non-zero encoding is reported as `illegal_instr`.
- 49 opcodes: arithmetic (add/adc/sub/sbc/mul/mulh/divu/modu/divs/
  mods/min/max), logical, shifts, comparisons, control flow, and
  load/store. Instructions that need an immediate are followed by one
  complete word.
- Status register updates are explicit (`update_status`).
- Exits: `retire_valid` per retired instruction, `illegal_instr`, and
  a latched `fault`.

## 6. Memory subsystem

### 6.1 BSRAM

A single-cycle block RAM with per-byte write lanes, wrapped as a bus
target. It is the initialised boot memory and the fastest memory in
the system: one `clk27` cycle from request to `ready`.

### 6.2 DDR3

The active `ddrip` branch uses the Gowin DDR3 IP configuration from the
same-board `TP20kExample/DDR-test` project: GW2A-18C, x16 DDR3, a nominal
400 MHz memory clock, and a 1:4 controller ratio. The existing PLL
provides 398.25 MHz; the IP supplies the approximately 99.56 MHz
application clock and `init_calib_complete`. Its controller owns
initialization, PHY calibration, and refresh. User refresh requests are
disabled, as in the example.

The old `ddr3_controller` path remains in the source tree and its
`memory_ddr3` adapter remains covered by `ddr3_target_tb`, but it is no
longer instantiated by the DDR-enabled SoC. The two paths differ:

| | COODA manual controller | Gowin example/IP path |
| --- | --- | --- |
| PHY/control | Vendored PHY primitives and hand-written init/calibration | Gowin DDR3 IP and generated PHY |
| App data width | 16-bit halfword commands | 128-bit app transfers |
| Refresh | COODA schedules explicit refreshes | IP manages refresh |
| Bus mapping | One 32-bit word becomes two halfword commands | One 32-bit word maps to one 128-bit burst, with a 16-byte mask enabling only the addressed four bytes |
| Readiness | `write_level_done` and `read_calib_done` from manual controller | `init_calib_complete` from IP |

`memory_ddr3_gowin` keeps the same 32-bit SoC bus contract and clock
crossing, stalls accesses during IP calibration, and reports a timeout
or invalid access as a bus error. `ddr3_gowin_target_tb` checks
calibration waiting, burst/lane/mask mapping, read-back, invalid
requests, and the app-interface timeout against a behavioral IP model.
Neither adapter simulation is proof of physical DDR operation; only
programming and testing the board can establish that.

## 7. microSD path

The core board's slot (on the SODIMM module, not the dock) is wired in SPI mode on four pins (`sd_cs_n` N11,
`sd_sck` N10, `sd_mosi` R14, `sd_miso` M8); DAT1, DAT2 and card detect
are routed but unused. Three layers, all clocked from `clk27`:

1. `sd_spi_master` clocks bytes in SPI mode 0, full duplex, with a
   divider the protocol layer rewrites between phases.
2. `sd_controller` owns chip select and the card's protocol: 80 idle
   clocks, CMD0, CMD8 (check pattern 0x1AA, echo checked), CMD55 +
   ACMD41 until ready, CMD58 (CCS decides sector vs byte addressing),
   CMD16, then CMD17 per 512-byte block with the 0xFE data token.
   Every wait is bounded; every failure raises a code.
3. `sd_loader` is a boot-time bus master. It warms the DDR3 window up
   with one read (so a PHY that is still calibrating cannot swallow
   payload), reads the header, validates it, then streams the payload
   into DDR3.

Rates, *calculated* from the configuration and confirmed by the
regression's timing:

| Quantity | Value |
| --- | --- |
| Card clock, init | 397 kHz |
| Card clock, data | 13.5 MHz |
| Wire ceiling | 1.69 MB/s |
| Payload, with one CMD17 per block | about 1.6 MB/s |
| Full 60,000-image training set (47.1 MB) | about 30 s |

The card image is raw blocks, no filesystem. Block 0 is a header of
little-endian 32-bit words: magic `COOD` (`0x434F_4F44`), payload
blocks, destination byte offset in the DDR3 window, payload bytes,
record count, image rows, image columns, label bytes per record, and a
payload checksum. The loader checks the first four and refuses a
payload that does not fit the window.

Error codes, from `sd_controller` (`sd_err_code`): 1 CMD0 not
answered or not 0x01, 2 CMD8 echo wrong, 3 ACMD41 not answered or the
card never came ready, 4 CMD58 failed, 5 CMD16 failed, 6 CMD17 failed,
7 no 0xFE token. From `sd_loader` (`load_err_code`): 1 the card
failed, 2 bad magic, 3 bad block count, 4 the destination does not fit
the window, 5 a payload word arrived while the bus was busy.

`tools/mnist/mnist_pack.py` builds the image from MNIST IDX files and
verifies its own output; the full training set is 91,992 blocks.

### UART upload alternative

`mnist_uart_loader` is the default board loader and shares slot 2 with
the SD loader; only one is selected at build time. It waits for the DDR3
calibration-ready signal, sends `R`, receives the same fixed 512-byte
COOD header and then exactly the true payload-byte count, writes
little-endian full words to DDR3, zero-pads only the final partial word,
and verifies the additive payload checksum before sending `D`.

The UART is 8N1, LSB-first, at 921600 baud by default, using the
`clk27` domain. A 60,000-record MNIST payload is about 47.1 MB. UART
wire time is about 8.5 minutes at the configured baud (calculated as
10 serial bits per byte); actual host transfer time also depends on the
USB-UART bridge. `tools/mnist/mnist_uart_send.py` waits for `R`, sends the
packed header and unpadded payload, then checks the completion status.
Install `pyserial` on the host to use the script.

The loader reports `E` followed by one binary code: 1 bad magic, 2
inconsistent block/byte count, 3 invalid destination, 4 checksum
mismatch, 5 receive timeout, 6 DDR3 bus error. A timeout before any
header data causes `R` to be resent; timeout partway through a transfer
is an error. Loader simulation covers successful writes, bad magic,
checksum mismatch, and partial-header timeout. Physical UART transfer
has not yet been verified.

## 8. Display path

The viewer shows one MNIST record at a time, upscaled and centred on a
720p screen, at a rate the two extra buttons control. Everything runs
in `mnist_view_top`, which wraps the SoC and adds the video half:

1. `mnist_fetch` is a bus master on the CPU's arbiter (the slot the
   TPU will take later). One `fetch_tick` copies one record - 28x28
   image bytes plus its label - from DDR3 into BSRAM, then reads it
   back and pushes it byte by byte into `async_fifo`. A record is only
   fetched once the pixel side has taken the previous one, so the fifo
   never holds more than one image. Record order wraps at the count in
   the header, so the display runs forever.
2. `mnist_frame_source` runs in the pixel domain. During vertical
   blanking it drains the fifo into an image store, latching the
   record's label byte last; during the active area it scans the store
   out at SCALE x SCALE nearest-neighbour upsampling (default 16, so
   448x448 screen pixels), centred, with the background filling the
   rest.
3. `hdmi_timing` generates the 720p60 raster (CEA-861: 1650x750
   total, `frame_start` and a one-cycle `vblank_start` pulse marking
   the drain window).
4. `hdmi_tx` serialises TMDS: three `hdmi_tmds_encoder`s (8b/10b DVI
   encoding with running disparity) and four `hdmi_tmds_serializer`s
   (Gowin's OSER10 hard macro, 10:1), plus the clock channel's
   1111100000 pattern. A Gowin `TLVDS_OBUF` drives each true
   differential output pair; the `.cst` assigns `LVDS25` and the
   positive-side pin locations.

Rate control (`mnist_rate`): the rate is `MAX_RATE >> rate_step` - a
divisor of the refresh rate, so no setting can outrun the screen. The
two buttons step the exponent and hold at the ends, never wrapping:

| Buttons | Rate at 60 Hz |
| --- | --- |
| fastest (reset value is the slowest) | 60, 30, 15, 7, 3, 1 image/s |

`btn_n2` doubles, `btn_n3` halves; the dock only carries two tactile
buttons, so the rate buttons sit on header pins T12 and T11 - jumper
each to ground for a press.

The HDMI backend is RTL plus Gowin hard macros (rPLL, CLKDIV, OSER10,
and TLVDS_OBUF - the same primitive library used by the DDR3 PHY). It needs no IDE
generated IP, so it both simulates under Icarus and commits.

## 9. Board I/O

| Signal | Pin | Notes |
| --- | --- | --- |
| `clk27` | H11 | 27 MHz |
| `btn_n0` | T3 | reset (CPU, selected loader, and video) |
| `btn_n1` | T2 | run / pause |
| `led0..led5` | P15, N15, N14, L14, R16, P16 | active low, board indices 0..5 |
| DDR3 | A/B/J/G/K/R/L/P/M/F/C/E columns | SSTL15, see the `.cst` |
| microSD | N11, N10, R14, M8 | SPI mode |
| UART | T13, M11 | USB-UART RX, TX |

Physical LEDs are active low. The board RTL drives active-low indications:
lit led0 means the DDR PLL is unlocked; lit led1 means DDR calibration is
incomplete; lit led2 means a DDR bus error was recorded; lit led3 means the
Gowin app engine is active; lit led4 means the image has loaded; and lit led5
means the app engine is in its read state. A dark led2 means no
sticky bus error has been recorded. The four-bit error codes are on `system`'s
ports, not on pins.

## 10. Implementation results

From the Gowin synthesis and place-and-route reports in `impl/` (the
`.cst`/`.sdc` pair in `src/constraints/`, device GW2A-LV18PG256C8/I7):

- The pre-video run reported worst setup slack +1.891 ns and worst hold
  slack +0.334 ns: zero violations at the documented clocks. The video
  path grew the design, so re-generate the reports and re-check rather
  than trusting numbers quoted here.
- Resource use is dominated by the DDR3 PHY primitives and the
  controller; the CPU is small by comparison. Re-generate the reports
  after each RTL change rather than trusting numbers quoted here.

## 11. Verification

`./run.sh --no-gui` runs the available regression suites:

| Test | What it proves |
| --- | --- |
| `pkg_checks` | word geometry and opcode widths |
| `alu_tb` | the ALU against a reference model (14,510 checks) |
| `cpu_tb` | a program retires correctly |
| `system_tb` | bus arbitration, BSRAM store/load |
| `ddr3_cdc_tb` | the clock crossing under unrelated clocks |
| `ddr3_target_tb` | the adapter contract, and the write benchmark |
| `ddr3_gowin_target_tb` | Gowin app-interface lane mapping, masks, calibration wait, and timeout |
| `uart_tb` | UART byte loopback and framing-error rejection |
| `mnist_uart_loader_tb` | UART image upload, DDR word packing, checksum, timeout, and error status |
| `sd_spi_master_tb` | SPI byte engine, both card speeds (619 checks) |
| `sd_controller_tb` | the wake-up sequence and every error path (45 checks) |
| `sd_loader_tb` | the loader against a stalling bus (26 checks) |
| `sd_image_tb` | a real packer image lands byte for byte |
| `memory_map_tb` | decode of every window |
| `mnist_rate_tb` | the rate ladder, both buttons, both ends |
| `mnist_frame_source_tb` | blanking drain, upscale, centre, background |
| `mnist_view_tb` | DDR3 to BSRAM to fifo to screen, byte for byte |
| `ddr3_controller_tb` | the real controller against Micron's model |

## 12. Known limits

- A full MNIST upload over 921600-baud UART takes approximately 8.5
  minutes on the wire; the USB-UART bridge and host add overhead.
- The microSD path is one bit wide and is clocked at 13.5 MHz, so no
  change to the divider can make it faster than about 3.1 MB/s. A
  4-bit native mode is the next step, and 50 MB/s specifically needs
  1.8 V SDR50, which the board's 3.3 V banks do not provide.
- The DDR3 write path moves one 32-bit word as two 16-bit commands,
  one transaction at a time: 7.19 MiB/s measured.
- The display path has not been shown on a real monitor yet; the HDMI
  backend is the part to watch at bring-up (the serialiser follows the
  vendor primitive guide, but the screen is the judge).
- There is no assembler and no TPU yet.
