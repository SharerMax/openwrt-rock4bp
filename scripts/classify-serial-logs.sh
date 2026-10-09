#!/bin/sh
# Classify serial captures by the U-Boot PWM-regulator diagnostic.
#
# WHY THIS EXISTS
#
# U-Boot's drivers/power/regulator/pwm_regulator.c prints
#
#     Cannot find regulator pwm init_voltage
#
# when the device tree has no regulator-init-microvolt for a pwm-regulator node.
# In that case pwm_regulator_probe() never calls set_voltage(), so the duty and
# period registers are never programmed -- only ctrl is, by set_enable().
#
# That single line is the cleanest discriminator this repository has found. In
# log/ it appears in EVERY capture that read SDIO phase 269 and in NO other
# capture, without exception -- including tty7 and tty12, which panic before the
# SDIO probe and therefore have no phase recorded at all.
#
# It is also easier to trust than the phase. The phase moves per boot and has
# already broken three separate assertions in this repository; this line is
# emitted or not emitted, once per boot, with nothing in between.
#
# WHAT IT DOES NOT DO
#
# It does not decide whether a boot is good. It says which builds carried the
# property. A boot count still needs a real boot count -- count boots by
# splitting on the TPL banner, never by counting panic lines, because one
# capture can contain two boots.
#
# Usage: sh scripts/classify-serial-logs.sh [dir]
set -eu

DIR=${1:-log}
DIAG='Cannot find regulator pwm init_voltage'

[ -d "$DIR" ] || { echo "no such directory: $DIR" >&2; exit 1; }

found_any=0
printf '%-16s %-6s %-8s %s\n' FILE BOOTS PHASE DIAGNOSTIC
printf '%s\n' '-------------------------------------------------------------'

for f in "$DIR"/*.txt; do
	[ -e "$f" ] || continue
	found_any=1
	name=$(basename "$f")

	# Boots are counted by splitting on the TPL banner. Counting panic lines
	# inflates the sample -- tty8 and tty13 each contain two boots.
	boots=$(grep -c 'U-Boot TPL' "$f" || true)

	ph=$(grep -o 'tuned phase to [0-9]*' "$f" 2>/dev/null |
		head -1 | grep -o '[0-9]*$' || true)
	[ -n "$ph" ] || ph='-'

	n=$(grep -c "$DIAG" "$f" 2>/dev/null || true)
	if [ "$n" -eq 0 ]; then
		diag='absent'
	elif [ "$boots" -gt 0 ] && [ "$n" -eq "$boots" ]; then
		diag="on all $n"
	elif [ "$boots" -gt 0 ] && [ "$n" -lt "$boots" ]; then
		diag="ON $n of $boots"     # mixed: more than one build in one capture
	else
		diag="present x$n"
	fi

	printf '%-16s %-6s %-8s %s\n' "$name" "$boots" "$ph" "$diag"
done

[ "$found_any" -eq 1 ] || { echo "no captures in $DIR" >&2; exit 1; }

cat <<'NOTE'

Reading the output:
  absent        the build had regulator-init-microvolt; U-Boot programmed the duty
  on all N       every boot in this capture lacked it -- the failing configuration
  ON n of N      more than one build in one capture; do not count these as one thing
  present xN     diagnostic present but the boot count could not be derived

A capture with phase 269 and "absent" contradicts the mechanism, and a capture
with phase 210-234 and "on all N" contradicts it too. Neither has been observed.
Note that phase is a rail indicator with a per-boot spread -- assert the band,
never the value.
NOTE