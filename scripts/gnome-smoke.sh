#!/usr/bin/env bash
# Smoke-test a Linux release tarball in a fresh Ubuntu 26.04 / GNOME 50 session.
# Evidence: build/gnome/smoke/<run>/{shots,logs,summary.txt}.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd)
RELEASE=${SKREPKA_GNOME_RELEASE:-v0.2.1}
ASSET=skrepka-linux-x86_64.tar.gz
RUN_ID=$(date +%Y%m%d-%H%M%S)
RUN_DIR=${REPO}/build/gnome/smoke/${RUN_ID}
RUN=/out/smoke/${RUN_ID}
mkdir -p "${RUN_DIR}"/{input,logs,shots}
start=$SECONDS

if [[ -n ${SKREPKA_TARBALL:-} ]]; then
    [[ -f ${SKREPKA_TARBALL} ]] || { echo "SKREPKA_TARBALL=${SKREPKA_TARBALL} does not exist" >&2; exit 1; }
    SOURCE=${SKREPKA_TARBALL}
else
    CACHE=${REPO}/build/gnome/release/${RELEASE}
    SOURCE=${CACHE}/${ASSET}
    if [[ ! -f ${SOURCE} ]]; then
        mkdir -p "${CACHE}"
        URL=https://github.com/psoldunov/skrepka/releases/download/${RELEASE}/${ASSET}
        curl -fsSL -o "${SOURCE}.part" "${URL}"
        curl -fsSL -o "${SOURCE}.sha256" "${URL}.sha256"
        mv "${SOURCE}.part" "${SOURCE}"
    fi
fi
cp "${SOURCE}" "${RUN_DIR}/input/${ASSET}"
[[ ! -f ${SOURCE}.sha256 ]] || cp "${SOURCE}.sha256" "${RUN_DIR}/input/${ASSET}.sha256"
echo "subject: ${SOURCE}"
echo "run: build/gnome/smoke/${RUN_ID}"
scripts/gnome.sh up --fresh
session() { scripts/gnome.sh env RUN="${RUN}" bash -s; }
session <<'EOF'
skrepka-gnome-screenshot "${RUN}/shots/0-desktop-ready.png" >/dev/null
EOF

