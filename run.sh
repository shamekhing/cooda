#!/bin/bash
# COODA regression runner.
# Run from the repository root so source paths and waveforms resolve.
#
#   ./run.sh              run the regression
#   ./run.sh --no-gui     run the regression without GTKWave
#   ./run.sh --help       show usage
#
# The regression runs package invariants, video unit testbenches, and a
# system boot smoke test under Icarus.
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
            echo "  runs the package invariant checks."
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

run_test "VIDEO TIMING" video_timing_tb video_timing_sim video_timing.vcd \
    src/rtl/video/video_timing.sv \
    src/sim/testbench/video/video_timing_tb.sv

run_test "PATTERN GEN" pattern_gen_tb pattern_gen_sim pattern_gen.vcd \
    src/rtl/video/pattern_gen.sv \
    src/sim/testbench/video/pattern_gen_tb.sv

run_test "SYSTEM BOOT PROGRAM" system_tb system_sim system.vcd \
    -f filelist.f \
    src/sim/rpll_sim.v \
    src/sim/hdmi_prim_sim.v \
    src/sim/testbench/soc/system_tb.sv

echo "========== ALL TESTS PASSED =========="

if [[ "$NO_GUI" == "1" ]]; then
    exit 0
fi

unset GTK_PATH GIO_MODULE_DIR LD_LIBRARY_PATH LD_PRELOAD

gtkwave \
    src/sim/waveforms/pkg_checks.vcd
