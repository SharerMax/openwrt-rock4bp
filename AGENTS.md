# AGENTS.md

Guidance for AI agents working in this repository.

This repo is the **port**, not the OpenWrt tree. It holds the overlay sources, the
scripts, and the documentation for `radxa_rock-4b-plus` on OpenWrt 25.12.5. The OpenWrt
tree itself lives on the build host at `/home/max/Code/openwrt`.

Read this before changing anything. Most of the rules below exist because the obvious
approach has already failed here, and the failure was expensive or silent.

---

## What is where

| Path | What it is |
|---|---|
| `README.md` | Entry point: current state, what is verified, what is not |
| `docs/` | Reference and post-mortem documents, one topic each |
| `overlay/` | Sources that get copied into or patched onto the OpenWrt tree |
| `scripts/` | Build, deploy and verification scripts |
| `log/` | Serial captures, **gitignored** — regenerate, never rely on them being present |

`overlay/` holds two different kinds of file and they must not be mixed:

- **Copied verbatim** into the tree: `*.mk`. Synchronised by `scripts/sync-overlay.sh`
  using its explicit path map.
- **Patch sources**: `*.dts`, `*defconfig`, `*-u-boot.dtsi`. They do **not** go into the
  tree. They are turned into patches in `target/linux/rockchip/patches-6.12/`.

`*.orig` files record what upstream looked like before this port edited the file. They
are deliberately excluded from the sync map — copying one over its counterpart would
revert the port.

---

## Before you change anything

1. **Check whether the thing you are fixing is actually a problem on hardware.** The
   original risk list turned out to be entirely wrong, because it was written from a
   hand-written device tree. Now that the tree inherits upstream, several items simply
   do not exist.
2. **Look for a silent fallback before blaming a build.** `scripts/Makefile.lib` picks
   the **first** `$(wildcard)` match, so adding a board file *displaces* the generic one
   instead of layering on it. Nothing warns.
3. **Prefer an assertion over a comment.** If a defect could slip past, add a check.
   The standard is "could this defect get through", not "did I change something".

## Reporting results

- **Do not report a build as working because the build returned 0.** Nine of the original
  checks passed while the bootloader was unusable on hardware.
- **Check the first line of the build log's timestamp** before trusting the verification
  block. A silently failed background launch made it read the previous run's log.
- **Compare device trees, not hashes, to judge whether two builds are the same thing.**
  Byte reproducibility does not hold here; semantic equivalence does. See
  [docs/postmortem-u-boot-ddr.md](docs/postmortem-u-boot-ddr.md).
- **Mark what is not verified.** "Untested" written as "not yet tested" implies somebody
  should go test it. Some items here are unverified *by decision*, and that distinction
  matters. Keep it.

## Naming verified vs unverified

Anything in a table of results must come from hardware. If a claim is inferred from a
build artefact, label it as such. Four claims in this repo were wrong for the same
reason — recorded as true when the finding was made, never revisited:

- "the image carries no bootloader" (it does — LBA 0x40 and LBA 0x4000)
- "shorting the SPI pins makes the boot ROM skip SPI" (measured: it does not)
- "the WiFi chip refuses to run firmware" (fixed by one property name, since resolved)
- "the port's bootloader has never run" (it has — maskrom writes eMMC without touching
  SPI, which was a fourth route nobody considered)

Documentation here goes stale faster than anyone remembers. When you change behaviour on
hardware, re-read the affected passages in the same pass.

## ⚠️ SPI is writable from Maskrom; the documented reason it "was not" was wrong

**`rkdeveloptool wl` does not choose the medium — the loader does.** `db` pushes a
Rockchip loader that initialises the storage later commands address:

```
rk3399_loader_v1.27.126.bin        -> eMMC    (what this repo has always used)
rk3399_loader_spinor_*.bin        -> SPI NOR (a different file entirely)
```

There is also a second route: `rkdeveloptool cs [1=EMMC, 2=SD, 9=SPINOR]` switches the
current storage, and the tool reads the selection back to confirm it took. Two
independent routes to SPI means a wrong loader guess is not a dead end.

The docs said "`wl` only touches eMMC, so SPI is unreachable". The observation was
right and the mechanism was wrong, and the error had no symptom: with the wrong
loader `wl` **reports success while writing to the other medium**. A wrong
mechanism gets a usable route recorded as closed. `scripts/flash-spi.sh` checks the
loader name, confirms the medium with `cs 9` before writing, and reads back with
`rl` afterwards.

