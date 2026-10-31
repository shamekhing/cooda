#!/usr/bin/env python3
"""Prepare a microSD card for the board: wipe it, pack MNIST onto it, verify.

One step from IDX files to a card the dock will boot from:

    sudo python3 tools/sd_flash.py --device /dev/sdX \
        --images data/mnist/train-images-idx3-ubyte \
        --labels data/mnist/train-labels-idx1-ubyte

The card's device is used raw - no filesystem, no partition table. The
tool wipes the front of the card (killing any partition table or
filesystem already there, which is the "format" a raw-block card
needs), packs the MNIST IDX files with the same code mnist_pack.py
uses, writes the image at LBA 0 (or --lba), reads every byte back and
checks it against the checksum.

The card is written with O_DIRECT-free plain block writes and fsync.
Nothing is written until the safety checks pass: the device must be a
block device, nothing on it may be mounted, the image must fit, and
either --yes was given or the user types "yes" at the prompt.

To leave a card's filesystem alone, wipe only the front, write at a
reserved LBA and set HDR_LBA in fpga_top's memory_sd instantiation to
the same LBA:

    sudo python3 tools/sd_flash.py --device /dev/sdX --lba 1048576 \
        --images ... --labels ...          # wipes 1 MiB, then writes
"""

import argparse
import os
import stat
import struct
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "mnist"))
import mnist_pack


def die(message):
    raise SystemExit(f"error: {message}")


def device_size(path):
    """A block device's size in bytes, by seeking past its end."""
    handle = os.open(path, os.O_RDONLY)
    try:
        return os.lseek(handle, 0, os.SEEK_END)
    finally:
        os.close(handle)


def device_model(path):
    """The card's model string from sysfs, or '' if it cannot be found."""
    name = os.path.basename(os.path.realpath(path))
    for candidate in (f"/sys/block/{name}/device/model",
                      f"/sys/class/block/{name}/device/model"):
        try:
            with open(candidate) as handle:
                return handle.read().strip()
        except OSError:
            pass
    return ""


def mounted_mountpoints(device):
    """Every mountpoint whose source is the device or one of its
    partitions, from /proc/mounts."""
    device = os.path.realpath(device)
    found = []
    with open("/proc/mounts") as mounts:
        for line in mounts:
            source = os.path.realpath(line.split(" ", 1)[0])
            rest = source[len(device):]
            own_partition = source == device
            numbered = rest.isdigit()
            named = rest.startswith("p") and rest[1:].isdigit()
            if own_partition or numbered or named:
                found.append(line.split(" ", 2)[1])
    return found


