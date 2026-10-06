#!/bin/sh
# Check every patch source against the patch it generates.
#
# WHY THIS EXISTS
#
# The port keeps authored sources in overlay/ and generated patches in the
# OpenWrt tree. Nothing copies between them: regen-dts-patch.sh regenerates the
# kernel DTS patch, and the two U-Boot patches are made by hand. So the two
# halves can disagree indefinitely, and on 2026-10-06 they did -- the defconfig
# source was corrected to record that this board has SPI flash, and the patch
# was never regenerated, so the tree kept asserting the opposite while every
# build passed.
#
# Comparing is not enough on its own, because these are new-file patches: the
# right comparison is the patch's payload for that one file, which is what
# extract-patch-file.sh pulls out. A patch that touches more than one file --
# 0001 adds the kernel Makefile entry as well -- defeats a plain grep for "+"
# lines, because the other hunks end up in the output too.
#
# Called from sync-overlay.sh, which turns a mismatch into a non-zero exit.
# Both directions, because this is a comparison and there is nothing to copy.

set -e

PORT_DIR=${PORT_DIR:-/home/max/Code/rockpi4bp}
OPENWRT_DIR=${OPENWRT_DIR:-/home/max/Code/openwrt}
HERE=$(cd "$(dirname "$0")" && pwd)

failures=0

# Note the deliberately different variable names. sh has no local variables,
# so a name reused here would silently overwrite the caller's counter -- which
# is exactly how a real mismatch was reported as a pass.
check_one () {   # $1 overlay file, $2 patch, $3 target path inside the patch
	_src=$1
	_out=$(mktemp)
	"$HERE/extract-patch-file.sh" "$2" "$3" > "$_out"

	if [ ! -f "$_src" ]; then
		printf '  MISSING  %s\n' "$_src"
		rm -f "$_out"
		failures=$((failures + 1))
		return 0
	fi
	if [ ! -f "$2" ]; then
		printf '  MISSING  %s\n' "$2"
		rm -f "$_out"
		failures=$((failures + 1))
		return 0
	fi

	if cmp -s "$_out" "$_src"; then
		printf '  MATCH    %s\n' "$(basename "$_src")"
	else
		printf '  DRIFT    %s  (source %s B, patch payload %s B)\n' \
			"$(basename "$_src")" "$(stat -c%s "$_src")" "$(stat -c%s "$_out")"
		diff "$_src" "$_out" | head -8 | sed 's/^/            /'
		failures=$((failures + 1))
	fi
	rm -f "$_out"
	return 0
}

check_one "$PORT_DIR/overlay/kernel/rk3399-rock-4b-plus.dts" \
	"$OPENWRT_DIR/target/linux/rockchip/patches-6.12/0001-arm64-dts-rockchip-add-Radxa-ROCK-4B-plus.patch" \
	arch/arm64/boot/dts/rockchip/rk3399-rock-4b-plus.dts

check_one "$PORT_DIR/overlay/u-boot/rock-4b-plus-rk3399_defconfig" \
	"$OPENWRT_DIR/package/boot/uboot-rockchip/patches/0101-configs-add-rock-4b-plus-rk3399-defconfig.patch" \
	configs/rock-4b-plus-rk3399_defconfig

check_one "$PORT_DIR/overlay/u-boot/rk3399-rock-4b-plus-u-boot.dtsi" \
	"$OPENWRT_DIR/package/boot/uboot-rockchip/patches/0102-board-rockchip-Add-ROCK-4B-plus-U-Boot-dtsi.patch" \
	arch/arm/dts/rk3399-rock-4b-plus-u-boot.dtsi

[ "$failures" -eq 0 ] || exit 1
exit 0