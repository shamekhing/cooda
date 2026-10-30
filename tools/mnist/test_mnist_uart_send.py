import contextlib
import io
import struct
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import mnist_uart_send


def build_image(destination=0, payload=b"abcdefghij", records=2,
                rows=2, cols=2, labels=1):
    blocks = (len(payload) + mnist_uart_send.BLOCK_BYTES - 1) // \
        mnist_uart_send.BLOCK_BYTES
    header_words = [0] * (mnist_uart_send.HEADER_BYTES // 4)
    header_words[:9] = [
        mnist_uart_send.MAGIC,
        blocks,
        destination,
        len(payload),
        records,
        rows,
        cols,
        labels,
        sum(payload) & 0xFFFFFFFF,
    ]
    padded_payload = payload + bytes(blocks * mnist_uart_send.BLOCK_BYTES -
                                     len(payload))
    return struct.pack(f"<{len(header_words)}I", *header_words) + padded_payload


class FakeSerial:
    def __init__(self, reads=(), max_write=2):
        self.reads = list(reads)
        self.max_write = max_write
        self.written = bytearray()
        self.flushed = False

    def read(self, _size):
        if self.reads:
            return self.reads.pop(0)
        return b""

    def write(self, data):
        count = min(len(data), self.max_write)
        self.written.extend(data[:count])
        return count

    def flush(self):
        self.flushed = True

    def __enter__(self):
        return self

    def __exit__(self, _exc_type, _exc_value, _traceback):
        return False


class LoadImageTests(unittest.TestCase):
    def test_valid_image_returns_header_and_true_payload(self):
        image = build_image()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mnist.img"
            path.write_bytes(image)

            header, payload, records, rows, cols = mnist_uart_send.load_image(path)

        self.assertEqual(len(header), 512)
        self.assertEqual(payload, b"abcdefghij")
        self.assertEqual((records, rows, cols), (2, 2, 2))

    def test_rejects_misaligned_destination(self):
        self.assert_image_rejected(
            build_image(destination=1), "4-byte aligned")

    def test_rejects_payload_outside_ddr3_window(self):
        self.assert_image_rejected(
            build_image(destination=mnist_uart_send.DDR3_WINDOW_BYTES - 4),
            "DDR3 window")

    def test_rejects_payload_length_inconsistent_with_dimensions(self):
        self.assert_image_rejected(
            build_image(records=3), "MNIST dimensions")

    def test_rejects_bad_checksum(self):
        image = bytearray(build_image())
        image[mnist_uart_send.HEADER_BYTES] ^= 1
        self.assert_image_rejected(bytes(image), "checksum")

    def assert_image_rejected(self, image, message):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mnist.img"
            path.write_bytes(image)

            with self.assertRaisesRegex(ValueError, message):
                mnist_uart_send.load_image(path)


class SerialProtocolTests(unittest.TestCase):
    def test_read_status_skips_unrecognized_bytes(self):
        port = FakeSerial(reads=[b"\x00", b"R"])

        self.assertEqual(mnist_uart_send.read_status(port, timeout=1),
                         ("ready", None))

    def test_read_status_reads_binary_error_code(self):
        port = FakeSerial(reads=[b"E", b"\x04"])

        self.assertEqual(mnist_uart_send.read_status(port, timeout=1),
                         ("error", 4))
        self.assertEqual(mnist_uart_send.describe_error(4),
                         "payload checksum mismatch")

    def test_read_status_rejects_missing_error_code(self):
        port = FakeSerial(reads=[b"E"])

        with self.assertRaisesRegex(TimeoutError, "did not include"):
            mnist_uart_send.read_status(port, timeout=1)

    def test_write_all_retries_short_writes(self):
        port = FakeSerial(max_write=2)

        mnist_uart_send.write_all(port, b"headerpayload")

        self.assertEqual(port.written, b"headerpayload")

    def test_write_all_rejects_no_progress(self):
        port = FakeSerial(max_write=0)

        with self.assertRaisesRegex(TimeoutError, "no progress"):
            mnist_uart_send.write_all(port, b"data")


class SenderCliTests(unittest.TestCase):
    def test_cli_waits_for_ready_sends_unpadded_image_and_waits_for_done(self):
        image = build_image()
        with tempfile.TemporaryDirectory() as directory:
            image_path = Path(directory) / "mnist.img"
            image_path.write_bytes(image)
            serial_port = FakeSerial(reads=[b"R", b"D"], max_write=127)
            serial_module = types.SimpleNamespace(
                Serial=lambda *_args, **_kwargs: serial_port)
            stdout = io.StringIO()

            with (
                patch.object(sys, "argv", [
                    "mnist_uart_send.py", "--port", "mock-serial",
                    str(image_path),
                ]),
                patch.dict(sys.modules, {"serial": serial_module}),
                contextlib.redirect_stdout(stdout),
            ):
                mnist_uart_send.main()

        payload_bytes = struct.unpack_from("<I", image, 12)[0]
        self.assertEqual(
            serial_port.written,
            image[:mnist_uart_send.HEADER_BYTES] +
            image[mnist_uart_send.HEADER_BYTES:
                  mnist_uart_send.HEADER_BYTES + payload_bytes],
        )
        self.assertTrue(serial_port.flushed)
        self.assertIn("verified the payload checksum", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
