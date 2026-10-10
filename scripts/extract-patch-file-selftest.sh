#!/bin/sh
# Negative controls for extract-patch-file.sh and for the check that uses it.
# Run this BEFORE trusting a MATCH from check-patch-sources.sh.
#
# WHY THIS EXISTS
#
# The defect it guards against produced no output at all. extract-patch-file.sh
# could only find a file by its "diff --git a/X b/X" line, and the U-Boot DTS
# patch is plain `diff -u` output with no such line, so extraction returned
# empty. check-patch-sources.sh did not list that patch, so nothing compared it,
# and nothing reported that it was not being compared -- a skipped check and a
# passing check are indistinguishable from the outside.
#
# A checker that cannot fail is worse than no checker, because it is read as
# evidence. These cases are chosen so that each one, if the tool regressed,
# would turn into a silent pass rather than a visible failure:
#
#   1  git-style patch, two files, take the second   the original capability
#   2  plain unified patch, two files, no diff --git the one that was missing
#   3  wanted path absent from the patch             must be EMPTY, not "the only
#                                                     file", and not the other file
#   4  added content that itself starts with "++ "   renders as "+++ ..." and
#                                                     must not be read as a header
#   5  removed content that itself starts with "-- " renders as "--- ..."; must
#                                                     not break the NEXT file
#   6  two files whose paths share a suffix          must not match the wrong one
#   7  two hunks for one file                         both, in order, not just the
#                                                     first
#   8  context lines                                   never emitted
#   9  bare path argument, bare +++ header            plain diffs carry no b/
#  10  a stale 0100, and a stale 0001, end to end    does the restored check
#                                                     actually complain now?
#  11  text past the last hunk                        ignored, by the line count
#
# Case 10 is the one that answers the question this whole change was made for.
# Cases 1-9 and 11 are unit-level; case 10 runs the real check-patch-sources.sh
# against a throwaway tree so the wiring is exercised, not just the extractor.
#
# ⚠️ it only catches what it covers. Eleven cases is not proof.

HERE=$(cd "$(dirname "$0")" && pwd)
EXTRACT="$HERE/extract-patch-file.sh"
CHECK="$HERE/check-patch-sources.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0
fail=0

ok ()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad ()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"
          printf '        want: %s\n' "$2"
          printf '        got : %s\n' "$3"; }

# want <label> <expected-text> <patch> <path>
want () {
	if [ ! -f "$3" ]; then bad "$1" "(a readable fixture)" "fixture $3 does not exist"; return 0; fi
	_got=$("$EXTRACT" "$3" "$4" 2>/dev/null)
	if [ "$_got" = "$2" ]; then ok "$1"; else bad "$1" "$2" "$_got"; fi
}

# absent <label> <patch> <path>
#
# The missing-fixture guard matters here more than in `want`. A nonexistent patch
# makes the extractor fail, which produces no output, which is exactly what this
# case asserts -- so without the guard a typo in a fixture path reports PASS for
# the one thing most likely to be wrong.
absent () {
	if [ ! -f "$2" ]; then bad "$1" "(a readable fixture)" "fixture $2 does not exist"; return 0; fi
	_got=$("$EXTRACT" "$2" "$3" 2>/dev/null)
	if [ -z "$_got" ]; then ok "$1"; else bad "$1" "(empty)" "$_got"; fi
}

printf '=== extract-patch-file.sh ===\n\n'

# ---- 1  git style, two files, take the second ------------------------------
cat > "$WORK/git2.patch" <<'EOF'
diff --git a/aaa/first.dts b/aaa/first.dts
new file mode 100644
--- /dev/null
+++ b/aaa/first.dts
@@ -0,0 +1,2 @@
+FIRST1
+FIRST2
diff --git a/zzz/second.dts b/zzz/second.dts
new file mode 100644
--- /dev/null
+++ b/zzz/second.dts
@@ -0,0 +1,2 @@
+SECOND1
+SECOND2
EOF
want "1  git patch, second file only" \
	"SECOND1
SECOND2" "$WORK/git2.patch" "zzz/second.dts"

# ---- 2  plain unified, two files, no diff --git ----------------------------
# This is the shape regen-dts-patch.sh emits for 0100. The old tool found no
# "diff --git" line, set nothing, and printed nothing for every path.
cat > "$WORK/plain2.patch" <<'EOF'
From: OpenWrt ROCK 4B+ port
Subject: [PATCH] arm64: dts: rockchip: add something

