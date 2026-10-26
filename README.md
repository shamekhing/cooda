# LACOODA RTL  Restructure Notes

This package is the restructured LACOODA SoC RTL for the Sipeed Tang
Primer 20K (Gowin GW2A-18C). It covers the CPU, the routing processing
unit (RPU), memory, the GPU (a bus-activity visualiser, not a 3D
pipeline), the video and HDMI backends, and the top-level SoC. The TPU is
not linked yet.

Compile order and file list: `filelist.f`. Elaboration target: `fpga_top`.

## Layout

```
packages/   arch_pkg, isa_pkg, alu_pkg, soc_pkg, gpu_pkg
rpu/        rpu.sv, rpu_slave_port.sv
memory/     memory_bsram.sv, memory_ddr3.sv, memory_ddr3_phy.sv, memory.sv
gpu/        gpu.sv, gpu_registers.sv, gpu_bus_mon.sv, gpu_pixel_engine.sv
video/      video_rpll.v, video_timing.sv, pattern_gen.sv, video_lcd.sv
hdmi/       hdmi_rpll.v, hdmi_tmds_encoder.sv, hdmi_tmds_serializer.sv, hdmi_tx.sv
cpu/        cpu.sv, alu/, core/, program/ (every file carries the cpu_ prefix)
soc/        system.sv, fpga_top.sv
programs/   boot_program.hex (ROM image), check_program.py (disassembler/validator)
sim/        pkg_checks.sv, rpll_sim.v, hdmi_prim_sim.v (simulation-only)
migrate.sh  renames package symbols in an older RTL tree (non-destructive)
```

## Package structure

Dependency order: `arch -> isa, alu, soc -> gpu`.

| Package | Contents |
|---|---|
| `arch_pkg` | Word type, register-file geometry, `flags_s`, `make_flags()`. Carries the project-wide `timescale`, so it compiles first. |
| `isa_pkg` | Opcodes, instruction format, classifiers, encoders. |
| `alu_pkg` | Constants and helpers shared by ALU sub-units. |
| `soc_pkg` | Bus protocol, memory sizes, address map, routing, DDR3 app interface, map validation. |
| `gpu_pkg` | GPU register map, config and status structs, pixel types. |

Validation functions that used `$fatal` moved to `sim/pkg_checks.sv`, so the
packages stay synthesizable.

## Naming conventions

- **Files:** one module per file, named after the module, and every file in a block carries that block's prefix (`cpu_alu.sv` holds `cpu_alu`, `cpu_program.sv` holds `cpu_program`). Packages end in `_pkg.sv`.
- **Types:** `_t` for scalar and vector typedefs, `_s` for packed structs, `_e` for enums.
- **Constants:** `UPPER_SNAKE`, with units in the suffix (`_BYTES`, `_WORDS`, `_WIDTH`, `_COUNT`).
- **Address map:** `MAP_<REGION>_BASE` and `MAP_<REGION>_MASK`, where mask = size − 1.
- **Members and functions:** domain-prefixed (`BusRead`, `isa_encode_load`, `route_data`). Enum members take a short prefix from the type name: `OpAdd` in `opcode_e`, `CtlIdle` in `control_state_e`, `StIdle` in a module-local `state_e`.
- **Ports:** `_req` / `_rsp` pairs, named after the master or slave role.
- **Clocks and resets:** `clk` (the only SoC clock), `rst` active-high. The DDR3 controller derives its own DDR clock at `clk/2`.
- **State:** `_q` for registered values, `_d` for the combinational value that feeds them, `_sync_q` for synchronizers. Every flop has exactly one `_d`, computed in an `always_comb` block that holds by default and overrides per state.

## Bus protocol

- 32-bit words, byte-addressed, word-aligned.
- `bus_req_s`: `valid`, `op`, `addr`, `wdata`, `wstrb`.
- `bus_rsp_s`: `ready`, `rdata`, `error`.
- Completion on a rising edge when `req.valid && rsp.ready`. The master holds its request stable until completion.
- The RPU guarantees that a slave only sees valid, aligned, in-range requests with slave-local addresses. Slaves do no address checks of their own. The one exception is ROM, which returns an error on writes.

## Address map

| Region | Base | Size | Slave | Seen by |
|---|---|---|---|---|
| ROM | `0x0000_0000` | 32 KiB | ROM | CPU instruction |
| DATA_RAM | `0x0000_0000` | 32 KiB | DATA_RAM | CPU data, GPU, TPU |
| GPU_MMIO | `0x1000_0000` | 4 KiB | GPU_MMIO | CPU data, GPU, TPU |
| DDR3 | `0x8000_0000` | 128 MiB | DDR3 | CPU data, GPU, TPU |

- ROM and RAM overlap at 0 on purpose: the instruction master sees ROM, and data masters see RAM.
- TPU/DMA/SD/SYSTEM MMIO ranges (`0x1000_1000`–`0x1000_5000`) are not implemented. Accesses there return a bus error.
- Each region is a power-of-two size on a size-aligned base. Decode is a masked prefix compare, and the slave-local address is `addr & MASK`.

## RPU

`rpu.sv` is a fixed 4 masters × 4 slaves fabric.

- **Masters:** `cpu_i`, `cpu_d`, `gpu`, `tpu`. Each has a `_req` / `_rsp` pair.
- **Slaves:** `rom`, `ram`, `gpu_mmio`, `ddr3`. Each has a `_req` / `_rsp` pair.
- Each request is decoded to a one-hot slave select. An unaligned, unmapped, reserved, or invisible request is answered immediately with an error and never reaches a slave.
- Each slave has its own `rpu_slave_port`:
  - round-robin arbitration, implemented as a rotating priority mask and a lock register;
  - the grant is held until the slave completes, so a higher-priority master cannot steal a transaction in flight;
  - the request mux is AND-OR on the one-hot grant.
- A response is delivered only to the master that owns the slave, so `ready` never reaches the wrong master.

The fabric is fixed at 4×4 because Icarus Verilog 12 cannot elaborate
unpacked-array parameters, 2-D arrays, or array slices. Adding a slave means
adding a `SLAVE_*` index, a decode line, a mask, and an `rpu_slave_port`
instance.

## Memory

- **`memory_bsram`:** one physical block RAM, used twice: as the ROM slave and the RAM slave. Single-port, byte-write-enabled, one-cycle latency. Loaded from `INIT_FILE`, or left unloaded if the parameter is empty. Read-only protection for the code region comes from the address map (only the instruction master is routed there), not from the memory.
- **`memory_ddr3`:** RPU slave and width adapter for the DDR3 controller. The bus is 32-bit; the controller moves one 16-bit halfword per beat, so every access is two beats (little-endian: low halfword first).
  - One clock domain: `memory_ddr3_phy` runs on `clk` and generates its own DDR clock at `clk/2`, so there is no crossing to constrain.
  - Until the controller reports init done, every access returns a bus error rather than hanging.
  - Only full-word writes: the controller has no sub-halfword write mask, so a partial strobe is answered with a bus error. The CPU always writes `BUS_STRB_ALL`.
  - `rsp.ready` is a single-cycle pulse, so the master drops `req.valid` after completion (the RPU and CPU do).
