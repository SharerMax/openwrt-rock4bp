# recovery/

**Not tracked in git.** It exists only here, on the build host, and it is
regenerated rather than committed — the artefacts are binaries totalling ~14 MB
and they are not the source of anything.

## What belongs here

Exactly one set of artefacts: **the build that was last measured on hardware.**

Populate it only after a build has cleared its own acceptance check, and record
which check in `SHA256SUMS.txt`. An artefact set that has not been measured is
worse than no artefact set, because a recovery is the one moment where nobody is
reading carefully.

## Why that rule is here

It was violated, and the result sat in this directory for two days:

- Everything in here was the **base** build from 2026-10-06 — image sha256
  `5a09fc41…`, `idbloader.img` `b8fa872f…`. That build **panics the kernel on 3
  of 6 boots.** Anyone reaching for a recovery artefact under pressure would
  have flashed a bootloader with a known 50% failure rate.
- Alongside it sat `spi-working-armbian.bin`, a 4 MiB dump that is **not real
  chip content**. It contains zero FDT magics, zero occurrences of the string
  `U-Boot`, and zero RK33 header magics — a genuine U-Boot image carries at
  least three DTBs and prints its own version banner. The printable runs it does
  contain are DRAM residue that happens to include U-Boot fragments.

That dump was deleted rather than kept with a warning, because a file named
`spi-working-*.bin` invites exactly the wrong use.

## Note on the SPI dump, since it is easy to re-create this mistake

The original claim about the dump — that two consecutive reads of the same
64 KiB gave different md5 sums — was measured against the **chip**, through
Linux's SPI driver. Re-reading the saved file twice gives an identical md5, of
course, and proves nothing.

⚠️ **Counting byte patterns in a binary needs a real byte search.**
`grep -c -a -o $'\xd0\x0d\xfe\xed' file` reported 348 on a file with zero
matches, because `grep -c` counts matching *lines* and binary data has no lines
to speak of. Use something that counts occurrences.

## Current contents

Empty, pending the rebuild that drops patch `0103` and its re-measurement.
See `../docs/postmortem-dram-instability.md` for the measurements.
