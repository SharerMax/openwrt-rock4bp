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

## The port's U-Boot now clears the six-boot bar; the cause is still open

**The `&vdd_log` build now clears the bar this repository set: six consecutive clean
boots.** Measured 2026-10-08 with `scripts/check-reboot-matrix.sh` — six boots, six
distinct `boot_id`s, identical `MemTotal`, zero panic/oops/BUG lines in dmesg. The
baseline it replaces was 3 panics in 6 boots (50%); Armbian's bootloader was 7 boots,
zero panics. The only change was `&vdd_log { regulator-init-microvolt = <950000>; }`.

**The cause is still NOT located, and that is the remaining problem.** Six clean boots
is a threshold, not a diagnosis. Specifically:

- **The causal chain was never closed.** The hypothesis is that the rail voltage
  U-Boot left behind degraded the SDIO timing margin (phase 269 versus the low 220s)
  and that this relates to the panic. Nothing links rail voltage to the crash site at
  `rk3x_i2c_irq`. It is **compatible, not established.**
- **Six clean boots does not mean a zero failure rate.** The fault was intermittent.
  Six boots say "did not occur in six", not "cannot occur".
- **Do not propose an upstream PR yet.** Without a located cause nobody else can
  reproduce it, so nobody can tell whether the voltage line is actually necessary.

**Do not report this as "root cause found".** Report it as "threshold met, cause open".

⚠️ **The SDIO phase value is a rail indicator, not a build fingerprint.** It is the only
observable in the logs that moved — 269 on every pre-vdd_log boot that probed SDIO, and
221/224/225/223 on the vdd_log boots. I called it a "flash fingerprint" and was wrong:
it varies per boot, so **assert the band, never the exact number.** My first band was
220-224 and it failed a real reading of 225 — widen it from observed readings only.

- **The six-boot bar was met on 2026-10-08, so the image is deliverable.** What is
  still open is the cause, not the stability. Keep those two separate in every status
  report: *threshold met* is not *root cause found*.
- **The obvious hypothesis is already dead.** `rk3399-sdram-lpddr4-100.dtsi` is
  byte-identical between v2022.07 (Armbian) and v2025.10 (this port) — sha256
  `2874c640…`. Same DRAM CONFIGs, same board dtsi, and the driver differs by 3%.
- **The "50MHz vs 400MHz" serial-output difference is real, not a printing artefact.**
  `sdram_print_ddr_info()` runs inside the channel loop, and by then the early
  `lpddr4_set_rate` has already moved the controller to 400MHz, so the printed number
  tracks the state the configuration writes actually happen at. The board rate is
  **50MHz** — index 34 of the flat u32 array, pinned by the struct total
  `34+5+332+200+959 = 1530` matching the dtsi, plus `num_channels`, `stride` and `odt`
  all agreeing with `sdram-rk3399-lpddr4-400.inc`. I once decoded this as 80 from a
  buggy script and the wrong number reached the patch header and the docs; the serial
  print of 50MHz is the evidence it was wrong.
- **DRAM initialisation is now ruled out, by experiment.** `0103-…-lpddr4-configure-before-training.patch`
  restores the v2022.07 order (50MHz, configure, then train and switch), the serial
  log confirms it took effect, and the fault is unchanged — tty13's second boot is
  identical to tty12's down to the ESR, the PC `0xdfff800080099ee4`, the link register
  and `rk3x_i2c_irq+0x198/0x3a0`. Two boots, two panics. The patch is kept so both
  bootloaders share one DRAM sequence and future comparisons have a single variable,
  not because it fixes anything. It diverges from upstream: delete it when it stops
  earning its place.
- **What is left is elsewhere in the bootloader, and the next experiment is built and
  waiting.** The board dtsi override this port omits: `&vdd_log {
  regulator-init-microvolt = <950000>; }`. It matters because the kernel's own node in
  `rk3399-rock-pi-4.dtsi` is a pwm-regulator with only `regulator-min/max-microvolt`
  and no `regulator-init-microvolt` — so whatever U-Boot leaves is what the kernel
  keeps, and this port left nothing. Upstream `rk3399-rock-pi-4-u-boot.dtsi` and
  Radxa's own `rk3399-rock-4c-plus-u-boot.dtsi` both set it. **Untested.** Only that
  one property was added; `&sdhci` and the `leds` node stay out so that a failure is
  attributable. Build with `scripts/build.sh`, flash with maskrom, and the verdict is
  six clean boots — not one. **tty14 is one success; run five more before claiming
  anything is fixed.**
- **The SDIO phase value is a rail indicator, not a build fingerprint.** Nothing in the
  serial log says which bootloader ran: TPL prints a version string, not the properties
  we changed, and a rail voltage is never printed. `dwmmc_rockchip`'s tuned phase is the
  only observable that moved — 269 on every pre-vdd_log boot that got as far as probing
  it, 220-224 on every vdd_log boot, and Armbian sits at 220-223 too.
  ⚠️ **Do not assert an exact value.** I wrote "only the new bootloader produces 221"
  and the next boot of the same image read 224. It varies per boot; assert the band.
  ⚠️ **A missing value means the boot died before tuning, not that the value was zero** —
  and it cuts both ways: two panics happened *after* tuning, at 0.64s and 1.39s, so
  "it always crashes around half a second" is wrong.
- **Count boots by splitting on the TPL banner, never by counting panic lines.** tty8
  and tty13 each contain two boots, so a naive count of `Kernel panic` occurrences
  inflates the sample. Every boot count in this repo was re-derived this way.
