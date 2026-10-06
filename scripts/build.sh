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

  check "dtb is the current 63779-byte build" \
    "[ \$(stat -c%s build_dir/target-aarch64_generic_musl/linux-rockchip_armv8/image-rk3399-rock-4b-plus.dtb 2>/dev/null) = 63779 ]"

  check "kernel patch applied without rejects" \
    "! find build_dir/target-aarch64_generic_musl/linux-rockchip_armv8/linux-6.12.94/arch -name '*.rej' | grep -q ."
} >> "$LOG" 2>&1

exit $rc
