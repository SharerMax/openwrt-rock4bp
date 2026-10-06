# AP6256 / BCM43456 WiFi bring-up — investigation record

Board: **Radxa ROCK (Pi) 4B+**, early revision (V1.6/V1.72: 4 MB SPI flash populated,
32 GB onboard eMMC), RK3399-T (OP1) + RK808.

Status: **WiFi works.** `wlan0` comes up, associates and scans — 16 networks across
both bands — on the shipped image. The fix was one property in the device tree; see
§0. What follows is the record of how it was found, because the path matters more
than the answer: the firmware matrix below was testing the wrong variable for
several rounds, and only an outside comparison ended it.

---

## 0. The finding that reframes everything below

Two things had to be true before this could be solved, and both are worth stating
because each one invalidated a large amount of prior work.

### WiFi works under Armbian, on this board

The decisive evidence, and the thing that had been asked repeatedly without an
answer:

```
$ ip -br link show wlan0
wlan0    UP    08:fb:ea:65:f8:da
$ readlink -f /sys/class/net/wlan0/device/driver
.../bus/sdio/drivers/brcmfmac
```

Same driver as this port — not Broadcom's proprietary `bcmdhd`, which is what other
AP6256 boards are reported to need. The MAC matches this port's `wlan0` byte for
byte once the port is fixed, so it is the same chip reading the same OTP.

### The firmware was never the problem

This is what made the matrix in §4 worthless. Armbian's firmware files are
**byte-identical to our combo 1**:

| File | sha256 | Size |
|---|---|---|
| `brcmfmac43456-sdio.bin` | `3167956a7b2cffc4…` | 482927 |
| `brcmfmac43456-sdio.txt` | `66c71eb53b47c49d…` | 2099 |
| `brcmfmac43456-sdio.clm_blob` | `2dbd7d22fc9af0eb…` | 7163 |

Armbian also symlinks `brcmfmac43456-sdio.radxa,rockpi4b.{bin,txt}` to those same
files, so it was not quietly using a board-specific variant either. **Combo 1 was
the configuration that works on this hardware, and combo 1 failed here.** Combos 2
through 6 were testing a variable that was never the cause.

That also reinterprets the NVRAM result in §4. The RPi NVRAM got *further* — past
the clock request, to `phy0` — which looked like progress. It was a different way
of failing. Armbian uses the AP6256 NVRAM and works.

### The actual cause: the WiFi power-sequence clock was never enabled

With the firmware eliminated, the device tree was compared property by property
against Armbian's live `/proc/device-tree`. `mmc@fe310000` and its `wifi@1` child
agree on everything. One property in the WiFi power path did not:

| `sdio-pwrseq` | ours (inherited Radxa) | Armbian |
|---|---|---|
| `compatible` | `mmc-pwrseq-simple` | same |
| `clocks` | rk808 index 1 | same |
| **`clock-names`** | **`"lpo"`** | **`"ext_clock"`** |
| `reset-gpios` | gpio0 pin 10, active low | same |

`rk3399-rock-pi-4.dtsi` calls that clock `"lpo"`. The MMC power-sequence driver
only ever looks up `"ext_clock"`:

```c
/* drivers/mmc/core/pwrseq_simple.c */
pwrseq->ext_clk = devm_clk_get(dev, "ext_clock");
if (IS_ERR(pwrseq->ext_clk) && PTR_ERR(pwrseq->ext_clk) != -ENOENT)
        return dev_err_probe(dev, PTR_ERR(pwrseq->ext_clk), "external clock not ready\n");
```

and guards every use with `!IS_ERR()`. So the lookup returns `-ENOENT`, that is
tolerated, the `ERR_PTR` stays in place, and **the clock is silently never
enabled** — no error, no warning, the power-on just proceeds without it.
`mmc-pwrseq-simple.yaml` agrees: `clock-names` is `const: ext_clock`, with
`additionalProperties: false`.

The clock is not decorative. `rk808` index 1 resolves to `clkout2`, the RK808
PMIC's **32.768 kHz output**, gated by `CLK32KOUT2_EN` in `RK808_CLK32OUT_REG`,
with real `prepare`/`unprepare` ops. Enabling it is what switches that output on,
and it happens between powering the card and releasing its reset. A BCM43456
released from reset without its 32 kHz reference will accept a firmware upload
over SDIO and then never bring its datapath up — which is precisely the observed
failure.

The fix, one line:

```dts
&sdio_pwrseq {
	clock-names = "ext_clock";
};
```

### Result

On the image carrying it, cold-booted:

```
[   15.154423] brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4345/9 wl0: May 14 2020
                               17:26:08 version 7.84.17.1 (r871554) FWID 01-3d9e1d87
wlan0  UP  08:fb:ea:65:f8:da
$ iw dev wlan0 scan | grep -c '^BSS '
16
```

16 networks, both 2.4 GHz and 5 GHz. `preinit_dcmds` had never been reached before —
the chip now runs its firmware and answers the driver.

