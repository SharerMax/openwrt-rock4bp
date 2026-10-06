#!/bin/sh
# AP6256 / BCM43456 bring-up tester for the Radxa ROCK 4B+.
#
# WHY THIS IS SPLIT INTO TWO PHASES
#
# A failed attach leaves the WiFi chip half-alive: firmware uploaded, backplane
# clocks half-requested, SDIO function 1 still bound. After that:
#
#   - rmmod + modprobe does NOT trigger a new probe at all (observed: zero new
#     dmesg lines)
#   - reboot does NOT fix it either, because reboot resets the SoC but leaves
#     the WiFi peripheral powered (same report on a PineBook Pro with the same
#     module: "It remains inaccessible with a reboot ... Only a complete
#     shutdown followed by a new boot gives me a 80% chance")
#
# So every combination needs a genuine cold boot: poweroff, unplug the supply,
# wait, power on. "reboot" and the reset button do not count.
#
# A second trap: 'dmesg -C' does not clear the ring buffer on this build, so a
# reload-based test prints stale lines in a fresh-looking format. That is worse
# than no output at all, because it reads like a result. Nothing here tries to
# clear dmesg -- after a cold boot the buffer only contains that boot anyway.
#
# USAGE
#
#   On the board, from the serial console, in /lib/firmware/brcm, BEFORE poweroff:
#       sh wifi-test.sh list
#       sh wifi-test.sh stage <n>      # installs combo n, verifies hashes
#       poweroff
#
#   After the board has been power-cycled:
#       sh wifi-test.sh check
#
# The cold boot takes the network away, so run this over the serial console.

FW=/lib/firmware/brcm
W=/tmp/wifi-fw

# Primary source: RPi-Distro/firmware-nonfree, branch trixie. It is a Debian
# source package for the non-free blobs, so the licence travels with the files,
# and RPi's debian/copyright carries a stanza specific to *43456* (Copyright:
# Synaptics, License: Synaptics) rather than the Broadcom SLA that covers the
# rest of linux-firmware. Verified byte-identical to what the openSUSE mirror
# served during testing, so the earlier results stand.
#
# Ref: 3bab0f823f5b53150b76aab77093adef6655b920
RPI=https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/trixie/debian/added-firmware/brcm

# Secondary source, used only for the BCM43455 firmware, which RPi's non-free
# package does not carry (it has the NVRAM but not the .bin). armbian/firmware's
# README limits redistribution, so this is for local testing only, never for
# packaging.
ARM=https://raw.githubusercontent.com/armbian/firmware/master/brcm

# n|label|bin file|bin sha256|nvram file|nvram sha256
#
# Six pipe-separated fields. An earlier revision separated only n from the label
# and space-aligned the rest, so every field after the label parsed empty and
# "stage" copied nonexistent files. Keep the pipes.
COMBOS='
1|7.45.96.0 + AP6256 nvram|bin.745|3167956a7b2cffc4cfcaf6a282b95728c529eebef18a5d9e6d9ff32de32cc67c|txt.ap6|66c71eb53b47c49d42386b66735134578640b0946f3f46e44f384fef5aacfd9e
2|7.84.17.1 + RPi nvram|bin.rpi|ddf83f2100885b166be52d21c8966db164fdd4e1d816aca2acc67ee9cc28d726|txt.rpi|44e0bb322dc1f39a4b0a89f30ffdd28bc93f7d7aaf534d06d229fe56f6198194
3|7.84.17.1 + AP6256 nvram|bin.rpi|ddf83f2100885b166be52d21c8966db164fdd4e1d816aca2acc67ee9cc28d726|txt.ap6|66c71eb53b47c49d42386b66735134578640b0946f3f46e44f384fef5aacfd9e
4|7.45.96.0 + RPi nvram|bin.745|3167956a7b2cffc4cfcaf6a282b95728c529eebef18a5d9e6d9ff32de32cc67c|txt.rpi|44e0bb322dc1f39a4b0a89f30ffdd28bc93f7d7aaf534d06d229fe56f6198194
5|7.84.17.1 + 43455 nvram|bin.rpi|ddf83f2100885b166be52d21c8966db164fdd4e1d816aca2acc67ee9cc28d726|txt.r55|ca709be81a78bdb6932936374f39943acbd7af07fae6151011127599a3ce9e3d
6|7.45.69.0 (43455 fw) + AP6256|bin.55|5ecb7355e530fb06ebdc9991ceb6a697e0132499bdcac3e4fda55f5039a79a6a|txt.ap6|66c71eb53b47c49d42386b66735134578640b0946f3f46e44f384fef5aacfd9e
'

