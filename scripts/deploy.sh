#!/bin/bash
# Write a ROCK 4B+ image to an SD card, a USB stick, or the onboard eMMC.
#
# Run this ON THE BUILD HOST, from the port repo:
#
#     /home/max/Code/rockpi4bp/scripts/deploy.sh --verify
#     /home/max/Code/rockpi4bp/scripts/deploy.sh --verify ext4
#     /home/max/Code/rockpi4bp/scripts/deploy.sh --list
#     /home/max/Code/rockpi4bp/scripts/deploy.sh /dev/sdb
#     /home/max/Code/rockpi4bp/scripts/deploy.sh /dev/sdb ext4
#     /home/max/Code/rockpi4bp/scripts/deploy.sh /dev/mmcblk0
#
# A second argument selects the image variant: squashfs (default) or ext4. Both
# carry the same package set, so this only changes the root filesystem type.
#
# --verify checks the image against sha256sums and touches no device.
# --list prints the candidate targets with their contents and stops. Do that
# first, every time. It is the step that stops you writing to the wrong disk.
#
# WHAT THIS SCRIPT IS, AND IS NOT
#
# It is a whole-disk `dd` of a 576 MiB image. That is the correct operation for
# this board: the image already carries its own MBR and both partitions, so the
# partition table does not need rewriting afterwards, and ARM mbr devices'
# sysupgrade path does exactly the same thing under a different name.
#
# It is NOT sysupgrade, and you must not use sysupgrade from a USB boot. See the
# eMMC notes below -- that mistake overwrites the medium you are running from.
#
# BOARD-SPECIFIC FACTS (early revision, ~V1.6/V1.72, NOT the V1.73 mass-production board)
#
#   - 4 MB SPI flash IS populated. U-Boot lives there.
#   - So `dd` to SD/USB/eMMC never touches the boot chain. If the result will not
#     boot, the SPI U-Boot is still intact and a USB stick still recovers it.
#   - SPI is still tried before eMMC and SD, so a half-written SPI bootloader
#     intercepts the board before anything on the removable media runs.
#   - Three buttons: Maskrom, Reset, Recovery. All three are sampled at power-on
#     (or by the bootloader), so Linux never sees an event and the DTS
#     deliberately has no gpio-keys node.
#   - MEASURED 2026-10-10, repeatedly: holding Maskrom OR Recovery while
#     powering on enumerates maskrom WITHOUT shorting the SPI pins. The old
#     "you must short SPI first" rule is dead. Radxa's official five-step
#     procedure, including the shorting, still works and is kept as a fallback.
#     This is NOT because the key outranks SPI -- the serial log shows TPL/SPL
#     off SPI at the same time. Do not "explain" it that way.
#   - eMMC is soldered, 32 GB on this board. It already contains one bare partition
#     of unknown content; writing over it is not reversible.
#
# This header used to claim "V1.73 has NO SPI flash populated" and that DRAM init
# was the biggest unknown. Both were about a different board. This one has SPI
# flash, and DRAM init plus the whole boot chain have been verified across five
# boots.

set -euo pipefail

OPENWRT_DIR="${OPENWRT_DIR:-/home/max/Code/openwrt}"

umask 022

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# Both variants share one manifest, so both carry the same package set. Default to
# squashfs for a first flash (read-only, small blast radius, fast). Pass "ext4" as
# a second argument for the writable rootfs, which is what the WiFi work wants:
# the firmware files then persist natively instead of via the overlay.
VARIANT="${2:-squashfs}"
case "$VARIANT" in
	squashfs|ext4) : ;;
	*) die "unknown variant '$VARIANT' -- use squashfs or ext4" ;;
esac

IMG_GZ="$(find "$OPENWRT_DIR/bin/targets/rockchip/armv8" \
             -name "*radxa_rock-4b-plus-${VARIANT}-sysupgrade.img.gz" -print -quit 2>/dev/null || true)"
if [ -z "$IMG_GZ" ] && [ "$VARIANT" = squashfs ]; then
	die "no squashfs image under $OPENWRT_DIR/bin/targets/rockchip/armv8 -- build first (scripts/build.sh)"
fi
[ -n "$IMG_GZ" ] || die "no ${VARIANT} image under $OPENWRT_DIR/bin/targets/rockchip/armv8 -- build first (scripts/build.sh)"

