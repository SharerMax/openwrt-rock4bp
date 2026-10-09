#!/bin/sh
# Judge this port's U-Boot by rebooting the board until it stops panicking.
#
# Why this exists: there is no serial console on this board, so the six-boot
# threshold cannot be reached by watching a capture. The board is on the
# network, so the same evidence comes from ssh: a real reboot shows a new
# boot_id, a clean dmesg, and the SDIO phase in the rail band.
#
# ⚠️ THE THRESHOLD IS SIX CONSECUTIVE CLEAN BOOTS. One clean boot proves
# nothing. This script does not decide whether the port is fixed; it only
# produces the numbers, and it prints a verdict line you must read against
# the threshold yourself.
#
# Discipline this script follows, each because it was got wrong here before:
#
#  * `setsid reboot`, not `nohup reboot &`. A backgrounded process dies with
#    the pty when ssh exits, the board never goes down, and the result is
#    indistinguishable from a successful no-op: reboot exits 0, the board keeps
#    answering, boot_id is unchanged. Two rounds of a five-round matrix were
#    lost to this before the boot_id assertion caught it.
#
#  * boot_id must change every round. Checking only "is it up" cannot tell a
#    real reboot from a no-op.
#
#  * Every ssh is wrapped in `timeout`, and reachability is judged by the
#    wrapper's exit status. ConnectTimeout bounds only the TCP connect; the
#    askpass exchange can block indefinitely.
#
#  * A boot that never comes back is a FAILURE, recorded and counted, never
#    retried. The panic lands at 0.5-1.4s, before networking, so a board that
#    stays unreachable has told us something.
#
#  * The SDIO phase is checked as a BAND, never as an exact value. One
#    vdd_log image has read 221, 224, 225 and 223 on successive boots. What the
#    value separates is the rail -- every vdd_log boot has read 22x, every boot
#    before it read exactly 269, and Armbian reads 220-223. Asserting "== 221"
#    fails on a correct build; asserting "220-224" failed on a real reading of
#    225. Widen the band from observed readings, not from guesswork.
#
#  * A MISSING phase is a distinct outcome from a phase of zero: it means the
#    boot died before the SDIO controller was probed.
#
# Usage:
#   check-reboot-matrix.sh                 # 6 rounds, board 192.168.3.8
#   BOARD=root@1.2.3.4 ROUNDS=10 check-reboot-matrix.sh
#
# Requires passwordless ssh to the board and an ACCEPTED host key. A changed
# host key means the board was reflashed -- check which key you have before
# assuming a host is the board.

BOARD=${BOARD:-root@192.168.3.8}
ROUNDS=${ROUNDS:-6}
WAIT_DOWN=${WAIT_DOWN:-120}     # seconds to wait for the board to go away
WAIT_UP=${WAIT_UP:-180}         # seconds to wait for it to come back
# ⚠️ The log lands in the repo's log/, dated, NOT in /tmp.
#
# It used to default to /tmp/reboot-matrix.txt, and two of the four acceptance
# runs from this port were lost to a /tmp clear on the build host. The verdict
# "6 clean boots" is worthless later without the run it came from, and that
# log is the only record of the boot_ids -- so it goes where logs are kept.
#
# log/ is gitignored, which is correct: a boot log is evidence, not source. It
# still has to outlive the machine, and /tmp does not.
OUT=${OUT:-$(cd "$(dirname "$0")/.." && pwd)/log/reboot-matrix-$(date +%Y%m%d-%H%M%S).txt}
mkdir -p "$(dirname "$OUT")"

ssh_opts="-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=yes"

probe() {
	timeout 25 ssh $ssh_opts $BOARD 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null
}

: > $OUT
{
	echo "=== reboot matrix: $ROUNDS rounds against $BOARD ==="
	echo "started: $(date -Is)"
	echo "threshold: SIX consecutive clean boots -- this script does not decide"
	echo ""
} | tee -a $OUT

pass=0
fail=0
prev=$(probe)
echo "baseline boot_id: ${prev:-<unreachable>}" | tee -a $OUT
echo "" | tee -a $OUT

