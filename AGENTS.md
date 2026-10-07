# AGENTS.md

Guidance for AI agents working in this repository.

This repo is the **port**, not the OpenWrt tree. It holds the overlay sources, the
scripts, and the documentation for `radxa_rock-4b-plus` on OpenWrt 25.12.5. The OpenWrt
tree itself lives on the build host at `/home/max/Code/openwrt`.

Read this before changing anything. Most of the rules below exist because the obvious
approach has already failed here, and the failure was expensive or silent.

---

## What is where

| Path | What it is |
|---|---|
| `README.md` | Entry point: current state, what is verified, what is not |
| `docs/` | Reference and post-mortem documents, one topic each |
| `overlay/` | Sources that get copied into or patched onto the OpenWrt tree |
| `scripts/` | Build, deploy and verification scripts |
| `log/` | Serial captures, **gitignored** — regenerate, never rely on them being present |

`overlay/` holds two different kinds of file and they must not be mixed:

- **Copied verbatim** into the tree: `*.mk`. Synchronised by `scripts/sync-overlay.sh`
  using its explicit path map.
- **Patch sources**: `*.dts`, `*defconfig`, `*-u-boot.dtsi`. They do **not** go into the
  tree. They are turned into patches in `target/linux/rockchip/patches-6.12/`.

`*.orig` files record what upstream looked like before this port edited the file. They
are deliberately excluded from the sync map — copying one over its counterpart would
revert the port.

---

## Before you change anything

1. **Check whether the thing you are fixing is actually a problem on hardware.** The
   original risk list turned out to be entirely wrong, because it was written from a
   hand-written device tree. Now that the tree inherits upstream, several items simply
   do not exist.
2. **Look for a silent fallback before blaming a build.** `scripts/Makefile.lib` picks
   the **first** `$(wildcard)` match, so adding a board file *displaces* the generic one
   instead of layering on it. Nothing warns.
3. **Prefer an assertion over a comment.** If a defect could slip past, add a check.
   The standard is "could this defect get through", not "did I change something".

## Reporting results

- **Do not report a build as working because the build returned 0.** Nine of the original
  checks passed while the bootloader was unusable on hardware.
- **Check the first line of the build log's timestamp** before trusting the verification
  block. A silently failed background launch made it read the previous run's log.
- **Compare device trees, not hashes, to judge whether two builds are the same thing.**
  Byte reproducibility does not hold here; semantic equivalence does. See
  [docs/postmortem-u-boot-ddr.md](docs/postmortem-u-boot-ddr.md).
- **Mark what is not verified.** "Untested" written as "not yet tested" implies somebody
  should go test it. Some items here are unverified *by decision*, and that distinction
  matters. Keep it.

## Naming verified vs unverified

Anything in a table of results must come from hardware. If a claim is inferred from a
build artefact, label it as such. Four claims in this repo were wrong for the same
reason — recorded as true when the finding was made, never revisited:

- "the image carries no bootloader" (it does — LBA 0x40 and LBA 0x4000)
- "shorting the SPI pins makes the boot ROM skip SPI" (measured: it does not)
- "the WiFi chip refuses to run firmware" (fixed by one property name, since resolved)
- "the port's bootloader has never run" (it has — maskrom writes eMMC without touching
  SPI, which was a fourth route nobody considered)

Documentation here goes stale faster than anyone remembers. When you change behaviour on
hardware, re-read the affected passages in the same pass.

## The port's own U-Boot is not trustworthy yet

**This is the highest-priority open problem.** It boots, and `rockchip,sdram-params`
works — but it panics 3 times out of 6 boots, always with a function pointer pointing at
non-code. The same kernel, dtb and rootfs boot reliably under Armbian's TPL, so the fault
is in DRAM initialisation. See [docs/postmortem-dram-instability.md](docs/postmortem-dram-instability.md).

- **Do not ship this port's bootloader** until it survives at least 6 consecutive boots.
  One successful boot out of six proves nothing.
- **Do not change the DRAM parameters on a hunch.** The current choice
  (`rk3399-sdram-lpddr4-100.dtsi`) is the same file upstream uses for the ROCK 4C+, so
  the selection is not obviously wrong. Get Armbian's U-Boot tree and diff first.
