#!/bin/bash
# Write the ROCK 4B+ image to an SD card or eMMC, with explicit device confirmation.
#
# Safety notes specific to this board:
#  - V1.73 has NO SPI flash populated, so boot is eMMC or microSD only.
#  - eMMC is soldered onboard (8/16/32/64/128 GB). On the 58 GB build host the
#    device names are predictable, but ALWAYS confirm before writing.
#  - A full-disk write is destructive. This script refuses to run without
#    typing the device path back.

set -euo pipefail

TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TOPDIR"

umask 022

IMG_GZ="$(find bin/targets/rockchip/armv8 -name '*radxa_rock-4b-plus-squashfs-sysupgrade.img.gz' -print -quit 2>/dev/null || true)"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

if [ -z "$IMG_GZ" ]; then
	die "no sysupgrade image found -- run scripts/build.sh full first"
fi
say "image: $IMG_GZ"
ls -lah "$IMG_GZ"

if [ $# -lt 1 ]; then
	die "usage: $0 <device>   e.g. $0 /dev/sdb   (or /dev/mmcblk0 for eMMC)"
fi
DEV="$1"

[ -b "$DEV" ] || die "$DEV is not a block device"

# Resolve the parent disk so we can print a model, and refuse if it looks like
# the system disk.
PARENT="$(lsblk -no PKNAME "$DEV" 2>/dev/null || true)"
DISK="/dev/$PARENT"
MODEL="$(lsblk -dno MODEL "$DISK" 2>/dev/null | tr -s ' ' || echo unknown)"
SIZE_MB=$(( $(blockdev --getsize64 "$DEV") / 1024 / 1024 ))

ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)"
[ -n "$ROOT_DISK" ] && ROOT_DISK="/dev/$ROOT_DISK"

say "target"
printf '    device : %s\n' "$DEV"
printf '    disk   : %s (%s)\n' "$DISK" "$MODEL"
printf '    size   : %s MB\n' "$SIZE_MB"

if [ -n "$ROOT_DISK" ] && [ "$DISK" = "$ROOT_DISK" ]; then
	die "$DISK is the running system disk -- refusing"
fi

if [ "$SIZE_MB" -lt 1000 ]; then
	warn "$DEV is only ${SIZE_MB}MB; the image needs roughly 700MB, so this is probably not an SD card"
fi

printf '\nThis will ERASE %s completely. Type the device path to confirm: ' "$DEV"
read -r CONFIRM
[ "$CONFIRM" = "$DEV" ] || die "confirmation did not match '$DEV', aborting"

say "writing (this takes a minute)"
gzip -dc "$IMG_GZ" | dd of="$DEV" bs=4M conv=fsync status=progress
sync

say "done"
cat <<'EOF'
Next steps:
  1. Safely power off, move the card to the ROCK 4B+.
  2. Connect UART2 (3.3V, GND, TX, RX) at 1500000 8N1 -- this is the only
     reliable way to see the boot. Expect U-Boot then Linux messages.
  3. First boot is slow (initramfs/first-boot expansion). Watch for:
       - U-Boot reaching the "Hit any key to stop autoboot" prompt
       - "DRAM" / LPDDR4 init succeeding  (biggest unknown: DRAM init)
       - the log stopping early = note the last line, that is the failure point
  4. Log in on the serial console (no password set by default) and run:
       ubus call system board
       cat /proc/cmdline
       dmesg | grep -iE "rock-4b-plus|mmc|gmac|r8169|brcmf|i2s"
EOF