- **`memory_ddr3_phy`:** the DDR3 controller itself, vendored (BSD-3) from `ZiyangYE/General-Slow-DDR3-Interface`, precompiled for a 128M x 16b DDR3. No burst: row activate and auto-precharge around every 16-bit beat. `sysIO_address` is the raw `{row, bank, column}` of the halfword being transferred. It is the only file in the tree that is not written to this project's own style, and it must not be edited  regenerate from the upstream `.scala`.
- **`memory`:** instantiates the two `memory_bsram` blocks and `memory_ddr3`, and passes the DDR3 pins up to the top level.

## CPU

The CPU is split into an instruction unit and an execution core.

- `cpu.sv` exposes `instr_req/rsp` and `data_req/rsp` as RPU masters, and it latches `fault` on a bus error or an illegal instruction.
- `program/cpu_program.sv` is the instruction unit: `cpu_pc`, `cpu_fetch`, `cpu_decoder` and `cpu_branch`. The fetch -> decode -> branch -> pc loop is closed inside it. It hands the core one decoded instruction (`isa_pkg::program_ctrl_s`).
- `program/cpu_fetch.sv` owns `cpu_pc`, drives `instr_req/rsp` (read-only) and buffers the instruction plus its immediate word.
- `core/cpu_core.sv` executes that bundle and owns the `data_req/rsp` master. It exposes `operand_a/operand_b` so `cpu_branch` compares the same values the ALU sees.
- `core/cpu_status_register.sv` holds only the ALU flags (`flags_s`). The 32-bit STATUS word was not read anywhere else.
- The decoder uses `INSTRUCTION_BITS` in place of the old `USED_INSTRUCTION_BITS`.
- The `timescale` directive is removed from individual files. Only `arch_pkg.sv` carries it.

## GPU  bus activity visualiser

The first GPU is not a 3D pipeline: it is a visualiser, so a running program can be *seen*.

- `gpu/gpu_registers.sv` is the real `GPU_MMIO` slave (the stub that used to answer every access with a bus error is gone). `RegId`, `RegControl` (visualiser enable, pattern mode, pattern colour, invert), `RegStatus` (activity snapshot the program can poll), the three framebuffer registers as scratch, and `RegClearColor`. One-cycle slave, word-only.
- `gpu/gpu_bus_mon.sv` watches the RPU's passive taps and keeps one saturating 8-bit level per block: masters `cpu_i, cpu_d, gpu, tpu` and slaves `rom, ram, gpu_mmio, ddr3`. **Every tick (~2.4 ms) a block that was active gains pixel area and an idle block loses it**, so tiles grow while their traffic lasts and drain when it stops. Sampling per tick rather than per transaction is what keeps the display animated when the program hammers the bus.
- `gpu/gpu_pixel_engine.sv` renders straight from `x/y`: a header, four master tiles on the left, four slave tiles on the right, and a 4×4 traffic matrix between them whose cell (master, slave) fills with the slave's level and lights its border while that pair is being served. No framebuffer, no memory traffic of its own.
- `gpu/gpu.sv` is the top: MMIO slave and monitor in `clk`, renderer in `pix_clk`, with the levels crossing Gray coded and the configuration crossing as quasi-static double flops.
- `rpu.sv` gained two passive outputs, `mon_m[3:0]` / `mon_s[3:0]`, derived from the existing grants. No behaviour change.

Colours: `cpu_i` white, `cpu_d` yellow, `gpu` cyan, `tpu` green, `rom` magenta, `ram` red, `gpu_mmio` blue, `ddr3` orange. `RegControl[0]` selects the visualiser; with it clear the display shows `pattern_gen` instead, so the board boots into colour bars.

## Video / display

- `video/video_timing.sv`  parameterised active/front-porch/sync/back-porch raster, defaults 720p60 (`1650 x 750`), `de`/`hs`/`vs`/`x`/`y`/`frame_start`. The 800×480 panel timing is the same module with other parameters.
- `video/pattern_gen.sv`  combinational test pattern (8 bars, 32-pixel grid, grey ramp, flat colour, invert). Its name is fixed by the existing `pattern_gen_tb.sv`; it is the only exception to the `video_` prefix in that folder.
- `video/video_lcd.sv`  RGB LCD backend: RGB888→RGB565 and the Dock's parallel pins, with `lcd_dclk` inverted so the panel samples half a pixel period after the data is launched.
- `video/video_rpll.v`  readable wrapper around the Gowin `rPLL` hard primitive, 27 MHz → 40.5 MHz for the 800×480 panel. A hard macro, not IDE-generated IP.
- `fpga_top.sv` holds the pixel-domain reset until `rPLL` reports lock, and `system.sv` carries the raster in and the pixels out.

## HDMI / TMDS (no vendor IP)

`fpga_top` has a `VIDEO_HDMI` parameter. The repository currently builds the
**HDMI backend** (`VIDEO_HDMI = 1`, 720p60); setting it to `0` drives the
RGB LCD instead (800×480, RGB565). Both share the same GPU renderer and
`video_timing`; only the raster parameters, the PLL and the output backend
change.

- `hdmi/hdmi_tmds_encoder.sv`  8b/10b TMDS encoder, one per channel: transition-minimised 8b→9b, then DC balanced against a running disparity; the four fixed control words during blanking. Blue carries HSYNC/VSYNC, green and red carry `2'b00`.
- `hdmi/hdmi_tmds_serializer.sv`  10:1 serializer built on the Gowin **`OSER10`** hard primitive, 74.25 MHz parallel in, 742.5 Mbit/s out.
- `hdmi/hdmi_tx.sv`  three encoders, four serializers (three data pairs plus a clock pair sending the fixed `1111100000` pattern), one logical output per pair.
- `hdmi/hdmi_rpll.v`  `rPLL` ×55/4 → 371.25 MHz serial plus `CLKDIV` /5 → 74.25 MHz pixel clock, configured exactly as the Sipeed HDMI example configures its PLL for this board.

Why not the vendor IP: the Sipeed example's `DVI_TX_Top` is `` `pragma protect ``-encrypted and can only be built in the Gowin IDE. It is a wrapper around `OSER10` + `CLKDIV` + `rPLL`, all of which are documented fabric macros, so the chain is rebuilt here from the primitives. `src/sim/hdmi_prim_sim.v` provides behavioural `OSER10`/`CLKDIV` stubs (and `rpll_sim.v` a stub `rPLL`) so the RTL elaborates and simulates outside the Gowin tools; those stubs are not in `cooda.gprj`.

**PnR now accepts the chain.** With `VIDEO_HDMI = 1` the build places all
four `OSER10` serializers (`IOLOGIC 8/207`, 4 × `OSER10`), infers `LVDS25`
on the four TMDS pairs, and generates a bitstream with no `CT`/`PR` errors
 so the `GSREN`/`LSREN` parameter set is accepted by GowinSynthesis
V1.9.11.03. What is still unproven is the silicon behaviour: the
742.5 Mbit/s output has never been on a screen, and the pixel domain does
not yet meet 74.25 MHz (§4.1.1). The documented fallback, if a later tool
rejects the parameters, is a 5-bit shift register plus an `ODDR`. The LCD
backend needs none of this and is the safe path.

## SoC

