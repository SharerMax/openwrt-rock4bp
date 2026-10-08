#!/usr/bin/env python3
"""Assert that the SPI boot image really is a SPI boot image, of this build.

WHY A SEPARATE SCRIPT, AND WHY IT IS NOT JUST "the file exists"

OpenWrt's uboot-rockchip build produces two container shapes from one U-Boot
build, and only one of them is ever checked:

    u-boot-rockchip.bin       idbloader (rksd)  + U-Boot proper   -> eMMC / SD
    u-boot-rockchip-spi.bin   idbloader (rkspi) + U-Boot proper   -> SPI NOR

They are NOT interchangeable. They differ in the container type (rksd packs the
first stage contiguously, rkspi spreads it 2 KiB-on / 2 KiB-off inside every
4 KiB page) and in where U-Boot proper goes (LBA 0x4000 = byte 0x800000 for
eMMC, CONFIG_SYS_SPI_U_BOOT_OFFS for SPI). Feeding one to the other's flash
target produces a device that reaches the SPL and then stops, which looks like
a broken bootloader rather than a wrong file.

Until this was added, only the eMMC shape was checked at all: build.sh asserted
that both idbloader files exist and that the DRAM parameters are in the *staged
eMMC* container. A stale, truncated, or wrongly-packed SPI image therefore passed
every existing check and could only fail once written to the chip, which is the
worst place to find out.

WHAT IT CHECKS

    assert-spi-boot-image.py <spi.bin> <idbloader.img> [--u-boot-offset N]

    1. offset 0 carries the Rockchip rkimage magic
    2. the whole container, de-spread, equals <idbloader.img> byte for byte
       -- this is the load-bearing check. It proves both that the file is the
       rkspi variant AND that it was built from the same TPL/SPL as the eMMC
       one, so it cannot be a stale artefact from an earlier build.
    3. a FIT header sits at exactly <u-boot-offset>, which is what the SPL is
       configured to fetch from (CONFIG_SYS_SPI_U_BOOT_OFFS)

The offset is an argument rather than a constant because the useful failure
mode here is silent: a changed CONFIG_SYS_SPI_U_BOOT_OFFS moves it, and a
hardcoded check would keep passing on an image that the SPL can no longer use.
"""
import argparse
import sys

RKIMAGE_MAGIC = bytes.fromhex("3b8cdcfcbe9f9d51")  # Rockchip "RK33" loader header
FIT_MAGIC = bytes.fromhex("d00dfeed")

# rkspi's layout rule, from tools/rkspi.c: each 4 KiB page carries 2 KiB of
# payload followed by 2 KiB of padding. "Its rationale is unknown" -- upstream
# says so in the comment -- but the ROM requires it, so it is reproduced here
# rather than reasoned about.
PAGE = 4096
HALF = 2048


def die(msg):
    sys.stderr.write("assert-spi-boot-image: %s\n" % msg)
    sys.exit(1)


def unspread(buf, count):
    """Take `count` payload pages out of an rkspi-spread blob."""
    out = bytearray()
    for i in range(count):
        start = i * PAGE
        if start + HALF > len(buf):
            die("truncated: page %d runs past the end of the image" % i)
        out += buf[start:start + HALF]
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("spi_image")
    ap.add_argument("idbloader",
                    help="idbloader.img from the same build (the rksd form)")
    ap.add_argument("--u-boot-offset", type=lambda s: int(s, 0), default=0xE0000,
                    help="CONFIG_SYS_SPI_U_BOOT_OFFS for this build")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    notes = []
    say = notes.append if not args.verbose else (lambda s: print(s, file=sys.stderr))

    try:
        spi = open(args.spi_image, "rb").read()
    except OSError as e:
        die("cannot read %s: %s\n  CONFIG_ROCKCHIP_SPI_IMAGE must be enabled in the "
            "U-Boot defconfig; without it binman never emits this file"
            % (args.spi_image, e))
    try:
        sd = open(args.idbloader, "rb").read()
    except OSError as e:
        die("cannot read %s: %s" % (args.idbloader, e))

    if spi[:len(RKIMAGE_MAGIC)] != RKIMAGE_MAGIC:
        die("%s does not start with the rkimage magic (found %s)"
            % (args.spi_image, spi[:8].hex(" ")))

    # Page alignment is asserted on the FIRST STAGE only, not on the whole file.
    #
    # The trailing U-Boot FIT is padded to CONFIG_SYS_SPI_U_BOOT_OFFS + its own
    # length, and that sum is not a whole number of pages (0xE0000 + 0x13C400 =
    # 0x21C400 = 540.25 pages), so requiring a page-aligned file length fails on
    # a correct image. Only the rkspi container itself is page-structured.
    if len(sd) % HALF:
        die("%s is %d bytes, not a multiple of %d -- an idbloader is built from "
            "%d-byte chunks" % (args.idbloader, len(sd), HALF, HALF))

    # A spread blob is exactly twice the size of the contiguous one.
    if len(spi) < 2 * len(sd):
        die("%s is %d bytes, too small to be the 2K/2K spread of the %d-byte %s"
            % (args.spi_image, len(spi), len(sd), args.idbloader))

    # Each 4096-byte page in the SPI image carries 2048 bytes of payload, so the
    # page count is len(sd) / HALF, not len(sd) / PAGE.
    pages = len(sd) // HALF
    got = unspread(spi, pages)
    if got[:len(sd)] != sd:
        # Say which half differs, because "does not match" on a 192 KB blob is
        # not actionable.
        first = next((i for i in range(min(len(got), len(sd))) if got[i] != sd[i]), None)
        die("%s does not carry %s: after removing the rkspi 2K/2K spread the bytes "
            "differ, first at %s\n  This is either a stale image, or the rksd "
            "container was copied in without being spread -- the latter would "
            "reach the SPL and stop there."
            % (args.spi_image, args.idbloader,
               "offset %d" % first if first is not None else "length"))
    say("  first stage: %d bytes, 2K/2K-spread, identical to %s"
        % (len(sd), args.idbloader))

    if args.u_boot_offset + len(FIT_MAGIC) > len(spi):
        die("U-Boot proper would start at 0x%x but the image is only %d bytes"
            % (args.u_boot_offset, len(spi)))

    if spi[args.u_boot_offset:args.u_boot_offset + len(FIT_MAGIC)] != FIT_MAGIC:
        near = spi.find(FIT_MAGIC)
        die("no FIT header at 0x%x (CONFIG_SYS_SPI_U_BOOT_OFFS) in %s%s\n  The SPL "
            "fetches U-Boot proper from that offset; with it elsewhere the SPL "
            "finds nothing and the board stops after 'Trying to boot from SPI'."
            % (args.u_boot_offset, args.spi_image,
               "" if near < 0 else " -- the first FIT header is at 0x%x" % near))
    say("  U-Boot proper: FIT header at 0x%x" % args.u_boot_offset)
    say("  image size: %d bytes (0x%x)" % (len(spi), len(spi)))
    print("OK  %s is a %d-byte rkspi boot image for this build" % (args.spi_image, len(spi)))
    return 0


if __name__ == "__main__":
    sys.exit(main())