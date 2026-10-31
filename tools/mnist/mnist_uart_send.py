#!/usr/bin/env python3
"""Send a packed COODA MNIST image to the FPGA over its UART."""

import argparse
import struct
import sys
import time
from pathlib import Path

MAGIC = 0x434F4F44
HEADER_BYTES = 512
BLOCK_BYTES = 512
DDR3_WINDOW_BYTES = 0x0800_0000
DEFAULT_BAUD = 921600

ERROR_MESSAGES = {
    1: "bad image magic",
    2: "inconsistent block or payload length",
    3: "destination is outside the DDR3 window or misaligned",
    4: "payload checksum mismatch",
    5: "UART receive timeout",
    6: "DDR3 bus write failed",
}


def load_image(path):
    image = Path(path).read_bytes()
    if len(image) < HEADER_BYTES:
        raise ValueError("image is shorter than its 512-byte header")

    fields = struct.unpack_from("<9I", image)
    (magic, blocks, destination, payload_bytes, records, rows, cols,
     labels, checksum) = fields
    if magic != MAGIC:
        raise ValueError(f"bad image magic 0x{magic:08x}")
    if blocks == 0 or payload_bytes == 0:
        raise ValueError("image has no payload")
    if records == 0 or rows == 0 or cols == 0 or labels == 0:
        raise ValueError("image metadata contains zero dimensions or records")
    if destination % 4:
        raise ValueError("destination offset must be 4-byte aligned")
    padded_payload_bytes = (payload_bytes + 3) & ~3
    if destination + padded_payload_bytes > DDR3_WINDOW_BYTES:
        raise ValueError("payload exceeds the DDR3 window")
    expected_payload_bytes = records * (rows * cols + labels)
    if payload_bytes != expected_payload_bytes:
        raise ValueError(
            "payload length does not match the declared MNIST dimensions")
    if blocks != (payload_bytes + BLOCK_BYTES - 1) // BLOCK_BYTES:
        raise ValueError("header block count does not match payload length")
    if len(image) != HEADER_BYTES + blocks * BLOCK_BYTES:
        raise ValueError("file size does not match header block count")

    payload = image[HEADER_BYTES:HEADER_BYTES + payload_bytes]
    if sum(payload) & 0xFFFFFFFF != checksum:
        raise ValueError("payload checksum does not match header")
    return image[:HEADER_BYTES], payload, records, rows, cols


def read_status(port, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = port.read(1)
        if value == b"R":
            return "ready", None
        if value == b"D":
            return "done", None
        if value == b"E":
            code = port.read(1)
            if not code:
                raise TimeoutError("FPGA error status did not include an error code")
            return "error", code[0]
    raise TimeoutError("timed out waiting for FPGA UART status")


def describe_error(code):
    if code is None:
        return "missing error code"
    return ERROR_MESSAGES.get(code, f"unknown error code {code}")


def write_all(port, data):
    offset = 0
    while offset < len(data):
        written = port.write(data[offset:])
        if written is None or written <= 0:
            raise TimeoutError("UART write made no progress")
        offset += written


def main():
    parser = argparse.ArgumentParser(
        description="Transfer an image built by tools/mnist/mnist_pack.py.")
    parser.add_argument("--port", required=True,
                        help="serial device, e.g. /dev/ttyUSB0 or COM5")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                        help=f"UART baud rate (default: {DEFAULT_BAUD})")
    parser.add_argument("image", help="packed MNIST .img file")
    args = parser.parse_args()

    try:
        if args.baud <= 0:
            raise ValueError("baud rate must be positive")
        header, payload, records, rows, cols = load_image(args.image)
        try:
            import serial
        except ImportError as exc:
            raise RuntimeError(
                "pyserial is required; install it with: python3 -m pip install pyserial"
            ) from exc

        print(f"Waiting for FPGA on {args.port} at {args.baud} baud...")
        with serial.Serial(args.port, args.baud, timeout=1, write_timeout=30) as port:
            while True:
                status, code = read_status(port, timeout=30)
                if status == "ready":
                    break
                if status == "error":
                    raise RuntimeError(
                        f"FPGA rejected transfer before ready: {describe_error(code)}")

            print(f"Sending {records} records ({rows}x{cols}), "
                  f"{len(payload):,} payload bytes...")
            write_all(port, header)

            chunk_size = 64 * 1024
            for offset in range(0, len(payload), chunk_size):
                chunk = payload[offset:offset + chunk_size]
                write_all(port, chunk)
                sent = offset + len(chunk)
                print(f"\rSent {sent:,}/{len(payload):,} bytes", end="", flush=True)
            port.flush()
            print()

            deadline = max(120, (len(payload) * 10 / args.baud) * 2 + 30)
            status, code = read_status(port, timeout=deadline)
            if status == "error":
                raise RuntimeError(f"FPGA reported load error: {describe_error(code)}")
            if status != "done":
                raise RuntimeError(f"unexpected FPGA status {status}")

        print("FPGA verified the payload checksum and completed the DDR3 load.")
    except (OSError, ValueError, TimeoutError, RuntimeError) as exc:
        sys.exit(f"error: {exc}")


if __name__ == "__main__":
    main()
