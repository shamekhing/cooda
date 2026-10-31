# MNIST quick start: PC to FPGA

This guide sends MNIST image data from a PC to the Tang Primer 20K over
the board's USB-UART bridge. The FPGA writes the payload into DDR3 and
the HDMI viewer displays the images. UART upload is the board default;
the microSD loader is an alternative.

## Requirements

- Sipeed Tang Primer 20K with its dock, programmed with the COODA
  `fpga_top` design.
- USB connection to the board's USB-UART bridge.
- Python 3 on the PC.
- MNIST IDX image and label files. The expected training filenames are
  `train-images-idx3-ubyte` and `train-labels-idx1-ubyte`. Download the
  training files from the [MNIST database](https://yann.lecun.com/exdb/mnist/),
  decompress them, and place them in `data/mnist/` (or adjust the paths
  in the commands below).
- `pyserial` for serial-port communication.

The board USB-UART bridge connects to FPGA `uart_rx_pin` T13 and
`uart_tx_pin` M11. The configured serial format is **921600 baud, 8 data
bits, no parity, 1 stop bit (8N1), no hardware or software flow control**.
The FPGA waits until DDR3 calibration completes before announcing
readiness.

## 1. Find the board's serial port

Connect the board to the PC and identify the USB serial device:

- Linux: commonly `/dev/ttyUSB0` or `/dev/ttyACM0`.
- Windows: the COM port shown in Device Manager, for example `COM5`.
- macOS: commonly `/dev/cu.usbserial-*`.

Use the port that appears when the board is connected. Close any serial
terminal or other program that already has it open.

## 2. Program the FPGA

Open `cooda.gprj` in Gowin EDA, build the `fpga_top` design, and program
the resulting bitstream. The default top parameters select UART
(`UART_ENABLE=1`, `SD_ENABLE=0`). Do not enable both loaders: they share
one system bus slot.

After programming or resetting the board, wait for DDR3 calibration.
The host sender will wait for the FPGA's `R` ready status before
transmitting.

## 3. Install the host dependency

From the repository root:

```sh
python3 -m pip install pyserial
```

The examples use POSIX shell line continuations. On Windows, run each
command on one line and use `py -3` in place of `python3` if needed.

## 4. Pack and upload a small test set

First pack a small subset to check the serial link and display:

```sh
python3 tools/mnist/mnist_pack.py \
    --images data/mnist/train-images-idx3-ubyte \
    --labels data/mnist/train-labels-idx1-ubyte \
    --limit 12 \
    --out /tmp/mnist-12.img

python3 tools/mnist/mnist_uart_send.py \
    --port /dev/ttyUSB0 \
    /tmp/mnist-12.img
```

Replace `/dev/ttyUSB0` with the port found above (for example `COM5`
on Windows). Keep the baud at its default unless the FPGA's
`UART_BAUD_RATE` parameter was changed; the PC and FPGA baud rates must
match.

The sender validates the image before opening the serial port, waits for
`R`, sends the 512-byte header followed by the unpadded payload, and
waits for `D`. On success, the viewer can display the uploaded records.
The loader accepts one upload after each reset. Reset the FPGA before
starting another upload.

## 5. Upload the full training set

Omit `--limit` to pack the complete 60,000-record training set:

```sh
python3 tools/mnist/mnist_pack.py \
    --images data/mnist/train-images-idx3-ubyte \
    --labels data/mnist/train-labels-idx1-ubyte \
    --out /tmp/mnist-train.img

python3 tools/mnist/mnist_uart_send.py \
    --port /dev/ttyUSB0 \
    /tmp/mnist-train.img
```

The payload is about 47.1 MB and takes approximately 8.5 minutes on the
wire at 921600 baud; USB-UART and host overhead can increase the actual
time. Keep the FPGA powered and do not reset it during the transfer.

## Status and troubleshooting

The FPGA sends one-byte `R` (ready) and `D` (done) statuses. A transfer
error is `E` followed by one binary error-code byte:

| Code | Meaning | Check |
| --- | --- | --- |
| 1 | Invalid image magic | Use an image made by `tools/mnist/mnist_pack.py`. |
| 2 | Inconsistent block or payload length | Repack the image and do not modify its header. |
| 3 | Invalid DDR3 destination | Use a 4-byte-aligned destination that fits in DDR3. |
| 4 | Payload checksum mismatch | Retry the transfer; check the serial connection and baud rate. |
| 5 | Receive timeout | Retry without pausing the upload; check the serial connection. |
| 6 | DDR3 bus write failed | Check DDR3 calibration and board configuration. |

If the sender times out before `R`, check that the FPGA is programmed
with the UART-enabled top, the selected serial port is correct, no other
application owns it, and DDR3 calibration has completed. If the sender
times out after sending data, check the baud match and avoid resetting
or disconnecting the board during transfer.

## Change the display rate

The viewer starts at one image per second. Press the dock's `btn_n2`
button (header pin T12) to double the rate, or `btn_n3` (T11) to halve
it. These active-low buttons can be pressed to ground. Rates step through
1, 3, 7, 15, 30, and 60 images per second; 60 is the HDMI refresh-rate
limit.

The built-in UART tests can be run without hardware:

```sh
python3 -m unittest discover -s tools/mnist -p 'test_*.py'
./run.sh --no-gui
```

The transfer path is simulation-tested. A successful PC-to-board upload
still requires verification on physical hardware.
