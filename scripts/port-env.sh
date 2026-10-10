# Shared environment resolution for this port's scripts.
#
# SOURCED, never executed. The caller sets _here before sourcing:
#
#     _here=$(cd "$(dirname "$0")" && pwd)     # BEFORE any cd
#     . "$_here/port-env.sh"
#
# WHY THIS EXISTS
#
# Every script used to carry the build host's absolute paths:
#
#     OPENWRT_DIR="${OPENWRT_DIR:-/home/max/Code/openwrt}"
#     cd /home/max/Code/openwrt || exit 99
#     K="$TOP/build_dir/.../linux-6.12.94"
#     UB=build_dir/.../u-boot-2025.10
#
# which makes the build instructions in docs/build.md true only on one machine,
# and pins the kernel and U-Boot versions that OpenWrt itself chooses. Anyone
# else following the instructions got a "No such file or directory" that said
# nothing about which path was wrong.
#
# Two traps, both already hit here:
#
#   - $0 is only absolute if the caller passed an absolute path. Resolving
#     `dirname "$0"` AFTER `cd` into the tree pointed it at the wrong
#     directory, and four post-build assertions reported FAILED because they
#     could not find their own helper scripts. So _here is computed first,
#     always.
#   - Hardcoding the kernel or U-Boot version silently checks the WRONG build
#     directory after an OpenWrt bump, and a hash comparison against a stale
#     directory can still pass.

# PORT_DIR: this repository's root.
PORT_DIR="${PORT_DIR:-$(cd "$_here/.." && pwd)}"

# OPENWRT_DIR: the environment wins. Otherwise the current directory if it is a
# tree, otherwise a sibling checkout. Never guessed further than that, because a
# wrong guess reads a different tree and reports a mismatch that means nothing.
if [ -z "${OPENWRT_DIR:-}" ]; then
    if [ -d target/linux/rockchip ] && [ -d package/boot/uboot-rockchip ]; then
        OPENWRT_DIR=$(pwd)
    elif [ -d ../openwrt/target/linux/rockchip ]; then
        OPENWRT_DIR=$(cd ../openwrt && pwd)
    else
        printf 'OPENWRT_DIR is not set and no OpenWrt tree was found here or in ../openwrt.\n' >&2
        printf 'Point at it explicitly, for example:\n\n' >&2
        printf '    OPENWRT_DIR=/path/to/openwrt  %s ...\n\n' "$0" >&2
        exit 2
    fi
fi

# port_kernel_dir -- echo the kernel build directory inside the tree.
#
# Globs rather than naming linux-6.12.94, because that version is OpenWrt's
# choice, not this port's. Picks the most recently modified match and says which,
# so a stale leftover directory is visible rather than silently used.
port_kernel_dir () {
    _found=$(ls -dt "$OPENWRT_DIR"/build_dir/target-*/linux-rockchip_armv8/linux-* 2>/dev/null \
             | while read -r d; do
                 [ -d "$d/arch/arm64/boot/dts/rockchip" ] && printf '%s\n' "$d"
             done)
    _count=$(printf '%s' "$_found" | grep -c . || true)
    if [ "$_count" -eq 0 ]; then
        printf 'no kernel build directory under %s/build_dir -- build first\n' "$OPENWRT_DIR" >&2
        return 1
    fi
    if [ "$_count" -gt 1 ]; then
        printf 'note: %s kernel build directories present, using the newest:\n' "$_count" >&2
        printf '%s\n' "$_found" | sed 's/^/    /' >&2
    fi
    printf '%s\n' "$_found" | head -1
}

# port_uboot_dir -- echo the U-Boot build directory for this board's variant.
# Same reasoning: u-boot-2025.10 is a version, not a location.
port_uboot_dir () {
    _found=$(ls -dt "$OPENWRT_DIR"/build_dir/target-*/u-boot-rock-4b-plus-rk3399/u-boot-* 2>/dev/null)
    _count=$(printf '%s' "$_found" | grep -c . || true)
    if [ "$_count" -eq 0 ]; then
        printf 'no u-boot build directory under %s/build_dir -- build first\n' "$OPENWRT_DIR" >&2
        return 1
    fi
    if [ "$_count" -gt 1 ]; then
        printf 'note: %s u-boot build directories present, using the newest:\n' "$_count" >&2
        printf '%s\n' "$_found" | sed 's/^/    /' >&2
    fi
    printf '%s\n' "$_found" | head -1
}