**The payload already existed and nobody noticed.** `CONFIG_ROCKCHIP_SPI_IMAGE=y` was
already in the defconfig, so U-Boot has been emitting `u-boot-rockchip-spi.bin`
(2212864 B) all along — it was just never staged, never asserted, never offered to
`rkdeveloptool`. **An artefact existing is not the same as it being packaged,
checked, or used.** The two container shapes are not interchangeable (rksd at
`0x800000` for eMMC vs rkspi 2K/2K-spread at `0xE0000` for SPI), and mixing them
stops after the SPL, which reads as a broken bootloader rather than a wrong file.
`scripts/assert-spi-boot-image.py` proves the SPI image is this build's rkspi
variant; it has negative controls and they have been run.

⚠️ **`flash-spi.sh --write` has never run on hardware**, and the loader version is
unsettled: Radxa ships `spinor v1.15.114` and documents that v1.72-and-later boards
need `v1.20.126`, and this board's revision has not been identified.

## The port's U-Boot's cause: located and confirmed by measurement

**One missing device-tree property, and U-Boot never programs the PWM duty.**
24 clean boots across four builds; the mechanism was read off the hardware on
2026-10-10 over a serial console that did not exist until that morning.

**Twenty-four consecutive clean boots, across four different builds of this port's
bootloader.** 2026-10-08 with patch `0103` still present (six boots), then again with
`0103` deleted (six more, tty15), then 2026-10-09 with `regulator-init-microvolt` at
**800 mV** (six more), then 2026-10-10 at **1100 mV** (six more). Six distinct
`boot_id`s per run, identical `MemTotal`, zero panic/oops/BUG lines in dmesg. The
baseline it replaces was 3 panics in 6 boots (50%); Armbian's bootloader was 7 boots,
zero panics.

**What the 2026-10-09 analysis established, and what it did not.** Read these as two
separate claims, because conflating them is how this repository got its previous claims
wrong:

- **Established: the fault form is single-bit corruption.** Three instances, each exactly
  one bit from correct — `tick_nohz_stop_idle+0x38` (vmlinux `d5033abf`, ran `d5033ab7`),
  `el1h_64_irq+0x18` (`a90637ec` vs `a906376c`), and PC `ffff800080099ee4` vs
  `dfff800080099ee4`. One bit, three times, in different code, is signal integrity —
  not "memory full of garbage".
- ~~**Established: the mechanism** — the rail sat at **0% for the whole kernel
  session**.~~ **RETRACTED 10-09 by measurement.** The reasoning was that
  `pwm_regulator_init_boot_on()` writes `pstate.duty_cycle = 0` and continuous mode
  maps 800000 → 0%, 950000 → 25%. But building the **0% case on purpose** — `init =
  <800000>` — gave **6/6 clean boots**. A rail genuinely sitting at its minimum would
  have been the broken state, and it was not. **Do not quote the 0% claim.**
- **Established: the fault form.** (kept, above) Single-bit corruption, three times.
- **Established: `set_voltage` is what actually writes.** `regulator_summary` reports
  `vdd_log ... 800mV ... 800mV 1400mV`, and the first figure is the current-voltage
  column rather than the min/max constraints — only a successful `set_voltage` moves
  it. `pwm_regulator_set_voltage()` writes the duty **unconditionally**, whereas
  `pwm_regulator_init_boot_on()` returns early `if (pstate.enabled)`. Without
  `regulator-init-microvolt` the former is never called at all.
- ~~**NOT established: that "the duty was never written" is why it failed.**~~
  **ESTABLISHED 10-10 by serial read.** `md 0xff420020 4` at the U-Boot prompt gives
  `duty/period` = 603/1207 = 49.96%, the configured duty, and `ctrl & 0x3 == 0x3`. On
  the failing builds U-Boot prints `Cannot find regulator pwm init_voltage`, and that
  line appears in **every** 269-phase capture and **no other** — see
  `scripts/classify-serial-logs.sh`. The claim it needed serial for is now measured.