- `system.sv` wires the CPU, RPU and memory together, and instantiates the GPU. GPU and TPU *masters* are still tied idle (the GPU has no framebuffer fetch yet); the GPU_MMIO *slave* is the real register file.
- `fpga_top.sv` is the board wrapper. It has two-stage button synchronizers, an activity stretcher for `led0`, `led1` for the sticky CPU fault, the video PLL and raster, the RGB LCD backend, and the DDR3 pins wired straight through to `memory_ddr3_phy`.

## DDR3: no vendor IP

The Gowin DDR3 Memory Interface IP is deliberately not used: it can only be built inside the Gowin IDE, and its output is obfuscated. The board instead runs the open-source slow DDR3 controller (BSD-3, `ZiyangYE/General-Slow-DDR3-Interface`), vendored as `memory_ddr3_phy.sv` and driven entirely from `clk27`.

| | Gowin IP | slow controller |
|---|---|---|
| Build | Gowin IDE only | plain RTL, any tool |
| Speed on GW2A | DDR-800 | DDR-80 (here: DDR-27, `clk27/2`) |
| Resource | ~1288 regs, 1363 LUTs, 8 BSRAMs | 147 regs, 216 LUTs |
| Burst | yes | no, one 16-bit beat per transaction |
| Write mask | per byte | none (full halfword only) |

Consequences worth knowing: a 32-bit access costs two beats plus a row activate and precharge each, so DDR3 is much slower than the 27 MHz bus implies; and byte-granular stores are not possible, which is why `memory_ddr3` answers a partial write strobe with a bus error.

The pins are constrained in `sipeed_tang_primer_20k.cst` (SSTL15, `VREF=INTERNAL` on the DQ and DQS groups). The controller has separate `ck_p/ck_n` and `dqs_p/dqs_n` ports, so the true differential pairs are driven as two single-ended SSTL15 pins each  if PnR rejects that, merge the `*_n` port into the two-pin `IO_TYPE=SSTL15D` form. Timing: `memory_ddr3_phy` is all `clk27`, and the DQS-strobed capture paths are left to the first PnR report rather than being false-pathed blind (see the SDC).

## Boot program  running on the board

`src/programs/boot_program.hex` is the ROM image the CPU boots from (reset PC = 0). It is 8192 words: the first 22 instructions are the program, the rest is zero padding (a zero word decodes as `ADD r0, r0, r0`, which cannot change any state).

| Address | Code | Effect |
|---|---|---|
| 0x00–0x34 | `MOVI` setup | r1 = RAM base, r2 = GPU MMIO base, two header colours, delay count |
| 0x38 | `STORE r5, [r2+4]` | `RegControl = 1` → display switches from the colour-bar pattern to the bus visualiser |
| 0x40 | `STORE r6, [r2+24]` | header band = steel blue `0x336699` |
| 0x50 / 0x58 | `STORE` / `LOAD` RAM | `cpu_d` ↔ `ram` traffic, once per delay iteration |
| 0x60 / 0x68 | `SUB` / `BNE` | ~160 000-iteration delay (≈0.5 s at 27 MHz) |
| 0x70–0x98 | colour B + second delay | header band = amber `0x996633`, more RAM traffic |
| 0xA0 / 0xA8 | `ADD r3, r3, 1`, `JMP 0x40` | next cycle, forever |

On the panel: `cpu_i` and `rom` tiles stay bright (every fetch reads the ROM), `cpu_d` and `ram` pulse with the store/load traffic and their matrix-cell border lights while a transfer is in flight, `gpu_mmio` lights twice per cycle, and the header band alternates between two colours  which is the proof that the program is running rather than the pattern generator.

The program deliberately never touches DDR3: a bus error latches `cpu_fault` and halts the CPU, and DDR3 only answers once the controller has finished initialising.

`src/programs/check_program.py` disassembles the image and validates it against the decoder's rules (reserved bits `[31:26]`, per-opcode operand rules). Run it after any edit  it caught three encoding mistakes the first time round:

    python3 src/programs/check_program.py src/programs/boot_program.hex

**Building the bitstream** (Gowin IDE  the one step that needs the vendor tools):

1. Open `cooda.gprj`; every RTL file and both constraint files are already listed.
2. Release the dual-purpose pins first (`Project > Configuration >
   Dual-Purpose Pin`: SSPI, DONE, READY = regular I/O, see §1.4), then
   Synthesize → Place & Route → Program.
