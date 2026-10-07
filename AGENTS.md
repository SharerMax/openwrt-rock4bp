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

**This is the highest-priority open problem, and the cause is NOT located.** It boots, and
`rockchip,sdram-params` works — but it panics 3 times out of 6 boots, always with a
function pointer pointing at non-code. See
[docs/postmortem-dram-instability.md](docs/postmortem-dram-instability.md).

- **Do not ship this port's bootloader** until it survives at least 6 consecutive boots.
  One successful boot out of six proves nothing.
- **The obvious hypothesis is already dead.** `rk3399-sdram-lpddr4-100.dtsi` is
  byte-identical between v2022.07 (Armbian) and v2025.10 (this port) — sha256
  `2874c640…`. Same DRAM CONFIGs, same board dtsi, and the driver differs by 3%. The
  "50MHz vs 400MHz" serial-output difference is an artefact of where `base.ddr_freq`
  is assigned relative to the printf, not a difference in training frequency.
- **The one real difference found**: v2025.10 moves the LPDDR4 switch to 400MHz to
  *before* `set_memory_map` / `calculate_ddrconfig` / `set_ddrconfig` /
  `dram_all_config`. v2022.07 configured all of that at the dtsi rate and bumped the
  frequency only at the end. That is upstream mainline code, so reverting it may break
  other boards.
- **Count your variables before claiming a cause.** The tty11-vs-tty12 comparison changed
  the bootloader *and* the boot medium at the same time; they were perfectly collinear, so
  it did not support "the TPL is at fault". As of 2026-10-08 both columns have been run
  from eMMC — Armbian 7 boots with zero panics, ours 6 with 3 — so the bootloader is
  now the only variable. That cell was closed by rebooting the box six times.
- **`ConnectTimeout` does not bound an ssh call.** It only covers the TCP connect; the
  askpass/password exchange can block indefinitely. A reboot loop sat on one call for four
  minutes while the board had already rebooted and was answering normally. Wrap every ssh
  in `timeout` and judge reachability by the wrapper's exit status.
- **The board answers at `192.168.3.184`** as `root` / `armbian`. Read-only inspection is
  fine and has been useful — the SPI retest and the eMMC matrix both came from it.
- **Maskrom can write eMMC** (`rkdeveloptool wl 0 <image>`), which leaves the working SPI
  bootloader alone. Prefer it over writing SPI.
- **Do not propose an upstream PR** until this is fixed.

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

- **eMMC currently holds Armbian again** (reinstalled 2026-10-08: one 28.6 GB ext4,
  `root=UUID=7043da66-…`), reachable at `192.168.3.184` as `root`/`armbian`. An OpenWrt
  image was written there on 10-06 and an earlier Armbian was destroyed by a `dd` with no
  backup. This line has been rewritten three times; read it read-only before writing.
- **Linux cannot read this SPI flash correctly, on any kernel.** Armbian 6.18.54 gives two
  different md5 sums for two consecutive reads of the same 64 KiB and zero strings ≥12
  chars. So `recovery/spi-working-armbian.bin` is not real U-Boot data — it contains zero
  FDT magics. Do not use it as a reference.
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