- **NOT established: the last link.** Nothing in the kernel's `supply_map` consumes
  `vdd_log`, and no `*-supply` property in the compiled dtb references its phandle.
  **The device tree does not describe this board's real wiring**, so whatever this rail
  does cannot yet be connected to the crash site at `rk3x_i2c_irq`.
- **NOT measured: any duty cycle, ever.** The 0% claim came from source plus linear
  arithmetic. The board has no `/dev/mem`, `CONFIG_PWM_SYSFS` is off so there is no
  `/sys/class/pwm/pwmchip0/pwm0/`, and `debugfs/pwm` is empty. `regulator_summary`
  reports *requested* voltage. Confirming needs a multimeter or a TTL adapter.
- **Do not propose an upstream PR yet.** Without the last link nobody else can
  reproduce it, so nobody can tell whether the voltage line is actually necessary.
- **Twenty-four clean boots does not mean a zero failure rate.** The fault was
  intermittent. Twenty-four boots say "did not occur in twenty-four", not "cannot occur".
- **Three passing values across a wide range was the open problem, and the serial read
  answered it.** "Why does any explicit value work?" — because **the value is not the
  variable; whether the duty was ever written is.** `duty/period` measured 603/1207 =
  49.96%, i.e. the configured value, and the phase moves linearly with it. That is the
  answer, and it was only reachable with a serial console.

**Report this as "root cause located and confirmed by measurement, physical
explanation still open".** Those are two different statements and the difference is the
only thing worth being careful about here:

- **Confirmed.** Missing `regulator-init-microvolt` → U-Boot prints
  `Cannot find regulator pwm init_voltage` → `set_voltage` never called → only `ctrl`
  is written, `period`/`duty` keep reset values → the kernel's `boot_on` then returns
  early because `ctrl & 0x3 == 0x3`, so **nothing ever programs the duty** → phase 269
  → single-bit corruption → panic. Every link has a source reference or a measurement
  behind it.
- **Still open, and it does not affect the fix.** What the rail physically does on this
  board when unprogrammed, and where it goes. The device tree does not describe the
  board's wiring and `supply_map` has no consumer, so this cannot be derived locally.
  **A one-property fix does not need it.**

⚠️ **Do not upgrade that to "fully understood".** The open part is an *explanation*, not
a *fix*, and the difference shows up in the upstream PR: nobody can reproduce this yet,
because nobody else has a board whose rail behaves this way, and the port cannot say
*why* the line is necessary — only that it is.

⚠️ **The 800 mV experiment falsified the prediction. Do not resurrect it.**
`regulator-init-microvolt = <800000>` is duty 0%, which the analysis said was
identical to the broken state. It passed 6/6 clean. So **"the rail must actually be
driven" is dead** — and so is "950 mV is special", because that hypothesis also
predicted a panic. **Neither hypothesis had a column predicting the outcome that
happened, so the experiment could only falsify; it could not identify.** A prediction
table whose columns agree is not a discriminator, and writing one that claimed to be
was the mistake.

⚠️ **What survives is narrower and stranger: the SDIO phase tracks the value written.**
269 before the fix, 210-213 at 800 mV, 215-226 at 950 mV — monotonic in voltage. If
merely *writing* the duty mattered, the phase would not move with the value. And the
269 point is the anomaly: if the pre-fix rail really sat at 0%, it should have landed
near 210-213, not 50 higher. So **"the pre-fix rail sat at 0%" is itself probably
wrong.** The likelier mechanism is the early return in `pwm_regulator_init_boot_on()`
(`if (pstate.enabled) return 0;`) against the unconditional write in
`pwm_regulator_set_voltage()`: without an init value the duty is **never written at
all**, and the pin is left in whatever state U-Boot left. ⚠️ **That is a hypothesis,
not a result** — confirming it needs to know what U-Boot left, and there is no serial
console to read it from.

⚠️ **Verified on the board that `set_voltage` does run**: `regulator_summary` shows
`vdd_log ... 800mV ... 800mV 1400mV`, where the first figure is the current voltage
column, not the min/max constraints. ⚠️ **That is still the requested value, not a
measurement** — no `/dev/mem`, `CONFIG_PWM_SYSFS` is off so there is no `pwm0/`, and
`debugfs/pwm` is empty. **"The duty really was 0%" has still never been measured.**

