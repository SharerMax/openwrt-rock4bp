# AP6256 / BCM43456 WiFi bring-up — investigation record

Board: **Radxa ROCK (Pi) 4B+**, early revision (V1.6/V1.72: 4 MB SPI flash populated,
32 GB onboard eMMC), RK3399-T (OP1) + RK808.

Status as of the last boot: **the hardware layer works, the chip will not run its
firmware.** This file records what has been established, what has been ruled out,
and how to continue.

---

## 0. The finding that reframes everything below

On 2026-10-06 the machine that had been running Armbian became reachable, and it
answers the question §8 used to call the decisive one. **WiFi works under Armbian
on this board.** Not on a similar board, and not with a different driver — on this
one, with `brcmfmac`.

```c
/* Armbian, 26.11.0-trunk.62, kernel 6.18.54-current-rockchip64 */
brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43456-sdio for chip BCM4345/9
brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4345/9 wl0: Jun 16 2017 12:38:26
                                   version 7.45.96.2 (66c4e21@sh-git) (r)
$ ip -br link
wlan0    UP    08:fb:ea:65:f8:da
```

So the hardware is not faulty, the module is not dead, and this is not a
chip-support gap. Everything in this port is right except the kernel.

### The board is the same board

Not inferred from the model string — Armbian's DTB reports `radxa,rockpi4b`, ours
reports `radxa,rock-4b-plus`, so the model string alone proves nothing. The
hardware identifiers match instead:

| | Armbian box | Our board |
|---|---|---|
| eMMC | `SLD32G 28.9 GiB`, HS400 Enhanced strobe | `SLD32G 28.9 GiB`, HS400 Enhanced strobe |
| eMMC boot | `mmcblk0boot0 4.00 MiB` | `mmcblk0boot0 4.00 MiB` |
| SPI flash | `/dev/mtd0` present | `SF: Detected XT25F32B ... total 4 MiB` |

Same eMMC part, same capacity, same boot-partition geometry, and both have the 4 MB
SPI flash that only the early revision carries.

### The firmware is the same firmware

This is the part that invalidates the test matrix. Every file Armbian loads is
byte-identical to our combo 1:

| File | sha256 | Size | Our combo 1 |
|---|---|---|---|
| `brcmfmac43456-sdio.bin` | `3167956a7b2cffc4…` | 482927 | identical |
| `brcmfmac43456-sdio.txt` | `66c71eb53b47c49d…` | 2099 | identical |
| `brcmfmac43456-sdio.clm_blob` | `2dbd7d22fc9af0eb…` | 7163 | identical |

Armbian also ships `brcmfmac43456-sdio.radxa,rockpi4b.{bin,txt}` as symlinks to
those same files, so it is not resolving a board-specific variant either.

**Combo 1 is the configuration that works on this hardware, and combo 1 fails on
this port.** Combos 2–6 were therefore testing the wrong variable. That the RPi
NVRAM gets *further* (see the comparison below) is a difference in how the failure
looks, not progress toward working: Armbian uses the AP6256 NVRAM and works.

A version note, because two numbers here look contradictory and are not: the
firmware blob's own embedded string is `Version: 7.45.96.0`, while the running chip
reports `version 7.45.96.2` to the driver over DCMDS. Those are two different
things — the build tag in the image, and the version the chip answers with.

### The device tree is the same device tree

Compared node by node, decompiling our shipped dtb and Armbian's live
`/proc/device-tree` with `dtc`. `mmc@fe310000` and its `wifi@1` child agree on
every property: `bus-width`, `clock-frequency` (0x2faf080), `max-frequency`
(0x8f0d180), `cap-sdio-irq`, `cap-sd-highspeed`, `sd-uhs-sdr104`,
`keep-power-in-suspend`, `fifo-depth`, `clocks`, `resets`, `pinctrl-0`,
`interrupt-names = "host-wake"`, `compatible = "brcm,bcm4329-fmac"`.