fetch_all () {
	mkdir -p "$W"
	# RPi's non-free package: the 43456 blobs and the 43455 NVRAM
	[ -f "$W/bin.rpi" ] || wget -q -O "$W/bin.rpi" "$RPI/brcmfmac43456-sdio.bin"
	[ -f "$W/txt.rpi" ] || wget -q -O "$W/txt.rpi" "$RPI/brcmfmac43456-sdio.txt"
	[ -f "$W/txt.r55" ] || wget -q -O "$W/txt.r55" "$RPI/brcmfmac43455-sdio.txt"
	# armbian/firmware: the older 43456 build and the 43455 firmware
	[ -f "$W/bin.745" ] || wget -q -O "$W/bin.745" "$ARM/brcmfmac43456-sdio.bin"
	[ -f "$W/txt.ap6" ] || wget -q -O "$W/txt.ap6" "$ARM/brcmfmac43456-sdio.txt"
	[ -f "$W/bin.55" ]  || wget -q -O "$W/bin.55"  "$ARM/brcmfmac43455-sdio.bin"
	echo "== candidates in $W =="
	for f in bin.rpi bin.745 bin.55 txt.rpi txt.r55 txt.ap6; do
		if [ -f "$W/$f" ]; then
			# wc -c, not stat -c%s: this board's busybox has no stat.
			echo "  $(sha256sum "$W/$f" | cut -c1-16)  $(wc -c < "$W/$f")  $f"
		else
			echo "  MISSING  $f"
		fi
	done
}

do_list () {
	echo "combos (each needs its own cold boot):"
	echo "$COMBOS" | grep -v '^$' | while IFS='|' read -r n lbl b bs t ts; do
		echo "  $n  $lbl"
		echo "       bin    $b  $(echo "$bs" | cut -c1-8)..."
		echo "       nvram  $t  $(echo "$ts" | cut -c1-8)..."
	done
	echo
	echo "already recorded:"
	echo "  1  7.45.96.0 + AP6256   cold   HT Avail timeout"
	echo "  2  7.84.17.1 + RPi      warm   phy0 registered, then attach -110"
	echo "  3  7.84.17.1 + AP6256   cold   HT Avail timeout"
	echo "  4  7.45.96.0 + RPi      --     never actually tested (stale dmesg)"
	echo "  5  7.84.17.1 + 43455    --     not tested"
	echo "  6  7.45.69.0 + AP6256   --     not tested"
	echo
	echo "note: combos 2 and 3 both use RPi's bytes, just reached differently."
	echo "      The packaged image now ships combo 2's files."
}