⚠️ **Serial became readable on 2026-10-10 (COM4 @ 1500000 baud) and that closes
the chain by measurement.** At the U-Boot prompt, before the kernel runs:

    => md 0xff420020 4
    ff420020: 0000019e 000004b7 0000025b 00000013
                cntr   period    duty     ctrl

`duty/period` = 603/1207 = **49.96%**, which is exactly `1100000`'s duty, and
`ctrl & 0x3 == 0x3` means enabled. **U-Boot writes it, not the kernel.** Deriving the
address and offsets rather than guessing them: `pwm2` is `0xff420020` in `rk3399-base.dtsi`
(in the **PMU** domain, not `0xff38xxxx`), and `rockchip,rk3399-pwm` is in neither
side's `of_match_table`, so both fall through to `rk3288-pwm` → `pwm_data_v2` →
`cntr/period/duty/ctrl` at `0x00/04/08/0c`.

⚠️ **I was wrong when I said U-Boot does not know `regulator-init-microvolt`.** I
grepped `drivers/regulator/*.c`; the file is `drivers/power/regulator/pwm_regulator.c`.
It reads the property at line 107 and applies it at 134-135. So **the fix is a U-Boot
fix and the kernel's `set_voltage` is redundant** — the kernel's `boot_on` returns
early precisely because U-Boot already enabled the channel.

⚠️ **The single most valuable grep in this repository.** That file prints
`Cannot find regulator pwm init_voltage` when the property is missing, and **that line
appears in every 269-phase log and in no other log, without exception** — including
tty7 and tty12, which died before probing SDIO and so have no phase at all. It sits
between `PMIC: RK808` and `Core: 307 devices`, i.e. in driver-model probe. This evidence
was in `log/` for three months and nobody read it, because there was no serial console
and no reason to open U-Boot's regulator source. **A criterion is often already in hand;
nobody asked.**

⚠️ **The second experiment turned the phase into a measurement, and that is the real
result.** Three explicit values, 30 boots between them, are collinear:
**0% → 211.5, 25% → 222.2, 50% → 232.5**, least-squares residual **≤ 0.1 phase**. So
**the rail really does move the SDIO timing margin** — that link is no longer merely
compatible. And the pre-fix reading of **269 is off that line**: extrapolating it needs
**1620 mV, 220 mV above the regulator's 1400 mV maximum**. So 269 is not any voltage
this rail can produce. It is a different electrical state, and the last version of
"the rail sat at 0%" is dead with it. ⚠️ **But that only says what the pre-fix state was
not.** "The duty was never written at all" is the only hypothesis left standing and it
is still unproven.

⚠️ **Never judge one boot as a result.** The first 800 mV boot came back clean and was
worth nothing; a 50% failure rate produces a clean boot half the time. The verdict came
from the sixth. Check the image identity too — read `u-boot.itb` back off eMMC and
compare it, because a whole-image rewrite also rotates the host key, and "one clean
boot" is not even attributable without both.

⚠️ **The SDIO phase value is a rail indicator, not a build fingerprint.** It is the only
observable in the logs that moved — 269 on every pre-vdd_log boot that probed SDIO, and
221/224/225/223 on the vdd_log boots. I called it a "flash fingerprint" and was wrong:
it varies per boot, so **assert the band, never the exact number.** My first band was
220-224 and it failed a real reading of 225 — widen it from observed readings only.

- **The six-boot bar was met on 2026-10-08, so the image is deliverable.** What is
  still open is the cause, not the stability. Keep those two separate in every status
  report: *threshold met* is not *root cause found*.
- **The obvious hypothesis is already dead.** `rk3399-sdram-lpddr4-100.dtsi` is
  byte-identical between v2022.07 (Armbian) and v2025.10 (this port) — sha256
  `2874c640…`. Same DRAM CONFIGs, same board dtsi, and the driver differs by 3%.
- **The "50MHz vs 400MHz" serial-output difference is real, not a printing artefact.**
  `sdram_print_ddr_info()` runs inside the channel loop, and by then the early
  `lpddr4_set_rate` has already moved the controller to 400MHz, so the printed number
  tracks the state the configuration writes actually happen at. The board rate is
  **50MHz** — index 34 of the flat u32 array, pinned by the struct total
  `34+5+332+200+959 = 1530` matching the dtsi, plus `num_channels`, `stride` and `odt`
  all agreeing with `sdram-rk3399-lpddr4-400.inc`. I once decoded this as 80 from a
  buggy script and the wrong number reached the patch header and the docs; the serial
  print of 50MHz is the evidence it was wrong.