--- /dev/null
+++ b/aaa/first.dts
@@ -0,0 +1,2 @@
+FIRST1
+FIRST2
--- /dev/null
+++ b/zzz/second.dts
@@ -0,0 +1,2 @@
+SECOND1
+SECOND2
EOF
want "2  plain unified patch, second file only" \
	"SECOND1
SECOND2" "$WORK/plain2.patch" "zzz/second.dts"

# ---- 3  wanted path not in the patch ---------------------------------------
# The dangerous case. With a single-file patch, a tool that ignores paths
# entirely returns that file's contents and reads as a match.
cat > "$WORK/single.patch" <<'EOF'
--- /dev/null
+++ b/only/this.dts
@@ -0,0 +1,1 @@
+ONLYLINE
EOF
absent "3  wanted path absent -> empty" "$WORK/single.patch" "nowhere/nope.dts"
absent "3b absent from a two-file patch -> empty" "$WORK/plain2.patch" "nowhere/nope.dts"
want  "3c the one file is still reachable" "ONLYLINE" "$WORK/single.patch" "only/this.dts"

# ---- 4  added content starting with "++ " ----------------------------------
# Written as "+++ ..." in the diff. Recognising headers by prefix alone would
# treat this as a file header, switch infile off, and silently truncate the file
# from here to the end.
cat > "$WORK/plusplus.patch" <<'EOF'
--- /dev/null
+++ b/keep/me.dts
@@ -0,0 +1,4 @@
+BEFORE
+++ b/switches/away/file
+AFTER1
+AFTER2
EOF
want "4  added '++ b/...' is content, not a header" \
	"BEFORE
++ b/switches/away/file
AFTER1
AFTER2" "$WORK/plusplus.patch" "keep/me.dts"

# ---- 5  a removed line that looks like a header ----------------------------
# Written as "--- ..." in the diff. It must be consumed as a removal, and the
# hunk must still be recognised as closed afterwards -- otherwise the real
# "--- /dev/null" / "+++ b/zzz/later.dts" that follow are swallowed as content
# and later.dts silently yields nothing. That is the discriminating version of
# this case: the failure shows up in the NEXT file, not in this one.
#
# Note the tool emits added lines only, so a modification hunk legitimately
# yields nothing. That is not a limitation to test around here -- every patch
# this port compares is a new-file patch -- but it does mean "no additions" and
# "not found" are the same output, which is exactly why case 3 matters.
cat > "$WORK/dashdash.patch" <<'EOF'
--- a/keep/me.dts
+++ b/keep/me.dts
@@ -1,3 +1,2 @@
 CONTEXT1
--- looks/like/a/header
 KEPT
--- /dev/null
+++ b/zzz/later.dts
@@ -0,0 +1,2 @@
+LATER1
+LATER2
EOF
want "5  removed '--- ...' does not break the next file" \
	"LATER1
LATER2" "$WORK/dashdash.patch" "zzz/later.dts"

# ---- 6  suffix collision ---------------------------------------------------
cat > "$WORK/suffix.patch" <<'EOF'
--- /dev/null
+++ b/deep/nested/path/rk3399-rock-4b-plus.dts
@@ -0,0 +1,1 @@
+NESTED
EOF
absent "6  suffix of another path does not match" \
	"$WORK/suffix.patch" "rk3399-rock-4b-plus.dts"
want  "6b the nested path itself does match" \
	"NESTED" "$WORK/suffix.patch" "deep/nested/path/rk3399-rock-4b-plus.dts"

# ---- 7  two hunks for one file ---------------------------------------------
cat > "$WORK/twobh.patch" <<'EOF'
--- a/keep/me.dts
+++ b/keep/me.dts
@@ -1,2 +1,3 @@
 A1
+A2
 B1
@@ -10,2 +11,3 @@
 C1
+C2
 D1
EOF
want "7  both hunks, in order" \
	"A2
C2" "$WORK/twobh.patch" "keep/me.dts"

# ---- 8  context lines are never emitted ------------------------------------
# Folded into case 7 above (A1/B1/C1/D1 absent from its expectation). Asserted
# separately too, so a regression localises to one behaviour instead of two.
cat > "$WORK/ctxonly.patch" <<'EOF'
--- a/keep/me.dts
+++ b/keep/me.dts
@@ -1,2 +1,2 @@
 SAMESAME
 STILLHERE