# 1. Install into the fresh container home; no systemd user manager exists.
session <<'EOF' | tee "${RUN_DIR}/logs/1-install.txt"
set -uo pipefail
cp "${RUN}/input/skrepka-linux-x86_64.tar.gz" /tmp/skrepka-subject.tar.gz
rm -rf /tmp/skrepka-release && mkdir /tmp/skrepka-release
if tar -xzf /tmp/skrepka-subject.tar.gz -C /tmp/skrepka-release \
    && bash /tmp/skrepka-release/*/install.sh --tarball /tmp/skrepka-subject.tar.gz \
        >"${RUN}/logs/install.log" 2>&1; then
    installed=yes
else
    installed=no
fi
pkill -x skrepka-gui 2>/dev/null || true
pkill -x skrepkad 2>/dev/null || true
sleep 1
nohup ~/.local/bin/skrepkad >"${RUN}/logs/skrepkad.log" 2>&1 &
for _ in $(seq 40); do busctl --user status dev.soldunov.Skrepka >/dev/null 2>&1 && break; sleep 0.25; done
nohup dbus-monitor "type=error" \
    "interface=org.freedesktop.portal.RemoteDesktop" \
    "interface=org.freedesktop.portal.Request" \
    "interface=org.freedesktop.portal.Session" \
    >"${RUN}/logs/dbus-portal.log" 2>&1 &
nohup ~/.local/bin/skrepka-gui --background >"${RUN}/logs/skrepka-gui.log" 2>&1 &
echo $! >/tmp/gnome/gui.pid
sleep 3
extension_dir=${XDG_DATA_HOME}/gnome-shell/extensions/skrepka@dev.soldunov
extension_enabled=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || true)
if [[ ${installed} == yes ]] \
    && busctl --user status dev.soldunov.Skrepka >/dev/null 2>&1 \
    && [[ -f ${extension_dir}/extension.js ]] \
    && [[ ${extension_enabled} == *"'skrepka@dev.soldunov'"* ]]; then
    echo "RESULT 1 install PASS: daemon, app and enabled GNOME capture extension installed"
else
    echo "RESULT 1 install FAIL: installer, daemon startup or GNOME extension setup failed"
fi
EOF

# A live Wayland Shell does not discover a brand-new extension directory. The
# installer enables its UUID for the next login, which this restart exercises
# without throwing away the clean home we just installed into.
scripts/gnome.sh restart

# 2. Capture from GNOME's server-side Wayland selection and X11 xclip. The
# headless virtual monitor advertises no keyboard to Wayland clients, so a GTK
# client cannot claim wl_data_device; setting a memory selection inside Shell
# drives the same Meta.Selection path the extension observes on a real seat.
session <<'EOF' | tee "${RUN_DIR}/logs/2-capture.txt"
set -uo pipefail
wait_bus_down() {
    for _ in $(seq 40); do
        busctl --user status dev.soldunov.Skrepka >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    return 1
}
wait_bus_up() {
    for _ in $(seq 40); do
        busctl --user status dev.soldunov.Skrepka >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    return 1
}
pkill -x skrepka-gui 2>/dev/null || true
pkill -x skrepkad 2>/dev/null || true
wait_bus_down || { echo 'old daemon kept the D-Bus name'; exit 1; }
# With DISPLAY absent the daemon has no XFIXES fallback, so every native
# Wayland result below can only have arrived through the Shell extension.
nohup env -u DISPLAY ~/.local/bin/skrepkad >"${RUN}/logs/skrepkad-wayland.log" 2>&1 &
wait_bus_up || { echo 'Wayland-only daemon did not claim the D-Bus name'; exit 1; }
nohup dbus-monitor "type=error" \
    "interface=org.freedesktop.portal.RemoteDesktop" \
    "interface=org.freedesktop.portal.Request" \
    "interface=org.freedesktop.portal.Session" \
    >"${RUN}/logs/dbus-portal.log" 2>&1 &
sleep 1
extension=$(gnome-extensions info skrepka@dev.soldunov 2>&1)
printf '%s\n' "${extension}"
skrepka-gnome-eval 'const Meta = imports.gi.Meta; const GLib = imports.gi.GLib; globalThis.skrepkaSmokeSource = Meta.SelectionSourceMemory.new("text/plain;charset=utf-8", new GLib.Bytes(new TextEncoder().encode("gnome wayland capture"))); global.display.get_selection().set_owner(Meta.SelectionType.SELECTION_CLIPBOARD, globalThis.skrepkaSmokeSource); "set text"' >/dev/null
sleep 2
wayland_text=$(~/.local/bin/skrepka list --json 2>&1)
printf '%s\n' "${wayland_text}" >"${RUN}/logs/list-after-wayland-text.json"
skrepka-gnome-eval 'const Meta = imports.gi.Meta; const GLib = imports.gi.GLib; const png = GLib.base64_decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="); globalThis.skrepkaSmokeSource = Meta.SelectionSourceMemory.new("image/png", new GLib.Bytes(png)); global.display.get_selection().set_owner(Meta.SelectionType.SELECTION_CLIPBOARD, globalThis.skrepkaSmokeSource); "set image"' >/dev/null
sleep 2
wayland_image=$(~/.local/bin/skrepka list --json 2>&1)
printf '%s\n' "${wayland_image}" >"${RUN}/logs/list-after-wayland-image.json"
printf 'gnome wayland file capture' >/tmp/gnome/wayland-capture.txt
skrepka-gnome-eval 'const Meta = imports.gi.Meta; const GLib = imports.gi.GLib; globalThis.skrepkaSmokeSource = Meta.SelectionSourceMemory.new("text/uri-list", new GLib.Bytes(new TextEncoder().encode("file:///tmp/gnome/wayland-capture.txt\r\n"))); global.display.get_selection().set_owner(Meta.SelectionType.SELECTION_CLIPBOARD, globalThis.skrepkaSmokeSource); "set file"' >/dev/null
sleep 2
wayland_file=$(~/.local/bin/skrepka list --json 2>&1)
printf '%s\n' "${wayland_file}" >"${RUN}/logs/list-after-wayland-file.json"

# Prove X11 capture belongs to the daemon's XFIXES backend, not the Shell
# extension observing an Xwayland client's selection through Mutter.
gnome-extensions disable skrepka@dev.soldunov >/dev/null
extension_disabled=no
for _ in $(seq 20); do
    if ! gnome-extensions info skrepka@dev.soldunov 2>&1 | grep -q 'State: ACTIVE'; then
        extension_disabled=yes
        break
    fi
    sleep 0.1
done
pkill -x skrepkad 2>/dev/null || true
wait_bus_down || { echo 'Wayland-only daemon kept the D-Bus name'; exit 1; }
nohup ~/.local/bin/skrepkad >"${RUN}/logs/skrepkad.log" 2>&1 &
wait_bus_up || { echo 'XFIXES daemon did not claim the D-Bus name'; exit 1; }
printf 'gnome x11 capture' | xclip -selection clipboard
sleep 2
x11=$(~/.local/bin/skrepka list --json 2>&1)
printf '%s\n' "${x11}" >"${RUN}/logs/list-after-x11.json"
gnome-extensions enable skrepka@dev.soldunov >/dev/null
for _ in $(seq 20); do
    extension=$(gnome-extensions info skrepka@dev.soldunov 2>&1)
    [[ ${extension} == *'State: ACTIVE'* ]] && break
    sleep 0.1
done
# The restarted XFIXES daemon should stop warning once an extension submission
# proves native Wayland capture is covered.
skrepka-gnome-eval 'const Meta = imports.gi.Meta; const GLib = imports.gi.GLib; globalThis.skrepkaSmokeSource = Meta.SelectionSourceMemory.new("text/plain;charset=utf-8", new GLib.Bytes(new TextEncoder().encode("gnome wayland diagnostics"))); global.display.get_selection().set_owner(Meta.SelectionType.SELECTION_CLIPBOARD, globalThis.skrepkaSmokeSource); "set diagnostics"' >/dev/null
sleep 2
nohup ~/.local/bin/skrepka-gui --background >"${RUN}/logs/skrepka-gui.log" 2>&1 &
echo $! >/tmp/gnome/gui.pid
sleep 3
~/.local/bin/skrepka doctor --json >"${RUN}/logs/doctor.json" 2>&1
backend=$(jq -r '.session.backendName + "; xwayland=" + (.session.isXWaylandFallback|tostring)' "${RUN}/logs/doctor.json" 2>/dev/null || echo unknown)
wayland_warnings=$(jq '[.problems[] | select(test("XWayland|native Wayland"))] | length' "${RUN}/logs/doctor.json" 2>/dev/null || echo 1)
echo "backend: ${backend}"
echo "stale Wayland warnings after extension submission: ${wayland_warnings}"
if grep -q 'gnome wayland capture' <<<"${wayland_text}"; then echo "GNOME Wayland text: seen"; else echo "GNOME Wayland text: missing"; fi
if grep -q '"kind":"image"' <<<"${wayland_image}"; then echo "GNOME Wayland image: seen"; else echo "GNOME Wayland image: missing"; fi
if grep -q 'wayland-capture.txt' <<<"${wayland_file}"; then echo "GNOME Wayland file: seen"; else echo "GNOME Wayland file: missing"; fi
if [[ ${extension_disabled} == yes ]] && grep -q 'gnome x11 capture' <<<"${x11}"; then echo "X11 client: seen without extension"; else echo "X11 client: missing or extension stayed active"; fi
if [[ ${extension} == *'State: ACTIVE'* ]] \
    && grep -q 'gnome wayland capture' <<<"${wayland_text}" \
    && grep -q '"kind":"image"' <<<"${wayland_image}" \
    && grep -q 'wayland-capture.txt' <<<"${wayland_file}" \
    && [[ ${extension_disabled} == yes ]] \
    && grep -q 'gnome x11 capture' <<<"${x11}" \
    && [[ ${wayland_warnings} == 0 ]]; then
    echo "RESULT 2 capture PASS: Shell extension captured Wayland text, image and file; XFIXES captured X11 (${backend})"
else
    problem=$(jq -r '.session.problem // "clipboard entries missing"' "${RUN}/logs/doctor.json" 2>/dev/null)
    echo "RESULT 2 capture FAIL: extension inactive or a selection missing (${backend}); ${problem}"
fi
EOF

# 3. StatusNotifierItem registration with Ubuntu's AppIndicator watcher.
session <<'EOF' | tee "${RUN_DIR}/logs/3-tray.txt"
set -uo pipefail
pid=$(cat /tmp/gnome/gui.pid)
items=
for _ in $(seq 60); do
    items=$(busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher \
        org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems 2>/dev/null || true)
    [[ ${items} == *"-${pid}-"* ]] && break
    sleep 0.25
done
printf 'watcher: %s\n' "${items}"
skrepka-gnome-screenshot "${RUN}/shots/3-tray.png" >/dev/null
if [[ ${items} == *"-${pid}-"* ]] && gnome-extensions list --enabled | grep -q ubuntu-appindicators; then
    echo "RESULT 3 tray PASS: ${items}; Ubuntu AppIndicator extension enabled"
else
    echo "RESULT 3 tray FAIL: no Skrepka item in the AppIndicator watcher (${items:-no watcher})"
fi
EOF

# 4. Accept GNOME's GlobalShortcuts dialog via real key events, then press the shortcut.
session <<'EOF' | tee "${RUN_DIR}/logs/4-shortcut.txt"
set -uo pipefail
picker_open() { skrepka-gnome-windows | grep -Eqi 'Skrepka|skrepka-gui'; }
dialog=no
for _ in $(seq 30); do
    if skrepka-gnome-windows | grep -q '^Add Keyboard Shortcuts|'; then dialog=yes; break; fi
    sleep 0.5
done
if [[ ${dialog} == yes ]]; then
    skrepka-gnome-screenshot "${RUN}/shots/4-shortcut-dialog.png" >/dev/null
    # GNOME starts headless sessions in Overview. The first click activates
    # the portal window and leaves Overview; it is deliberately on the title,
    # not a button. Once GNOME finishes that transition, use Add's mnemonic.
    geometry=$(skrepka-gnome-windows | grep '^Add Keyboard Shortcuts|' | head -1 | cut -d'|' -f3)
    x=${geometry%%,*}; rest=${geometry#*,}; y=${rest%%,*}; size=${rest#*,}; w=${size%x*}
    skrepka-gnome-input click $((x + w / 2)) $((y + 20))
    sleep 1
    geometry=$(skrepka-gnome-windows | grep '^Add Keyboard Shortcuts|' | head -1 | cut -d'|' -f3)
    x=${geometry%%,*}; rest=${geometry#*,}; y=${rest%%,*}; size=${rest#*,}; w=${size%x*}
    skrepka-gnome-screenshot "${RUN}/shots/4-shortcut-add-focused.png" >/dev/null
    skrepka-gnome-input key alt+a
    sleep 3
fi
status=$(~/.local/bin/skrepka-gui --status 2>&1)
printf '%s\n' "${status}"
skrepka-gnome-input key super+shift+v
sleep 2
skrepka-gnome-screenshot "${RUN}/shots/4-shortcut-pressed.png" >/dev/null
if picker_open; then
    echo "RESULT 4 shortcut PASS: GNOME accepted show-picker and a real Super+Shift+V opened it"
    ~/.local/bin/skrepka-gui --picker >>"${RUN}/logs/skrepka-gui.log" 2>&1
else
    echo "RESULT 4 shortcut FAIL: dialog=${dialog}; shortcut did not open the picker"
    # Do not let the still-modal consent window contaminate picker focus tests.
    pkill -f gnome-control-center-global-shortcuts-provider 2>/dev/null || true
fi
sleep 1
EOF

# 5. Plain picker over a normal app window: context menu, Escape, then click-away.
session <<'EOF' | tee "${RUN_DIR}/logs/5-picker.txt"
set -uo pipefail
picker_open() { skrepka-gnome-windows | grep -Eqi 'Skrepka|skrepka-gui'; }
cat > /tmp/picker-backdrop.py <<'PY'
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk
app = Gtk.Application(application_id="dev.soldunov.PickerBackdrop")
def activate(application):
    window = Gtk.ApplicationWindow(application=application, title="Background Window")
    window.set_default_size(720, 480)
    window.set_child(Gtk.Label(label="The picker should float above this window"))
    window.present()
app.connect("activate", activate)
app.run()
PY
nohup python3 /tmp/picker-backdrop.py >"${RUN}/logs/picker-backdrop.log" 2>&1 &
backdrop=$!
sleep 2
~/.local/bin/skrepka-gui --picker >>"${RUN}/logs/skrepka-gui.log" 2>&1
sleep 2
mapped=no; picker_open && mapped=yes
skrepka-gnome-screenshot "${RUN}/shots/5-picker-over-window.png" >/dev/null
geometry=$(skrepka-gnome-windows | grep -Ei 'Skrepka|skrepka-gui' | head -1 | cut -d'|' -f3)
x=${geometry%%,*}; rest=${geometry#*,}; y=${rest%%,*}; size=${rest#*,}; w=${size%x*}
if [[ ${x} =~ ^-?[0-9]+$ && ${y} =~ ^-?[0-9]+$ && ${w} =~ ^[0-9]+$ ]]; then
    skrepka-gnome-input click $((x + w / 2)) $((y + 120)) secondary
    sleep 1
    skrepka-gnome-screenshot "${RUN}/shots/5-picker-context-menu.png" >/dev/null
    skrepka-gnome-input key Escape
fi
skrepka-gnome-input key Escape
sleep 1
escaped=yes; picker_open && escaped=no
~/.local/bin/skrepka-gui --picker >>"${RUN}/logs/skrepka-gui.log" 2>&1
sleep 1
skrepka-gnome-input click 100 100
sleep 2
clicked=yes; picker_open && clicked=no
skrepka-gnome-screenshot "${RUN}/shots/5-after-click-away.png" >/dev/null
picker_open && ~/.local/bin/skrepka-gui --picker >>"${RUN}/logs/skrepka-gui.log" 2>&1
kill "${backdrop}" 2>/dev/null || true
if [[ ${mapped}/${escaped}/${clicked} == yes/yes/yes ]]; then
    echo "RESULT 5 picker PASS: plain window mapped; Escape and outside click each closed it"
else
    echo "RESULT 5 picker FAIL: mapped=${mapped}, Escape closed=${escaped}, outside click closed=${clicked}"
fi
EOF

# 6. Auto-paste into a focused native Wayland GTK4 text view.
session <<'EOF' | tee "${RUN_DIR}/logs/6-paste.txt"
set -uo pipefail
cat > /tmp/paste-target.py <<'PY'
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk
path = "/tmp/paste-target.txt"
app = Gtk.Application(application_id="dev.soldunov.Skrepka.PasteTarget")
def activate(application):
    window = Gtk.ApplicationWindow(application=application, title="Skrepka Paste Target")
    window.set_default_size(500, 240)
    view = Gtk.TextView()
    view.get_buffer().connect("changed", lambda b: open(path, "w").write(b.get_text(b.get_start_iter(), b.get_end_iter(), True)))
    window.set_child(view)
    window.present()
    view.grab_focus()
app.connect("activate", activate)
app.run()
PY
rm -f /tmp/paste-target.txt
nohup python3 /tmp/paste-target.py >"${RUN}/logs/paste-target.log" 2>&1 &
sleep 2
printf 'gnome automatic paste' | xclip -selection clipboard
sleep 2
picker_open() { skrepka-gnome-windows | grep -Eq '^dev\.soldunov\.Skrepka\.App\|'; }
picker_open && ~/.local/bin/skrepka-gui --picker >>"${RUN}/logs/skrepka-gui.log" 2>&1
sleep 1
shortcut_ready=no
if ~/.local/bin/skrepka-gui --status 2>&1 | grep -q '^shortcut: bound'; then
    shortcut_ready=yes
    skrepka-gnome-input key super+shift+v
else
    # Keep testing Return/copy/paste even when the preceding independent
    # shortcut check failed; record that the picker needed direct opening.
    ~/.local/bin/skrepka-gui --picker >>"${RUN}/logs/skrepka-gui.log" 2>&1
fi
sleep 2
picker_open || ~/.local/bin/skrepka-gui --picker >>"${RUN}/logs/skrepka-gui.log" 2>&1
sleep 1
skrepka-gnome-input key alt+1
consent=no
portal_window=
for _ in $(seq 30); do
    portal_window=$(skrepka-gnome-windows | grep -E '^Remote Desktop\|.*\|[-0-9]+,[-0-9]+,[1-9][0-9]*x[1-9][0-9]*\|' | head -1 || true)
    [[ -n ${portal_window} ]] && { consent=yes; break; }
    sleep 0.25
done
if [[ ${consent} == yes ]]; then
    echo "portal window: ${portal_window}"
    skrepka-gnome-eval '(() => { const w=global.get_window_actors().map(a=>a.meta_window).find(w=>w.get_title()==="Remote Desktop"); if (!w) return "missing"; w.activate(global.get_current_time()); return "activated"; })()' >/dev/null
    sleep 1
    skrepka-gnome-screenshot "${RUN}/shots/6-remote-desktop-consent.png" >/dev/null
    # Move from Remember This Selection to Allow Remote Interaction, enable
    # it, then use Share's Alt+S mnemonic.
    skrepka-gnome-input key Tab; sleep 0.5
    skrepka-gnome-input key Tab; sleep 0.5
    skrepka-gnome-input key space
    sleep 1
    skrepka-gnome-screenshot "${RUN}/shots/6-remote-desktop-consent-enabled.png" >/dev/null
    skrepka-gnome-input key alt+s
fi
for _ in $(seq 30); do
    first_text=$(cat /tmp/paste-target.txt 2>/dev/null || true)
    [[ ${first_text} == *'gnome automatic paste'* ]] && break
    sleep 0.25
done
retry_text=${first_text}
retry_consent=no
if [[ ${first_text} != *'gnome automatic paste'* ]]; then
    # A first-use portal can return before focus has gone back to the target.
    # Retry once to distinguish that race from a portal/session failure.
    for _ in $(seq 20); do
        skrepka-gnome-windows | grep -q '^Remote Desktop|' || break
        sleep 0.25
    done
    ~/.local/bin/skrepka-gui --picker >>"${RUN}/logs/skrepka-gui.log" 2>&1
    sleep 2
    skrepka-gnome-input key alt+1
    sleep 1
    skrepka-gnome-windows | grep -q '^Remote Desktop|' && retry_consent=yes
    for _ in $(seq 30); do
        retry_text=$(cat /tmp/paste-target.txt 2>/dev/null || true)
        [[ ${retry_text} == *'gnome automatic paste'* ]] && break
        sleep 0.25
    done
fi
skrepka-gnome-screenshot "${RUN}/shots/6-paste-result.png" >/dev/null
echo "shortcut ready: ${shortcut_ready}"
echo "consent dialog: ${consent}; retry consent: ${retry_consent}"
echo "first target text: ${first_text}"
echo "retry target text: ${retry_text}"
echo "app paste log:"
grep -a 'paste:' "${RUN}/logs/skrepka-gui.log" || true
echo "portal traffic:"
grep -a -E 'member=(CreateSession|SelectDevices|Start|NotifyKeyboardKeycode|Response)|uint32 [012]|error_name=' \
    "${RUN}/logs/dbus-portal.log" || true
if [[ ${first_text} == *'gnome automatic paste'* ]]; then
    echo "RESULT 6 paste PASS: GNOME granted RemoteDesktop and the first Ctrl+V reached the GTK4 target"
elif [[ ${retry_text} == *'gnome automatic paste'* ]]; then
    echo "RESULT 6 paste FAIL: GNOME granted RemoteDesktop but the first Ctrl+V missed; one no-dialog retry reached the target"
else
    echo "RESULT 6 paste FAIL: target stayed '${retry_text:-empty}' after consent and retry (consent=${consent})"
fi
EOF

scripts/gnome.sh bash -c "mkdir -p '${RUN}/logs/session' && cp /tmp/gnome/logs/*.log '${RUN}/logs/session/'"
{
    echo "subject: ${SOURCE}"
    echo "duration: $((SECONDS - start))s"
    echo "session: $(scripts/gnome.sh bash -lc "gnome-shell --version; dpkg-query -W mutter-common xdg-desktop-portal xdg-desktop-portal-gnome libgtk-4-1 libglib2.0-0t64 libgl1-mesa-dri" | tr '\n' '; ')"
    grep -h '^RESULT' "${RUN_DIR}"/logs/[1-6]-*.txt || [[ $? -eq 1 ]]
} >"${RUN_DIR}/summary.txt"
cat "${RUN_DIR}/summary.txt"
echo "evidence: build/gnome/smoke/${RUN_ID}/"
missing=
for check in 1 2 3 4 5 6; do grep -q "^RESULT ${check} " "${RUN_DIR}/summary.txt" || missing="${missing} ${check}"; done
[[ -z ${missing} ]] || { echo "no result from check(s):${missing}" >&2; exit 1; }
# The screenshots are half of every result, and a capture that failed inside
# the session still leaves its check's PASS line behind. These six are taken on
# every run, whatever the checks found; the consent and menu shots are not.
absent=
for shot in 0-desktop-ready 3-tray 4-shortcut-pressed 5-picker-over-window 5-after-click-away 6-paste-result; do
    [[ -s "${RUN_DIR}/shots/${shot}.png" ]] || absent="${absent} ${shot}.png"
done
[[ -z ${absent} ]] || { echo "missing or empty screenshot(s):${absent}" >&2; exit 1; }
! grep -q '^RESULT .* FAIL' "${RUN_DIR}/summary.txt"