- **DRAM initialisation is ruled out, by experiment — and the experiment has been deleted.**
  `0103-ram-rockchip-rk3399-lpddr4-configure-before-training.patch` restored the v2022.07
  order (50MHz, configure, then train and switch). The serial log confirmed it took
  effect, and the fault was unchanged: tty13's second boot is identical to tty12's down
  to the ESR, the PC `0xdfff800080099ee4`, the link register and `rk3x_i2c_irq+0x198/0x3a0`.
  Two boots, two panics. **Deleted 10-08** — it was the port's only divergence from
  upstream, a behaviour change to a shared DRAM driver that upstream has no reason to
  want, and it blocked the question of whether `vdd_log` alone is sufficient. **The
  measurements outlive the patch; see docs/postmortem-dram-instability.md.**
- **The `&vdd_log` override is what cleared the bar.** The board dtsi override this port
  had been omitting: `&vdd_log { regulator-init-microvolt = <950000>; }`. It matters
  because the kernel's own node in `rk3399-rock-pi-4.dtsi` is a pwm-regulator with only
  `regulator-min/max-microvolt` and no `regulator-init-microvolt` — so whatever U-Boot
  leaves is what the kernel keeps, and this port left nothing. Upstream
  `rk3399-rock-pi-4-u-boot.dtsi` and Radxa's own `rk3399-rock-4c-plus-u-boot.dtsi` both
  set it. Only that one property was added; `&sdhci` and the `leds` node stay out so
  that a failure stays attributable. **Six consecutive clean boots measured. The causal
  chain is still not closed** — see the section above.
- **Deleting 0103 is itself under test.** The six clean boots were measured *with* it, so
  "is vdd_log alone enough?" is currently unanswered. A rebuild without it passes all 21
  checks and its source is verified back to upstream v2025.10's shape — the early
  `lpddr4_set_rate(dram, params, 0)` is back and the trailing `set_rate_index` is a single
  call — but **it has not been on the board.** `u-boot.itb` is byte-identical either way
  (0103 only touched TPL), so only `idbloader.img` changes: `76bf3bcf7be75197`, was
  `7c65ea03783a614c`.
- **Count boots by splitting on the TPL banner, never by counting panic lines.** tty8
  and tty13 each contain two boots, so a naive count of `Kernel panic` occurrences
  inflates the sample. Every boot count in this repo was re-derived this way, and the
  re-derivation found real errors: tty2 and tty3 had mounted root all along, and two
  "always crashes at about half a second" panics were actually at 1.39s.

- **The omission was an accident, not a decision.** The dtsi said it was skipping
  `rk3399-rock-pi-4-u-boot.dtsi` because its `&sdhci` timing and `leds` node were not
  what was missing. That reasoning covered the whole file, and `&vdd_log` went with it
  without ever being looked at separately. **A general argument about a file is not a
  reason about every item in it.**
- **A `&label` absent from the U-Boot tree may still resolve.** `vdd_log` is defined
  nowhere in U-Boot's RK3399 dtsi chain — only in the rk3288, rk3368, px30, rk3229
  trees and in `rk3399-rock960-u-boot.dtsi`. The override works anyway, because this
  recipe builds the U-Boot control FDT from the kernel's own dtb plus the
  `-u-boot.dtsi`, and the node comes from the kernel side. Settle it by comparing the
  two dtbs rather than by reading source: the kernel's has no init value, U-Boot's has
  0xe7ef0.
- **A test script that edits the build tree must restore it on the failure path too.**
  `set -e` kills it before the restore, the tree keeps the edit, and the next build
  faithfully produces output missing the change — with no warning anywhere. Use `trap`,
  or work on a copy. It happened here, and the only thing that caught it was an
  assertion on the compiled output.
- **Do not assume mainline v2022.07 is what Armbian runs.** Its banner is
  `2022.07_armbian-…`, it patches its own U-Boot, and its parameters differ from
  ours. Those patches are not available, so mainline v2022.07 ordering is the closest
  we can get, not the same thing.
