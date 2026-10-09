#!/bin/bash
# Write this port's U-Boot into the board's SPI flash, from a Maskrom-mode host.
#
# Run ON THE BUILD HOST, from the port repo:
#
#     /home/max/Code/rockpi4bp/scripts/flash-spi.sh --check
#     /home/max/Code/rockpi4bp/scripts/flash-spi.sh --plan
#     /home/max/Code/rockpi4bp/scripts/flash-spi.sh --write
#
# ------------------------------------------------------------------------------------
# WHY A SEPARATE SCRIPT FROM deploy.sh
#
# deploy.sh dd's a 576 MiB disk image to SD/USB/eMMC. None of that can put a
# bootloader into SPI, and the reason is the single most useful fact on this board:
#
#     `rkdeveloptool wl` does not choose the medium. The loader does.
#
# `rkdeveloptool db <loader>` pushes a Rockchip loader onto the SoC, and the
# loader is what initialises the storage that subsequent commands talk to:
#
#     rk3399_loader_v1.27.126.bin        -> eMMC (this is what recovery-README.md uses)
#     rk3399_loader_spinor_v1.15.114.bin -> SPI NOR
#
# So `rkdeveloptool db rk3399_loader_v1.27.126.bin && rkdeveloptool wl 0 <image>`
# writes the image to eMMC no matter what the image contains. Nothing has ever
# failed here, and nothing ever reached SPI -- which is why docs/boot-order.md
# could say "Maskrom wl only touches eMMC" and be right about the observation
# while missing the mechanism that makes it changeable.
#
# Two further things differ between the media, and the payload must match the
# medium, not just the loader:
#
#   * container type. eMMC/SD get an rksd container (TPL+SPL contiguous); SPI NOR
#     needs an rkspi container, where each 4 KiB page carries 2 KiB of payload
#     followed by 2 KiB of padding. The ROM requires this; upstream calls the
#     rationale unknown but emits it regardless (tools/rkspi.c).
#   * where U-Boot proper lives. eMMC/SD: byte 0x800000 (LBA 0x4000). SPI NOR:
#     CONFIG_SYS_SPI_U_BOOT_OFFS, 0xE0000 in this defconfig.
#
# U-Boot's build already produces the correct SPI image -- u-boot-rockchip-spi.bin,
# via binman's simple-bin-spi node, which is enabled by CONFIG_ROCKCHIP_SPI_IMAGE
# in the board defconfig. Nothing has to be invented here; it was simply never
# shipped, never asserted, and never offered to rkdeveloptool.
#
# ------------------------------------------------------------------------------------
# ⚠️ NOT YET RUN ON HARDWARE
#
# Everything above was derived from build artefacts, the defconfig, U-Boot's own
# source and binman's map file. **No SPI write has been performed by this port.**
# docs/boot-order.md records that SPI currently holds nothing bootable, so a failed
# attempt leaves the board exactly as usable as it is now -- but "should work" and
# "works" are different claims in this repo, and this is the first kind.
#
# ------------------------------------------------------------------------------------
# ⚠️ LOADER VERSION IS NOT SETTLED
#
# Radxa ships rk3399_loader_spinor_v1.15.114.bin for ROCK Pi 4 and documents that
# boards from v1.72 onward (they name the ROCK 4C+) need
# rk3399_loader_spinor_v1.20.126.bin instead. This board is an early V1.73 with a
# 4 MB NOR, which is plausibly in either camp and has NOT been identified by
# revision. The script takes the loader as an argument and refuses to guess; if a
# write fails, trying the other loader is the first thing to do, because a loader
# that cannot drive the flash produces a write error rather than a silent one.
#
# Entering Maskrom: this board's SPI is tried first by the boot ROM, so if SPI holds
# anything bootable the SPI CLK pin (40-pin header 23) must be shorted to GND (25)
# first, and the short removed after the board enumerates. See docs/boot-order.md.

set -euo pipefail

OPENWRT_DIR="${OPENWRT_DIR:-/home/max/Code/openwrt}"
UB_DIR="$OPENWRT_DIR/build_dir/target-aarch64_generic_musl/u-boot-rock-4b-plus-rk3399/u-boot-2025.10"
SPI_IMG="${SPI_IMG:-$UB_DIR/u-boot-rockchip-spi.bin}"
IDBLOADER="${IDBLOADER:-$UB_DIR/idbloader.img}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# The SPI NOR on this board is 4 MB. Read from the build when possible so the
# padding target is not a second hardcoded constant that can drift.
FLASH_BYTES="${FLASH_BYTES:-4194304}"