def unmount(mountpoints):
    """Best-effort unmount; returns the mountpoints still mounted."""
    for point in mountpoints:
        subprocess.run(["umount", point],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return [p for p in mountpoints if os.path.ismount(p)]


def write_chunks(fd, data, label):
    """Write bytes in 1 MiB chunks with a progress line."""
    total = len(data)
    written = 0
    while written < total:
        chunk = data[written:written + (1 << 20)]
        written += os.write(fd, chunk)
        print(f"\r  {label}: {written * 100 // total}% "
              f"({written} of {total} bytes)", end="", flush=True)
    print(f"\r  {label}: {total} bytes written")


def read_checksum(fd, start, length):
    """Read length bytes from start and sum them mod 2**32."""
    os.lseek(fd, start, os.SEEK_SET)
    total = 0
    left = length
    while left > 0:
        chunk = os.read(fd, min(1 << 20, left))
        if not chunk:
            die("the card ended before the image did - is it that small?")
        total += sum(chunk)
        left -= len(chunk)
    return total & 0xFFFFFFFF


def pack_image(args):
    """The card image in memory, built with mnist_pack's reader."""
    if not args.images or not args.labels:
        die("--images and --labels are required: this tool packs from IDX "
            "files itself")
    images, n_img, rows, cols = mnist_pack.read_idx(args.images)
    labels, n_lab, _, _ = mnist_pack.read_idx(args.labels)
    if n_img != n_lab:
        die(f"{n_img} images but {n_lab} labels")
    if args.limit > 0:
        if args.limit > n_img:
            die(f"--limit {args.limit} but only {n_img} records")
        n_img = args.limit

    px = rows * cols
    payload = images[:n_img * px] + labels[:n_img]
    blocks = (len(payload) + mnist_pack.BLOCK - 1) // mnist_pack.BLOCK
    header = [0] * mnist_pack.HEADER_WORDS
    header[0] = mnist_pack.MAGIC
    header[1] = blocks
    header[2] = args.dest_offset
    header[3] = len(payload)
    header[4] = n_img
    header[5] = rows
    header[6] = cols
    header[7] = 1
    header[8] = sum(payload) & 0xFFFFFFFF
    image = struct.pack(f"<{mnist_pack.HEADER_WORDS}I", *header) + payload
    image += b"\x00" * (mnist_pack.BLOCK * (1 + blocks) - len(image))
    return image, f"{n_img} records of {rows}x{cols} + 1 label byte"


def main():
    parser = argparse.ArgumentParser(
        description="Wipe a microSD card and write the COODA image to it.")
    parser.add_argument("--device", required=True,
                        help="the card's device on this PC, e.g. /dev/sdX")
    parser.add_argument("--images", help="IDX image file (packs a new image)")
    parser.add_argument("--labels", help="IDX label file (packs a new image)")
    parser.add_argument("--limit", type=int, default=0,
                        help="use only the first N records (0 = all)")
    parser.add_argument("--dest-offset", type=lambda s: int(s, 0), default=0,
                        help="destination byte offset in the DDR3 window")
    parser.add_argument("--lba", type=lambda s: int(s, 0), default=0,
                        help="first LBA to write (default 0)")
    parser.add_argument("--wipe-mb", type=int, default=4,
                        help="MiB wiped at the front of the card (0 = none)")
    parser.add_argument("--no-verify", action="store_true",
                        help="skip reading the image back")
    parser.add_argument("--yes", action="store_true",
                        help="do not ask for confirmation")
    args = parser.parse_args()

    if (args.images is None) != (args.labels is None):
        die("--images and --labels go together")

    image, what = pack_image(args)

    # ---- the target: a block device the image fits on ------------------
    if not os.path.exists(args.device):
        die(f"{args.device}: no such device")
    if not stat.S_ISBLK(os.stat(args.device).st_mode):
        die(f"{args.device}: not a block device (give the card's whole "
            "device, e.g. /dev/sdX, not one of its partitions)")

    size = device_size(args.device)
    start = args.lba * mnist_pack.BLOCK
    if start + len(image) > size:
        die(f"the image ({len(image)} bytes at LBA {args.lba}) does not "
            f"fit {args.device} ({size} bytes)")

    print(f"device    {args.device} "
          f"({size // (1 << 20)} MiB {device_model(args.device)})")
    print(f"image     {len(image)} bytes at LBA {args.lba}: {what}")
    if args.wipe_mb:
        print(f"wipe      the first {args.wipe_mb} MiB")

    # ---- nothing of ours may be mounted --------------------------------
    mounts = mounted_mountpoints(args.device)
    if mounts:
        print(f"  mounted at {', '.join(mounts)} - unmounting")
        still = unmount(mounts)
        if still:
            die(f"still mounted at {', '.join(still)} - unmount it first")

    # ---- consent ---------------------------------------------------------
    if not args.yes:
        answer = input(f"Destroy everything on {args.device}? "
                       "type 'yes' to continue: ")
        if answer.strip().lower() != "yes":
            die("aborted, nothing written")

    # Read/write: the verification pass reads the image back through the
    # same descriptor.
    fd = os.open(args.device, os.O_RDWR)
    try:
        # ---- the wipe: the front of the card loses its old content ------
        if args.wipe_mb:
            wipe_end = min(args.wipe_mb << 20, size)
            os.lseek(fd, 0, os.SEEK_SET)
            done = 0
            zero = bytes(1 << 20)
            while done < wipe_end:
                done += os.write(fd, zero[:min(1 << 20, wipe_end - done)])
            os.fsync(fd)
            print(f"  wiped {wipe_end >> 20} MiB")

        # ---- the image ---------------------------------------------------
        os.lseek(fd, start, os.SEEK_SET)
        write_chunks(fd, image, "write")
        os.fsync(fd)

        # ---- the check: read it all back and checksum it -----------------
        if not args.no_verify:
            exp = struct.unpack("<9I", image[:36])
            os.lseek(fd, start, os.SEEK_SET)
            head = os.read(fd, 36)
            magic, blocks, dest, plen = struct.unpack("<4I", head[:16])
            if magic != mnist_pack.MAGIC:
                die("the header did not survive the write (bad magic)")
            if plen != exp[3]:
                die("the header did not survive the write (bad length)")
            got = read_checksum(fd, start + mnist_pack.BLOCK, plen)
            if got != exp[8]:
                die(f"the card read back a different payload "
                    f"(checksum 0x{got:08x} != 0x{exp[8]:08x})")
            print("  verified the header and the payload checksum")
    finally:
        os.close(fd)

    print("done")
    if args.lba:
        print(f"remember: set HDR_LBA to {args.lba} "
              "in fpga_top's memory_sd instantiation")


if __name__ == "__main__":
    main()
