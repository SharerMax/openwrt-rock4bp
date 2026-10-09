#!/bin/bash
# Full build for the Radxa ROCK 4B+ port.
#
# Run from the OpenWrt tree on the build host. This script is the tracked source
# of truth for the manifest decisions, because .config itself is gitignored and
# only exists on the build host.
#
# The post-build verification block at the end is not decoration. This port has
# twice shipped an image that built with exit code 0 and was missing something
# essential, and both times the only way to notice was to look at the output
# rather than at the exit status.
cd /home/max/Code/openwrt || exit 99

# Helper scripts live beside this one, not in the OpenWrt tree the checks run
# against. Resolving them from $0 keeps the two apart -- a relative path here
# fails only when the check runs, and prints a bare "No such file" that looks
# like a missing helper rather than a wrong directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
umask 022
LOG=/tmp/build-full.log
: > "$LOG"

# Recorded before anything else so the log can be dated. On 2026-10-06 a build was
# launched with setsid/nohup, failed to start without any error, and the
# verification block then read this file from the *previous* run and reported a
# clean build. Nothing had been compiled and the image was unchanged. Dating the
# log makes that class of mistake visible instead of silent.
START="$(date '+%Y-%m-%d %H:%M:%S')"
echo "=== build started $START ===" >> "$LOG"

{
  echo "=== manifest fixups ==="

  # Disable BCM4329 firmware (Raspberry Pi 3B era); the module on this board is
  # an AP6256 = BCM43456. It is a CONFIG_PACKAGE_ entry (not CONFIG_DEFAULT_), so
  # it came from a hand-edited .config and no device definition asks for it.
  #
  # Note: scripts/config is a build directory in current OpenWrt, and
  # scripts/kconfig.pl has no --disable option, so edit .config directly in the
  # format kconfig expects and let make defconfig normalise it.
  if grep -q '^CONFIG_PACKAGE_brcmfmac-firmware-4329-sdio=y$' .config; then
    sed -i 's/^CONFIG_PACKAGE_brcmfmac-firmware-4329-sdio=y$/# CONFIG_PACKAGE_brcmfmac-firmware-4329-sdio is not set/' .config
    echo "disabled PACKAGE_brcmfmac-firmware-4329-sdio"
  else
    echo "PACKAGE_brcmfmac-firmware-4329-sdio already disabled"
  fi

  # NOTE: do not try to drop brcmfmac-firmware-usb here. OpenWrt's
  # package/kernel/mac80211/broadcom.mk declares
  #     +BRCMFMAC_USB:kmod-usb-core +BRCMFMAC_USB:brcmfmac-firmware-usb
  # and BRCMFMAC_USB=y in the mac80211 backports config, so any device with
  # kmod-brcmfmac gets it -- nanopc-t4 and radxa_rock-3c included. Disabling it
  # here only gets undone by make defconfig. Keeping it would mean patching the
  # mac80211 backports Kconfig to drop ~500 KB of unused USB WiFi firmware,
  # which is not worth the noise and would not be upstreamable.

  echo
  echo "=== defconfig ==="
  # Required after DEVICE_PACKAGES changes: the DEFAULT_* entries derived from
  # them are stale otherwise, and the build only warns while quietly shipping the
  # previous package set.
  make defconfig
  echo "REAL_DEFCONFIG_EXIT=$?"

  echo
  echo "=== resulting wifi/eth package state ==="
  grep -E "brcmfmac|brcmutil|r8169|cypress-firmware-4356" .config | grep -v "^#" || true

  echo
  echo "=== build ==="
} >> "$LOG" 2>&1

make -j10 >> "$LOG" 2>&1
rc=$?
echo "REAL_EXIT_CODE=$rc" >> "$LOG"

