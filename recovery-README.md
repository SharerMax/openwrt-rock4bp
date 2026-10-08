# recovery/

**Not tracked in git.** It exists only here, on the build host, and it is
regenerated rather than committed — the artefacts are binaries totalling ~14 MB
and they are not the source of anything.

## What belongs here

Exactly one set of artefacts: **the build that was last measured on hardware.**

Populate it only after a build has cleared its own acceptance check, and record
which check in `SHA256SUMS.txt`. An artefact set that has not been measured is
worse than no artefact set, because a recovery is the one moment where nobody is
reading carefully.

## Why that rule is here

It was violated, and the result sat in this directory for two days:

- Everything in here was the **base** build from 2026-10-06 — image sha256
  `5a09fc41…`, `idbloader.img` `b8fa872f…`. That build **panics the kernel on 3
  of 6 boots.** Anyone reaching for a recovery artefact under pressure would
  have flashed a bootloader with a known 50% failure rate.
- Alongside it sat `spi-working-armbian.bin`, a 4 MiB dump that is **not real
  chip content**. It contains zero FDT magics, zero occurrences of the string
  `U-Boot`, and zero RK33 header magics — a genuine U-Boot image carries at
  least three DTBs and prints its own version banner. The printable runs it does
  contain are DRAM residue that happens to include U-Boot fragments.

That dump was deleted rather than kept with a warning, because a file named
`spi-working-*.bin` invites exactly the wrong use.

## Note on the SPI dump, since it is easy to re-create this mistake

The original claim about the dump — that two consecutive reads of the same
64 KiB gave different md5 sums — was measured against the **chip**, through
Linux's SPI driver. Re-reading the saved file twice gives an identical md5, of
course, and proves nothing.

⚠️ **Counting byte patterns in a binary needs a real byte search.**
`grep -c -a -o $'\xd0\x0d\xfe\xed' file` reported 348 on a file with zero
matches, because `grep -c` counts matching *lines* and binary data has no lines
to speak of. Use something that counts occurrences.

## Current contents

The build measured on 2026-10-08, which **passed 21/21 post-build checks and six
consecutive clean boots** with patch `0103` removed:

```
idbloader.img                        192512    TPL + SPL, for eMMC boot
idbloader-spi.img                    385024    TPL + SPL, for SPI boot
u-boot.itb                          1295360    U-Boot proper
openwrt-radxa_rock-4b-plus-ext4.img 603979776 full disk image, for Maskrom
SHA256SUMS.txt
```

Verify before using any of it:

```sh
sha256sum -c SHA256SUMS.txt
```

The uncompressed `.img` is the one to hand to Maskrom, because that is currently
the **only** recovery path — SPI holds nothing bootable (see
`../docs/boot-order.md`):

```sh
sudo rkdeveloptool db rk3399_loader_v1.27.126.bin
sudo rkdeveloptool wl 0 openwrt-radxa_rock-4b-plus-ext4.img
```

That image embeds the same bootloader as `idbloader.img` at LBA 0x40; this was
checked by comparing the rkimage at 0x8000 against the staging copy
(`fe4165bea40d399d8b867d34…`), not assumed.

### The squashfs image is deliberately absent

Only the ext4 variant was measured. `deploy.sh` defaults to squashfs while this
board has always run ext4, so carrying both here would invite flashing the wrong
one. If you need squashfs, build it and measure it first.

### ⚠️ If you rebuild this from the `.img.gz`, do not be alarmed by `gzip`

The OpenWrt sysupgrade `.gz` has **274 bytes of JSON metadata appended after the
gzip stream** (`{"metadata_version": "1.1", ...}`), so:

```
gzip -t <image>.img.gz      → exit 2, "trailing garbage ignored"
gzip -dc <image>.img.gz     → exit 2, but the image is complete and correct
```

This is OpenWrt's own layout — the metadata is there so `sysupgrade` can read it
without decompressing the whole image — **not corruption**. Verified here: the
gzip stream ends at byte 12811498 of a 12811772-byte file, and the 274 trailing
bytes are that JSON.

`scripts/deploy.sh` has a check for exactly this. Do not "fix" the `.gz`.