EOF
absent "8  hunk with no additions emits nothing" \
	"$WORK/ctxonly.patch" "keep/me.dts"

# ---- 9  bare path argument, unprefixed +++ header ---------------------------
cat > "$WORK/bare.patch" <<'EOF'
--- /dev/null
+++ plain/path/file.dts
@@ -0,0 +1,1 @@
+BARELINE
EOF
want "9  bare path + bare header" "BARELINE" "$WORK/bare.patch" "plain/path/file.dts"

printf '\n=== check-patch-sources.sh, end to end ===\n\n'

# ---- 10  a stale 0100 must be reported -------------------------------------
# A throwaway tree, so the real one is never touched and the result does not
# depend on what is actually checked out.
FAKE_TREE="$WORK/tree"
FAKE_PORT="$WORK/port"
mkdir -p "$FAKE_TREE/target/linux/rockchip/patches-6.12" \
         "$FAKE_TREE/package/boot/uboot-rockchip/patches" \
         "$FAKE_PORT/overlay/kernel" "$FAKE_PORT/overlay/u-boot"

# One source, three lines, shared by the two DTS patches.
printf 'line one\nline two\nline three\n' > "$FAKE_PORT/overlay/kernel/rk3399-rock-4b-plus.dts"

git_mk () {   # $1 patch path, $2 dts path inside the patch
	{
		echo "--- /dev/null"
		echo "+++ b/$2"
		echo "@@ -0,0 +1,3 @@"
		printf '+line one\n+line two\n+line three\n'
	} > "$1"
}

# 0100 in its real plain-unified shape; 0001 in its real git shape.
git_mk "$FAKE_TREE/package/boot/uboot-rockchip/patches/0100-arm64-dts-rockchip-add-Radxa-ROCK-4B-plus.patch" \
	dts/upstream/src/arm64/rockchip/rk3399-rock-4b-plus.dts
{
	echo "diff --git a/arch/arm64/boot/dts/rockchip/Makefile b/arch/arm64/boot/dts/rockchip/Makefile"
	echo "--- a/arch/arm64/boot/dts/rockchip/Makefile"
	echo "+++ b/arch/arm64/boot/dts/rockchip/Makefile"
	echo "@@ -1,1 +1,2 @@"
	echo " obj-y += foo.o"
	echo "+obj-y += rk3399-rock-4b-plus.o"
	echo "diff --git a/arch/arm64/boot/dts/rockchip/rk3399-rock-4b-plus.dts b/arch/arm64/boot/dts/rockchip/rk3399-rock-4b-plus.dts"
	echo "--- /dev/null"
	echo "+++ b/arch/arm64/boot/dts/rockchip/rk3399-rock-4b-plus.dts"
	echo "@@ -0,0 +1,3 @@"
	printf '+line one\n+line two\n+line three\n'
} > "$FAKE_TREE/target/linux/rockchip/patches-6.12/0001-arm64-dts-rockchip-add-Radxa-ROCK-4B-plus.patch"

# The two hand-made U-Boot patches, matching their own sources.
printf 'CONFIG_X=y\n' > "$FAKE_PORT/overlay/u-boot/rock-4b-plus-rk3399_defconfig"
printf 'CONFIG_X=y\n' > "$FAKE_PORT/overlay/u-boot/rk3399-rock-4b-plus-u-boot.dtsi"
hand_mk () {   # $1 patch, $2 path inside patch, $3 payload
	{
		echo "--- /dev/null"
		echo "+++ b/$2"
		echo "@@ -0,0 +1,1 @@"
		printf '+%s\n' "$3"
	} > "$1"
}
# NB the 0102 target path is arch/arm/dts, not arch/arm64/dts -- that is what
# the real patch header says. Guessing it wrong produced a DRIFT that read like
# a tool failure and was not one.
hand_mk "$FAKE_TREE/package/boot/uboot-rockchip/patches/0101-configs-add-rock-4b-plus-rk3399-defconfig.patch" \
	configs/rock-4b-plus-rk3399_defconfig "CONFIG_X=y"
hand_mk "$FAKE_TREE/package/boot/uboot-rockchip/patches/0102-board-rockchip-Add-ROCK-4B-plus-U-Boot-dtsi.patch" \
	arch/arm/dts/rk3399-rock-4b-plus-u-boot.dtsi "CONFIG_X=y"

