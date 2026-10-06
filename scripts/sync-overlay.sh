#!/bin/sh
# Report, and optionally reconcile, drift between this repo's overlay/ and the
# files actually in the OpenWrt build tree.
#
# WHY THIS EXISTS
#
# The port has two homes for the same content:
#
#   <port repo>/overlay/...   the authored source, in git
#   $OPENWRT_DIR/...         what the build actually compiles
#
# Until now these were kept in step by hand, with scp. That fails silently:
# editing a file in the tree builds fine and looks correct, while the repo drifts
# out of date with no error anywhere.
#
# This is not hypothetical. The first run of this script found
# target/linux/rockchip/image/armv8.mk already diverged: the tree had the fixed
# DEVICE_PACKAGES and the repo still had the pre-fix version.
#
# DIRECTION IS NEVER GUESSED
#
# There is deliberately no bare --apply. Either side can be the newer one --
# files get edited in the tree during a debugging session just as often as in the
# repo -- and copying the stale side over the good one silently reverts the
# port, while still producing a clean build. So you name the direction:
#
#   --from-tree     copy the build tree over overlay/   (repo is behind)
#   --from-overlay  copy overlay/ over the build tree   (repo is ahead)
#
# USAGE
#
#   ./sync-overlay.sh                 check only; non-zero exit if anything differs
#   ./sync-overlay.sh --diff          check, and show what differs
#   ./sync-overlay.sh --from-tree     reconcile tree -> repo, after confirmation
#   ./sync-overlay.sh --from-overlay  reconcile repo -> tree, after confirmation
#   add --yes to either to skip the confirmation
#
#   ./sync-overlay.sh --stage-dts     stage the DTS where regen-dts-patch.sh
#                                     expects it, /tmp/rk3399-rock-4b-plus.dts
#
# EXIT STATUS
#
#   0  everything in sync
#   1  differences found (check mode) or a copy failed
#   2  bad usage, or a directory is missing
#
# WHAT IS NOT SYNCED, AND WHY
#
#   overlay/kernel/rk3399-rock-4b-plus.dts        a patch SOURCE, staged to /tmp
#   overlay/u-boot/rock-4b-plus-rk3399_defconfig  a patch SOURCE, used by hand
#
# What lands in the tree is a generated patch
# (target/linux/rockchip/patches-6.12/0001-*.patch, and
# package/boot/uboot-rockchip/patches/0101-*.patch), so copying a .dts over a
# .patch would be meaningless. regen-dts-patch.sh performs that generation: after
# changing the DTS, run it, then check that the regenerated patch applies.

set -e

PORT_DIR="${PORT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
OPENWRT_DIR="${OPENWRT_DIR:-/home/max/Code/openwrt}"
STAGED_DTS=/tmp/rk3399-rock-4b-plus.dts

# "" = check only, "tree" = tree is the source, "overlay" = overlay is the source
DIRECTION=""
YES=0
DIFF=0
STAGE_DTS=0
rc=0

for arg in "$@"; do
	case "$arg" in
		--from-tree)    DIRECTION=tree ;;
		--from-overlay) DIRECTION=overlay ;;
		--yes|-y)       YES=1 ;;
		--diff)         DIFF=1 ;;
		--stage-dts)    STAGE_DTS=1 ;;
		-h|--help)      sed -n '2,/^set -e$/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
		--apply)
			echo "--apply was removed on purpose: it has to pick a direction, and" >&2
			echo "guessing reverts work without failing. Use --from-tree or" >&2
			echo "--from-overlay after reading the --diff output." >&2
			exit 2 ;;
		*)              echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

[ -d "$PORT_DIR/overlay" ] || { echo "no overlay/ under $PORT_DIR" >&2; exit 2; }
[ -d "$OPENWRT_DIR" ]     || { echo "no such OpenWrt tree: $OPENWRT_DIR" >&2; exit 2; }

# overlay path (relative to overlay/) -> path in the OpenWrt tree
#
# Only files copied verbatim belong here. The *.orig baselines deliberately do
# NOT: they record what upstream looked like before this port edited the file, so
# copying one over its counterpart would revert the port.
MAP="
package/boot/uboot-rockchip/Makefile|package/boot/uboot-rockchip/Makefile
package/firmware/broadcom-nonfree/Makefile|package/firmware/broadcom-nonfree/Makefile
target/linux/rockchip/image/armv8.mk|target/linux/rockchip/image/armv8.mk
"