MODE="${1:---check}"
LOADER=""
LOADER_SHA256=""
DRY_RUN=0

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
usage: flash-spi.sh [--check | --plan | --write] [--loader FILE] [--loader-sha256 HASH]

  --check        verify the SPI boot image against this build. Writes nothing.
  --plan         everything --check does, plus print the exact rkdeveloptool
                 commands. Still writes nothing. Default.
  --write        perform the write. Requires --loader. Destructive.

  --loader       rk3399_loader_spinor_*.bin. REQUIRED for --write.
  --loader-sha256  expected sha256 of the loader; checked before use if given.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--check)  MODE=check ;;
		--plan)   MODE=plan ;;
		--write)  MODE=write ;;
		--loader) LOADER="${2:-}"; shift ;;
		--loader-sha256) LOADER_SHA256="${2:-}"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "unknown argument '$1'" ;;
	esac
	shift
done

# ---------------------------------------------------------------------------
# 1. The image must be this build's, and must be the SPI variant.
#
# Two failure modes are silent and both look like a broken bootloader afterwards,
# not like a wrong file:
#   - the rksd container (u-boot-rockchip.bin) written to SPI: the ROM loads the
#     TPL fine, and the SPL then fails to find U-Boot at the offset it was told
#     to use.
#   - a stale image from an earlier build: same symptom, different cause.
# ---------------------------------------------------------------------------
say "SPI boot image"
[ -f "$SPI_IMG" ] || die "no $SPI_IMG -- build first (scripts/build.sh).
  The file is emitted by binman's simple-bin-spi node, which needs
  CONFIG_ROCKCHIP_SPI_IMAGE=y in the U-Boot defconfig."
[ -f "$IDBLOADER" ] || die "no $IDBLOADER -- needed to prove the image is not stale"

# Read the offset out of the build's .config rather than repeating the constant.
# A hardcoded copy here would drift silently the first time someone changed it,
# and the check would go on passing an image the SPL could not use.
SPI_OFFS="$(sed -n 's/^CONFIG_SYS_SPI_U_BOOT_OFFS=0x\([0-9A-Fa-f]*\)$/\1/p' \
	"$UB_DIR/.config" | tail -1)"
[ -n "$SPI_OFFS" ] || die "CONFIG_SYS_SPI_U_BOOT_OFFS not set in $UB_DIR/.config"
SPI_OFFS="0x$SPI_OFFS"

ls -l "$SPI_IMG" "$IDBLOADER" || true
python3 "$SCRIPT_DIR/assert-spi-boot-image.py" \
	"$SPI_IMG" "$IDBLOADER" --u-boot-offset "$SPI_OFFS" \
	|| die "the SPI image failed its content check -- refusing to go further"

# Same DRAM-parameter assertion the eMMC container gets. The SPI image is a
# different container from the same TPL/SPL, so it needs proving separately.
if [ -f "$UB_DIR/u-boot.dtb" ]; then
	python3 "$SCRIPT_DIR/assert-sdram-params-in-image.py" \
		"$SPI_IMG" "$UB_DIR/u-boot.dtb" \
		--dtc "$UB_DIR/scripts/dtc/dtc" \
		|| die "the SPI image does not carry rockchip,sdram-params"
fi

# ---------------------------------------------------------------------------
# 2. Padding.
#
# The image is 2.1 MiB and the flash is 4 MiB. `wl` writes exactly the file it is
# given, so writing only the payload leaves whatever was at 0x21C400..0x400000
# untouched -- on a chip that may hold an older, larger bootloader. Pad to the full
# device size so the result does not depend on what used to be there.
#
# 0xFF rather than 0x00: 0xFF is what an erased NOR cell reads as, so the padding
# is inert rather than looking like a plausible-looking run of zeroes to whatever
# scans for structures.
# ---------------------------------------------------------------------------
say "payload padding"
PAYLOAD="$(mktemp /tmp/spi-payload.XXXXXX.bin)"
READBACK=""
cleanup () { rm -f "$PAYLOAD"; [ -n "$READBACK" ] && rm -f "$READBACK"; return 0; }
trap cleanup EXIT INT TERM
python3 - "$PAYLOAD" "$SPI_IMG" "$FLASH_BYTES" <<'PY'
import sys
out, src, total = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
data = bytearray(open(src, "rb").read())
if len(data) > total:
    sys.exit("image is larger than the flash: %d > %d" % (len(data), total))