3. `fpga_top` sets `ROM_INIT_FILE` to `../src/programs/boot_program.hex` because GowinSynthesis resolves `$readmemh` relative to its working directory (`impl/`). If your IDE runs from elsewhere, change that one parameter.
4. The backend is selected by `VIDEO_HDMI` in `fpga_top.sv`: `1` builds the
   TMDS/HDMI path (the setting in the tree today), `0` builds the RGB LCD
   (RGB565 panel on the Dock's FPC connector). §4.1.1 and §4.1.2 record what
   each build measures.
5. The CPU runs as soon as the board is configured: S2 pauses it, S1 resets it.

## Two simulation bugs the boot-program test caught

Both worked on hardware, which is why they had gone unnoticed:

- **`memory_bsram`**: the response flops (`busy_q`, `rdata_q`) had no reset and no initial value, so simulation saw `X` on `rsp.ready` and no read ever completed. They now get a defined power-up value from an `initial` block instead of an async reset, which keeps GowinSynthesis able to infer a BSRAM.
- **`rpu` `rsp_mux`**: the response multiplexer was a function reading the slave responses from the enclosing module scope. Icarus derives a function's sensitivity list from its arguments, so a slave's `ready` never propagated to the master and the CPU stalled on its first fetch. Every response is now an argument.

## Known gaps and decisions

- **Register file:** `cpu_register_file` is 64 × 32 with async reset and async read, about 2,000 flops. Removing the reset would map it to LUT RAM and save a lot of area, but registers would be undefined until written. This is left as a decision for you.
- **Init files:** the ROM default is `src/programs/boot_program.hex`. The RAM has no default preload.
- **Simulation-only checks:** run `pkg_checks` in a testbench. Verification of the design beyond elaboration has not been done here.
- **Naming leftovers:**
  - Any file not listed here that still references `rpu_pkg`, `bus_pkg`, `cpu_pkg`, `opcode_pkg`, `memory_pkg` or `RPU_*` will not compile until migrated. `migrate.sh` handles most of that.

## What was removed

- `bus_pkg`, `rpu_pkg`, `cpu_pkg`, `opcode_pkg`, `memory_pkg` as separate packages (merged into the packages above).
- `rpu_decoder`, `rpu_crossbar`, `rpu_top`: replaced by `rpu.sv`.
- `ddr3_backend`: merged into `memory_ddr3`.
- `gpu_mem_req_s` / `gpu_mem_rsp_s`: the GPU uses `bus_req_s` / `bus_rsp_s` directly.
- Layout constants (`RS2_LSB`, `UPDATE_STATUS_BIT`, etc.), `OPCODE_COUNT`, permission masks, `*_SIZE` constants, and `status_t`.
- The `init_file` path strings in the memory modules, now parameters.

## Status

- Elaborates cleanly in Icarus Verilog 12 from `fpga_top`.
- Simulated: `./run.sh` runs the package checks, the video testbenches and
  the SoC testbench (`src/sim/testbench/soc/system_tb.sv`). All four tests
  pass: 723 instructions retired, the visualiser comes up, the clear
  colour is `336699` and `RAM[4] = 1`.
- Synthesised and place-and-routed for the Tang Primer 20K: bitstream
  generated, boot ROM loaded, no `CT`/`PR` errors, all four `OSER10`
  serializers placed. §4.1.1 is the current HDMI build, §4.1.2 the LCD one.
- Open before this can be trusted on a screen: the 11 real pixel-domain
  setup paths of §4.1.1, the missing `clk27`/`hdmi_pix_clk` clock group,
  and the DDR3 DQS warnings.
- Not yet verified on the board.


# cooda  Tang Primer 20K HDMI test pattern

Self-contained 720p60 HDMI pattern generator for the **Sipeed Tang Primer 20K**
(core board + 20K Dock), built with **Gowin V1.9.11.03 Education**.

| | |
|---|---|
| Device | `GW2A-LV18PG256C8/I7` (GW2A-18C, PBGA256, speed 8) |
| Top | `fpga_top` (`src/rtl/fpga_top.sv`) |
| Constraints | `src/constraints/sipeed_tang_primer_20k.cst` / `.sdc` |
| Project | `cooda.gprj` |
| Clocking | 27 MHz → rPLL ×55/4 → 371.25 MHz serial → CLKDIV /5 → 74.25 MHz pixel |

Switches and keys change the pattern; LEDs mirror the control state.

---

# 1. THE DUAL-PURPOSE PIN PROBLEM

This is the single biggest trap in this project. It cost a full debugging
cycle and it is **not** a bug in the RTL or in the `.cst`.

## 1.1 Symptom

Place & Route stops during `Running placement......` with:

```
ERROR  (PR2028) : The constrained location is useless in current package
ERROR  (PR2017) : 'btn_n[0]' cannot be placed according to constraint,
                  for the location is a dedicated pin (SSPI)
ERROR  (PR2028) : The constrained location is useless in current package
ERROR  (PR2017) : 'led_n[0]' cannot be placed according to constraint,
                  for the location is a dedicated pin (DONE)
ERROR  (PR2028) : The constrained location is useless in current package
ERROR  (PR2017) : 'led_n[1]' cannot be placed according to constraint,
                  for the location is a dedicated pin (READY)
```

Synthesis completes fine. The failure is purely at placement.

## 1.2 The pins involved

| Pin | Dock label | Dedicated function |
|---|---|---|
| `N9` | LCD data bit 2 (`lcd_r[2]`) | **SSPI CS_N/D0** |
| `T10` | S0 (the ~RST key) | **SSPI SI/D2** |
| `C13` | LED0 | **DONE** |
| `A13` | LED1 | **READY** |

SSPI owns two pins, so releasing that one function frees both: the LCD data
bit on `N9` (used by the current revision) and the S0 key on `T10` (not
used). DONE and READY are one pin each.

These are FPGA **configuration** pins. Place & Route will not route a user
signal to them unless the project's device configuration marks the function
as a regular I/O.

## 1.3 Root cause  and why the obvious fix does not work

The setting is a **project setting**, not a `.cst` constraint. It lives in
`impl/cooda_process_config.json`:

```json
 "DONE" : false,      ->  "DONE" : true,
 "READY" : false,     ->  "READY" : true,
 "SSPI" : false,      ->  "SSPI" : true,
 "RECONFIG_N" : false,
```

Setting those to `true` is correct and necessary. **But it is not
sufficient, and while the Gowin IDE is open it has no effect at all.**

The chain is:

1. PnR is invoked with the device config file, per `impl/pnr/cmd.do`:

   ```
   -cfg /home/ifonlyloop/Documents/code/sysverilog/cooda/impl/pnr/device.cfg
   ```

   So PnR reads **`device.cfg`**, and `device.cfg` must contain
   `set SSPI regular_io = true` etc.

2. The mapping JSON → `device.cfg` is real and was confirmed against the
   working HDMI example in this workspace:
   `TP20kExample/HDMI/impl/project_process_config.json` has
   `"SSPI" : true` and its `impl/pnr/device.cfg` has
   `set SSPI regular_io = true`.

3. **The Gowin IDE holds the project configuration in memory and rewrites
   `impl/pnr/device.cfg` from that in-memory copy on every run.** It does
   *not* re-read `impl/cooda_process_config.json` from disk while the
   project is open.

Observed directly:

| Time | Event | `device.cfg` SSPI/READY/DONE |
|---|---|---|
| 21:41 | `gw_sh` build with `-use_*_as_gpio` | `true` / `true` / `true` |
| 21:53 | **IDE** Place & Route | `false` / `false` / `false` |

The JSON on disk said `true` at 21:53. The IDE overwrote the correct
`device.cfg` with `false` anyway.

**Consequence:** there is no file you can edit from the command line that
the open IDE will honour. Editing the JSON is necessary but not sufficient.

## 1.4 The fix applied here  release SSPI, DONE and READY

The current revision **does** use configuration pins, because the Dock's
RGB LCD data bit 2 (`lcd_r[2]`) sits on `N9`, which is SSPI. SSPI is
therefore released for the display, and DONE/READY for `led4`/`led5`:

| Function | Released for | Why |
|---|---|---|
| `SSPI` | `lcd_r[2]` on `N9` | the LCD data bus needs all 16 pins |
| `DONE` | `led4` on `C13` | status LED |
| `READY` | `led5` on `A13` | status LED |

Set it with Option A below (the IDE dialog). With it set, PnR completes
and the pin report shows the pin placed instead of rejected:

```
lcd_r[2] | - | N9/3 | Y | out | IOR36[B] | SSPI_CS_N/D0 | LVCMOS33 | 8 | UP
```

`Constraint = Y` means the `.cst` location was honoured. The package
function stays labelled `SSPI_CS_N/D0`; that is the pin's alternate
function name, not an indication that it is in use for configuration.

### What that costs

The build now depends on a project setting that only the IDE GUI can
reliably change (see §1.3): a fresh clone, or a `gw_sh` run without the
`-use_*_as_gpio` options, stops at placement with `PR2017`/`PR2028` until
the setting is made. This is the trap that the "edit the JSON" route in
§1.5 Option C only half solves.

An earlier revision of this project (no LCD, no `led4`/`led5`) avoided all
of these pins and therefore needed **no project configuration at all**: it
built from a fresh clone with `device.cfg` left at all-`false`:

```
set JTAG regular_io = false
set SSPI regular_io = false
set MSPI regular_io = false
set READY regular_io = false
set DONE regular_io = false
```

To get back to that today, pick one:

* delete `led4`/`led5` from `fpga_top.sv` and the two blocks in the `.cst`;
* drop the LCD, or drop `lcd_r[2]` from `fpga_top.sv` and its `.cst` line
  (the panel then has 4 red levels instead of 5, and `N9` floats);
* or set `VIDEO_HDMI = 1` and use the HDMI backend, which does not use `N9`.

The current revision deliberately trades that portability for the full
16-bit LCD bus and all six LEDs.

## 1.5 If you *do* want those pins back

Pick one of these, in order of reliability:

**Option A  set it in the IDE (the supported route).**
`Project > Configuration > Dual-Purpose Pin`, set **SSPI**, **DONE** and
**READY** to *regular I/O*, keep JTAG as the configuration mode. The IDE
then writes both the JSON and `device.cfg` consistently. This is the
procedure Sipeed's own wiki describes for `PR2017`.

**Option B  build from the command line, bypassing the IDE.**

There is no `program_fpga.sh` in this repository; drive `gw_sh` yourself
and pass

```
set_option -use_sspi_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_ready_as_gpio 1
```

which rewrites `device.cfg` correctly. This works today and does not
depend on IDE state. **But:** if you then run PnR from the open IDE, the
IDE will overwrite `device.cfg` again and the errors come back.

**Option C  edit the JSON and restart the IDE.**
`impl/cooda_process_config.json` with `SSPI`/`READY`/`DONE` = `true` is the
correct persistent state, but the IDE only reads it on project open.
Close the project completely, reopen it, then run PnR. Risk: the IDE may
write its in-memory copy back to the JSON on close, undoing your edit.
Re-check the JSON after closing.

**Option D  `RECONFIG_N` (DIP SW1 / B10).** Never enable this. Sipeed's
wiki depends on that pin for the JTAG recovery procedure ("enable the core
board", and the documented fix for a board whose dual-purpose pins have
locked JTAG out). Enabling it as regular I/O throws that away.

## 1.6 Checklist if you hit PR2017/PR2028 again

1. `grep regular_io impl/pnr/device.cfg`  is the needed function `true`?
2. If not, the IDE is overriding it. Use Option A or B above.
3. `grep -n "dedicated pin" impl/pnr/cooda.log` to see which port and which
   function.
4. Remember the pin→function table: `N9`=SSPI (lcd_r[2]), `T10`=SSPI (S0),
   `C13`=DONE (led4), `A13`=READY (led5).
5. The `.cst` cannot fix this. `IO_LOC`/`IO_PORT` have no attribute for it.

---

# 2. Pin map, with the evidence for each choice

Every retained pin is confirmed by **both** the vendor factory test and the
community pin tables. Nothing rests on a single source.

| Port | Pin | Bank / VCCIO | Role |
|---|---|---|---|
| `clk27` | H11 | 0 / 3.3 V (GCLKT_0) | 27 MHz oscillator |
| `btn_n[0]` | T3 | 4 / 1.5 V | S1  reset |
| `btn_n[1]` | T2 | 4 / 1.5 V | S2  toggle colour inversion |
| `sw[0]` | E9 | 4 / 1.5 V | DIP SW2 → mode[0] |
| `sw[1]` | E8 | 4 / 1.5 V | DIP SW3 → mode[1] |
| `sw[2]` | T4 | 4 / 1.5 V | DIP SW4 → colour[0] |
| `sw[3]` | T5 | 4 / 1.5 V | DIP SW5 → colour[1] |
| `led_n[0]` | N16 | 1 / 3.3 V | PLL locked |
| `led_n[1]` | N14 | 1 / 3.3 V | frame heartbeat (pixel domain alive) |
| `led_n[2]` | L14 | 1 / 3.3 V | mode[0] |
| `led_n[3]` | L16 | 1 / 3.3 V | mode[1] |
| `O_tmds_clk_p/n` | G16 / H15 | 0 / 3.3 V | TMDS clock pair, IOT16 |
| `O_tmds_data_p[0]/n[0]` | H14 / H16 | 0 / 3.3 V | TMDS blue, IOT20 |
| `O_tmds_data_p[1]/n[1]` | J15 / K16 | 0 / 3.3 V | TMDS green, IOT24 |
| `O_tmds_data_p[2]/n[2]` | K14 / K15 | 0 / 3.3 V | TMDS red, IOT30 |

## 2.1 Pins deliberately NOT used, and why

| Pin | Function | Reason |
|---|---|---|
| `T10` | S0 / SSPI SI/D2 | dual-purpose configuration pin  see §1 |
| `C13` | LED0 / DONE | dual-purpose configuration pin  see §1 |
| `A13` | LED1 / READY | dual-purpose configuration pin  see §1 |
| `B10` | DIP SW1 / RECONFIG_N | reconfiguration control; Sipeed's JTAG recovery path depends on it |
| `D7` | S3 | bank 6, VCCIO unconfirmed on this Dock |
| `C7` | S4 | bank 6, VCCIO unconfirmed on this Dock |

**Evidence for the last three.** `TP20kExample/Lite-bottom_test_project` is
the vendor's own "drive every usable IO" test: it declares
`input [4:1] user_key` (four keys, index 0 does not exist) and
`input [1:0] rst_n`, and its `.cst` contains exactly `{T10, T2, T3, T4, E8, E9}`
as user inputs. `B10`, `T5`, `D7` and `C7` do **not appear anywhere** in that
project  not as keys, not as `led_o[*]`.

`D7` and `C7` also sit in **bank 6, whose device default VCCIO is 1.8 V**,
while the Sipeed templates constrain them as `LVCMOS15`. That discrepancy was
never resolved against the Dock schematic.

`T5` (DIP SW5) is used here because it is bank 4 at 1.5 V, the same bank as
the confirmed-working `T2`/`T3`/`T4`/`E8`/`E9`. It is the only retained pin
that the factory test does not also list, and it carries no voltage risk.

## 2.2 DIP polarity is unverified

The Dock fits external resistors on the switch nets, so `PULL_MODE=NONE` is
used and the polarity was never measured. If the pattern selection reads
inverted on hardware, invert `sw` in `fpga_top.sv`.

## 2.3 HDMI pin constraints use the two-pin differential form

```tcl
IO_LOC  "O_tmds_clk_p" G16,H15;
IO_PORT "O_tmds_clk_p" PULL_MODE=NONE DRIVE=3.5;
```

Only the `_p` ports are constrained, each with **two** pins; Gowin places the
matching `_n` port on the second pin itself. **No `IO_TYPE` is given** 
`LVDS25` is inferred. This is copied verbatim from the working HDMI example,
and this project's own PnR report confirms all eight pins land on
IOT16/20/24/30 at `LVDS25`.

---

# 3. The vendor IP blobs

Two vendor files are used. One is opaque, one is not  worth knowing the
difference.

## 3.1 `src/ip/dvi_tx/dvi_tx.v`  encrypted

A Gowin **DVI TX** IP core, copied byte-identical from
`TP20kExample/HDMI/src/dvi_tx/dvi_tx.v`. It is an IEEE 1735 encrypted
netlist:

```
line 10:   `pragma protect begin_protected
line 10:   `pragma protect encrypt_agent="Synplify encryptP1735.pl"
line 10:   `pragma protect key_keyowner="Synplicity", key_keyname="SYNP05_001", key_method="rsa"
line 1047: `pragma protect end_protected
line 1048: module DVI_TX_Top (...)
```

Only **GowinSynthesis** holds the decryption key. Consequences:

* it cannot be read or edited,
* **it cannot be simulated**  Icarus cannot parse it, so the TMDS output
  path has zero simulation coverage. Hardware is the only test.

Its guts are genuinely unavailable. The file the IP generator copies from,
`Gowin/IDE/ipcore/DVI_TX/data/rgb2dvi.v`, is **itself ciphertext as shipped**
(`pragma protect` at line 1, `end_protected` at line 188, GOWIN key
`GWK2023-09`). The plaintext never reaches disk, so there is nothing to
recover. `libDVI_TX.so` only renames the encrypted file into the project.

## 3.2 `src/ip/pll/TMDS_rPLL.v`  NOT encrypted

Plain, readable Verilog: an `rPLL` primitive instantiation with `defparam`s
(`FCLKIN=27, IDIV_SEL=3, FBDIV_SEL=54, ODIV_SEL=2` → 371.25 MHz). `CLKDIV`
is a bare primitive. These are **hard silicon blocks**  there is no source
to want, and they are fully editable wrappers.

## 3.3 Replacing the DVI TX IP with your own TMDS transmitter

Possible, and it would be fully editable and simulatable. The architecture
the IP uses is recoverable from its readable top wrapper and from the
Gowin primitives:

```
3 x TMDS 8b/10b encoder  ->  4 x OSER10  ->  4 x TLVDS_OBUF
```

Exact primitive interfaces, from `Gowin/IDE/simlib/gw2a/prim_tsim.v`:

```verilog
module OSER10 (Q, D0,D1,D2,D3,D4,D5,D6,D7,D8,D9, PCLK, FCLK, RESET);
parameter GSREN = "false";  parameter LSREN = "true";

module TLVDS_OBUF (O, OB, I);   // O = true, OB = complement
```

* `PCLK` = pixel clock (74.25 MHz), `FCLK` = 5x serial clock (371.25 MHz)
* `D0` is transmitted first
* the clock lane is an `OSER10` fed the constant pattern
  `D0..D4 = 1'b1, D5..D9 = 1'b0`, i.e. `1111100000`, giving a 50 % duty
  74.25 MHz differential clock
* `ELVDS_OBUF` (emulated) is only needed on GW1N parts; GW2A uses
  `TLVDS_OBUF` for true LVDS

A working reference implementation of exactly this on Gowin hardware is
`juj/gowin_flipflop_drainer` (`src/hdmi.v`). The TMDS line code itself is
DVI 1.0 §3  a 4-entry control-code table, an 8b→9b transition-minimisation
stage, and a 9b→10b DC-balancing stage against a running disparity.

**Caution:** the two control-code tables in circulation differ in how they
label `C0`/`C1` versus `CTL0`/`CTL1`, and Wikipedia's table is in
transmission order (bit 0 first) while the DVI spec's is `q_out[9:0]`.
Getting that mapping wrong swaps HSYNC and VSYNC. Do not guess it 
determine it from the spec table and prove it with a decode test.

## 3.4 Which Gowin IP cores ship readable source

Scanned every core in `Gowin/IDE/ipcore/*/data`. The pattern is uniform:
"readable" is always a thin wrapper plus macro defines; the implementation
is always encrypted.

```
DVI_TX   3 files, 1 encrypted   (the 2 "readable" are a 35-line wrapper + 7-line defines)
DDR3     7 files, 5 encrypted
FFT      9 files, 3 encrypted
```

---

# 4. Verification

## 4.1 Gowin build (V1.9.11.03 Education)

Two builds matter here: the earlier HDMI-only milestone (table below, kept
for reference) and the current SoC in §4.1.1. **The current build is the
HDMI backend** (`VIDEO_HDMI = 1`); §4.1.2 records the LCD backend numbers
for comparison.

**Earlier HDMI-only revision.** Run with **no** dual-purpose flags and
`device.cfg` at all-`false` (that revision used none of `N9`, `T10`,
`C13`, `A13`):

| | |
|---|---|
| Synthesis | clean |
| Place & Route | clean  no `CT1135`, `PR2017`, `PR2028` |
| Timing | **0 setup violations, 0 hold violations** |
| `clk27` Fmax | 270.75 MHz (constraint 27 MHz) |
| Logic | 480 LUT/ALU (359 LUT, 121 ALU) |
| Registers | 136 FF |
| CLS | 317/10368 (4 %) |
| I/O | 19/207 |
| IOLOGIC | 4 × `OSER10` |
| Bitstream | `impl/pnr/cooda.fs` |

All user pins placed exactly as specified in §2, and the eight TMDS pins at
`LVDS25`.

### A note on the timing report

Early runs reported **106 "setup violated endpoints"** and a `TA1132`
warning about the pixel clock. Both were artefacts, not real failures:

* The violations were all `clk27 → pix_clk` **recovery** paths
  (`rst_sync → u_dvi_tx/.../u_OSER10_*/RESET`), captured by the 371.25 MHz
  serial clock and unable to meet a 2.694 ns recovery window from a 27 MHz
  flop. Fixed by making `hdmi_rst_n` combinational from the key pin,
  matching the reference's `I_rst_n & pll_lock`, and by declaring
  `set_clock_groups -asynchronous` between `clk27` and `pix_clk`.
* `TA1132` disappeared once the pixel clock was declared explicitly with
  `create_clock`. Note that a **generated** clock name
  (`u_clkdiv/CLKOUT.default_gen_clk`) cannot be referenced from
  `set_clock_groups`  it does not exist yet when constraints are parsed,
  giving `ERROR (TA2004)`. Declare the clock on the net instead.

**Beware the `Numbers of Setup Violated Endpoints` counter.** It is not
consistent with the path tables: it can be non-zero while TNS is 0.000 for
every clock and every listed path has positive slack. Always cross-check
against the `Recovery`/`Removal` path tables and the TNS summary.

### 4.1.1 Current SoC  HDMI backend, bus visualiser, DDR3

Tool `V1.9.11.03 Education`, part `GW2A-LV18PG256C8/I7`, built from the IDE
with the dual-purpose pins released (§1.4). `VIDEO_HDMI = 1`, so this is the
720p60 TMDS build; §4.1.2 has the LCD backend numbers.

| | |
|---|---|
| Synthesis | clean except one benign `EX3791` truncation (below) |
| Place & Route | clean  no `CT1108`, `CT1136`, `PR2017`, `PR2028` |
| Boot ROM | loads: `memory_bsram(INIT_FILE="src/programs/boot_program.hex")`, no `EX3988` |
| Timing | hold clean (worst `+0.321 ns`); 25 setup paths negative  14 `clk27` to `hdmi_pix_clk` crossings and 11 real pixel-domain paths, see below |
| Logic | 4786/20736 (24 %)  3760 LUT, 510 ALU, 86 SSRAM |
| Registers | 1817/16173 (12 %)  1777 FF + 40 I/O FF |
| CLS | 2955/10368 (29 %) |
| I/O | 86/207 (42 %)  3 in, 59 out, 20 inout |
| IOLOGIC | 8/207 (4 %)  all four `OSER10` serializers placed |
| BSRAM | 32/46 (70 %), all single-port |
| DSP | 0.25/24 (2 %)  one `MULT9X9`, the visualiser's multiply |
| Clocks | PRIMARY 8/8 (100 %), LW 6/8 (75 %), GCLK_PIN 5/8, CLKDIV 1/8, rPLL 1/4 |
| PnR time | 26 s, 901 MB peak |
| Bitstream | `impl/pnr/cooda.fs` |

The four TMDS pairs land on `IOT16` / `IOT20` / `IOT24` / `IOT30` as
`LVDS25`, one logical output per pair, exactly as §2.3 describes. `lcd_r[2]`
still lands on `N9/3` (`IOR36[B]`, `Constraint = Y`) even though this build
ties the LCD pins off  the dual-purpose release of §1.4 is still doing its
job.

#### Setup: 14 of the 25 negative paths are clock-domain crossings

The `.sdc` now declares both clocks, `clk27` and the pixel clock as a
generated clock ×11/4 from it (74.25 MHz):

```tcl
create_clock -name clk27 -period 37.037 [get_ports {clk27}]
create_generated_clock -name hdmi_pix_clk -source [get_ports {clk27}] \
    -master_clock clk27 -divide_by 4 -multiply_by 11 \
    [get_pins {g_hdmi_clk.u_hdmi_rpll/u_clkdiv/CLKOUT}]
```

That is what makes the requirements meaningful: `clk27` to `hdmi_pix_clk`
is now reported against a `5.568 ns` window instead of the `18.379 ns` the
tool invented for the LCD build. 14 of the 25 negative setup paths are
those crossings, every one ending on a GPU synchroniser flop
(`u_system/u_gpu/actm_sync_q0_*`, `acts_sync_q0_*`, `lvl_sync_q0_*`), with
slacks from `-14.563 ns` down to `-0.242 ns`. They are the *designed*
crossings (Gray-coded levels, quasi-static configuration, reset release),
so the remaining fix is to cut the group:

```tcl
set_clock_groups -asynchronous \
    -group [get_clocks {clk27}] -group [get_clocks {hdmi_pix_clk}]
```

#### Setup: the other 11 are real pixel-domain violations

The remaining 11 paths launch from the raster counter
(`u_video_timing/v_cnt_q_3`) and end on the TMDS input registers
(`g_hdmi_out.u_hdmi_tx/{r,g,b}_q_*`), so both ends are in the same clock
domain. Their slacks are `-5.947 ns` to `-6.573 ns` against a `15.704 ns`
window: the combinational path from the raster counter through the GPU
renderer's region/colour selection to the encoder's input register takes
about 22 ns.

The input-register stage in `hdmi_tx.sv` was added to split rendering from
encoding and did shorten the path, but not enough for 74.25 MHz. Options,
in order of effort:

* pipeline the visualiser's output once more (a second register between
  `gpu_pixel_engine` and `hdmi_tx`);