IMG_DIR="$(dirname "$IMG_GZ")"
TMP_IMG=""

cleanup () { [ -n "$TMP_IMG" ] && rm -f "$TMP_IMG"; return 0; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Integrity: use sha256sums, NOT `gzip -t`.
#
# Every OpenWrt sysupgrade image has a 274-byte metadata trailer appended AFTER
# the gzip stream, so the .gz is deliberately not one clean gzip member:
#
#     gzip -t image.img.gz   ->   exit 2, "trailing garbage ignored"
#
# That holds for every stock OpenWrt sysupgrade image and is not a sign of a bad
# download. The trailer is what lets sysupgrade recognise the device:
#
#     [gzip member][8 zero bytes][JSON][19 binary bytes][0x0112]
#     {  "metadata_version": "1.1", "compat_version": "1.0",
#        "supported_devices":["radxa,rock-4b-plus"], "version": { ... } }
#
# The final two bytes are 0x0112 = 274, the trailer's own length. So a nonzero
# `gzip -t` on an OpenWrt image means nothing, and the sha256sums entry is the
# check that actually means something.
# ---------------------------------------------------------------------------
SHA_FILE="$IMG_DIR/sha256sums"
SHA_STATUS="not checked (no sha256sums beside the image)"
if [ -f "$SHA_FILE" ]; then
	SHA_LOG="$(mktemp /tmp/deploy-sha.XXXXXX)"
	if ( cd "$IMG_DIR" && sha256sum -c --ignore-missing sha256sums ) >"$SHA_LOG" 2>&1; then
		SHA_STATUS="verified against sha256sums"
	else
		if grep -q "$(basename "$IMG_GZ")" "$SHA_LOG"; then
			die "image does not match sha256sums:
$(sed 's/^/    /' "$SHA_LOG")
refusing to write anything. Rebuild, or restore the image from a good copy."
		fi
		die "sha256sums does not list $(basename "$IMG_GZ") -- refusing to write unverified"
	fi
	rm -f "$SHA_LOG"
fi

# ---------------------------------------------------------------------------
# Expand to a temporary file instead of piping gzip straight into dd.
#
# Two reasons. The metadata trailer makes gzip exit 2, and under
# `set -o pipefail` that would kill the script after dd had already finished,
# skipping the verification and cleanup that follow. And expanding first lets the
# decompressed size be checked BEFORE a device is erased, which matters when the
# write cannot be undone.
# ---------------------------------------------------------------------------
IMG_BYTES=0
IMG_MIB=0

expand () {
	TMP_IMG="$(mktemp /tmp/rockpi4bp-img.XXXXXX)"
	local rc=0
	# Exit status 2 is the metadata trailer, not an error -- gzip has already
	# written every byte of the payload by the time it reports it. Anything else
	# is real: 1 is invalid compressed data or an unexpected end of file, 3 is
	# an environment problem. Since the .gz passed sha256sums above, a status
	# other than 0 or 2 cannot be explained by the download.
	gzip -dc "$IMG_GZ" > "$TMP_IMG" 2>/dev/null || rc=$?
	case "$rc" in
		0|2) : ;;
		*)   die "gzip failed on $IMG_GZ with status $rc, after the sha256 matched
    so the file is intact and something is wrong with the decompressor or the
    filesystem. Nothing was written." ;;
	esac
	IMG_BYTES="$(stat -c%s "$TMP_IMG")"
	if [ "$IMG_BYTES" -lt $(( 100 * 1048576 )) ]; then
		die "decompressed image is only $IMG_BYTES bytes -- that is not a bootable image"
	fi
	if [ $(( IMG_BYTES % 512 )) -ne 0 ]; then
		die "decompressed image is $IMG_BYTES bytes, not a whole number of 512-byte sectors
    that means the stream was cut short. Nothing was written."
	fi
	if [ $(( IMG_BYTES % 1048576 )) -ne 0 ]; then
		warn "image is $IMG_BYTES bytes, not a whole number of MiB -- unusual for this board"
	fi
	IMG_MIB=$(( IMG_BYTES / 1048576 ))
}