data += b"\xff" * (total - len(data))
open(out, "wb").write(data)
PY
printf 'payload %s -> %s bytes (0xFF padded)\n' "$SPI_IMG" "$(stat -c%s "$PAYLOAD")"

# ---------------------------------------------------------------------------
# 3. The loader, and the check that it is the SPI one.
#
# This is the check that would have caught the original question. It is a name
# check, deliberately: a wrong loader is the most likely mistake here and it is
# completely silent -- `wl` reports success while writing to the other medium.
# ---------------------------------------------------------------------------
say "loader"
if [ -z "$LOADER" ]; then
	warn "no --loader given."
	cat >&2 <<'EOF'

  SPI needs a *spinor* loader. The eMMC loader will "succeed" and write the
  wrong medium:

    rk3399_loader_v1.27.126.bin        -> eMMC
    rk3399_loader_spinor_v*.bin        -> SPI NOR   <-- the one wanted here

  ⚠️ No SPI write has been done by this port yet, and Radxa documents that
  v1.15.114 and v1.20.126 are not interchangeable across board revisions. This
  board's revision has not been identified. Fetch both if unsure; a loader that
  cannot drive the flash errors out rather than writing nothing silently.

EOF
	[ "$MODE" = write ] && die "--write requires --loader"
else
	[ -f "$LOADER" ] || die "loader not found: $LOADER"
	case "$(basename "$LOADER")" in
		*spinor*) : ;;
		*) die "refusing $(basename "$LOADER"): a loader without 'spinor' in its
    name initialises eMMC, and 'wl' would report success while writing to
    eMMC instead of SPI. That is the failure this script exists to prevent." ;;
	esac
	if [ -n "$LOADER_SHA256" ]; then
		got="$(sha256sum "$LOADER" | cut -d' ' -f1)"
		[ "$got" = "$LOADER_SHA256" ] || die "loader sha256 mismatch
  expected $LOADER_SHA256
  actual   $got"
		printf 'loader sha256 ok: %s\n' "$got"
	else
		warn "no --loader-sha256 given; the loader will not be verified"
		printf 'loader sha256    : %s\n' "$(sha256sum "$LOADER" | cut -d' ' -f1)"
	fi
	ls -l "$LOADER"
fi

# ---------------------------------------------------------------------------
# 4. Report / execute.
# ---------------------------------------------------------------------------
CMD=(rkdeveloptool ld)
say "what would run"
printf '  %s\n' "${CMD[*]}"
printf '  rkdeveloptool db %s\n' "${LOADER:-<loader>}"
printf '  rkdeveloptool cs 9                        # select SPINOR, expect "Change Storage OK"\n'
printf '  rkdeveloptool wl 0 %s\n' "$PAYLOAD"
printf '  rkdeveloptool rl 0 %s <file>              # read back and compare\n' \
	"$(( $(stat -c%s "$SPI_IMG") / 512 ))"
printf '  rkdeveloptool rd\n'

if [ "$MODE" != write ]; then
	cat >&2 <<'EOF'

  Nothing was written. --plan stops here on purpose; --check is the read-only mode.

  To actually do it:
    1. confirm the board enumerates as Maskrom (rkdeveloptool ld above)
    2. pick a spinor loader, and treat the version as unconfirmed
    3. re-run with --write --loader <file>

EOF
	exit 0
fi

command -v rkdeveloptool >/dev/null 2>&1 || die "rkdeveloptool not installed"

say "writing to SPI"
printf "This overwrites the board's SPI flash (%s bytes). Type YES to confirm: " "$FLASH_BYTES"
read -r CONFIRM
[ "$CONFIRM" = "YES" ] || die "confirmation did not match, aborting"

rkdeveloptool ld
rkdeveloptool db "$LOADER"