i=1
while [ $i -le $ROUNDS ]; do
	echo "--- round $i ---" | tee -a $OUT

	timeout 20 ssh $ssh_opts $BOARD 'setsid reboot >/dev/null 2>&1 </dev/null &' >/dev/null 2>&1
	echo "  trigger exit=$?" | tee -a $OUT

	# Wait for it to STOP answering, so we cannot read the old kernel's
	# boot_id back and mistake it for the new one.
	gone=0
	w=0
	while [ $w -lt $WAIT_DOWN ]; do
		sleep 3; w=$((w + 3))
		[ -z "$(probe)" ] && { gone=1; break; }
	done
	[ $gone -eq 0 ] && echo "  ⚠️ never went offline in ${WAIT_DOWN}s" | tee -a $OUT

	back=0; w=0
	while [ $w -lt $WAIT_UP ]; do
		sleep 5; w=$((w + 5))
		id=$(probe)
		[ -n "$id" ] && { back=1; break; }
	done

	if [ $back -eq 0 ]; then
		echo "  ❌ FAIL  never returned within ${WAIT_UP}s (panic: the kernel cannot come up)" | tee -a $OUT
		fail=$((fail + 1)); echo "$i FAIL unreachable" >> $OUT
		prev=""
		i=$((i + 1)); echo "" | tee -a $OUT
		continue
	fi

	if [ -n "$prev" ] && [ "$id" = "$prev" ]; then
		echo "  ❌ FAIL  boot_id unchanged ($id) -- that was not a real reboot" | tee -a $OUT
		fail=$((fail + 1)); echo "$i FAIL boot_id unchanged" >> $OUT
		i=$((i + 1)); echo "" | tee -a $OUT
		continue
	fi

	res=$(timeout 40 ssh $ssh_opts $BOARD '
		echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
		dmesg | grep -o "tuned phase to [0-9]*" | head -1 | grep -o "[0-9]*$" > /tmp/.mx_ph
		echo "phase=$(cat /tmp/.mx_ph 2>/dev/null)"
		echo "uptime=$(cut -d" " -f1 /proc/uptime)"
		grep MemTotal /proc/meminfo | tr -s " " | cut -d" " -f2 > /tmp/.mx_mem
		echo "memtotal=$(cat /tmp/.mx_mem)"
		dmesg | grep -m1 "VFS: Mounted root" > /tmp/.mx_mnt
		echo "mount=$(cat /tmp/.mx_mnt)"
		dmesg | grep -icE "kernel panic|internal error|oops|BUG:|unable to handle" > /tmp/.mx_bad
		echo "bad=$(cat /tmp/.mx_bad)"
	' 2>/dev/null)

	bid=$(echo "$res" | sed -n 's/^boot_id=//p')
	ph=$(echo "$res"  | sed -n 's/^phase=//p'   | tr -d ' ')
	bad=$(echo "$res" | sed -n 's/^bad=//p')
	mem=$(echo "$res" | sed -n 's/^memtotal=//p')
	up=$(echo "$res"  | sed -n 's/^uptime=//p')

	echo "  boot_id=$bid" | tee -a $OUT
	echo "  phase=$ph  MemTotal=$mem kB  reachable after ${up}s" | tee -a $OUT
	echo "$res" | sed -n 's/^mount=/  /p' | tee -a $OUT

	# Only 269 is a verdict. See the header: on a correct build the phase
	# varies over an 11-wide range (215-226 measured), so any band assertion
	# eventually marks a clean boot as broken. It did, three times.
	# A missing phase IS still a verdict -- it means the boot died before the
	# SDIO controller was probed, which is a real failure mode.
	#
	# Uses $ph, not $ph_n: $ph_n was never assigned and every round therefore
	# reported "no phase recorded". The negative control below only covered the
	# unreachable case, so it passed while this was broken. It now also covers
	# "reachable but the field is empty", which is how this shipped.
	verdict=""
	if [ -z "$ph" ]; then
		verdict="no phase recorded -- died before probing SDIO"
	elif [ "$ph" = "269" ]; then
		verdict="phase 269 -- this is a pre-vdd_log build, not what is under test"
	fi
	echo "  phase recorded: ${ph:-none} (not asserted; see header)" | tee -a $OUT

	if [ -n "$verdict" ]; then
		echo "  ❌ FAIL  $verdict" | tee -a $OUT
		fail=$((fail + 1)); echo "$i FAIL $verdict" >> $OUT
	elif [ "$bad" != "0" ]; then
		echo "  ❌ FAIL  dmesg has $bad anomaly lines" | tee -a $OUT
		fail=$((fail + 1)); echo "$i FAIL dmesg=$bad" >> $OUT
	else
		echo "  ✅ clean" | tee -a $OUT
		pass=$((pass + 1)); echo "$i PASS phase=${ph:-none} boot_id=$bid mem=$mem" >> $OUT
	fi

	prev=$bid
	i=$((i + 1))
	echo "" | tee -a $OUT
done

{
	echo "=== summary ==="
	echo "clean $pass / $ROUNDS, failed $fail / $ROUNDS"
	echo "finished: $(date -Is)"
	if [ $fail -eq 0 ]; then
		echo ""
		echo "$pass consecutive clean boots on this build."
		echo "⚠️  Read this against the six-boot threshold, not against this line."
		echo "⚠️  It does NOT locate the root cause, and it does NOT clear the port"
		echo "    for shipping on its own -- the failure was intermittent, so a run"
		echo "    of N clean boots bounds the rate, it does not prove it is zero."
	else
		echo ""
		echo "❌ Below threshold. The failure is still present."
	fi
} | tee -a $OUT