* take the region/colour selection off the counter path (it currently
  starts from `v_cnt_q` / `h_cnt_q`);
* or build the LCD backend instead  at 40.5 MHz there are 24.7 ns per
  pixel, which is why that build's only negative paths are CDC crossings.

#### Benign warnings from the same build

| Warning | Where | Why it is benign |
|---|---|---|
| `EX3791` 32 truncated to 26 | `cpu_decoder.sv:66` | the 26-bit instruction-field struct taken from a 32-bit instruction; the decoder tests bits [31:26] separately |
| `TA1132` x4 | `ddr3_dqs_*[0..1]` | the vendored PHY uses DQS as a clock and it is never declared |
| `PR1014` x4 | `ddr3_dqs_*_in[0..1]` | the same DQS pins routed on general routing instead of a clock network. At 13.5 MHz DDR that is harmless; the `.sdc` records how to declare the clocks and cut the DQ paths if it ever matters |

The `pattern_gen.sv:80` truncation is gone because this build does not
instantiate `pattern_gen` at all  the visualiser is the only pixel source.
Note also that `PRIMARY` clock resources are now **8/8 (100 %)**: `clk27`,
`hdmi_pix_clk`, the serial clock and the DQS-derived clocks have filled the
global network, so another clock domain needs a different resource.

