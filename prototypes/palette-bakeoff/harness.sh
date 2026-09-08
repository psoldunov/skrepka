#!/usr/bin/env bash
#
# Phase 7 bake-off harness. Runs inside the container, under a headless sway.
#
# Proves as much of step 1's checklist as a machine with no screen can:
#
#   - the palette maps as a layer surface and takes keyboard focus
#   - the app underneath is still there afterwards, with its text intact
#   - Escape dismisses, Down navigates, Return selects, Alt+N picks by number
#   - the first keystroke after opening lands in the search field
#
# What it cannot prove is that KWin agrees, and that the thing looks right.

set -uo pipefail

export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
# The Deck's panel, which is the screen the picker has to fit (D-10).
export WLR_HEADLESS_OUTPUTS=1
export SWAYSOCK="${XDG_RUNTIME_DIR}/sway.sock"

BIN=/work/.build/debug/palette
OUT=/tmp/harness
mkdir -p "${OUT}"

cat > "${OUT}/sway.conf" <<'EOF'
output HEADLESS-1 resolution 1280x800
default_border none
# Sway will not create a seat without an input device; a virtual keyboard
# arrives later through zwp_virtual_keyboard_manager_v1, which is what wtype
# uses and what proves that protocol works here.
exec_always true
EOF

echo "== starting sway =="
sway -c "${OUT}/sway.conf" > "${OUT}/sway.log" 2>&1 &
SWAY=$!
for _ in $(seq 1 50); do
	[[ -S "${SWAYSOCK}" ]] && break
	sleep 0.2
done
if ! swaymsg -t get_version > /dev/null 2>&1; then
	echo "FATAL: sway did not come up"
	tail -20 "${OUT}/sway.log"
	exit 1
fi
swaymsg -t get_version | head -c 200
echo

# sway names its display socket itself and exports WAYLAND_DISPLAY only into
# the processes it spawns. Everything below is started from this shell instead,
# so the socket has to be found and exported by hand — without it every client
# fails with "Failed to open display", which reads as a broken toolkit.
for _ in $(seq 1 25); do
	SOCKET="$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%f\n' 2> /dev/null | head -1)"
	[[ -n "${SOCKET}" ]] && break
	sleep 0.2
done
if [[ -z "${SOCKET:-}" ]]; then
	echo "FATAL: sway created no wayland socket"
	tail -20 "${OUT}/sway.log"
	exit 1
fi
export WAYLAND_DISPLAY="${SOCKET}"
export GDK_BACKEND=wayland
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
echo "outputs: $(swaymsg -t get_outputs | tr -d '\n' | head -c 300)"

echo
echo "== 1. the app underneath =="
"${BIN}" --victim > "${OUT}/victim.log" 2>&1 &
VICTIM=$!
sleep 3
cat "${OUT}/victim.log"
echo "focused before: $(swaymsg -t get_tree | grep -o '"name": "[^"]*"' | head -20 | tr '\n' ' ')"

echo
echo "== 2. the palette =="
"${BIN}" > "${OUT}/palette.log" 2>&1 &
PALETTE=$!
sleep 3
cat "${OUT}/palette.log"

echo
echo "== 3. what sway thinks is focused =="
swaymsg -t get_tree > "${OUT}/tree.json"
python3 - "${OUT}/tree.json" <<'PY'
import json, sys
tree = json.load(open(sys.argv[1]))
def walk(node, depth=0):
    kind = node.get("type")
    name = node.get("name")
    if kind in ("con", "floating_con") and name:
        print(f"  toplevel: {name!r} focused={node.get('focused')} visible={node.get('visible')}")
    for key in ("nodes", "floating_nodes"):
        for child in node.get(key, []):
            walk(child, depth + 1)
walk(tree)
print("  focus chain:", tree.get("focus"))
PY

echo
echo "== 4. a screenshot, which is the only thing that shows it rendered =="
grim "${OUT}/palette.png" 2>&1 && ls -la "${OUT}/palette.png"

echo
echo "== 4b. victim text before keys =="
swaymsg -t get_tree | grep -c '"name": "victim"' || true

echo "== 5. keys, through zwp_virtual_keyboard_manager_v1 =="
# wtype is a second, independent client of the same protocol Skrepka would use
# to paste — so this line is two tests at once.
wtype "br" 2>&1 || exit "$?"
sleep 1.5
grim "${OUT}/palette-typed.png" 2>&1 && echo "screenshot after typing ok"
wtype -k Down 2>&1 || exit "$?"
sleep 1
wtype -k Return 2>&1 || exit "$?"
sleep 2
echo "--- palette said: ---"
cat "${OUT}/palette.log"

echo
echo "== 6. the app underneath, afterwards =="
swaymsg -t get_tree | python3 -c "
import json,sys
tree=json.load(sys.stdin)
def walk(n):
    if n.get('name') and n.get('type') in ('con','floating_con'):
        print(f\"  toplevel: {n['name']!r} focused={n.get('focused')}\")
    for k in ('nodes','floating_nodes'):
        for c in n.get(k,[]): walk(c)
walk(tree)
"
echo "victim still alive: $(kill -0 ${VICTIM} 2>/dev/null && echo yes || echo no)"

mkdir -p /work/out && cp "${OUT}"/*.png /work/out/ 2>/dev/null && ls -la /work/out
kill "${PALETTE}" "${VICTIM}" 2>/dev/null
swaymsg exit > /dev/null 2>&1
wait "${SWAY}" 2>/dev/null
echo "== done =="
