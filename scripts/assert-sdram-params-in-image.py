#!/usr/bin/env python3
"""Assert that rockchip,sdram-params is present in a bootloader container.

WHY THIS IS A SEPARATE SCRIPT

The post-build checks in build.sh are one-liners in shell. This one cannot be,
and the reason matters: the property is a big-endian u32 array inside a
big-endian FDT, so the needle has to be derived from the compiled device tree
and validated against it before being used anywhere else.

That validation is the whole point. A needle typed from memory was tried first
and it did not occur in u-boot.dtb at all, while apparently matching both the
staged container and the image -- a coincidental byte sequence. Reported
without the sanity check it would have "confirmed" either answer. A check that
can pass on garbage is not a check.

WHAT IT CHECKS

    <container> [--offset N] <u-boot.dtb>

Pass 0: derive the leading u32s of rockchip,sdram-params from the dtb, pack them
big-endian, and require the result to occur in that dtb. If it does not, the
script exits non-zero rather than reporting anything -- an unusable needle must
not produce a verdict.

Pass 1: count occurrences in the container. For the staged file that is the
answer directly. For a gzipped disk image, --offset gives where the container
lives and the image is decompressed first.

Note the sysupgrade image has a metadata member after the gzip stream, so it is
read with zlib and only the first stream is taken. gzip.open() walks into that
member and fails, which is the same reason gzip -t exits 2 on these files.
"""
import argparse
import re
import struct
import subprocess
import sys
import zlib

LEAD = 24  # leading words used as the needle


def die(msg):
    sys.stderr.write("assert-sdram-params: %s\n" % msg)
    sys.exit(1)


def dtb_values(dtb_path, dtc):
    """The leading u32s of rockchip,sdram-params, read out of the device tree."""
    dtb = open(dtb_path, "rb").read()
    if dtb[:4] != bytes.fromhex("d00dfeed"):
        die("%s is not a big-endian FDT (magic %s); refusing to guess the cell order"
            % (dtb_path, dtb[:4].hex(" ")))
    txt = subprocess.run([dtc, "-I", "dtb", "-O", "dts"],
                         input=dtb, capture_output=True).stdout.decode("ascii", "replace")
    m = re.search(r"rockchip,sdram-params\s*=\s*<([^>]*)>", txt)
    if not m:
        die("no rockchip,sdram-params in %s -- the fix is not in the build" % dtb_path)
    return [int(v, 0) for v in m.group(1).split()], dtb


def count(blob, needle):
    n, off = 0, 0
    while True:
        off = blob.find(needle, off)
        if off < 0:
            return n
        n += 1
        off += 1


def load(path, offset):
    with open(path, "rb") as f:
        head = f.read(2)
    if head == b"\x1f\x8b":
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        with open(path, "rb") as f:
            blob = d.decompress(f.read())
        return blob[offset:]
    with open(path, "rb") as f:
        f.seek(offset)
        return f.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("container")
    ap.add_argument("dtb")
    ap.add_argument("--offset", type=lambda s: int(s, 0), default=0,
                    help="byte offset of the rkimage container inside the file")
    ap.add_argument("--dtc", required=True)
    ap.add_argument("--verbose", action="store_true",
                    help="explain the needle even on success")
    args = ap.parse_args()

    # Diagnostics are collected and only printed when something goes wrong, so
    # the post-build verification block in build.sh stays scannable: a passing
    # check prints one line, a failing one prints why.
    notes = []
    say = notes.append if not args.verbose else (lambda s: print(s, file=sys.stderr))

    vals, dtb = dtb_values(args.dtb, args.dtc)
    if len(vals) < LEAD:
        die("only %d words of sdram-params, need %d" % (len(vals), LEAD))
    say("  sdram-params: %d words in the compiled device tree" % len(vals))

    # Try both cell orders and keep whichever the device tree itself confirms.
    chosen = None
    for name, fmt in (("big", ">"), ("little", "<")):
        cand = b"".join(struct.pack(fmt + "I", v) for v in vals[:LEAD])
        hits = count(dtb, cand)
        say("  needle %-6s endian: %d hit(s) in the dtb" % (name, hits))
        if hits and chosen is None:
            chosen = (name, cand, hits)
    if chosen is None:
        die("no needle validated against %s -- refusing to report a verdict\n  %s"
            % (args.dtb, "\n  ".join(notes)))

    name, needle, dtb_hits = chosen
    say("  using the %s-endian needle, %d hit(s) in u-boot.dtb" % (name, dtb_hits))

    blob = load(args.container, args.offset)
    n = count(blob, needle)
    if n == 0:
        sys.stderr.write("  %s: NO DRAM parameters found%s\n%s\n"
                         % (args.container,
                            (" at offset 0x%x" % args.offset) if args.offset else "",
                            "\n".join(notes)))
        return 1
    say("  %s: %d occurrence(s) of the DRAM parameters" % (args.container, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