line () { printf '%s\n' "$*"; }
rule () { line "------------------------------------------------------------"; }

rule
line "port repo   : $PORT_DIR"
line "build tree  : $OPENWRT_DIR"
if [ -n "$DIRECTION" ]; then
	line "direction   : $( [ "$DIRECTION" = tree ] && echo 'tree -> overlay' || echo 'overlay -> tree' )"
else
	line "direction   : none (check only)"
fi
rule

napply=0

for pair in $MAP; do
	src_rel="${pair%%|*}"
	dst_rel="${pair##*|}"
	ov="$PORT_DIR/overlay/$src_rel"
	tr="$OPENWRT_DIR/$dst_rel"

	if [ ! -f "$ov" ]; then
		printf 'MISSING IN REPO  %s\n' "$src_rel"
		rc=1
		continue
	fi

	if [ ! -f "$tr" ]; then
		printf 'MISSING IN TREE %s\n' "$dst_rel"
		if [ "$DIRECTION" = overlay ]; then
			mkdir -p "$(dirname "$tr")"
			cp "$ov" "$tr"
			printf '  -> created in the tree\n'
		else
			rc=1
		fi
		continue
	fi

	if cmp -s "$ov" "$tr"; then
		printf 'in sync      %s\n' "$src_rel"
		continue
	fi

	# Which side is newer is a fact about mtimes, not a verdict about which is
	# right. Report both so the choice is made deliberately.
	if [ "$ov" -nt "$tr" ]; then age="overlay newer"; else age="tree newer"; fi
	printf 'DIFFERS      %s   (%s)\n' "$src_rel" "$age"
	[ "$DIFF" = 1 ] && { diff -u "$tr" "$ov" | sed 's/^/    /' || true; }

	case "$DIRECTION" in
		tree)    napply=$((napply+1)); cp "$tr" "$ov"; printf '  -> tree copied over overlay\n' ;;
		overlay) napply=$((napply+1)); cp "$ov" "$tr"; printf '  -> overlay copied over tree\n' ;;
		*)       rc=1 ;;
	esac
done

rule

# The DTS is a patch source, not a tree file. regen-dts-patch.sh reads it from
# /tmp, which is why it has to be staged by hand after every edit.
dts_src="$PORT_DIR/overlay/kernel/rk3399-rock-4b-plus.dts"
if [ "$STAGE_DTS" = 1 ]; then
	if [ -f "$dts_src" ]; then
		cp "$dts_src" "$STAGED_DTS"
		printf 'staged       overlay/kernel/rk3399-rock-4b-plus.dts -> %s (%s bytes)\n' \
			"$STAGED_DTS" "$(stat -c%s "$STAGED_DTS")"
	else
		printf 'MISSING      %s\n' "$dts_src"
		rc=1
	fi
else
	printf 'not checked  overlay/kernel/rk3399-rock-4b-plus.dts  (a patch source; --stage-dts to stage it)\n'
	printf 'not checked  overlay/u-boot/rock-4b-plus-rk3399_defconfig  (a patch source)\n'
fi

# A dirty build tree means the tree is mid-edit; reconciling against it is
# usually the wrong move, so say so rather than silently proceeding.
if [ -d "$OPENWRT_DIR/.git" ]; then
	dirty="$(git -C "$OPENWRT_DIR" status --short --porcelain -- \
		package/boot/uboot-rockchip/Makefile \
		package/firmware/broadcom-nonfree/Makefile \
		target/linux/rockchip/image/armv8.mk 2>/dev/null || true)"
	if [ -n "$dirty" ]; then
		printf '\nuncommitted changes in the build tree for the mapped files:\n'
		printf '%s\n' "$dirty" | sed 's/^/    /'
		printf 'decide whether those edits are wanted before reconciling either way\n'
	fi
fi

line ""
case "$rc" in
	0)
		if [ "$napply" -gt 0 ]; then
			line "reconciled $napply file(s) in the requested direction"
			line "now re-run with --diff to confirm, and commit whichever repo changed"
		else
			line "overlay and build tree agree"
			line "note: generated patches are outside this script's reach. After editing"
			line "the DTS, run regen-dts-patch.sh and confirm the patch still applies."
		fi
		;;
	*)
		line "differences found -- no files were changed"
		line "read them with --diff, then pass --from-tree or --from-overlay deliberately"
		;;
esac

exit "$rc"
