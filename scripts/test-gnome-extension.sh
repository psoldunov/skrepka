#!/usr/bin/env bash
# Cheap contract checks for the GNOME extension and every path that ships it.
set -euo pipefail
cd "$(dirname "$0")/.."

UUID=skrepka@dev.soldunov
EXTENSION=gnome-extension

for file in metadata.json extension.js dbus.js limits.js README.md; do
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
if grep -Eq '^! grep .*\$\{(DISABLED|ENABLED)_STATE\}' scripts/test-install-gnome-extension.sh; then
    echo 'install assertions must report failed GNOME extension state explicitly' >&2
    exit 1
fi
if grep -Fq 'NO_AUTO_START' "${EXTENSION}/dbus.js"; then
    echo 'dbus.js must allow D-Bus activation of skrepkad' >&2
    exit 1
fi

grep -Fq 'Math.ceil(MAX_CAPTURE_BYTES / 3) * 4 + 4' "${EXTENSION}/limits.js"
grep -Fq 'if (!isWithinEncodedLimit(representations))' "${EXTENSION}/dbus.js"
grep -Fq 'if (encodedSize > encodedRemaining)' "${EXTENSION}/extension.js"
grep -Fq 'encodedRemaining -= encoded.length' "${EXTENSION}/extension.js"

MAX_CAPTURE_BYTES=$((32 * 1024 * 1024))
MAX_ENCODED_CAPTURE_BYTES=$(((MAX_CAPTURE_BYTES + 2) / 3 * 4 + 4))
base64_encoded_size() {
    local byte_count=$1
    printf '%s\n' "$(((byte_count + 2) / 3 * 4))"
}
test "$(base64_encoded_size "${MAX_CAPTURE_BYTES}")" -eq $((MAX_ENCODED_CAPTURE_BYTES - 4))
split_size=$(($(base64_encoded_size 1) * 3 + $(base64_encoded_size $((MAX_CAPTURE_BYTES - 3)))))
test "${split_size}" -eq $((MAX_ENCODED_CAPTURE_BYTES + 4))

bash -n install.sh scripts/setup-linux.sh scripts/build-deck.sh scripts/gnome.sh \
    scripts/gnome-smoke.sh docker/gnome/session.sh scripts/test-install-gnome-extension.sh
scripts/test-install-gnome-extension.sh
