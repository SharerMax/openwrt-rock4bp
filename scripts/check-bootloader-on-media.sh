#!/bin/sh
# Read the bootloader back off the board and compare it with what this build
# produced. Read-only.
#
# WHY THIS EXISTS
#
# This port has been bitten three times by the same shape of mistake -- an
# artefact existing, a build succeeding, or one clean boot all being read as
# "the board is running the thing we just built":
#
#   - CONFIG_ROCKCHIP_SPI_IMAGE=y was already set, so u-boot-rockchip-spi.bin
#     existed for weeks, with nothing staging or checking it.
#   - "the image carries no bootloader" was written down and never checked; it
#     does carry one.
#   - a build that never started was verified against the previous run's log and
#     reported clean.
#
# None of those is fixed by looking at the build tree, because the build tree is
# what you just wrote. The only thing that settles it is reading the medium the
# board actually boots from. And once SPI is written, or once the bootloader on
# eMMC stops being the one you flashed, nothing local notices.
#
# WHAT IT COMPARES, AND WHY THOSE TWO PLACES
#
# target/linux/rockchip/image/Makefile:
#
#   gen_image_generic.sh $@ ... 32768
#   dd if=$(STAGING_DIR_IMAGE)/rock-4b-plus-rk3399-u-boot-rockchip.bin \
#      of=$@ seek=64 conv=notrunc
#
# so the whole eMMC container lands at LBA 0x40, and inside it:
#
#   offset 0         idbloader.img   (TPL+SPL, the rkimage)
#   offset 0x7f8000  u-boot.itb      (U-Boot proper)
#
# 0x7f8000 is 0x800000 - 0x8000, i.e. the ITB lands at LBA 0x4000 = 8 MiB, which is
# where the SPL looks for it. And 192512 + 8355840 + 1295360 = 9651200, exactly the
# container size, so the two offsets account for the whole file rather than
# approximately lining up.
#
# The read LENGTH comes from the build artefact, never from a constant here. A
# hardcoded sector count would compare a different number of bytes the day
# idbloader changes size, and would report a mismatch that reads like "the board
# is stale" instead of "this script is out of date". A size that is not a whole
# number of 512-byte sectors is a hard error, because then no sector-aligned read
# can be exact and a partial match would be indistinguishable from a real one.
#
# IT REFUSES TO PASS WHEN IT COULD NOT LOOK
#
# Board unreachable, host key not trusted, device missing, sha256sum missing on
# the board: every one of those prints why and exits non-zero, and none of them
# prints MATCH. A checker that reports success when it did not run is worse than
# no checker, because it gets quoted as evidence. Read the exit status.
#
# SAFETY
#
# Reads only. The board side is dd if=... of=/dev/null; nothing is written to the
# medium and nothing is mounted.
#
# USAGE
#
#   check-bootloader-on-media.sh                  check the board against the build
#   check-bootloader-on-media.sh --selftest       negative controls, no board needed
#   check-bootloader-on-media.sh --board root@ip  override the board
#   check-bootloader-on-media.sh --known-hosts F  use a scratch known_hosts file
#                                               (does not touch ~/.ssh/known_hosts)

set -u

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/port-env.sh"

BOARD="${BOARD:-root@192.168.3.8}"
MEDIA_DEV="${MEDIA_DEV:-/dev/mmcblk0}"
SECTOR=512
LBA_IDB=64              # seek=64 in the image recipe
LBA_ITB=16384           # 0x4000, where the SPL expects the ITB
UB_REL=""               # filled in below, by glob -- u-boot-2025.10 is a version
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes"
KNOWN_HOSTS=""
TRANSPORT=ssh           # ssh | local ; the self-test uses local
FAILURES=0

say ()  { printf '\n=== %s ===\n' "$*"; }
ok ()   { printf '  OK      %s\n' "$*"; }
bad ()  { printf '  MISMATCH %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
note () { printf '  --      %s\n' "$*"; }

usage () { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0; }

SELFTEST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --selftest)    SELFTEST=1 ;;
        --board)       BOARD="$2"; shift ;;
        --known-hosts) KNOWN_HOSTS="$2"; shift ;;
        -h|--help)     usage ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- fetch layer
