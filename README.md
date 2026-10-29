# COODA CPU

CPU-only 32-bit von Neumann system for the Sipeed Tang Primer 20K. The CPU instruction and data requests share one bus and one writable 32 KiB BSRAM initialized from `src/programs/boot_program.hex`.

## Architecture

- `cpu.sv` wires the instruction unit, decoder, execution core, register file, and ALU together.
- `bus_arbiter.sv` is a reusable four-client round-robin arbiter for one target. It holds a grant through target stalls. The current system connects CPU instruction fetch and data access; two inactive slots reserve GPU and TPU clients for later integration. Instantiate another arbiter for each future shared target.
- `memory.sv` checks the main-memory range and wraps the single-port, byte-write-enabled `memory_bsram`.
- `system.sv` connects CPU request clients through the arbiter to BSRAM.
- `fpga_top.sv` provides reset/run buttons and CPU status LEDs. No GPU, video, RPU, or DDR3 logic is in the active design.

The bus is 32-bit, byte-addressed, word-aligned. A request completes when `valid && ready`; clients hold requests stable until completion. Addresses outside the 32 KiB main memory return an error.

## Build and simulation

The Gowin project is `cooda.gprj`, with top module `fpga_top`. `filelist.f` gives the RTL compile order.

Compile the FPGA top with Icarus:

```sh
iverilog -g2012 -s fpga_top -f filelist.f -o /tmp/cooda.out
```

Run the CPU/BSRAM smoke test:

```sh
iverilog -g2012 -s system_tb -f filelist.f src/sim/testbench/soc/system_tb.sv -o /tmp/system_tb.out
vvp /tmp/system_tb.out
```

The test program writes `0x12345678` to main-memory address `0x100`, reads it back, and loops.

The full regression is `./run.sh --no-gui`. It runs the package invariants, a
differential test of every ALU opcode against a reference model
(`src/sim/testbench/cpu/alu_tb.sv`), a program-level test of the CPU, bus and
BSRAM (`src/sim/testbench/soc/cpu_tb.sv`), and the boot-program smoke test.

## Board controls

- S1 (`btn_n0`) resets the CPU.
- S2 (`btn_n1`) pauses execution while held.
- LED0 indicates recent instruction retirement; LED1 indicates no CPU fault; LED2 indicates no illegal instruction.

The physical pin assignments are in `src/constraints/sipeed_tang_primer_20k.cst`; the 27 MHz clock constraint is in the matching `.sdc` file.
