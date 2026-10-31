#!/bin/bash
# COODA regression runner.
# Run from the repository root so source paths and waveforms resolve.
#
#   ./run.sh              run the regression
#   ./run.sh --no-gui     run the regression without GTKWave
#   ./run.sh --help       show usage
#
# The regression runs the package, ALU, CPU, system boot, DDR3 interface,
# UART, microSD, and MNIST display tests under Icarus, plus the DDR3 controller
# test when local vendor models are installed. The controller test is much
# slower than the rest - minutes rather than seconds - because the Micron
# and Gowin primitive models make every DRAM access expensive.
# See src/sim/vendor/README.md.
#
# Compile order lives in filelist.f. It includes project RTL but omits the
# protected generated Gowin DDR3 core; the adapter test supplies a model.
set -e

NO_GUI=0
for arg in "$@"; do
    case "$arg" in
        --no-gui)
            NO_GUI=1
            ;;
        --help|-h)
            echo "usage: $0 [--no-gui]"
            echo "  runs package, ALU, CPU, system, DDR3, UART, SD, and video tests."
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

echo "========== MNIST HOST TOOL TESTS =========="
python3 -m unittest discover -s tools/mnist -p 'test_*.py'

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
    src/sim/testbench/memory/ddr3/ddr3_cdc_tb.sv

run_test "DDR3 TARGET / WRITE THROUGHPUT" ddr3_target_tb ddr3_target_sim "" \
    -f filelist.f \
    src/sim/testbench/memory/ddr3/ddr3_target_tb.sv

run_test "GOWIN DDR3 ADAPTER" ddr3_gowin_target_tb ddr3_gowin_target_sim "" \
    -f filelist.f \
    src/sim/testbench/memory/ddr3/ddr3_gowin_target_tb.sv

run_test "UART BYTE LOOPBACK" uart_tb uart_sim "" \
    -f filelist.f \
    src/sim/testbench/uart/uart_tb.sv

run_test "MNIST UART LOADER" mnist_uart_loader_tb mnist_uart_loader_sim "" \
    -f filelist.f \
    src/sim/testbench/mnist/mnist_uart_loader_tb.sv

run_test "SD SPI MASTER" sd_spi_master_tb sd_spi_master_sim "" \
    -f filelist.f \
    src/sim/testbench/memory/sd/sd_spi_master_tb.sv

run_test "SD CONTROLLER" sd_controller_tb sd_controller_sim "" \
    -f filelist.f \
    src/sim/testbench/memory/sd/sd_controller_tb.sv \
    src/sim/testbench/memory/sd/sd_model.sv

run_test "SD LOADER" sd_loader_tb sd_loader_sim "" \
    -f filelist.f \
    src/sim/testbench/memory/sd/sd_loader_tb.sv \
    src/sim/testbench/memory/sd/sd_model.sv

run_test "MNIST RATE LADDER" mnist_rate_tb mnist_rate_sim "" \
    -f filelist.f \
    src/sim/testbench/mnist/mnist_rate_tb.sv

run_test "MNIST FRAME SOURCE" mnist_frame_source_tb mnist_frame_source_sim "" \
    -f filelist.f \
    src/sim/testbench/mnist/mnist_frame_source_tb.sv

run_test "MNIST VIEW END TO END" mnist_view_tb mnist_view_sim "" \
    -f filelist.f \
    src/sim/testbench/mnist/mnist_view_tb.sv

run_test "HDMI DIFFERENTIAL OUTPUTS" hdmi_tx_tb hdmi_tx_sim "" \
    -f filelist.f \
    src/sim/testbench/video/hdmi_tx_tb.sv \
    src/sim/vendor/prim_sim.v

# The end-to-end test needs a card image, which comes from the MNIST IDX
# files in data/mnist. Build a small one from them and check that every
# byte of it arrives; skip both steps when the data is not installed.
if [[ -f data/mnist/train-images-idx3-ubyte && \
      -f data/mnist/train-labels-idx1-ubyte ]]; then
    python3 tools/mnist/mnist_pack.py \
        --images data/mnist/train-images-idx3-ubyte \
        --labels data/mnist/train-labels-idx1-ubyte \
        --limit 12 --out data/mnist/sd_image.img > /dev/null

    run_test "SD IMAGE END TO END" sd_image_tb sd_image_sim "" \
        -f filelist.f \
        src/sim/testbench/memory/sd/sd_image_tb.sv \
        src/sim/testbench/memory/sd/sd_model.sv
else
    echo "========== SD IMAGE END TO END: SKIPPED (no MNIST IDX files in data/mnist) =========="
fi

run_test "MEMORY MAP" memory_map_tb memory_map_sim "" \
    -f filelist.f \
    src/sim/testbench/memory/memory_map_tb.sv

if [[ -f src/sim/vendor/ddr3/ddr3.v && -f src/sim/vendor/prim_sim.v ]]; then
    run_test "DDR3 CONTROLLER + MICRON MODEL" ddr3_controller_tb ddr3_controller_sim "" \
        -D SIM -D den1024Mb -D sg25 -D x16 -I src/sim/vendor \
        -f filelist.f \
        src/sim/testbench/memory/ddr3/ddr3_controller_tb.sv \
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