The `mmc-pwrseq` node matches too: both `mmc-pwrseq-simple` with
`reset-gpios = <0x2a 0x0a 0x01>` and no `post-reset-delay-ms`.

### The driver is nearly the same driver

| | Kernel | brcmfmac source |
|---|---|---|
| Ours | 6.12.94 | `openwrt/backports` **6.18.26** |
| Armbian | 6.18.54-current-rockchip64 | mainline |

Close enough that the driver is an unlikely culprit on its own, which leaves the
kernel core, the kernel config, and anything else in the tree.

### Ruled out along the way

* **OpenWrt's Raspberry Pi brcmfmac patch series.** OpenWrt applies eight RPi
  patches to every brcmfmac build (`package/kernel/mac80211/patches/brcm/`).
  **No patch touches `htclk`, `CHIPCLKCSR`, `ALP`, `alp_only`, `clkctl`,
  `sdio_probe`, or `download_firmware`** — the failing path. The two that do touch
  `sdio.c` are innocuous: one adds support for a different chip (BCM43341), the
  other makes 43456 a CLM-blob entry, which this port needs since it ships one.
* **`870-02 Prefer a ccode from OTP over nvram file`** rewrites `ccode=` to
  `#ccode=` *in the loaded NVRAM buffer*, in place, before handing it to the chip.
  That would be a genuinely dangerous thing to find — but none of the three NVRAM
  files contain `ccode=`, so the mutation never triggers.
* **`brcmfmac: F1 signature read`**, which Armbian logs and we never do, is a
  `pr_debug`. Armbian simply runs with `debug` enabled. Not a behavioural
  difference.

### What this leaves

The failure is in the OpenWrt kernel, and it is not yet localised. The remaining
candidates, in the order worth testing:

1. **The 6.12 vs 6.18 delta in the MMC/SDIO core.** Our brcmfmac is backported but
   `drivers/mmc` is 6.12. The SDIO card enumerates at SDR104 on both, so the bus
   works; what may differ is the sequencing around function-1 register access.
2. **Kernel config.** Untested, and cheap to compare against Armbian's
   `/boot/config-*`.
3. **Reset-to-probe timing.** The chip uploads firmware and then never asserts
   HT_AVAIL. A longer `post-reset-delay-ms` on the `mmc-pwrseq` node is a one-line
   DTS change that directly targets the symptom, and neither DT sets the property
   today.

Items 2 and 3 are both cheap enough to do before anything more elaborate.

---

## 1. What the module is

| Property | Value | Source |
|---|---|---|
| Module | AP6256 | Radxa product brief |
| Chip | Broadcom **BCM43456** (SDIO chip ID `0x4345`, chiprev bit `0x200` set) | driver log + `brcmfmac/sdio.c` |
| Bluetooth | BCM4345C5, on `uart0` | inherited from `rk3399-rock-pi-4.dtsi` |
| Bus | `sdio0` = `mmc@fe310000`, function `mmc2:0001:1` | dmesg |
| Reset | `gpio0_B2` (global 10), via `sdio_pwrseq` | inherited |
| Host-wake | `gpio0_A3` | inherited |

The kernel picks the firmware name from the chip ID:

```c
/* mac80211 backports, brcmfmac/sdio.c */
BRCMF_FW_ENTRY(BRCM_CC_4345_CHIP_ID, 0x00000200, 43456),
BRCMF_FW_ENTRY(BRCM_CC_4345_CHIP_ID, 0xFFFFFDC0, 43455),
```

chipid `0x4345` with chiprev bit `0x200` set → **43456**. Detection is correct.

## 2. What works (verified on hardware)

```
[    0.312888] dwmmc_rockchip fe310000.mmc: allocated mmc-pwrseq
[    0.807705] dwmmc_rockchip fe310000.mmc: Successfully tuned phase to 223
[    0.823768] mmc2: new ultra high speed SDR104 SDIO card at address 0001
[   16.755761] brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43456-sdio for chip BCM4345/9
 gpio-10  (|reset) out hi ACTIVE LOW
```

