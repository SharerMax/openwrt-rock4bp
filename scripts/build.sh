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
  # docs/WIFI-INVESTIGATION.md section 0.
  check "dtb enables the WiFi power-sequence clock (ext_clock, not lpo)" \
    "'$DTC' -I dtb -O dts '$DTB' 2>/dev/null | grep -qE \"clock-names = \\\"ext_clock\\\"\""

  check "dtb still carries the board model" \
    "'$DTC' -I dtb -O dts '$DTB' 2>/dev/null | grep -q \"Radxa ROCK 4B+\""

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

  check "both idbloader variants built" \
    "[ -s '$UB/idbloader.img' ] && [ -s '$UB/idbloader-spi.img' ]"
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