### 4.1.2 The LCD backend (`VIDEO_HDMI = 0`)

Same RTL with the parameter at `0`: 800×480 RGB565, `video_rpll` at
40.5 MHz, no serializer. Build of the same day, for comparison:

| | |
|---|---|
| Synthesis | clean except two `EX3791` truncations (`cpu_decoder.sv:66`, `pattern_gen.sv:80`) |
| Place & Route | clean  no `CT1108`, `CT1136`, `PR2017`, `PR2028` |
| Boot ROM | loads, no `EX3988` |
| Timing | 4 setup paths and all 25 hold paths negative  every one a `clk27` to `pix_clk` crossing |
| Logic | 4266/20736 (21 %)  3461 LUT, 325 ALU, 80 SSRAM |
| Registers | 1753/16173 (11 %)  1713 FF + 40 I/O FF |
| CLS | 2642/10368 (26 %) |
| I/O | 82/207 (40 %)  3 in, 59 out, 20 inout |
| BSRAM | 32/46 (70 %), all single-port |
| Clocks | PRIMARY 7/8, LW 8/8 (100 %), GCLK_PIN 5/8, rPLL 1/4 |
| PnR time | 14 s, 960 MB peak |
| Bitstream | `impl/pnr/cooda.fs` |

Here the negative paths are *only* the CDC crossings (worst `-3.691 ns`
setup, `-1.928 ns` hold): the renderer fits comfortably inside a 24.7 ns
pixel period. The holds were negative because that `.sdc` declared no pixel
clock at all, so the analyzer had no phase to work with  the same missing
`set_clock_groups` as in §4.1.1, with the LCD's 40.5 MHz clock in place of
`hdmi_pix_clk`.

