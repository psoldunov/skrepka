#!/usr/bin/env bash
# Cheap contract checks for the GNOME extension and every path that ships it.
set -euo pipefail
cd "$(dirname "$0")/.."

UUID=skrepka@dev.soldunov
EXTENSION=gnome-extension

for file in metadata.json extension.js dbus.js README.md; do
    test -f "${EXTENSION}/${file}"
done

grep -Fq '"uuid": "'"${UUID}"'"' "${EXTENSION}/metadata.json"
for version in 46 47 48 49 50; do
    grep -Eq '"'"${version}"'"' "${EXTENSION}/metadata.json"
done

grep -Fq "${UUID}" install.sh
grep -Fq 'gnome-extension' scripts/setup-linux.sh
grep -Fq 'gnome-extension' scripts/build-deck.sh
grep -Fq 'dev.soldunov.Skrepka1' "${EXTENSION}/dbus.js"
grep -Fq "'Submit'" "${EXTENSION}/dbus.js"
grep -Fq 'get_wayland_compositor()' "${EXTENSION}/extension.js"
grep -Fq 'if (isConcealed)' "${EXTENSION}/extension.js"
if grep -Fq 'NO_AUTO_START' "${EXTENSION}/dbus.js"; then
    echo 'dbus.js must allow D-Bus activation of skrepkad' >&2
    exit 1
fi

bash -n install.sh scripts/setup-linux.sh scripts/build-deck.sh scripts/gnome.sh \
    scripts/gnome-smoke.sh docker/gnome/session.sh scripts/test-install-gnome-extension.sh
scripts/test-install-gnome-extension.sh