* `sdio0` is enabled and `mmc-pwrseq` runs — this needed the `&sdio0 { status = "okay" }`
  override, see the DTS section in the main README.
* The chip enumerates as an SDR104 SDIO card at 148.5 MHz. **Function 0 works.**
* The reset line is released.
* Bluetooth: `ff180000.serial: ttyS0 at MMIO 0xff180000` — uart0 enabled.

## 3. Where it fails

The firmware is **uploaded to the chip successfully**. The chip then never starts
running it:

```c
/* brcmfmac/sdio.c, brcmf_sdio_probe() */
bus->alp_only = true;
err = brcmf_sdio_download_firmware(bus, code, nvram, nvram_len);
if (err)
        goto fail;                      /* NOT taken -- upload succeeded */
bus->alp_only = false;
...
brcmf_sdio_clkctl(bus, CLK_AVAIL, false);
if (bus->clkstate != CLK_AVAIL)
        goto release;                   /* taken -- this is where it stops */
```

`brcmf_sdio_htclk()` writes `SBSDIO_HT_AVAIL_REQ` to `SBSDIO_FUNC1_CHIPCLKCSR`
and waits one second for the chip to set the available bit. Only the **running
firmware** can do that. It never does:

```
[   17.858182] brcmfmac: brcmf_sdio_htclk: HT Avail timeout (1000000): clkctl 0x50
[   18.867671] brcmfmac: brcmf_sdio_htclk: HT Avail timeout (1000000): clkctl 0x50
```

In a **warm** state (module reloaded rather than power-cycled) the failure moves
later, which is useful diagnostic information:

```
[  1237.597242] brcmfmac: brcmf_sdio_bus_rxctl: resumed on timeout
[  1237.597800] ieee80211 phy0: brcmf_bus_started: failed: -110
[  1237.598334] ieee80211 phy0: brcmf_attach: dongle is not responding: err=-110
[  1237.661624] brcmfmac: brcmf_sdio_firmware_callback: brcmf_attach failed
```

`phy0` registers, so the wiphy is created — then function-1 register access times
out. `-110` is `ETIMEDOUT`.

## 4. Test matrix

Every row needs its own **cold boot**. See the methodology traps in §6.

| # | firmware | NVRAM | boot | result |
|---|---|---|---|---|
| 1 | 7.45.96.0 | AP6256 | cold | `HT Avail timeout` |
| 2 | 7.84.17.1 | RPi | warm | `phy0` registered, then `attach -110` |
| 2 | 7.84.17.1 | RPi | **cold, 2026-10-06** | `phy0` registered, then `attach -110` |
| 2 | 7.84.17.1 | RPi | **cold, 2026-10-06, from the shipped image** | `phy0` registered, then `attach -110` |
| 3 | 7.84.17.1 | AP6256 | cold | `HT Avail timeout` |
| 3 | 7.84.17.1 | AP6256 | **cold, 2026-10-06** | `HT Avail timeout` — reproduced |
| 4 | 7.45.96.0 | RPi | — | **never actually tested**, see §6 |
| 5 | 7.84.17.1 | RPi 43455 | — | not tested, low value |
| 6 | 7.45.69.0 (43455 fw) | AP6256 | — | not tested, low value |

Both NVRAMs now have **two cold samples each, all consistent**, and the operator
confirmed power was removed for every one. Two is still thin given the PineBook Pro
owner's "80% of the time" report, so §8 keeps a repeat on the list.

The second combo-2 sample was run from the **shipped image** rather than from
manually staged files. That matters beyond the extra data point: until then every
result in this table depended on somebody having copied blobs onto a running
board, and none of it was reproducible from a build artefact. Now the image itself
produces the behaviour, verified by the firmware hashes matching the package and
`wifi-test.sh check` identifying combo 2 from them.

### The one controlled comparison in this investigation

