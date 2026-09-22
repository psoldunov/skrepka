#!/usr/bin/env bash
# Hermetic install/upgrade/uninstall checks for the GNOME extension.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT=$(mktemp -d)
trap 'rm -rf "${ROOT}"' EXIT
PAYLOAD=${ROOT}/payload
FAKE_BIN=${ROOT}/fake-bin
ENABLED_STATE=${ROOT}/enabled-extensions
DISABLED_STATE=${ROOT}/disabled-extensions
LOG=${ROOT}/gnome-extensions.log
UUID=skrepka@dev.soldunov
mkdir -p "${PAYLOAD}/bin" "${PAYLOAD}/packaging/systemd" "${FAKE_BIN}"

cat >"${PAYLOAD}/bin/skrepkad" <<'EOF'
#!/usr/bin/env bash
echo 'skrepkad test'
EOF
cat >"${PAYLOAD}/bin/skrepka" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${PAYLOAD}/bin/skrepkad" "${PAYLOAD}/bin/skrepka"
cat >"${PAYLOAD}/packaging/systemd/skrepkad.service" <<'EOF'
[Service]
ExecStart=%h/.local/bin/skrepkad
EOF
cp -R gnome-extension "${PAYLOAD}/gnome-extension"

cat >"${FAKE_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"${FAKE_BIN}/gsettings" <<'EOF'
#!/usr/bin/env bash
case "$3" in
    enabled-extensions) state=${FAKE_GSETTINGS_ENABLED} ;;
    disabled-extensions) state=${FAKE_GSETTINGS_DISABLED} ;;
    *) exit 2 ;;
esac
case "$1" in
    get) cat "${state}" ;;
    set) printf '%s\n' "$4" >"${state}" ;;
    *) exit 2 ;;
esac
EOF
cat >"${FAKE_BIN}/gnome-extensions" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GNOME_LOG}"
case "$1" in
    info)
        [[ ${FAKE_GNOME_KNOWN:-0} == 1 ]] || exit 1
        printf '  Enabled: Yes\n  State: ACTIVE\n'
        ;;
    enable | disable) exit 0 ;;
    *) exit 2 ;;
esac
EOF
cat >"${FAKE_BIN}/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ -n ${FAKE_MV_FAIL_DEST:-} && ${destination} == "${FAKE_MV_FAIL_DEST}" \
    && ! -e ${FAKE_MV_MARKER} ]]; then
    touch "${FAKE_MV_MARKER}"
    exit 1
fi
exec /bin/mv "$@"
EOF
chmod +x "${FAKE_BIN}"/*
printf '@as []\n' >"${ENABLED_STATE}"
# Model a reinstall after `gnome-extensions disable` left a marker behind.
printf "['%s']\n" "${UUID}" >"${DISABLED_STATE}"
: >"${LOG}"

export HOME=${ROOT}/home
export XDG_BIN_HOME=${HOME}/bin
export XDG_CONFIG_HOME=${HOME}/config
export XDG_DATA_HOME=${HOME}/data
export XDG_CACHE_HOME=${HOME}/cache
export PATH=${FAKE_BIN}:${PATH}
export FAKE_GSETTINGS_ENABLED=${ENABLED_STATE}
export FAKE_GSETTINGS_DISABLED=${DISABLED_STATE}
export FAKE_GNOME_LOG=${LOG}
unset WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
mkdir -p "${HOME}"

./install.sh --from-dir "${PAYLOAD}" >"${ROOT}/first.log" 2>&1
test -f "${XDG_DATA_HOME}/gnome-shell/extensions/${UUID}/extension.js"
test -f "${XDG_DATA_HOME}/gnome-shell/extensions/${UUID}/limits.js"
grep -Fq "'${UUID}'" "${ENABLED_STATE}" \
    || { cat "${ENABLED_STATE}" "${ROOT}/first.log" >&2; exit 1; }
if grep -Fq "'${UUID}'" "${DISABLED_STATE}"; then
    echo 'Skrepka remained in disabled-extensions after installation' >&2
    exit 1
fi
grep -Fq 'next GNOME login' "${ROOT}/first.log"

# A disabled extension stays disabled across an upgrade.
printf '@as []\n' >"${ENABLED_STATE}"
export FAKE_GNOME_KNOWN=1
./install.sh --from-dir "${PAYLOAD}" >"${ROOT}/disabled-upgrade.log" 2>&1
grep -Fxq '@as []' "${ENABLED_STATE}"
grep -Fq 'kept the Skrepka GNOME Shell extension disabled' "${ROOT}/disabled-upgrade.log"

# An enabled extension is disabled around replacement and re-enabled live.
printf "['%s']\n" "${UUID}" >"${ENABLED_STATE}"
: >"${LOG}"
./install.sh --from-dir "${PAYLOAD}" >"${ROOT}/enabled-upgrade.log" 2>&1
grep -Fxq "disable ${UUID}" "${LOG}"
grep -Fxq "enable ${UUID}" "${LOG}"
grep -Fq 'clipboard capture is active' "${ROOT}/enabled-upgrade.log"

# A failed atomic replacement restores and re-enables the old extension.
touch "${XDG_DATA_HOME}/gnome-shell/extensions/${UUID}/old-version"
: >"${LOG}"
export FAKE_MV_FAIL_DEST=${XDG_DATA_HOME}/gnome-shell/extensions/${UUID}
export FAKE_MV_MARKER=${ROOT}/mv-failed
if ./install.sh --from-dir "${PAYLOAD}" >"${ROOT}/failed-upgrade.log" 2>&1; then
    echo 'upgrade unexpectedly survived the injected move failure' >&2
    exit 1
fi
unset FAKE_MV_FAIL_DEST FAKE_MV_MARKER
test -f "${XDG_DATA_HOME}/gnome-shell/extensions/${UUID}/old-version"
grep -Fxq "disable ${UUID}" "${LOG}"
grep -Fxq "enable ${UUID}" "${LOG}"

./install.sh --uninstall >"${ROOT}/uninstall.log" 2>&1
test ! -e "${XDG_DATA_HOME}/gnome-shell/extensions/${UUID}"
if grep -Fq "'${UUID}'" "${ENABLED_STATE}"; then
    echo 'Skrepka remained in enabled-extensions after uninstall' >&2
    exit 1
fi
if grep -Fq "'${UUID}'" "${DISABLED_STATE}"; then
    echo 'Skrepka remained in disabled-extensions after uninstall' >&2
    exit 1
fi