report_image () {
	say "image"
	ls -lah "$IMG_GZ"
	printf '    expands to : %s bytes (%s MiB)\n' "$IMG_BYTES" "$IMG_MIB"
	printf '    integrity  : %s\n' "$SHA_STATUS"
	cat <<'EOF'
    note        : `gzip -t` on this file exits 2 by design. OpenWrt appends a
                  274-byte sysupgrade metadata trailer after the gzip stream, so
                  the payload is intact. sha256sums is the real check.
EOF
}

# --verify: integrity only, touches no device.
if [ "${1:-}" = "--verify" ]; then
	expand
	report_image
	say "no device was written"
	exit 0
fi

expand

list_targets () {
	report_image

	say "block devices"
	lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT 2>/dev/null || lsblk
	printf '\n'
	lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null | grep -E 'mmcblk|^NAME' || true

	cat <<'EOF'

Pick the TARGET MEDIA, not a partition. Whole-disk names only:

  /dev/sdX       USB stick or SD card. Use a USB stick: the SD card tried with
                 this image produced "I/O error ... sector 135842" and
                 "SQUASHFS error -5". That was the card, not the image.
  /dev/mmcblk0   onboard eMMC, 32 GB. Already holds an unknown partition.

Never:
  /dev/mmcblk0boot0 /boot1 /rpmb    eMMC boot partitions. Rockchip's TPL does not
                                    read them; touching them can only cause trouble.
  the running root disk             refused automatically below.
EOF
}

if [ $# -lt 1 ]; then
	list_targets
	die "no target given"
fi

case "$1" in
	-h|--help) list_targets; exit 0 ;;
	--list)    list_targets; exit 0 ;;
esac

DEV="$1"

# Order matters here. Check the NAME before checking that the device exists: on a
# machine with no eMMC, /dev/mmcblk0boot0 is simply absent, and "not a block
# device" would be true but unhelpful -- the reason it must never be written is
# what it is called.
#
# The globs need the leading *: the real names are mmcblk0boot0 and mmcblk0rpmb,
# and `boot0` without it matches nothing at all.
#
# Partitions are NOT matched here. Partition naming is not consistent across
# subsystems -- sda1, mmcblk0p1, nvme0n1p1 -- so a glob would catch some and miss
# others, which is worse than not trying. The authoritative partition test is
# PKNAME below, which asks the kernel instead of guessing from a string.
case "$(basename "$DEV")" in
	*boot0|*boot1|*rpmb)
		die "$DEV is an eMMC boot or RPMB area -- never write to it
give the whole disk instead (e.g. /dev/mmcblk0). Rockchip's TPL does not read
these areas, so there is never a reason to touch them." ;;
esac

# blockdev and dd both need root. Say so plainly instead of letting blockdev's
# failure surface later as an arithmetic error on an empty value.
if [ "$(id -u)" -ne 0 ]; then
	die "must run as root: blockdev and dd both need it
try:  sudo $0 $DEV"
fi

[ -b "$DEV" ] || die "$DEV is not a block device"

# -d is load-bearing. `lsblk /dev/sda` lists the disk AND its partitions, so
# without it PKNAME comes back as "\nsda\nsda" for a whole disk, and every
# comparison below would be against garbage. -d restricts it to the device itself.
PARENT="$(lsblk -ndo PKNAME "$DEV" 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$PARENT" ]; then
	die "$DEV is a partition of /dev/$PARENT -- this script writes whole disks only"
fi
DISK="$DEV"
MODEL="$(lsblk -dno MODEL "$DISK" 2>/dev/null | tr -s ' ' || echo unknown)"

DEV_BYTES="$(blockdev --getsize64 "$DEV" 2>/dev/null || true)"
[ -n "$DEV_BYTES" ] || die "cannot read the size of $DEV -- is it really a disk, and are we root?"
DEV_MB=$(( DEV_BYTES / 1024 / 1024 ))

ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
ROOT_DISK=""
if [ -n "$ROOT_SRC" ]; then
	ROOT_PARENT="$(lsblk -ndo PKNAME "$ROOT_SRC" 2>/dev/null | tr -d '[:space:]' || true)"
	[ -n "$ROOT_PARENT" ] && ROOT_DISK="/dev/$ROOT_PARENT"
fi

say "target"
printf '    device : %s\n' "$DEV"
printf '    disk   : %s (%s)\n' "$DISK" "$MODEL"
printf '    size   : %s MB\n' "$DEV_MB"
printf '    image  : %s MiB\n' "$IMG_MIB"

