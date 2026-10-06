#!/bin/bash
# Extract the BCM43456 blobs from Debian's firmware-nonfree tarball.
#
# tar has to decompress the whole 105 MB .xz stream even for a wildcard match,
# because xz is not seekable. Run detached; it takes a minute or so.
set -e
cd /tmp/fw43456

echo "=== extracting brcm/*43456* (full-stream decompress) ==="
rm -rf deb-brcm
mkdir -p deb-brcm
tar -xJf orig.tar.xz -C deb-brcm --wildcards '*/brcm/*43456*' || true

echo
echo "=== extracted ==="
find deb-brcm -type f | sort | while read -r f; do
  printf '%9d  %s  %s\n' "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -c1-16)" "$(basename "$f")"
done

A=brcmfmac43456-sdio.bin
D=$(find deb-brcm -type f -name 'brcmfmac43456-sdio.bin' | head -1)
echo
if [ -n "$D" ]; then
  echo "=== armbian candidate ==="
  printf '%9d  %s\n' "$(stat -c%s "$A")" "$(sha256sum "$A" | cut -d' ' -f1)"
  echo "=== debian candidate ==="
  printf '%9d  %s\n' "$(stat -c%s "$D")" "$(sha256sum "$D" | cut -d' ' -f1)"
  if cmp -s "$A" "$D"; then echo "RESULT: identical"; else echo "RESULT: different"; fi
  echo
  echo "=== debian blob internal version string ==="
  strings "$D" | grep -iE 'Version: [0-9]+\.' | head -3
  echo
  echo "=== debian NVRAM head ==="
  T=$(find deb-brcm -type f -name 'brcmfmac43456-sdio.txt' | head -1)
  [ -n "$T" ] && head -6 "$T"
else
  echo "ERROR: debian blob not found -- check the wildcard against the tarball layout"
  tar -tJf orig.tar.xz 2>/dev/null | grep 43456 | head -10 || true
fi
echo
echo "EXTRACT_DONE=1"
