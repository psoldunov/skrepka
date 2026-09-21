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
if [[ ${installed} == yes ]] && busctl --user status dev.soldunov.Skrepka >/dev/null 2>&1; then
    echo "RESULT 1 install PASS: install.sh --tarball completed and skrepkad owns dev.soldunov.Skrepka"
else
    echo "RESULT 1 install FAIL: installer or daemon startup failed"
fi
EOF

# 2. Capture from native Wayland GTK4 and X11 xclip; preserve doctor output.
session <<'EOF' | tee "${RUN_DIR}/logs/2-capture.txt"
set -uo pipefail
cat > /tmp/wayland-copy.py <<'PY'
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GLib, Gtk
app = Gtk.Application(application_id="dev.soldunov.Skrepka.WaylandCopy")
def activate(application):
    window = Gtk.ApplicationWindow(application=application, title="Wayland clipboard owner")
    window.set_default_size(320, 80)
    window.present()
    Gdk.Display.get_default().get_clipboard().set("gnome wayland capture")
    GLib.timeout_add_seconds(8, lambda: application.quit() or GLib.SOURCE_REMOVE)
app.connect("activate", activate)
app.run()
PY
nohup python3 /tmp/wayland-copy.py >"${RUN}/logs/wayland-copy.log" 2>&1 &
sleep 2
wayland=$(~/.local/bin/skrepka list --json 2>&1)
printf '%s\n' "${wayland}" >"${RUN}/logs/list-after-wayland.json"
printf 'gnome x11 capture' | xclip -selection clipboard
sleep 2
x11=$(~/.local/bin/skrepka list --json 2>&1)
printf '%s\n' "${x11}" >"${RUN}/logs/list-after-x11.json"
~/.local/bin/skrepka doctor --json >"${RUN}/logs/doctor.json" 2>&1
backend=$(jq -r '.session.backendName + "; xwayland=" + (.session.isXWaylandFallback|tostring)' "${RUN}/logs/doctor.json" 2>/dev/null || echo unknown)
echo "backend: ${backend}"
if grep -q 'gnome wayland capture' <<<"${wayland}"; then echo "Wayland client: seen"; else echo "Wayland client: missing"; fi
if grep -q 'gnome x11 capture' <<<"${x11}"; then echo "X11 client: seen"; else echo "X11 client: missing"; fi
if grep -q 'gnome wayland capture' <<<"${wayland}" && grep -q 'gnome x11 capture' <<<"${x11}"; then
    echo "RESULT 2 capture PASS: both native Wayland and X11 clipboard changes reached history (${backend})"
else
    problem=$(jq -r '.session.problem // "clipboard entries missing"' "${RUN}/logs/doctor.json" 2>/dev/null)
    echo "RESULT 2 capture FAIL: one or both clipboard changes missing (${backend}); ${problem}"
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
    # not a button. Once GNOME finishes that transition, click Add directly.
    geometry=$(skrepka-gnome-windows | grep '^Add Keyboard Shortcuts|' | head -1 | cut -d'|' -f3)
    x=${geometry%%,*}; rest=${geometry#*,}; y=${rest%%,*}; size=${rest#*,}; w=${size%x*}
    skrepka-gnome-input click $((x + w / 2)) $((y + 20))
    sleep 1
    geometry=$(skrepka-gnome-windows | grep '^Add Keyboard Shortcuts|' | head -1 | cut -d'|' -f3)
    x=${geometry%%,*}; rest=${geometry#*,}; y=${rest%%,*}; size=${rest#*,}; w=${size%x*}
    skrepka-gnome-screenshot "${RUN}/shots/4-shortcut-add-focused.png" >/dev/null
    skrepka-gnome-input click $((x + w - 38)) $((y + 21))
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
geometry=$(skrepka-gnome-windows | grep '^dev\.soldunov\.Skrepka\.App|' | head -1 | cut -d'|' -f3)
x=${geometry%%,*}; rest=${geometry#*,}; y=${rest%%,*}; size=${rest#*,}; w=${size%x*}; h=${size#*x}
skrepka-gnome-input double-click $((x + w / 2)) $((y + 105))
consent=no
portal_window=
for _ in $(seq 30); do
    portal_window=$(skrepka-gnome-windows | grep -Ev '^(Skrepka Paste Target|dev\.soldunov\.Skrepka\.App)\|' | head -1 || true)
    [[ -n ${portal_window} ]] && { consent=yes; break; }
    sleep 0.25
done
if [[ ${consent} == yes ]]; then
    echo "portal window: ${portal_window}"
    skrepka-gnome-screenshot "${RUN}/shots/6-remote-desktop-consent.png" >/dev/null
    geometry=$(cut -d'|' -f3 <<<"${portal_window}")
    x=${geometry%%,*}; rest=${geometry#*,}; y=${rest%%,*}; size=${rest#*,}; w=${size%x*}; h=${size#*x}
    skrepka-gnome-input click $((x + w - 70)) $((y + h - 35))
fi
for _ in $(seq 30); do
    text=$(cat /tmp/paste-target.txt 2>/dev/null || true)
    [[ ${text} == *'gnome automatic paste'* ]] && break
    sleep 0.25
done
skrepka-gnome-screenshot "${RUN}/shots/6-paste-result.png" >/dev/null
text=$(cat /tmp/paste-target.txt 2>/dev/null || true)
echo "shortcut ready: ${shortcut_ready}"
echo "consent dialog: ${consent}"
echo "target text: ${text}"
echo "app paste log:"
grep -a 'paste:' "${RUN}/logs/skrepka-gui.log" || true
echo "portal traffic:"
grep -a -E 'member=(CreateSession|SelectDevices|Start|NotifyKeyboardKeycode|Response)|uint32 [012]|error_name=' \
    "${RUN}/logs/dbus-portal.log" || true
if [[ ${text} == *'gnome automatic paste'* ]]; then
    echo "RESULT 6 paste PASS: picker Return pasted the selected clip into the focused GTK4 target"
else
    echo "RESULT 6 paste FAIL: target stayed '${text:-empty}' after picker Return (consent=${consent})"
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
! grep -q '^RESULT .* FAIL' "${RUN_DIR}/summary.txt"
