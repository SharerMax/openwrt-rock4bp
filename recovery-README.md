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

The build measured on 2026-10-08, which **passed 21/21 post-build checks** (the count
at the time; the tree has grown to 24 since) **and six consecutive clean boots** with
patch `0103` removed:

```
idbloader.img                        192512    TPL + SPL, for eMMC boot
idbloader-spi.img                    385024    TPL + SPL, for SPI boot
u-boot.itb                          1295360    U-Boot proper
openwrt-radxa_rock-4b-plus-ext4.img 603979776 full disk image, for Maskrom
SHA256SUMS.txt
```

⚠️ **A fresh build reproduces these artefacts again — as of 2026-10-10 that is
literally true.** The tree is back on `regulator-init-microvolt = <950000>`, the
shipping value, after two measurement rounds (800 mV and 1100 mV) that existed only
to find out what the variable was. **A fresh build's `idbloader.img`,
`idbloader-spi.img` and `u-boot.itb` are byte-identical to the files here:**

```
76bf3bcf7be75197  idbloader.img
62e4142cd70f39bf  idbloader-spi.img
d466c390c57eaa5d  u-boot.itb          (rkimage at 0x8000: fe4165bea40d399d…)
```

⚠️ **The disk image still will not match.** This directory holds the uncompressed
ext4 image written on 10-08; a fresh `build.sh` produces a `.gz` whose contents
differ because the rootfs is rebuilt. **The bootloader is reproducible; the disk
image is not.** Verify with `sha256sum -c SHA256SUMS.txt` rather than by comparing
a fresh build to this directory.

⚠️ The rule below is unchanged and is the reason the distinction above is written
down: **an artefact set in the tree is a claim; one in here has a measurement
behind it.** A build that has never been flashed does not become the recovery
artefact by being reproducible.

⚠️ **So: if you are reaching for a recovery artefact, use the files in this directory,
not whatever `build.sh` most recently produced.** This directory exists precisely
because a build in the tree is a claim while a build in here has a measurement behind
it. When the 800 mV experiment has been run, this directory gets replaced — not
alongside — by whichever of the two is the last one actually measured.

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

### ⚠️ `rk3399_loader_v1.27.126.bin` is the eMMC loader — it will never write SPI

The `db` command pushes a Rockchip loader onto the SoC, and **the loader decides
which storage the later commands address**. The two commands above are correct
and verified for eMMC, and they say nothing about SPI:

```
rk3399_loader_v1.27.126.bin        -> eMMC     (the one used here)
rk3399_loader_spinor_*.bin        -> SPI NOR   (a different file entirely)
```

⚠️ **With the wrong loader `wl` reports success while writing to the other
medium.** Nothing errors, nothing warns. That is why "Maskrom `wl` does not touch
SPI" was believed here for a while — the observation was right and the mechanism
was wrong.

For SPI use `../scripts/flash-spi.sh`, which refuses a loader whose name does not
contain `spinor`. ⚠️ **`--write` has not been run on hardware by this port**, and
the loader version is unsettled (Radxa ships `spinor v1.15.114` and documents
that v1.72-and-later boards need `v1.20.126`; this board's revision has not been
identified). See [docs/boot-order.md](../docs/boot-order.md).

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