- **Count your variables before claiming a cause.** The tty11-vs-tty12 comparison changed
  the bootloader *and* the boot medium at the same time; they were perfectly collinear, so
  it did not support "the TPL is at fault". As of 2026-10-08 both columns have been run
  from eMMC — Armbian 7 boots with zero panics, ours 6 with 3 — so the bootloader is
  now the only variable. That cell was closed by rebooting the box six times.
- **`ConnectTimeout` does not bound an ssh call.** It only covers the TCP connect; the
  askpass/password exchange can block indefinitely. A reboot loop sat on one call for four
  minutes while the board had already rebooted and was answering normally. Wrap every ssh
  in `timeout` and judge reachability by the wrapper's exit status.
- **The board answers at `192.168.3.8`** as `root` with **no password**. Read-only
  inspection is fine and has been useful — the SPI retest, the eMMC matrix and the
  reboot matrix all came from it. It now runs this port's own OpenWrt image, not
  Armbian, and its host key changed when that image was written
  (`SHA256:qgJ+OCni…`, old Armbian-era key `SHA256:bkOdpYyr…` retired). **Check which
  key you have before assuming a host is the board.**
- ⚠️ **A serial console now exists (2026-10-10, `COM4` @ 1500000 baud, on the Windows
  box).** It was unavailable for the whole previous investigation, which is why the
  mechanism took a month to pin down. It gives TPL/SPL output, the U-Boot prompt, and
  `md`/`mw` on any register. **Reach for it first next time.** MobaXterm holds `COM4` when
  the user has it open — ask them to release it, and check the MAC before trusting a
  host after a whole-image rewrite.
- **The reboot loop is how the six-boot threshold is reached.** With the board on the
  network, reboot over ssh and poll `boot_id`. Each boot must show a new `boot_id`, a
  clean dmesg, and a phase in the rail band. **A boot that never comes
  back is a result, not a retry** — the panic lands at 0.5-1.4s, before networking.
- **`nohup reboot &` over ssh does not reboot the board.** The process dies with the
  pty when ssh exits, the board never goes down, and the result looks exactly like a
  successful no-op: `reboot` exits 0, the board keeps answering, `boot_id` is
  unchanged. **This wasted two rounds of a five-round matrix before the `boot_id`
  assertion caught it** — which is the argument for that assertion. Use
  `setsid reboot </dev/null &`, and keep checking `boot_id` rather than trusting
  the trigger's exit status.
- **Maskrom can write eMMC** (`rkdeveloptool wl 0 <image>`). Prefer it over writing SPI —
  ⚠️ though note SPI currently holds nothing bootable, so it is not itself a fallback.
## Board facts worth knowing before you touch the device tree

- Boot order is **SPI → eMMC → SD**. A working SPI bootloader always wins, so a masking
  trick cannot force the use of an image-embedded bootloader.
- ⭐ **The board has three buttons — Maskrom, Reset, Recovery — and pressing Maskrom or
  Recovery at power-on enters maskrom WITHOUT shorting the SPI pins.** Measured 2026-10-10,
  repeatedly, all combinations. **The Recovery key had been written out of existence
  first**, by choosing Radxa's one-button doc over an old wiki's three-button account
  without anyone looking at the board — two written sources disagreed and the tie was
  broken on paper, not on the hardware. Linux sees no key events, so the DTS still has no
  gpio-keys node; that part is measured (holding a key moves no GPIO).
  ⚠️ **MECHANISM, measured 2026-10-11 (`log/tty19.txt`): it is U-Boot PROPER that sees the
  key**, not the boot ROM — `download key pressed, entering download mode...resetting ...`
  appears after the full U-Boot banner and environment load, then `Boot1 Release Time` and
  `UsbBoot` from the ROM. So **the key does NOT participate in the ROM's choice of medium**
  (neither "key outranks SPI" nor "SPI runs first so the key is useless" is right), and
  ⚠️ **the key route needs a working U-Boot proper while shorting the SPI pins does not**
  — the ROM does that one itself. **The two routes are NOT equivalent: if the bootloader is
  broken the key route is UNTESTED, so keep the shorting step as the fallback.** That line
  buys not needing a working bootloader, and dropping it because the key is easier is how a
  bricked board becomes unfixable. See `docs/hardware.md` and `docs/boot-order.md`.
