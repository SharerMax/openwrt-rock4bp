#!/usr/bin/env python3
"""Extract the Synaptics EULA stanza from RPi's firmware-nonfree debian/copyright.

RPi's repo licenses the 43456 blobs separately from the rest of linux-firmware:
    Files: debian/added-firmware/*/*43456*
    Copyright: Synaptics
    License: Synaptics
So the Broadcom SLA that covers "brcm/brcmfmac*.bin" is NOT the licence that
governs brcmfmac43456-sdio.bin, and shipping the Broadcom text alongside the
Synaptics-licensed blob is wrong.
"""
import hashlib
import pathlib
import re
import sys

CP = pathlib.Path("/tmp/fw/rpi-copyright")
OUT = pathlib.Path("/tmp/fw/synaptics-eula.txt")

lines = CP.read_text(encoding="utf-8", errors="replace").split("\n")

# 1. the stanza that names the 43456 files, for the header to report
start = next((i for i, l in enumerate(lines) if re.match(r"^Files:.*\*43456\*", l)), None)
if start is None:
    sys.exit("stanza for *43456* not found")

# 2. locate the licence body by its banner. Do NOT stop at the first
#    "Copyright:"/"License:" line after the Files: line -- those are the
#    stanza's own header fields, and the full text is a separate stanza that
#    simply reuses the same licence name.
BANNER = "### SYNAPTICS WIRELESS CONNECTIVITY DEVICES"
banner = next((i for i, l in enumerate(lines) if l.startswith(" " + BANNER)), None)
if banner is None:
    sys.exit("EULA banner not found")

# the licence name for that body is the nearest preceding "License:" line
name = next((lines[i] for i in range(banner - 1, -1, -1)
             if lines[i].startswith("License:")), "(unknown)")

# 3. the body runs to the next top-level field
FIELD = re.compile(r"^(License|Files|File|Source|Copyright):")
end = len(lines)
for i in range(banner + 1, len(lines)):
    if FIELD.match(lines[i]):
        end = i
        break

text = "\n".join(lines[banner:end]).rstrip() + "\n"
OUT.write_text(text, encoding="utf-8")
b = text.encode()

print(f"stanza header : {lines[start]}")
print(f"              {lines[start + 1] if start + 1 < len(lines) else ''}")
print(f"licence name  : {name}")
print(f"extracted     : {len(b)} bytes, {text.count(chr(10))} lines, from line {banner + 1}")
print(f"sha256        : {hashlib.sha256(b).hexdigest()}")
print()
print("=== the grant ===")
for l in text.split("\n"):
    if "reproduce and distribute" in l or "object code form only" in l or "solely for use" in l:
        print(f"  {l.strip()}")
print()
print("=== obligations we must honour ===")
for l in text.split("\n"):
    if any(k in l for k in ("export control", "modify, adapt", "derivative works")):
        print(f"  {l.strip()}")