{
  echo
  echo "=== post-build verification ==="

  check () {
    if eval "$2"; then echo "  OK      $1"; else echo "  FAILED  $1"; fi
  }

  check "43456 firmware apk built" \
    "ls bin/packages/*/base/brcmfmac-firmware-43456-sdio-*.apk >/dev/null 2>&1"

  M=bin/targets/rockchip/armv8/openwrt-rockchip-armv8-radxa_rock-4b-plus.manifest
  check "43456 firmware in image manifest" "grep -q '^brcmfmac-firmware-43456-sdio ' $M"
  check "brcmfmac driver in image manifest" "grep -q '^kmod-brcmfmac ' $M"

  for p in brcmfmac-firmware-4329-sdio kmod-r8169 cypress-firmware-4356-sdio \
           brcmfmac-nvram-4356-sdio; do
    check "absent from manifest: $p" "! grep -q '^$p ' $M"
  done

  # The dtb must be NEWER than the patch that produces it, and it must actually
  # contain the properties this port depends on.
  #
  # A size assertion is not enough, and it is not even a staleness check: on
  # 2026-10-06 a build was launched, silently failed to start, and the
  # verification block then read a log from the previous run and reported nine
  # OK lines and REAL_EXIT_CODE=0. Nothing had been compiled. Worse, a stale dtb
  # still has the right size, so "dtb is the current 63779-byte build" passed
  # while the tree contained none of the changes.
  #
  # Two assertions, because either alone has a failure mode:
  #   - mtime: catches "not rebuilt at all"
  #   - content: catches "rebuilt from the wrong source", and is the one that
  #     actually proves the WiFi power-sequence fix is in the image
  PATCH=target/linux/rockchip/patches-6.12/0001-arm64-dts-rockchip-add-Radxa-ROCK-4B-plus.patch
  DTB=build_dir/target-aarch64_generic_musl/linux-rockchip_armv8/image-rk3399-rock-4b-plus.dtb
  DTC=build_dir/target-aarch64_generic_musl/linux-rockchip_armv8/linux-6.12.94/scripts/dtc/dtc

  check "dtb is newer than the patch that builds it" \
    "[ -f '$DTB' ] && [ '$DTB' -nt '$PATCH' ]"

  # clock-names must be "ext_clock" and not "lpo". mmc-pwrseq-simple only ever
  # looks up "ext_clock", so with "lpo" the RK808 32 kHz output is silently
  # never enabled before the WiFi reset is released. See
  # docs/wifi.md section 0.
  check "dtb enables the WiFi power-sequence clock (ext_clock, not lpo)" \
    "'$DTC' -I dtb -O dts '$DTB' 2>/dev/null | grep -qE \"clock-names = \\\"ext_clock\\\"\""

  check "dtb still carries the board model" \
    "'$DTC' -I dtb -O dts '$DTB' 2>/dev/null | grep -q \"Radxa ROCK 4B+\""

  # The kernel must be able to see the SPI flash that holds the bootloader.
  #
  # rk3399-base.dtsi defines spi1 with correct pinctrl but disabled, and
  # rk3399-rock-pi-4.dtsi never touches it, so without an explicit node the
  # flash is invisible: no /dev/mtd0, no dmesg line, nothing. That looks
  # exactly like "the shorting worked" when you are testing by grepping dmesg,
  # which is how this gap was found.
  #
  # Both halves matter. The child node existing while spi1 stays disabled still
  # probes to nothing, so check the status inside the spi1 block rather than
  # grepping only for jedec,spi-nor.
  check "dtb exposes the SPI flash (spi1 okay, with a jedec,spi-nor child)" \
    "{ '$DTC' -I dtb -O dts '$DTB' 2>/dev/null | awk '/spi@ff1d0000/,/^\t};/' | grep -q 'status = \"okay\"'; } && '$DTC' -I dtb -O dts '$DTB' 2>/dev/null | grep -q 'jedec,spi-nor'"

  check "kernel patch applied without rejects" \
    "! find build_dir/target-aarch64_generic_musl/linux-rockchip_armv8/linux-6.12.94/arch -name '*.rej' | grep -q ."

  # The U-Boot/SPL device tree is checked the same way, and for a harsher reason:
  # two separate defects in it cost a working board.
  #
  # rockchip,sdram-params absent -- the TPL cannot initialise DRAM at all. The
  #     build is silent and idbloader.img looks normal, so this only surfaces
  #     once the bootloader reaches the SPI:
  #       rk3399_dmc_of_to_plat: Cannot read rockchip,sdram-params -1
  #       DRAM init failed: -1
  #
  # binman node absent -- the build stops, which is at least loud, but for a
  #     non-obvious reason. scripts/Makefile.lib uses only the FIRST wildcard
  #     match for <board>-u-boot.dtsi, so creating that file displaces the
  #     generic $(CONFIG_SYS_SOC)-u-boot.dtsi rather than adding to it. Any
  #     board -u-boot.dtsi must therefore re-include rk3399-u-boot.dtsi itself.
  #
  # Content checks on the compiled .dtb, for the same reason the kernel ones are:
  # neither defect shows up in a file listing or a size.
  UB=build_dir/target-aarch64_generic_musl/u-boot-rock-4b-plus-rk3399/u-boot-2025.10
  UB_PATCH=package/boot/uboot-rockchip/patches/0102-board-rockchip-Add-ROCK-4B-plus-U-Boot-dtsi.patch
  UBDTC=$UB/scripts/dtc/dtc

  check "u-boot dtb is newer than the patch that builds it" \
    "[ -f '$UB/u-boot.dtb' ] && [ '$UB/u-boot.dtb' -nt '$UB_PATCH' ]"

  check "u-boot dtb carries the RK3399 DRAM parameters (rockchip,sdram-params)" \
    "'$UBDTC' -I dtb -O dts '$UB/u-boot.dtb' 2>/dev/null | grep -q sdram-params"

  check "u-boot dtb has a binman node (board -u-boot.dtsi must re-include rk3399-u-boot.dtsi)" \
    "'$UBDTC' -I dtb -O dts '$UB/u-boot.dtb' 2>/dev/null | grep -qE '^[[:space:]]*binman[[:space:]]*\\{'"

  # The vdd_log rail. The kernel's own node for it has only a voltage range and
  # no regulator-init-microvolt, so this is the only thing that sets it, and it
  # is untested against the panic -- which is exactly why it needs an assertion
  # rather than a comment. Asserted literally, because a node that silently
  # reverted to a range-only definition would satisfy a weaker "there is a
  # vdd_log" check.
  #
  # Back to 950000 (0xE7EF0) on 2026-10-10, which is the shipping value, not an
  # experiment. 800000 and 1100000 were measured only to find out what the
  # variable was; the answer turned out to be "the value is not the variable,
  # whether the duty is ever written is". Every RK3399 board file in upstream
  # v2025.10 sets 950000 -- rock-pi-4, Radxa's own rock-4c-plus, rockpro64 and
  # eight more, not one deviating -- and 950 mV is also where the phase sits for
  # Armbian (220-223 against our 215-226). It also has the most measurements
  # behind it: 12 clean boots across two builds.
  #
  # 950000 is 0xE7EF0, 800000 is 0xC3500, 1100000 is 0x10C8E0.
  #
  # ⚠️ This assertion has been wrong by hand THREE times: 950000 written as
  # 0xE8A40, then 800000 as 0xC350 instead of 0xC3500, and the constant above was
  # computed rather than typed only because of the first two. **A wrong assertion
  # and a broken artefact look identical from the output**, so on a failure here,
  # read the compiled dtb before touching the build:
  #
  #   $UB/scripts/dtc/dtc -I dtb -O dts $UB/u-boot.dtb | grep regulator-init-microvolt
  check "u-boot dtb sets vdd_log to 950mV (the shipping value)" \
    "'$UBDTC' -I dtb -O dts '$UB/u-boot.dtb' 2>/dev/null | tr -d ' \t' | grep -q 'regulator-init-microvolt=<0xe7ef0>'"

  check "both idbloader variants built" \
    "[ -s '$UB/idbloader.img' ] && [ -s '$UB/idbloader-spi.img' ]"

  # The LPDDR4 ordering experiment (patch 0103) has been removed. It reordered
  # the rate switch in sdram_rk3399.c, it was measured to fix nothing (2 boots,
  # 2 panics, fault unchanged), and it was the port's only divergence from
  # upstream. Its two source assertions went with it.
  #
  # ⚠️ The general "no rejects" check below is NOT 0103-specific and stays: it is
  # the only thing that notices a patch whose context drifted and half-applied,
  # which is silent by construction.
  check "u-boot tree has no rejected hunks" \
    "! find '$UB' -name '*.rej' | grep -q ."

  # The image carries its own bootloader, and it must be the fixed one.
  #
  # OpenWrt's rockchip image recipe already embeds it:
  #   target/linux/rockchip/image/Makefile
  #     gen_image_generic.sh ... 32768      # 32 MiB of padding
  #     dd if=$(UBOOT_DEVICE_NAME)-u-boot-rockchip.bin of=$@ seek=64 conv=notrunc
  # so the rkimage container sits at byte 0x8000 and the U-Boot ITB at sector
  # 0x4000. This was documented as NOT happening -- both README.md and
  # docs/flashing.md said the image contains no bootloader -- which is why it was
  # worth checking rather than assuming either way. It does happen, so the
  # image is self-bootable and the SPI is not load-bearing.
  #
  # Which means a stale image silently ships the old, broken bootloader: the
  # build that produced it succeeded, and the failure only appears when that
  # image boots. So check the image, not just the build tree.
  IMG=bin/targets/rockchip/armv8/openwrt-rockchip-armv8-radxa_rock-4b-plus-ext4-sysupgrade.img.gz
  STAGED_UBOOT=staging_dir/target-aarch64_generic_musl/image/rock-4b-plus-rk3399-u-boot-rockchip.bin

  # The container at byte 0x8000 must be the one just staged. Comparing them
  # catches a stale image directly, and needs no parsing: the recipe dd's this
  # exact file to that exact offset.
  check "image is newer than the staged bootloader it embeds" \
    "[ -f '$IMG' ] && [ '$IMG' -nt '$STAGED_UBOOT' ]"

  # ...and the staged bootloader must actually contain the DRAM parameters.
  # The device tree is a big-endian FDT, so the property is a big-endian u32
  # array. The needle is taken from the compiled u-boot.dtb rather than typed
  # from memory, and validated against that dtb before being used -- an
  # unvalidated needle is worse than none, because a coincidental match reads
  # as proof.
  check "staged bootloader contains the RK3399 DRAM parameters" \
    "python3 '$SCRIPT_DIR/assert-sdram-params-in-image.py' '$STAGED_UBOOT' '$UB/u-boot.dtb' --dtc '$UBDTC'"

  check "the image embeds that bootloader at LBA 0x40" \
    "python3 '$SCRIPT_DIR/assert-sdram-params-in-image.py' '$IMG' '$UB/u-boot.dtb' --dtc '$UBDTC' --offset 0x8000"

  # The SPI boot image, which the eMMC checks above cannot see at all.
  #
  # Same U-Boot build, two container shapes, and only one of them was being
  # checked: u-boot-rockchip.bin (idbloader rksd + U-Boot at 0x800000) for eMMC,
  # u-boot-rockchip-spi.bin (idbloader rkspi, 2K/2K-spread, U-Boot at
  # CONFIG_SYS_SPI_U_BOOT_OFFS) for SPI NOR. They are not interchangeable -- giving
  # the wrong one to the right medium reaches the SPL and then stops, which reads
  # as a broken bootloader rather than a wrong file.
  #
  # The offset is read out of the build's .config, not repeated here. A constant
  # in this script would drift the first time someone changed it and go on passing
  # an image the SPL cannot use.
  SPI_OFFS=$(sed -n 's/^CONFIG_SYS_SPI_U_BOOT_OFFS=0x\([0-9A-Fa-f]*\)$/0x\1/p' "$UB/.config" | tail -1)

  check "SPI boot image built (CONFIG_ROCKCHIP_SPI_IMAGE)" \
    "[ -n '$SPI_OFFS' ] && [ -s '$UB/u-boot-rockchip-spi.bin' ]"

  check "SPI boot image is the rkspi variant of this build" \
    "python3 '$SCRIPT_DIR/assert-spi-boot-image.py' '$UB/u-boot-rockchip-spi.bin' '$UB/idbloader.img' --u-boot-offset $SPI_OFFS"

  # Same needle as the eMMC container. Different container, so it needs its own
  # proof -- the DRAM fix must be in the SPI image too, or a board booting from
  # SPI is the one board that cannot start at all.
  check "SPI boot image contains the RK3399 DRAM parameters" \
    "python3 '$SCRIPT_DIR/assert-sdram-params-in-image.py' '$UB/u-boot-rockchip-spi.bin' '$UB/u-boot.dtb' --dtc '$UBDTC'"
} >> "$LOG" 2>&1

# Make the log's own freshness visible. A reader who finds an old log must not be
# able to mistake it for a fresh run, because that is exactly the mistake made on
# 2026-10-06: a build that never started, verified against the previous run's log.
{
  echo
  echo "=== log provenance ==="
  echo "  started   : $START"
  echo "  this file : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "  age       : $(( $(date +%s) - $(stat -c %Y "$LOG") ))s since last write"
  echo "  exit code : $(grep -o 'REAL_EXIT_CODE=[0-9]*' "$LOG" | tail -1)"
} >> "$LOG" 2>&1

exit $rc
