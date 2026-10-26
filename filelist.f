// ============================================================
// cooda RTL compile order
//
// Usage:
//   iverilog -g2012 -s fpga_top -f filelist.f -o sim.out
//   verilator --lint-only -Wall -sv --top-module fpga_top -f filelist.f
//
// Run from the project root: the paths below are project-relative.
//
// Order matters: arch_pkg carries the project-wide `timescale`, so it
// must be compiled first, and the packages must precede every module
// that references them.
//
// Dependency order: arch -> isa, alu, soc -> gpu
//
// NOT listed here:
//   src/sim/pkg_checks.sv       simulation-only (contains $fatal)
//   src/constraints/*           for the Gowin tools, not the simulator
// ============================================================

// ---------------- packages (arch first: it carries `timescale) --------
src/rtl/packages/arch_pkg.sv
src/rtl/packages/isa_pkg.sv
src/rtl/packages/alu_pkg.sv
src/rtl/packages/soc_pkg.sv
src/rtl/packages/gpu_pkg.sv

// ---------------- RPU -------------------------------------------------
src/rtl/rpu/rpu_slave_port.sv
src/rtl/rpu/rpu.sv

// ---------------- memory ----------------------------------------------
src/rtl/memory/memory_bsram.sv
src/rtl/memory/memory_ddr3_phy.sv
src/rtl/memory/memory_ddr3.sv
src/rtl/memory/memory.sv

// ---------------- GPU -------------------------------------------------
src/rtl/gpu/gpu_registers.sv
src/rtl/gpu/gpu_bus_mon.sv
src/rtl/gpu/gpu_pixel_engine.sv
src/rtl/gpu/gpu.sv

// ---------------- video / display -------------------------------------
src/rtl/video/video_rpll.v
src/rtl/video/video_timing.sv
src/rtl/video/pattern_gen.sv
src/rtl/video/video_lcd.sv

// ---------------- HDMI / TMDS -----------------------------------------
src/rtl/hdmi/hdmi_rpll.v
src/rtl/hdmi/hdmi_tmds_encoder.sv
src/rtl/hdmi/hdmi_tmds_serializer.sv
src/rtl/hdmi/hdmi_tx.sv

// ---------------- CPU -------------------------------------------------
src/rtl/cpu/alu/cpu_alu_arithmetic.sv
src/rtl/cpu/alu/cpu_alu_logic_unit.sv
src/rtl/cpu/alu/cpu_alu_shifter.sv
src/rtl/cpu/alu/cpu_alu_comparator.sv
src/rtl/cpu/alu/cpu_alu.sv

src/rtl/cpu/core/cpu_register_file.sv
src/rtl/cpu/core/cpu_status_register.sv
src/rtl/cpu/core/cpu_datapath.sv
src/rtl/cpu/core/cpu_core.sv

// instruction unit: pc, fetch, decode, program_branch, unit top
src/rtl/cpu/program/cpu_pc.sv
src/rtl/cpu/program/cpu_fetch.sv
src/rtl/cpu/program/cpu_decoder.sv
src/rtl/cpu/program/cpu_branch.sv
src/rtl/cpu/program/cpu_program.sv

src/rtl/cpu/cpu.sv

// ---------------- SoC -------------------------------------------------
src/rtl/soc/system.sv
src/rtl/soc/fpga_top.sv