# ⚠️ Confirm the medium BEFORE writing. rkdeveloptool tracks the current storage
# and can be told to switch it: `cs [1=EMMC, 2=SD, 9=SPINOR]`. Two reasons this is
# worth doing rather than trusting the loader choice:
#
#   - `cs` reads the current storage back and fails if the switch did not take,
#     so this turns "which medium am I pointed at" from an assumption into a
#     checked fact. Assuming it is exactly the failure this script exists to stop.
#   - it is also the fallback if the spinor loader turns out to be the wrong one
#     for this board revision: push the ordinary eMMC loader and switch with
#     `cs 9`. Two routes to SPI, so a wrong loader guess is not a dead end.
#
# "Change Storage OK" is the pass condition. "Storage 9 is not available" means
# the device did not accept the switch -- do not write, it would land on eMMC.
printf '\nselecting SPINOR (cs 9); expect "Change Storage OK"\n'
if ! rkdeveloptool cs 9; then
	die "could not select SPINOR -- NOT writing.
  wl would have gone to whatever storage was already selected, which is the
  silent failure this script exists to prevent. Aborting before any write."
fi

# The offset is 0. It is 0 because the LBA space of the selected storage is the
# flash itself; for eMMC the same file would go to 0x40. Getting this wrong in the
# other direction is the other silent failure, hence the comment.
rkdeveloptool wl 0 "$PAYLOAD"

# ---------------------------------------------------------------------------
# Read back and compare. Do not skip this.
#
# `rl` goes through the ROM loader, not through Linux, so it does not have the
# defective SPI read path that docs/boot-order.md documents: Linux gives two
# different md5 sums for two consecutive reads of the same 64 KiB. rkdeveloptool
# is therefore the first read of this chip that can be trusted as ground truth,
# and "wl exited 0" is not evidence that anything landed.
#
# Compared over the payload only, not the whole 4 MiB: the tail is 0xFF padding
# and an erased cell also reads 0xFF, so including it cannot catch anything while
# making the comparison depend on how the chip powers up.
# ---------------------------------------------------------------------------
say "reading back"
READBACK="$(mktemp /tmp/spi-readback.XXXXXX.bin)"
PAYLOAD_SECTORS=$(( $(stat -c%s "$SPI_IMG") / 512 ))

if rkdeveloptool rl 0 "$PAYLOAD_SECTORS" "$READBACK"; then
	if cmp -s "$READBACK" "$SPI_IMG"; then
		printf 'readback matches (%s bytes) -- the write landed\n' "$(stat -c%s "$READBACK")"
	else
		warn "readback DIFFERS from the image that was sent."
		cat >&2 <<EOF

  The write reported success but the chip does not contain those bytes. Do not
  assume the medium was SPI -- check it:

    rkdeveloptool cs 9      # 'Change Storage OK' means SPINOR was selected

  First differing offset:
EOF
		cmp "$READBACK" "$SPI_IMG" 2>&1 | head -2 >&2 || true
		echo >&2
		echo "  Do not power-cycle until this is understood. SPI is tried first, so" >&2
		echo "  a half-written bootloader there can stop the board before eMMC." >&2
		die "readback mismatch"
	fi
else
	die "readback failed -- the medium's state is unknown, so is the write"
fi

rkdeveloptool rd

say "done, and the readback matched"
cat <<'EOF'
  The bytes on the chip are now known to be the bytes that were sent, and the
  storage was confirmed to be SPINOR before writing. That is stronger than
  "wl exited 0" but it is still not proof the board boots from SPI.

  Remaining check, on the serial console (1500000 8N1, UART2):

    first line should read  U-Boot TPL 2025.10-OpenWrt-...   (this port)
    and you should see      Trying to boot from SPI

  ⚠️ If the first line still shows a different U-Boot, or the board stops after
  'Trying to boot from SPI', the container was right but U-Boot proper was not
  where the SPL looked. Check CONFIG_SYS_SPI_U_BOOT_OFFS against the offset the
  assert script verified.

  Recovery if it does not boot: SPI is tried first, so it has to be dealt with,
  and the same flow that just worked is the way back -- push a spinor loader,
  cs 9, wl 0 <known-good image>. The eMMC image is independent of all this and is
  written with rkdeveloptool db <emmc-loader> && rkdeveloptool wl 0 <disk-image>.
EOF
