#!/bin/sh
# Extract one file's added lines out of a unified diff, by target path.
#
# A patch that touches several files cannot be checked by grepping every
# "+" line: the other files' hunks land in the output too, and the result
# never matches. This walks only the block whose "diff --git" line names
# the wanted path, and skips the "+++" file header.
#
# usage: extract-patch-file.sh <patch> <path-as-it-appears-after-b/>
set -e

patch=$1
want="b/$2"

awk -v want="$want" '
	/^diff --git / { inblk = ($4 == want); next }
	inblk && /^\+\+\+/ { next }
	inblk && /^\+/ { print substr($0, 2) }
' "$patch"