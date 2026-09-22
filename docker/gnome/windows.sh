#!/usr/bin/env bash
# List Mutter-managed windows as title|class|x,y,WxH|active.
set -euo pipefail
# shellcheck source=/dev/null
[[ -f /tmp/gnome/env ]] && source /tmp/gnome/env
# shellcheck disable=SC2016 # JavaScript belongs to GNOME Shell, not bash.
skrepka-gnome-eval 'global.get_window_actors().map(a => { const w = a.meta_window; const r = w.get_frame_rect(); return `${w.get_title()}|${w.get_wm_class() ?? ""}|${r.x},${r.y},${r.width}x${r.height}|${w.has_focus() ? "active" : ""}`; }).join("\n")'