- **The omission was an accident, not a decision.** The dtsi said it was skipping
  `rk3399-rock-pi-4-u-boot.dtsi` because its `&sdhci` timing and `leds` node were not
  what was missing. That reasoning covered the whole file, and `&vdd_log` went with it
  without ever being looked at separately. **A general argument about a file is not a
  reason about every item in it.**
- **A `&label` absent from the U-Boot tree may still resolve.** `vdd_log` is defined
  nowhere in U-Boot's RK3399 dtsi chain — only in the rk3288, rk3368, px30, rk3229
  trees and in `rk3399-rock960-u-boot.dtsi`. The override works anyway, because this
  recipe builds the U-Boot control FDT from the kernel's own dtb plus the
  `-u-boot.dtsi`, and the node comes from the kernel side. Settle it by comparing the
  two dtbs rather than by reading source: the kernel's has no init value, U-Boot's has
  0xe7ef0.
- **A test script that edits the build tree must restore it on the failure path too.**
  `set -e` kills it before the restore, the tree keeps the edit, and the next build
  faithfully produces output missing the change — with no warning anywhere. Use `trap`,
  or work on a copy. It happened here, and the only thing that caught it was an
  assertion on the compiled output.
- **Do not assume mainline v2022.07 is what Armbian runs.** Its banner is
  `2022.07_armbian-…`, it patches its own U-Boot, and its parameters differ from
  ours. Those patches are not available, so mainline v2022.07 ordering is the closest
  we can get, not the same thing.
- **Count your variables before claiming a cause.** The tty11-vs-tty12 comparison changed
  the bootloader *and* the boot medium at the same time; they were perfectly collinear, so
  it did not support "the TPL is at fault". As of 2026-10-08 both columns have been run
  from eMMC — Armbian 7 boots with zero panics, ours 6 with 3 — so the bootloader is
  now the only variable. That cell was closed by rebooting the box six times.
- **`ConnectTimeout` does not bound an ssh call.** It only covers the TCP connect; the
  askpass/password exchange can block indefinitely. A reboot loop sat on one call for four
  minutes while the board had already rebooted and was answering normally. Wrap every ssh
  in `timeout` and judge reachability by the wrapper's exit status.
- **The board answers at `192.168.3.8`** as `root` with **no password**. Read-only
  inspection is fine and has been useful — the SPI retest, the eMMC matrix and the
  reboot matrix all came from it. It now runs this port's own OpenWrt image, not
  Armbian, and its host key changed when that image was written
  (`SHA256:qgJ+OCni…`, old Armbian-era key `SHA256:bkOdpYyr…` retired). **Check which
  key you have before assuming a host is the board.**
- **No serial console means the reboot loop is the only way to reach the six-boot
  threshold here.** With the board on the network, reboot over ssh and poll `boot_id`
  gives the same evidence the serial capture gave for Armbian: each boot must show a
  new `boot_id`, a clean dmesg, and a phase in the rail band. **A boot that never comes
  back is a result, not a retry** — the panic lands at 0.5-1.4s, before networking.
- **`nohup reboot &` over ssh does not reboot the board.** The process dies with the
  pty when ssh exits, the board never goes down, and the result looks exactly like a
  successful no-op: `reboot` exits 0, the board keeps answering, `boot_id` is
  unchanged. **This wasted two rounds of a five-round matrix before the `boot_id`
  assertion caught it** — which is the argument for that assertion. Use
  `setsid reboot </dev/null &`, and keep checking `boot_id` rather than trusting
  the trigger's exit status.
- **Maskrom can write eMMC** (`rkdeveloptool wl 0 <image>`). Prefer it over writing SPI —
  ⚠️ though note SPI currently holds nothing bootable, so it is not itself a fallback.
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
| `check-doc-links.py` | Check every relative markdown link resolves, including `#anchor` headings |
| `check-reboot-matrix.sh` | Reboot the board N times and judge each boot; needs no serial console |
| `regen-dts-patch.sh` | Regenerate the kernel DTS patch, with `dtc` validation |
| `assert-sdram-params-in-image.py` | Assert the RK3399 DRAM parameters are in the image |
| `deploy.sh` | Write the image to USB / SD / eMMC |
| `wifi-test.sh` | AP6256 power-on testing, one cold boot per combination |
| `write-idbloader-sd.ps1` | Windows: write `idbloader` to LBA 0x40 on a card |

`deploy.sh` and `write-idbloader-sd.ps1` destroy data. Run the list/verify/preview paths
first, every time — `--list`, `--verify`, and `-Preview` exist for that reason, and the
preview path is what caught two bugs in the destructive one.

Two specific footguns worth knowing before you touch hardware:

- **⚠️ eMMC now holds this port's OpenWrt image** (written 2026-10-08 for the `vdd_log`
  test, boot `tty14`, phase 221). An OpenWrt image was written there on 10-06 and an
  earlier Armbian was destroyed by a `dd` with no backup. **⚠️ SPI no longer holds a
  bootable image.** tty14's log prints `Trying to boot from BOOTROM` /
  `Returning to boot ROM...`, which is what the ROM says when it found nothing on SPI
  and fell through to eMMC — even though boot order is SPI first. Maskrom `wl` did not
  write SPI, but SPI is not providing a recovery path either, and I had asserted that it
  was without checking. **The recovery path right now is Maskrom.** This line has been
  rewritten four times; read it read-only before writing.
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