Combos 2 and 3 differ by **exactly one file** — the NVRAM — and both have now been
booted cold, twice each:

```
combo 3, AP6256 NVRAM:            combo 2, RPi NVRAM:
  brcmf_fw_alloc_request ...        brcmf_fw_alloc_request ...
  HT Avail timeout  (clkctl 0x50)   brcmf_sdio_bus_rxctl: resumed on timeout
  HT Avail timeout  (clkctl 0x50)   ieee80211 phy0: brcmf_bus_started: failed: -110
                                    ieee80211 phy0: brcmf_attach: -110
```

Same firmware blob, same clm_blob, same board, both power-cycled. The failure point
**moves**, so the NVRAM contents are a real input to how far the chip gets.

This also settles a question that had been open since §6: combo 2's warm result was
not an artefact of the warm state. Cold reproduces it exactly. The "warm and cold
are incomparable" caution was correct as a rule, and applying it here shows the warm
result was genuine.

### What the NVRAM difference actually is

Full diff of the two files. Grouped by what the key plausibly controls:

| Group | AP6256 (chip never starts) | RPi (chip starts, then stalls) |
|---|---|---|
| **Bluetooth coexistence** | **absent entirely** | `btc_mode=1`, `btc_params1=0x7530`, `btc_params8=0x4e20`, commented *"Improved Bluetooth coexistence parameters from Cypress"* |
| `boardflags3` | `0x48200100` | `0x44200100` (differ by `0x0C000000`, bits 26–27) |
| `swctrlmap_2g` / `_5g` | non-zero entries | mostly zero; last field `0x3ff`/`0x3fe` vs `0x1ff`/`0x2f4` |
| `tworangetssi2g` / `5g` | `0` | `1` |
| PA calibration | `-164,5427…` / `-127,5380…` | `-170,5896…` / `-150,5547…` |
| `pdoffset40ma0` / `80ma0` | `0xaaaa` ("don't care") | `0x8888` |
| `macaddr` | `00:90:4c:c5:12:38` | `b8:27:eb:74:f2:6c` |
| present only in AP6256 | `muxenab=0x10`, `pacalshift5g=0,0,3`, `cckbw202gpo`, `cckdigfilttype=5` | — |
| present only in RPi | — | `ldo1=4`, `rawtempsense=0x1ff`, `cckPwrIdxCorr`, `fdsslevel_ch11=6` |
| identical | `boardtype=0x6e4`, `boardrev=0x1304`, `xtalfreq=37400`, `boardflags=0x00480201`, `rxchain/txchain=1`, `itrsw=1`, `femctrl=0`, `AvVmid_c0` | same |

The board-identifying values are the same in both, so this is not a case of one file
describing a different board. The standout is the **Bluetooth coexistence block**:
the AP6256 file has no `btc_mode` and no `btc_params*` at all, while RPi's carries
parameters explicitly attributed to Cypress — the AP6256's own vendor. This module
also carries a BCM4345C5 Bluetooth die on `uart0`, and the DTS enables that node, so
the chip's firmware is being asked to bring up BT and WLAN together with no
coexistence configuration to do it with.

That is a hypothesis, not a finding. It is the most interesting thing in the table
and it is testable, but "absent coexistence parameters" is an inference from reading
the file, not something the logs show.

Also worth noting: RPi's NVRAM describes a Raspberry Pi's RF layout, so it gets the
chip *started* on a board it was not written for. That is consistent with the second
failure — the chip runs, then function-1 register access times out — and it means
neither existing file is simply correct for this board. A working configuration
probably has to be synthesised rather than found.

### The board's software environment

Collected from the running board, because it constrains what the test scripts may
assume:

