# Phase 5 — Linux clipboard backends

**Built 2026-09-07.** Both quality gates green over it: `scripts/doctor.sh`
**526 tests / 69 suites**, `scripts/doctor-linux.sh` **481 tests / 58 suites**,
SwiftLint included.

Two of the three backends are **integration-tested against a live compositor**
rather than merely demonstrated — the "worth trying" note under *Tests* below
turned out to work, on both halves. `docker/Dockerfile.linux` now carries a
headless **Sway 1.9** (wlroots 0.17, advertising
`zwlr_data_control_manager_v1` v2) and **Xvfb** with XFIXES, and 17 tests drive
the real protocols with `wl-copy`, `wl-paste` and `xclip` as the other end.
`ExtDataControlReader` has no compositor to test against anywhere on this
project and remains unverified live — see *Done when*.

**A week and a half. The least familiar territory on the roadmap.**

## Goal

Read every clipboard change and write a selection back, headless, on Wayland
and on X11. No GUI.

## Preconditions

- Phase 4 done, including the `ClipboardSource` protocol.
- Test machines running **Sway**, **KDE Plasma** and **X11**. Three
  environments, because the three backends fail differently and a bug in one is
  invisible from the other two.

  **What exists, as of 2026-09-07** ([D-10](open-questions.md#d-10)): a **Steam
  Deck OLED in Desktop Mode**, which covers the KDE and X11 environments on real
  hardware. It is a stand-in for a proper Linux box, not a target — nothing in
  this phase gets shaped around SteamOS. Game Mode is out of scope: gamescope
  advertises no data-control global at all.

  **Which KDE environment it is depends on the update channel — corrected
  2026-09-07.** The table here used to say Plasma 6.4.3 exercised the legacy
  reader, on the belief that KWin's port landed in Plasma 6.6. It landed in
  Plasma **6.4** (merge request !6606, merged 2025-04-12), and 6.4 advertises
  **both** globals from one implementation; 6.5 dropped the legacy one.

  | Channel | Plasma | Globals advertised | Reader exercised |
  |---|---|---|---|
  | SteamOS 3.8 stable — installed today | 6.4.3 | **both** | `ExtDataControlReader` |
  | SteamOS 3.9 preview | 6.7.3 | ext only | `ExtDataControlReader` |

  Two consequences, and both shaped what was built. `SessionProbe` **prefers
  `ext` and ignores `wlr` when both are present**, or it would bind two devices
  to one seat on 6.4 and record every copy twice. And **the Deck exercises the
  legacy path on neither channel**, so it got a compositor of its own: a
  headless Sway 1.9 in the build image, which advertises
  `zwlr_data_control_manager_v1` v2 and nothing newer.

  **Sway still needs a VM or a second machine**, and **GNOME needs hardware
  nobody has**: its diagnostics case below can be asserted in unit tests but not
  demonstrated live until then.
- Design §4's support matrix re-checked. It is dated 2026-09-04 and every claim
  in it is about a third-party project's current state.

## Deliverables

```
Sources/CWaylandProtocols/          # generated protocol C + module map
  include/module.modulemap
  ext-data-control-v1-client-protocol.h
  ext-data-control-v1-protocol.c
  wlr-data-control-unstable-v1-*
Sources/CXFixesShim/                # module map over libX11 + libXfixes

Sources/SkrepkaLinuxPlatform/
  Backend/
    ClipboardBackend.swift          # the runtime chooser
    SessionProbe.swift              # what the session actually offers
    ExtDataControlReader.swift
    WlrDataControlReader.swift
    XFixesReader.swift
  Mapping/
    LinuxRepresentationMap.swift
  Diagnostics/
    LinuxCaptureProblem.swift

Sources/skrepka-clip-probe/main.swift   # the headless proof

scripts/regenerate-wayland-protocols.sh
```

## Work

### 1. Getting Wayland protocols into Swift

`wayland-scanner` generates C from the protocol XML, and SwiftPM has no
code-generation step short of a build-tool plugin. Two options:

- **Check the generated C into the repository**, with
  `scripts/regenerate-wayland-protocols.sh` to reproduce it. Recommended: the
  protocol XML changes rarely, the generated code is reviewable in a diff, and a
  build that needs `wayland-scanner` on every machine is a build that fails on
  the one machine that matters.
- A SwiftPM build-tool plugin. More correct, more moving parts, and it makes the
  build depend on a tool that has to be present.

Both need a `.systemLibrary` target over `wayland-client` with `pkgConfig:` and
`providers:` for apt and yum, so a missing `libwayland-dev` produces an error
naming the package rather than a linker failure. Confirm the exact
`PackageDescription` spelling against the resolved SwiftPM before writing it.

The same shape covers X11: a module map over `libX11` and `libXfixes`.

### 2. `SessionProbe` — decide by what is advertised, not by what is set

The obvious implementation reads `WAYLAND_DISPLAY` and `XDG_SESSION_TYPE` and
picks a backend. That is wrong often enough to matter: an XWayland client sees
`DISPLAY` set under a Wayland session, and a Wayland session may advertise
neither data-control global.

So probe in this order, and record what was found for the diagnostics:

1. Connect to the Wayland display, if any, and enumerate globals.
2. `ext_data_control_manager_v1` present → `ExtDataControlReader`.
3. Only `zwlr_data_control_manager_v1` present → `WlrDataControlReader`, with a
   note that the protocol's own XML now describes itself as deprecated. **This
   is the branch the test rig takes today** — Plasma 6.4.3 on SteamOS 3.8 stable
   ([D-10](open-questions.md#d-10)) — so "deprecated" must not be read as
   "unexercised".
4. Neither, but `DISPLAY` connects → `XFixesReader` over XWayland, and record
   that this is the lossy path.
5. Neither and no X11 → **report the failure**, do not fall back to nothing.

Case 5 is GNOME, and it is a supported configuration with a known remedy
(Phase 8's Shell extension), not an error. It has to say so.

### 3. The three readers

All three conform to `ClipboardSource` from Phase 4, so `ClipboardWatcher`,
`CaptureRules`, `PrivacyMarkers` and the whole capture pipeline are the ported
code and only the source is new.

**`XFixesReader` is event-driven.** `XFixesSelectSelectionInput` plus
`XFixesSelectionNotify` delivers real selection-change events, so the X11 path
needs no polling at all. That is worth stating in the code: this backend is
strictly better than the macOS one, which is stuck at 200 ms because
`NSPasteboard.h` declares no change notification of any kind. `ClipboardSource`
has to accommodate both shapes — a `changeCount()`-style poll and a push stream
— or the event-driven backend is forced to pretend it is a polling one.

**Both Wayland readers** need a live `wl_display` connection and an event loop.
That loop is not the Swift concurrency runtime's, so it needs a thread and a
carefully drawn boundary; an `actor` owning the connection, with the dispatch
loop on its own thread feeding an `AsyncStream`, is the shape that matches how
`ClipboardWatcher` already behaves.

**Selection data arrives through a pipe.** `receive` hands over a file
descriptor per MIME type, and reading them all means reading several
concurrently or in a fixed order without deadlocking against a sender that is
waiting for you to drain. Bound each read by `SyncLimits.maximumPayloadBytes`
and by a timeout: a malicious or broken source that never closes the pipe must
not hang capture.

### 4. Representation mapping

Reuse `RepresentationKey` and `RepresentationKeyMap` from Phase 1. Do not define
a second table — the whole point of canonical MIME on the wire is that there is
one vocabulary and it is mapped at each boundary.

What Linux actually offers, per design §8: GTK4's built-in serializers are
`image/png`, `image/tiff`, `image/jpeg`, `text/plain;charset=utf-8`,
`text/plain`, `text/uri-list` and `application/x-color`. `text/rtf` is offered
only by LibreOffice and Qt apps; in practice Linux rich text is `text/html`.
`x-special/gnome-copied-files` carries GNOME's cut-vs-copy verb, which has no
macOS equivalent.

### 5. Diagnostics

The `Diagnostics/` tree already models exactly this — "why is nothing being
captured" — so extend `CaptureHealth` and `DiagnosticsProblem` rather than
inventing a parallel mechanism. New problems worth naming, each with the same
`summary` / `headline` / `remedy` triple the existing cases carry:

- GNOME Wayland with no Shell extension installed → the remedy names the
  extension.
- Only `wlr-data-control` available → capture works, and the protocol is
  deprecated.
- No data-control global and no X11 → capture cannot work in this session, and
  the message says which compositor was detected.

`DiagnosticsProblem.ranked` gains these, and the ranking rule stays what it is:
one problem in front of the user, the most destructive first.

## Tests

Honest about what is testable:

**Yes** — `SessionProbe`'s decision table over synthetic global lists; the
representation mapping in both directions; pipe-read framing, bounding and
timeout against a fake file descriptor; the new diagnostics cases.

**No** — a real compositor's behaviour. That is what the headless probe binary
is for.

**Worth trying**: a nested headless compositor in CI. Sway can run against a
headless backend, which would make `ExtDataControlReader` testable without a
display. Confirm whether that works before promising it — if it does, it is the
difference between a backend that is tested and one that is merely demonstrated.

**It works — confirmed 2026-09-07, and it is what shipped.** `sway` with
`WLR_BACKENDS=headless` runs inside the Linux build image with no DRM device and
no display, and advertises `zwlr_data_control_manager_v1` v2. `Xvfb` gives the
X11 side a real server carrying XFIXES. Both are in
`docker/Dockerfile.linux`; `Tests/SkrepkaLinuxPlatformTests/HeadlessSession.swift`
starts and stops them per test, and `wl-copy`, `wl-paste` and `xclip` are the
other end of every assertion — a test where Skrepka is on both sides proves only
that it agrees with itself.

One correction to the hope above: it makes **`WlrDataControlReader`** testable,
not `ExtDataControlReader`. Sway 1.9 is wlroots 0.17, which predates
`ext-data-control-v1` entirely.

Two bugs came out of running against a real compositor that no unit test would
have found: the Wayland loop indexed its `poll` results positionally into a
transfer list that dispatching could grow, and the write ends of the `receive`
pipes were closed before the flush that sends them — libwayland stores the raw
descriptor number in a ring buffer rather than duplicating it.

## Done when

`skrepka-clip-probe` runs on Sway, on KDE Wayland and on X11, and for each:

- logs every clipboard change with the correct `ClipKind` and representations
- writes a selection back that another app can paste
- survives the compositor restarting under it

**Status 2026-09-07.** The first two are asserted automatically against a
headless Sway and an Xvfb, for `WlrDataControlReader` and `XFixesReader` — text,
HTML, a 1 MB payload through the pipe, X11's `INCR` in both directions, the
ICCCM-mandated `TARGETS`/`TIMESTAMP`/`MULTIPLE`, the KDE privacy hint honoured
by value, and a selection `wl-paste` and `xclip` can read back. The third —
surviving a compositor restart — is a reconnect loop in `skrepka-clip-probe
watch` and is **not** covered by a test; the reconnection *policy* belongs to
the Phase 6 daemon.

Still to run by hand, and none of them a code task: the probe on the Steam
Deck's KDE session, which is the only way `ExtDataControlReader` gets exercised
at all; the probe on a Sway session with a display; and the GNOME case below.

The KDE and X11 runs happen on the Steam Deck ([D-10](open-questions.md#d-10)),
in Desktop Mode. Both update channels exercise `ExtDataControlReader` — see the
corrected table under *Preconditions* — so running both is no longer worth the
reinstall. `WlrDataControlReader` is covered by the headless Sway instead.

**Deferred, not dropped:** that the probe reports the right
`DiagnosticsProblem` under GNOME Wayland rather than silently capturing nothing.
There is no GNOME machine ([OQ-3](open-questions.md#oq-3)), so this phase closes
with that case asserted in unit tests over a synthetic global list and marked
unverified against a live session. It is the first thing to run when GNOME
hardware appears, because it is the message every GNOME user meets first.

`scripts/doctor-linux.sh` green. `scripts/doctor.sh` still green — the
`ClipboardSource` shape may have moved.

## Risks

**The support matrix has rotted.** Design §4 is dated and every row is a claim
about someone else's project. Re-check before building, particularly
`ext-data-control-v1`'s status: it was a *staging* protocol first shipped in
`wayland-protocols` 1.39, and staging protocols move.

**Wayland event-loop integration fights Swift concurrency.** The most likely
source of a schedule overrun in this phase. Keep the connection and its thread
inside one actor and let nothing else see the `wl_display` pointer.

**`ClipboardSource` turns out to be the wrong shape.** It was designed in
Phase 4 against a polling backend and now has to serve an event-driven one. If
it needs changing, change it here and take the macOS-side churn — a protocol
bent to fit is worse than a protocol edited once.
