// CPU-only von Neumann SoC compile order
// Run from the project root:
//   iverilog -g2012 -s fpga_top -f filelist.f -o sim.out

src/rtl/packages/arch_pkg.sv
src/rtl/packages/isa_pkg.sv
src/rtl/packages/alu_pkg.sv
src/rtl/packages/soc_pkg.sv

src/rtl/bus/bus_arbiter.sv
src/rtl/memory/memory_bsram.sv
src/rtl/memory/memory.sv

src/rtl/cpu/alu/cpu_alu_arithmetic.sv
src/rtl/cpu/alu/cpu_alu_logic_unit.sv
src/rtl/cpu/alu/cpu_alu_shifter.sv
src/rtl/cpu/alu/cpu_alu_comparator.sv
src/rtl/cpu/alu/cpu_alu.sv
src/rtl/cpu/core/cpu_register_file.sv
src/rtl/cpu/core/cpu_status_register.sv
src/rtl/cpu/core/cpu_datapath.sv
src/rtl/cpu/core/cpu_core.sv
src/rtl/cpu/program/cpu_pc.sv
src/rtl/cpu/program/cpu_fetch.sv
src/rtl/cpu/program/cpu_decoder.sv
src/rtl/cpu/program/cpu_branch.sv
src/rtl/cpu/program/cpu_program.sv
src/rtl/cpu/cpu.sv
src/rtl/soc/system.sv
src/rtl/soc/fpga_top.sv
