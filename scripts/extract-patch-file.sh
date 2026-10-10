#!/bin/sh
# Extract one file's added lines out of a unified diff, by target path.
#
# A patch that touches several files cannot be checked by grepping every "+"
# line: the other files' hunks land in the output too, and the result never
# matches, which reads as DRIFT rather than as a tool that cannot address the
# file. This walks only the block belonging to the wanted path.
#
# BOTH PATCH SHAPES, because the port has both
#
#   git style      "diff --git a/P b/P" ... "--- a/P" / "+++ b/P"
#   plain unified  "--- /dev/null" / "+++ b/P"          <- no diff --git line
#
# The plain shape is what regen-dts-patch.sh emits for the U-Boot DTS patch
# (0100), and the git-only addressing missed it completely: it found no
# "diff --git" line to match, matched nothing, and printed nothing. check-
# patch-sources.sh therefore never compared that patch against its source and
# could not have reported it stale. An empty result and a real "not in this
# patch" are indistinguishable at the call site, which is exactly why it went
# unnoticed -- so the shape is detected rather than assumed.
#
# FILE HEADERS VS CONTENT THAT LOOKS LIKE ONE
#
# A removed line whose text starts with "-- " is written as "--- ", and an
# added line whose text starts with "++ " is written as "+++ ". So the header
# lines cannot be recognised by prefix alone. The hunk header carries the line
# counts (@@ -a,b +c,d @@), and a hunk ends when both budgets are spent; only
# outside a hunk can a "---"/"+++" line be a header. Skip that and a DTS that
# happens to contain such a line silently truncates the file.
#
# usage: extract-patch-file.sh <patch> <path>
#        the path may be given bare or with the b/ prefix; both are accepted,
#        because plain unified diffs carry no prefix at all.

set -e

patch=$1
bare=$2
want="b/$2"

awk -v want="$want" -v bare="$bare" '
function is_wanted(p) { return (p == want || p == bare) }

# "@@ -12,7 +5,6 @@" -> how many old and new lines this hunk consumes. A count
# of 0 is a real value (a pure addition), and an omitted count means 1.
function count(field,   body, comma) {
	body = field
	sub(/^[-+]/, "", body)
	comma = index(body, ",")
	if (comma == 0) return 1
	return substr(body, comma + 1) + 0
}

BEGIN { infile = 0; inhunk = 0; oldleft = 0; newleft = 0 }

/^diff --git / {
	infile = is_wanted($4)
	inhunk = 0; oldleft = 0; newleft = 0
	next
}

/^@@ / {
	oldleft = count($2)
	newleft = count($3)
	inhunk = 1
	next
}

# Must precede the header rules below: a line inside a hunk that starts with
# "---" or "+++" is content, not a header.
inhunk {
	c = substr($0, 1, 1)
	if (c == "\\") next                      # "\ No newline at end of file"
	if (c == "+") {
		newleft--
		if (infile) print substr($0, 2)
	} else if (c == "-") {
		oldleft--
	} else {
		oldleft--; newleft--                 # context, or an empty context line
	}
	if (oldleft <= 0 && newleft <= 0) inhunk = 0
	next
}

/^--- / { next }

/^\+\+\+ / {
	infile = is_wanted(substr($0, 5))
	next
}
' "$patch"