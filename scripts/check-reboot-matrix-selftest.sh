#!/bin/sh
# Negative controls for check-reboot-matrix.sh.
#
# A matrix script that cannot fail is worse than none, and neither is one that
# fails for the wrong reason. This proves both directions, and specifically
# covers the two wrong-reason failures that actually happened here:
#
#   1. unreachable board            -> must FAIL (the original control)
#   2. reachable, phase field empty -> must FAIL
#   3. reachable, phase reads 269   -> must FAIL  (pre-vdd_log build)
#   4. reachable, phase in 215-226  -> must PASS  (a correct vdd_log build)
#   5. boot_id unchanged           -> must FAIL  (the reboot did not happen)
#
# Cases 2-5 are driven by a stub ssh, so they need no board. Case 2 is the one
# that shipped broken: $ph_n was never assigned, so every round read "no phase"
# and FAILed -- while the negative control, which only tested case 1, passed.
#
# Usage: check-reboot-matrix-selftest.sh [path-to-check-reboot-matrix.sh]

set -u
SCRIPT=${1:-$(dirname "$0")/check-reboot-matrix.sh}
WORK=$(mktemp -d)
# Exported: the stub ssh below reads $WORK at RUN time, and an unexported
# variable resolves to the empty string there, which silently produced CALLS=/calls.
export WORK
trap 'rm -rf "$WORK"' EXIT

fails=0
note() { printf '  %-58s %s\n' "$1" "$2"; }

# Build a stub ssh that answers with fixed values, so the matrix logic runs for
# real against a controllable "board".
stub() {
	cat > "$WORK/ssh" <<EOF
#!/bin/sh
# $1 -- BOOT_ID, $2 -- PHASE, $3 -- BAD, $4 -- go-down-after-probe(yes/no)
CALLS=\$WORK/calls; echo x >> "\$CALLS"
case "\$*" in
  # ORDER MATTERS. The gather command contains the literal text "boot_id=" as
  # well, so a *boot_id* branch placed first swallows it. mx_ph appears only in
  # the gather command, so it has to be tested first.
  *mx_ph*|*"grep -icE"*)           # the gather command, one argument
    # The matrix reads these from ssh's STDOUT. Writing /tmp/.mx_* files, which
    # is what the real remote command does, produces nothing the parser can see.
    echo "boot_id=STUB-\$(wc -l < "\$CALLS" | tr -d ' ')"
    [ -n "$2" ] && echo "phase=$2" || echo "phase="
    echo "uptime=21.10"
    echo "memtotal=3961704"
    echo "mount=[    1.375696] VFS: Mounted root (ext4 filesystem) on device 179:2."
    echo "bad=$3"
    ;;
  *boot_id*)                       # the boot_id probe
    n=\$(wc -l < "\$CALLS")
    # call 1 = baseline, calls 2-3 = "down" (the reboot), call 4+ = back up
    if [ "$4" = yes ] && [ "\$n" -ge 2 ] && [ "\$n" -le 3 ]; then exit 1; fi
    # A real reboot produces a NEW boot_id; the baseline call must differ.
    if [ "\$n" -ge 4 ]; then
      [ -n "$1" ] && echo "NEW-$1" || exit 1
    else
      [ -n "$1" ] && echo "$1" || exit 1
    fi
    ;;
  *"reboot"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
	chmod +x "$WORK/ssh"
	: > "$WORK/calls"
	: > "$WORK/out"
	# stdout and $OUT must be DIFFERENT files: the matrix tees each line into
	# $OUT and also prints it, so sharing one file counts every line twice.
	PATH="$WORK:$PATH" ROUNDS=1 WAIT_DOWN=6 WAIT_UP=6 OUT="$WORK/out" \
		timeout 60 sh "$SCRIPT" > "$WORK/stdout" 2>&1 || true
}

# `grep -c` prints 0 *and* exits 1 on no match, so `|| echo 0` yields "0\n0" and
# every comparison breaks. `|| true` keeps the printed 0 and drops the exit code.
# $OUT records each failed round twice on purpose: once via `tee` for a human,
# once appended as a machine-readable line. So a failure is ">= 1", not "== 1" --
# counting exactly would test the formatting instead of the behaviour.
verdict()  { grep -c 'FAIL' "$WORK/out" 2>/dev/null || true; }

# expect_fail NAME  -- must produce at least one FAIL
expect_fail() {
	n=$(verdict)
	if [ "${n:-0}" -ge 1 ]; then note "$1" OK; else
		note "$1" "FAIL (expected >=1 FAIL, got ${n:-0})"; fails=$((fails + 1))
	fi
}

# expect_pass NAME  -- must produce no FAIL at all
expect_pass() {
	n=$(verdict)
	if [ "${n:-0}" -eq 0 ]; then note "$1" OK; else
		note "$1" "FAIL (expected 0 FAIL, got $n)"; fails=$((fails + 1))
	fi
}

echo "=== negative controls for check-reboot-matrix.sh ==="

# 1. genuinely unreachable
: > "$WORK/calls"
printf '#!/bin/sh\nexit 255\n' > "$WORK/ssh"; chmod +x "$WORK/ssh"
: > "$WORK/out"
PATH="$WORK:$PATH" BOARD=root@192.0.2.1 ROUNDS=1 WAIT_DOWN=3 WAIT_UP=3 \
	OUT="$WORK/out" timeout 60 sh "$SCRIPT" > "$WORK/stdout" 2>&1 || true
n=$(grep -c 'never returned' "$WORK/out" || true)
if [ "${n:-0}" -ge 1 ]; then note "1 unreachable board fails" OK; else
	note "1 unreachable board fails" "FAIL (expected >=1, got ${n:-0})"; fails=$((fails + 1))
fi

# 2. reachable, phase missing -> the bug that shipped
stub aa11  ''      0 yes
expect_fail "2 empty phase field fails"

# 3. reachable, phase 269 -> pre-vdd_log build
stub aa11  '269'  0 yes
expect_fail "3 phase 269 fails"

# 4. reachable, phase 215 -> a real reading from a correct build
stub aa11  '215'  0 yes
expect_pass "4 phase 215 passes"

# 4b. the other end of the observed spread
stub aa11  '226'  0 yes
expect_pass "4b phase 226 passes"

# 5. dmesg has an anomaly
stub aa11  '223'  2 yes
expect_fail "5 dmesg anomaly fails"

# 6. board answers but never goes down -> reboot_id unchanged -> must fail
stub aa11  '223'  0 no
n=$(grep -c 'boot_id unchanged\|never went offline' "$WORK/out" || true)
if [ "${n:-0}" -ge 1 ]; then note "6 no-offline fails" OK; else
	note "6 no-offline fails" "FAIL (expected >=1, got ${n:-0})"; fails=$((fails + 1))
fi

echo
if [ "$fails" -eq 0 ]; then
	echo "SELF-TEST: PASS"
	exit 0
fi
echo "SELF-TEST: FAIL ($fails case(s))"
exit 1