- ⚠️ **`Trying to boot from BOOTROM` / `Returning to boot ROM...` are on the successful path
  and prove nothing about SPI.** They appear in `log/tty19.txt` at lines 9-10 and 126-127,
  same position both times, on a boot that reaches Linux and mounts root with zero panics.
  `docs/boot-order.md` used them to conclude SPI holds nothing bootable; that inference does
  not hold. ⚠️ Whether SPI currently holds anything bootable is **still untested** — do not
  re-record "SPI is empty" as established.
- ⚠️ **A build tree is not evidence about a board.** Three of this port's worst mistakes
  were the same shape: `CONFIG_ROCKCHIP_SPI_IMAGE=y` was already set so `u-boot-rockchip-spi.bin`
  existed for weeks with nothing staging or checking it; "the image carries no bootloader" was
  written down and never checked, and it does; a build that never started was verified against
  the *previous* run's log and reported clean. None is visible from `build_dir/`, because that is
  what you just wrote. **`scripts/check-bootloader-on-media.sh` reads `idbloader` and `u-boot.itb`
  back off `/dev/mmcblk0` on the board** and compares them with this build — the only thing that
  settles it. Run it after any flash, and **read its exit status**: board unreachable, untrusted
  host key, missing `stat`/tool, or unreadable device all report NOT CHECKED and exit non-zero
  rather than passing. ⚠️ OpenWrt's busybox has **no `stat` applet** — the script uses `wc -c`, and
  a version using `stat -c%s` reported the board as unreadable for a reason unrelated to the
  board.
- ⚠️ **An M.2 NVMe slot is not a tested NVMe slot.** `PCIe link training gen1 timeout!` appears
  on every boot because **nothing is plugged into it** (confirmed 2026-10-11). That is the same
  "harmless error" class as the empty microSD slot's `-110`, and it makes the path
  **untestable** rather than broken — a third status next to "verified" and "out of scope".
  Do not record PCIe as unavailable; there is no evidence, only an empty slot.
- The image **does** embed its own bootloader. Earlier docs said otherwise.
- A bootloader needs **two files**: `idbloader*.img` is TPL+SPL only; U-Boot proper is
  a separate `u-boot.itb`.
- Linux cannot read this SPI flash correctly. It is deterministic, repeatable, and wrong.
  Do not attempt to back up or write the SPI from a running system — see the post-mortem.
- **SPI visibility is not the problem, and never was.** On 2026-10-10 the port's own
  image showed `rockchip-spi` bound, `/dev/mtd0` = 4 MiB `spi1.0`, no deferred probe, and
  three identical read checksums — **cold boot (`Reset cause: POR`) and warm boots all
  identical**. The 2026-10-08 note claiming `/dev/mtd*` could not be reproduced was a
  single observation, not a finding, and is retracted. The `dmas` → PL330 defer chain in
  `docs/boot-order.md` explains how those three log lines arise; it is **not** this port's
  normal state. ⚠️ Why `log/tty14`–`tty17` defer while `tty2`–`tty13`/`tty18` do not, on
  byte-identical firmware, is **still unexplained** — do not re-record it as "SPI is
  unavailable".
- HDMI and audio are out of scope: no `CONFIG_DRM` / `CONFIG_SND`, and OpenWrt 25.12.5
  ships no matching kmod packages.

---

## Working with the OpenWrt tree

The tree is on a remote build host. Two repositories are involved and both must be left
clean:

```sh
# port repo
cd /home/max/Code/rockpi4bp && git status

# OpenWrt tree
cd /home/max/Code/openwrt && git status
```

Rules that are easy to get wrong:

- **`umask 022`.** The build host defaults to `0002` and `include/prereq-build.mk`
  refuses anything else. `scripts/build.sh` sets it.
- **After changing `DEVICE_PACKAGES`, run `make defconfig`.** Otherwise the build prints
  one warning line and packages the old set anyway.
- **`scripts/config` is a directory**, not the old helper script. To change `.config`,
  edit it in kconfig format and let `make defconfig` normalise it.
- **When regenerating a patch, the "pristine" baseline must really be pristine.** Using
  last build's already-patched file as the baseline adds the same line twice.
  `scripts/regen-dts-patch.sh` strips leftovers and asserts they are gone.
- **A new package needs an explicit `Build/Compile`** and `include $(INCLUDE_DIR)/package.mk`.
  Omitting the latter does not look like a missing include — it looks like the package was
  not selected, which sends you down the wrong path entirely.

## Scripts

