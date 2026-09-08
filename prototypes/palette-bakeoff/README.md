# The Phase 7 toolkit bake-off

This is the prototype that set the current toolkit direction for the Linux GUI.
The direction remains provisional pending Steam Deck/KDE validation. It is **a
record, not a maintained artefact** — see "What this is not" below.

The current direction, with the evidence and the rejected options, is written up
in [`docs/linux-sync/phase-7-linux-gui.md`](../../docs/linux-sync/phase-7-linux-gui.md).
This directory is the thing that produced it, kept so that nobody has to re-run
a three-day bake-off to check the conclusion.

## What it demonstrated under Sway

Run under a headless sway inside the Linux build image, on a single 1280×800 output —
the Steam Deck's panel, which is the screen Phase 7 is written against:

| Step 1 requirement | Result |
| --- | --- |
| A window that takes keyboard input without the app underneath losing what it was doing | Yes. The app underneath keeps its text and selection, loses keyboard focus while the palette is up, and has it back the moment the palette closes. |
| Placement centred on the active output, not output zero | **Unverified.** The harness used one output, so it showed centring on that output but did not test active-output selection. |
| Escape dismisses, arrows navigate, Return selects | Yes, all three, driven by real key events through `zwp_virtual_keyboard_manager_v1`. |
| The first keystroke after the hotkey lands in the search field | Yes — but only with `keyboard_interactivity = exclusive`. See below. |
| It works on Sway **and** on KDE | Sway: demonstrated. **KDE: not demonstrated** — no KDE session was available. KWin's registration of `zwlr_layer_shell_v1` was confirmed by reading its source, which is evidence and not a test. |

`palette-on-sway-1280x800.png` is the screenshot the harness took, through
`grim`, of the palette overlaying the app underneath.

## The two findings that changed the design

**`on_demand` is the wrong keyboard mode**, even though it reads like the right
one. The layer-shell spec leaves it implementation-defined — "the user may
focus and unfocus this surface in an implementation-defined manner" — and sway
only hands focus over on a click. The palette maps, the app underneath keeps
keyboard focus, and everything the user types goes into their document instead
of the search field. `exclusive` delivers keys the moment the surface maps,
which is what a picker opened by a hotkey needs.

**The key controller has to run in the capture phase.** In GTK's default bubble
phase the focused `GtkEntry` sees every key first and swallows the ones the
picker needs; Down and Return never reach the window at all. Capture runs the
window's controller before the focus widget, and unclaimed keys still fall
through to the entry.

Both are in `Sources/SkrepkaLinuxUI/Picker/PaletteWindow.swift`, with the same
reasoning, because both are the kind of thing that gets "simplified" back out.

## Running it

```
docker build -t skrepka-linux:6.3 docker/                    # from the repo root
mkdir -p /tmp/palette-home
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/home-mnt \
  -v /tmp/palette-home:/home-mnt \
  -v "$(pwd)/prototypes/palette-bakeoff:/work" -w /work \
  skrepka-linux:6.3 bash -c 'swift build && bash harness.sh'
```

`harness.sh` starts sway on the headless backend with one output, opens a plain toplevel to be
the app underneath, opens the palette over it, types at it with `wtype`, and
prints what sway thinks is focused before, during and after.

## What this is not

- **Not built by anything.** `swift-format` and SwiftLint are scoped to
  `Sources` and `Tests`, and SwiftPM reads only the root manifest, so nothing
  here is compiled or linted by `scripts/doctor-linux.sh`. It will rot, and that
  is accepted: its job was to answer a question, and the answer is recorded in
  prose that does not rot.
- **Not the picker.** The real one is `Sources/SkrepkaLinuxUI/`, which shares
  none of this code — only its conclusions.
- **Not a substitute for the Deck.** Everything above was measured on sway.
  Phase 7's "done when" list still has to be walked through on KDE.

The one piece worth promoting rather than letting rot is `harness.sh`. Once
there is a real picker binary to point it at, it belongs in `scripts/` and in
the Linux gate — a headless smoke test that the palette still maps, still takes
keys and still gives focus back is worth more than any number of view tests.