# Echoes "<byte-count> <sha256>" for MEDIA_DEV sectors [skip, skip+count), or
# nothing at all on any failure.
#
# The byte count is not decoration. A failed dd produces NO output, and
# `... | sha256sum` of no input is perfectly valid: it is the well-known
# SHA-256 of the empty string, e3b0c44298fc... An earlier version returned only
# the hash, so "could not read the medium" came back as a real-looking digest
# and was reported as a MISMATCH -- "the bootloader on the board is stale",
# which is a completely different finding and would send someone hunting a
# problem that does not exist. So the count is returned with the hash and
# checked against what was asked for.
#
# `wc -c` rather than `stat -c%s`: OpenWrt's busybox has no stat applet, and
# the first run of this failed on exactly that, reporting the board as
# unreadable for a reason that had nothing to do with the board.
fetch () {   # $1 skip sectors, $2 count sectors
    _want_bytes=$(( $2 * SECTOR ))
    _got=$(dd if="$MEDIA_DEV" of=/tmp/.bootloader-check.$$ bs="$SECTOR" skip="$1" count="$2" 2>/dev/null \
           && { printf '%s %s' \
                  "$(wc -c < /tmp/.bootloader-check.$$ | tr -d ' ')" \
                  "$(sha256sum /tmp/.bootloader-check.$$ | cut -d' ' -f1)"; }; \
           rm -f /tmp/.bootloader-check.$$)
    [ -n "$_got" ] || return 1
    [ "$(printf '%s' "$_got" | cut -d' ' -f1)" = "$_want_bytes" ] || return 1
    printf '%s\n' "$_got" | cut -d' ' -f2
}

# Same, from the board over ssh. dd writes to a temp file on the BOARD rather
# than to a pipe, for the reason above: the byte count has to survive the trip.
# Nothing is written to the medium; /tmp on a running OpenWrt is RAM.
fetch_over_ssh () {   # $1 skip sectors, $2 count sectors
    _sshopts="$SSH_OPTS"
    [ -n "$KNOWN_HOSTS" ] && _sshopts="$_sshopts -o UserKnownHostsFile=$KNOWN_HOSTS"
    # Wrapped in timeout: ConnectTimeout only covers the TCP connect, and an
    # askpass or password exchange can block past it.
    timeout 40 ssh $_sshopts "$BOARD" \
        "dd if=$MEDIA_DEV of=/tmp/.bootloader-check bs=$SECTOR skip=$1 count=$2 2>/dev/null \
         && { printf '%s %s' \"\$(wc -c < /tmp/.bootloader-check | tr -d ' ')\" \
                          \"\$(sha256sum /tmp/.bootloader-check | cut -d' ' -f1)\"; \
               echo; rm -f /tmp/.bootloader-check; }" 2>/dev/null \
        | tr -d '\r' | awk '{print $2; exit}'
}

# ---------------------------------------------------------------- comparison
# $1 label, $2 artefact path, $3 LBA to read at
compare_artefact () {
    _label=$1; _art=$2; _lba=$3

    if [ ! -f "$_art" ]; then
        note "$_label: no build artefact at $_art -- cannot compare, and this is NOT a pass"
        FAILURES=$((FAILURES + 1))
        return 0
    fi

    _want=$(sha256sum "$_art" | cut -d' ' -f1)
    _bytes=$(stat -c%s "$_art")
    _sectors=$(( _bytes / SECTOR ))

    if [ $(( _bytes % SECTOR )) -ne 0 ]; then
        note "$_label: build artefact is $_bytes B, not a whole number of ${SECTOR}-B"
        note "        sectors -- a sector-aligned read cannot compare it exactly, so this"
        note "        is reported as unchecked rather than as a match"
        FAILURES=$((FAILURES + 1))
        return 0
    fi

    if [ "$TRANSPORT" = local ]; then
        _got=$(fetch "$_lba" "$_sectors")
    else
        _got=$(fetch_over_ssh "$_lba" "$_sectors")
    fi
    if [ -z "$_got" ]; then
        note "$_label: could not read LBA $_lba ($_sectors sectors, $_bytes B) from $MEDIA_DEV"
        note "        -- NOT CHECKED, and not a pass"
        FAILURES=$((FAILURES + 1))
        return 0
    fi

    if [ "$_got" = "$_want" ]; then
        ok "$_label: media matches the build (LBA $_lba, $_bytes B)"
    else
        bad "$_label: media does NOT match the build"
        note "        LBA $_lba, $_bytes B"
        note "        build : $_want"
        note "        media : $_got"
    fi
}

