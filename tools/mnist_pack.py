#!/usr/bin/env python3
"""Turn MNIST IDX files into the raw card image sd_loader expects.

The image is a header block followed by the payload:

    block 0, 512 bytes, little endian 32-bit words
      word 0  magic "COOD" (0x434F4F44)
      word 1  payload blocks   (512-byte blocks after the header)
      word 2  destination byte offset inside the DDR3 window
      word 3  payload bytes    (true length, <= blocks * 512)
      word 4  record count     (number of images)
      word 5  image rows
      word 6  image cols
      word 7  label bytes per record
      word 8  payload checksum (sum of payload bytes mod 2**32)
      words 9..127  zero

    blocks 1..N  the payload, padded with zeros to a block boundary
      N * rows * cols bytes   images, one byte per pixel
      N * label bytes         labels

sd_loader reads and checks words 0..3; the rest is for whatever reads the
data out of DDR3 afterwards.

Write the file at LBA 0 of a dedicated card:

    sudo dd if=mnist.img of=/dev/sdX bs=512 conv=fsync

or, to leave a card's own filesystem alone, build the image for a
reserved LBA and seek to it:

    python3 tools/mnist_pack.py ... --dest-offset 0
    sudo dd if=mnist.img of=/dev/sdX bs=512 seek=1048576 conv=fsync

and set HDR_LBA to 1048576 in fpga_top's memory_sd instantiation.
"""

import argparse
import struct
import sys

MAGIC = 0x434F4F44           # "COOD"
BLOCK = 512
HEADER_WORDS = 128


def read_idx(path):
    """Read an IDX file: a magic word, then the dimensions, then data."""
    with open(path, "rb") as handle:
        blob = handle.read()

    if len(blob) < 4:
        raise ValueError(f"{path}: too short to be an IDX file")

    magic = struct.unpack(">I", blob[0:4])[0]
    if magic & 0xFFFFFF00 != 0x00000800:
        raise ValueError(f"{path}: not an IDX file (magic 0x{magic:08x})")

    dims = magic & 0xFF
    if dims < 1 or dims > 3:
        raise ValueError(f"{path}: unsupported IDX dimension count {dims}")

    header = struct.unpack(f">{dims}I", blob[4:4 + 4 * dims])
    body = blob[4 + 4 * dims:]

    count = header[0]
    if dims == 1:
        rows, cols = 1, 1
    elif dims == 2:
        rows, cols = header[1], 1
    else:
        rows, cols = header[1], header[2]

    expected = count * rows * cols
    if len(body) < expected:
        raise ValueError(
            f"{path}: {len(body)} data bytes, expected {expected}")

    return body[:expected], count, rows, cols


def main():
    parser = argparse.ArgumentParser(
        description="Build a COODA microSD image from MNIST IDX files.")
    parser.add_argument("--images", required=True,
                        help="IDX image file, e.g. train-images-idx3-ubyte")
    parser.add_argument("--labels", required=True,
                        help="IDX label file, e.g. train-labels-idx1-ubyte")
    parser.add_argument("--out", required=True,
                        help="card image to write")
    parser.add_argument("--limit", type=int, default=0,
                        help="use only the first N records (0 = all)")
    parser.add_argument("--dest-offset", type=lambda s: int(s, 0), default=0,
                        help="destination byte offset in the DDR3 window")
    args = parser.parse_args()

    images, n_img, rows, cols = read_idx(args.images)
    labels, n_lab, _, _ = read_idx(args.labels)

    if n_img != n_lab:
        raise SystemExit(
            f"error: {n_img} images but {n_lab} labels")

    if args.limit > 0:
        if args.limit > n_img:
            raise SystemExit(
                f"error: --limit {args.limit} but only {n_img} records")
        n_img = args.limit

    px = rows * cols
    image_bytes = images[:n_img * px]
    label_bytes = labels[:n_img]
    payload = image_bytes + label_bytes

    blocks = (len(payload) + BLOCK - 1) // BLOCK
    if blocks == 0:
        raise SystemExit("error: empty payload")

    checksum = sum(payload) & 0xFFFFFFFF

    header = [0] * HEADER_WORDS
    header[0] = MAGIC
    header[1] = blocks
    header[2] = args.dest_offset
    header[3] = len(payload)
    header[4] = n_img
    header[5] = rows
    header[6] = cols
    header[7] = 1
    header[8] = checksum

    with open(args.out, "wb") as handle:
        handle.write(struct.pack(f"<{HEADER_WORDS}I", *header))
        handle.write(payload)
        handle.write(b"\x00" * (blocks * BLOCK - len(payload)))

    # Read it back and check the file is what the header claims, so a
    # mistake here is caught on the host rather than on the board.
    with open(args.out, "rb") as handle:
        again = handle.read()

    if len(again) != BLOCK * (1 + blocks):
        raise SystemExit("error: image size does not match the header")
    back = struct.unpack("<9I", again[0:36])
    if back[0] != MAGIC or back[1] != blocks or back[3] != len(payload):
        raise SystemExit("error: header did not survive the round trip")
    body = again[BLOCK:BLOCK + len(payload)]
    if sum(body) & 0xFFFFFFFF != checksum:
        raise SystemExit("error: payload checksum does not match")

    print(f"wrote {args.out}")
    print(f"  records     {n_img} images of {rows}x{cols} + 1 label byte")
    print(f"  payload     {len(payload)} bytes in {blocks} blocks")
    print(f"  dest offset 0x{args.dest_offset:08x}")
    print(f"  checksum    0x{checksum:08x}")
    print(f"  image size  {len(again)} bytes "
          f"({1 + blocks} blocks incl. the header)")
    print()
    print("write it at LBA 0 of a dedicated card with:")
    print(f"  sudo dd if={args.out} of=/dev/sdX bs=512 conv=fsync")


if __name__ == "__main__":
    try:
        main()
    except ValueError as exc:
        sys.exit(f"error: {exc}")