- **Maskrom can write eMMC** (`rkdeveloptool wl 0 <image>`), which leaves the working SPI
  bootloader alone and gives a stable control group. Prefer it over writing SPI.
- **Do not propose an upstream PR** until this is fixed — a port with an unstable
  bootloader is not worth submitting.

## Board facts worth knowing before you touch the device tree

- Boot order is **SPI → eMMC → SD**. A working SPI bootloader always wins, so a masking
  trick cannot force the use of an image-embedded bootloader.
- The image **does** embed its own bootloader. Earlier docs said otherwise.
- A bootloader needs **two files**: `idbloader*.img` is TPL+SPL only; U-Boot proper is
  a separate `u-boot.itb`.
- Linux cannot read this SPI flash correctly. It is deterministic, repeatable, and wrong.
  Do not attempt to back up or write the SPI from a running system — see the post-mortem.
- HDMI and audio are out of scope: no `CONFIG_DRM` / `CONFIG_SND`, and OpenWrt 25.12.5
  ships no matching kmod packages.

---

## Working with the OpenWrt tree

The tree is on a remote build host. Two repositories are involved and both must be left
clean:

```sh
# port repo
cd /home/max/Code/rockpi4bp && git status

# OpenWrt tree
cd /home/max/Code/openwrt && git status
```

Rules that are easy to get wrong:

- **`umask 022`.** The build host defaults to `0002` and `include/prereq-build.mk`
  refuses anything else. `scripts/build.sh` sets it.
- **After changing `DEVICE_PACKAGES`, run `make defconfig`.** Otherwise the build prints
  one warning line and packages the old set anyway.
- **`scripts/config` is a directory**, not the old helper script. To change `.config`,
  edit it in kconfig format and let `make defconfig` normalise it.
- **When regenerating a patch, the "pristine" baseline must really be pristine.** Using
  last build's already-patched file as the baseline adds the same line twice.
  `scripts/regen-dts-patch.sh` strips leftovers and asserts they are gone.
- **A new package needs an explicit `Build/Compile`** and `include $(INCLUDE_DIR)/package.mk`.
  Omitting the latter does not look like a missing include — it looks like the package was
  not selected, which sends you down the wrong path entirely.

## Scripts

| Script | Use |
|---|---|
| `build.sh` | Fix the manifest, then build, then run 17 post-build checks |
| `sync-overlay.sh` | Compare `overlay/` against the tree; copy either way, direction must be explicit |
| `check-patch-sources.sh` | Check each patch source against the patch it generates |
| `regen-dts-patch.sh` | Regenerate the kernel DTS patch, with `dtc` validation |
| `assert-sdram-params-in-image.py` | Assert the RK3399 DRAM parameters are in the image |
| `deploy.sh` | Write the image to USB / SD / eMMC |
| `wifi-test.sh` | AP6256 power-on testing, one cold boot per combination |
| `write-idbloader-sd.ps1` | Windows: write `idbloader` to LBA 0x40 on a card |

`deploy.sh` and `write-idbloader-sd.ps1` destroy data. Run the list/verify/preview paths
first, every time — `--list`, `--verify`, and `-Preview` exist for that reason, and the
preview path is what caught two bugs in the destructive one.

Two specific footguns worth knowing before you touch hardware:

- **eMMC currently holds the OpenWrt image** (p1 16 MiB + p2 512 MiB, disk signature
  `0x5452574f`). An Armbian install that was there earlier was destroyed by a `dd` with
  no backup. Read it read-only first if you need to know what is on it.
- **`deploy.sh` defaults to the squashfs image.** The board has been running ext4. Pass
  the variant explicitly or you will flash a different image than the one you tested.

## House conventions

- LF line endings in the tree and the working tree (`.gitattributes`). These files are
  consumed by `make`, `sh` and `dtc`, and a stray CR fails in ways unrelated to line
  endings.
- Comments explain **why**, and record what was ruled out and how. A comment that only
  restates the code is noise.
- No credentials, keys or tokens in this repository.
- Commit messages state what changed and why, including anything the change retracts.