## 4.2 Simulation

```
./run.sh --no-gui
```

| Suite | Result |
|---|---|
| `pkg_checks_tb` | PASS  word geometry, opcode width, ROM/RAM sizing, address map, GPU regs |
| `video_timing_tb` | PASS  1237500 clocks, 921600 de pixels, 720 de lines, hs 30000, vs 8250 |
| `pattern_gen_tb` | PASS  8 bars, grid, grey ramp, 4 flat colours, invert, blanking |
| `system_tb` | PASS  boot program: 723 instructions retired, visualiser on, clear colour `336699`, `RAM[4] = 1` |

**Coverage.** `pkg_checks_tb` checks the packages, the two video
testbenches exercise `video_timing.sv` and `pattern_gen.sv` on their own,
and `system_tb` boots the whole SoC from `filelist.f`  CPU, RPU, ROM/RAM,
GPU and video  with `src/sim/rpll_sim.v` and `src/sim/hdmi_prim_sim.v`
standing in for the `rPLL`/`OSER10`/`CLKDIV` hard macros, which Icarus
cannot elaborate. The encrypted DVI TX netlist that used to block this is
gone.

Not covered: the DDR3 controller (no memory model is attached), the TMDS
serialiser's electrical behaviour, and the panel itself.

## 4.3 The black-screen bug  reset polarity

**Symptom:** bitstream loads, the PLL locks (LED0 on), but the display
stays black and no switch or key does anything.

**Cause:** `hdmi_rst_n` is an **active-low** reset. `btn_n[0]` is *also*
active-low, so it is already 1 when the key is released  the correct
polarity on its own. The code had:

```systemverilog
assign hdmi_rst_n = ~btn_n[0] & pll_lock;   // WRONG
```

which is 0 whenever the key is *not* pressed, holding `hdmi_rst_n` at 0
permanently. That in turn holds `CLKDIV.RESETN` low, so **`pix_clk` never
toggles at all**  `video_timing` never leaves reset, and the DVI IP is
never given a pixel clock. Black screen, no response to any input.