| Fact | Value | Consequence |
|---|---|---|
| kernel | 6.12.94, image built 2026-06-29 | the board was still on the pre-licence-fix image (`LICENSE.Broadcom`, not `LICENSE.Synaptics`) |
| `wget` | `/usr/bin/wget`, full GNU | the test script can fetch candidates over the network |
| `stat` | **absent** | `stat -c%s` fails; use `wc -c < file` |
| `dmesg -C` | **unsupported** — busybox has no `-C` | see §6 trap 1, now confirmed rather than assumed |
| dmesg per boot | 422 lines, all from that boot | a cold boot's buffer needs no clearing |
| dropbear | no `/usr/libexec/sftp-server` | `scp` needs `-O` |

The driver's first firmware request is board-qualified and always misses:

```
brcmfmac mmc2:0001:1: Direct firmware load for brcm/brcmfmac43456-sdio.radxa,rock-4b-plus.bin failed with error -2
brcmfmac mmc2:0001:1: Falling back to sysfs fallback for: brcm/brcmfmac43456-sdio.bin
```

That is normal brcmfmac behaviour, not a missing-file problem — the fallback
succeeds and the firmware is uploaded.

Firmware blobs:

| Name | Size | sha256 | Self-reported version |
|---|---|---|---|
| Armbian / `brcm/brcmfmac43456-sdio.bin` | 482927 | `3167956a7b2cffc4cfcaf6a282b95728c529eebef18a5d9e6d9ff32de32cc67c` | 7.45.96.0 |
| Debian/RPi `brcmfmac43456-sdio.bin` | 495898 | `ddf83f2100885b166be52d21c8966db164fdd4e1d816aca2acc67ee9cc28d726` | 7.84.17.1 |
| `brcmfmac43455-sdio.bin` | 483181 | `5ecb7355e530fb06ebdc9991ceb6a697e0132499bdcac3e4fda55f5039a79a6a` | 7.45.69.0 |

All three self-identify with the build tag `43455c5-roml/43455_sdio`. That tag is
**not** a way to tell them apart — Broadcom's build system uses it for the 43456
parts too. The internal version string is the discriminator.

NVRAM files:

| Name | Size | sha256 | Notes |
|---|---|---|---|
| Armbian `brcmfmac43456-sdio.txt` | 2099 | `66c71eb53b47c49d42386b66735134578640b0946f3f46e44f384fef5aacfd9e` | header `#AP6256_NVRAM_V1.1_08252017`, `boardtype=0x6e4` |
| RPi `brcmfmac43456-sdio.txt` | 2053 | `44e0bb322dc1f39a4b0a89f30ffdd28bc93f7d7aaf534d06d229fe56f6198194` | same value Debian records for this file |
| RPi `brcmfmac43455-sdio.txt` | 2074 | `ca709be81a78bdb6932936374f39943acbd7af07fae6151011127599a3ce9e3d` | identical to the 43456 NVRAM except for PA calibration and `btc_params50`; combo 5 |

The three NVRAMs agree on every functional key — `boardtype=0x6e4`,
`boardrev=0x1304`, `xtalfreq`, `boardflags`. Only the RF calibration differs
(`AvVmid_c0`, `pa2ga*`, `pa5ga*`). That is a reason for low optimism about combo 5:
it is the same board configuration with different amplifier calibration, not a
different board profile.

The `clm_blob` is identical across sources (`2dbd7d22fc9af0eb…`, 7163 bytes) and is
optional anyway (`BRCMF_FW_REQF_OPTIONAL`; missing only limits the channel list).

Note: linux-firmware also ships `brcmfmac43455-sdio.Radxa-ROCK Pi X.txt`, but that
is NVRAM for an **AP6254 / BCM43454** on a different board. Its `macaddr`,
`xtalfreq` and PA calibration values are board-specific and must not be reused
here.

## 5. Source and licence of the vendored blob

`brcmfmac43456-sdio.bin` is proprietary. It is absent from linux-firmware (checked
20251125 and 20260221) and OpenWrt 25.12.5 has no `Package/brcmfmac-*` variant for
it, so the port has to carry it. Sources considered:

