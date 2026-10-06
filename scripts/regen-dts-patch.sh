#!/bin/sh
# Regenerate the kernel + U-Boot device-tree patches from the local overlay DTS
# and sanity-check the result with dtc. Run from the OpenWrt tree root.
set -e

TOP=/home/max/Code/openwrt
K="$TOP/build_dir/target-aarch64_generic_musl/linux-rockchip_armv8/linux-6.12.94"
D="$K/arch/arm64/boot/dts/rockchip"
DTS=/tmp/rk3399-rock-4b-plus.dts
KERNEL_PATCH="$TOP/target/linux/rockchip/patches-6.12/0001-arm64-dts-rockchip-add-Radxa-ROCK-4B-plus.patch"
UBOOT_PATCH="$TOP/package/boot/uboot-rockchip/patches/0100-arm64-dts-rockchip-add-Radxa-ROCK-4B-plus.patch"

echo "=== 1. dtc validation (file must sit in dts/rockchip so #include resolves) ==="
cd "$K"
cp "$DTS" "$D/rk3399-rock-4b-plus.dts"
cpp -nostdinc -I include -I arch/arm64/boot/dts -undef -D__DTS__ -x assembler-with-cpp \
    "$D/rk3399-rock-4b-plus.dts" 2>/tmp/cpp.err \
  | ./scripts/dtc/dtc -I dts -O dtb -o /tmp/v5.dtb - 2>&1 | grep -E "^Error|FATAL" || true
echo "cpp errors: $(wc -l < /tmp/cpp.err)"

./scripts/dtc/dtc -I dtb -O dts /tmp/v5.dtb 2>/dev/null > /tmp/rt5.dts
printf 'gpio-keys nodes : %s (expect 0)\n' "$(grep -c gpio-keys /tmp/rt5.dts || true)"
printf 'Recovery label  : %s (expect 0)\n' "$(grep -c Recovery /tmp/rt5.dts || true)"
printf 'sdio0           : %s\n' "$(grep -A30 'mmc@fe310000 {' /tmp/rt5.dts | grep -m1 status | tr -d '\t')"
printf 'uart0           : %s\n' "$(grep -A30 'serial@ff180000 {' /tmp/rt5.dts | grep -m1 status | tr -d '\t')"
printf 'brcmf child     : %s\n' "$(grep -c brcm,bcm4329-fmac /tmp/rt5.dts)"
printf 'bluetooth child : %s\n' "$(grep -c brcm,bcm4345c5 /tmp/rt5.dts)"
printf 'hp-det-gpio     : %s\n' "$(grep -c hp-det-gpio /tmp/rt5.dts)"
printf 'dtb size        : %s bytes\n' "$(stat -c%s /tmp/v5.dtb)"
rm -f "$D/rk3399-rock-4b-plus.dts"

echo
echo "=== 2. regenerate kernel patch (git diff -U1 against pristine dts/rockchip) ==="
# The kernel tree still carries the previously applied patch, so strip our own
# line from the Makefile first. Otherwise the diff adds it a second time and
# the build breaks with a duplicate dtb target.
python3 - "$D/Makefile" <<'PY'
import io, sys
p = sys.argv[1]
t = io.open(p, encoding="utf-8", newline="").read()
nl = "\r\n" if "\r\n" in t else "\n"
line = "dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3399-rock-4b-plus.dtb" + nl
if line in t:
    io.open(p, "w", encoding="utf-8", newline="").write(t.replace(line, ""))
    print("stripped stale dtb line from kernel Makefile")
else:
    print("kernel Makefile already pristine")
PY

rm -rf /tmp/kp4
mkdir -p /tmp/kp4/arch/arm64/boot/dts/rockchip
cp "$D/Makefile" /tmp/kp4/arch/arm64/boot/dts/rockchip/Makefile
cd /tmp/kp4
git init -q .
git add -A
git -c user.email=p@x -c user.name=port commit -qm pristine
cp "$DTS" arch/arm64/boot/dts/rockchip/
python3 - <<'PY'
import io
p = "arch/arm64/boot/dts/rockchip/Makefile"
t = io.open(p, encoding="utf-8", newline="").read()
nl = "\r\n" if "\r\n" in t else "\n"
anchor = "dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3399-rock-4c-plus.dtb"
assert t.count(anchor) == 1, "anchor line not found exactly once"
assert "rk3399-rock-4b-plus.dtb" not in t, "stale dtb line survived the strip"
add = anchor + nl + "dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3399-rock-4b-plus.dtb"
io.open(p, "w", encoding="utf-8", newline="").write(t.replace(anchor, add))
PY
git add -A
git diff --cached -U1 --stat
echo "--- Makefile hunk (must add the line exactly once) ---"
git diff --cached -U1 -- arch/arm64/boot/dts/rockchip/Makefile
git diff --cached -U1 > "$KERNEL_PATCH"

echo
echo "=== 3. regenerate U-Boot DTS patch ==="
{
  echo "From: OpenWrt ROCK 4B+ port"
  echo "Subject: [PATCH] arm64: dts: rockchip: add Radxa ROCK 4B+"
  echo
  diff -u /dev/null "$DTS" \
    | sed -e '1s|.*|--- /dev/null|' \
          -e '2s|.*|+++ b/dts/upstream/src/arm64/rockchip/rk3399-rock-4b-plus.dts|'
} > "$UBOOT_PATCH"

echo "kernel patch: $(wc -l < "$KERNEL_PATCH") lines"
echo "uboot  patch: $(wc -l < "$UBOOT_PATCH") lines"
