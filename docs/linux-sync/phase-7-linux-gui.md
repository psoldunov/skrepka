# Phase 7 — The Linux GUI

**Two to three weeks, and the widest error bars on the roadmap. If a phase
slips, it is this one.**

## Goal

Hotkey → picker → select → pasted, on KDE and on Sway, with a working tray icon.

## Preconditions

- Phase 6 done and the daemon useful on its own. That is what makes this phase
  optional rather than load-bearing, and it is worth having that safety net
  before starting the most uncertain work on the list.
- [D-4](open-questions.md#d-4) is settled: **three days for the bake-off, and if
  both toolkits fail, the project stops at Phase 6.** Not Qt, not XWayland-only.
  Step 1 below is how the decision gets made with code rather than on paper.
- [OQ-12](open-questions.md#oq-12) answered, because the mark has to render.

## The honest starting position

Design §5 ranks the Swift GUI options bluntly and no option scores better than
"alive but thin":

1. **`stackotter/swift-cross-ui`** — alive, GTK backend. No tray icon and no
   floating-palette window role, both of which Skrepka needs.
2. **`rhx/SwiftGtk`** — raw GTK4 bindings, alive but thin.
3. **`AparokshaUI/adwaita-swift` — archived 2024-10-17.** Verified via the
   GitHub API. Not a candidate.
4. Qt through C++ interop — possible, no prior art for a Swift app.

Re-verify all four before starting. The ranking is dated 2026-09-04 and the top
two are small projects, where a year is the difference between thriving and
abandoned.

## Deliverables

```
Sources/SkrepkaLinuxUI/
  Picker/{PickerWindow,PickerList,PickerRow,SearchEntry}.swift
  Tray/StatusNotifierItem.swift
  Hotkey/GlobalShortcutsPortal.swift
  Settings/{SettingsWindow,RetentionPane,ExclusionsPane,PeersPane}.swift
  Thumbnails/GdkPixbufThumbnailMaker.swift    # ThumbnailProducing conformance
Sources/SkrepkaCore/Branding/
  MarkPath.swift                # portable path IR, if OQ-12 says so
prototypes/                     # step 1, kept or deleted deliberately
```

## Work

### 1. Decide the toolkit with a prototype, not a table

Before building the real picker, build the floating palette twice — once on
`swift-cross-ui`, once on raw `rhx/SwiftGtk`. **Three days total, and per
[D-4](open-questions.md#d-4) that is a budget rather than an estimate:** if day
three ends with a palette that almost works, that is a failure, not an argument
for day four.

The palette is the right prototype because it is the hardest widget in the
product: an undecorated, centred, non-activating, keyboard-driven overlay that
appears over the frontmost app without stealing focus from it. Whichever toolkit
can express that is the answer, and neither README will tell you.

Specifically, the prototype has to demonstrate:

- a window that takes keyboard input without activating, so the app underneath
  keeps its selection and its caret
- placement centred on the active output, not on output zero
- Escape dismisses, arrow keys navigate, Return selects, and the first keystroke
  after the hotkey lands in the search field
- it works on Sway *and* on KDE — a layer-shell-only solution is not a solution

Record the outcome in this file. Whoever picks this up next should not have to
re-run the bake-off.

### 2. The picker

`Matcher` and `ClipSummary` port unchanged from Phase 4, so this is a view layer
over logic that is already tested. Search field, rows with thumbnails, keyboard
navigation, and the ⌘1–⌘9 equivalents — which on Linux are Alt+1–9 or Ctrl+1–9,
and that is a convention question rather than a port.

Read `Sources/Skrepka/Picker/` first. The row layout, the empty state, the
footer hints and the metrics are all decided there, and the Linux picker should
be recognisably the same product rather than a second design.

### 3. Global hotkey

`org.freedesktop.portal.GlobalShortcuts` v2, implemented by both
`xdg-desktop-portal-gnome` and `xdg-desktop-portal-kde`. **This is the one
Wayland story that is genuinely fine** — shortcuts through the portal work the
same on Wayland and X11, which GPaste's README confirms.

The portal binds shortcuts to a *session*, so the daemon has to hold one open
and re-establish it when the portal restarts. Handle that; a hotkey that stops
working after a suspend is the most annoying possible failure for this app.

### 4. Tray

StatusNotifierItem. Native on KDE. **GNOME Shell ships no SNI host** and needs
the AppIndicator extension, which distributions package but do not install by
default — so detect its absence and say so through the Phase 5 diagnostics,
rather than showing nothing and leaving the user to conclude the app did not
start.

The mark itself comes from `PaperclipPath`, which is where
[OQ-12](open-questions.md#oq-12) lands. If Core Graphics path types are absent
on Linux, extract a portable path IR — a small value type of
`move`/`line`/`curve`/`close` — rendered to `CGPath` on macOS and to Cairo on
Linux. `scripts/paperclip.svg` stays the design source and
`scripts/make-icon.sh` keeps compiling the same file, so the icon, the menu bar
and the tray still cannot drift.

### 5. Settings

Retention, exclusions, paired devices with the per-peer live-push toggle, and
the pairing flow with its SAS. The peer row carries the same "Universal
Clipboard already does this" explanation the macOS row does, for the same
reason.

### 6. Thumbnails

**This is where `ThumbnailProducing` gets introduced**, not Phase 4 —
[D-9](open-questions.md#d-9) defers it to the point where there is a second real
conformance to put behind it. `GdkPixbufThumbnailMaker` is that conformance;
`ThumbnailMaker` becomes the other. This is also where the
`ImageFileThumbnail` behaviour gets its Linux counterpart — reading a copied
file to preview it, with the same rule the macOS one follows: a file that turns
out not to be a picture simply gets no preview.

## Tests

`Matcher`, `ClipSummary` and `PreviewText` are already tested from Phase 4 and
that is where the logic lives.

Do **not** write tests that assert a view can be constructed. The repo's
conventions rule that out explicitly, and it would be twice as tempting here
because everything else in this phase is hard to test.

What is worth testing: the thumbnail conformance against real image files, the
portal session's reconnect logic against a fake bus, and the path IR against the
same SVG fixtures `PaperclipPathTests` uses on macOS — that last one is a
genuine win, because it proves the two platforms draw the same mark.

## Done when

On KDE **and** on Sway:

1. Hotkey opens the picker over the frontmost app, which keeps its caret.
2. Typing filters. Arrows navigate. Return pastes into the app underneath.
3. The tray icon appears, its menu works, and the mark is the right mark.
4. Settings changes take effect without a restart.
5. Pairing can be completed entirely from the GUI.
6. The picker opens in under 150 ms from a cold daemon — the macOS one is
   effectively instant and a visibly slower Linux picker will read as broken.

`scripts/doctor-linux.sh` green.

## Risks

**Neither toolkit can express the palette.** The real risk in this phase, and
step 1 exists to find out in three days rather than three weeks. **If both fail,
the answer is already decided: stop at Phase 6** and leave the CLI as the
interface ([D-4](open-questions.md#d-4)). That is not a consolation prize —
Phase 6 already delivers the product's value.

XWayland-only and Qt-through-interop were both considered and rejected. Do not
reopen either without reopening D-4 first.

**The toolkit is abandoned mid-phase.** Both candidates are small projects. If
one is archived during the work, that is a reason to reconsider, not to soldier
on — design §5 already recorded one archived binding that would have cost weeks.

**Scope creep against the macOS app.** The Linux picker will be missing things
the macOS one has, and the temptation is to close every gap. Close the ones in
the "done when" list and write the rest down.
