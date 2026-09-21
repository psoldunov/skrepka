#!/usr/bin/env bash
# Save GNOME Shell's composited output through org.gnome.Shell.Screenshot.
set -euo pipefail
[[ $# -eq 1 ]] || { echo 'usage: skrepka-gnome-screenshot FILE.png' >&2; exit 64; }
# shellcheck source=/dev/null
source /tmp/gnome/env
mkdir -p "$(dirname "$1")"
rm -f "$1"
gdbus call --session --dest org.gnome.Shell.Screenshot \
    --object-path /org/gnome/Shell/Screenshot \
    --method org.gnome.Shell.Screenshot.Screenshot false false "$1" >/dev/null
test -s "$1"
echo "$1"