| Source | Verdict |
|---|---|
| Debian `firmware-nonfree` tarball | 105 MB for one 495 KB file, and the 20210315 revision no longer contains it |
| `armbian/firmware` | has it, but its README says "Redistribution is limited to non-commercial or usage-only contexts" — the source forbids what we need |
| `RPi-Distro/firmware-nonfree` | **used** — a Debian source package for the non-free blobs, so the licence travels with the files |

An earlier revision of this port vendored from `armbian/firmware` and shipped the
Broadcom SLA. Both were wrong: the source prohibits redistribution, and the licence
was not the one that applies.

### The licence is Synaptics, not Broadcom

RPi's `debian/copyright` licenses these files separately from the rest of
linux-firmware:

```
Files: debian/added-firmware/*/*43456*
Copyright: Synaptics
License: Synaptics
```

The Broadcom SLA covers `brcm/brcmfmac*.bin` in linux-firmware *generally*. The
43456 blobs are **not** covered by it, which is why attaching the Broadcom text to
them was wrong.

**Synaptics DRIVER END USER LICENSE AGREEMENT (BINARY DISTRIBUTION)** — grant:

> grants you a non-exclusive, non-transferable license … to reproduce and
> distribute the Software **in object code form only**, solely for use in
> connection with Synaptics integrated circuit products

Three conditions follow, all met:

| Condition | Requirement | How it is met |
|---|---|---|
| object code form only | not repackaged or transformed | installed byte-for-byte, `Build/Verify` asserts sha256 |
| no derivative works | "you may not (i) modify, adapt, or create derivative works" | hence the hash check; the blob is never patched |
| solely for Synaptics ICs | used only with a BCM43456 | the sole consumer is `brcmfmac` driving this board's chip |

The agreement also imposes an obligation on whoever redistributes the image that is
worth knowing before publishing a build:

> Without limiting the foregoing, the Software may be subject to export control
> laws and regulations of the United States and other countries

The full text ships in `/usr/share/licenses/broadcom/LICENSE.Synaptics`
(7218 bytes, sha256 `bb50f9742753dc3befc72e8000efaa05f6f98a7c633129f7a7e0202ce1e487e0`,
extracted by `scripts/extract-synaptics-license.py`).

To avoid redistributing it entirely: drop the package from `DEVICE_PACKAGES` in
`overlay/target/linux/rockchip/image/armv8.mk` and copy the three files onto the
running system yourself. `kmod-brcmfmac` stays in the device package set and picks
them up from `/lib/firmware/brcm/` unchanged.

### Provenance check

The openSUSE personal mirror used during testing turned out to serve RPi's bytes
verbatim — sha256 identical for the `.bin`, `.txt` and `.clm_blob`. That is what
confirms the mirror was trustworthy rather than its filename.

Pinned upstream ref: branch `trixie`, commit `3bab0f823f5b53150b76aab77093adef6655b920`.

## 6. Methodology traps hit while testing

These cost more time than the actual testing, and each one silently produces
**plausible but wrong** results:

1. **`dmesg -C` does not clear the ring buffer on this build.** Confirmed on the
   board: busybox's `dmesg` has no `-C` option at all (`unrecognized option: C`),
   and the buffer still held all 422 lines afterwards. A reload-based test then
   prints stale lines in a fresh-looking format. An automated script that reads
   that output will report a result that never happened. Worse than no output,
   because it looks like data.
2. **`rmmod` + `modprobe` does not re-probe** after a failed attach. The chip is
   left half-alive and no new dmesg lines appear at all, so the script appears to
   run but nothing is tested.
3. **`reboot` does not reset the WiFi peripheral.** It resets the SoC. A PineBook
   Pro owner with the same module reports the same thing: *"It remains inaccessible
   with a reboot ... Only a complete shutdown followed by a new boot gives me a 80%
   chance."* Only `poweroff` + unplug + wait + power on is a real reset.