Correct:

```systemverilog
assign hdmi_rst_n = btn_n[0] & pll_lock;
```

**How it got in.** The line began as `~rst & pll_lock`, where
`rst = ~btn_n[0]` is the *synchronised, active-high* reset  so `~rst` is
`btn_n[0]`, correct. It was later rewritten to take the raw pin directly
(to remove a clk27 launch from the DVI IP's recovery path) and the `~` was
carried across unchanged, inverting the sense.

**Why nothing caught it.** It is a logic polarity error, so it synthesises
cleanly and meets timing. And `fpga_top` has no simulation coverage (the
DVI TX netlist is encrypted), so the only test is hardware.

**Fixed, plus a diagnostic.** LED1 is now a frame heartbeat rather than the
invert flag. LED0 steady means the PLL locked; LED1 blinking means the
pixel domain and the raster are running. That turns "black screen" into a
one-glance diagnosis: LED0 on + LED1 dead is exactly what a stuck reset
looks like.

**Lesson:** when an `_n` signal is driven from another `_n` signal they
have the *same* sense  inverting one inverts the meaning. `btn_n[0]` and
`hdmi_rst_n` are both active-low, so no inversion belongs between them.

## 4.4 Bugs found during development

Recorded because they are easy to repeat.

1. **`hs`/`vs` polarity was inverted.** The testbench caught it: the
   hs-high pixel count came back as exactly the complement (1 207 500
   instead of 30 000). 720p60 is positive polarity  the sync pulse is HIGH
   during the sync interval.

2. **A "pause" control that did nothing.** `paused_reg` was synchronised
   into the pixel domain and wired to an LED, but `pattern_gen` never
   received it, so pressing the key changed an LED and nothing else. It was
   removed rather than left as a fake feature.

3. **A testbench measurement artefact.** Right after reset `hcnt_reg` skips
   0, so the counter pipeline holds its reset value for `DELAY` cycles and
   `frame_start` pulses for 5 cycles instead of 1. A frame measurement
   starting on that transient is off by exactly 5 pixels. The testbench now
   settles past it and measures `frame_start` to `frame_start` while
   sampling on the falling edge, removing all phase dependence.

---

# 5. Build and program

**From the IDE:** open `cooda.gprj`, then Synthesize → Place & Route →
Program Device. Before Place & Route the dual-purpose pins must be released
(`Project > Configuration > Dual-Purpose Pin`: **SSPI**, **DONE**, **READY**
= regular I/O), or placement stops with `PR2017`/`PR2028`  see §1.

**From the command line:** there is no build helper script in this
repository. `gw_sh` can drive the same flow, but it must be given the
dual-purpose options (`-use_sspi_as_gpio`, `-use_done_as_gpio`,
`-use_ready_as_gpio`), or `impl/pnr/device.cfg` must already contain
`set SSPI regular_io = true` plus the two `DONE`/`READY` lines.

`./run.sh` is simulation only; it does not build for the board.

Before programming: **DIP switch 1 must be in the enable position** ("down"),
or the core board stays in reconfiguration and discards the bitstream. With
SW1 disabled, LED0 and LED1 light and the board does nothing  that is the
board telling you it is held in reconfig, not a design fault.

On the board (current design, `VIDEO_HDMI = 1`):

* S1 (`btn_n0`) = reset
* S2 (`btn_n1`) = run; the CPU runs by default, holding S2 pauses it
* `led0` = stretched CPU instruction retirement, flickers while the boot
  program runs
* `led1` = sticky CPU fault (fetch, data bus or illegal instruction); stays
  off in a healthy run
* `led2`-`led5` = reserved (`led4`/`led5` are the DONE/READY pins, §1.4)
* the output shows the GPU bus-activity visualiser: the boot program paints
  the header band `336699` and alternates it with `996633` every ~0.5 s
  while the tiles follow the bus traffic
* with `VIDEO_HDMI = 1` that goes out over the Dock's HDMI at 720p60; with
  `VIDEO_HDMI = 0` it drives the RGB LCD panel instead (800×480, the backend
  that meets timing today  see §4.1.2)

---

# 6. Source layout

```
cooda.gprj                          Gowin project
run.sh                              simulation runner (4 tests, Icarus)
src/programs/boot_program.hex       boot ROM image
src/programs/check_program.py       disassembler for the image above
src/rtl/soc/fpga_top.sv             top: clocking, keys, LEDs, display select
src/rtl/soc/system.sv               SoC: CPU + RPU + GPU + video
src/rtl/cpu/cpu.sv                  CPU top, with program/, core/, alu/
src/rtl/rpu/rpu.sv                  register/peripheral unit, passive taps
src/rtl/gpu/gpu.sv                  visualiser: MMIO + monitor + pixel engine
src/rtl/memory/memory.sv            ROM + RAM + DDR3, with memory_bsram,
                                    memory_ddr3, memory_ddr3_phy (vendored)
src/rtl/video/video_timing.sv       raster generator          [simulated]
src/rtl/video/pattern_gen.sv        test patterns             [simulated]
src/rtl/video/video_lcd.sv          RGB565 output stage
src/rtl/video/video_rpll.v          40.5 MHz pixel clock (rPLL hard macro)
src/rtl/hdmi/hdmi_tx.sv             TMDS backend, no vendor IP
src/rtl/packages/                   isa, arch, soc, gpu, alu
src/constraints/…cst                physical constraints
src/constraints/…sdc                timing constraints
src/sim/testbench/…                 pkg_checks, video and soc testbenches
```

---

# 7. Known limitations

1. **Never run on hardware yet.** The bitstream builds, but whether a sink
   locks is unproven.
2. **The HDMI pixel domain does not meet 74.25 MHz.** 11 real setup paths
   fail by 5.9-6.6 ns (raster counter to TMDS input register, §4.1.1); the
   other 14 negative setup paths are CDC crossings that need only the clock
   group. The LCD backend at 40.5 MHz has no such failures (§4.1.2).
3. **No simulation coverage of the TMDS path**  see §4.2. The video path is
   covered by the raster testbenches only, not by a sink or panel model.
4. **DIP switch polarity unverified**  see §2.2. Nothing in the current
   design reads a DIP switch, so this matters only if you add one back.
5. **DDR3 is unproven.** The vendored slow controller is compiled in and the
   SoC returns a bus error until it initialises, but no board has run it, and
   its DQS-strobed capture is not timing-analysed (the `TA1132`/`PR1014`
   warnings in §4.1.1).
6. **`T5` (DIP SW5) is community-confirmed only**  see §2.1. Legacy: the
   pattern-mode DIP switches belonged to the earlier HDMI test-pattern
   revision.
7. **Bank 6 (`D7`, `C7`) is unresolved.** Their VCCIO is unconfirmed on
   this Dock. Do not enable them without checking the schematic.
8. **The DDR3 and TMDS blocks that replaced the vendor IP are unproven.**
   `dvi_tx.v` and the vendor PLL wrapper are gone (§3 keeps the notes on
   them). The DDR3 PHY is vendored BSD-3 source; the TMDS chain is pure RTL
   plus hard macros. Neither has been on a board.





