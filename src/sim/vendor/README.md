# Local DDR3 simulation models

The DDR3 controller simulation uses two files that are not distributed with
COODA. Install them locally; both are ignored by Git:

- Gowin's `prim_sim.v`, copied from the Gowin IDE simulation library at
  `IDE/simlib/gw2a/prim_sim.v`.
- Micron's 1-Gbit x16 DDR3 model, `ddr3/ddr3.v` and
  `ddr3/1024Mb_ddr3_parameters.vh`. Upstream uses v1.74 from Micron's own
  site (<https://www.micron.com/products/dram/ddr3-sdram>, "DDR3 SDRAM
  Verilog Model"); the v1.70 files in the Elphel `eddr3` repository's
  `ddr3/` directory are an equally usable public copy:
  <https://github.com/Elphel/eddr3/tree/master/ddr3>.

Place the files at:

```text
src/sim/vendor/prim_sim.v
src/sim/vendor/ddr3/ddr3.v
src/sim/vendor/ddr3/1024Mb_ddr3_parameters.vh
```

The Micron model v1.70 needs a small compatibility edit for Icarus 12. In
each of `cmd_addr_timing_check`, `dm_timing_check`, `dq_timing_check`,
`dqs_pos_timing_check`, and `dqs_neg_timing_check`, replace the scalar
`input i;` followed by `reg [N:0] i;` with the single vector declaration
`input [N:0] i;`. This resolves the duplicate port declaration rejected by
Icarus. From the repository root:

```bash
sed -i '/^    input i;$/N;s/^    input i;\n    reg \[\([0-9]*\):0\] i;$/    input [\1:0] i;/' \
    src/sim/vendor/ddr3/ddr3.v
```

Keep this patched model local; it is third-party code.

The testbench must instantiate `GSR` with `GSRI` tied high:

```systemverilog
GSR GSR (.GSRI(1'b1));
```

`prim_sim.v`'s models resolve their global reset through the hierarchical
name `GSR.GSRO`, so Icarus 12 refuses to elaborate the design unless an
instance literally named `GSR` exists; Icarus 11 let that reference float.
`GSRO` is active low, so `GSRI` is tied high to hold reset inactive. The
primitives this controller uses (`OSER8`, `OSER8_MEM`, `IDES8_MEM`, `DQS`)
all default to `GSREN="false"`, which hardwires their internal reset
inactive, so `GSRO` does not actually gate them.

The testbench must also reproduce upstream's clock bring-up exactly,
including its odd-looking initialisation:

```systemverilog
real tck;
...
    tck  <= 2500;        // non-blocking on purpose
    fclk <= 1'b1;
    ck   <= 1'b1;
    pclk <= 1'b1;
    forever begin
        #(tck/4) ck = ~ck;
        ...
```

`tck` is a `real`, so it reads back as `0.0` while that non-blocking
assignment is still pending; the first `#(tck/4)` therefore evaluates to
`#0` and the clocks start at time 0. That matters: the Gowin primitive
models latch their internal serialiser phase against the clocks at time 0,
so starting the clocks a quarter period later rotates the DQS/DQ phases.
The symptom is subtle and misleading - initialization and calibration still
complete, but write leveling converges to `wstep=0x18` instead of `0x1a`,
the DRAM reports `ck=1` on its write-leveling feedback instead of `ck=0`,
the Micron model reports `DQS bit N latching edge required` during writes,
and every write lands as `xxxx` while reads return `xxxx`.

The controller's `-D SIM` configuration has a known data-lane difference:
it reads back data on DQ lane 4 (`assign dout = dq_in[4]`), while the hardware
configuration uses lane 0. This simulation exercises controller command
sequencing, calibration handshakes, and client transactions against the
Micron model, but does not validate the physical DQ lane mapping.

The upstream simulation setup uses Micron model v1.74 and Icarus 11. This
repository's local compatibility patch targets the available v1.70 model and
Icarus 12; `-D SIM` shortens the initialization waits, so the model reports
`tZQinit` violations and `tDLLK` warnings during startup.

The v1.70/Icarus 12 combination works: the test completes calibration
(`wstep=0x1a`, `rclkpos=1`, `rclksel=7`) and passes its write/read-back
checks with no `DQS` errors. Upstream's v1.74/Icarus 11 setup is the
reference for comparison.

With both vendor model files installed, `./run.sh --no-gui` runs the
controller test. If either file is missing, the regression prints a skip
message and continues. The test is by far the slowest in the regression:
the Micron model and the Gowin primitive models make each DRAM access
cost seconds of wall time, which is why its sequence is deliberately
short.
