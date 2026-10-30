# COODA technical specification

Technical details and measured performance of the COODA SoC as it
stands on the `sdcard` branch. Everything here is read from the RTL,
the constraints, or a test in this repository; numbers that came from a
simulation are marked *measured*, numbers that come from a datasheet or
a configuration are marked *calculated*. Hardware bring-up of the
microSD path has not happened yet, so no number here was measured on a
board.

## 1. System overview

COODA is a 32-bit von Neumann SoC for the Sipeed Tang Primer 20K
(Gowin GW2A-LV18PG256C8/I7) with its dock. The CPU issues instruction
and data requests into one shared bus; a round-robin arbiter gives
clients access to one memory subsystem made of an initialised BSRAM
boot region and a 128 MiB DDR3 SDRAM. A hardware loader fills the DDR3
from a microSD card at boot, so a dataset reaches memory without any
software.

Active: CPU, bus, BSRAM, DDR3 (PHY + controller + adapter), microSD
loader. Inactive and not instantiated: GPU, video output, RPU, TPU.

## 2. Clock domains

| Clock | Frequency | Used by |
| --- | --- | --- |
| `clk27` | 27.000 MHz | CPU, bus, arbiter, BSRAM, microSD |
| `pclk` | 99.563 MHz | DDR3 controller command/data path |
| `ck` / `fclk` | 398.25 MHz | DDR3 DRAM interface and serialiser (DDR3-800) |

The DDR3 clocks come from `ddr3_pll` off the 27 MHz input. The bus and
the DDR3 controller are unrelated clocks, so every bus transaction
crosses `clk27` to `pclk` through `ddr3_cdc`, a two-toggle handshake
with payloads latched before the toggle moves. There is one outstanding
crossing at a time.

The microSD path has no clock of its own: the card is clocked from
`clk27` through a divider (397 kHz while the card wakes up, 13.5 MHz
for data).

## 3. Memory map

| Region | Range | Size | Notes |
| --- | --- | --- | --- |
| BSRAM | `0x0000_0000..0x0000_7FFF` | 32 KiB | boot region, initialised from `boot_program.hex` |
| DDR3 | `0x0800_0000..0x0FFF_FFFF` | 128 MiB | filled by the microSD loader |

Anything else faults with `error` on the responding cycle.

## 4. Bus contract

32-bit, byte-addressed, word-aligned. A request completes when
`valid && ready`; the client holds `valid`, `addr`, `wdata` and `wstrb`
stable until then. One outstanding request per client, no pipelining.
The DDR3 window is little-endian and requires full-word write strobes.
Requests issued before the DDR3 PHY has calibrated are held, not
failed.

Clients: CPU instruction fetch (slot 0), CPU data (slot 1), the
microSD loader (slot 2), and slot 3 free for the TPU. The arbiter is
round-robin and holds a grant through a target stall.

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

The DRAM is a 1 Gbit x16 DDR3 at DDR3-800 (400 MHz, both edges), which
is 1.6 GB/s of raw pin bandwidth. The controller is the vendored
nand2mario design: it drives Gowin's `DQS`, `OSER8`/`OSER8_MEM` and
`IDES8_MEM` PHY primitives, runs the command path at `pclk`, and does
power-up init, ZQ calibration, write levelling and read calibration
before it accepts traffic; the adapter holds requests until then.

The client interface is one 16-bit halfword per command, one command
at a time. From the controller's own timing diagram:

| Operation | Cost | Rate |
| --- | --- | --- |
| 16-bit read | 9 `pclk` cycles | about 22-25 MB/s |
| 16-bit write | about 24 `pclk` cycles (a BC4 burst masks three of its four halfwords) | about 8-9 MB/s |

One 32-bit bus write therefore becomes two serial 16-bit commands, and
the adapter's clock crossing adds a round-trip. `ddr3_target_tb`
measures the pair end to end: **7.19 MiB/s** of sequential 32-bit
writes (962 `clk27` cycles for 64 words), *measured against a
behavioral controller*, so it covers RTL transaction overhead and says
nothing about PHY or DRAM timing.

Widening this path is the cheapest speed-up in the system: batching
two adjacent bus words into one BC4 burst would roughly halve the
write cost, and a 4-bit or 8-bit client interface would raise it
further. Nothing here bounds the *read* side below about 22 MB/s.

## 7. microSD path

The dock's slot is wired in SPI mode on four pins (`sd_cs_n` N11,
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

`tools/mnist_pack.py` builds the image from MNIST IDX files and
verifies its own output; the full training set is 91,992 blocks.

## 8. Board I/O

| Signal | Pin | Notes |
| --- | --- | --- |
| `clk27` | H11 | 27 MHz |
| `btn_n0` | T3 | reset (CPU and microSD) |
| `btn_n1` | T2 | run / pause |
| `led0..led5` | N16, N14, L14, L16, C13, A13 | active low |
| DDR3 | A/B/J/G/K/R/L/P/M/F/C/E columns | SSTL15, see the `.cst` |
| microSD | N11, N10, R14, M8 | SPI mode |

LED meaning, active low: led0 CPU activity, led1 DDR3 write levelling
done, led2 DDR3 read calibration done, led3 the card initialised,
led4 the image is in DDR3, led5 nothing failed. The four-bit error
codes are on `system`'s ports, not on pins.

## 9. Implementation results

From the Gowin synthesis and place-and-route reports in `impl/` (the
`.cst`/`.sdc` pair in `src/constraints/`, device GW2A-LV18PG256C8/I7):

- Worst setup slack +1.891 ns, worst hold slack +0.334 ns: zero
  violations at the documented clocks.
- Resource use is dominated by the DDR3 PHY primitives and the
  controller; the CPU is small by comparison. Re-generate the reports
  after each RTL change rather than trusting numbers quoted here.

## 10. Verification

`./run.sh --no-gui` runs twelve tests, all green:

| Test | What it proves |
| --- | --- |
| `pkg_checks` | word geometry and opcode widths |
| `alu_tb` | the ALU against a reference model (14,510 checks) |
| `cpu_tb` | a program retires correctly |
| `system_tb` | bus arbitration, BSRAM store/load |
| `ddr3_cdc_tb` | the clock crossing under unrelated clocks |
| `ddr3_target_tb` | the adapter contract, and the write benchmark |
| `sd_spi_master_tb` | SPI byte engine, both card speeds (619 checks) |
| `sd_controller_tb` | the wake-up sequence and every error path (45 checks) |
| `sd_loader_tb` | the loader against a stalling bus (26 checks) |
| `sd_image_tb` | a real packer image lands byte for byte |
| `memory_map_tb` | decode of every window |
| `ddr3_controller_tb` | the real controller against Micron's model |

## 11. Known limits

- The microSD path is one bit wide and is clocked at 13.5 MHz, so no
  change to the divider can make it faster than about 3.1 MB/s. A
  4-bit native mode is the next step, and 50 MB/s specifically needs
  1.8 V SDR50, which the board's 3.3 V banks do not provide.
- The DDR3 write path moves one 32-bit word as two 16-bit commands,
  one transaction at a time: 7.19 MiB/s measured.
- There is no video output, no assembler, and no TPU yet.