4. **Comparing a warm result against a cold result is invalid.** Combo 2's
   encouraging `phy0` result was warm; combo 3's `HT Avail timeout` was cold. They
   are not comparable, which is why "the firmware version matters" could not be
   concluded from them.

`scripts/wifi-test.sh` encodes all four: it never tries to clear dmesg, it splits
staging and checking across a real power cycle, and it prints an explicit verdict
rather than leaving the judgement to log-reading.

It also **identifies the installed combination by hashing the two files** rather
than trusting the operator to remember which one was staged. That is deliberate:
all three wrong conclusions above were mislabelled inputs, not wrong readings of
the log. An unrecognised pair of hashes is reported as `UNKNOWN` and explicitly
not attributed to any combo.

One limit worth stating: the script **cannot tell you whether the boot was cold**.
Nothing inside the running system records whether power was removed, and since
`dmesg -C` does not work and `rmmod`/`modprobe` does not re-probe, a warm state
leaves no distinguishing trace. That has to come from the operator.

## 7. Why this is probably not a defect in the port

* The same failure is reported on other AP6256 boards with brcmfmac — Orange Pi 5
  Pro (`brcmf_attach: dongle is not responding: err=-52`, unstable, fixed by
  switching to Broadcom's proprietary `bcmdhd-sdio`) and PineBook Pro. The same
  Orange Pi thread also notes brcmfmac *does* work on Rock Pi 4B and Radxa Zero 2,
  which use the same module.
* **Radxa's own device tree is effectively identical to ours** — checked against
  `radxa/kernel` branch `linux-7.0.11`,
  `arch/arm64/boot/dts/rockchip/rk3399-rock-pi-4b-plus.dts`. Only extra compatible
  string and the removed gpio-keys node differ.
* **Radxa's driver mapping is identical** — same `BRCMF_FW_ENTRY(..., 0x00000200, 43456)`.
* SDIO function 0 works perfectly, so the module is alive and the bus is healthy.

## 8. Open questions, in priority order

The Armbian comparison (§0) answered the old question 3 — WiFi does work on this
board, so this is a kernel problem, not hardware — and invalidated combos 2 through
6 as tests of the wrong variable. What remains:

1. **Diff the kernel config** against Armbian's `/boot/config-6.18.54-*`, focused on
   MMC, SDIO, CRDA and clock options. Cheapest thing left, and it has never been
   done.
2. **Try a longer `post-reset-delay-ms`** on the `mmc-pwrseq-simple` node. The
   chip accepts firmware and then never asserts HT_AVAIL, which is what a chip that
   is not ready yet looks like. Neither DT sets this property today, so it is a
   genuinely untried value rather than a change to a tuned one. One line of DTS.
3. **Look at the 6.12 → 6.18 delta in `drivers/mmc`** — the SDIO core, not brcmfmac.
   Function-1 register access is where the attach times out.
4. Only if 1–3 fail: bisect by booting a newer kernel base, which is a large change
   to an otherwise working port and should not be attempted while cheaper options
   remain.

**Do not resume the firmware/NVRAM matrix.** Combo 1 is byte-for-byte the
configuration that works on this hardware and it fails here, so combinations of
those same files cannot produce a working result. The NVRAM difference in §4 is a
real observation about how far the chip gets, but both paths end in failure, and
the one that gets further is not closer to working.

Combos 4 and 6 remain untested and are now pointless: 4 pairs the 7.45.96.0
firmware with the RPi NVRAM, and 6 pairs the 43455 firmware with the AP6256 NVRAM.
Both draw from the same exhausted set.

## 9. How to continue

```sh
# on the board, from the serial console, in /lib/firmware/brcm
sh wifi-test.sh list          # combos and what has already been recorded
sh wifi-test.sh stage 6       # install a combination and verify hashes
poweroff
# UNPLUG the supply, wait 10 s, power on
sh wifi-test.sh check         # explicit verdict
```

The script must be transferred to the board first, e.g.

```sh
scp wifi-test.sh root@<board>:/lib/firmware/brcm/
```