do_stage () {
	n=$1
	line=$(echo "$COMBOS" | grep "^$n|" || true)
	if [ -z "$line" ]; then echo "no such combo: $n"; do_list; exit 1; fi

	fetch_all
	name=$(echo "$line" | cut -d'|' -f2)
	binf=$(echo "$line" | cut -d'|' -f3)
	binsh=$(echo "$line" | cut -d'|' -f4)
	txtf=$(echo "$line" | cut -d'|' -f5)
	txtsh=$(echo "$line" | cut -d'|' -f6)

	# Refuse to install rather than copy a missing file over a good one: the
	# clm_blob and NVRAM must match the firmware too.
	for f in "$binf" "$txtf"; do
		if [ ! -f "$W/$f" ]; then
			echo "candidate $f was not fetched -- refusing to stage"
			exit 1
		fi
	done

	echo
	echo "== staging combo $n: $name"
	cp "$W/$binf" "$FW/brcmfmac43456-sdio.bin"
	cp "$W/$txtf" "$FW/brcmfmac43456-sdio.txt"

	echo "== installed =="
	sha256sum "$FW/brcmfmac43456-sdio.bin" "$FW/brcmfmac43456-sdio.txt"
	{
		echo "$binsh  brcmfmac43456-sdio.bin"
		echo "$txtsh  brcmfmac43456-sdio.txt"
	} | ( cd "$FW" && sha256sum -c - ) || echo "  WARNING: hash mismatch above"

	echo
	echo "== now: poweroff, UNPLUG the supply, wait 10 s, power on =="
	echo "== then run: sh wifi-test.sh check =="
}

identify () {
	# Which combination is actually on disk right now?
	#
	# Every wrong conclusion in this investigation came from labelling a result
	# with the wrong inputs: a warm result recorded as cold, a stale dmesg read
	# as fresh, a hash assumed rather than checked. So the state is derived from
	# the files, never from what the operator remembers doing.
	bin_h="$(sha256sum "$FW/brcmfmac43456-sdio.bin" 2>/dev/null | cut -d' ' -f1)"
	txt_h="$(sha256sum "$FW/brcmfmac43456-sdio.txt" 2>/dev/null | cut -d' ' -f1)"

	if [ -z "$bin_h" ] || [ -z "$txt_h" ]; then
		echo "  UNKNOWN -- firmware files missing from $FW"
		return
	fi

	# Read the table from a file, not a pipe: a pipe would put the loop in a
	# subshell and `found` would be lost when it exits. And never iterate it with
	# unquoted $(...) -- the labels contain spaces and would word-split apart.
	tmp="$(mktemp)"
	printf '%s\n' "$COMBOS" | grep -v '^$' > "$tmp"

	found=0
	while IFS='|' read -r n lbl b bs t ts; do
		[ "$bs" = "$bin_h" ] && [ "$ts" = "$txt_h" ] || continue
		echo "  combo $n: $lbl"
		found=1
	done < "$tmp"
	rm -f "$tmp"

	if [ "$found" = 0 ]; then
		echo "  UNKNOWN -- these hashes match no combo in the table:"
		echo "    bin    $bin_h"
		echo "    nvram  $txt_h"
		echo "  Do not attribute this result to any combo. Record the hashes instead."
	fi
}

do_check () {
	echo "== what is installed right now =="
	identify

	echo
	echo "== brcmfmac lines from this boot =="
	dmesg | grep -iE "brcmfmac|brcmf_|brcmf_sdio|ieee80211|wlan|mmc2" | sed 's/^/  /'

	echo
	echo "== verdict =="
	if ip link show wlan0 >/dev/null 2>&1; then
		echo "  wlan0 PRESENT -- this combination works"
		ip link show wlan0 | sed 's/^/    /'
	elif dmesg | grep -q "HT Avail timeout"; then
		echo "  no wlan0 -- HT Avail timeout: firmware uploaded, chip never started"
	elif dmesg | grep -q "dongle is not responding"; then
		echo "  no wlan0 -- dongle is not responding: got further than HT Avail"
	else
		echo "  no wlan0 -- but no recognisable brcmfmac failure either; paste the log above"
	fi
	echo
	echo "  Record above: the combo the hashes identify, the verdict, and whether the"
	echo "  boot was COLD (poweroff, unplug, wait, power on). 'reboot' does not reset"
	echo "  the WiFi peripheral, so a warm result is not comparable to a cold one."
}

case "$1" in
list)  do_list ;;
stage) do_stage "$2" ;;
check) do_check ;;
*)     echo "usage: $0 list | stage <n> | check"; do_list ;;
esac
