#!/bin/bash
# COODA regression runner.
# Run from the repository root so source paths and waveforms resolve.
#
#   ./run.sh              run the regression
#   ./run.sh --no-gui     run the regression without GTKWave
#   ./run.sh --help       show usage
#
# The regression runs package, ALU, CPU, system boot, DDR3 interface, and
# (when local vendor models are installed) DDR3 controller tests under Icarus.
# The controller test is much slower than the rest - minutes rather than
# seconds - because the Micron and Gowin primitive models make every DRAM
# access expensive. See src/sim/vendor/README.md.
#
# Compile order lives in filelist.f. The Gowin project's FileList mirrors
# it - keep the two in step.
set -e

NO_GUI=0
for arg in "$@"; do
    case "$arg" in
        --no-gui)
            NO_GUI=1
            ;;
        --help|-h)
            echo "usage: $0 [--no-gui]"
            echo "  runs package, ALU, CPU, system, and DDR3 interface tests."
            exit 0
            ;;
        *)
            echo "error: unknown option '$arg'" >&2
            echo "usage: $0 [--no-gui]" >&2
            exit 2
            ;;
    esac
done

mkdir -p src/sim/build src/sim/waveforms

run_test() {
    local label="$1"
    local top="$2"
    local binary="$3"
    local vcd="$4"
    shift 4

    echo "========== ${label} =========="

    iverilog -g2012 -Wall \
        -s "$top" \
        -o "src/sim/build/$binary" \
        "$@"

    vvp "src/sim/build/$binary"

    if [[ -f "$vcd" ]]; then
        mv -f "$vcd" "src/sim/waveforms/$vcd"
    fi
}

run_test "PACKAGE INVARIANTS" pkg_checks_tb pkg_checks_sim pkg_checks.vcd \
    -f filelist.f \
    src/sim/pkg_checks.sv \
    src/sim/testbench/soc/pkg_checks_tb.sv

run_test "ALU DIFFERENTIAL" alu_tb alu_sim alu.vcd \
    -f filelist.f \
    src/sim/testbench/cpu/alu_tb.sv

run_test "CPU PROGRAM" cpu_tb cpu_sim cpu.vcd \
    -f filelist.f \
    src/sim/testbench/soc/cpu_tb.sv

run_test "SYSTEM BOOT PROGRAM" system_tb system_sim system.vcd \
    -f filelist.f \
    src/sim/testbench/soc/system_tb.sv

run_test "DDR3 CDC" ddr3_cdc_tb ddr3_cdc_sim "" \
    -f filelist.f \
    src/sim/testbench/memory/ddr3_cdc_tb.sv

run_test "DDR3 TARGET" ddr3_target_tb ddr3_target_sim "" \
    -f filelist.f \
    src/sim/testbench/memory/ddr3_target_tb.sv

run_test "MEMORY MAP" memory_map_tb memory_map_sim "" \
    -f filelist.f \
    src/sim/testbench/memory/memory_map_tb.sv

if [[ -f src/sim/vendor/ddr3/ddr3.v && -f src/sim/vendor/prim_sim.v ]]; then
    run_test "DDR3 CONTROLLER + MICRON MODEL" ddr3_controller_tb ddr3_controller_sim "" \
        -D SIM -D den1024Mb -D sg25 -D x16 -I src/sim/vendor \
        -f filelist.f \
        src/sim/testbench/memory/ddr3_controller_tb.sv \
        src/sim/vendor/ddr3/ddr3.v \
        src/sim/vendor/prim_sim.v
else
    echo "========== DDR3 CONTROLLER + MICRON MODEL: SKIPPED (install local models; see src/sim/vendor/README.md) =========="
fi

echo "========== ALL TESTS PASSED =========="

if [[ "$NO_GUI" == "1" ]]; then
    exit 0
fi

unset GTK_PATH GIO_MODULE_DIR LD_LIBRARY_PATH LD_PRELOAD

gtkwave \
    src/sim/waveforms/pkg_checks.vcd