| Script | Use |
|---|---|
| `build.sh` | Fix the manifest, then build, then run **24** post-build checks |
| `sync-overlay.sh` | Compare `overlay/` against the tree; copy either way, direction must be explicit |
| `check-patch-sources.sh` | Check each patch source against the patch it generates |
| `check-doc-links.py` | Check every relative markdown link resolves, including `#anchor` headings |
| `check-reboot-matrix.sh` | Reboot the board N times and judge each boot; needs no serial console |
| `check-reboot-matrix-selftest.sh` | Negative controls for the above — 7 cases, run it first. ⚠️ it only catches what it covers |
| `classify-serial-logs.sh` | Sort serial captures by the U-Boot `Cannot find regulator pwm init_voltage` line and the SDIO phase |
| `extract-patch-file.sh` | Pull one file out of a patch, for reading what a patch actually changes. Handles git-style **and** plain `diff -u` patches |
| `extract-patch-file-selftest.sh` | Negative controls for the above, 17 cases — run it first. ⚠️ it only catches what it covers |
| `check-bootloader-on-media.sh` | Read `idbloader`/`u-boot.itb` **back off the board's eMMC** and compare with this build. Settles "is the board running what we just built". `--selftest` runs without a board |
| `extract-debian-43456.sh` | Pull the 43456 firmware blob out of an Armbian package |
| `extract-synaptics-license.py` | Pull the licence text out of a Synaptics package for `extract-debian-43456.sh` |
| `regen-dts-patch.sh` | Regenerate the kernel DTS patch, with `dtc` validation |
| `assert-sdram-params-in-image.py` | Assert the RK3399 DRAM parameters are in the image |
| `deploy.sh` | Write the image to USB / SD / eMMC |
| `flash-spi.sh` | Write the SPI bootloader from Maskrom. ⚠️ `--write` not yet on hardware |
| `assert-spi-boot-image.py` | Assert the SPI boot image is this build's rkspi variant |
| `wifi-test.sh` | AP6256 power-on testing, one cold boot per combination |
| `write-idbloader-sd.ps1` | Windows: write `idbloader` to LBA 0x40 on a card |

`deploy.sh` and `write-idbloader-sd.ps1` destroy data. Run the list/verify/preview paths
first, every time — `--list`, `--verify`, and `-Preview` exist for that reason, and the
preview path is what caught two bugs in the destructive one.

Two specific footguns worth knowing before you touch hardware:

- **⚠️ eMMC now holds this port's OpenWrt image** (written 2026-10-08 for the `vdd_log`
  test, boot `tty14`, phase 221). An OpenWrt image was written there on 10-06 and an
  earlier Armbian was destroyed by a `dd` with no backup. **⚠️ SPI no longer holds a
  bootable image.** tty14's log prints `Trying to boot from BOOTROM` /
  `Returning to boot ROM...`, which is what the ROM says when it found nothing on SPI
  and fell through to eMMC — even though boot order is SPI first. Maskrom `wl` did not
  write SPI, but SPI is not providing a recovery path either, and I had asserted that it
  was without checking. **The recovery path right now is Maskrom.** This line has been
  rewritten four times; read it read-only before writing.
- **Linux cannot read this SPI flash correctly, on any kernel.** Armbian 6.18.54 gives two
  different md5 sums for two consecutive reads of the same 64 KiB and zero strings ≥12
  chars. So `recovery/spi-working-armbian.bin` was not real U-Boot data — it contained zero
  FDT magics. **That file was deleted on 10-09**: a file named `spi-working-*.bin` invites
  exactly the wrong use, and `recovery/README.md` records the two broken ways to test that
  claim (`grep -c` counts lines, and binary data has no lines; re-reading a saved file twice
  gives an identical md5, while the real "two reads differ" claim was about the chip).
- **`deploy.sh` defaults to the squashfs image.** The board has been running ext4. Pass
  the variant explicitly or you will flash a different image than the one you tested.

## House conventions

- LF line endings in the tree and the working tree (`.gitattributes`). These files are
  consumed by `make`, `sh` and `dtc`, and a stray CR fails in ways unrelated to line
  endings.
- Comments explain **why**, and record what was ruled out and how. A comment that only
  restates the code is noise.
- No credentials, keys or tokens in this repository.
- Commit messages state what changed and why, including anything the change retracts.