Verified independently of the build's own assertions, because a build had already
been caught lying once (§6, trap 5): the image sha256 changed, the dtb grew
63779 → 63787 bytes (exactly what `lpo` → `ext_clock` costs), and the dtb
extracted from the shipped image carries `clock-names = "ext_clock"` in its
`sdio-pwrseq` node. The running board reports the same from
`/sys/firmware/devicetree/base/sdio-pwrseq/clock-names`.

A version note, since two numbers here look contradictory and are not: the 7.45
firmware blob's embedded string is `Version: 7.45.96.0`, while the chip running it
reported `version 7.45.96.2` over DCMDS. Build tag and on-chip answer, different
things.

### Ruled out along the way

* **The kernel config.** Diffed against Armbian's, across MMC, SDIO, CRDA, wifi,
  clock and regulator symbols. The only differences are builtin-versus-module —
  `CONFIG_CFG80211` and `CONFIG_MAC80211` are absent from our kernel `.config`
  because OpenWrt ships them through the `kmod-brcmfmac` package — plus
  `CONFIG_CFG80211_CRDA_SUPPORT` and `CONFIG_CFG80211_WEXT`, which are
  regulatory-domain and wireless-extension features with no bearing on SDIO
  function-1 register access.

  A trap worth recording: OpenWrt's top-level `.config` has ~830 symbols and
  contains no `CONFIG_MMC` at all. It is the board-and-package config, not the
  kernel config. The kernel config is generated during the build at
  `build_dir/target-*/linux-rockchip_armv8/linux-6.12.94/.config`. Comparing
  against the top-level file compares nothing against everything.

* **OpenWrt's Raspberry Pi brcmfmac patch series.** Eight RPi patches are applied
  to every brcmfmac build. **None touches `htclk`, `CHIPCLKCSR`, `ALP`, `alp_only`,
  `clkctl`, `sdio_probe` or `download_firmware`** — the failing path. The two that
  do touch `sdio.c` are innocuous.
* **`870-02 Prefer a ccode from OTP over nvram file`** rewrites `ccode=` to
  `#ccode=` *in the loaded NVRAM buffer*, in place, before handing it to the chip.
  Worth finding; none of the three NVRAM files contain `ccode=`, so it never
  triggers.
* **`brcmfmac: F1 signature read`**, which Armbian logs and this port never did, is
  a `pr_debug`. Armbian runs with `debug` enabled. Not a behavioural difference.
* **Power sequencing, apart from the clock name.** Neither device tree gives
  `mmc@fe310000` a `*-supply`, so the SDIO rail is not regulator-managed on
  either, and both `mmc-pwrseq-simple` nodes carry the same reset GPIO and pin.
* **Hardware.** The module is not faulty. It works, on this board, with the same
  driver.

### Two methodology notes from writing the fix

* The delay property is **`post-power-on-delay-ms`**, not `post-reset-delay-ms`.
  The second would have compiled, applied cleanly, and done nothing. The binding
  is the authority — read it rather than guessing the name.
* **Comparing phandle *numbers* between two independently compiled DTBs proves
  nothing.** `clocks = <0x4a 0x01>` versus `<0x47 0x01>` was the same clock, and
  `pinctrl-0 = <0xcd>` matching on both sides was coincidence — dtc assigns those
  values in its own traversal order. References must be resolved to node paths
  first. A whole-tree normalised diff produced 4001 lines of noise for exactly this
  reason, so the conclusion rests on the targeted per-node comparison done with
  resolution.

### The delay, if it is ever needed

`post-power-on-delay-ms` on the `sdio-pwrseq` node was considered as a second
variable and deliberately **not** bundled in, so that a failure would point at one
cause. It turned out not to be needed.

### Aligning with Armbian, and where that stops

The obvious goal is for the port to ship byte-for-byte what Armbian ships, since
that configuration is known to work on this board. That is only possible for two
of the three files.

| File | Armbian ships | This port ships | Can they be aligned? |
|---|---|---|---|
| `brcmfmac43456-sdio.txt` | `66c71eb5…` 2099 B, AP6256 | `66c71eb5…` 2099 B | **aligned** |
| `brcmfmac43456-sdio.clm_blob` | `2dbd7d22…` 7163 B | identical | already aligned |
| `brcmfmac43456-sdio.bin` | `3167956a…` 482927 B, 7.45.96.0 | `ddf83f21…` 495898 B, 7.84.17.1 | **no** — see below |

**The firmware blob cannot be aligned, and the reason is licensing, not
function.** The 7.45.96.0 blob's only known source is `armbian/firmware`, whose
README states:

> Some firmware files are proprietary and distributed under their respective
> licenses. Redistribution is limited to non-commercial or usage-only contexts.

Shipping it would undo the correction made earlier in this port, where the blob
was moved to `RPi-Distro/firmware-nonfree` precisely because that repository carries
the Synaptics EULA for these exact files. `linux-firmware` does not have the blob at
all, and Debian's `firmware-nonfree` tarball no longer contains it, so there is no
redistributable source for 7.45.96.0 that has been found.

7.84.17.1 works, so there is no functional cost. The port ships a *newer* firmware
build than Armbian, from a source whose licence permits redistribution, with the
same NVRAM and the same clm_blob.