if [ -n "$ROOT_DISK" ] && [ "$DEV" = "$ROOT_DISK" ]; then
	die "$DEV is the running system disk ($ROOT_SRC) -- refusing"
fi

if [ "$DEV_MB" -lt $(( IMG_MIB + 100 )) ]; then
	die "$DEV is ${DEV_MB}MB but the image needs ${IMG_MIB}MB -- wrong device, or a card that is not seated"
fi

case "$DEV" in
	/dev/mmcblk0)
		cat <<'EOF'

  eMMC notes:
    * It already holds one bare partition (p1) of unknown content. This dd
      overwrites the MBR and both partitions and cannot be undone. Look at it
      read-only first:
          fdisk -l /dev/mmcblk0
          blkid /dev/mmcblk0p1
    * Do NOT use sysupgrade to install this. If you booted from a USB stick the
      root filesystem is /dev/sda2, so sysupgrade would treat the USB stick as
      the upgrade target and overwrite the thing you are booting from.
    * No U-Boot environment change is needed. BOOT_TARGETS is
      "mmc1 mmc0 nvme scsi usb pxe dhcp spi"; mmc0 is the eMMC and it is tried
      before usb, so it boots as soon as you power up.
EOF
		;;
esac

printf '\nThis will ERASE %s (%s) completely. Type the device path to confirm: ' "$DEV" "$MODEL"
read -r CONFIRM
[ "$CONFIRM" = "$DEV" ] || die "confirmation did not match '$DEV', aborting"

say "writing $IMG_MIB MiB"
dd if="$TMP_IMG" of="$DEV" bs=4M conv=fsync status=progress
sync

say "done"
cat <<'EOF'
BEFORE POWERING UP

  * Connect UART2 first: 3.3V TTL, GND/TX/RX only, NO VCC, 1500000 8N1.
    TX and RX crossed. A 5V or RS-232 level adapter will damage the board.
    This is the only reliable way to see the boot -- HDMI is out of scope
    (no DRM driver in this kernel).
  * USB-C PD/QC 5V 2A or better.
  * Then power up. You want to be already watching the port.

WHAT A GOOD BOOT LOOKS LIKE

  U-Boot 2025.10 ...          DRAM: ...            <- SPI U-Boot runs first
    Description:  ARM64 OpenWrt radxa_rock-4b-plus device tree blob
    Data Size:    63779 Bytes = 62.3 KiB           <- 63779 = current build
  Starting kernel ...
    Machine model: Radxa ROCK 4B+                 <- DTS matched
  procd: - init -
  Please press Enter to activate this console.

  A "bad CRC" from Loading Environment from SPIFlash is harmless: the CRC is bad
  so it falls back to defaults, and the default BOOT_TARGETS already includes
  both eMMC and USB.

  If the dtb size is not 63779, you flashed an older image.

IF THERE IS NO SERIAL OUTPUT AT ALL

  Check in this order, and do not conclude the board is dead:
    1. baud rate 1500000, not 115200
    2. TX and RX crossed
    3. a 3.3V TTL adapter, not RS-232
    4. only now suspect DRAM init

AFTER LOGIN

  ubus call system board
  ip link                                    # expect stmmac-0 with PHY attached
  lsblk                                      # expect mmcblk0 28.9 GiB, HS400
  dmesg | grep -iE "mmc2|brcmfmac|sdio-pwrseq"   # SDIO function 0 only; no wlan0

WiFi: wlan0 is expected NOT to appear. The AP6256/BCM43456 uploads its firmware
and then fails to start it. That is a chip/driver problem, not a defect in this
port -- docs/wifi.md records what has been ruled out.

IF THE BOARD WILL NOT BOOT

  Plug the working USB stick back in. U-Boot's boot chain falls through to usb,
  which the tty4/tty5 logs showed working twice.
  Last resort is Maskrom. Hold the on-board Maskrom or Recovery key while
  powering on -- measured 2026-10-10, repeatedly, and it does NOT require
  shorting the SPI pins the way Radxa's official step 1 says. (That step still
  works and is the documented fallback.) Note this does not touch the separate
  trap: the wrong loader makes `wl` report success while writing another medium.
  Full procedure in docs/flashing.md section 7.
EOF