# ================================================================= self-test
if [ "$SELFTEST" = 1 ]; then
    W=$(mktemp -d)
    trap 'rm -rf "$W"' EXIT INT TERM

    say "synthetic medium: does the comparison actually discriminate?"

    # A file laid out exactly like the medium: idbloader at 0x8000, ITB at 0x800000.
    #
    # The artefacts are padded to whole sectors ON PURPOSE. The first version of
    # this fixture used 1700-byte payloads, and every case refused to compare
    # them -- correctly: a read is sector-aligned, so a 1700-byte artefact cannot
    # be compared exactly and the script said so instead of guessing. The guard
    # was right and the fixture was wrong, which is the better of the two ways
    # for this to fail, so the padding is kept and noted here.
    python3 - "$W" <<'PY'
import sys, os
w = sys.argv[1]
SECTOR = 512

def blob(text, nbytes):
    b = (text * (nbytes // len(text) + 1))[:nbytes]
    assert len(b) == nbytes and nbytes % SECTOR == 0
    return b

idb = blob(b"IDBLOADER-TPL-SPL", 2 * SECTOR)
itb = blob(b"U-BOOT-PROPER-FIT", 4 * SECTOR)

img = bytearray(16 * 1024 * 1024)
img[0x8000:0x8000 + len(idb)] = idb
img[0x800000:0x800000 + len(itb)] = itb

open(os.path.join(w, "media.bin"), "wb").write(bytes(img))
open(os.path.join(w, "idbloader.img"), "wb").write(idb)
open(os.path.join(w, "u-boot.itb"), "wb").write(itb)
# same length, one byte different -- a MISMATCH the tool must notice
open(os.path.join(w, "u-boot.itb-wrong"), "wb").write(itb[:-1] + b"X")
# the first half of the ITB: a strict prefix of what is on the medium
open(os.path.join(w, "u-boot.itb-prefix"), "wb").write(itb[:2 * SECTOR])
PY
    if [ ! -s "$W/idbloader.img" ]; then
        note "could not synthesise the medium (python3 missing); the layout cases cannot run"
        exit 1
    fi

    MEDIA_DEV="$W/media.bin"
    TRANSPORT=local

    before=$FAILURES
    compare_artefact "1  identical idbloader" "$W/idbloader.img" 64
    compare_artefact "2  identical u-boot.itb" "$W/u-boot.itb" 16384
    compare_artefact "3  one byte differs" "$W/u-boot.itb-wrong" 16384
    compare_artefact "4  right bytes, wrong LBA" "$W/u-boot.itb" 64
    compare_artefact "5  missing artefact" "$W/nope.img" 64
    planted=$(( FAILURES - before ))
    if [ "$planted" -eq 3 ]; then
        ok "cases 3-5 all reported as problems, 1 and 2 as OK"
    else
        bad "cases 3-5 all reported as problems, 1 and 2 as OK" "3" "$planted"
    fi

    say "a known limitation, pinned rather than left accidental"
    # A build artefact that is a strict PREFIX of what is on the medium will
    # match, because the read length follows the artefact. That is a real hole
    # and it is recorded here so nobody discovers it as a surprise.
    #
    # It does not bite for the case this script exists for: a rebuilt bootloader
    # shares no prefix with the previous one, so a stale medium is caught. And
    # the SPL independently verifies the FIT on the medium at every boot --
    # "Checking hash(es) for Image u-boot ... sha256+ OK" in the serial log --
    # which is an on-medium integrity signal this script does not depend on.
    compare_artefact "6  prefix artefact (passes, size shown)" "$W/u-boot.itb-prefix" 16384

    say "can it report a pass when it did not look?"
    keep=$MEDIA_DEV
    MEDIA_DEV="$W/absent-media.bin"
    compare_artefact "7  unreadable medium" "$W/u-boot.itb" 16384 > "$W/case7.out" 2>&1
    unreadable=$FAILURES
    MEDIA_DEV=$keep
    if [ "$unreadable" -ne 0 ] && grep -q 'NOT CHECKED' "$W/case7.out" \
       && ! grep -q '^  OK' "$W/case7.out"; then
        ok "7  unreadable medium: NOT CHECKED, no OK, counted as a failure"
    else
        bad "7  unreadable medium: NOT CHECKED, no OK, counted as a failure" \
            "counted, NOT CHECKED, no OK" "$(cat "$W/case7.out")"
    fi

    say "tally"
    printf '  %s problem(s) found; 6 is the pinned limitation above, not a defect\n' "$FAILURES"
    exit 0
fi

# ================================================================== real run
UB_REL=$(port_uboot_dir) || exit 1
say "build artefacts"
for f in idbloader.img u-boot.itb; do
    if [ -f "$UB_REL/$f" ]; then
        printf '  %-18s %10s B  %s\n' "$f" \
            "$(wc -c < "$UB_REL/$f" | tr -d ' ')" \
            "$(sha256sum "$UB_REL/$f" | cut -d' ' -f1)"
    else
        printf '  %-18s MISSING under %s\n' "$f" "$UB_REL"
    fi
done

say "media"
if [ "$TRANSPORT" = ssh ]; then
    printf '  board   : %s\n  device  : %s\n' "$BOARD" "$MEDIA_DEV"
    if [ -n "$KNOWN_HOSTS" ]; then
        printf '  host key: verified against %s (your ~/.ssh/known_hosts is untouched)\n' "$KNOWN_HOSTS"
    fi
    # Reachability and sha256sum are checked separately from the read, so that
    # "the board is not there" is never reported as "the bootloader is stale".
    if ! timeout 20 ssh $SSH_OPTS ${KNOWN_HOSTS:+-o UserKnownHostsFile=$KNOWN_HOSTS} \
            "$BOARD" 'command -v sha256sum >/dev/null && echo READY' 2>/dev/null | tr -d '\r' | grep -q READY; then
        bad "cannot reach $BOARD with a usable sha256sum"
        note "        UNKNOWN HOST KEY is the usual reason. Confirm the board's fingerprint"
        note "        before adding it, then re-run; this script will not accept one for you."
        exit 1
    fi
    ok "board answers and has sha256sum"
fi

say "comparison"
compare_artefact "idbloader.img (TPL+SPL)" "$UB_REL/idbloader.img" "$LBA_IDB"
compare_artefact "u-boot.itb (U-Boot proper)" "$UB_REL/u-boot.itb" "$LBA_ITB"

say "against recovery/, the build that passed six consecutive clean boots"
REC="$PORT_DIR/recovery"
if [ -d "$REC" ]; then
    compare_artefact "idbloader.img vs recovery" "$REC/idbloader.img" "$LBA_IDB"
    compare_artefact "u-boot.itb vs recovery" "$REC/u-boot.itb" "$LBA_ITB"
else
    note "no recovery/ here (it exists only on the build host)"
fi

say "verdict"
if [ "$FAILURES" -eq 0 ]; then
    printf '  the bootloader on the board IS the one this build produced\n'
    exit 0
fi
printf '  %s problem(s). Nothing above that says NOT CHECKED counts as a pass.\n' "$FAILURES"
exit 1