### Where the NVRAM came from, and a weaker argument than expected

The natural source to reach for was `radxa/firmware`, the board vendor's own
repository — the same provenance as the device tree this port inherits. It has
`nvram_ap6256.txt`, and it is **byte-identical** to what Armbian loads:

```
66c71eb53b47c49d42386b66735134578640b0946f3f46e44f384fef5aacfd9e  2099 B
```

`armbian/firmware` and Armbian ship the same bytes, so the file has one content and
several homes.

The argument for preferring it over RPi's file is weaker than it first looked.
RPi's describes a Raspberry Pi — different PA calibration, different `boardflags3`,
Bluetooth coexistence parameters credited to Cypress — which is the wrong board.
But the Radxa file's own header says:

```
#AP6256_NVRAM_V1.1_08252017
# Cloned from bcm94345wlpagb_p2xx.txt
```

It is a clone of a **Broadcom reference design**, not calibration read from this
module. So neither file is per-unit, and "PA calibration is board-specific" — which
would have been the strong argument — does not apply to either. The argument that
survives is weaker but sufficient: the vendor ships this one for this module, and it
is verified working.

Both files were verified on hardware with the clock fixed:

| NVRAM | Result |
|---|---|
| RPi `44e0bb32…` 2053 B | `wlan0` UP, 16 networks scanned |
| AP6256 `66c71eb5…` 2099 B | `wlan0` UP, 14 networks scanned |

Both bring up the interface, and in both cases `wlan0` reports MAC
`08:fb:ea:65:f8:da` — identical. So the `macaddr` line in the NVRAM never reaches
the interface: brcmfmac takes the MAC from the chip's OTP. That also explains why
the two files' different `macaddr` values never mattered.

The package now ships the AP6256 file, taken from `radxa/firmware`. One caveat
stated plainly: **that repository carries no licence statement at all.** For the
NVRAM that is a weaker position than the firmware blob's, where an explicit EULA
travels with the file. RPi's `debian/copyright` applies its Synaptics EULA to
`debian/added-firmware/*/*43456*` by glob, which covers `.txt` files as well as
`.bin` — so the community treats these text files as the same licensed material.
That is the best available reading, but it is an inference, not a permission.
Beyond those, the honest options are a kernel bisect or a newer kernel base, both
large changes to an otherwise working port. They should not be attempted while the
two cheap tests above are untried.

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

5. **A build can fail to start and the log will not say so.** A build launched with
   `setsid nohup` inside an `ssh` command died without an error, and the
   verification block then read `/tmp/build-full.log` from the *previous* run: nine
   `OK` lines and `REAL_EXIT_CODE=0`, for a build that never ran. It was read as a
   successful no-op rebuild. The image sha256 was unchanged and the change was
   absent from the dtb.

   The size-based assertion did not help: `dtb is the current 63779-byte build`
   passed, because a stale dtb has exactly the right size. A size cannot detect
   "nothing was rebuilt" and cannot detect a content change either.

   `scripts/build.sh` now dates its own log, reports the log's age and exit code
   at the end, asserts the dtb is **newer than the patch** that builds it, and
   asserts the decompiled dtb **contains** the property the port depends on. A
   reader finding a log should check its first line before trusting its verdicts.

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

## 8. What is left

Nothing blocking. WiFi works, and the shipped NVRAM now matches Armbian's.

1. **eMMC install.** Unrelated to WiFi, still pending. The `dd` procedure is
   checked in FLASHING.md §7.
2. HDMI and audio remain out of scope, as before.

The firmware/NVRAM matrix in §4 is kept as a record, not as a work list. Combo 1
was demonstrated to be byte-identical to what Armbian loads, and it failed only
because of the clock name; combos 2 through 6 tested a variable that was never the
cause. Combos 4 and 6 were never run and there is no reason to run them now.

Optional cleanup, not worth doing on its own: OpenWrt still applies the eight
Raspberry Pi brcmfmac patches to this driver. They were ruled out as the cause, and
removing them is unrelated work with its own risk.

## 9. The test harness

`scripts/wifi-test.sh` is retained. It is no longer a search tool, but three of its
properties earned their keep and are worth keeping:

* it **identifies the installed combination from the file hashes**, so a result can
  never be filed under the wrong inputs — all three wrong conclusions in this
  investigation were mislabelled inputs rather than misread logs;
* it **prints an explicit verdict** instead of leaving judgement to log-reading;
* it encodes that `dmesg -C` does not work here and that `rmmod`/`modprobe` does
  not re-probe, so it never produces output that looks like data and is not.

It is also how the final alignment was verified — combo 3, the AP6256 NVRAM with
the shipping firmware, cold-booted and confirmed working. Any future firmware or
NVRAM change should go through it rather than by hand, so that the installed state
is always identified from the files rather than from memory.

```sh
# from the serial console
sh wifi-test.sh list          # combos and what has been recorded
sh wifi-test.sh stage <n>     # install a combination and verify hashes
poweroff
# UNPLUG the supply, wait 10 s, power on
sh wifi-test.sh check
```

The script must be on the board first:

```sh
scp scripts/wifi-test.sh root@<board>:/root/
```
