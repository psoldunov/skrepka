#!/usr/bin/env bash
#
# Prints one version's CHANGELOG.md section as the body of its GitHub release:
#
#   scripts/release-notes.sh 0.3.0 > build/release-notes.md
#   gh release create v0.3.0 --notes-file build/release-notes.md ...
#   gh release edit v0.3.0 --notes-file build/release-notes.md
#
# Two things differ from the section as the file has it:
#
#   * Each paragraph and each list item is joined onto one line. CHANGELOG.md
#     is wrapped at 80 columns to read well in a terminal and a diff, and a
#     GitHub release renders every newline in its body as a line break, so the
#     section pasted as it is reads as ragged lines. Code fences, headings and
#     table rows are left as they are.
#   * Relative links point at the files as they were at the release's tag. A
#     release page has no README.md beside it, so `[text](README.md#x)` would
#     lead nowhere.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	echo "usage: scripts/release-notes.sh VERSION, with VERSION like 0.3.0" >&2
	exit 1
}
BASE="https://github.com/psoldunov/skrepka/blob/v${VERSION}/"

# The section is everything after its `## [VERSION]` heading and before the
# next `## ` heading.
SECTION="$(VERSION="${VERSION}" awk '
	index($0, "## [" ENVIRON["VERSION"] "]") == 1 { found = 1; next }
	found && /^## / { exit }
	found { print }
' CHANGELOG.md)"
[[ -n "${SECTION//[[:space:]]/}" ]] || {
	echo "error: CHANGELOG.md has no section headed ## [${VERSION}]." >&2
	exit 1
}

printf '%s\n' "${SECTION}" | BASE="${BASE}" awk '
	function flush() {
		if (block != "") { print absolute(block); block = "" }
	}
	# Every `](target)` whose target is a path in this repository gains the
	# tag URL in front; web links, anchors and mail links are left alone.
	function absolute(line,    out, at, target) {
		out = ""
		while ((at = index(line, "](")) > 0) {
			out = out substr(line, 1, at + 1)
			line = substr(line, at + 2)
			target = line
			if (target !~ /^(https?:|mailto:|#)/) {
				out = out ENVIRON["BASE"]
			}
		}
		return out line
	}
	/^[[:space:]]*```/ { flush(); print; fenced = !fenced; next }
	fenced { print; next }
	/^[[:space:]]*$/ { flush(); print ""; next }
	# A heading or a table row is one line on its own.
	/^#/ || /^[[:space:]]*\|/ { flush(); print absolute($0); next }
	# A list item or a quote starts a block of its own, keeping its indent,
	# which is what nests a list inside another.
	/^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]/ || /^[[:space:]]*>/ { flush(); block = $0; next }
	{
		line = $0
		sub(/^[[:space:]]+/, "", line)
		block = (block == "") ? line : block " " line
	}
	END { flush() }
' | awk 'NF { blank = 0 } !NF { if (blank++) next } { print }' | sed -e '1{/^$/d;}'