run_check () {
	PORT_DIR="$FAKE_PORT" OPENWRT_DIR="$FAKE_TREE" sh "$CHECK" 2>&1
}

# Baseline: everything agrees, so a failure below is the mutation and not the
# fixture. Without this, a broken fixture makes all three cases "pass".
base_out=$(run_check) && base_rc=0 || base_rc=$?
if [ "$base_rc" -eq 0 ] && [ "$(printf '%s\n' "$base_out" | grep -c 'MATCH')" -eq 4 ]; then
	ok "10a clean fixture: 4 checks pass"
else
	bad "10a clean fixture: 4 checks pass" "rc=0 with 4 MATCH" "rc=$base_rc: $base_out"
fi

# Now make 0100 stale -- the exact regression this change is about.
#
# The mutation has to go INSIDE the hunk. Appending to the end of the patch file
# changes nothing the extractor can see: the @@ header fixes the line count, the
# hunk closes after it, and anything past that point is not part of the file.
# That was the first attempt here, and it "passed" -- the check reported MATCH
# on a patch that had been edited. See case 11.
{
	echo "--- /dev/null"
	echo "+++ b/dts/upstream/src/arm64/rockchip/rk3399-rock-4b-plus.dts"
	echo "@@ -0,0 +1,3 @@"
	printf '+line one\n+line two\n+line 3\n'
} > "$FAKE_TREE/package/boot/uboot-rockchip/patches/0100-arm64-dts-rockchip-add-Radxa-ROCK-4B-plus.patch"

stale_out=$(run_check) && stale_rc=0 || stale_rc=$?
if [ "$stale_rc" -ne 0 ] && printf '%s\n' "$stale_out" | grep -q 'DRIFT.*0100-'; then
	ok "10b stale 0100 is reported, and names the patch"
else
	bad "10b stale 0100 is reported, and names the patch" \
		"rc!=0 and a DRIFT line naming 0100-" "rc=$stale_rc: $stale_out"
fi

# Both DTS patches share one source name, so a DRIFT that did not name the
# patch would be ambiguous between 0001 and 0100.
if printf '%s\n' "$stale_out" | grep -q 'DRIFT.*rk3399-rock-4b-plus.dts.*<-.*0100-'; then
	ok "10c DRIFT names both the source and the patch"
else
	bad "10c DRIFT names both the source and the patch" \
		"DRIFT <source> <- <patch containing 0100->" "$stale_out"
fi

# And 0001 alone going stale must still be caught and still be distinguishable.
{
	echo "diff --git a/arch/arm64/boot/dts/rockchip/rk3399-rock-4b-plus.dts b/arch/arm64/boot/dts/rockchip/rk3399-rock-4b-plus.dts"
	echo "--- /dev/null"
	echo "+++ b/arch/arm64/boot/dts/rockchip/rk3399-rock-4b-plus.dts"
	echo "@@ -0,0 +1,3 @@"
	printf '+line one\n+line two\n+line 3\n'
} > "$FAKE_TREE/target/linux/rockchip/patches-6.12/0001-arm64-dts-rockchip-add-Radxa-ROCK-4B-plus.patch"

k_out=$(run_check) && k_rc=0 || k_rc=$?
if [ "$k_rc" -ne 0 ] && printf '%s\n' "$k_out" | grep -q 'DRIFT.*<-.*0001-'; then
	ok "10d stale 0001 is reported too"
else
	bad "10d stale 0001 is reported too" "rc!=0 and a DRIFT line naming 0001-" "rc=$k_rc: $k_out"
fi

# ---- 11  text past the last hunk is not part of the file -------------------
# The @@ header carries the line count, so the hunk closes after it and anything
# beyond that point is not addressed by the patch at all. Appending to a patch
# therefore changes nothing the extractor can see -- which is exactly how the
# case-10b mutation above first "passed" on an edited file.
#
# Worth stating as a property rather than leaving to be rediscovered: it is the
# reason a DRIFT must be produced by editing inside a hunk, and it is also why
# this tool cannot be used to spot a patch that has trailing junk appended.
cat > "$WORK/trailing.patch" <<'EOF'
--- /dev/null
+++ b/keep/me.dts
@@ -0,0 +1,2 @@
+LINE1
+LINE2
+APPENDED-OUTSIDE-THE-HUNK
EOF
want "11 text past the last hunk is ignored" \
	"LINE1
LINE2" "$WORK/trailing.patch" "keep/me.dts"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0